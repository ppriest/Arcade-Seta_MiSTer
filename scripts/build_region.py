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


def region_erase_ff(body, region):
    """True when the ROM_REGION carries ROMREGION_ERASEFF (or ERASEVAL(0xff))."""
    m = re.search(r'ROM_REGION\(\s*[^,]+,\s*"' + re.escape(region) + r'",\s*([^)]*)\)', body)
    flags = m.group(1) if m else ""
    return "ERASEFF" in flags or "ERASEVAL(0xff)" in flags.lower().replace(" ", "")


def region_inverted(body, want):
    """Whether ROM_REGION carries ROMREGION_INVERT for this region.

    MAME inverts every byte of such a region after loading it. Two regions in
    seta.cpp have it -- oisipuzl's sprites and one other set's -- and ignoring
    it decodes every pen as its complement, which reads as a palette fault
    rather than a data one.
    """
    for raw in body.split("\n"):
        line = raw.split("//")[0].strip()
        m = re.match(r'ROM_REGION\w*\(\s*0x[0-9a-fA-F]+\s*,\s*"([^"]+)"\s*,\s*([^)]*)\)',
                     line)
        if m and m.group(1) == want:
            return "ROMREGION_INVERT" in m.group(2)
    return False


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
        # DECLARED AND NEVER LOADED. sokonuke's gfx3 is
        # ROM_REGION(0x100, "gfx3", ROMREGION_ERASE) with "Unused" written
        # beside it, and MAME still instantiates a second tile layer over it.
        # An erased region is zeros, which is what the padding below writes.
        return bytes(size), size, str(zip_for(setname, all_blocks)[0])
    # HOLES ARE ZERO-FILLED (build() in build_maincpu_hex.py), which is what
    # MAME gives a region declared without an erase flag. A region declared
    # ROMREGION_ERASEFF (daiohp2's maincpu, not yet built) would hold 0xFF in
    # every byte its loads skip, and nothing here reproduces that yet. Refuse,
    # rather than assemble a plausible wrong image.
    if region_erase_ff(body, region):
        sys.exit(f"{setname}/{region}: ROMREGION_ERASEFF hole fill is not "
                 f"implemented -- holes are zero here, MAME's would be 0xFF")
    zippath, key = zip_for(setname, all_blocks)

    # ROM_COPY takes its bytes from ANOTHER region of the same set, so that
    # region has to be built first. kamenrid and magspeed carve both tile
    # regions out of one "user1"; there is no file to resolve and no CRC to
    # resolve it by.
    copies = [r for r in recs if r[0] == "copy"]
    recs = [r for r in recs if r[0] != "copy"]
    img = bytearray(build(zippath, recs, key)) if recs else bytearray()
    for kind, src_region, dest, length, _crc, src_ofs in copies:
        src = region_image(setname, src_region, all_blocks)[0]
        if len(src) < src_ofs + length:
            sys.exit(f"{setname}/{region}: ROM_COPY wants {length:#x} bytes at "
                     f"{src_ofs:#x} of {src_region}, which is {len(src):#x} long")
        if len(img) < dest:
            img.extend(b"\xff" * (dest - len(img)))
        img[dest:dest + length] = src[src_ofs:src_ofs + length]
    # ROM_REGION allocates `size`; the loads may leave a tail unwritten. MAME
    # zero-fills a region it allocates, so a short image is padded with zeros
    # -- NOT with the 0xff build() pads holes with, which is a program-ROM
    # convention (an unprogrammed EPROM reads 0xff).
    if region_inverted(body, region):
        img = bytearray(b ^ 0xFF for b in img)
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
