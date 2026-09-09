#!/usr/bin/env python3
"""Build sim/x1_012_tb's inputs from a captured MAME frame plus the ROM set.

    python scripts/prep_x1_012_tb.py drgnunit debug/p2-drgnunit-f900

Produces, in sim/x1_012_tb/:
    vram.hex    0x2000 words of tilemap VRAM, both banks
    vctrl.hex   the three control words
    gfx2.hex    the whole "gfx2" region as 16-bit words IN SDRAM ORDER
    expect.hex  the model's pen index for every visible pixel, row-major
    cfg.hex     the layer configuration, one value per line, in CFG's order
    fixture.txt what this fixture is, for a bare run

THE EXPECTED IMAGE IS THE LAYER ALONE -- x1_012_model.render() with no sprite
pass. That is deliberate: this bench tests one chip. The sprites are already
verified against MAME by sim/x1_001_tb, and the two together are checked by
comparing the model's composite against MAME's own render, which is where the
12-of-12 figure comes from. Mixing them here would mean a failure could belong
to either.

SDRAM ORDER, not ROM order. The bench's ROM model answers 64-bit granules the
way rtl/memory/sdram.sv does, and a 16-bit word there is {odd byte, even byte}
-- so a region written out in ROM order would decode as a plausible picture
with every pair of pixels swapped, which reads as a layout bug and is not one.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_region import region_image
from x1_012_model import LAYER_GAMES, Layer, decode_tiles, render
from x1_001_model import load_capture, _be16

OUT = Path(__file__).resolve().parent.parent / "sim" / "x1_012_tb"

# The order rtl/video/x1_012.sv's bench reads them back in. Keep in step.
CFG = ["xoffs", "xoffs_flip", "flipscr", "vis_dimy", "colorbase", "code_mask",
       "vis_x0", "vis_x1", "vis_y0", "vis_y1"]


def s9(v):
    """A signed 9-bit value as the bench's $readmemh will take it."""
    return v & 0x1FF


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("capdir")
    ap.add_argument("--tag")
    a = ap.parse_args()

    if a.game not in LAYER_GAMES:
        sys.exit(f"no layer config for '{a.game}'. Known: "
                 f"{', '.join(sorted(LAYER_GAMES))}")
    cfg = LAYER_GAMES[a.game]
    cap = Path(a.capdir)
    tag = a.tag or a.game

    vram = _be16((cap / f"{tag}_l0vram.bin").read_bytes())
    vctrl = _be16((cap / f"{tag}_l0ctrl.bin").read_bytes())
    gfx2 = region_image(a.game, "gfx2")[0]
    code, ylow, ctrl, pal, _ = load_capture(cfg, cap, tag)

    tiles = decode_tiles(gfx2)
    vis = cfg["visarea"]
    x0, x1, y0, y1 = vis
    dimy = y1 - y0 + 1
    flip = bool(ctrl[0] & 0x40)

    # The LAYER ALONE -- no sprite pass.
    bmp = render(cfg, vram, vctrl, tiles, None, dimy, flip)

    OUT.mkdir(parents=True, exist_ok=True)

    vr = list(vram[:0x2000]) + [0] * max(0, 0x2000 - len(vram))
    (OUT / "vram.hex").write_text(
        "".join(f"{w & 0xffff:04x}\n" for w in vr[:0x2000]))
    (OUT / "vctrl.hex").write_text(
        "".join(f"{(vctrl[i] if i < len(vctrl) else 0) & 0xffff:04x}\n"
                for i in range(3)))

    words = bytearray(gfx2)
    if len(words) & 1:
        words.append(0)
    (OUT / "gfx2.hex").write_text(
        "".join(f"{words[2 * k + 1] << 8 | words[2 * k]:04x}\n"
                for k in range(len(words) // 2)))

    (OUT / "expect.hex").write_text(
        "".join(f"{bmp[y][x] & 0x7ff:03x}\n"
                for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)))

    vals = {
        "xoffs":      s9(cfg["l0_xoffsets"][1]),   # (flip, noflip)
        "xoffs_flip": s9(cfg["l0_xoffsets"][0]),
        "flipscr":    1 if flip else 0,
        "vis_dimy":   dimy,
        "colorbase":  cfg["gfx_colorbase"],
        # gfx_element wraps a code past the end of the region. layout_tilemap is
        # RGN_FRAC(1,1) and 128 bytes per tile, so elements = region / 128, and
        # every in-scope region is a power of two -- the wrap is a mask.
        "code_mask":  (len(gfx2) // 128) - 1,
        "vis_x0": x0, "vis_x1": x1, "vis_y0": y0, "vis_y1": y1,
    }
    (OUT / "cfg.hex").write_text("".join(f"{vals[k]:08x}\n" for k in CFG))

    (OUT / "fixture.txt").write_text(
        f"game     {a.game}\n"
        f"capture  {cap}\n"
        f"vctrl    {' '.join(f'{v:04x}' for v in vctrl[:3])}\n"
        f"bank     {1 if vctrl[2] & 8 else 0}\n"
        f"flipscr  {flip}\n"
        f"tiles    {len(tiles)}\n"
        f"expect   {(x1 - x0 + 1) * (y1 - y0 + 1)} pixels\n")

    print(f"{a.game}: vctrl {' '.join(f'{v:04x}' for v in vctrl[:3])}  "
          f"bank {1 if vctrl[2] & 8 else 0}  flip {flip}")
    print(f"  gfx2 {len(gfx2)} bytes, {len(tiles)} tiles, "
          f"code_mask {vals['code_mask']:#x}")
    print(f"  expect {(x1 - x0 + 1) * (y1 - y0 + 1)} pixels -> {OUT}")


if __name__ == "__main__":
    main()
