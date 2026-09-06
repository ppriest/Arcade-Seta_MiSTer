#!/usr/bin/env python3
"""Launch each game in turn and record what the hardware actually does.

    python scripts/sweep.py                    # all deployed FG-2 sets
    python scripts/sweep.py gogomile pbancho   # just these

For each set: launch it, let it settle, clear the probe counters, let it run a
measured interval, read the probe back over JTAG, and take a screenshot. Then
print one row per game so the sets can be compared side by side.

WHY A SWEEP RATHER THAN ONE GAME
--------------------------------
A single black screen says almost nothing -- it is consistent with a dead CPU,
an empty ROM, a broken palette or a dead output stage. Comparing sets separates
those, because the sets differ in known ways:

  gogomile vs gogomileo   program ROM only. Same board, same graphics, same
                          mod byte, same image size.
  gogomile vs pbancho     different program ROM, different graphics, different
                          image SIZE, and mod byte 0x02 instead of 0x00
                          (pbancho swaps SERVICE1 and COIN2 in the SYSTEM
                          port).

Identical numbers across all of them point at something systemic -- the memory
path or the output stage -- and rule out anything game-specific. Numbers that
track image size say the download is faithful.

The counters are CLEARED and then read after a measured interval, because
several of them count per-cycle events and saturate at 65535 almost
immediately; an uncleared read only ever says "lots".

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs a probe to tabulate, and deployed .mra files, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

QUARTUS = Path(r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_stp.exe")
READ_ISSP = REPO / "scripts" / "read_issp.tcl"

# name -> the .mra as deployed. Kept here rather than globbed so a set that
# failed to deploy shows up as an error instead of silently vanishing.
GAMES = {
    "gogomile":  "Susume! Mile Smile - Go Go! Mile Smile (newer)",
    "gogomileo": "_alternatives/_Susume! Mile Smile - Go Go! Mile Smile/"
                 "Susume! Mile Smile - Go Go! Mile Smile (older)",
    "pbancho":   "Gyakuten!! Puzzle Bancho (Japan, set 1)",
    "pbanchoa":  "_alternatives/_Gyakuten!! Puzzle Bancho/"
                 "Gyakuten!! Puzzle Bancho (Japan, set 2)",
}

FIELD = re.compile(r"^\s{2}(\w+)\s+(\S+)\s*$")


def read_probe(clear=False):
    if not QUARTUS.exists():
        sys.exit(f"quartus_stp not found at {QUARTUS}")
    cmd = [str(QUARTUS), "-t", str(READ_ISSP)] + (["clear"] if clear else [])
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=180,
                       cwd=str(REPO))
    if "NO JTAG HARDWARE" in p.stdout or "not found" in p.stdout:
        sys.exit("no JTAG hardware -- is the USB Blaster attached?")
    out = {}
    for line in p.stdout.splitlines():
        m = FIELD.match(line.rstrip())
        if m and m.group(1) not in ("hardware", "device", "instance", "raw"):
            out[m.group(1)] = m.group(2)
    if not out:
        sys.exit(f"could not parse probe output:\n{p.stdout[-800:]}")
    return out


def analyse(png):
    """Distinct colours and the dominant one -- 'is anything being drawn'."""
    try:
        from PIL import Image
    except ImportError:
        return "(PIL not installed)"
    im = Image.open(png).convert("RGB")
    cols = sorted(im.getcolors(maxcolors=1 << 24), reverse=True)
    total = im.size[0] * im.size[1]
    top_n, top_c = cols[0]
    return f"{len(cols)} colours, top {top_c} {100*top_n/total:.1f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("games", nargs="*", default=None)
    ap.add_argument("--measure", type=float, default=3.0,
                    help="seconds to run between clearing and reading (default 3)")
    ap.add_argument("--outdir", default=str(REPO / "debug" / "hw"))
    a = ap.parse_args()

    names = a.games or list(GAMES)
    unknown = [n for n in names if n not in GAMES]
    if unknown:
        sys.exit(f"unknown set(s): {', '.join(unknown)}. "
                 f"Known: {', '.join(GAMES)}")

    outdir = Path(a.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    rows = []

    for name in names:
        print(f"\n=== {name} ===")
        mra = f"/media/fat/_Arcade/{GAMES[name]}.mra"
        r = subprocess.run([sys.executable, str(REPO / "scripts" / "hw.py"),
                            "launch", mra], cwd=str(REPO))
        if r.returncode != 0:
            print(f"  launch failed, skipping"); continue

        time.sleep(4)                       # let the core come up and settle
        read_probe(clear=True)              # zero the counters
        time.sleep(a.measure)               # measured interval
        p = read_probe()

        png = outdir / f"{name}.png"
        subprocess.run([sys.executable, str(REPO / "scripts" / "hw.py"),
                        "shot", "--out", str(png)], cwd=str(REPO))
        pic = analyse(png) if png.exists() else "(no screenshot)"

        for k, v in p.items():
            print(f"    {k:16s} {v}")
        print(f"    picture          {pic}")
        rows.append((name, p, pic))

    # ---- side by side ----
    if len(rows) > 1:
        keys = ["frames", "z80_fetches", "ym_writes", "pcm_keyons",
                "fm_keyons", "snd_peak"]
        print("\n" + "=" * 78)
        print(f"{'set':11s}" + "".join(f"{k:>16s}" for k in keys if k in rows[0][1]))
        for name, p, _ in rows:
            print(f"{name:11s}" + "".join(f"{p.get(k,'-'):>16s}"
                                          for k in keys if k in rows[0][1]))
        print("\npicture:")
        for name, _, pic in rows:
            print(f"  {name:11s} {pic}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
