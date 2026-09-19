#!/usr/bin/env python3
"""Build sim/t65c02_tb/prog.hex and expect.txt: a 65C02 program exercising the
instructions added to T65 (rtl/cpu/t65/PROVENANCE.md), with the results it
must leave in memory and each added instruction's cycle count.

    python sim/t65c02_tb/make_prog.py

Cycle counts are the WDC W65C02S datasheet's (table 5-7), for the page-cross-
free cases used here.
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
ORG = 0xC000
code = bytearray()
labels, fixups = {}, []
expect = {}        # address -> byte
cycles = []        # (pc, opcode, expected cycles)


def pc():
    return ORG + len(code)


def emit(*b, cyc=None):
    if cyc is not None:
        cycles.append((pc(), b[0], cyc))
    code.extend(b)


def jmp_abs(label):
    emit(0x4C, 0, 0)
    fixups.append((len(code) - 2, label))


# setup
emit(0xA2, 0xFF, 0x9A)            # LDX #$FF ; TXS
emit(0xD8)                        # CLD

# STZ zp
emit(0xA9, 0x55, 0x85, 0x10)      # LDA #$55 ; STA $10
emit(0x64, 0x10, cyc=3)           # STZ $10
expect[0x10] = 0x00
# STZ zp,x
emit(0xA2, 0x02)                  # LDX #$02
emit(0xA9, 0xAA, 0x85, 0x12)      # LDA #$AA ; STA $12
emit(0x74, 0x10, cyc=4)           # STZ $10,X
expect[0x12] = 0x00
# STZ abs
emit(0xA9, 0x77, 0x8D, 0x00, 0x03)
emit(0x9C, 0x00, 0x03, cyc=4)     # STZ $0300
expect[0x0300] = 0x00
# STZ abs,x
emit(0xA9, 0x66, 0x8D, 0x02, 0x03)
emit(0x9E, 0x00, 0x03, cyc=5)     # STZ $0300,X
expect[0x0302] = 0x00

# (zp) group, pointer $20/$21 -> $0400
emit(0xA9, 0x00, 0x85, 0x20, 0xA9, 0x04, 0x85, 0x21)
emit(0xA9, 0x3C)
emit(0x92, 0x20, cyc=5)           # STA ($20)
expect[0x0400] = 0x3C
emit(0xA9, 0x00)
emit(0xB2, 0x20, cyc=5)           # LDA ($20)
emit(0x85, 0x30)
expect[0x30] = 0x3C
emit(0xA9, 0xC1, 0x12, 0x20, 0x85, 0x31)   # ORA ($20)
cycles.append((pc() - 4, 0x12, 5))
expect[0x31] = 0xFD
emit(0xA9, 0xFF, 0x32, 0x20, 0x85, 0x32)   # AND ($20)
cycles.append((pc() - 4, 0x32, 5))
expect[0x32] = 0x3C
emit(0xA9, 0xFF, 0x52, 0x20, 0x85, 0x33)   # EOR ($20)
cycles.append((pc() - 4, 0x52, 5))
expect[0x33] = 0xC3
emit(0x18, 0xA9, 0x01, 0x72, 0x20, 0x85, 0x34)   # CLC ; ADC ($20)
cycles.append((pc() - 4, 0x72, 5))
expect[0x34] = 0x3D
emit(0x38, 0xA9, 0x40, 0xF2, 0x20, 0x85, 0x35)   # SEC ; SBC ($20)
cycles.append((pc() - 4, 0xF2, 5))
expect[0x35] = 0x04
# CMP ($20): equal -> Z and C set
emit(0xA2, 0x00, 0xA9, 0x3C)
emit(0xD2, 0x20, cyc=5)           # CMP ($20)
emit(0xD0, 0x03, 0x90, 0x01, 0xE8)   # BNE +3 ; BCC +1 ; INX
emit(0x86, 0x36)                  # STX $36
expect[0x36] = 0x01

# BRA
emit(0xA9, 0x11)
emit(0x80, 0x02, cyc=3)           # BRA +2
emit(0xA9, 0xEE)
emit(0x85, 0x37)
expect[0x37] = 0x11

# BIT #imm: Z from A and M; N and V unchanged (set N via LDA #$80 first)
emit(0xA2, 0x00, 0xA9, 0x8F)      # LDX #0 ; LDA #$8F (N=1)
emit(0x89, 0x70, cyc=2)           # BIT #$70 -> Z=1, N still 1
emit(0xD0, 0x03, 0x10, 0x01, 0xE8)   # BNE +3 ; BPL +1 ; INX
emit(0x86, 0x38)
expect[0x38] = 0x01

# BIT zp,x: [$42]=$C0, A=$40 -> N=1 V=1 Z=0
emit(0xA9, 0xC0, 0x85, 0x42, 0xA2, 0x02, 0xA9, 0x40)
emit(0x34, 0x40, cyc=4)           # BIT $40,X
emit(0x08, 0x68, 0x29, 0xC2, 0x85, 0x39)   # PHP ; PLA ; AND #$C2 ; STA $39
expect[0x39] = 0xC0

# BIT abs,x: [$0502]=0, A=$FF -> Z=1 N=0 V=0
emit(0xA9, 0x00, 0x8D, 0x02, 0x05, 0xA9, 0xFF)
emit(0x3C, 0x00, 0x05, cyc=4)     # BIT $0500,X
emit(0x08, 0x68, 0x29, 0xC2, 0x85, 0x3A)
expect[0x3A] = 0x02

# TSB zp: [$50]=$0F, A=$F1 -> [$50]=$FF, Z=0
emit(0xA9, 0x0F, 0x85, 0x50, 0xA9, 0xF1)
emit(0x04, 0x50, cyc=5)           # TSB $50
emit(0x08, 0x68, 0x29, 0x02, 0x85, 0x3B)
expect[0x50] = 0xFF
expect[0x3B] = 0x00
# TRB zp: [$51]=$FF, A=$0F -> [$51]=$F0
emit(0xA9, 0xFF, 0x85, 0x51, 0xA9, 0x0F)
emit(0x14, 0x51, cyc=5)           # TRB $51
expect[0x51] = 0xF0
# TSB abs: [$0600]=0, A=$01 -> [$0600]=$01, Z=1
emit(0xA9, 0x00, 0x8D, 0x00, 0x06, 0xA9, 0x01)
emit(0x0C, 0x00, 0x06, cyc=6)     # TSB $0600
emit(0x08, 0x68, 0x29, 0x02, 0x85, 0x3C)
expect[0x0600] = 0x01
expect[0x3C] = 0x02
# TRB abs: [$0601]=$81, A=$80 -> [$0601]=$01
emit(0xA9, 0x81, 0x8D, 0x01, 0x06, 0xA9, 0x80)
emit(0x1C, 0x01, 0x06, cyc=6)     # TRB $0601
expect[0x0601] = 0x01

# INC A / DEC A, PHX/PLY (implemented by T65 already; regression)
emit(0xA9, 0x41, 0x1A, 0x1A, 0x3A, 0x85, 0x3D)   # LDA #$41 ; INC ; INC ; DEC -> $42
expect[0x3D] = 0x42
emit(0xA2, 0x5A, 0xDA, 0x7A, 0x84, 0x3E)          # LDX #$5A ; PHX ; PLY ; STY $3E
expect[0x3E] = 0x5A

# JMP (abs,x): X=2, table at TABLE+2 -> TARGET
emit(0xA2, 0x02)
emit(0x7C, 0, 0, cyc=6)
fixups.append((len(code) - 2, "TABLE"))
emit(0xA9, 0xEE, 0x85, 0x3F)      # skipped
labels["TARGET"] = pc()
emit(0xA9, 0x22, 0x85, 0x3F)
expect[0x3F] = 0x22

# JMP (abs,x) with the entry straddling a page: X=1, table $C7FE -> entry at
# $C7FF/$C800. The 65C02 carries into the high byte (Caliber 50's sub CPU
# jump tables can land there).
emit(0xA2, 0x01)
emit(0x7C, 0xFE, 0xC7, cyc=6)
emit(0xA9, 0xEE, 0x85, 0x41)      # skipped
labels["TARGET2"] = pc()
emit(0xA9, 0x33, 0x85, 0x41)
expect[0x41] = 0x33

# BRK clears D on the 65C02: SED ; BRK ; handler pushes P
emit(0xF8, 0x00, 0x00)            # SED ; BRK #0
labels["AFTER_BRK"] = pc()
jmp_abs("AFTER_BRK")              # not reached: the handler never returns

labels["IRQ"] = pc()
emit(0x08, 0x68, 0x29, 0x08, 0x85, 0x40)   # PHP ; PLA ; AND #$08 ; STA $40
expect[0x40] = 0x00
emit(0xA9, 0x01, 0x8D, 0x00, 0x02)          # done flag
labels["DONE"] = pc()
jmp_abs("DONE")

labels["TABLE"] = pc()
emit(0, 0, 0, 0)                  # TABLE+0, TABLE+2 filled below
tbl = labels["TABLE"] - ORG
code[tbl + 2] = labels["TARGET"] & 0xFF
code[tbl + 3] = labels["TARGET"] >> 8
expect[0x0200] = 0x01

for off, lab in fixups:
    code[off] = labels[lab] & 0xFF
    code[off + 1] = labels[lab] >> 8

rom = bytearray(0x4000)
assert len(code) < 0x7FF, "the page-crossing table at $C7FF would overlap the code"
rom[:len(code)] = code
rom[0x7FF] = labels["TARGET2"] & 0xFF
rom[0x800] = labels["TARGET2"] >> 8
vec = lambda a, v: (rom.__setitem__(a - ORG, v & 0xFF), rom.__setitem__(a - ORG + 1, v >> 8))
vec(0xFFFC, ORG)
vec(0xFFFE, labels["IRQ"])
vec(0xFFFA, labels["IRQ"])

(HERE / "prog.hex").write_text("\n".join(f"{b:02x}" for b in rom) + "\n")
with open(HERE / "expect.txt", "w") as f:
    for a, v in sorted(expect.items()):
        f.write(f"M {a:04x} {v:02x}\n")
    for p, op, c in cycles:
        f.write(f"C {p:04x} {op:02x} {c}\n")
print(f"{len(code)} bytes, {len(expect)} memory checks, {len(cycles)} cycle checks")
