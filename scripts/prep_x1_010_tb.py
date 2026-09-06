#!/usr/bin/env python3
"""Build sim/x1_010_tb's fixtures from scripts/x1_010_model.py.

    python scripts/prep_x1_010_tb.py --selftest --samples 512
    python scripts/prep_x1_010_tb.py --regs debug/gh/gundhara_x1snd.bin \\
        --rom sample.bin --samples 2048

Writes regs.hex (8192 register bytes), rom.hex (the PCM sample ROM) and
expect.hex ({left,right} per line) into sim/x1_010_tb/, all gitignored.

`--selftest` builds a synthetic case that exercises both modes without needing
a ROM set: a waveform channel with a ramp wave and a full envelope, and a PCM
channel reading a known pattern. Synthetic content is chosen so a wrong index
shows up as a wrong VALUE rather than as silence -- LESSONS_LEARNED, "Any test
using uniform or all-zero content is invariant under byte order and cannot
catch this".
"""
import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

spec = importlib.util.spec_from_file_location("x1m", HERE / "x1_010_model.py")
x1m = importlib.util.module_from_spec(spec)
sys.modules["x1m"] = x1m
spec.loader.exec_module(x1m)


def synthetic():
    """A register image and ROM exercising both modes at once."""
    reg = bytearray(0x2000)

    # --- channel 0: waveform, envelope-driven volume ---
    for i in range(128):
        reg[0x1000 + i] = (i * 2 - 128) & 0xFF     # a signed ramp
    for i in range(128):
        reg[0x0080 + i] = 0xF0 if i < 64 else 0x0F  # L then R: a stereo swap
    reg[0] = 0x03          # key on, waveform, no one-shot
    reg[1] = 0x00          # waveform 0 -> 0x1000
    reg[2] = 0x00
    reg[3] = 0x04          # pitch 0x0400
    reg[4] = 0x08          # envelope step
    reg[5] = 0x01          # envelope 1 -> 0x80

    # --- channel 3: waveform with one-shot, so key-off is exercised ---
    reg[3 * 8 + 0] = 0x07  # key on, waveform, ONE-SHOT
    reg[3 * 8 + 1] = 0x00
    reg[3 * 8 + 2] = 0x00
    reg[3 * 8 + 3] = 0x02
    reg[3 * 8 + 4] = 0x40  # a fast envelope, so it ends inside the run
    reg[3 * 8 + 5] = 0x01

    # --- channel 1: PCM ---
    rom = bytearray(1 << 20)
    for i in range(0x4000):
        rom[i] = (i * 7 + (i >> 8)) & 0xFF         # non-repeating, signed-ish
    reg[8 + 0] = 0x01      # key on, PCM
    reg[8 + 1] = 0xF3      # left loud, right quiet -- an asymmetric mix
    reg[8 + 2] = 0x20      # frequency
    reg[8 + 4] = 0x00      # start 0
    reg[8 + 5] = 0xFE      # end = (0x100-0xFE)<<12 = 0x2000

    # --- channel 2: PCM with the divider set, and frequency 0 (MAME's hack) ---
    reg[16 + 0] = 0x81     # key on, PCM, divider
    reg[16 + 1] = 0x08
    reg[16 + 2] = 0x00     # frequency 0 -> MAME forces 4
    reg[16 + 4] = 0x01     # start 0x1000
    reg[16 + 5] = 0xFC
    return reg, bytes(rom)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--regs", help="an 8 KB x1snd capture (big-endian words)")
    ap.add_argument("--rom", help="raw PCM sample ROM")
    ap.add_argument("--samples", type=int, default=512)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    if a.selftest or not a.regs:
        reg, rom = synthetic()
        what = "synthetic (both modes, one-shot, divider, freq-0 hack)"
    else:
        raw = open(a.regs, "rb").read()
        # capture.lua writes big-endian words; the chip reads the LOW byte,
        # which is byte 1 of each pair.
        reg = bytearray(raw[2 * i + 1] for i in range(len(raw) // 2))
        reg.extend(b"\x00" * max(0, 0x2000 - len(reg)))
        rom = open(a.rom, "rb").read() if a.rom else b""
        what = a.regs

    out = Path(a.out) if a.out else (HERE.parent / "sim" / "x1_010_tb")
    out.mkdir(parents=True, exist_ok=True)

    chip = x1m.X1010(bytes(reg), rom)
    samples = chip.render(a.samples)

    with open(out / "regs.hex", "w", newline="\n") as f:
        for b in reg[:0x2000]:
            f.write("%02x\n" % b)
    with open(out / "rom.hex", "w", newline="\n") as f:
        # Only the region the chip can address, and only as far as there is
        # content -- a 1 MB file of zeros makes elaboration needlessly slow.
        n = min(len(rom), 1 << 20)
        for b in rom[:n]:
            f.write("%02x\n" % b)
    with open(out / "expect.hex", "w", newline="\n") as f:
        for l, r in samples:
            f.write("%04x%04x\n" % (x1m.to16(l) & 0xFFFF, x1m.to16(r) & 0xFFFF))

    nz = sum(1 for l, r in samples if l or r)
    print(f"{out}:")
    print(f"  source      {what}")
    print(f"  regs.hex    8192 bytes")
    print(f"  rom.hex     {min(len(rom), 1 << 20)} bytes")
    print(f"  expect.hex  {len(samples)} samples, {nz} non-zero")
    if nz == 0:
        sys.exit("every expected sample is silent -- that tests nothing")


if __name__ == "__main__":
    main()
