#!/usr/bin/env python3
"""Build sim/seta_video_tb's fixtures: chip state, graphics, palette, and the
RGB frame MAME produced from exactly that state.

    python scripts/mame_capture.py umanclub --frame 900 --name uc900
    python scripts/prep_video_tb.py umanclub debug/uc900
    scripts/run_sim.sh seta_video_tb              (from the repository root)

sim/x1_001_tb checks the sprite engine against the model in PEN INDICES. This
bench checks the whole video path -- timing generator, line-buffer readout,
palette decode -- in RGB, against MAME's own render. It is the first test in
the project whose reference is the actual picture rather than an intermediate.

Three things only this bench can catch, and each of them looks like something
else:

  * pal5bit. The 5-to-8 bit expansion is (v << 3) | (v >> 2); a plain shift
    makes white 0xF8 and every colour slightly dark, which reads as a palette
    RAM problem rather than an arithmetic one.
  * The visible window. The line buffer is indexed by SCREEN-SPACE x and the
    visarea starts at y = 8, not 0. An off-by-one in either shows up as a
    shifted picture, which is what a wrong sprite offset also looks like.
  * The read pipeline. Address register, line-buffer RAM, palette index
    register, palette RAM, colour register -- five stages against a
    twelve-cycle dot. Mis-timed, it shifts the picture by one pixel, which is
    exactly the failure sim/x1_001_tb hit and diagnosed as "46% of the frame
    wrong".

FILES

  code.hex / ylow.hex / ctrl.hex / gfx.hex   as sim/x1_001_tb (gfx.hex is the
                                             NATURAL region -- the bench pushes
                                             it through gfx_swizzle itself)
  pal.hex     the captured palette RAM, one 16-bit word per entry
  rgb.hex     MAME's render, 0xRRGGBB per pixel, row-major over the visible area
  cfg.hex     board configuration, positional (see CFG below)
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from x1_001_model import GAMES, Sprites, load_capture, SNAPSHOT_TRANSFORM, _read_orientation
from build_region import region_image

OUT = REPO / "sim" / "seta_video_tb"

# Positional; the testbench indexes it by number. Keep the two in step.
CFG = [
    "fg_xoffs", "fg_xoffs_flip", "fg_yoffs", "fg_yoffs_flip",
    "bg_xoffs", "bg_xoffs_flip", "bg_yoffs", "bg_yoffs_flip",
    "bank_size", "spritelimit", "transpen", "bgflag_opaque",
    "colorbase_fg", "colorbase_bg", "screen_h", "vis_max_y",
    "backdrop", "gfx_half", "code_mask", "line_budget",
    "htotal", "hs_start", "hs_end", "hact_start", "hact_end",
    "vtotal", "vs_start", "vs_end", "vact_start", "vact_end",
    "pal_entries",
]


def s9(v):
    return v & 0x1FF


def geometry(cfg):
    """The screen timing hypothesis, from docs/ROADMAP.md.

    dot clock 8 MHz, htotal 512. vtotal 260 gives 60.10 Hz, which is what every
    Group A game declares (MAME's own 60 is its default, with no evidence
    either way -- only daioh's 57.42 is marked verified on PCB).

    Sync positions inside the blanking are NOT derived from anything. They are
    plausible and self-consistent; the scaler does not care where they sit as
    long as they are inside the blanking interval and stable. Recorded as a
    hypothesis so nobody later mistakes them for a measurement.
    """
    x0, x1, y0, y1 = cfg["visarea"]
    return {
        "htotal": 512, "hact_start": x0, "hact_end": x1,
        "hs_start": x1 + 17, "hs_end": x1 + 65,
        "vtotal": 260, "vact_start": y0, "vact_end": y1,
        "vs_start": y1 + 3, "vs_end": y1 + 6,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("capdir")
    ap.add_argument("--budget", type=int, default=0,
                    help="line_budget in clk_sys cycles; 0 disables the cutoff")
    a = ap.parse_args()

    if a.game not in GAMES:
        sys.exit(f"{a.game}: not configured in x1_001_model.GAMES")
    cfg = GAMES[a.game]
    capdir = Path(a.capdir)

    gfx, gfx_size, zippath = region_image(a.game, "gfx1")
    code, ylow, ctrl, pal, tag = load_capture(cfg, capdir)

    x0, x1, y0, y1 = cfg["visarea"]
    W, H = x1 - x0 + 1, y1 - y0 + 1
    OUT.mkdir(parents=True, exist_ok=True)

    (OUT / "code.hex").write_text("".join(f"{w & 0xffff:04x}\n" for w in code[:0x2000]))
    (OUT / "ylow.hex").write_text("".join(f"{b & 0xff:02x}\n" for b in ylow[:0x300]))
    (OUT / "ctrl.hex").write_text("".join(f"{b & 0xff:02x}\n" for b in ctrl[:4]))
    (OUT / "pal.hex").write_text(
        "".join(f"{pal[i] & 0xffff:04x}\n" if i < len(pal) else "0000\n"
                for i in range(cfg["palette_entries"])))

    words = bytearray(gfx)
    if len(words) & 1:
        words.append(0)
    (OUT / "gfx.hex").write_text(
        "".join(f"{words[2 * k + 1] << 8 | words[2 * k]:04x}\n"
                for k in range(len(words) // 2)))

    # MAME's own render of this frame, undone back to screen space. The
    # snapshot goes through the render pipeline, which applies the cabinet
    # orientation -- x1_001_model.SNAPSHOT_TRANSFORM records what was measured
    # for each value scr:orientation() reports, and why it is measured rather
    # than reasoned about.
    from PIL import Image
    ref = Image.open(capdir / "reference.png").convert("RGB")
    orient = _read_orientation(capdir, tag)
    if orient is None:
        orient = cfg.get("rot", 0)
    if orient not in SNAPSHOT_TRANSFORM:
        sys.exit(f"orientation {orient} has never been calibrated "
                 f"-- see SNAPSHOT_TRANSFORM in x1_001_model.py")
    if SNAPSHOT_TRANSFORM[orient] == "rot180":
        ref = ref.transpose(Image.ROTATE_180)
    if ref.size != (W, H):
        sys.exit(f"MAME's snapshot is {ref.size}, the visible area is {(W, H)}")
    px = ref.load()
    (OUT / "rgb.hex").write_text(
        "".join(f"{px[x, y][0] << 16 | px[x, y][1] << 8 | px[x, y][2]:06x}\n"
                for y in range(H) for x in range(W)))

    geo = geometry(cfg)
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
        "colorbase_fg":  cfg["gfx_colorbase"] + cfg["colorbase"] * 16,
        "colorbase_bg":  cfg["gfx_colorbase"],
        "screen_h":      cfg["screen_h"],
        "vis_max_y":     y1,
        "backdrop":      cfg["backdrop"],
        "gfx_half":      gfx_size // 2,
        "code_mask":     (gfx_size // 2 // 64) - 1,
        "line_budget":   a.budget,
        "pal_entries":   cfg["palette_entries"],
    }
    vals.update(geo)
    (OUT / "cfg.hex").write_text("".join(f"{vals[k]:08x}\n" for k in CFG))

    (OUT / "fixture.txt").write_text(
        f"game     {a.game}\n"
        f"capture  {a.capdir} ({tag})\n"
        f"gfx1     {gfx_size:#x} bytes from {zippath}\n"
        f"palette  {cfg['palette_entries']} entries\n"
        f"visible  {W}x{H} at x {x0} y {y0}\n"
        f"timing   htotal {geo['htotal']} vtotal {geo['vtotal']} "
        f"(HYPOTHESIS -- see seta_video_timing.sv)\n"
        f"budget   {a.budget}\n"
        f"ctrl     {' '.join(f'{c:02x}' for c in ctrl)}\n")

    print(f"fixtures for {a.game} in {OUT}")
    print(f"  visible      {W}x{H} at x {x0} y {y0}")
    print(f"  timing       htotal {geo['htotal']} vtotal {geo['vtotal']} "
          f"hs {geo['hs_start']}..{geo['hs_end']} vs {geo['vs_start']}..{geo['vs_end']}")
    print(f"  palette      {cfg['palette_entries']} entries")
    print(f"  gfx words    {len(words) // 2}")
    print(f"  reference    {W * H} RGB pixels (orientation {orient})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
