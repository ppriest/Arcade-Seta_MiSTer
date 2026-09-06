#!/usr/bin/env python3
"""Diff the core's own bus trace against MAME's, and name the first divergence.

    python scripts/mame_capture.py thunderl --boot-trace 20000 --name tl-boot20k
    scripts/run_sim.sh seta_core_tb +TRACE=20000
    python scripts/diff_core_trace.py debug/tl-boot20k/thunderl_boot.trace \\
                                      sim/seta_core_tb/core.trace

sim/maincpu_tb already diffs the CPU against MAME, but with a behavioural ROM
and every peripheral reading zero -- so it runs out of road the moment the game
reads a DIP switch or a protection register. This compares the WHOLE CORE, with
its real peripherals, against MAME with its real peripherals, and it is the
only test here that can follow a game past its own start-up.

WHY THIS IS AN ALIGNMENT, NOT A LINE-FOR-LINE COMPARISON
--------------------------------------------------------
TG68K is not a cycle-accurate 68000 and its prefetch is not MAME's. Extra
reads, duplicated reads and short reorderings are all expected and are not
faults -- sim/maincpu_tb hit all three before this existed.

The first version of this script tried to handle that with a sliding window
and a single cursor into MAME's trace. It stalled on the first access MAME
never makes and reported 27 matches out of 20,000, which reads as a completely
broken core and was a completely broken matcher: the lookahead has to be able
to skip on BOTH sides. difflib does that correctly but is quadratic and ran for
ten minutes on 100,000 entries without finishing, so `align` below is a bounded
two-pointer walk instead -- O(n * window), and the window only has to cover a
prefetch difference, which is one or two entries.

WRITES ARE THE SIGNAL. A read can differ innocently -- a prefetch is still a
read. A write is the game ACTING on what it read, so the first write that one
side makes and the other does not is where the two machines actually parted.
"""
import argparse
import sys


def load(path, limit=0):
    out = []
    for line in open(path, encoding="utf8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 4:
            f = line.split()
        if len(f) < 4:
            continue
        out.append((f[1].lower(), int(f[2], 16), int(f[3], 16)))
        if limit and len(out) >= limit:
            break
    return out


def fmt(t):
    return f"{t[0]} {t[1]:06X} {t[2]:04X}"


def align(mame, core, window):
    """A bounded two-pointer alignment. O(n*window), not O(n*m).

    difflib does this properly but is quadratic, and these traces are 100,000
    entries -- it ran for ten minutes without finishing. The sequences are
    ~94% identical with short local edits, which is exactly the case a
    windowed walk handles: at each step, look ahead in BOTH streams for the
    nearest agreement and skip whichever side is behind.

    The first version of this script looked ahead in one stream only. It
    stalled on the first access MAME never makes and reported 27 matches out
    of 20,000 -- a completely broken matcher reading as a completely broken
    core. Skipping has to be possible on both sides.

    Returns (matched, core_only, mame_only, data_mismatches, first_gap).
    """
    i = j = 0
    matched = 0
    core_only = mame_only = 0
    data_bad = []
    first_gap = None

    while i < len(mame) and j < len(core):
        if mame[i][0] == core[j][0] and mame[i][1] == core[j][1]:
            matched += 1
            if mame[i][2] != core[j][2]:
                data_bad.append((j, core[j], mame[i]))
            i += 1
            j += 1
            continue

        # Find the nearest re-agreement within the window, preferring the
        # smaller skip so a one-entry prefetch difference costs one entry.
        best = None
        for d in range(1, window + 1):
            if j + d < len(core) and mame[i][0] == core[j + d][0] \
                    and mame[i][1] == core[j + d][1]:
                best = ("core", d)
                break
            if i + d < len(mame) and mame[i + d][0] == core[j][0] \
                    and mame[i + d][1] == core[j][1]:
                best = ("mame", d)
                break
        if best is None:
            if first_gap is None:
                first_gap = (j, i)
            # Nothing agrees within the window: step both and keep going, so
            # one bad region does not abandon the rest of the comparison.
            i += 1
            j += 1
            core_only += 1
            mame_only += 1
            continue
        if first_gap is None:
            first_gap = (j, i)
        if best[0] == "core":
            core_only += best[1]
            j += best[1]
        else:
            mame_only += best[1]
            i += best[1]

    core_only += len(core) - j
    mame_only += len(mame) - i
    return matched, core_only, mame_only, data_bad, first_gap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("core")
    ap.add_argument("--window", type=int, default=24,
                    help="how far to look ahead in either stream for the next "
                         "agreement; a prefetch difference is one or two")
    ap.add_argument("--show", type=int, default=10)
    a = ap.parse_args()

    core = load(a.core)
    # Only as much of MAME's trace as the core's covers, plus slack.
    mame = load(a.mame, limit=len(core) + 4096)
    print(f"MAME  {len(mame)} accesses from {a.mame}")
    print(f"core  {len(core)} accesses from {a.core}")

    matched, core_only, mame_only, data_bad, first_gap = align(
        mame, core, a.window)

    pct = 100.0 * matched / max(len(core), 1)
    print()
    print(f"  matched        {matched} accesses, same direction and address")
    print(f"  agreement      {pct:.1f}% of the core's trace")
    print(f"  core only      {core_only}   (extra or reordered prefetches)")
    print(f"  MAME only      {mame_only}")

    if data_bad:
        print()
        print(f"  DATA MISMATCHES: {len(data_bad)} on accesses both sides make.")
        print(f"  This is the one that matters -- a peripheral returning "
              f"something different.")
        for idx, c, m in data_bad[:a.show]:
            print(f"    core #{idx:7d} {fmt(c)}   MAME {fmt(m)}")
    else:
        print()
        print("  data           every matched access carried the SAME value")

    if first_gap:
        j, i = first_gap
        print()
        print(f"  first divergence at core #{j} / MAME #{i}:")
        for k in range(max(0, j - 3), min(len(core), j + a.show)):
            print(f"    core  {'>' if k == j else ' '} {fmt(core[k])}")
        for k in range(max(0, i - 3), min(len(mame), i + a.show)):
            print(f"    MAME  {'>' if k == i else ' '} {fmt(mame[k])}")

    print()
    if data_bad:
        print(f"FAIL: {len(data_bad)} matched access(es) carried different data")
        return 1
    if pct < 90.0:
        print(f"FAIL: only {pct:.1f}% of the core's trace aligns with MAME's")
        return 1
    print(f"PASS: {matched} of {len(core)} accesses aligned ({pct:.1f}%), "
          f"no data mismatch")
    return 0


if __name__ == "__main__":
    sys.exit(main())
