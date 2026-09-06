#!/usr/bin/env python3
"""Run sim/x1_001_tb over every captured frame, at several ROM latencies.

    python scripts/x1_001_rtl_sweep.py                  # every capture found
    python scripts/x1_001_rtl_sweep.py --lat 6,12,24
    python scripts/x1_001_rtl_sweep.py --games thunderl,umanclub

One frame is not a test. The captures already in debug/ span eight sets and
three points in each game, and each one exercises a different mix -- a
different sprite bank, a different column count, a boot state with every entry
stacked on one line. Running all of them at more than one ROM latency is the
same argument sim/maincpu_tb makes: a renderer that depends on the answer
arriving in a particular cycle passes at one latency and fails at another, and
the failure looks like a rendering bug rather than a handshake bug.

It also reports the LINE BUDGET, which is the number this phase actually needs.
A line is 512 dots at a believed 8 MHz dot clock = 6144 clk_sys cycles at
96 MHz. Anything above that is a line the engine could not finish in time, and
on hardware means dropped sprites rather than a wrong picture.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from x1_001_model import GAMES

# 512 dots at 8 MHz, against a 96 MHz clk_sys. The dot clock is still a
# hypothesis (docs/ROADMAP.md, "Screen timing"), so this is a target, not a
# specification -- but it is the target the rest of the design assumes.
LINE_BUDGET = 6144


def find_bash():
    """Git bash, explicitly.

    `bash` on PATH here is WSL's: a different OS with /mnt/c instead of /c,
    which cannot run the Windows ModelSim binaries at all. It fails with
    "No such file or directory" for a path that plainly exists, identically
    for every case, which reads as a total RTL failure. Same defence as
    scripts/maincpu_sweep.py.
    """
    for c in (os.environ.get("GIT_BASH"),
              r"C:\Program Files\Git\bin\bash.exe",
              r"C:\Program Files\Git\usr\bin\bash.exe",
              r"C:\Program Files (x86)\Git\bin\bash.exe"):
        if c and Path(c).exists():
            return c
    sys.exit("Git bash not found. Set GIT_BASH.")


def captures(games):
    out = []
    for d in sorted((REPO / "debug").glob("*")):
        if not d.is_dir() or not (d / "reference.png").exists():
            continue
        # flip-* captures come from x1_001_sweep.py --flip. They are the
        # ONLY frames in which spritectrl[0] bit 6 is set, so without them
        # the flipped half of the sprite Y arithmetic is never compared
        # against MAME -- only against the model, through prep's --flip.
        m = re.match(r"(sweep|flip)-([a-z0-9]+)-f(\d+)$", d.name)
        if not m:
            continue
        if m.group(2) in GAMES and (not games or m.group(2) in games):
            out.append((m.group(2), int(m.group(3)), d,
                        "flip" if m.group(1) == "flip" else ""))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", default="6,12,24",
                    help="ROM latencies in clk_sys cycles")
    ap.add_argument("--games", default="", help="comma-separated subset")
    ap.add_argument("--budget", type=int, default=0,
                    help="line_budget in clk_sys cycles; 0 disables the cutoff. "
                         "With it on, a run that still matches the model proves "
                         "the cutoff cost nothing VISIBLE -- the sprites it "
                         "dropped were the stale entries no game can see.")
    a = ap.parse_args()

    games = set(f for f in a.games.split(",") if f)
    lats = [int(x) for x in a.lat.split(",")]
    caps = captures(games)
    if not caps:
        sys.exit("no captures in debug/ -- run scripts/x1_001_sweep.py first")

    bash = find_bash()
    rows, fails = [], 0
    for game, frame, capdir, variant in caps:
        r = subprocess.run([sys.executable, str(REPO / "scripts" / "prep_x1_001_tb.py"),
                            game, str(capdir)],
                           cwd=REPO, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"FAIL {game} f{frame}: fixture build failed\n{r.stderr}")
            fails += 1
            continue
        for lat in lats:
            p = subprocess.run([bash, "scripts/run_sim.sh", "x1_001_tb",
                                f"+ROMLAT={lat}", f"+BUDGET={a.budget}"],
                               cwd=REPO, capture_output=True, text=True)
            log = p.stdout + p.stderr
            ok = "PASS:" in log
            def num(pat):
                m = re.search(pat + r"\s+(\d+)", log)
                return int(m.group(1)) if m else -1
            worst = num(r"worst line")
            m = re.search(r"worst line\s+\d+ clk_sys cycles \((\d+) sprites\)", log)
            wspr = int(m.group(1)) if m else -1
            spr = num(r"sprites blitted")
            cut = num(r"lines cut short")
            mism = num(r"mismatches")
            rows.append((game, frame, lat, ok, worst, spr, mism, wspr, cut,
                         variant))
            # With a cutoff in force the worst line is the cutoff itself, so
            # reporting it as "over budget" would be reporting the cutoff
            # working. Only flag it when the engine ran unconstrained.
            flag = ("" if (a.budget or worst <= LINE_BUDGET)
                    else f"  OVER BUDGET by {worst - LINE_BUDGET}")
            tag = f"{game}{'/flip' if variant else ''}"
            print(f"{'PASS' if ok else 'FAIL'} {tag:15s} f{frame:<5d} lat {lat:3d}"
                  f"  worst line {worst:6d} cyc / {wspr:4d} sprites"
                  f"  total {spr:6d}  cut {cut:3d}  mismatches {mism}{flag}")
            if not ok:
                fails += 1
                for line in log.splitlines():
                    if "FAIL" in line or "FIRST" in line:
                        print("      " + line.strip("# "))

    print()
    passed = sum(1 for r in rows if r[3])
    print(f"{passed} of {len(rows)} runs identical to the model")
    if rows:
        if a.budget:
            print(f"line_budget {a.budget} was in force; "
                  f"{sum(r[8] for r in rows)} line(s) cut short in total, "
                  f"{sum(r[6] for r in rows)} pixel(s) changed by it")
        worst = max(rows, key=lambda r: r[4])
        if a.budget:
            wspr = max(r[7] for r in rows)
            print(f"cutoff at {a.budget} cycles: worst line carried {wspr} sprites")
        else:
            over = [r for r in rows if r[4] > LINE_BUDGET]
            print(f"line budget {LINE_BUDGET} clk_sys cycles (512 dots at 8 MHz):")
            print(f"  worst observed  {worst[4]} cycles / {worst[7]} sprites "
                  f"on {worst[0]} f{worst[1]} at latency {worst[2]}")
            print(f"  over budget     {len(over)} of {len(rows)} runs")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
