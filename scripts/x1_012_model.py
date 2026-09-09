#!/usr/bin/env python3
"""A line-by-line model of Seta's X1-012 tile layer generator.

    python scripts/x1_012_model.py drgnunit debug/p2-drgnunit-f900 --compare

This is to Phase 2 what x1_001_model.py is to Phase 1: the golden reference
that the RTL is written against, and the thing that gets diffed against MAME's
own render first. Every rule below is transcribed from
src/mame/seta/x1_012.cpp and the composition from seta_state::
seta_layers_update -- not reasoned out from what the picture ought to look
like. Where a value is a per-game machine_config call it is named in GAMES
rather than folded into the code.

WHAT THE CHIP IS

  A single tilemap, TILEMAP_SCAN_ROWS, 16x16 tiles, 64 columns x 32 rows --
  1024x512 pixels, wrapping in both axes. Each layer has TWO tilemaps in its
  VRAM and only one is displayed at a time (x1_012.cpp's opening comment);
  the other is selected by vctrl[2] bit 3 and lives at word offset 0x1000.

  Per tile, from the selected bank:
      code  = vram[i] & 0x3fff
      flip  = (vram[i] & 0xc000) >> 14      TILE_FLIPXY
      attr  = vram[i + 0x800]
      color = attr & 0x1f
  and the gfx set is (vctrl[2] & 0x10) >> 4 -- the "colour mode" bit, which
  for a 4bpp game selects a second decode that does not exist, so MAME
  popmessages and falls back to 0. Modelled, because a game that sets it
  would otherwise silently render from the wrong place.

  Pen 0 is transparent (set_transparent_pen(0)), but the bottom layer is
  drawn with TILEMAP_DRAW_OPAQUE, so for a one-layer game every pixel comes
  from the tilemap and the fill underneath is never visible. Modelled
  faithfully anyway: Phase 3 draws layer 1 non-opaque over it.

WHAT IS NOT HERE

  draw_tilemap_palette_effect -- blandia's second-palette trick, reached only
  when (m_vregs & 4) and a second palette exists. Phase 5.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_region import region_image
from x1_001_model import (GAMES, Sprites, compare, load_capture, to_rgb,
                          write_png, _be16)

# ---------------------------------------------------------------------------
# Per-game configuration, from the machine_config, one line each.
#
#   l0_xoffsets   X1_012(...).set_xoffsets(flip, noflip)
#   layers        how many X1_012 devices the config instantiates
#   tile_offset   set_tile_offset_callback, or None
#
# drgnunit, stg, qzkklogy and qzkklgy2 all run the drgnunit machine_config;
# stg and the qzkk* sets differ only in sprite offsets and rotation, which
# live in the sprite config they already share with Phase 1.
# ---------------------------------------------------------------------------
_ONE_LAYER = dict(
    # (FLIP, NOFLIP), the order set_xoffsets takes its arguments in and the
    # order x1_001_model's fg_xoffs/bg_xoffs already use. MAME stores them the
    # other way round -- m_xoffsets[1] = flip, [0] = noflip -- so one of the two
    # has to be reversed somewhere; doing it at the read keeps every table in
    # this project in the driver's own order.
    l0_xoffsets=(-2, -2),        # set_xoffsets(-2, -2)
    layers=1,
    tile_offset=None,
    # seta_layers_update fills with pen 0, NOT no_layers' 0x1f0.
    backdrop=0,
)


def _sprite_cfg(**over):
    """A Phase 1 sprite config with this family's machine_config values."""
    cfg = dict(GAMES["thunderl"])
    cfg.update(
        fg_xoffs=(2, 2), fg_yoffs=(-0x12, 0x0e),
        bg_xoffs=(0, 0), bg_yoffs=(0x1, -0x1),
        gfx_colorbase=0x000, total_color_codes=32,
        palette_entries=512,
        bank_size=0x1000,
        backdrop=0,
        visarea=(0, 383, 8, 247),   # set_visarea(0*8, 48*8-1, 1*8, 31*8-1)
        rot=0,
    )
    cfg.update(_ONE_LAYER)
    cfg.update(over)
    return cfg


# Each of these runs the drgnunit machine_config and then overrides. The
# overrides are the whole difference between the four, and assuming they were
# absent cost 0.3% to 26% of the pixels on six of nine frames.
LAYER_GAMES = {
    # set_fg_xoffsets(2, 2), set_xoffsets(-2, -2)
    "drgnunit": _sprite_cfg(rot=0),
    # stg: set_fg_xoffsets(0, 0). Layer offsets inherited.
    "stg":      _sprite_cfg(rot=270, fg_xoffs=(0, 0)),
    # qzkklogy: set_fg_xoffsets(1, 1), set_xoffsets(-1, -1)
    "qzkklogy": _sprite_cfg(rot=0, fg_xoffs=(1, 1), l0_xoffsets=(-1, -1)),
    # qzkklgy2: set_fg_xoffsets(0, 0), set_xoffsets(-3, -1) -- the one set
    # whose flip and noflip layer offsets actually differ.
    "qzkklgy2": _sprite_cfg(rot=0, fg_xoffs=(0, 0), l0_xoffsets=(-3, -1)),
}


# ---------------------------------------------------------------------------
# layout_tilemap -- "The tilemap bitplanes are packed togheter" (seta.cpp)
#
#     16,16, RGN_FRAC(1,1), 4,
#     planes  { STEP4(0,4) }                        = 0, 4, 8, 12
#     xoffs   { STEP4(4*4*8*3,1), STEP4(4*4*8*2,1),
#               STEP4(4*4*8,1),   STEP4(0,1) }
#     yoffs   { STEP8(0,4*4), STEP8(4*4*8*4,4*4) }
#     charincrement 16*16*4
#
# 128 bytes per tile. The x offsets run in DESCENDING groups of four, which is
# the part no amount of staring at a picture would tell you and the reason
# this is transcribed rather than derived -- Phase 1's record is that every
# graphics layout reasoned out from byte order was wrong, and every one
# decoded from real ROM data and checked against MAME was right.
# ---------------------------------------------------------------------------
# THE FIRST PLANE LISTED IS THE MOST SIGNIFICANT BIT of the pen. That is
# MAME's gfx_layout convention, not a property of this chip, and reading it the
# other way round is not a wrong picture -- it is a RECOGNISABLE picture with a
# large minority of pixels wrong, which reads as a subtly bad layout rather
# than as an inverted bit order. Scored against MAME's own render over sixteen
# candidate layouts: every variant with the planes ascending scored 33-34%, and
# the transcription with the planes read MSB-first scored 100.00%.
#
# Phase 4's 6bpp layouts have the same convention and the same trap.
_PLANES = [0, 4, 8, 12]
_XOFFS = ([4 * 4 * 8 * 3 + i for i in range(4)] +
          [4 * 4 * 8 * 2 + i for i in range(4)] +
          [4 * 4 * 8 * 1 + i for i in range(4)] +
          [0 + i for i in range(4)])
_YOFFS = ([0 + i * (4 * 4) for i in range(8)] +
          [4 * 4 * 8 * 4 + i * (4 * 4) for i in range(8)])
_TILE_BITS = 16 * 16 * 4


def decode_tiles(gfx):
    """Every 16x16 4bpp tile in the region, as a flat list of 256 pens each."""
    ntiles = (len(gfx) * 8) // _TILE_BITS
    out = []
    for t in range(ntiles):
        base = t * _TILE_BITS
        tile = bytearray(256)
        for y in range(16):
            yo = _YOFFS[y]
            for x in range(16):
                xo = _XOFFS[x]
                pen = 0
                for p, po in enumerate(_PLANES):
                    bit = base + yo + xo + po
                    byte = gfx[bit >> 3]
                    if byte & (0x80 >> (bit & 7)):
                        pen |= 1 << (len(_PLANES) - 1 - p)
                tile[y * 16 + x] = pen
        out.append(tile)
    return out


class Layer:
    """One X1-012's worth of state, plus its tile ROM."""

    def __init__(self, cfg, vram, vctrl, tiles):
        self.cfg = cfg
        self.vram = vram            # words
        self.vctrl = vctrl          # three words
        self.tiles = tiles

    # -- x1_012_device::get_tile_info -------------------------------------
    def tile_info(self, index):
        bank = 0x1000 if (self.vctrl[2] & 0x0008) else 0
        word = self.vram[bank + index]
        code = word & 0x3fff
        # TILE_FLIPXY TRANSPOSES THE TWO BITS. From emu/tilemap.h:
        #     TILE_FLIPXY(xy) = ((xy & 2) >> 1) | ((xy & 1) << 1)
        # with TILE_FLIPX = 1 and TILE_FLIPY = 2. So for
        # TILE_FLIPXY((word & 0xc000) >> 14), word bit 14 becomes FLIPY and
        # word bit 15 becomes FLIPX -- the opposite way round to what the
        # macro's name reads like, and the opposite of what was written here
        # first.
        #
        # It costs 2-5% of the pixels, only on frames that happen to contain a
        # flipped tile, and only on those tiles: drgnunit's three frames were
        # pixel-exact throughout, so this looked like a per-game problem in the
        # other three sets rather than a decode bug. What identified it was
        # asking what the WRONG PIXELS had in common -- every one of them was
        # in a tile whose flip bits were non-zero.
        flipx = bool(word & 0x8000)
        flipy = bool(word & 0x4000)
        attr = self.vram[bank + index + 0x800]
        color = attr & 0x1f
        # gfx = (m_vctrl[2] & 0x10) >> 4, and gfx(1) is nullptr for every
        # game in this phase, so MAME popmessages and uses 0.
        gfx = (self.vctrl[2] & 0x10) >> 4
        if gfx == 1:
            gfx = 0
        if self.cfg["tile_offset"] is not None:
            code = self.cfg["tile_offset"](code)
        return code, color, flipx, flipy

    # -- the tilemap's own 1024x512 pixmap --------------------------------
    def pixmap(self):
        pm = bytearray(1024 * 512)
        colors = bytearray(1024 * 512)
        for row in range(32):
            for col in range(64):
                index = row * 64 + col          # TILEMAP_SCAN_ROWS
                code, color, flipx, flipy = self.tile_info(index)
                tile = self.tiles[code % len(self.tiles)]
                ox, oy = col * 16, row * 16
                for y in range(16):
                    sy = 15 - y if flipy else y
                    dst = (oy + y) * 1024 + ox
                    src = sy * 16
                    for x in range(16):
                        sx = 15 - x if flipx else x
                        pm[dst + x] = tile[src + sx]
                        colors[dst + x] = color
        return pm, colors

    # -- x1_012_device::update_scroll -------------------------------------
    def scroll(self, vis_dimy, flip):
        x = self.vctrl[0]
        y = self.vctrl[1]
        x += 0x10 - self.cfg["l0_xoffsets"][0 if flip else 1]
        y -= (256 - vis_dimy) // 2
        if flip:
            x = -x - 512
            y = y - vis_dimy
        return x, y


def render(cfg, vram, vctrl, tiles, spr, vis_dimy, flip):
    """seta_layers_update for a ONE-layer game.

    m_layers[1] is absent, so `order` is 0 and the whole function collapses
    to: fill(0), layer 0 drawn OPAQUE, then the sprites. Nothing chooses a
    priority and nothing swaps.
    """
    layer = Layer(cfg, vram, vctrl, tiles)
    pm, colors = layer.pixmap()
    sx, sy = layer.scroll(vis_dimy, flip)

    w, h = cfg["screen_w"], cfg["screen_h"]
    # Rows, not a flat list: this is the bitmap Sprites.draw_* write into, and
    # sharing their representation is what lets the layer sit UNDER the real
    # Phase 1 sprite engine instead of a reimplementation of it.
    bmp = [[cfg["backdrop"]] * w for _ in range(h)]

    # TILEMAP_DRAW_OPAQUE: every pixel, transparent pen included. set_flip
    # mirrors the whole pixmap about its own 1024x512 before the scroll.
    for y in range(h):
        row = bmp[y]
        for x in range(w):
            if flip:
                # FLIP SCREEN IS NOT SOLVED. This branch is wrong and is left
                # here so the shape is visible, not because it works.
                #
                # Every frame this model was verified against has flip screen
                # CLEAR -- 12 of 12 pixel-identical, all unflipped. The first
                # flipped capture ever taken for this family (drgnunit f900,
                # spritectrl[0] = 0x50, via mame_capture.py --dip) puts 29.6%
                # of the pixels wrong, and bucketing them by whether the sprite
                # pass drew them gives ZERO wrong under sprites and all 27,309
                # in the tilemap. So the sprite flip is right and this is not.
                #
                # Eight candidate mappings scored against MAME's own render:
                #     70.37%  1023-(x+sx), 511-(y+sy)        <- this one
                #     70.37%  1023-x+sx, 511-y+sy
                #     70.37%  mirror x only
                #     70.35%  x-sx-512, mirror y
                #     70.25%  x-sx-512, y-sy-256   (draw_tilemap_palette_effect)
                #     65.12%  mirror y only
                #     48.87%  x-sx, y-sy
                #     46.67%  x+sx, y+sy           (no flip at all)
                # Three different mappings tie at the top and "mirror x only"
                # scores the same as a full mirror, which means the y term is
                # not discriminating -- so the error is not in this expression.
                #
                # NEXT HYPOTHESIS, untested: MAME's set_flip(TILEMAP_FLIPX |
                # TILEMAP_FLIPY) also inverts EACH TILE'S OWN flip bits, not
                # just the map indexing. None of the eight candidates touched
                # tile_info's flipx/flipy, and that is where to look next.
                px, py = (1023 - (x + sx)) & 1023, (511 - (y + sy)) & 511
            else:
                px, py = (x + sx) & 1023, (y + sy) & 511
            o = py * 1024 + px
            row[x] = cfg["gfx_colorbase"] + colors[o] * 16 + pm[o]

    if spr is not None:
        spr.draw_background(bmp)
        spr.draw_foreground(bmp)
    return bmp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("capdir")
    ap.add_argument("--tag")
    ap.add_argument("--png")
    ap.add_argument("--compare", action="store_true")
    ap.add_argument("--no-sprites", action="store_true",
                    help="render the layer alone. Cannot be compared against "
                         "MAME, which always draws the sprites too")
    a = ap.parse_args()

    if a.game not in LAYER_GAMES:
        sys.exit(f"no layer config for '{a.game}'. Known: "
                 f"{', '.join(sorted(LAYER_GAMES))}")
    cfg = LAYER_GAMES[a.game]
    cap = Path(a.capdir)
    tag = a.tag or a.game

    vram = _be16((cap / f"{tag}_l0vram.bin").read_bytes())
    vctrl = _be16((cap / f"{tag}_l0ctrl.bin").read_bytes())
    print(f"capture {tag}: vctrl {' '.join(f'{v:04x}' for v in vctrl)}  "
          f"bank {1 if vctrl[2] & 8 else 0}  "
          f"colour mode {(vctrl[2] & 0x10) >> 4}")

    gfx2 = region_image(a.game, "gfx2")[0]
    tiles = decode_tiles(gfx2)
    print(f"  {len(tiles)} tiles in gfx2 ({len(gfx2)} bytes)")

    code, ylow, ctrl, pal, _ = load_capture(cfg, cap, tag)
    gfx1 = region_image(a.game, "gfx1")[0]
    spr = None if a.no_sprites else Sprites(cfg, code, ylow, ctrl, gfx1)

    vis = cfg["visarea"]
    vis_dimy = vis[3] - vis[2] + 1
    flip = bool(ctrl[0] & 0x40)
    bmp = render(cfg, vram, vctrl, tiles, spr, vis_dimy, flip)

    if a.png:
        write_png(a.png, to_rgb(bmp, pal, cfg))
        print(f"  wrote {a.png}")
    if a.compare:
        sys.exit(compare(bmp, pal, cfg, cap, tag))


if __name__ == "__main__":
    main()
