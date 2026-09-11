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
    cfg.setdefault("l0_colorbase", 0)
    cfg.setdefault("l1_colorbase", 0)
    cfg.update(over)
    return cfg


# Each of these runs the drgnunit machine_config and then overrides. The
# overrides are the whole difference between the four, and assuming they were
# absent cost 0.3% to 26% of the pixels on six of nine frames.
# ---------------------------------------------------------------------------
# Phase 3 -- two 4bpp layers, the X1-011 order register, and a palette split
# three ways. GFXDECODE bases: sprites 0, layer 0 0x400, layer 1 0x200, of
# 512*3 entries.
# ---------------------------------------------------------------------------
def _two_layer_cfg(**over):
    cfg = _sprite_cfg()
    cfg.update(
        layers=2,
        palette_entries=512 * 3,
        l0_colorbase=0x400, l1_colorbase=0x200,
        l0_xoffsets=(-2, -2), l1_xoffsets=(-2, -2),
        # 4bpp, one gfx entry per layer: colour mode 1 falls back to 0.
        l0_bpp=4, l1_bpp=4,
        # Direct: MAME leaves these games' colortable at its default, which
        # dipalette.cpp fills as `pen % indirect_colors` -- identity.
        l0_pal_mode="direct", l1_pal_mode="direct",
        l0_pal_bank=0, l1_pal_bank=0,
    )
    cfg.update(over)
    return cfg


def _6bpp_cfg(**over):
    """The Phase 4 families. Bases are the GFXDECODE_ENTRY arguments."""
    cfg = _two_layer_cfg()
    cfg.update(
        # 0x600 of palette RAM. The GFXDECODE bases index a COLORTABLE of
        # 16*32 + 64*32*4 entries, but the colortable is the remap -- what the
        # hardware has, and what the core instantiates, is 1536 entries.
        palette_entries=0x600,
        l0_xoffsets=(0, 0), l1_xoffsets=(0, 0),
        # A 6bpp layer's pixel leaves the engine as {color, pen} -- no base.
        l0_colorbase=0, l1_colorbase=0,
    )
    cfg.update(over)
    return cfg


# ---------------------------------------------------------------------------
# Phase 4 -- 6bpp layers.
#
# GFXDECODE, entry [0] then [1], from seta.cpp:
#   gundhara  L1 gfx2 16*32+64*32*1 / *3     L2 gfx3 16*32+64*32*0 / *2
#   jjsquawk  L1 gfx2 16*32+64*32*0 / *2     L2 gfx3 16*32+64*32*1 / *3
#             -- note gundhara and jjsquawk SWAP which layer sits at which
#             base, on top of differing in their palette remap by two
#             characters. Both read like typos and neither is one.
# ---------------------------------------------------------------------------
# `pal_mode`: "masked" drops the colour code's low two bits before the add,
# "plain" does not. gundhara and jjsquawk BOTH instantiate gfx_jjsquawk_layer1
# and gfx_jjsquawk_layer2 -- there is no gfx_gundhara_* pair -- and differ only
# in which palette function they pass. `pal_bank` is where that function sends
# each layer.
SIXBPP_GAMES = {
    # set_fg_xoffsets(0, 0) on gundhara, (1, 1) on jjsquawk -- the default
    # the sprite config carries is drgnunit's (2, 2), and two pixels shows up
    # as a ring of wrong pixels around every glyph.
    "gundhara": _6bpp_cfg(
        rot=270, fg_xoffs=(0, 0), l0_bpp=6, l1_bpp=6,
        l0_pal_mode="masked", l1_pal_mode="masked",
        l0_pal_bank=0x400, l1_pal_bank=0x200),
    # blandia: both layers 6bpp; the colour mode is vctrl[2] bit 4 at run
    # time and the RTL promotes "bland0" to bland1 from it, so the config
    # names mode 0. set_xoffsets(6, -2) on both layers, set_fg_xoffsets(8, 0).
    # 3072 palette entries: 1536 of its own and the second palette RAM the
    # offset effect reads, which the capture ships as blandia_palette2.bin.
    "blandia": _6bpp_cfg(
        rot=0, fg_xoffs=(8, 0), l0_bpp=6, l1_bpp=6,
        l0_xoffsets=(6, -2), l1_xoffsets=(6, -2),
        l0_pal_mode="bland0", l1_pal_mode="bland0",
        l0_pal_bank=0x400, l1_pal_bank=0x200,
        palette_entries=3072),
    "jjsquawk": _6bpp_cfg(
        rot=0, fg_xoffs=(1, 1), l0_bpp=6, l1_bpp=6,
        # set_xoffsets(-1, -1) on both layers.
        l0_xoffsets=(-1, -1), l1_xoffsets=(-1, -1),
        l0_pal_mode="plain", l1_pal_mode="plain",
        l0_pal_bank=0x400, l1_pal_bank=0x200),
    # zingzip's layer 2 is 4bpp, and only its layer 1 is remapped -- the rest
    # of the colortable keeps MAME's identity default, so layer 2 is direct
    # with the palette base its GFXDECODE carries.
    "zingzip": _6bpp_cfg(
        rot=270, fg_xoffs=(0, 0), l0_bpp=6, l1_bpp=4,
        l0_xoffsets=(-2, -1), l1_xoffsets=(-2, -1),
        l0_pal_mode="masked", l0_pal_bank=0x400,
        l1_pal_mode="direct", l1_colorbase=0x200),
    "extdwnhl": _6bpp_cfg(
        rot=0, fg_xoffs=(0, 0), l0_bpp=6, l1_bpp=4,
        l0_xoffsets=(-2, -2), l1_xoffsets=(-2, -2),
        l0_pal_mode="masked", l0_pal_bank=0x400,
        l1_pal_mode="direct", l1_colorbase=0x200),
    # sokonuke runs extdwnhl's machine_config outright.
    "sokonuke": _6bpp_cfg(
        rot=0, fg_xoffs=(0, 0), l0_bpp=6, l1_bpp=4,
        l0_xoffsets=(-2, -2), l1_xoffsets=(-2, -2),
        l0_pal_mode="masked", l0_pal_bank=0x400,
        l1_pal_mode="direct", l1_colorbase=0x200),
    # madshark calls no set_xoffsets at all.
    "madshark": _6bpp_cfg(
        rot=270, fg_xoffs=(0, 0), l0_bpp=6, l1_bpp=6,
        l0_pal_mode="plain", l1_pal_mode="plain",
        l0_pal_bank=0x400, l1_pal_bank=0x200),
}


TWO_LAYER_GAMES = {
    # All four use set_fg_xoffsets(0, 0) and both layers at set_xoffsets(-2,-2).
    # daioh is 16 MHz verified from PCB.
    "daioh":    _two_layer_cfg(rot=270, fg_xoffs=(0, 0)),
    "rezon":    _two_layer_cfg(rot=0,   fg_xoffs=(0, 0)),
    # wrofaero does NOT call set_xoffsets, so both layers keep the device
    # default {0, 0} rather than daioh's and rezon's (-2, -2).
    "wrofaero": _two_layer_cfg(rot=270, fg_xoffs=(0, 0),
                               l0_xoffsets=(0, 0), l1_xoffsets=(0, 0)),
    "msgundam": _two_layer_cfg(rot=0, fg_xoffs=(0, 0)),
    # kamenrid and magspeed carve both tile regions out of one "user1" region
    # with ROM_COPY, so their tiles are 0x40000 and 0x80000 rather than 1-2 MB.
    "kamenrid": _two_layer_cfg(rot=0, fg_xoffs=(0, 0)),
    # magspeed: set_xoffsets(0, -2) on BOTH layers -- the only Group C set
    # whose flip and noflip layer offsets differ. Its vregs is at 0x500015,
    # past the 8 bytes _TWO_LAYER_TAPS covers, so mame_capture.py taps wider
    # for it; the captured frame writes 1, which swaps the layers.
    "magspeed": _two_layer_cfg(rot=0, fg_xoffs=(0, 0),
                               l0_xoffsets=(0, -2), l1_xoffsets=(0, -2)),
    # oisipuzl: set_visarea(0, 40*8-1, 2*8, 30*8-1) -- 320x224, narrower and
    # shorter than the 384x240 the rest of the group uses.
    #
    # oisipuzl's SPRITE region is ROMREGION_INVERT, and its tilemaps flip
    # independently of the sprites -- see tilemaps_flip below. Nothing else in
    # Group C has either.
    "oisipuzl": _two_layer_cfg(rot=0, fg_xoffs=(1, 1),
                               l0_xoffsets=(-1, -1), l1_xoffsets=(-1, -1),
                               visarea=(0, 319, 16, 239),
                               tilemaps_flip=1),
    # eightfrc: set_fg_xoffsets(4, 3) -- the only set whose flip and noflip
    # sprite offsets differ -- and no set_xoffsets on either layer.
    # eightfrc: set_visarea(0, 48*8-1, 2*8, 30*8-1) -- 384x224.
    "eightfrc": _two_layer_cfg(rot=90, fg_xoffs=(4, 3),
                               l0_xoffsets=(0, 0), l1_xoffsets=(0, 0),
                               visarea=(0, 383, 16, 239)),
}


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
def _layout(bpp):
    """(planes, xoffs, yoffs, bits per tile) for layout_tilemap[_6bpp].

    The two differ only in how many planes a pixel has, so the offsets are the
    same expressions with 4 replaced by 6 -- which is exactly how seta.cpp
    writes them. Transcribed, not derived:

        4bpp  { STEP4(0,4) }                       planes
              { STEP4(4*4*8*3,1), ... STEP4(0,1) } x
              { STEP8(0,4*4), STEP8(4*4*8*4,4*4) } y
        6bpp  { STEP4(0,4), STEP2(4*4,4) }
              { STEP4(6*4*8*3,1), ... STEP4(0,1) }
              { STEP8(0,6*4), STEP8(6*4*8*4,6*4) }
    """
    planes = [4 * i for i in range(bpp)]
    xoffs = [bpp * 4 * 8 * g + i for g in (3, 2, 1, 0) for i in range(4)]
    yoffs = ([i * (bpp * 4) for i in range(8)] +
             [bpp * 4 * 8 * 4 + i * (bpp * 4) for i in range(8)])
    return planes, xoffs, yoffs, 16 * 16 * bpp


_PLANES, _XOFFS, _YOFFS, _TILE_BITS = _layout(4)


def decode_tiles(gfx, bpp=4):
    """Every 16x16 tile in the region, as a flat list of 256 pens each."""
    planes, xoffs, yoffs, tile_bits = _layout(bpp)
    ntiles = (len(gfx) * 8) // tile_bits
    out = []
    for t in range(ntiles):
        base = t * tile_bits
        tile = bytearray(256)
        for y in range(16):
            yo = yoffs[y]
            for x in range(16):
                xo = xoffs[x]
                pen = 0
                for p, po in enumerate(planes):
                    bit = base + yo + xo + po
                    byte = gfx[bit >> 3]
                    if byte & (0x80 >> (bit & 7)):
                        pen |= 1 << (len(planes) - 1 - p)
                tile[y * 16 + x] = pen
        out.append(tile)
    return out


class Layer:
    """One X1-012's worth of state, plus its tile ROM."""

    def __init__(self, cfg, vram, vctrl, tiles, bpp=4, colorbase_m1=None):
        self.bpp = bpp
        # The mode-1 palette base, where the layer has a second gfx entry.
        self.colorbase_m1 = colorbase_m1
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
        # gfx = (m_vctrl[2] & 0x10) >> 4 picks the layer's second GFXDECODE
        # entry. For the 4bpp games gfx(1) is nullptr and MAME falls back to 0;
        # for the 6bpp ones it exists but differs only in a palette base that
        # the colortable maps to the same place. Either way nothing here
        # changes, so the bit is read and dropped.
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


def _draw(cfg, layer, bmp, vis_dimy, flip, opaque, base=None):
    """One layer into bmp. OPAQUE draws every pixel; otherwise pen 0 is
    transparent -- set_transparent_pen(0)."""
    pm, colors = layer.pixmap()
    sx, sy = layer.scroll(vis_dimy, flip)
    w, h = cfg["screen_w"], cfg["screen_h"]
    # PER LAYER, not one for the whole game. daioh's GFXDECODE_ENTRYs put
    # sprites at 0, layer 0 at 0x400 and layer 1 at 0x200 of 512*3 entries.
    if base is None:
        base = cfg["gfx_colorbase"]
    # A 6bpp pen is six bits, so the colour granularity is 64.
    gran = 64 if layer.bpp == 6 else 16
    for y in range(h):
        row = bmp[y]
        for x in range(w):
            if flip:
                px, py = (1023 - (x + sx)) & 1023, (511 - (y + sy)) & 511
            else:
                px, py = (x + sx) & 1023, (y + sy) & 511
            o = py * 1024 + px
            pen = pm[o]
            if opaque or pen:
                row[x] = base + colors[o] * gran + pen


def render2(cfg, l0, l1, spr, vis_dimy, flip, vregs):
    """seta_layers_update for a TWO-layer game, transcribed.

        order = m_layers[1].found() ? m_vregs : 0
        bit 0  Layer 0 Above Layer 1   (swap)
        bit 1  Sprites Above Frontmost Layer
        bit 2  the palette effect, blandia only -- Phase 5, popmessage here

    The BOTTOM layer of the pair is drawn TILEMAP_DRAW_OPAQUE and the top one
    transparently, whichever way round the swap puts them.
    """
    w, h = cfg["screen_w"], cfg["screen_h"]
    bmp = [[cfg["backdrop"]] * w for _ in range(h)]
    order = vregs

    # seta_layers_update: flip = m_spritegen->is_flipped() ^ m_tilemaps_flip.
    # THE LAYERS AND THE SPRITES DO NOT ALWAYS AGREE. oisipuzl is the only set
    # in scope whose machine_config calls set_tilemaps_flip(1) -- "flip is
    # inverted for the tilemaps" -- and its captured frame has the sprite
    # chip's flip bit SET, so the sprites are flipped and the layers are not.
    # Passing one flag to both put 94.9% of its pixels wrong.
    lflip = flip ^ bool(cfg.get("tilemaps_flip", 0))

    def sprites():
        if spr is not None:
            spr.draw_background(bmp)
            spr.draw_foreground(bmp)

    if order & 1:                       # layer 1 underneath
        _draw(cfg, l1, bmp, vis_dimy, lflip, True, cfg['l1_colorbase'])
        if order & 2:
            sprites()
            _draw(cfg, l0, bmp, vis_dimy, lflip, False, cfg['l0_colorbase'])
        else:
            _draw(cfg, l0, bmp, vis_dimy, flip, False, cfg['l0_colorbase'])
            sprites()
    else:                               # layer 0 underneath
        _draw(cfg, l0, bmp, vis_dimy, lflip, True, cfg['l0_colorbase'])
        if order & 2:
            sprites()
            _draw(cfg, l1, bmp, vis_dimy, lflip, False, cfg['l1_colorbase'])
        else:
            _draw(cfg, l1, bmp, vis_dimy, flip, False, cfg['l1_colorbase'])
            sprites()
    if order & 4:
        raise NotImplementedError(
            "vregs bit 2 is the blandia palette effect -- Phase 5")
    return bmp


def render(cfg, vram, vctrl, tiles, spr, vis_dimy, flip,
           bpp=4, colorbase_m1=None):
    """seta_layers_update for a ONE-layer game.

    m_layers[1] is absent, so `order` is 0 and the whole function collapses
    to: fill(0), layer 0 drawn OPAQUE, then the sprites. Nothing chooses a
    priority and nothing swaps.
    """
    layer = Layer(cfg, vram, vctrl, tiles, bpp, colorbase_m1)
    pm, colors = layer.pixmap()
    sx, sy = layer.scroll(vis_dimy, flip)
    base = cfg["gfx_colorbase"]
    gran = 64 if bpp == 6 else 16

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
            row[x] = base + colors[o] * gran + pm[o]

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
    ap.add_argument("--vregs", type=lambda v: int(v, 0), default=0,
                    help="m_vregs for a two-layer game: bit 0 layer order, "
                         "bit 1 sprites above the front layer. Write only, so "
                         "it comes from the capture's write log.")
    ap.add_argument("--no-sprites", action="store_true",
                    help="render the layer alone. Cannot be compared against "
                         "MAME, which always draws the sprites too")
    a = ap.parse_args()

    two = a.game in TWO_LAYER_GAMES
    if not two and a.game not in LAYER_GAMES:
        sys.exit(f"no layer config for '{a.game}'. Known: "
                 f"{', '.join(sorted(set(LAYER_GAMES) | set(TWO_LAYER_GAMES)))}")
    cfg = TWO_LAYER_GAMES[a.game] if two else LAYER_GAMES[a.game]
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

    if two:
        vram1 = _be16((cap / f"{tag}_l1vram.bin").read_bytes())
        vctrl1 = _be16((cap / f"{tag}_l1ctrl.bin").read_bytes())
        gfx3 = region_image(a.game, "gfx3")[0]
        tiles1 = decode_tiles(gfx3)
        print(f"  {len(tiles1)} tiles in gfx3 ({len(gfx3)} bytes)")

    code, ylow, ctrl, pal, _ = load_capture(cfg, cap, tag)
    gfx1 = region_image(a.game, "gfx1")[0]
    spr = None if a.no_sprites else Sprites(cfg, code, ylow, ctrl, gfx1)

    vis = cfg["visarea"]
    vis_dimy = vis[3] - vis[2] + 1
    flip = bool(ctrl[0] & 0x40)
    if two:
        # m_vregs, the X1-011 order register. It is WRITE ONLY, so it cannot be
        # dumped as a region -- take it from --vregs, or from the write log:
        #   awk '$3 ~ /50000[23]/ {print $4}' <capture>/<tag>_writes.log | tail -1
        l0 = Layer(dict(cfg, l0_xoffsets=cfg["l0_xoffsets"]), vram, vctrl, tiles)
        l1 = Layer(dict(cfg, l0_xoffsets=cfg["l1_xoffsets"]), vram1, vctrl1,
                   tiles1)
        bmp = render2(cfg, l0, l1, spr, vis_dimy, flip, a.vregs)
    else:
        bmp = render(cfg, vram, vctrl, tiles, spr, vis_dimy, flip)

    if a.png:
        write_png(a.png, to_rgb(bmp, pal, cfg))
        print(f"  wrote {a.png}")
    if a.compare:
        sys.exit(compare(bmp, pal, cfg, cap, tag))


if __name__ == "__main__":
    main()
