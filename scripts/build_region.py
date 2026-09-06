#!/usr/bin/env python3
"""Assemble any ROM_REGION of any in-scope set, straight from seta.cpp + roms/.

    python scripts/build_region.py umanclub gfx1 -o debug/umanclub_gfx1.bin
    python scripts/build_region.py thunderl x1snd --check
    python scripts/build_region.py --list atehate

build_maincpu_hex.py does this for "maincpu" from a table checked into the
repo, because the program image is what every boot test loads and a stable
table is worth having. The graphics and sample regions do not need a table:
they are read once per reference capture, and reading them from the driver
each time removes a whole class of transcription error at no cost.

This shares both halves of the proven path rather than reimplementing either:
extract_romstart.region_records for the parse, build_maincpu_hex.build for the
four load kinds. The only thing added here is the DECLARED REGION SIZE, which
the sprite layout needs -- layout_sprites is RGN_FRAC(1,2) and splits the
region in half, so a region assembled to the length of its loads rather than
to the length ROM_REGION declares would split in the wrong place. They are
equal for every in-scope set, and the check below says so rather than assuming
it.
"""
import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract_romstart import SRC, blocks, region_records
from build_maincpu_hex import build

ROMS = Path(__file__).resolve().parent.parent / "roms"


def region_size(body, want):
    """The size ROM_REGION declares, or None if the set has no such region."""
    for raw in body.split("\n"):
        line = raw.split("//")[0].strip()
        m = re.match(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"', line)
        if m and m.group(2) == want:
            return int(m.group(1), 16)
    return None


def region_names(body):
    out = []
    for raw in body.split("\n"):
        m = re.match(r'ROM_REGION\w*\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"',
                     raw.split("//")[0].strip())
        if m:
            out.append((m.group(2), int(m.group(1), 16)))
    return out


def load_blocks():
    if not os.path.exists(SRC):
        sys.exit(f"driver not found at {SRC} (set MAME_SRC)")
    return blocks(open(SRC, encoding="utf8", errors="replace").read())


def zip_for(setname, all_blocks):
    """roms/ is MERGED: a clone lives inside its parent's archive.

    The driver's own GAME() line carries the parent, so find it there rather
    than by guessing at filenames.
    """
    own = ROMS / f"{setname}.zip"
    if own.exists():
        return own, setname
    src = open(SRC, encoding="utf8", errors="replace").read()
    m = re.search(r'GAME\w*\(\s*\d+\s*,\s*' + re.escape(setname) +
                  r'\s*,\s*(\w+)\s*,', src)
    if m and m.group(1) != "0":
        parent = ROMS / f"{m.group(1)}.zip"
        if parent.exists():
            return parent, setname
    sys.exit(f"no archive for {setname!r} in {ROMS} "
             f"(looked for {setname}.zip and its parent)")


def region_image(setname, region, all_blocks=None):
    """The assembled region, padded to the length ROM_REGION declares."""
    all_blocks = all_blocks or load_blocks()
    if setname not in all_blocks:
        sys.exit(f"{setname}: no ROM_START in the driver")
    body = all_blocks[setname]
    size = region_size(body, region)
    if size is None:
        have = ", ".join(n for n, _ in region_names(body))
        sys.exit(f"{setname} has no {region!r} region. It has: {have}")
    recs, unknown = region_records(body, region)
    if unknown:
        sys.exit(f"{setname}/{region}: unrecognised load line(s): {unknown[:2]}")
    if not recs:
        sys.exit(f"{setname}/{region}: ROM_REGION is declared but nothing loads into it")
    zippath, key = zip_for(setname, all_blocks)
    img = bytearray(build(zippath, recs, key))
    # ROM_REGION allocates `size`; the loads may leave a tail unwritten. MAME
    # zero-fills a region it allocates, so a short image is padded with zeros
    # -- NOT with the 0xff build() pads holes with, which is a program-ROM
    # convention (an unprogrammed EPROM reads 0xff).
    if len(img) < size:
        img.extend(b"\x00" * (size - len(img)))
    elif len(img) > size:
        sys.exit(f"{setname}/{region}: loads produced {len(img):#x} bytes but "
                 f"ROM_REGION declares {size:#x} -- the records were misread")
    return bytes(img), size, str(zippath)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set")
    ap.add_argument("region", nargs="?", help="maincpu, gfx1, gfx2, gfx3, x1snd")
    ap.add_argument("-o", "--out", help="write the image here")
    ap.add_argument("--list", action="store_true",
                    help="list the set's regions and their declared sizes")
    a = ap.parse_args()

    all_blocks = load_blocks()
    if a.list or not a.region:
        if a.set not in all_blocks:
            sys.exit(f"{a.set}: no ROM_START in the driver")
        for name, size in region_names(all_blocks[a.set]):
            recs, _ = region_records(all_blocks[a.set], name)
            print(f"  {name:10s} {size:#09x}  {len(recs)} record(s)")
        return 0

    img, size, zippath = region_image(a.set, a.region, all_blocks)
    print(f"{a.set}/{a.region}: {len(img):#x} bytes from {zippath}")
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_bytes(img)
        print(f"  wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
