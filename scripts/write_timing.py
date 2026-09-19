#!/usr/bin/env python3
"""When each game writes its video RAM, relative to vblank, in MAME.

    python scripts/write_timing.py [set ...] [--skip 600] [--frames 1800]

Runs each set headless (scripts/mame/wtiming.lua) and counts writes to sprite
Y, sprite control, sprite code/X and each tile layer's VRAM and control, by
scanline, over --frames frames of attract after --skip. Regions come from
mame_capture.py's FAMILIES. Results: debug/wtiming/<set>.txt (raw) and a table
of, per region, where the writes fall relative to vblank start (MAME's line
numbers and frame length; see report()).
"""
import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import FAMILIES, GAMES, MAME_DIR, MAME_EXE, NO_WINDOW, rompath  # noqa: E402

REGIONS = ("sprylow", "sprctrl", "sprcode", "l0vram", "l1vram", "l0ctrl", "l1ctrl")
PARENTS_ONLY = ("thunderl", "wits", "blockcar", "umanclub", "neobattl", "atehate",
                "pairlove", "drgnunit", "stg", "qzkklogy", "qzkklgy2", "daioh",
                "rezon", "wrofaero", "msgundam", "eightfrc", "oisipuzl", "kamenrid",
                "magspeed", "gundhara", "zingzip", "jjsquawk", "extdwnhl", "sokonuke",
                "madshark", "blandia", "zombraid",
                "downtown", "twineagl", "metafox", "arbalest")


def run(game, skip, frames, coin=0, tag="", extra=""):
    out = REPO / "debug" / "wtiming" / f"{game}{tag}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    regions = FAMILIES[GAMES[game]][0]
    taps = ",".join(f"{r}:{lo:06x}:{lo + ln - 1:06x}" for r, (lo, ln) in regions.items()
                    if r in REGIONS)
    if extra:
        taps += "," + extra
    env = dict(os.environ, WT_OUT=out.as_posix(), WT_TAPS=taps,
               WT_SKIP=str(skip), WT_FRAMES=str(frames), WT_COIN=str(coin), WT_SNAP="1")
    subprocess.run([str(MAME_EXE), game, "-skip_gameinfo", "-nodebug", "-nothrottle",
                    "-sound", "none", "-video", "none", "-nowindow",
                    "-autoboot_delay", "0",
                    "-autoboot_script", (REPO / "scripts" / "mame" / "wtiming.lua").as_posix(),
                    "-rompath", rompath(REPO),
                    "-snapshot_directory", (REPO / "debug" / "wtiming" / f"snap{tag}").as_posix(),
                    "-snapview", "native"],
                   cwd=str(MAME_DIR), env=env, capture_output=True, timeout=3600, **NO_WINDOW)
    return out


def parse(path):
    d = {"hist": {}, "last": {}}
    for line in path.read_text().splitlines():
        k, _, v = line.partition(" ")
        if k in ("vtotal", "vbstart", "frames"):
            d[k] = int(v)
        else:
            name, _, vals = v.partition(" ")
            d[k][name] = [int(x) for x in vals.split(",")]
    return d


def report(game, d):
    """Per region: writes a frame; the share of them in the first 2 lines
    after vblank start (where the core copies and snapshots sprites), in
    MAME's vblank, and in the first 24 lines (the core's 272-line frame has 24
    lines of vblank); and a strip of 8-line buckets from vblank start (' '
    none, '.' under 1%, 0-9 tenths, '#' over 90% of the region's writes)."""
    vt, vb, nf = d["vtotal"], d["vbstart"], d["frames"]
    blank = (vt - vb) % vt
    print(f"{game}: {vt} lines, vblank start {vb} ({blank} lines of vblank), {nf} frames")
    print(f"  {'region':8s} {'/frame':>7s} {'+0..1':>6s} {'vblank':>6s} {'+0..23':>6s}  "
          f"from vblank start, 8 lines a column")
    for name, h in d["hist"].items():
        total = sum(h)
        if not total:
            continue
        rel = [h[(i + vb) % vt] for i in range(vt)]
        strip = ""
        for b in range(0, vt, 8):
            f = sum(rel[b:b + 8]) / total
            strip += " " if f == 0 else "." if f < 0.01 else "#" if f > 0.9 else str(min(9, int(f * 10)))
        pct = lambda n: 100.0 * sum(rel[:n]) / total
        print(f"  {name:8s} {total / nf:7.1f} {pct(2):5.1f}% {pct(blank):5.1f}% {pct(24):5.1f}%  "
              f"|{strip}|")
    print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*")
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--coin", type=int, default=0,
                    help="insert a coin at this frame and play (P1 Right held, "
                         "Button 1 pulsed); counting still starts at --skip")
    ap.add_argument("--extra", default="",
                    help="more taps, name:hexlo:hexhi[,...] (twineagl's tile "
                         "bank: tbank:400000:400007)")
    ap.add_argument("--tag", default="", help="suffix for the result file")
    ap.add_argument("--reuse", action="store_true", help="report existing results only")
    a = ap.parse_args()
    for g in a.sets or PARENTS_ONLY:
        path = REPO / "debug" / "wtiming" / f"{g}{a.tag}.txt"
        if not a.reuse or not path.exists():
            run(g, a.skip, a.frames, a.coin, a.tag, a.extra)
        if not path.exists():
            print(f"{g}: no result (MAME failed?)\n")
            continue
        label = f"{g}{a.tag}" + (f" (coin at frame {a.coin})" if a.coin else "")
        report(label, parse(path))


if __name__ == "__main__":
    sys.exit(main())
