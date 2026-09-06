#!/usr/bin/env python3
"""Check a MAME boot trace against the program image built offline.

    python scripts/mame_capture.py thunderl --boot-trace 400 --name tl-boot
    python scripts/check_boot_trace.py thunderl debug/tl-boot/thunderl_boot.trace

Two independent paths to the same bytes:

  * `build_maincpu_hex.py` assembles the image from the driver's ROM_START
    records (extracted by `extract_romstart.py`, resolved by CRC through
    `romset.py`);
  * MAME loads the ROMs with its own loader and its own CPU fetches them.

They share no code. If every word MAME's CPU read from inside the program
region equals the same address in our image, the interleave is right --
which is the check LESSONS_LEARNED's "Prove the interleave against MAME's
disassembly offline, before building" is really asking for, done mechanically
rather than by eye over a handful of instructions.

WHAT THIS DOES NOT PROVE
------------------------
LESSONS_LEARNED, "A hardware-vs-image comparison cannot detect a wrong image":
that entry is about comparing two things built from the SAME assumption. This
is not that -- MAME's loader is independent of ours -- but the caution still
bounds the claim. It shows the two agree on the addresses MAME happened to
read during the traced window. It says nothing about regions the boot never
touches, and nothing at all about the graphics or sound ROMs.
"""
import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)      # the __main__ guard keeps main() from running
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("trace", help="the *_boot.trace from --boot-trace")
    ap.add_argument("--zip", help="ROM archive. Default: roms/<parent>.zip, "
                                  "found by searching roms/ for the set")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    bm = _load("build_maincpu_hex", HERE / "build_maincpu_hex.py")
    if a.set not in bm.SETS:
        sys.exit(f"no ROM_START records for '{a.set}'. Add it with "
                 f"scripts/extract_romstart.py --emit")

    zippath = a.zip
    if not zippath:
        import zipfile
        roms = HERE.parent / "roms"
        for z in sorted(roms.glob("*.zip")):
            names = zipfile.ZipFile(z).namelist()
            if z.stem == a.set or any(n.startswith(a.set + "/") for n in names):
                zippath = str(z)
                break
        if not zippath:
            sys.exit(f"no archive in {roms} holds set '{a.set}'")

    img = bm.build(zippath, bm.SETS[a.set], a.set)

    rows = [l.rstrip("\n").split("\t")
            for l in open(a.trace, encoding="utf8")
            if l.strip() and not l.startswith("#")]
    if not rows:
        sys.exit(f"{a.trace} has no access records")

    checked = mismatch = skipped = 0
    first_bad = None
    for seq, rw, addr, data in rows:
        addr_i, data_i = int(addr, 16), int(data, 16)
        if rw != "r" or addr_i + 1 >= len(img):
            skipped += 1
            continue
        want = int.from_bytes(img[addr_i:addr_i + 2], "big")
        checked += 1
        if want != data_i:
            mismatch += 1
            if first_bad is None:
                first_bad = (seq, addr, data_i, want)
            if a.verbose:
                print(f"  seq {seq:>5} @ {addr}  MAME {data_i:04X}  image {want:04X}")

    print(f"{a.set}: image {len(img):#x} bytes from {zippath}")
    print(f"  {len(rows)} accesses in the trace")
    print(f"  {checked} reads inside the image: {checked - mismatch} match, "
          f"{mismatch} differ")
    print(f"  {skipped} skipped (writes, or outside the image)")

    if checked == 0:
        sys.exit("nothing was comparable -- wrong set, or a trace from a "
                 "different game")
    if mismatch:
        seq, addr, got, want = first_bad
        sys.exit(f"\nFAIL: first divergence at trace seq {seq}, address {addr}: "
                 f"MAME fetched {got:04X}, our image holds {want:04X}. "
                 f"The interleave for '{a.set}' is wrong.")
    print("\nPASS: every word MAME's CPU fetched from the program region equals "
          "the image built offline from ROM_START.")


if __name__ == "__main__":
    main()
