#!/usr/bin/env python3
"""Check SDRAM read data on the running core against the ROM image, over JTAG.

    python scripts/sdram_check.py gundhara            # launch, then 24 samples
    python scripts/sdram_check.py gundhara --no-launch --samples 48

Probe B on the Seta_stp revision records the last gfx2 granule the layer-0
tile engine consumed, with its 64 bits of data. This launches the game (unless
told not to), lets the engine run, then repeatedly reads that pair and compares
the data against the region assembled by scripts/build_region.py from the ROM
zip. Every mismatch is reported with the XOR and the bit positions, and a
histogram of bad bits is printed at the end.

WHY ONLY THE LOW 32 BITS ARE COMPARED. The 64-bit field is read over JTAG in
two halves and the engine keeps fetching in between, so on a busy layer the
upper words can belong to the NEXT granule. Measured: on a build that renders
gundhara perfectly, words 2-3 disagreed with the ROM in 19 of 24 samples while
words 0-1 agreed in 24 of 24. Words 0-1 are coherent with the address; use
those.

WHAT A CLEAN RESULT LOOKS LIKE: diffs 0. What the regression that motivated
this looked like: bit 8 set in word 0 in roughly half the samples, never any
other bit, across every granule address -- the first beat of every SDRAM read
burst with one data line wrong.

A layer-0 gfx2 region is what probe B exposes, so the game must have a layer 0
(Group B and later). gundhara is the usual choice because it is the set that
runs on every build so far.
"""
import argparse
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

TITLES = {
    "gundhara": "Gundhara",
    "zingzip":  "Zing Zing Zip (World) - Zhen Zhen Ji Pao (China)",
    "jjsquawk": "J. J. Squawkers",
    "rezon":    "Rezon",
}


def probe_b():
    p = subprocess.run(["quartus_stp", "-t", "scripts/read_issp.tcl", "B"],
                       cwd=REPO, capture_output=True, text=True)
    d = dict(re.findall(r"^\s+(\w+)\s+(\S+)\s*$", p.stdout, re.M))
    return int(d["l0_gran_addr"], 16), int(d["l0_gran_data"], 16)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--samples", type=int, default=24)
    ap.add_argument("--no-launch", action="store_true")
    ap.add_argument("--settle", type=int, default=45)
    a = ap.parse_args()

    out = REPO / "debug" / "hw" / f"{a.game}_gfx2.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    if not out.exists():
        subprocess.run([sys.executable, "scripts/build_region.py", a.game, "gfx2",
                        "-o", str(out)], cwd=REPO, check=True, capture_output=True)
    img = out.read_bytes()

    if not a.no_launch:
        subprocess.run([sys.executable, "scripts/hw.py", "launch",
                        TITLES.get(a.game, a.game)], cwd=REPO, capture_output=True)
        time.sleep(a.settle)

    diffs, bits, addrs = 0, Counter(), []
    for _ in range(a.samples):
        g, got = probe_b()
        got &= 0xFFFFFFFF
        want = int.from_bytes(img[g * 8:g * 8 + 4], "little")
        addrs.append(g)
        if got != want:
            diffs += 1
            x = got ^ want
            bits.update(i for i in range(32) if (x >> i) & 1)
            print(f"  granule {g:06X}  hw={got:08X}  rom={want:08X}  xor={x:08X}")
    print(f"{a.game}: {a.samples} samples, {diffs} diffs, bad bits {dict(bits)}")
    print("granules:", " ".join(f"{g:X}" for g in addrs))
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
