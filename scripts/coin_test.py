#!/usr/bin/env python3
"""Coin 1 pulses of several lengths in MAME, one snapshot each.

    python scripts/coin_test.py twineagl downtown [--at 600] [--count 3]

Each case runs the set headless (scripts/mame/coin.lua), holds Coin 1 for
HOLD frames COUNT times with GAP frames between, and snapshots the screen
(debug/coin/<set>/<hold>_<gap>.png) to read the credit count off.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import MAME_DIR, MAME_EXE, NO_WINDOW, rompath  # noqa: E402

# (hold, gap) in frames: MAME's PORT_IMPULSE(5), a quick tap, a normal press,
# a long press, and quick repeats
CASES = [(5, 60), (2, 60), (10, 60), (30, 60), (120, 60), (5, 10)]


def run(game, hold, gap, at, count):
    out = REPO / "debug" / "coin" / game
    snaps = out / f"snap_{hold}_{gap}"
    shutil.rmtree(snaps, ignore_errors=True)
    env = dict(os.environ, CN_AT=str(at), CN_HOLD=str(hold), CN_GAP=str(gap),
               CN_COUNT=str(count), CN_SNAP="120")
    subprocess.run([str(MAME_EXE), game, "-skip_gameinfo", "-nodebug", "-nothrottle",
                    "-sound", "none", "-video", "none", "-nowindow",
                    "-autoboot_delay", "0",
                    "-autoboot_script", (REPO / "scripts" / "mame" / "coin.lua").as_posix(),
                    "-rompath", rompath(REPO),
                    "-snapshot_directory", snaps.as_posix(), "-snapview", "native"],
                   cwd=str(MAME_DIR), env=env, capture_output=True, timeout=600, **NO_WINDOW)
    pngs = sorted(snaps.rglob("*.png"))
    if not pngs:
        return None
    dst = out / f"{hold}_{gap}.png"
    shutil.copy(pngs[-1], dst)
    shutil.rmtree(snaps, ignore_errors=True)
    return dst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="+")
    ap.add_argument("--at", type=int, default=600)
    ap.add_argument("--count", type=int, default=3)
    a = ap.parse_args()
    for g in a.sets:
        for hold, gap in CASES:
            p = run(g, hold, gap, a.at, a.count)
            print(f"{g} hold {hold:3d} gap {gap:3d}: {p or 'no snapshot'}")


if __name__ == "__main__":
    sys.exit(main())
