#!/usr/bin/env python3
"""Run sim/seta_video_tb over every captured frame: the whole video path
against MAME's own render, in RGB.

    python scripts/video_sweep.py                 # every capture found
    python scripts/video_sweep.py --lat 12,24
    python scripts/video_sweep.py --games umanclub,wits

scripts/x1_001_rtl_sweep.py checks the sprite engine against the model in pen
indices. This checks the picture: timing generator, line-buffer readout,
palette decode, and the double-buffer cadence, sampled the way the MiSTer
framework samples it (on vga_ce with vga_de high) rather than by reaching into
the line buffer.

THE LINE BUDGET IS ON BY DEFAULT here, unlike the sprite sweep. There it is off
so the RTL and the model render the same unbounded picture; here the reference
is MAME and the engine has exactly one real line to work in, so the budget is
what the hardware will actually run with. 6100 rather than the full 6144 so the
engine reaches its done state and idles before the buffers swap -- at exactly
6144 the cutoff and the swap race, and the overrun path restarts the engine
mid-render instead of stopping it cleanly.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from x1_001_model import GAMES

# 512 dots x 12 clk_sys cycles, less a margin so the engine idles before the
# buffers swap.
DEFAULT_BUDGET = 6100


def find_bash():
    """Git bash, explicitly -- `bash` on PATH here is WSL's, a different OS
    that cannot run the Windows ModelSim binaries at all."""
    for c in (os.environ.get("GIT_BASH"),
              r"C:\Program Files\Git\bin\bash.exe",
              r"C:\Program Files\Git\usr\bin\bash.exe"):
        if c and Path(c).exists():
            return c
    sys.exit("Git bash not found. Set GIT_BASH.")


def captures(games):
    out = []
    for d in sorted((REPO / "debug").glob("sweep-*")):
        m = re.match(r"sweep-([a-z0-9]+)-f(\d+)$", d.name)
        if m and (d / "reference.png").exists() and m.group(1) in GAMES:
            if not games or m.group(1) in games:
                out.append((m.group(1), int(m.group(2)), d))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", default="12,24", help="ROM latencies in clk_sys cycles")
    ap.add_argument("--games", default="", help="comma-separated subset")
    ap.add_argument("--budget", type=int, default=DEFAULT_BUDGET)
    a = ap.parse_args()

    games = set(f for f in a.games.split(",") if f)
    lats = [int(x) for x in a.lat.split(",")]
    caps = captures(games)
    if not caps:
        sys.exit("no captures in debug/ -- run scripts/x1_001_sweep.py first")

    bash = find_bash()
    rows, fails = [], 0
    for game, frame, capdir in caps:
        r = subprocess.run([sys.executable, str(REPO / "scripts" / "prep_video_tb.py"),
                            game, str(capdir), "--budget", str(a.budget)],
                           cwd=REPO, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"FAIL {game} f{frame}: fixture build failed\n{r.stderr}")
            fails += 1
            continue
        for lat in lats:
            p = subprocess.run([bash, "scripts/run_sim.sh", "seta_video_tb",
                                f"+ROMLAT={lat}"],
                               cwd=REPO, capture_output=True, text=True)
            log = p.stdout + p.stderr
            ok = "PASS:" in log

            def num(pat, default=-1):
                m = re.search(pat + r"\s+(\d+)", log)
                return int(m.group(1)) if m else default
            mism = num(r"mismatches")
            over = num(r"line overruns")
            cut = num(r"lines cut short")
            m = re.search(r"worst line\s+(\d+) cycles \((\d+) sprites\)", log)
            wcyc, wspr = (int(m.group(1)), int(m.group(2))) if m else (-1, -1)
            rows.append((game, frame, lat, ok, mism, over, cut, wspr))
            print(f"{'PASS' if ok else 'FAIL'} {game:10s} f{frame:<5d} lat {lat:3d}"
                  f"  mismatches {mism:6d}  overruns {over:3d}  cut {cut:4d}"
                  f"  worst line {wcyc:5d} cyc / {wspr:3d} sprites")
            if not ok:
                fails += 1
                for line in log.splitlines():
                    if "FAIL" in line or "FIRST" in line:
                        print("      " + line.strip("# "))

    print()
    passed = sum(1 for r in rows if r[3])
    print(f"{passed} of {len(rows)} frames identical to MAME's own render")
    if rows:
        print(f"  budget          {a.budget} clk_sys cycles per line")
        print(f"  line overruns   {sum(r[5] for r in rows)} (any is a bug: the "
              f"budget should stop the engine before the buffers swap)")
        print(f"  lines cut short {sum(r[6] for r in rows)}, costing "
              f"{sum(r[4] for r in rows)} pixel(s) in total")
        print(f"  worst line completed {max(r[7] for r in rows)} sprites")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
