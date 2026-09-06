#!/usr/bin/env python3
"""Sweep the SDRAM_CLK phase at runtime and measure the DQ eye with a pattern.

NOT CURRENTLY RUNNABLE: the probe bits 47..32 that reported `phase_pos` now
carry the interrupt state (Fuuki.sv). The stepping controls (source bits 1
and 2) still exist; restore the field to the probe before using this.

    python scripts/phase_sweep.py --pattern ones --span 44 --step 4

Loads one known-pattern .mra ONCE (see scripts/sdram_pattern_test.py), then
walks the SDRAM_CLK phase over JTAG without relaunching: for each point it
steps the PLL's C1 counter, re-arms the read-back walker in place, takes a
screenshot, decodes it, and counts words that differ from the pattern. The
output is the error count against phase -- the eye -- so the phase to ship is
the CENTRE of the zero-error window, not the first point that happened to
work.

Controls are the ISSP probe's source bits (see Fuuki.sv, "RUNTIME SDRAM_CLK
PHASE STEPPING"): bit 1 / bit 2 step up / down by 1 << bits[5:3] steps of
~132 ps; bit 6 toggles the walker re-arm. `phase_pos` in the probe reports
where the sweep currently is, in steps from the build's phase.

The sweep goes DOWN first to the start of the span and then UP across it, so
every point is approached from the same direction. A relaunch resets the
phase to the build value; run --restore before relaunching a game if you want
the device left where the build put it (it is harmless either way).

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs a probe field for the SDRAM_CLK phase (already noted as stale on Fuuki), which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import sdram_pattern_test as spt   # noqa: E402

QUARTUS_STP = spt.QUARTUS_STP
ISSP = spt.ISSP
HW = spt.HW


def issp(*args):
    p = subprocess.run([str(QUARTUS_STP), "-t", str(ISSP), *map(str, args)],
                       capture_output=True, text=True, timeout=180, cwd=str(REPO))
    return p.stdout


def phase_pos():
    m = re.search(r"^\s+phase_pos\s+(-?\d+)", issp(), re.M)
    return int(m.group(1)) if m else None


def step(n, up):
    """Move |n| steps. n must be a power of two <= 128 (one pulse each)."""
    sel = max(0, n.bit_length() - 1)
    base = sel << 3
    issp("set", base)                      # size select stable first
    issp("pulse", base | (0x02 if up else 0x04))
    issp("set", 0)


def rearm_and_dump(tag):
    issp("set", 0x40); time.sleep(0.3); issp("set", 0x00)   # toggle bit 6 twice = two kicks
    time.sleep(1.5)
    from tracer_readout import read_buffer
    ents, _ = read_buffer(tag=tag)
    return {v >> 16: v & 0xFFFF for v in ents if v is not None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pattern", default="ones", choices=list(spt.PATTERNS))
    ap.add_argument("--span", type=int, default=44, help="total steps to cover, centred on the build phase")
    ap.add_argument("--step", type=int, default=4, help="steps between points (power of two)")
    ap.add_argument("--restore", action="store_true", help="return to the build phase at the end")
    a = ap.parse_args()

    e = spt.env()
    r = spt.run_one(a.pattern, e)
    if "void" in r:
        sys.exit(f"pattern load failed: {r['void']}")
    exp = r["exp"]
    print(f"pattern '{a.pattern}' loaded; at build phase: {len(r['bad'])} wrong")

    half = a.span // 2
    pos = phase_pos()
    print(f"phase_pos reads {pos} (expect 0 after a fresh load)")
    # go down to the start
    moved = 0
    while moved < half:
        step(a.step, up=False); moved += a.step
    results = []
    out = spt.OUT / "sweep"; out.mkdir(parents=True, exist_ok=True)
    for i in range(0, a.span + 1, a.step):
        p = phase_pos()
        got = rearm_and_dump(out / f"p{i:03d}.png")
        bad = sum(1 for k in got if got[k] != exp[k])
        results.append((p, len(got), bad))
        print(f"  phase {p:+5d} steps ({p*0.1323:+6.2f} ns): {bad:3d} wrong of {len(got)} recovered")
        if i < a.span:
            step(a.step, up=True)
    zero = [p for p, n, b in results if n and b == 0]
    if zero:
        print(f"\nzero-error window: {min(zero):+d} .. {max(zero):+d} steps "
              f"({min(zero)*0.1323:+.2f} .. {max(zero)*0.1323:+.2f} ns); centre {(min(zero)+max(zero))//2:+d}")
    else:
        print("\nno zero-error point in this span")
    if a.restore:
        p = phase_pos()
        while p and p != 0:
            n = 1
            while n * 2 <= abs(p) and n < 128: n *= 2
            step(n, up=(p < 0)); p = phase_pos()
        print(f"restored: phase_pos = {phase_pos()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
