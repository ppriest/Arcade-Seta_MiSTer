#!/usr/bin/env python3
"""Capture the CPU's first 256 completed accesses after the ROM loads, and
compare the program fetches with MAME's boot trace.

    python scripts/boot_trace.py capture gogomile
    python scripts/boot_trace.py compare gogomile

`capture` loads the game twice -- once with trace source 1 ({FC, word addr})
and once with source 2 ({data, addr[7:0]}) -- because a source is an OSD bit
and the .CFG is only read at load. Both captures are first-N from the moment
the download finishes (the sources are gated on dl_done in fuuki_core.sv), so
entry k of each is the same access, and the low address byte carried by the
data capture is checked against the address capture to prove it.

`compare` extracts the FC=6 program fetches in order and matches MAME's
expected fetch list (scripts/parse_mame_trace.py) as an in-order subsequence
-- the same check sim/maincpu_tb passes 84/84 -- and prints the accesses
around the first divergence with the data the CPU actually consumed.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs the trace ring and its CPU capture source, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import json
import struct
import subprocess
import sys
import time
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from tracer_readout import read_buffer, issp   # noqa: E402

HW = REPO / "scripts" / "hw.py"
CFG = REPO / "scripts" / "cfg.py"
OUT = REPO / "debug" / "hw" / "trace"

MRA = {
    "gogomile": "Susume! Mile Smile - Go Go! Mile Smile (newer)",
    "pbancho":  "Gyakuten!! Puzzle Bancho (Japan, set 1)",
    "asurabld": "Asura Blade - Sword of Dynasty (Japan)",
    "asurabus": "Asura Buster - Eternal Warriors (USA)",
}
# FG-2: (zip, high-byte ROM, low-byte ROM). FG-3 program images are built by
# scripts/build_mra.py's rom_load32_byte; compare() only supports FG-2 here.
PROG = {
    "gogomile": ("gogomile", "fp2n.rom2", "fp1n.rom1"),
    "pbancho":  ("pbancho", "no1..rom2", "no2..rom1"),
}
FC = {1: "udata", 2: "uprog", 5: "Sdata", 6: "Sprog", 7: "IACK"}


def wait_download_done(limit=40):
    import re
    for _ in range(limit):
        time.sleep(2)
        if re.search(r"^\s+ioctl_download\s+no", issp(), re.M):
            return True
    return False


def wait_frozen(limit=30):
    import re
    for _ in range(limit):
        if re.search(r"^\s+ring_frozen\s+yes", issp(), re.M):
            return True
        time.sleep(2)
    return False


def is_vector_read(a):
    return a is not None and (a >> 21) == 5 and 4 <= (a & 0x1FFFFF) <= 9


def capture(game, window=0, fc_only=False, trig=False):
    """window: skip window*8191 ROM reads before recording (the tracer's
    odd step, see debug_tracer.sv); fc_only: one load, addresses only;
    trig: ring mode, frozen by the first exception-vector read, rotated so
    the last entry is that read."""
    OUT.mkdir(parents=True, exist_ok=True)
    result = {}
    srcs = ((1, "fc_addr"),) if fc_only else ((1, "fc_addr"), (2, "data_addr"))
    wtag = "_trig" if trig else (f"_w{window}" if window else "")
    for src, tag in srcs:
        subprocess.run([sys.executable, str(CFG), game, "--set", "overlay=1",
                        f"ring={int(trig)}", f"trig={int(trig)}",
                        f"src={src}", f"window={window}"], capture_output=True, cwd=str(REPO))
        r = subprocess.run([sys.executable, str(HW), "launch", MRA[game]],
                           capture_output=True, text=True, cwd=str(REPO))
        if "launching" not in r.stdout:
            sys.exit(f"launch failed: {r.stdout[-200:]}")
        if not wait_download_done():
            sys.exit("download never finished")
        time.sleep(5)
        if trig and not wait_frozen():
            sys.exit("ring never froze: the trigger (vector 2..4 read) did not fire")
        ents, probs = read_buffer(tag=f"{game}_{tag}{wtag}")
        print(f"  {tag}: {sum(e is not None for e in ents)}/256 entries, {len(probs)} readout problems")
        for p in probs[:5]:
            print("    ", p)
        result[tag] = ents
    if trig:
        # Ring order -> time order. The trigger entry (the vector read) is
        # the newest, so the entry after it in buffer order is the oldest.
        # Both captures rotate by the ADDRESS capture's trigger position: the
        # data capture cannot see FC, but the two loads are the same boot.
        A = result["fc_addr"]
        hits = [i for i, a in enumerate(A) if is_vector_read(a)]
        if len(hits) != 1:
            print(f"  WARNING: expected one vector read in the ring, found {len(hits)} at {hits}; not rotated")
        else:
            k = hits[0] + 1
            result["fc_addr"] = A[k:] + A[:k]
            print(f"  rotated: trigger was at ring index {hits[0]}; it is now entry 255")
            # The data capture is a separate load whose interrupt timing
            # relative to the boot need not match, so its ring position of
            # the trigger is unknown. Rotate it to best agree with the
            # address capture's low address bytes, and report how well.
            D = result.get("data_addr")
            if D:
                def score(k):
                    return sum(1 for i in range(256)
                               if A[(hits[0] + 1 + i) % 256] is not None and D[(k + i) % 256] is not None
                               and (D[(k + i) % 256] & 0xFF) == (A[(hits[0] + 1 + i) % 256] & 0xFF))
                best = max(range(256), key=score)
                result["data_addr"] = D[best:] + D[:best]
                print(f"  data capture rotated by {best}: low address bytes agree on {score(best)}/256 entries")
    (OUT / f"{game}_boot{wtag}.json").write_text(json.dumps(result))
    print(f"saved {OUT / f'{game}_boot{wtag}.json'}")
    if fc_only:
        summarise(result["fc_addr"], window)


def summarise(A, window):
    """Address-only view of one window: FC histogram, address range, and any
    supervisor-data reads inside the vector table (the exception signature)."""
    from collections import Counter
    fcs = Counter(); lo, hi = None, 0; vec = []
    for i, a in enumerate(A):
        if a is None:
            continue
        fc, wa = a >> 21, a & 0x1FFFFF
        fcs[FC.get(fc, str(fc))] += 1
        lo = wa if lo is None else min(lo, wa); hi = max(hi, wa)
        if fc == 5 and wa < 0x200:
            vec.append((i, 2 * wa))
    base = window * 8191
    print(f"  window {window}: ROM reads {base}..{base + 255}: FC {dict(fcs)}; "
          f"byte addr {2*lo:06X}..{2*hi:06X}")
    if vec:
        print(f"  vector-table reads (entry, byte addr): {vec[:12]}")
    prog = [f"{2*(a & 0x1FFFFF):06X}" for a in A[:24] if a is not None and (a >> 21) == 6]
    print(f"  first program fetches: {' '.join(prog)}")


def rom_words(game):
    zipn, hi, lo = PROG[game]
    with zipfile.ZipFile(REPO / "roms" / f"{zipn}.zip") as z:
        n = {x.split("/")[-1]: x for x in z.namelist()}
        a = z.read(n[hi]); b = z.read(n[lo])
    img = bytearray(len(a) * 2); img[0::2] = a; img[1::2] = b
    return lambda w: struct.unpack(">H", img[2*w:2*w+2])[0] if 2*w + 2 <= len(img) else None


def compare(game, suffix="", tail=0):
    d = json.loads((OUT / f"{game}_boot{suffix}.json").read_text())
    A, D = d["fc_addr"], d["data_addr"]
    W = rom_words(game)
    exp_path = REPO / "debug" / "hw" / f"{game}_expected_fetches.txt"
    expected = [int(l, 16) for l in exp_path.read_text().splitlines()
                if l.strip() and not l.startswith("//")]

    print(f"{game}: first accesses after the ROM loaded (entry, FC, byte addr, data, ROM, note)")
    misalign = 0
    fetches = []
    for i in range(256):
        if A[i] is None:
            continue
        fc, wa = A[i] >> 21, A[i] & 0x1FFFFF
        data = (D[i] >> 8) if D[i] is not None else None
        lo8 = (D[i] & 0xFF) if D[i] is not None else None
        if lo8 is not None and lo8 != (wa & 0xFF):
            misalign += 1
        exp = W(wa)
        note = ""
        if data is not None and exp is not None and data != exp:
            note = "DATA != ROM"
        if fc == 6:
            fetches.append(2 * wa)
        if i < 72 or note or (tail and i >= 256 - tail):
            ds = "----" if data is None else f"{data:04X}"
            es = "----" if exp is None else f"{exp:04X}"
            print(f"  {i:3d}  {FC.get(fc, str(fc)):5s}  {2*wa:06X}  {ds}  {es}  {note}")
    print(f"\n  address/data captures misaligned on {misalign} entries (0 = the two loads line up)")

    # in-order subsequence match against MAME
    j = 0
    for k, f in enumerate(fetches):
        if j < len(expected) and f == expected[j]:
            j += 1
    print(f"  MAME expected fetches matched in order: {j}/{len(expected)}")
    if j < len(expected):
        print(f"  first expected fetch NOT seen: 0x{expected[j]:06X} "
              f"(after matching up to 0x{expected[j-1]:06X})" if j else
              f"  the very first expected fetch 0x{expected[0]:06X} never appeared")
        # show what the hardware did instead, around that point
        seen = [f"{f:06X}" for f in fetches[:40]]
        print(f"  hardware's first program fetches: {' '.join(seen)}")


def hang(game, wait, fc_only=False):
    """Catch a hung CPU: run the game for `wait` seconds, PAUSE the CPU over
    JTAG (probe source bit 5 -> pause_control.ext_pause), and let the trace
    ring freeze on the last 256 ROM reads before the pause -- the loop the
    CPU is spinning in. The ring is not rotated (there is no trigger entry to
    rotate on); a loop reads the same either way."""
    OUT.mkdir(parents=True, exist_ok=True)
    result = {}
    srcs = ((1, "fc_addr"),) if fc_only else ((1, "fc_addr"), (2, "data_addr"))
    for src, tag in srcs:
        subprocess.run([sys.executable, str(CFG), game, "--set", "overlay=1", "ring=1",
                        "trig=0", f"src={src}", "window=0"], capture_output=True, cwd=str(REPO))
        r = subprocess.run([sys.executable, str(HW), "launch", MRA[game]],
                           capture_output=True, text=True, cwd=str(REPO))
        if "launching" not in r.stdout:
            sys.exit(f"launch failed: {r.stdout[-200:]}")
        if not wait_download_done():
            sys.exit("download never finished")
        print(f"  running {wait}s before the pause")
        time.sleep(wait)
        issp("set", 0x20)                      # pause, and hold it
        if not wait_frozen():
            sys.exit("ring never froze after the pause: the CPU is still fetching ROM")
        ents, probs = read_buffer(tag=f"{game}_{tag}_hang")   # ends with set 0 = unpause
        print(f"  {tag}: {sum(e is not None for e in ents)}/256 entries, {len(probs)} readout problems")
        result[tag] = ents
    (OUT / f"{game}_boot_hang.json").write_text(json.dumps(result))
    print(f"saved {OUT / f'{game}_boot_hang.json'}")
    from collections import Counter
    A = result["fc_addr"]
    fcs = Counter(FC.get(a >> 21, str(a >> 21)) for a in A if a is not None)
    addrs = Counter(2 * (a & 0x1FFFFF) for a in A if a is not None and (a >> 21) in (2, 6))
    print(f"  FC: {dict(fcs)}")
    print("  program addresses in the last 256 reads (addr: count):")
    for ad, n in sorted(addrs.items()):
        print(f"    {ad:06X}: {n}")


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("capture", "compare", "hang"))
    ap.add_argument("game", choices=list(MRA))
    ap.add_argument("--window", type=int, nargs="*", default=[0],
                    help="capture: tracer window(s) to record (skip n*8191 ROM reads)")
    ap.add_argument("--fc-only", action="store_true",
                    help="capture: addresses only (one load per window) and summarise")
    ap.add_argument("--trig", action="store_true",
                    help="capture/compare: ring frozen by the first vector 2..4 read")
    ap.add_argument("--tail", type=int, default=0, help="compare: also print the last N entries")
    ap.add_argument("--hang", action="store_true", help="compare: use the --hang capture")
    ap.add_argument("--wait", type=float, default=20, help="hang: seconds to run before pausing")
    a = ap.parse_args()
    if a.cmd == "hang":
        hang(a.game, a.wait, fc_only=a.fc_only)
    elif a.cmd == "compare":
        compare(a.game, suffix="_trig" if a.trig else ("_hang" if a.hang else ""), tail=a.tail)
    else:
        for w in a.window:
            capture(a.game, window=w, fc_only=a.fc_only, trig=a.trig)


if __name__ == "__main__":
    main()
