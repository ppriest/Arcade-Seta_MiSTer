#!/usr/bin/env python3
"""Turn tb_tilemap's rendered frame into a PNG, using the CAPTURED palette.

    python scripts/tilemap_png.py 2

Unlike scripts/gfx_sheet.py, this uses the game's REAL colours: the palette
came from the same captured MAME frame as the VRAM, so the output is directly
comparable to the screenshot MAME produced. Transparent pixels are drawn as a
checkerboard, because a single layer on its own is mostly transparent and a
black background would hide the difference between "transparent" and "black".

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs sim/tilemap_tb/ output, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import sys
from pathlib import Path
from PIL import Image

layer = int(sys.argv[1]) if len(sys.argv) > 1 else 2
d = Path("sim/tilemap_tb")
pal_raw = (d / "palette.bin").read_bytes()
rows = (d / f"frame_l{layer}.txt").read_text().split("\n")

# Palette is xRGB-555, big-endian words.
def rgb(i):
    v = (pal_raw[2*i] << 8) | pal_raw[2*i + 1]
    r, g, b = (v >> 10) & 31, (v >> 5) & 31, v & 31
    return (r << 3 | r >> 2, g << 3 | g >> 2, b << 3 | b >> 2)

W, H = 320, 240
img = Image.new("RGB", (W, H))
opaque = 0
for y in range(H):
    vals = rows[y].split()
    for x in range(W):
        v = int(vals[x], 16)
        if v & 0x2000:                       # opaque bit
            img.putpixel((x, y), rgb(v & 0x1FFF))
            opaque += 1
        else:
            s = 80 if ((x >> 3) ^ (y >> 3)) & 1 else 55
            img.putpixel((x, y), (s, s, s))

out = d / f"frame_l{layer}.png"
img.resize((W * 2, H * 2), Image.NEAREST).save(out)
print(f"{out}: {opaque} opaque of {W*H} pixels")
