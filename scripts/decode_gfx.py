#!/usr/bin/env python3
"""Decode Seta graphics tiles from a real ROM set and render them as ASCII.

    python scripts/decode_gfx.py roms/thunderl.zip t17 sprites --member2 t16
    python scripts/decode_gfx.py roms/rezon.zip us001006.u48 tile4 --tiles 0,1,2
    python scripts/decode_gfx.py roms/gundhara.zip bpgh-009.u65 tile6 --tiles 0

Proving the bit layout OFFLINE, before writing the RTL that depends on it.
A wrong gfx layout produces plausible-looking garbage on hardware and is
expensive to diagnose there; here it takes seconds and the answer is visual.

HOW THIS DIFFERS FROM THE FUUKI VERSION
---------------------------------------
Fuuki's copy hand-derived a pixel extractor per format -- fast, but each one
had to be reasoned out from a gfx_layout, and reasoning is exactly what
LESSONS_LEARNED says produces confident wrong answers about byte order. Seta's
formats are more awkward than Fuuki's (planes interleaved inside a word,
x-offsets that jump in 128-bit strides, and RGN_FRAC halves for sprites), so
this version instead implements MAME's gfx_layout semantics DIRECTLY and the
layouts below are transcribed, not derived.

The two MAME conventions that matter, and are easy to get backwards:
  * A "bit offset" N addresses bit (7 - N%8) of byte N//8 -- MSB first.
  * planeoffset[0] is the MOST significant bit of the pixel value.

Layouts transcribed from src/mame/seta/seta.cpp:

  layout_tilemap        "tile4"    4bpp 16x16, 128 bytes/tile
  layout_tilemap_6bpp   "tile6"    6bpp 16x16, 192 bytes/tile
  layout_tilemap_8bpp   "tile8"    8bpp 16x16, 256 bytes/tile (setaroul only,
                                   out of scope -- kept because it costs a line)
  layout_sprites        "sprites"  4bpp 16x16, RGN_FRAC(1,2), 64 bytes/half

RGN_FRAC: the sprite layout splits the region in half and takes two planes
from each. Pass both ROMs (--member2) or one already-concatenated image; the
split is computed from the total length, exactly as MAME does.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from romset import RomSet

SHADE = " .:-=+*#%@"


def STEP(n, start, step):
    return [start + i * step for i in range(n)]


# name -> dict(width, height, planes, planeoffset, xoffset, yoffset, charinc)
# charinc and every offset are in BITS, as in MAME.
# RGN_FRAC(1,2) is written as the string "H" and resolved against the region
# length at decode time.
LAYOUTS = {
    # static const gfx_layout layout_tilemap
    #   4, { STEP4(0,4) },
    #   { STEP4(4*4*8*3,1), STEP4(4*4*8*2,1), STEP4(4*4*8,1), STEP4(0,1) },
    #   { STEP8(0,4*4), STEP8(4*4*8*4,4*4) }, 16*16*4
    "tile4": dict(
        w=16, h=16, planes=4,
        planeoffset=STEP(4, 0, 4),
        xoffset=STEP(4, 4 * 4 * 8 * 3, 1) + STEP(4, 4 * 4 * 8 * 2, 1)
                + STEP(4, 4 * 4 * 8, 1) + STEP(4, 0, 1),
        yoffset=STEP(8, 0, 4 * 4) + STEP(8, 4 * 4 * 8 * 4, 4 * 4),
        charinc=16 * 16 * 4),

    # static const gfx_layout layout_tilemap_6bpp
    #   6, { STEP4(0,4), STEP2(4*4,4) },
    #   { STEP4(6*4*8*3,1), STEP4(6*4*8*2,1), STEP4(6*4*8,1), STEP4(0,1) },
    #   { STEP8(0,6*4), STEP8(6*4*8*4,6*4) }, 16*16*6
    "tile6": dict(
        w=16, h=16, planes=6,
        planeoffset=STEP(4, 0, 4) + STEP(2, 4 * 4, 4),
        xoffset=STEP(4, 6 * 4 * 8 * 3, 1) + STEP(4, 6 * 4 * 8 * 2, 1)
                + STEP(4, 6 * 4 * 8, 1) + STEP(4, 0, 1),
        yoffset=STEP(8, 0, 6 * 4) + STEP(8, 6 * 4 * 8 * 4, 6 * 4),
        charinc=16 * 16 * 6),

    # static const gfx_layout layout_tilemap_8bpp
    "tile8": dict(
        w=16, h=16, planes=8,
        planeoffset=STEP(8, 0, 4),
        xoffset=STEP(4, 8 * 4 * 8 * 3, 1) + STEP(4, 8 * 4 * 8 * 2, 1)
                + STEP(4, 8 * 4 * 8, 1) + STEP(4, 0, 1),
        yoffset=STEP(8, 0, 8 * 4) + STEP(8, 8 * 4 * 8 * 4, 8 * 4),
        charinc=16 * 16 * 8),

    # static const gfx_layout layout_sprites
    #   RGN_FRAC(1,2), 4, { RGN_FRAC(1,2)+8, RGN_FRAC(1,2)+0, 8, 0 },
    #   { STEP8(0,1), STEP8(8*2*8,1) },
    #   { STEP8(0,8*2), STEP8(8*2*8*2,8*2) }, 16*16*2
    "sprites": dict(
        w=16, h=16, planes=4,
        planeoffset=["H+8", "H+0", 8, 0],
        xoffset=STEP(8, 0, 1) + STEP(8, 8 * 2 * 8, 1),
        yoffset=STEP(8, 0, 8 * 2) + STEP(8, 8 * 2 * 8 * 2, 8 * 2),
        charinc=16 * 16 * 2),
}


def resolve_planes(planeoffset, region_bits):
    """Turn RGN_FRAC(1,2) markers into absolute bit offsets."""
    half = region_bits // 2
    out = []
    for p in planeoffset:
        if isinstance(p, str):
            out.append(half + int(p.split("+")[1]))
        else:
            out.append(p)
    return out


def bit(data, offset):
    """MAME bit addressing: offset N is bit (7 - N%8) of byte N//8."""
    byte = offset >> 3
    if byte >= len(data):
        return 0
    return (data[byte] >> (7 - (offset & 7))) & 1


def decode_tile(data, lay, index, region_bits):
    planeoffset = resolve_planes(lay["planeoffset"], region_bits)
    nplanes = lay["planes"]
    base = index * lay["charinc"]
    rows = []
    for y in range(lay["h"]):
        row = []
        for x in range(lay["w"]):
            here = base + lay["yoffset"][y] + lay["xoffset"][x]
            v = 0
            # planeoffset[0] is the MOST significant bit of the pixel.
            for p in range(nplanes):
                v = (v << 1) | bit(data, here + planeoffset[p])
            row.append(v)
        rows.append(row)
    return rows


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
    ap.add_argument("--member2", help=(
        "second ROM. For `sprites` this is the OTHER HALF of the region: "
        "MAME's RGN_FRAC(1,2) takes two planes from each half, so both are "
        "needed to see a tile at all. For a ROM_LOAD16_BYTE pair use "
        "--interleave byte."))
    ap.add_argument("--tiles", default="0,1,2,3")
    ap.add_argument("--interleave", choices=["none", "concat", "byte", "word_swap", "24"],
                    default="concat",
                    help="how `member` and `member2` combine. concat (default) "
                         "= member then member2, which is what a plain "
                         "ROM_LOAD pair at consecutive offsets gives. byte = "
                         "ROM_LOAD16_BYTE, member at even addresses. "
                         "word_swap = byte-swap each word of the result "
                         "(ROM_LOAD16_WORD_SWAP).")
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
            # ROM_LOAD16_BYTE: member supplies even addresses, member2 odd.
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
    if a.kind == "sprites" and not a.member2:
        print("WARNING: `sprites` is RGN_FRAC(1,2) -- two of the four planes "
              "come from the second half of the region. With one ROM the top "
              "two planes read as zero and every pixel is 0-3.\n",
              file=sys.stderr)

    maxval = (1 << lay["planes"]) - 1
    for t in [int(x, 0) for x in a.tiles.split(",")]:
        if (t + 1) * lay["charinc"] > region_bits:
            sys.exit(f"tile {t} is past the end of {len(data)} bytes of data")
        rows = decode_tile(data, lay, t, region_bits)
        hist = {}
        for r in rows:
            for v in r:
                hist[v] = hist.get(v, 0) + 1
        nz = sum(v for k, v in hist.items() if k != 0)
        print(f"--- tile {t} ({a.kind}) non-zero px {nz}/{sum(hist.values())}, "
              f"{len(hist)} distinct values ---")
        for r in rows:
            print("  " + "".join(
                SHADE[min(len(SHADE) - 1, v * len(SHADE) // (maxval + 1))] * 2
                for v in r))


if __name__ == "__main__":
    main()
