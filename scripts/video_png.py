#!/usr/bin/env python3
"""Turn tb_video's composed frame into a PNG and DIFF it against MAME's.

    python scripts/video_png.py [capture-dir]

tb_video writes raw xRGB-555 palette values, so this is a direct conversion --
no palette lookup, no interpretation. The reference is the screenshot MAME
rendered from exactly the state the testbench was fed, which makes this a
pixel-for-pixel comparison rather than a judgement call.

Outputs sim/tilemap_tb/frame_rgb.png and, when the two differ,
frame_diff.png marking every mismatched pixel.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs sim/video_tb/ output, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import sys
from pathlib import Path
from PIL import Image

cap = Path(sys.argv[1] if len(sys.argv) > 1 else "debug/thunderl-title")
d = Path("sim/tilemap_tb")
W, H = 320, 240

rows = (d / "frame_rgb.txt").read_text().split("\n")
img = Image.new("RGB", (W, H))
for y in range(H):
    vals = rows[y].split()
    for x in range(W):
        v = int(vals[x], 16)
        r, g, b = (v >> 10) & 31, (v >> 5) & 31, v & 31
        img.putpixel((x, y), (r << 3 | r >> 2, g << 3 | g >> 2, b << 3 | b >> 2))
img.save(d / "frame_rgb.png")

ref_path = next((p for p in (cap / "reference.png", cap / "0000.png") if p.exists()), None)
if ref_path is None:
    print(f"{d/'frame_rgb.png'} written; no reference image in {cap}")
    sys.exit(0)

ref = Image.open(ref_path).convert("RGB")
if ref.size != (W, H):
    print(f"reference is {ref.size}, expected {(W, H)} -- not comparing")
    sys.exit(0)

diff = Image.new("RGB", (W, H))
bad = 0
for y in range(H):
    for x in range(W):
        a, b = img.getpixel((x, y)), ref.getpixel((x, y))
        if a == b:
            diff.putpixel((x, y), (a[0] // 3, a[1] // 3, a[2] // 3))
        else:
            diff.putpixel((x, y), (255, 0, 255))
            bad += 1

total = W * H
print(f"reference: {ref_path}")
print(f"MATCH: {total - bad}/{total} pixels ({100.0 * (total - bad) / total:.3f}%)")
if bad:
    diff.save(d / "frame_diff.png")
    print(f"  {bad} differing pixels marked in {d/'frame_diff.png'}")
else:
    print("  PIXEL-PERFECT")
