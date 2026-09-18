#!/usr/bin/env python3
"""What each set does with the X1-001's control bytes, in MAME.

    python scripts/sprctrl_scan.py [set ...] [--skip 600] [--frames 900] [--coin N]

Runs each set headless (scripts/mame/sprctrl.lua) and records every write to
the four control bytes: the values written, how many frames the copy is
disabled (byte 1 bit 5 set), and every write that flips byte 1 bit 6 -- the
half the chip draws from -- while the copy is off. A game that does that owns
its double buffer, and x1_001.sv takes its sprite snapshot on that write
(docs/MAME_DIVERGENCE.md, "Strike Gunner: the game's own page flip takes the
snapshot").
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import FAMILIES, GAMES, MAME_DIR, MAME_EXE, NO_WINDOW, rompath  # noqa: E402
from write_timing import PARENTS_ONLY  # noqa: E402


def run(game, skip, frames, coin, tag):
    out = REPO / "debug" / "sprctrl" / f"{game}{tag}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    base = FAMILIES[GAMES[game]][0]["sprctrl"][0]
    env = dict(os.environ, SC_OUT=out.as_posix(), SC_BASE=f"{base:06x}",
               SC_SKIP=str(skip), SC_FRAMES=str(frames), SC_COIN=str(coin))
    subprocess.run([str(MAME_EXE), game, "-skip_gameinfo", "-nodebug", "-nothrottle",
                    "-sound", "none", "-video", "none", "-nowindow",
                    "-autoboot_delay", "0",
                    "-autoboot_script", (REPO / "scripts" / "mame" / "sprctrl.lua").as_posix(),
                    "-rompath", rompath(REPO)],
                   cwd=str(MAME_DIR), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    return out


def parse(path):
    d = {"val": {0: {}, 1: {}, 2: {}, 3: {}}, "flip": {}}
    for line in path.read_text().splitlines():
        f = line.split()
        if f[0] == "val":
            d["val"][int(f[1])][int(f[2], 16)] = int(f[3])
        elif f[0] == "flip":
            d["flip"][int(f[1])] = int(f[2])
        else:
            d[f[0]] = int(f[1])
    return d


def report(label, d):
    nf = d["frames"]
    c1 = d["val"][1]
    vals = " ".join(f"{v:02x}x{n}" for v, n in sorted(c1.items()))
    flips = sum(d["flip"].values())
    lines = ",".join(str(l) for l in sorted(d["flip"])) if d["flip"] else "-"
    print(f"{label}: {nf} frames, copy off (bit 5) on {d['bit5frames']} frames, "
          f"{flips} page flips" + (f" at lines {lines}" if d["flip"] else ""))
    print(f"  byte 1 written: {vals or '(never)'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=900)
    ap.add_argument("--coin", type=int, default=0)
    ap.add_argument("--tag", default="")
    ap.add_argument("--reuse", action="store_true")
    a = ap.parse_args()
    for g in a.sets or PARENTS_ONLY:
        path = REPO / "debug" / "sprctrl" / f"{g}{a.tag}.txt"
        if not a.reuse or not path.exists():
            run(g, a.skip, a.frames, a.coin, a.tag)
        if not path.exists():
            print(f"{g}: no result (MAME failed?)")
            continue
        report(f"{g}{a.tag}", parse(path))


if __name__ == "__main__":
    sys.exit(main())
