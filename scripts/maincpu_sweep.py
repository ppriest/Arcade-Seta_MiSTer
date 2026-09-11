#!/usr/bin/env python3
"""Boot one game from every memory-map family through maincpu.sv, against MAME.

    python scripts/maincpu_sweep.py                # one game per family
    python scripts/maincpu_sweep.py --all          # every mapped set
    python scripts/maincpu_sweep.py --latency 3,6,12

For each set: capture a MAME boot trace, build the fixtures, run sim/maincpu_tb,
and report whether the CPU's fetches matched. The point is the DECODE -- thirteen
families, and a wrong base address in any of them sends a work-RAM access
somewhere else, which shows up here as a divergence at a named address rather
than as a black screen much later.

`--latency` sweeps the behavioural ROM's response time. A bus FSM that only
works at one latency is a real hazard: Psikyo had a protocol bug that every
module-level sim passed because a short-latency model returned its response
while the FSM was between states. This is a cheap proxy for that until the
production SDRAM stack is wired underneath -- it is NOT a substitute for it.
"""
import argparse
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# set -> board index, from seta_board_pkg in rtl/cpu/maincpu.sv.
BOARDS = {
    "rezon": 0, "rezono": 0, "zingzip": 0, "wrofaero": 0, "gundhara": 0,
    "gundharac": 0, "jjsquawk": 0, "jjsquawko": 0, "zombraid": 0,
    "zombraidp": 0, "zombraidpj": 0, "daiohc": 0, "daiohp": 0, "daiohp2": 0,
    "daioh": 1, "daioha": 1,
    "extdwnhl": 2, "sokonuke": 2,
    "kamenrid": 3, "madshark": 3,
    "msgundam": 4, "msgundam1": 4,
    "blandia": 5,
    "blandiap": 6,
    "drgnunit": 7, "stg": 7, "qzkklogy": 7, "qzkklgy2": 7,
    "thunderl": 8, "thunderla": 8,
    "wits": 9,
    "umanclub": 10, "neobattl": 10,
    "blockcar": 11,
    "atehate": 12,
    "pairlove": 13,
    "oisipuzl": 14,
    "magspeed": 15,
}

# One representative per family, for the default run.
BASH = "bash"


def find_bash():
    """The Git/MSYS bash, NOT WSL's.

    `bash` on PATH here resolves to WSL's -- a different OS, with /mnt/c
    instead of /c, which cannot execute the Windows ModelSim binaries at all.
    Spawning it produced thirteen identical "no result" failures that read
    exactly like an RTL fault and were nothing of the kind. Name the shell.
    """
    import shutil
    for c in (os.environ.get("SETA_BASH"),
              "C:/Program Files/Git/bin/bash.exe",
              "C:/Program Files/Git/usr/bin/bash.exe",
              "C:/msys64/usr/bin/bash.exe",
              "E:/msys64/usr/bin/bash.exe"):
        if c and Path(c).is_file():
            return c
    w = shutil.which("bash")
    if w and "wsl" not in w.lower() and "System32" not in w:
        return w
    sys.exit("no Git/MSYS bash found -- set SETA_BASH to one. (`bash` on PATH "
             "is WSL's, which cannot run the Windows ModelSim binaries.)")


ONE_PER_FAMILY = ["gundhara", "daioh", "extdwnhl", "kamenrid", "msgundam",
                  "blandia", "blandiap", "drgnunit", "thunderl", "wits",
                  "umanclub", "blockcar", "atehate", "pairlove"]


def owner_zip():
    owner = {}
    for z in sorted((REPO / "roms").glob("*.zip")):
        owner[z.stem] = z
        for n in zipfile.ZipFile(z).namelist():
            if "/" in n:
                owner.setdefault(n.split("/")[0], z)
    return owner


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--accesses", type=int, default=400)
    ap.add_argument("--latency", default="6",
                    help="comma-separated ROM latencies to try")
    ap.add_argument("sets", nargs="*")
    a = ap.parse_args()

    global BASH
    BASH = find_bash()
    sets = a.sets or (sorted(BOARDS) if a.all else ONE_PER_FAMILY)
    lats = [int(x) for x in a.latency.split(",")]
    owner = owner_zip()

    width = max(len(s) for s in sets)
    bad = []
    for s in sets:
        if s not in BOARDS:
            print(f"{s:{width}s}  SKIP  no board mapping"); continue
        if s not in owner:
            print(f"{s:{width}s}  SKIP  no archive"); continue

        trace = REPO / "debug" / "bt" / s / f"{s}_boot.trace"
        if not trace.exists():
            r = subprocess.run([sys.executable, "scripts/mame_capture.py", s,
                                "--boot-trace", str(a.accesses),
                                "--name", f"bt/{s}"],
                               cwd=REPO, capture_output=True, text=True, timeout=300)
            if not trace.exists():
                print(f"{s:{width}s}  ERR   no trace: "
                      f"{(r.stdout + r.stderr).strip()[-70:]}")
                bad.append(s)
                continue

        p = subprocess.run([sys.executable, "scripts/prep_maincpu_tb.py", s, str(trace)],
                           cwd=REPO, capture_output=True, text=True)
        if p.returncode != 0:
            print(f"{s:{width}s}  ERR   prep: {(p.stdout+p.stderr).strip()[-70:]}")
            bad.append(s)
            continue

        results = []
        for lat in lats:
            r = subprocess.run([BASH, "scripts/run_sim.sh", "maincpu_tb",
                                f"+BOARD={BOARDS[s]}", f"+ROMLAT={lat}"],
                               cwd=REPO, capture_output=True, text=True, timeout=600)
            out = r.stdout + r.stderr
            m = re.search(r"PASS: (\d+) reads", out)
            if m:
                results.append((lat, "ok", m.group(1)))
            else:
                d = re.search(r"FIRST DIVERGENCE at byte address (\w+): "
                              r"RTL fetched (\w+), MAME (\w+)", out)
                short = (f"diverged @{d.group(1)} RTL {d.group(2)} MAME {d.group(3)}"
                         if d else
                         next((l.strip("# ").strip() for l in out.splitlines()
                               if "FAIL" in l), "no result"))
                results.append((lat, "fail", short))

        if all(x[1] == "ok" for x in results):
            print(f"{s:{width}s}  board {BOARDS[s]:2d}  PASS  {results[0][2]} reads"
                  f"  (latency {','.join(str(l) for l in lats)})")
        else:
            bad.append(s)
            for lat, st, info in results:
                if st != "ok":
                    print(f"{s:{width}s}  board {BOARDS[s]:2d}  FAIL  lat {lat}: {info}")

    print(f"\n{len(sets) - len(bad)} of {len(sets)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
