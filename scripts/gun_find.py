#!/usr/bin/env python3
"""Where does zombraid keep the aim position it draws its crosshair at?

    python scripts/gun_find.py            # run MAME, then diff
    python scripts/gun_find.py --no-run   # diff an existing debug/zombraid-gunfind

Runs scripts/mame/gunfind.lua headless: coin, start, then the P1 gun held at a
sequence of positions with work RAM, sprite code RAM and sprite Y-low dumped at
the end of each hold, plus a snapshot. Then reports every 16-bit word (and byte)
whose value moved with X only, with Y only, or with both -- the candidates for
the game's own computed crosshair position, which is what the core's overlay
should follow rather than the raw ADC value.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import MAME_DIR, MAME_EXE, rompath, NO_WINDOW  # noqa: E402

# (GUNX1, GUNY1, dump frame). Two X values at each of two Y values, and the
# centre, so a word that follows X, Y or both can be told apart. Held long
# enough that the game has read the ADC and redrawn several times.
SEQ = [(0x40, 0x40, 700), (0xC0, 0x40, 800), (0x40, 0xC0, 900),
       (0xC0, 0xC0, 1000), (0x80, 0x80, 1100)]


def run(out, p2=False):
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    env = dict(os.environ)
    env.update(
        SETA_OUT=out.as_posix(), SETA_TAG="zombraid",
        SETA_GUNSEQ=";".join(f"{x},{y},{f}" for x, y, f in SEQ),
        SETA_COIN_FRAME="200", SETA_START_FRAME="300", SETA_GUN_P2="1" if p2 else "0",
        SETA_SCRIPT=(REPO / "scripts" / "mame" / "gunfind.lua").as_posix(),
    )
    cmd = [str(MAME_EXE), "zombraid", "-skip_gameinfo", "-nodebug", "-nothrottle",
           "-sound", "none", "-video", "none", "-nowindow",
           "-autoboot_delay", "0",
           "-autoboot_script", (REPO / "scripts" / "mame" / "run.lua").as_posix(),
           "-snapshot_directory", out.as_posix(), "-snapview", "native",
           "-rompath", rompath(REPO),
           "-seconds_to_run", str(SEQ[-1][2] // 60 + 20)]
    r = subprocess.run(cmd, cwd=str(MAME_DIR), env=env, **NO_WINDOW,
                       capture_output=True, text=True, timeout=900)
    for line in (r.stdout or "").splitlines():
        if line.startswith("GUN") or line.startswith("LUAFAIL"):
            print("  " + line)
    err = out / "lua_error.txt"
    if err.exists():
        sys.exit("lua: " + err.read_text().strip())


def load(out, region):
    dumps = {}
    for i, (x, y, _) in enumerate(SEQ, 1):
        p = out / f"zombraid_s{i}_x{x:02x}_y{y:02x}_{region}.bin"
        if not p.exists():
            sys.exit(f"missing {p.name}")
        dumps[(x, y)] = p.read_bytes()
    return dumps


def words(d, i):
    return int.from_bytes(d[i:i + 2], "big")


def report(out, region, base):
    d = load(out, region)
    a, b, c, e, m = d[(0x40, 0x40)], d[(0xC0, 0x40)], d[(0x40, 0xC0)], d[(0xC0, 0xC0)], d[(0x80, 0x80)]
    n = len(a)
    x_only, y_only, both = [], [], []
    for i in range(0, n - 1, 2):
        va, vb, vc, ve, vm = (words(v, i) for v in (a, b, c, e, m))
        fx = (va != vb) and (vc != ve)          # X moved it at both Y
        fy = (va != vc) and (vb != ve)          # Y moved it at both X
        sx = (va == vc) and (vb == ve)          # Y did not
        sy = (va == vb) and (vc == ve)          # X did not
        if fx and sx and not fy:
            x_only.append((i, va, vb, vm))
        elif fy and sy and not fx:
            y_only.append((i, va, vc, vm))
        elif fx and fy:
            both.append((i, va, vb, vc, ve, vm))
    print(f"\n{region} @ {base:06x}: {len(x_only)} X-only, {len(y_only)} Y-only, "
          f"{len(both)} X-and-Y words")
    for i, va, vb, vm in x_only[:40]:
        print(f"  X  {base + i:06x}: x40={va:04x} xc0={vb:04x} centre={vm:04x}")
    for i, va, vc, vm in y_only[:40]:
        print(f"  Y  {base + i:06x}: y40={va:04x} yc0={vc:04x} centre={vm:04x}")
    for i, va, vb, vc, ve, vm in both[:40]:
        print(f"  XY {base + i:06x}: (40,40)={va:04x} (c0,40)={vb:04x} "
              f"(40,c0)={vc:04x} (c0,c0)={ve:04x} centre={vm:04x}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-run", action="store_true")
    ap.add_argument("--p2", action="store_true", help="drive the P2 gun and start a 2-player game")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    out = Path(a.out or (REPO / "debug" / ("zombraid-gunfind-p2" if a.p2 else "zombraid-gunfind")))
    if not a.no_run:
        run(out, a.p2)
    for region, base in (("workram", 0x200000), ("sprcode", 0xB00000), ("sprylow", 0xA00000)):
        report(out, region, base)


if __name__ == "__main__":
    main()
