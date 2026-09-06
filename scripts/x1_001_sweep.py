#!/usr/bin/env python3
"""Check scripts/x1_001_model.py against MAME's own render, over every Group A
set and several frames each.

    python scripts/x1_001_sweep.py                    # every configured game
    python scripts/x1_001_sweep.py thunderl atehate   # just these
    python scripts/x1_001_sweep.py --frames 300,900,1800

One capture is not a test. A single frame can agree by accident -- an empty
attract screen with everything transparent will match any renderer at all -- so
the sweep takes several frames per game and reports the sprite population it
actually exercised. A frame that turns out to draw nothing is called out rather
than counted as a pass.

Each frame is a full round trip: MAME runs the real ROM to that frame, dumps
the chip state the CPU can see, and re-renders its own picture of that exact
state; the model renders it too and the two must be identical, pixel for
pixel. Which of MAME's two available bitmaps is the right reference, and in
what orientation, is not obvious and is documented in x1_001_model.compare --
both readings cost a sweep.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from x1_001_model import GAMES, Sprites, load_capture, compare
from build_region import region_image

DEFAULT_FRAMES = (300, 900, 1800)


def population(spr):
    """How much of the frame the model actually drew, so a vacuous pass shows."""
    cfg = spr.cfg
    bank = spr._bank()
    fg = sum(1 for i in range(cfg["spritelimit"] + 1)
             if (spr.code[0x0000 + bank + i] & 0x3fff) != 0)
    ctrl2 = spr.ctrl[1]
    numcol = ctrl2 & 0x0f
    numcol = 16 if numcol == 1 else numcol
    return fg, numcol


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("games", nargs="*", default=None)
    ap.add_argument("--frames", default=",".join(str(f) for f in DEFAULT_FRAMES))
    ap.add_argument("--flip", action="store_true",
                    help="capture with the Flip Screen DIP ON. NO GAME SETS IT "
                         "BY ITSELF -- every ordinary capture has spritectrl[0] "
                         "bit 6 clear, so the flipped half of the sprite Y "
                         "arithmetic is otherwise never compared against MAME "
                         "at all. Captures land in debug/flip-<game>-f<frame>.")
    ap.add_argument("--keep", action="store_true",
                    help="keep the capture directories (default: they are kept "
                         "anyway; this flag exists so the intent is explicit)")
    a = ap.parse_args()

    games = a.games or sorted(GAMES)
    frames = [int(f) for f in a.frames.split(",")]

    gfx_cache = {}
    rows, fails = [], 0
    for game in games:
        if game not in GAMES:
            print(f"SKIP {game}: not configured in x1_001_model.GAMES")
            continue
        cfg = GAMES[game]
        if game not in gfx_cache:
            gfx_cache[game] = region_image(game, "gfx1")[0]
        gfx = gfx_cache[game]

        for frame in frames:
            name = (f"flip-{game}-f{frame}" if a.flip
                    else f"sweep-{game}-f{frame}")
            out = REPO / "debug" / name
            ref = out / "reference.png"
            if not ref.exists():
                r = subprocess.run(
                    [sys.executable, str(REPO / "scripts" / "mame_capture.py"),
                     game, "--frame", str(frame), "--name", name]
                    + (["--dip", "Flip Screen=On"] if a.flip else []),
                    cwd=REPO, capture_output=True, text=True)
                if r.returncode != 0 or not ref.exists():
                    print(f"FAIL {game} f{frame}: capture failed")
                    print("   " + (r.stdout or r.stderr).strip().splitlines()[-1:][0]
                          if (r.stdout or r.stderr).strip() else "")
                    fails += 1
                    continue

            code, ylow, ctrl, pal, _ = load_capture(cfg, out)

            # --flip MUST BE CHECKED, NOT TRUSTED. Setting the DIP is not the
            # same as the game acting on it: most of these read the switches
            # once during power-on init, so a DIP applied from the autoboot
            # script arrives too late. The first run of this option produced
            # six unflipped captures out of seven and reported PASS for all of
            # them -- a test that proves nothing while looking like coverage.
            if a.flip and not (ctrl[0] & 0x40):
                print(f"FAIL {game} f{frame}: --flip asked for flip screen but "
                      f"spritectrl[0] is 0x{ctrl[0]:02x}, bit 6 clear. The game "
                      f"did not act on the DIP; this capture proves nothing.")
                fails += 1
                continue
            spr = Sprites(cfg, code, ylow, ctrl, gfx)
            bmp = spr.render()
            fg, numcol = population(spr)
            print(f"--- {game} frame {frame}: ctrl "
                  f"{' '.join(f'{c:02x}' for c in ctrl)}, {fg} fg sprites, "
                  f"{numcol} bg columns")
            rc = compare(bmp, pal, cfg, out, game)
            if rc:
                fails += 1
            elif fg == 0 and numcol == 0:
                print("     (vacuous: nothing was drawn -- this frame proves nothing)")
            rows.append((game, frame, fg, numcol, rc == 0))

    print()
    drawn = sum(1 for r in rows if r[4] and (r[2] or r[3]))
    print(f"{sum(1 for r in rows if r[4])} of {len(rows)} frames identical to MAME, "
          f"{drawn} of them with sprites on screen")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
