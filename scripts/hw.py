#!/usr/bin/env python3
"""Drive the MiSTer over its Remote API: launch a game, grab a screenshot.

    python scripts/hw.py launch "Susume! Mile Smile - Go Go! Mile Smile (newer)"
    python scripts/hw.py shot  --out debug/hw/shot.png
    python scripts/hw.py run   "Gyakuten!! Puzzle Bancho (Japan, set 1)"

Needs MiSTer Remote (wizzomafizzo/mrext) listening on port 8182, and the same
./mister.env that scripts/deploy.py uses.

TWO BEHAVIOURS HERE ARE NOT OPTIONAL, both carried over from the Psikyo core
where each cost a false positive:

1. LAUNCH BOUNCES THROUGH menu.rbf FIRST. Launching a .mra while any core is
   already running -- including the very core the .mra targets -- does NOT
   reprogram the FPGA or reload the ROM; it silently reuses what is loaded.
   That produced a run where deploy, launch and screenshot all reported
   success and the screenshot was of an earlier build.

2. THE SCREENSHOT POST IS RE-SENT, not just polled for longer. The API call
   returns an empty body and is sometimes simply lost; the signal is a new
   file appearing in the core's screenshot folder. Polling harder after one
   POST does not help, so each attempt re-triggers.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs deployed .mra files on a MiSTer, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import argparse
import re
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CORE_NAME = "Seta"                       # matches CONF_STR's core name
REMOTE_ARCADE = "/media/fat/_Arcade"
REMOTE_SHOTS = "/media/fat/screenshots"


def load_env():
    path = REPO / "mister.env"
    if not path.exists():
        sys.exit("mister.env not found (gitignored; see scripts/deploy.py)")
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def find_putty(name):
    for c in (name, os.path.join(r"C:\Program Files\PuTTY", name)):
        found = shutil.which(c) or (c if os.path.isfile(c) else None)
        if found:
            return found
    sys.exit(f"Couldn't find {name}. Install PuTTY, or put it on PATH.")


class Mister:
    def __init__(self, env):
        self.host = env["MISTER_HOST"]
        self.user = env["MISTER_USER"]
        self.pw = env["MISTER_PASSWORD"]
        self.api = f"http://{self.host}:8182/api"
        self.plink = find_putty("plink.exe")
        self.pscp = find_putty("pscp.exe")

    # ---- shell ----
    def sh(self, command, timeout=60, check=True):
        p = subprocess.run([self.plink, "-ssh", "-batch", "-pw", self.pw,
                            f"{self.user}@{self.host}", command],
                           capture_output=True, text=True, timeout=timeout)
        if check and p.returncode != 0:
            sys.exit(f"ssh failed ({p.returncode}): {command}\n{p.stderr.strip()}")
        return p.stdout

    def get_file(self, remote, local, timeout=120):
        p = subprocess.run([self.pscp, "-batch", "-pw", self.pw,
                            f"{self.user}@{self.host}:{remote}", str(local)],
                           capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0:
            sys.exit(f"download failed: {remote}\n{p.stderr.strip()}")

    # ---- API ----
    def post(self, path, body=None, timeout=30):
        data = json.dumps(body).encode() if body is not None else b""
        req = urllib.request.Request(self.api + path, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read().decode(errors="replace")
        except urllib.error.HTTPError as e:
            sys.exit(f"API POST {path} failed: {e.code} {e.read()[:200]}")
        except Exception as e:
            sys.exit(f"API POST {path} failed: {type(e).__name__}: {e}")

    def get(self, path, timeout=30):
        with urllib.request.urlopen(self.api + path, timeout=timeout) as r:
            return r.read().decode(errors="replace")

    # ---- actions ----
    def launch(self, mra_path, bounce=True):
        if bounce:
            print("  bouncing through menu.rbf (forces a real FPGA reload)")
            self.post("/launch", {"path": "/media/fat/menu.rbf"})
            time.sleep(2)
        print(f"  launching {mra_path}")
        self.post("/launch", {"path": mra_path})

    def core_name(self):
        """MiSTer names the screenshot folder from the MRA SETNAME (it writes
        it to /tmp/CORENAME), not from the core's CONF_STR name. Looking under
        the CONF_STR name found nothing and reported "no screenshot produced"
        while the screenshots were being written normally."""
        n = self.sh("cat /tmp/CORENAME 2>/dev/null || true", check=False).strip()
        return n or CORE_NAME

    def shots(self, core=CORE_NAME):
        out = self.sh(f"ls -1 {REMOTE_SHOTS}/{core} 2>/dev/null || true", check=False)
        return set(l.strip() for l in out.splitlines() if l.strip())

    def screenshot(self, out_path, core=None, settle=4,
                   poll_timeout=15, attempts=4):
        # Settle BEFORE reading /tmp/CORENAME: straight after a launch it
        # still names the previous core, so the poll watched the wrong
        # folder and every trigger looked dropped (twice, after each of the
        # first two game launches). A retry seconds later always worked.
        time.sleep(settle)              # let the core actually render a frame
        core = core or self.core_name()
        print(f"  screenshot folder: {REMOTE_SHOTS}/{core}")
        before = self.shots(core)
        for attempt in range(1, attempts + 1):
            self.post("/screenshots")
            deadline = time.time() + poll_timeout
            while time.time() < deadline:
                new = self.shots(core) - before
                if new:
                    name = sorted(new)[-1]
                    out_path.parent.mkdir(parents=True, exist_ok=True)
                    # NOT quoted: pscp takes the remote path as one argv
                    # element, so shell quotes become part of the path.
                    self.get_file(f"{REMOTE_SHOTS}/{core}/{name}", out_path)
                    print(f"  screenshot -> {out_path} (remote {name})")
                    return out_path
                time.sleep(1)
            print(f"  no screenshot yet (attempt {attempt}/{attempts}), re-triggering")
        print("  NO SCREENSHOT PRODUCED -- the core may not be running, or the "
              "API dropped every trigger")
        return None


def resolve_mra(m, name):
    """Find the .mra on the device, so a typo fails here and not silently."""
    # Git Bash rewrites a leading-slash argument into a Windows path before
    # python sees it ("/media/fat/x" -> "C:/Program Files/Git/media/fat/x"),
    # which silently launched nothing. Recover the MiSTer path from wherever
    # the mangling left it.
    hit = re.search(r"/media/fat/.*", name)   # not `m` -- that is the Mister object
    if hit:
        return hit.group(0)
    if name.startswith("/"):
        return name
    if not name.endswith(".mra"):
        name += ".mra"
    for cand in (f"{REMOTE_ARCADE}/_Seta/{name}", f"{REMOTE_ARCADE}/{name}"):
        if m.sh(f'test -f "{cand}" && echo yes || echo no', check=False).strip() == "yes":
            return cand
    hits = m.sh(f'find {REMOTE_ARCADE} -name "{name}" 2>/dev/null | head -5',
                check=False).strip()
    if hits:
        return hits.splitlines()[0]
    sys.exit(f"no such .mra on the device: {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=("launch", "shot", "run", "playing"))
    ap.add_argument("mra", nargs="?", help=".mra name or absolute remote path")
    ap.add_argument("--out", default=str(REPO / "debug" / "hw" / "shot.png"))
    ap.add_argument("--settle", type=float, default=4)
    ap.add_argument("--no-bounce", action="store_true",
                    help="skip the menu.rbf bounce -- only when you WANT the "
                         "caching behaviour")
    a = ap.parse_args()

    m = Mister(load_env())

    if a.command == "playing":
        print(m.get("/games/playing"))
        return 0

    if a.command in ("launch", "run"):
        if not a.mra:
            sys.exit("give a .mra name")
        m.launch(resolve_mra(m, a.mra), bounce=not a.no_bounce)
        time.sleep(3)
        print("  playing:", m.get("/games/playing"))

    if a.command in ("shot", "run"):
        m.screenshot(Path(a.out), settle=a.settle)

    return 0


if __name__ == "__main__":
    sys.exit(main())
