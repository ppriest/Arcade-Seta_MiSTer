#!/usr/bin/env python3
"""Diff an SDRAM read-back dump (trace source 3 screenshot) against the ROM.

    python scripts/sdram_dump_check.py debug/hw/dump_p0.png pbancho 0
    python scripts/sdram_dump_check.py debug/hw/dump_p0.png pbancho 0 --also debug/hw/dump_p0b.png

The walker in rtl/fuuki_core.sv reads 256 consecutive words of the program
ROM region through the CPU's own path and the tracer shows them one per
scanline as {word index, data}. This decodes the screenshot, re-orders by the
index it carries (so a rotated ring or a torn row cannot mis-attribute a
word), and compares each word with the program image built exactly as
scripts/build_mra.py builds it.

WHAT THE SHAPE OF THE ERRORS MEANS
  * no mismatches            what the CPU sees IS the ROM; look elsewhere
  * a consistent permutation the image is laid out wrong: interleave / map
  * scattered, and DIFFERENT between two dumps of the same page
                             the READ PATH is unreliable -- SDRAM timing /
                             clock phase -- not the image

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs the SDRAM read-back walker (trace source 3), which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import argparse
import re
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

# Program-ROM parts per set, in the order build_mra.py's ground truth uses.
PROGRAM = {
    "gogomile":  ("gogomile", "load16_byte", ["fp2n.rom2", "fp1n.rom1"]),
    "gogomileo": ("gogomileo", "load16_byte", ["fp2.rom2", "fp1.rom1"]),
    "pbancho":   ("pbancho", "load16_byte", ["no1..rom2", "no2..rom1"]),
    "pbanchoa":  ("pbanchoa", "load16_byte", ["no1.rom2", "no2.rom1"]),
}


def program_image(setname):
    zipn, kind, parts = PROGRAM[setname]
    zp = REPO / "roms" / f"{zipn}.zip"
    if not zp.exists():
        zp = REPO / "roms" / f"{PROGRAM[setname][0]}.zip"
    with zipfile.ZipFile(zp) as z:
        names = {n.split("/")[-1]: n for n in z.namelist()}
        a = z.read(names[parts[0]]); b = z.read(names[parts[1]])
    img = bytearray(len(a) * 2); img[0::2] = a; img[1::2] = b
    return img


def decode(png):
    out = subprocess.run([sys.executable, str(REPO / "scripts" / "decode_debug_screenshot.py"),
                          str(png), "--mode", "scanline", "--limit", "240"],
                         capture_output=True, text=True).stdout
    vals = [int(m.group(1), 16) for l in out.splitlines()
            for m in [re.match(r"\s*\d+\s+0x([0-9A-Fa-f]+)", l)] if m]
    by_idx = {}
    for v in vals:
        by_idx.setdefault(v >> 16, v & 0xFFFF)   # first sighting wins
    return by_idx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("png"); ap.add_argument("setname"); ap.add_argument("page", type=lambda x: int(x, 0))
    ap.add_argument("--also", help="a second dump of the SAME page, to test consistency")
    a = ap.parse_args()

    img = program_image(a.setname)
    base = a.page * 256
    got = decode(a.png)
    print(f"{a.png}: {len(got)} of 256 words recovered for page {a.page} "
          f"(words 0x{base:X}-0x{base+255:X}, bytes 0x{2*base:X}-0x{2*base+511:X})")
    bad = []
    for i in range(256):
        exp = struct.unpack(">H", img[2*(base+i):2*(base+i)+2])[0]
        if i in got and got[i] != exp:
            bad.append((base + i, got[i], exp))
    if not bad:
        print("  NO MISMATCHES against the ROM image -- what the CPU sees is the ROM.")
    else:
        print(f"  {len(bad)} mismatches:")
        for w, g, e in bad[:40]:
            print(f"    word 0x{w:05X} (byte 0x{2*w:06X}): got {g:04X} expected {e:04X}"
                  f"   xor {g^e:04X}")
        if len(bad) > 40: print(f"    ... {len(bad)-40} more")

    if a.also:
        got2 = decode(a.also)
        differ = [i for i in range(256) if i in got and i in got2 and got[i] != got2[i]]
        print(f"\n{a.also}: same page dumped again -- {len(differ)} words differ between "
              f"the two dumps")
        if differ:
            print("  -> the read path is not deterministic: timing / clock phase, not the image")
            for i in differ[:12]:
                print(f"    word 0x{base+i:05X}: {got[i]:04X} vs {got2[i]:04X}")
        elif bad:
            print("  -> consistent between dumps: a static layout error (interleave / map)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
