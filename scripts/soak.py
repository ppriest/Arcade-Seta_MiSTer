#!/usr/bin/env python3
"""Run a game and watch for a hang: probe counters and screenshots on a timer.

    python scripts/soak.py gundhara --seconds 120 --every 10

Every `--every` seconds it clears the probe counters, waits, reads them back
and takes a screenshot. It prints, per sample: frames rendered, ROM reads
(saturates at 65535 = "lots"), irq1 pulses (one per frame when healthy), the
level-1 acknowledges, the pending flags, the CPU's last ROM address, and
whether the frame changed since the previous sample. A run of unchanged
frames with the CPU parked in a short loop is a hang; the probe row says
whether the interrupt it waits for is still being generated, stuck pending,
or acknowledged and simply not doing what the game expects.

Screenshots go to debug/hw/soak/<game>_<n>.png.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs a probe to sample, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import argparse
import hashlib
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from boot_trace import MRA          # noqa: E402
from tracer_readout import issp     # noqa: E402

HW = REPO / "scripts" / "hw.py"
OUT = REPO / "debug" / "hw" / "soak"
FIELDS = ("frames", "irq1_pulses", "iack_level1",
          "irq1_pending", "irq3_pending", "irq5_pending", "z80_fetches", "pause_latched",
          "ym_writes", "pcm_keyons", "fm_keyons", "snd_peak")


def probe(clear=False):
    out = issp("clear") if clear else issp()
    vals = {}
    for f in FIELDS:
        m = re.search(rf"^\s+{f}\s+(\S+)", out, re.M)
        vals[f] = m.group(1) if m else "?"
    return vals


def shot(path):
    subprocess.run([sys.executable, str(HW), "shot", "--out", str(path), "--settle", "1"],
                   capture_output=True, cwd=str(REPO))
    if not path.exists():
        return None
    from PIL import Image
    return hashlib.md5(Image.open(path).convert("RGB").tobytes()).hexdigest()[:8]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game", choices=list(MRA))
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--every", type=int, default=10)
    ap.add_argument("--no-launch", action="store_true", help="watch whatever is running")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if not a.no_launch:
        r = subprocess.run([sys.executable, str(HW), "launch", MRA[a.game]],
                           capture_output=True, text=True, cwd=str(REPO))
        if "launching" not in r.stdout:
            sys.exit(f"launch failed: {r.stdout[-200:]}")
        # ROM download: ~12 s for an FG-2 set, ~45 s for FG-3's 59 MB
        time.sleep(45 if a.game.startswith("asura") else 12)
    print(f"{'t':>5s} {'frames':>6s} {'irq1':>5s} {'iack1':>5s} pend(5,3,1) "
          f"{'z80':>9s} {'ymwr':>8s} {'pcm':>5s} {'fm':>4s} {'peak':>5s} frame")
    prev = None
    same = 0
    t0 = time.time()
    n = 0
    while time.time() - t0 < a.seconds:
        probe(clear=True)
        time.sleep(a.every)
        v = probe()
        n += 1
        h = shot(OUT / f"{a.game}_{n}.png")
        changed = "changed" if h != prev else "SAME"
        same = same + 1 if h == prev else 0
        prev = h
        pend = f"{v['irq5_pending'][0]}{v['irq3_pending'][0]}{v['irq1_pending'][0]}"
        print(f"{int(time.time()-t0):5d} {v['frames']:>6s} {v['irq1_pulses']:>5s} "
              f"{v['iack_level1']:>5s} {pend:^11s} {v['z80_fetches']:>9s} "
              f"{v['ym_writes']:>8s} {v['pcm_keyons']:>5s} {v['fm_keyons']:>4s} "
              f"{v['snd_peak']:>5s} {changed}"
              + ("  pause" if v["pause_latched"] == "yes" else ""))
        if same >= 3:
            print(f"  frame unchanged for {same} samples -- hung? (z80 fetches {v['z80_fetches']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
