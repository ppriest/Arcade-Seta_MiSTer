#!/usr/bin/env python3
"""The X1-001/X1-002 sprite chip, transcribed from MAME, as a reference renderer.

    python scripts/mame_capture.py umanclub --frame 900 --name uc
    python scripts/x1_001_model.py umanclub debug/uc --png debug/uc/model.png

    python scripts/x1_001_model.py --selftest

This is to the sprite engine what x1_010_model.py is to the sound engine: a
line-by-line transcription of `src/devices/video/x1_001.cpp`, driven from a
capture of the real register state, whose output the RTL is required to match.
The RTL cannot be diffed against MAME directly -- MAME renders a whole frame
from C++ with a `gfx_element` -- so the model is the bridge, and the model
itself is checked against MAME's own screenshot of the same frame.

WHAT THE CHIP ACTUALLY DOES, and the parts that are easy to get wrong:

  TWO INDEPENDENT THINGS share it. `draw_background` renders a "floating
  tilemap" of 16 columns x 32 sprites from spritecode[0x400..0x7ff] with
  per-column scroll, and `draw_foreground` renders up to 512 ordinary sprites
  from spritecode[0x000..0x3ff]. Background first, so foreground is on top.

  THE TWO HALVES POSITION Y DIFFERENTLY, and this is not a tidying
  opportunity. Foreground draws at `max_y - ((sy + yoffs) & 0xff)`, where
  max_y is the screen HEIGHT (256 here, not the visible 240). Background draws
  at `(sy) & 0xff` with no such reflection, from `sy = -(scrolly + yoffs) +
  (offs/2)*16`. One is a mirror of the other and both are transcribed as
  written.

  FOREGROUND IS DRAWN HIGH INDEX FIRST (`for i = spritelimit; i >= 0; i--`),
  so entry 0 ends up on top. With no per-sprite priority anywhere in the chip,
  back-to-front overwrite reproduces it exactly.

  EVERY SPRITE IS DRAWN FOUR TIMES, at (x, y), (x-512, y), (x, y-256) and
  (x-512, y-256). Modulo the 512x256 bitmap those four are one draw at
  (x & 0x1ff, y & 0xff), which is how the RTL will do it, but the model draws
  all four the way MAME does so the two are not silently the same by
  construction.

  BACKGROUND TAKES NO COLORBASE AND NO BANK CALLBACK. Foreground applies both.
  Background ignores the gfx bank entirely, so it can only reach the first
  0x4000 tiles.

  THE BANK EXPRESSION IS `(ctrl2 ^ (~ctrl2 << 1)) & 0x40`, copied including
  its operators. LESSONS_LEARNED, "Copy a driver's register expression
  including its operators" -- this exact class of bug cost the Psikyo project a
  layer-enable polarity hunt.
"""
import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from decode_gfx import LAYOUTS, decode_tile, resolve_planes

# ---------------------------------------------------------------------------
# Per-game chip configuration, transcribed from each machine_config in
# seta.cpp. Every Group A board sets exactly the same kludges; they are listed
# per game anyway so a later game that differs cannot inherit a wrong value.
#
#   fg_xoffs/fg_yoffs/bg_xoffs/bg_yoffs   set_*_offsets(flip, noflip)
#   gfx_colorbase                         the GFXDECODE_ENTRY base
#   palette_entries                       PALETTE(...).set_entries()
#   bank_size                             the argument to draw_sprites()
#   backdrop                              bitmap.fill() before drawing
#
# colorbase (m_colorbase), spritelimit (0x1ff) and transpen (0) are the device
# defaults for every in-scope game -- no seta.cpp machine_config calls
# set_colorbase, set_spritelimit or set_transpen. Named here so that stays
# checkable rather than implicit.
# ---------------------------------------------------------------------------
_GROUP_A = dict(
    fg_xoffs=(0, 0), fg_yoffs=(-0x12, 0x0e),
    bg_xoffs=(0, 0), bg_yoffs=(0x1, -0x1),
    colorbase=0, spritelimit=0x1ff, transpen=0,
    gfx_colorbase=0x000, total_color_codes=32,
    palette_entries=512,
    # screen_update_seta_no_layers passes 0x1000 and fills with pen 0x1f0.
    bank_size=0x1000, backdrop=0x1f0,
    screen_w=512, screen_h=256,
    visarea=(0, 383, 8, 247),        # set_visarea(0*8, 48*8-1, 1*8, 31*8-1)
    rot=0,
)

GAMES = {
    "thunderl":  dict(_GROUP_A, rot=270),
    "thunderla": dict(_GROUP_A, rot=270),
    "wits":      dict(_GROUP_A, rot=0),
    "blockcar":  dict(_GROUP_A, rot=90),
    "umanclub":  dict(_GROUP_A, rot=0),
    "neobattl":  dict(_GROUP_A, rot=270),
    "atehate":   dict(_GROUP_A, rot=0),
    # gfx_pairlove puts the sprites at palette index 0x200 of 2048.
    "pairlove":  dict(_GROUP_A, rot=270, gfx_colorbase=0x200, palette_entries=2048),
}


def setac_gfxbank(code, color):
    """seta_state::setac_gfxbank_callback -- used by every in-scope game."""
    bank = (color & 0x06) >> 1
    return (code & 0x3fff) + bank * 0x4000


class Sprites:
    """One capture's worth of chip state, plus the sprite ROM."""

    def __init__(self, cfg, spritecode, spriteylow, spritectrl, gfx, bgflag=0):
        self.cfg = cfg
        self.code = spritecode         # 0x2000 uint16
        self.ylow = spriteylow         # 0x300 uint8
        self.ctrl = spritectrl         # 4 uint8
        self.gfx = gfx                 # the raw "gfx1" region
        self.bgflag = bgflag
        self.lay = LAYOUTS["sprites"]
        self.region_bits = len(gfx) * 8
        # charincrement is per HALF for RGN_FRAC(1,2): the region splits in
        # two and a tile takes 64 bytes from each half.
        self.ntiles = (len(gfx) // 2) // (self.lay["charinc"] // 8)
        self._tile_cache = {}

    # -- gfx ---------------------------------------------------------------
    def tile(self, index):
        """16x16 of 4-bit pens, [y][x]. decode_gfx implements MAME's
        gfx_layout semantics and is what proved this format offline."""
        index %= max(self.ntiles, 1)
        t = self._tile_cache.get(index)
        if t is None:
            t = decode_tile(self.gfx, self.lay, index, self.region_bits)
            self._tile_cache[index] = t
        return t

    def blit(self, bmp, code, color, flipx, flipy, sx, sy, transpen):
        """gfx_element::transpen, for a 16x16 tile at 16 pens per colour."""
        h = len(bmp)
        w = len(bmp[0])
        base = self.cfg["gfx_colorbase"] + color * 16
        t = self.tile(code)
        for ty in range(16):
            y = sy + ty
            if y < 0 or y >= h:
                continue
            row = t[15 - ty] if flipy else t[ty]
            line = bmp[y]
            for tx in range(16):
                x = sx + tx
                if x < 0 or x >= w:
                    continue
                pen = row[15 - tx] if flipx else row[tx]
                if pen == transpen:
                    continue
                line[x] = base + pen

    # -- x1_001.cpp --------------------------------------------------------
    def _bank(self):
        ctrl2 = self.ctrl[1]
        return self.cfg["bank_size"] if ((ctrl2 ^ (~ctrl2 << 1)) & 0x40) else 0

    def draw_background(self, bmp):
        cfg = self.cfg
        ctrl, ctrl2 = self.ctrl[0], self.ctrl[1]
        flip = (ctrl >> 6) & 1
        numcol = ctrl2 & 0x0f
        bank = self._bank()
        max_y = 0xf0

        startcol = 0
        if ctrl & 0x01:
            startcol += 0x4
        if ctrl & 0x02:
            startcol += 0x8

        xoffs = cfg["bg_xoffs"][0] if flip else cfg["bg_xoffs"][1]
        yoffs = cfg["bg_yoffs"][0] if flip else cfg["bg_yoffs"][1]
        transpen = -1 if (self.bgflag & 0x80) else cfg["transpen"]

        if numcol == 1:
            numcol = 16
        upper = self.ctrl[2] + self.ctrl[3] * 256
        scrollram = self.ylow[0x200:]

        for col in range(numcol):
            scrollx = scrollram[col * 0x10 + 4]
            scrolly = scrollram[col * 0x10]
            for offs in range(0x20):
                i = ((col + startcol) & 0xf) * 32 + offs
                code = self.code[i + 0x400 + bank]
                color = self.code[i + 0x600 + bank]

                flipx = code & 0x8000
                flipy = code & 0x4000

                sx = scrollx + xoffs + (offs & 1) * 16
                sy = -(scrolly + yoffs) + (offs // 2) * 16
                if upper & (1 << col):
                    sx -= 256
                if flip:
                    sy = max_y - sy
                    flipx = not flipx
                    flipy = not flipy

                color = (color >> (16 - 5)) % cfg["total_color_codes"]
                code &= 0x3fff

                for dx in (0, -512):
                    for dy in (0, -256):
                        self.blit(bmp, code, color, flipx, flipy,
                                  (sx & 0x1ff) + dx, (sy & 0x0ff) + dy, transpen)

    def draw_foreground(self, bmp):
        cfg = self.cfg
        screenflip = (self.ctrl[0] & 0x40) >> 6
        bank = self._bank()
        cp = 0x0000 + bank      # char_pointer
        xp = 0x0200 + bank      # x_pointer

        xoffs = cfg["fg_xoffs"][0] if screenflip else cfg["fg_xoffs"][1]
        yoffs = cfg["fg_yoffs"][0] if screenflip else cfg["fg_yoffs"][1]

        max_y = cfg["screen_h"]                 # screen.height()
        vis_max_y = cfg["visarea"][3]

        for i in range(cfg["spritelimit"], -1, -1):
            code = self.code[cp + i] & 0x3fff
            color = (self.code[xp + i] & 0xf800) >> 11
            sx = (self.code[xp + i] & 0x00ff) - (self.code[xp + i] & 0x0100)
            sy = self.ylow[i] & 0xff
            flipx = self.code[cp + i] & 0x8000
            flipy = self.code[cp + i] & 0x4000

            code = setac_gfxbank(code, (self.code[xp + i] >> 8) & 0xff)

            color %= cfg["total_color_codes"]
            color += cfg["colorbase"]

            if screenflip:
                sy = max_y - sy + (cfg["screen_h"] - (vis_max_y + 1))
                flipx = not flipx
                flipy = not flipy

            px = (sx + xoffs) & 0x1ff
            py = max_y - ((sy + yoffs) & 0x0ff)
            for dx in (0, -512):
                for dy in (0, -256):
                    self.blit(bmp, code, color, flipx, flipy,
                              px + dx, py + dy, cfg["transpen"])

    def render(self):
        """One frame of pen indices, 512x256, exactly as
        screen_update_seta_no_layers builds it."""
        cfg = self.cfg
        bmp = [[cfg["backdrop"]] * cfg["screen_w"] for _ in range(cfg["screen_h"])]
        self.draw_background(bmp)
        self.draw_foreground(bmp)
        return bmp


# ---------------------------------------------------------------------------
# Capture loading
# ---------------------------------------------------------------------------
def _be16(data):
    return list(struct.unpack(f">{len(data) // 2}H", data[:len(data) // 2 * 2]))


def load_capture(cfg, capdir, tag=None):
    """Read a scripts/mame_capture.py dump directory.

    capture.lua reads every region through the CPU program space a WORD at a
    time and writes big-endian, so a byte-wide array (spriteylow, spritectrl)
    arrives as one value per 16-bit word with the data in the low byte. That is
    what the CPU sees, which is the point -- these are device handlers, not
    plain memory.
    """
    capdir = Path(capdir)
    if tag is None:
        cands = sorted(capdir.glob("*_sprcode.bin"))
        if not cands:
            sys.exit(f"no *_sprcode.bin in {capdir}")
        tag = cands[0].name[:-len("_sprcode.bin")]

    def rd(name):
        p = capdir / f"{tag}_{name}.bin"
        if not p.exists():
            sys.exit(f"missing {p}")
        return p.read_bytes()

    code = _be16(rd("sprcode"))
    code += [0] * (0x2000 - len(code))

    ylow_words = _be16(rd("sprylow"))
    ylow = [w & 0xff for w in ylow_words]
    ylow += [0] * (0x300 - len(ylow))

    ctrl = [w & 0xff for w in _be16(rd("sprctrl"))][:4]
    ctrl += [0] * (4 - len(ctrl))

    pal = _be16(rd("palette"))
    pal += [0] * (cfg["palette_entries"] - len(pal))
    return code, ylow, ctrl, pal, tag


def to_rgb(bmp, pal, cfg, crop=True):
    """pal5bit, exactly as set_pens does: rgb_t(pal5bit(d>>10), pal5bit(d>>5), pal5bit(d))."""
    def p5(v):
        v &= 0x1f
        return (v << 3) | (v >> 2)

    x0, x1, y0, y1 = cfg["visarea"]
    rows = range(y0, y1 + 1) if crop else range(len(bmp))
    cols = range(x0, x1 + 1) if crop else range(len(bmp[0]))
    out = []
    for y in rows:
        row = []
        for x in cols:
            d = pal[bmp[y][x] % len(pal)]
            row.append((p5(d >> 10), p5(d >> 5), p5(d)))
        out.append(row)
    return out


def write_png(path, rgb):
    """A minimal PNG writer -- no Pillow dependency, same as gfx_sheet.py's."""
    import zlib
    h = len(rgb)
    w = len(rgb[0]) if h else 0
    raw = bytearray()
    for row in rgb:
        raw.append(0)
        for r, g, b in row:
            raw += bytes((r, g, b))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(png)
    return w, h


# ---------------------------------------------------------------------------
def selftest():
    """Checks that need no ROMs and no capture: the arithmetic, not the art.

    Each one is a property the RTL will implement differently (per scanline
    rather than per sprite) and must still satisfy, so they are worth pinning
    down before either exists.
    """
    fails = []

    # 1. The four wrap copies of a foreground sprite are, modulo the bitmap,
    #    a single draw at (x & 0x1ff, y & 0xff). The RTL relies on this.
    for x in (0, 15, 300, 497, 505, 511):
        got = {(x + dx) % 512 for dx in (0, -512) for _ in (0,)}
        assert got == {x % 512}, x

    # 2. A scanline test of the same thing in y, which is how the RTL will
    #    select sprites: with Y = (sy + yoffs) & 0xff and the sprite drawn at
    #    max_y - Y and 256 lower, line L is covered iff ((L + Y) & 0xff) < 16,
    #    and the row within the sprite is (L + Y) & 0x0f.
    max_y = 256
    for Y in range(256):
        for L in range(256):
            rows = set()
            for dy in (0, -256):
                top = max_y - Y + dy
                if 0 <= L - top < 16:
                    rows.add(L - top)
            pred = {(L + Y) & 0x0f} if ((L + Y) & 0xff) < 16 else set()
            if rows != pred:
                fails.append(f"fg scanline select Y={Y} L={L}: {rows} != {pred}")

    # 3. The background's opposite convention: drawn at S and S-256 with
    #    S = sy & 0xff, so line L is covered iff ((L - S) & 0xff) < 16.
    for S in range(256):
        for L in range(256):
            rows = set()
            for dy in (0, -256):
                top = S + dy
                if 0 <= L - top < 16:
                    rows.add(L - top)
            pred = {(L - S) & 0x0f} if ((L - S) & 0xff) < 16 else set()
            if rows != pred:
                fails.append(f"bg scanline select S={S} L={L}: {rows} != {pred}")

    # 4. THE BANK EXPRESSION IS NOT "BIT 6 OF ctrl2", which is what it looks
    #    like and what the first draft of this file assumed. Expanding it:
    #
    #        bit 6 of (~ctrl2 << 1)  =  NOT bit 5 of ctrl2
    #        bit 6 of the XOR        =  bit6 XOR (NOT bit5)
    #
    #    which is true exactly when BITS 6 AND 5 ARE EQUAL. So the second
    #    sprite bank is selected when they agree, not when bit 6 is set.
    #
    #    That reading is what the rest of the chip corroborates: setac_eof
    #    buffers only when `~ctrl2 & 0x20` (bit 5 CLEAR) and copies
    #    0x1000 -> 0x0000 when bit 6 is set. With bit 5 clear, "bits equal"
    #    means bit 6 clear means draw from 0x1000 -- the half just copied FROM
    #    -- and bit 6 set means draw from 0x0000, the half just copied TO. A
    #    double buffer, and it only works out with this reading.
    #
    #    thunderl's documented control bytes are `10 6c 00 ff`: ctrl2 = 0x6c
    #    has both bits SET, so it draws from 0x1000 and, bit 5 being set, never
    #    buffers at all. An implementation that took the expression for
    #    `ctrl2 & 0x40` would read the wrong half and draw an empty screen.
    for c2 in range(256):
        want = ((c2 ^ (~c2 << 1)) & 0x40) != 0
        if want != (((c2 >> 6) & 1) == ((c2 >> 5) & 1)):
            fails.append(f"bank expr ctrl2={c2:#04x}: not 'bits 6 and 5 equal'")
    #    And the two readings disagree for exactly the 128 values with bit 5
    #    clear -- i.e. for every value that also enables buffering.
    disagree = sum(1 for c2 in range(256)
                   if (((c2 ^ (~c2 << 1)) & 0x40) != 0) != bool(c2 & 0x40))
    if disagree != 128:
        fails.append(f"bank expr differs from `ctrl2 & 0x40` on {disagree} values, wanted 128")

    # 5. The gfx bank callback reaches all four 0x4000-tile banks and nothing else.
    seen = {setac_gfxbank(0, c) for c in range(256)}
    if seen != {0, 0x4000, 0x8000, 0xc000}:
        fails.append(f"gfxbank reaches {sorted(seen)}")

    # 6. layout_sprites maps 16*16*4 pixel-planes onto exactly that many
    #    DISTINCT bit offsets, with no gaps and no duplicates inside a tile --
    #    the structural check decode_gfx.py's layouts were verified with.
    #    Run per half, since RGN_FRAC(1,2) puts two planes in each.
    lay = LAYOUTS["sprites"]
    region_bits = 2 * 0x10000 * 8            # any region; only the split matters
    planeoffset = resolve_planes(lay["planeoffset"], region_bits)
    half_bits = region_bits // 2
    for which, lo in (("low", 0), ("high", half_bits)):
        offs = set()
        for y in range(16):
            for x in range(16):
                for p, po in enumerate(planeoffset):
                    if (po >= half_bits) != (lo == half_bits):
                        continue
                    offs.add(lay["yoffset"][y] + lay["xoffset"][x] + po - lo)
        if len(offs) != 16 * 16 * 2:
            fails.append(f"layout_sprites {which} half: {len(offs)} distinct "
                         f"bit offsets, wanted {16 * 16 * 2}")
        elif max(offs) + 1 != lay["charinc"] or min(offs) != 0:
            fails.append(f"layout_sprites {which} half spans {min(offs)}..{max(offs)}, "
                         f"wanted 0..{lay['charinc'] - 1}")

    # 7. The byte layout the RTL fetches with, derived from the same offsets:
    #    byte = 32*yh + 16*xh + 2*yl + p within a half, MSB = leftmost pixel.
    #    A sprite ROW is then four 16-bit words, two per half. Getting this
    #    wrong is a whole-screen garbage bug that still looks like artwork.
    for y in range(16):
        for x in range(16):
            for p, po in enumerate(planeoffset):
                b = (lay["yoffset"][y] + lay["xoffset"][x] + po) // 8
                hi = 1 if po >= half_bits else 0
                b -= hi * (half_bits // 8)
                want = 32 * (y >> 3) + 16 * (x >> 3) + 2 * (y & 7) + (1 - (p & 1))
                if b != want:
                    fails.append(f"byte layout y={y} x={x} p={p}: {b} != {want}")

    for f in fails[:10]:
        print("FAIL: " + f)
    if fails:
        print(f"FAIL: {len(fails)} problem(s)")
        return 1
    print("PASS: scanline selection, bank expression and gfx bank all check out")
    return 0


# MAME's snapshot is written through the render pipeline, which applies the
# cabinet orientation. Undoing it is not something to reason about -- it was
# MEASURED, over seven sets at 384x240, by rendering each frame and asking
# which rigid transform made it exact:
#
#   scr:orientation()   transform to get back to screen space
#   ----------------    ----------------------------------------
#         0             none        (wits, umanclub, atehate)
#        90             none        (blockcar)
#       270             180 degrees (thunderl, thunderla, neobattl, pairlove)
#
# Every one of those was exact under exactly one transform and no other, and
# `-snapview native` did not change any of them. 180 has no in-scope game and
# is therefore unknown rather than assumed.
#
# The first sweep applied a transform derived by reasoning instead, and every
# rotated game "failed" by 90-99% of pixels while every unrotated one passed --
# which reads exactly like a renderer bug in the games that happen to be
# vertical, and was not one. So compare() undoes the measured transform, and
# when that fails it says which transform WOULD have worked, so the next
# person gets a one-line diagnosis instead of the same afternoon.
SNAPSHOT_TRANSFORM = {0: None, 90: None, 270: "rot180"}


def _read_orientation(capdir, tag):
    p = Path(capdir) / f"{tag}_info.txt"
    if p.exists():
        for line in p.read_text().splitlines():
            if line.startswith("orientation"):
                v = line.split(None, 1)[1].strip()
                if v.isdigit():
                    return int(v)
    return None


def compare(bmp, pal, cfg, capdir, tag=None):
    """Diff against MAME's own render of the same frame.

    The reference is `reference.png` -- MAME's snapshot, taken in the same
    frame notifier that dumps the registers. That matters: video:snapshot()
    RE-RENDERS from the state that is live when it is called, which is the
    state the dumps in the same notifier read. scr:pixels() looks like the
    better reference -- no file, no encoder, screen space by construction --
    but it returns the bitmap MAME rendered at the end of the VISIBLE area, one
    vblank earlier, before the game's vblank handler rewrote sprite RAM.
    Measured over 24 frames: the snapshot differs from this model by 0 pixels
    everywhere, pixels() by up to 4.3%.

    The snapshot's orientation is dealt with by SNAPSHOT_TRANSFORM above.
    """
    from PIL import Image
    capdir = Path(capdir)
    ref_path = capdir / "reference.png"
    if not ref_path.exists():
        print(f"FAIL: no reference.png in {capdir} -- re-capture")
        return 1

    rgb = to_rgb(bmp, pal, cfg, crop=True)
    H, W = len(rgb), len(rgb[0])
    mine = Image.new("RGB", (W, H))
    mine.putdata([px for row in rgb for px in row])

    orient = _read_orientation(capdir, tag) if tag else None
    if orient is None:
        orient = cfg.get("rot", 0)
    if orient not in SNAPSHOT_TRANSFORM:
        print(f"FAIL: orientation {orient} has never been calibrated -- see "
              f"SNAPSHOT_TRANSFORM in {Path(__file__).name}")
        return 1
    if SNAPSHOT_TRANSFORM[orient] == "rot180":
        mine = mine.transpose(Image.ROTATE_180)

    ref = Image.open(ref_path).convert("RGB")
    if ref.size != mine.size:
        print(f"FAIL: MAME's snapshot is {ref.size}, the model renders {mine.size}")
        return 1
    pr, pm = ref.load(), mine.load()
    bad, first = 0, None
    for y in range(H):
        for x in range(W):
            if pr[x, y] != pm[x, y]:
                bad += 1
                if first is None:
                    first = (x, y, pr[x, y], pm[x, y])
    if not bad:
        print(f"PASS: {W}x{H} pixels identical to MAME's own render of this frame")
        return 0

    # Before blaming the renderer, say whether this is the orientation table
    # being out of date -- which looks identical from the pixel count alone.
    alt = []
    for name, t in (("none", None), ("flipX", Image.FLIP_LEFT_RIGHT),
                    ("flipY", Image.FLIP_TOP_BOTTOM), ("rot180", Image.ROTATE_180)):
        q = mine if t is None else mine.transpose(t)
        pq = q.load()
        if not any(pr[x, y] != pq[x, y] for y in range(H) for x in range(W)):
            alt.append(name)
    print(f"FAIL: {bad} of {W * H} pixels differ ({100.0 * bad / (W * H):.2f}%); "
          f"first at {first[0]},{first[1]}: MAME {first[2]} model {first[3]}")
    if alt:
        print(f"      ...but a further {'/'.join(alt)} of the model IS exact. "
              f"This is SNAPSHOT_TRANSFORM[{orient}] being wrong, not the renderer.")
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game", nargs="?")
    ap.add_argument("capdir", nargs="?", help="a scripts/mame_capture.py output directory")
    ap.add_argument("--tag", help="capture tag (default: inferred from the files)")
    ap.add_argument("--gfx", help="pre-built gfx1 image (default: built from roms/)")
    ap.add_argument("--png", help="write the rendered frame here")
    ap.add_argument("--raw", help="write the 512x256 pen indices here, one byte per pixel")
    ap.add_argument("--full", action="store_true",
                    help="render the whole 512x256 bitmap, not just the visible area")
    ap.add_argument("--compare", action="store_true",
                    help="diff the rendered frame against MAME's own render of "
                         "it (the capture directory's *_screen.bin)")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        return selftest()
    if not a.game or not a.capdir:
        ap.error("need a game and a capture directory (or --selftest)")
    if a.game not in GAMES:
        sys.exit(f"{a.game}: not configured here. Games: {', '.join(sorted(GAMES))}")
    cfg = GAMES[a.game]

    if a.gfx:
        gfx = Path(a.gfx).read_bytes()
    else:
        from build_region import region_image
        gfx, _, zippath = region_image(a.game, "gfx1")
        print(f"gfx1 {len(gfx):#x} bytes from {zippath}")

    code, ylow, ctrl, pal, tag = load_capture(cfg, a.capdir, a.tag)
    print(f"capture {tag}: spritectrl {' '.join(f'{c:02x}' for c in ctrl)}"
          f"  bank {'1' if ((ctrl[1] ^ (~ctrl[1] << 1)) & 0x40) else '0'}"
          f"  numcol {ctrl[1] & 0x0f}")

    spr = Sprites(cfg, code, ylow, ctrl, gfx)
    print(f"  {spr.ntiles} tiles in the region")
    bmp = spr.render()

    if a.raw:
        Path(a.raw).parent.mkdir(parents=True, exist_ok=True)
        Path(a.raw).write_bytes(bytes(
            v & 0xff for row in bmp for v in row))
        print(f"  wrote {a.raw} (512x256, low byte of the pen index)")
    if a.png:
        w, h = write_png(a.png, to_rgb(bmp, pal, cfg, crop=not a.full))
        print(f"  wrote {a.png} ({w}x{h})")
    if a.compare:
        return compare(bmp, pal, cfg, a.capdir, tag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
