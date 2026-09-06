#!/usr/bin/env python3
"""Render Seta graphics ROM tiles to a PNG tile sheet.

    python scripts/gfx_sheet.py roms/rezon.zip us001007.u66 tile4 \
        --interleave word_swap --count 256 -o debug/rezon_l1.png

Companion to scripts/decode_gfx.py, which prints ASCII. This one produces an
image, which is a far better way to judge whether a layout is right across
hundreds of tiles at once.

THE LAYOUTS ARE NOT DEFINED HERE. They are imported from decode_gfx.py, so the
two tools cannot drift apart. Fuuki's pair each carried their own copy of the
pixel extractors, which is the same duplication hazard as a probe field table
that gets out of step with the probe.

IMPORTANT -- these are NOT the game's real colours. On this hardware the
palette lives in RAM (0x700400 on most boards) and is written by the game at
runtime; it is not in the ROM. What is in the ROM is a PEN INDEX per pixel. So
this renders pen index as false colour (a fixed hue ramp) and draws pen 0 --
the transparent pen for both the X1-012 tilemaps (set_transparent_pen(0)) and
the X1-001 sprites (m_transpen defaults to 0) -- as a grey checkerboard.
"""
import argparse
import colorsys
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from decode_gfx import LAYOUTS, decode_tile   # one definition, shared
from romset import RomSet


def false_colour(nplanes):
    """Pen index -> RGB. A hue ramp, so adjacent pens are clearly different."""
    n = 1 << nplanes
    out = []
    for v in range(n):
        h = (v * 0.61803398875) % 1.0          # golden ratio: no near-duplicates
        s = 0.65 if v else 0.0
        l = 0.25 + 0.55 * (v / (n - 1))
        r, g, b = colorsys.hls_to_rgb(h, l, s)
        out.append((int(r * 255), int(g * 255), int(b * 255)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("zip")
    ap.add_argument("member")
    ap.add_argument("kind", choices=sorted(LAYOUTS))
    ap.add_argument("--set", help=(
        "MAME set name, when reading a CLONE out of a merged parent zip. "
        "roms/ is merged, and two archives hold different dumps under the "
        "same basename in different clone directories -- see romset.py. "
        "Default: the zip's stem, i.e. the parent."))
    ap.add_argument("--member2", help="second ROM (see decode_gfx.py)")
    ap.add_argument("--interleave", choices=["none", "concat", "byte", "word_swap", "24"],
                    default="concat")
    ap.add_argument("--first", type=int, default=0)
    ap.add_argument("--count", type=int, default=256)
    ap.add_argument("--across", type=int, default=16)
    ap.add_argument("--scale", type=int, default=2)
    ap.add_argument("-o", "--out", default="gfx_sheet.png")
    a = ap.parse_args()

    rs = RomSet(a.zip, a.set)
    try:
        data = bytearray(rs.read(a.member))
        d2 = bytearray(rs.read(a.member2)) if a.member2 else None
    except KeyError as e:
        sys.exit(str(e))
    if a.member2:
        if a.interleave == "24":
            # The 6bpp layers. seta.cpp defines these locally (line ~9176):
            #   ROM_LOAD24_BYTE      = ROMX_LOAD(..., ROM_SKIP(2))
            #   ROM_LOAD24_WORD_SWAP = ROMX_LOAD(..., GROUPWORD|REVERSE|SKIP(1))
            # loaded at 0x000000 and 0x000001, so the region is 3-byte groups:
            #   dest[3g]   = byte_rom[g]                  (member)
            #   dest[3g+1] = word_rom[2g+1]               (member2, byte-swapped)
            #   dest[3g+2] = word_rom[2g]
            n = len(data)
            if len(d2) != 2 * n:
                sys.exit(f"24-bit interleave wants member2 to be exactly twice "
                         f"member: {n:#x} vs {len(d2):#x}")
            out = bytearray(3 * n)
            out[0::3] = data
            out[1::3] = d2[1::2]
            out[2::3] = d2[0::2]
            data = out
        elif a.interleave == "byte":
            out = bytearray(len(data) + len(d2))
            out[0::2] = data
            out[1::2] = d2
            data = out
        else:
            data = data + d2
    if a.interleave == "word_swap":
        for i in range(0, len(data) - 1, 2):
            data[i], data[i + 1] = data[i + 1], data[i]

    lay = LAYOUTS[a.kind]
    region_bits = len(data) * 8
    total = region_bits // lay["charinc"]
    count = min(a.count, max(0, total - a.first))
    if count <= 0:
        sys.exit(f"no tiles: {a.kind} holds {total} tiles, --first is {a.first}")
    if a.kind == "sprites" and not a.member2:
        print("WARNING: `sprites` is RGN_FRAC(1,2) -- with one ROM the top two "
              "planes read as zero and every pen is 0-3.", file=sys.stderr)

    pal = false_colour(lay["planes"])
    w, h = lay["w"], lay["h"]
    across = a.across
    down = (count + across - 1) // across
    img = Image.new("RGB", (across * w, down * h))
    px = img.load()
    for i in range(count):
        rows = decode_tile(data, lay, a.first + i, region_bits)
        ox, oy = (i % across) * w, (i // across) * h
        for y, row in enumerate(rows):
            for x, v in enumerate(row):
                if v == 0:
                    # transparent pen -> checkerboard, so "empty" is not
                    # confused with "a dark colour"
                    c = 0x50 if ((x >> 2) ^ (y >> 2)) & 1 else 0x38
                    px[ox + x, oy + y] = (c, c, c)
                else:
                    px[ox + x, oy + y] = pal[v]
    if a.scale > 1:
        img = img.resize((img.width * a.scale, img.height * a.scale), Image.NEAREST)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    img.save(a.out)
    print(f"{a.out}: {count} tiles of {a.kind} ({total} in the region), "
          f"{img.width}x{img.height}")


if __name__ == "__main__":
    main()
