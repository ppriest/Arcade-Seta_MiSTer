#!/usr/bin/env python3
"""Read the core's 256-entry trace buffer back through the screenshot path.

    from tracer_readout import read_buffer
    entries, problems = read_buffer(tag="boot_fc")      # list of 256 (int | None)

The overlay (rtl/seta_core.sv, "BANDED, SELF-CHECKING READOUT") shows each
entry on six scanlines -- three of the value, three of its bitwise inverse --
40 entries per screen, seven JTAG-selected pages. This walks the pages, takes
a screenshot of each, and recovers entries by CONTENT rather than by row
number. The inverse band is the self-check: v and ~v are read from the same
BRAM entry, so they must XOR to 0xFFFFFF whatever the memory holds, and any
transform in the capture path shows up as an unpaired run instead of being
read as data. That is how the framework's gamma LUT was caught (see
docs/LESSONS_LEARNED.md); the earlier one-row-per-entry overlays had read
its output as SDRAM corruption.

Recovery per screen: split the rows into runs of identical value; a run is a
band half if it is 2..4 rows long (blended edge rows differ and are excluded
naturally); pair consecutive runs (v, ~v) where v ^ ~v == 0xFFFFFF; that pair
is one entry, in order. Anything that does not pair is reported, not guessed.

STATUS: ported from Arcade-Fuuki_MiSTer, NOT yet exercised on this core.
It needs the banded trace overlay in the video path, which does not exist yet.
The mechanics carry over; check the details against the RTL before
trusting a result, and treat an empty output as unexplained rather
than as an answer.
"""
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HW = REPO / "scripts" / "hw.py"
DECODE = REPO / "scripts" / "decode_debug_screenshot.py"
ISSP = REPO / "scripts" / "read_issp.tcl"
QUARTUS_STP = Path(r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_stp.exe")
OUT = REPO / "debug" / "hw" / "trace"

PAGES = 7           # 7 x 40 = 280 >= 256
PER_PAGE = 40
PAGE_BITS = {0: 0x00, 1: 0x08, 2: 0x10, 3: 0x18, 4: 0x80, 5: 0x88, 6: 0x90}   # bits 4:3 and 7


def issp(*args):
    # scripts/hwlock.py: JTAG concurrent with a Quartus compile has
    # bugchecked this PC three times (0x139). memdump.py, sweep.py, soak.py,
    # wait_scene.py and sdram_pattern_test.py all reach JTAG through here,
    # so one guard covers them. The marker is machine-wide, so a Fuuki or
    # Psikyo build is refused while this is reading, and vice versa.
    import sys as _sys, os as _os
    _sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
    from hwlock import jtag_session
    with jtag_session("tracer_readout.issp"):
        p = subprocess.run([str(QUARTUS_STP), "-t", str(ISSP), *map(str, args)],
                           capture_output=True, text=True, timeout=180, cwd=str(REPO))
    return p.stdout


def shot(png):
    # The buffer is static while being read (first-N mode holds it, ring mode
    # is only used frozen), so the core's default 4 s settle per shot is not
    # needed; seven pages per buffer makes that worth trimming.
    subprocess.run([sys.executable, str(HW), "shot", "--out", str(png), "--settle", "1"],
                   capture_output=True, cwd=str(REPO))
    return png.exists()


def rows_of(png):
    out = subprocess.run([sys.executable, str(DECODE), str(png), "--mode", "scanline",
                          "--limit", "240"], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+0x([0-9A-Fa-f]+)", line)
        if m:
            rows[int(m.group(1))] = int(m.group(2), 16)
    return [rows.get(i) for i in range(240)]


def entries_from_rows(rows):
    """(entries_in_order, problems) from one screen of rows."""
    runs = []                      # (value, length)
    for v in rows:
        if v is None:
            continue
        if runs and runs[-1][0] == v:
            runs[-1][1] += 1
        else:
            runs.append([v, 1])
    # keep plausible band halves; edge/blend rows make 1-row runs, drop them
    halves = [(v, n) for v, n in runs if 2 <= n <= 5]
    entries, problems, i = [], [], 0
    while i + 1 < len(halves):
        v, a = halves[i]; w, b = halves[i + 1]
        if (v ^ w) == 0xFFFFFF:
            entries.append(v); i += 2
        else:
            problems.append(f"unpaired run {v:06X}x{a} next {w:06X}x{b}")
            i += 1
    return entries, problems


def read_buffer(tag="trace", settle=0.6, src_high=0, low_or=0):
    """Walk all pages; return (entries[256], problems).

    src_high: value kept in JTAG source bits [31:8] throughout (the memory
    dump's {region, page}); the readout page bits live in [7:0]. low_or is
    OR-ed into every [7:0] write (0x20 = hold the CPU paused)."""
    OUT.mkdir(parents=True, exist_ok=True)
    entries = [None] * 256
    problems = []
    for page in range(PAGES):
        issp("set", (src_high << 8) | PAGE_BITS[page] | low_or); time.sleep(settle)
        png = OUT / f"{tag}_p{page}.png"
        if not shot(png):
            problems.append(f"page {page}: no screenshot"); continue
        got, probs = entries_from_rows(rows_of(png))
        problems += [f"page {page}: {p}" for p in probs]
        if len(got) != PER_PAGE and page < PAGES - 1:
            problems.append(f"page {page}: recovered {len(got)} of {PER_PAGE} entries")
        for k, v in enumerate(got[:PER_PAGE]):
            idx = page * PER_PAGE + k
            if idx < 256:
                entries[idx] = v
    issp("set", (src_high << 8) | low_or)
    return entries, problems


if __name__ == "__main__":
    tag = sys.argv[1] if len(sys.argv) > 1 else "trace"
    ents, probs = read_buffer(tag)
    print(f"{sum(e is not None for e in ents)}/256 entries recovered; {len(probs)} problems")
    for p in probs[:10]:
        print("  ", p)
    for i in range(0, 256, 8):
        print(f"  {i:3d}: " + " ".join("------" if e is None else f"{e:06X}" for e in ents[i:i+8]))
