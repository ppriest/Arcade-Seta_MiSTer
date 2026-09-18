#!/usr/bin/env python3
"""Fixtures for sim/downtown_sub_tb: DownTown's "sub" region, MAME's
instruction addresses for the 65C02 from reset, and where MAME took
interrupts.

    python scripts/mame_subtrace.py downtown --seconds 3 --keep
    python sim/downtown_sub_tb/prep.py [--game downtown] [--count 200000]
    scripts/run_sim.sh downtown_sub_tb [+SUB_MAP=1 +BANK_ENTRIES=1]

The region comes from the set's ROM_START in downtown.cpp (scripts/
build_region.py): downtown's is ROM_LOAD("ud2-002-004.17c", 0x4000, 0x40000)
plus ROM_RELOAD at 0xc000, 0x4c000 bytes; twineagl's and metafox's one 8 KB
ROM at 0x6000 reloaded up to 0xffff. The bench's +SUB_MAP and +BANK_ENTRIES
are the set's downtown_board_cfg.sv values.

An interrupt entry is an instruction at a vector that the previous
instruction does not reach by falling through, branching or jumping; the
bench raises that interrupt during the previous instruction, so the core
takes it at the same boundary.
"""
import argparse
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
BRANCHES = ("jmp", "jsr", "bra", "beq", "bne", "bcc", "bcs", "bmi", "bpl", "bvc", "bvs")

ap = argparse.ArgumentParser()
ap.add_argument("--game", default="downtown")
ap.add_argument("--count", type=int, default=200000)
a = ap.parse_args()

os.environ.setdefault("MAME_SRC", "E:/mame/src/mame/seta/downtown.cpp")
sys.path.insert(0, str(REPO / "scripts"))
from build_region import region_image  # noqa: E402

region = bytearray(region_image(a.game, "sub")[0])
assert len(region) <= 0x4c000, "the bench's region array is 0x4c000 bytes"
(HERE / "sub.hex").write_text("\n".join(f"{b:02x}" for b in region) + "\n")


def vec(o):
    return region[o] | region[o + 1] << 8


NMI, IRQ = vec(0xfffa), vec(0xfffe)
pcs, text = [], []
for line in open(REPO / "debug" / "subtrace" / f"{a.game}-sub.log", errors="replace"):
    m = re.match(r"([0-9A-F]{4}):\s*(.*)$", line)
    if m:
        pcs.append(int(m.group(1), 16))
        text.append(m.group(2).strip())
        if len(pcs) == a.count:
            break

# MAME logs the instruction at the interrupted PC, then takes the interrupt
# without executing it (RTI returns to that PC), so that line is dropped and
# the interrupt is raised during the instruction before it.
entry = set()
for i in range(2, len(pcs)):
    if pcs[i] not in (NMI, IRQ):
        continue
    op = text[i - 1].split()[0]
    tgt = re.search(r"\$([0-9a-f]{4})$", text[i - 1])
    if op in BRANCHES and tgt and int(tgt.group(1), 16) == pcs[i]:
        continue
    if op in ("rts", "rti"):
        continue
    entry.add(i)
out_pc, irq = [], []
for i, pc in enumerate(pcs):
    if i + 1 in entry:
        irq[-1] = 1 if pcs[i + 1] == NMI else 2
        continue
    out_pc.append(pc)
    irq.append(0)
pcs = out_pc

(HERE / "expect_pc.hex").write_text("\n".join(f"{p:04x}" for p in pcs) + "\n")
(HERE / "irq_at.hex").write_text("\n".join(str(v) for v in irq) + "\n")
print(f"sub.hex {len(region):#x} bytes, {len(pcs)} MAME instruction addresses, "
      f"{irq.count(1)} NMI and {irq.count(2)} IRQ entries (NMI {NMI:04x}, IRQ {IRQ:04x})")
