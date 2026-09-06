#!/usr/bin/env python3
"""Build tb_tilemap's inputs from a captured MAME frame plus the ROM set.

    python scripts/prep_tilemap_tb.py debug/gogomile-title

Produces, in sim/tilemap_tb/:
    vram.bin        the captured tilemap VRAM, verbatim
    l{0,1,2}_gfx.bin  each layer's tile ROM, assembled exactly as the SDRAM
                    image will hold it (interleave applied, byte order fixed)
    config.txt      scroll and layer settings decoded from the captured vregs
    palette.bin     the captured palette, for turning indices back into pixels

The point is to render the SAME state MAME rendered and compare against the
screenshot it produced. Building the gfx images here rather than in the
testbench keeps the interleave in one place -- the same place decode_gfx.py and
the .mra generator will use -- so there is one definition of "the SDRAM image"
rather than three that can drift.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs sim/tilemap_tb/, and Seta tile formats, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import struct, sys, zipfile
from pathlib import Path

# Per layer: the region size, and the groups that fill it. Each group is
# (destination offset, kind, parts):
#   "swap16"  one ROM_LOAD16_WORD_SWAP
#   "pair32"  a ROM_LOAD32_WORD_SWAP pair, first part supplying bytes 0,1 of
#             each long -- which is the pixel's HIGH nibble
#
# Transcribed from each ROM_START, and the offsets matter: gogomile's layer 1
# is an 8 MB region built from FOUR ROMs as two pairs, at 0x000000 and
# 0x400000. Building only the first pair leaves every tile in the upper half
# reading whatever the gap contains -- which rendered as a solid block rather
# than failing, and is exactly the sort of thing only a picture catches.
GOGOMILE = {
    0: (0x200000, [(0x000000, "swap16", ["lh5370h6.rom3"])]),
    1: (0x800000, [(0x000000, "pair32", ["lh5370h7.rom15", "lh5370h8.rom11"]),
                   (0x400000, "pair32", ["lh5370h9.rom16", "lh5370ha.rom12"])]),
    2: (0x200000, [(0x000000, "swap16", ["lh5370hb.rom19"])]),
    # Sprites, stored under key "s". 16x16x4 on both boards.
    "s": (0x200000, [(0x000000, "swap16", ["lh537k2r.rom20"])]),
}
PBANCHO = {
    0: (0x200000, [(0x000000, "swap16", ["60.rom3"])]),
    1: (0x400000, [(0x000000, "pair32", ["59.rom15", "61.rom11"])]),
    # MAME loads 60.rom3 here too, commented "?maybe?" -- see ROADMAP open item.
    2: (0x200000, [(0x000000, "swap16", ["60.rom3"])]),
    "s": (0x200000, [(0x000000, "swap16", ["58.rom20"])]),
}
# FG-3. Note the pair ordering: bg1113 sits at ROM_START offset 0 and bg1012 at
# offset 2, so bg1113 supplies each pixel's HIGH nibble -- the reverse of how the
# names sort, which is exactly the sort of thing to take from ROM_START rather
# than from filenames.
#
# Sprites are a 32 MB region of eight 4 MB ROMs on 4 MB boundaries. asurabld
# leaves the FIRST one empty (sp01 is absent), so its sprite data starts at
# 0x400000 -- a hole a generator assuming dense packing would silently close,
# shifting every tile code in the set.
ASURABLD = {
    0: (0x800000, [(0x000000, "pair32", ["bg1113.u23", "bg1012.u22"])]),
    1: (0x800000, [(0x000000, "pair32", ["bg2123.u24", "bg2022.u25"])]),
    2: (0x200000, [(0x000000, "swap16", ["map.u5"])]),
    "s": (0x2000000, [(0x0400000, "swap16", ["sp23.u14"]),
                      (0x0800000, "swap16", ["sp45.u15"]),
                      (0x0c00000, "swap16", ["sp67.u16"]),
                      (0x1000000, "swap16", ["sp89.u17"]),
                      (0x1400000, "swap16", ["spab.u18"]),
                      (0x1800000, "swap16", ["spcd.u19"])]),
}
ASURABUS = {
    0: (0x800000, [(0x000000, "pair32", ["bg1113.u23", "bg1012.u22"])]),
    1: (0x800000, [(0x000000, "pair32", ["bg2123.u24", "bg2022.u25"])]),
    2: (0x200000, [(0x000000, "swap16", ["map.u5"])]),
    "s": (0x2000000, [(0x0000000, "swap16", ["sp01.u13"]),
                      (0x0400000, "swap16", ["sp23.u14"]),
                      (0x0800000, "swap16", ["sp45.u15"]),
                      (0x0c00000, "swap16", ["sp67.u16"]),
                      (0x1000000, "swap16", ["sp89.u17"]),
                      (0x1400000, "swap16", ["spab.u18"]),
                      (0x1800000, "swap16", ["spcd.u19"]),
                      (0x1c00000, "swap16", ["spef.u20"])]),
}

SETS = {"gogomile": GOGOMILE, "pbancho": PBANCHO,
        "asurabld": ASURABLD, "asurabus": ASURABUS}
FG3 = {"asurabld", "asurabus"}


def group(z, names, kind, parts):
    blobs = [bytearray(z.read(names[p])) for p in parts]
    if kind == "swap16":
        d = blobs[0]
        for i in range(0, len(d) - 1, 2):
            d[i], d[i+1] = d[i+1], d[i]
        return bytes(d)
    a, b = blobs
    out = bytearray(len(a) * 2)
    for i in range(0, len(a), 2):
        out[2*i+0] = a[i+1]; out[2*i+1] = a[i+0]
        out[2*i+2] = b[i+1]; out[2*i+3] = b[i+0]
    return bytes(out)


def build(zpath, size, groups):
    z = zipfile.ZipFile(zpath)
    names = {n.split('/')[-1]: n for n in z.namelist()}
    img = bytearray(size)
    for off, kind, parts in groups:
        blob = group(z, names, kind, parts)
        if off + len(blob) > size:
            sys.exit(f"group at 0x{off:x} overruns the {size:#x}-byte region")
        img[off:off+len(blob)] = blob
    return bytes(img)


def main():
    cap = Path(sys.argv[1] if len(sys.argv) > 1 else "debug/gogomile-title")
    game = sys.argv[2] if len(sys.argv) > 2 else "gogomile"
    out = Path("sim/tilemap_tb")   # shared by the tilemap and sprite benches
    out.mkdir(parents=True, exist_ok=True)

    pfx = "fg3" if game in FG3 else "fg2"
    vregs = (cap / f"{pfx}_vregs.bin").read_bytes()
    w = lambda i: struct.unpack_from(">H", vregs, i * 2)[0]

    # Decoded the same way vregs.sv does, INCLUDING the deliberate x/y offset
    # pairing (docs/ROADMAP.md) -- reproduced here so the testbench gets the
    # same numbers the RTL will compute, from an independent implementation.
    # FG-3 has NO layer-2 X offset (set_layer2_xoffs is FG-2 only). The
    # unflipped constants are identical on both boards; only the FLIPPED y
    # offset differs (0x2c7 on FG-3, 0x2a7 on FG-2).
    XOFFS, YOFFS = 0x01F3, 0x03F6
    L2_XOFFS = 0x0000 if game in FG3 else 0x0010
    flip = w(15) & 1
    if flip:
        sys.exit("captured frame has flip screen ON; the engine does not honour flip yet")
    soy = (w(6) - XOFFS) & 0xFFFF
    sox = (w(7) - YOFFS) & 0xFFFF
    scroll = {
        0: (((w(1) + sox) & 0xFFFF), ((w(0) + soy) & 0xFFFF)),
        1: (((w(3) + sox) & 0xFFFF), ((w(2) + soy) & 0xFFFF)),
        2: (((w(5) + L2_XOFFS) & 0xFFFF), (w(4) & 0xFFFF)),
    }
    l2_buffer = (w(15) >> 6) & 1

    for f in ("vram", "palette", "spriteram", "priority"):
        (out / f"{f}.bin").write_bytes((cap / f"{pfx}_{f}.bin").read_bytes())
    if game in FG3:
        # The tile bank is captured as TEXT, because it cannot be dumped from
        # the address space at all -- fuukifg3.cpp maps 0xa00000 writeonly(),
        # so a read returns 0. A zero bank collapses all four sprite code
        # ranges into one, which on asurabld points them into the EMPTY first
        # 4 MB of the sprite region and draws every sprite as a solid block.
        tb = int((cap / f"{pfx}_tilebank.txt").read_text().strip(), 16)
        (out / "tilebank.bin").write_bytes(tb.to_bytes(4, "big"))
        print(f"  sprite tile bank 0x{tb:08X} -> banks " +
              ", ".join(f"{(tb >> (16 + 4*b)) & 0xF:X}" for b in range(4)))

    spec = SETS[game]
    for layer, (size, groups) in spec.items():
        img = build(f"roms/{game}.zip", size, groups)
        (out / f"l{layer}_gfx.bin").write_bytes(img)
        desc = "; ".join(f"@{off:#08x} {kind} {'+'.join(parts)}" for off, kind, parts in groups)
        print(f"  l{layer}_gfx.bin  {len(img):>9,} bytes  {desc}")

    # Per-layer configuration, straight from each driver's GFXDECODE and
    # video_start(). The boards differ in more than tile size:
    #
    #             layer 0        layer 1        layer 2
    #   FG-2      16x16x4        16x16x8        8x8x4
    #             gran 16        gran 16 (*)    gran 16
    #             trans 0x0f     trans 0xff     trans 0x0f
    #
    #   FG-3      16x16x8        16x16x8        8x8x4
    #             gran 256       gran 256       gran 16
    #             colour >>= 4   colour >>= 4   colour as-is
    #             trans 0xff     trans 0xff     trans 0x0f
    #
    # (*) FG-2's layer 1 is 8bpp with granularity SIXTEEN, set explicitly by
    #     gfx(1)->set_granularity(16): "256 colour tiles with palette
    #     selectable on 16 colour boundaries". The pen therefore legitimately
    #     exceeds the granularity and must never be masked.
    #
    # FG-3 shifts tilemap colour right by 4 for layers 0 and 1 ONLY
    # (tmap_colour_cb), leaving two bits to select one of four 256-entry banks.
    fg3 = game in FG3
    with open(out / "config.txt", "w") as f:
        for layer in (0, 1, 2):
            sx, sy = scroll[layer]
            bank = layer if layer < 2 else (2 + l2_buffer)
            tile16 = 1 if layer < 2 else 0
            bpp8 = 1 if (fg3 and layer < 2) or (not fg3 and layer == 1) else 0
            gran256 = 1 if (fg3 and layer < 2) else 0
            shift4 = 1 if (fg3 and layer < 2) else 0
            trans = 0xFF if bpp8 else 0x0F
            pal_base = {0: 0x000, 1: 0x400, 2: 0xC00}[layer]
            f.write(f"{layer} {bank} {tile16} {bpp8} {shift4} {gran256} "
                    f"{pal_base} {trans} {sx} {sy}\n")

    print(f"\n  scroll (x, y) after offset decode:")
    for layer in (0, 1, 2):
        print(f"    layer {layer}: {scroll[layer][0]:5d}, {scroll[layer][1]:5d}")
    print(f"    layer 2 VRAM buffer: {l2_buffer}")
    print(f"  -> {out}")


main()
