#!/usr/bin/env python3
"""Build sim/x1_001_tb's fixtures from a captured frame plus the model's render.

    python scripts/mame_capture.py thunderl --frame 300 --name tl300
    python scripts/prep_x1_001_tb.py thunderl debug/tl300
    scripts/run_sim.sh x1_001_tb                 (from the repository root)

The RTL renders per SCANLINE from live RAM; MAME renders a whole frame at once
from the state at the end of it. Those are different machines, and comparing
them directly would only ever be valid for a game that writes nothing during
the frame. So the chain is split in two, and each half is checked against
something that can actually answer:

    x1_001.cpp  ==  scripts/x1_001_model.py     24 captured frames, 8 sets,
                                                pixel-identical (x1_001_sweep)
    model       ==  rtl/video/x1_001.sv         this bench, per scanline

Both halves render the SAME fixed register state, so the difference in when
they read it does not arise.

WHAT GOES IN THE FIXTURE

  code.hex    0x2000 words of sprite code / X / attributes
  ylow.hex    0x300 bytes of sprite Y low + per-column scroll
  ctrl.hex    the four control bytes
  gfx.hex     the whole "gfx1" region as 16-bit words IN SDRAM ORDER --
              word k = {region[2k+1], region[2k]}, the even byte in the LOW
              half, which is what sdram_download.sv produces and what
              maincpu.sv's ROM_BYTESWAP was written against. Get it backwards
              and every sprite still draws, in the wrong colours.
  expect.hex  the model's pen index for every visible pixel, row-major
  cfg.hex     the board configuration, one value per line, in the order the
              testbench reads it (see CFG below -- it is positional, so the
              two lists have to be edited together)
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from x1_001_model import GAMES, Sprites, load_capture
from build_region import region_image

OUT = REPO / "sim" / "x1_001_tb"

# Positional, and the testbench indexes it by number. Keep the two in step.
CFG = [
    "fg_xoffs", "fg_xoffs_flip", "fg_yoffs", "fg_yoffs_flip",
    "bg_xoffs", "bg_xoffs_flip", "bg_yoffs", "bg_yoffs_flip",
    "bank_size", "spritelimit", "transpen", "bgflag_opaque",
    "colorbase_fg", "colorbase_bg", "screen_h", "vis_max_y",
    "backdrop", "gfx_half", "code_mask",
    "vis_x0", "vis_x1", "vis_y0", "vis_y1",
]


def s9(v):
    """A signed offset as 9-bit two's complement, the width the RTL port has."""
    return v & 0x1FF


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("capdir")
    ap.add_argument("--flip", action="store_true",
                    help="force the flip-screen bit in spritectrl[0]. No "
                         "captured frame has it set, so this is a "
                         "model-against-RTL check only -- see the note in "
                         "rtl/video/x1_001.sv.")
    a = ap.parse_args()

    if a.game not in GAMES:
        sys.exit(f"{a.game}: not configured in x1_001_model.GAMES")
    cfg = GAMES[a.game]

    gfx, gfx_size, zippath = region_image(a.game, "gfx1")
    code, ylow, ctrl, pal, tag = load_capture(cfg, a.capdir)
    if a.flip:
        ctrl = list(ctrl)
        ctrl[0] |= 0x40

    spr = Sprites(cfg, code, ylow, ctrl, gfx)
    bmp = spr.render()

    x0, x1, y0, y1 = cfg["visarea"]
    OUT.mkdir(parents=True, exist_ok=True)

    (OUT / "code.hex").write_text(
        "".join(f"{w & 0xffff:04x}\n" for w in code[:0x2000]))
    (OUT / "ylow.hex").write_text(
        "".join(f"{b & 0xff:02x}\n" for b in ylow[:0x300]))
    (OUT / "ctrl.hex").write_text(
        "".join(f"{b & 0xff:02x}\n" for b in ctrl[:4]))

    # SDRAM order: even byte LOW. See the module header.
    words = bytearray(gfx)
    if len(words) & 1:
        words.append(0)
    (OUT / "gfx.hex").write_text(
        "".join(f"{words[2 * k + 1] << 8 | words[2 * k]:04x}\n"
                for k in range(len(words) // 2)))

    (OUT / "expect.hex").write_text(
        "".join(f"{bmp[y][x] & 0x7ff:03x}\n"
                for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)))

    vals = {
        "fg_xoffs":      s9(cfg["fg_xoffs"][1]),
        "fg_xoffs_flip": s9(cfg["fg_xoffs"][0]),
        "fg_yoffs":      s9(cfg["fg_yoffs"][1]),
        "fg_yoffs_flip": s9(cfg["fg_yoffs"][0]),
        "bg_xoffs":      s9(cfg["bg_xoffs"][1]),
        "bg_xoffs_flip": s9(cfg["bg_xoffs"][0]),
        "bg_yoffs":      s9(cfg["bg_yoffs"][1]),
        "bg_yoffs_flip": s9(cfg["bg_yoffs"][0]),
        "bank_size":     cfg["bank_size"],
        "spritelimit":   cfg["spritelimit"],
        "transpen":      cfg["transpen"],
        "bgflag_opaque": 0,
        # gfx_element's colour base plus m_colorbase, which every in-scope
        # machine_config leaves at 0. draw_background adds no m_colorbase, so
        # the two are separate ports rather than one.
        "colorbase_fg":  cfg["gfx_colorbase"] + cfg["colorbase"] * 16,
        "colorbase_bg":  cfg["gfx_colorbase"],
        "screen_h":      cfg["screen_h"],
        "vis_max_y":     y1,
        "backdrop":      cfg["backdrop"],
        "gfx_half":      gfx_size // 2,
        # gfx_element wraps a code past the end of the region: elements =
        # half / 64 bytes per tile, and every in-scope region is a power of
        # two, so the wrap is a mask.
        "code_mask":     (gfx_size // 2 // 64) - 1,
        "vis_x0": x0, "vis_x1": x1, "vis_y0": y0, "vis_y1": y1,
    }
    (OUT / "cfg.hex").write_text("".join(f"{vals[k]:08x}\n" for k in CFG))

    (OUT / "fixture.txt").write_text(
        f"game     {a.game}\n"
        f"capture  {a.capdir} ({tag})\n"
        f"gfx1     {gfx_size:#x} bytes from {zippath}\n"
        f"tiles    {spr.ntiles} per half, code_mask {vals['code_mask']:#x}\n"
        f"ctrl     {' '.join(f'{c:02x}' for c in ctrl)}"
        f"{'  (FLIP SCREEN FORCED)' if a.flip else ''}\n"
        f"visarea  x {x0}..{x1}  y {y0}..{y1}\n"
        f"bank     {'1' if ((ctrl[1] ^ (~ctrl[1] << 1)) & 0x40) else '0'}"
        f"  numcol {ctrl[1] & 0x0f}\n")

    print(f"fixtures for {a.game} in {OUT}")
    for k in CFG:
        print(f"  {k:14s} {vals[k]:#x}")
    print(f"  gfx words      {len(words) // 2}")
    print(f"  expect pixels  {(y1 - y0 + 1) * (x1 - x0 + 1)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
