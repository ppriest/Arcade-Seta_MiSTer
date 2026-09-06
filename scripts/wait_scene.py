#!/usr/bin/env python3
"""Poll screenshots until the frame matches a reference crop, then hold the
CPU paused (JTAG source bit 5) so memdump.py --live --pause can read that
exact scene.

    python scripts/wait_scene.py debug/hw/attract/gundhara_s5.png --crop 0,0,80,64 --timeout 240

The crop is compared by mean absolute pixel difference; the default
threshold suits a static element (a portrait, a logo). Prints the matching
screenshot's path and leaves the pause asserted; release with
`quartus_stp -t scripts/read_issp.tcl set 0`.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs a running core on a MiSTer, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from tracer_readout import issp   # noqa: E402

HW = REPO / "scripts" / "hw.py"
OUT = REPO / "debug" / "hw" / "scene"


def diff(a, b, box):
    d = ImageChops.difference(a.crop(box), b.crop(box)).convert("L")
    return ImageStat.Stat(d).mean[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("--crop", default="0,0,80,64", help="x,y,w,h of the region that identifies the scene")
    ap.add_argument("--threshold", type=float, default=6.0)
    ap.add_argument("--timeout", type=float, default=240)
    ap.add_argument("--every", type=float, default=1.0, help="settle between polls (the screenshot itself takes ~5 s)")
    a = ap.parse_args()
    x, y, w, h = (int(v) for v in a.crop.split(","))
    box = (x, y, x + w, y + h)
    ref = Image.open(a.reference).convert("RGB")
    OUT.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    n = 0
    while time.time() - t0 < a.timeout:
        n += 1
        png = OUT / f"poll_{n:03d}.png"
        subprocess.run([sys.executable, str(HW), "shot", "--out", str(png), "--settle", str(a.every)],
                       capture_output=True, cwd=str(REPO))
        if not png.exists():
            continue
        m = diff(Image.open(png).convert("RGB"), ref, box)
        print(f"  t={time.time()-t0:5.0f}s poll {n}: crop diff {m:5.1f}")
        if m < a.threshold:
            issp("set", 0x20)                       # pause, held
            time.sleep(0.5)
            subprocess.run([sys.executable, str(HW), "shot", "--out", str(OUT / "matched.png"), "--settle", "0.5"],
                           capture_output=True, cwd=str(REPO))
            print(f"MATCHED at poll {n}; CPU paused. Scene: {OUT / 'matched.png'}")
            return 0
    print("no match before the timeout; not paused")
    return 1


if __name__ == "__main__":
    sys.exit(main())
