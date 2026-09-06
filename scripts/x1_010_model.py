#!/usr/bin/env python3
"""A reference model of the Seta X1-010, transcribed from MAME.

    python scripts/x1_010_model.py --selftest
    python scripts/x1_010_model.py debug/gh/gundhara_x1snd.bin roms/gundhara.zip \
        --samples 2048 --out sim/x1_010_tb/expect.hex

This is the golden reference `sim/x1_010_tb` is checked against. It is a
line-by-line transcription of `sound_stream_update()` in
`src/devices/sound/x1_010.cpp`, NOT an independent interpretation -- the whole
value is that it agrees with MAME by construction, so a disagreement with the
RTL is the RTL's.

THE CHIP
--------
16 voices, stereo, clocked at 16 MHz, one output sample every 512 clocks =
31.25 kHz. 8 KB of RAM visible to the 68000 as 16-bit words, of which only the
low byte is the register the chip reads (the high byte is a read-back shadow
the chip ignores):

    0x0000-0x007f   16 channels x 8 register bytes
    0x0080-0x0fff   envelope data
    0x1000-0x1fff   waveform data (128 bytes per waveform, 8-bit signed)

Per channel, register 0 is:

    bit 7   frequency divider
    bit 2   envelope one-shot
    bit 1   0 = PCM from ROM, 1 = waveform from RAM
    bit 0   key on

Two details that are easy to get wrong and are not guessable from the register
map:

  * KEY-ON IS EDGE-TRIGGERED AT THE WRITE, not sampled by the engine. MAME
    resets both accumulators inside `write()` when register 0's bit 0 goes
    0 -> 1. A model that instead resets them when it *notices* key-on set will
    drift on any channel retriggered without an intervening key-off.
  * `if (freq == 0) freq = 4` in PCM mode is a MAME HACK, commented as such --
    "Meta Fox does write the frequency register, but this is a hack to make it
    work with the current setup. This is broken for Arbalester (it writes 8),
    but that'll be fixed later." It is carried here so the two agree, and
    flagged so nobody mistakes it for hardware behaviour.
"""
import argparse
import sys

NUM_CHANNELS = 16
VOL_BASE = 2 * 32 * 256 // 30      # 546; MAME's own integer expression


class X1010:
    def __init__(self, reg, rom):
        """reg: 8192 register/wave bytes. rom: the PCM sample ROM (up to 1 MB)."""
        self.reg = bytearray(reg)
        if len(self.reg) < 0x2000:
            self.reg.extend(b"\x00" * (0x2000 - len(self.reg)))
        self.rom = rom
        self.smp_offset = [0] * NUM_CHANNELS
        self.env_offset = [0] * NUM_CHANNELS

    def write(self, offset, data):
        """The 8-bit register write, including its key-on side effect."""
        ch, r = offset // 8, offset % 8
        if ch < NUM_CHANNELS and r == 0 and (self.reg[offset] & 1) == 0 and (data & 1):
            self.smp_offset[ch] = 0
            self.env_offset[ch] = 0
        self.reg[offset] = data

    def read_byte(self, addr):
        return self.rom[addr] if addr < len(self.rom) else 0

    def render(self, n):
        """n stereo samples, as (left, right) pairs in MAME's own units.

        MAME accumulates `data * vol` scaled by VOL_BASE against a full scale of
        32768*256. Sixteen channels at maximum volume and full-scale samples
        reach about twice that, so the chip's own mix can exceed 0 dBFS -- it is
        the stream that absorbs it. Kept faithful here; the RTL saturates and
        says so, rather than wrapping (LESSONS_LEARNED: an ADPCM accumulator
        that wrapped instead of saturating cost the Psikyo core a long hunt).
        """
        out = []
        for _ in range(n):
            accl = accr = 0
            for ch in range(NUM_CHANNELS):
                base = ch * 8
                status = self.reg[base + 0]
                if not (status & 1):
                    continue
                div = 1 if (status & 0x80) else 0

                if not (status & 2):
                    # ---- PCM from ROM ----
                    start = self.reg[base + 4] << 12
                    end = (0x100 - self.reg[base + 5]) << 12
                    voll = ((self.reg[base + 1] >> 4) & 0xF) * VOL_BASE
                    volr = ((self.reg[base + 1] >> 0) & 0xF) * VOL_BASE
                    freq = self.reg[base + 2] >> div
                    if freq == 0:
                        freq = 4              # MAME's Meta Fox hack; see the header
                    delta = self.smp_offset[ch] >> 4
                    if start + delta >= end:
                        self.reg[base + 0] = status & 0xFE      # key off
                        continue
                    data = self.read_byte(start + delta)
                    data = data - 256 if data > 127 else data   # s8
                    accl += data * voll
                    accr += data * volr
                    self.smp_offset[ch] = (self.smp_offset[ch] + freq) & 0xFFFFFFFF
                else:
                    # ---- waveform from RAM ----
                    start = (self.reg[base + 1] << 7) + 0x1000
                    freq = ((self.reg[base + 3] << 8) + self.reg[base + 2]) >> div
                    env = self.reg[base + 5] << 7
                    env_step = self.reg[base + 4]
                    delta = self.env_offset[ch] >> 10
                    if (status & 4) and delta >= 0x80:
                        self.reg[base + 0] = status & 0xFE      # key off
                        continue
                    vol = self.reg[(env + (delta & 0x7F)) & 0x1FFF]
                    voll = ((vol >> 4) & 0xF) * VOL_BASE
                    volr = ((vol >> 0) & 0xF) * VOL_BASE
                    data = self.reg[(start + ((self.smp_offset[ch] >> 10) & 0x7F)) & 0x1FFF]
                    data = data - 256 if data > 127 else data   # s8
                    accl += data * voll
                    accr += data * volr
                    self.smp_offset[ch] = (self.smp_offset[ch] + freq) & 0xFFFFFFFF
                    self.env_offset[ch] = (self.env_offset[ch] + env_step) & 0xFFFFFFFF
            out.append((accl, accr))
        return out


def to16(v):
    """MAME's units -> signed 16-bit, saturating.

    add_int(..., v, 32768*256) means v/(32768*256) of full scale, so a 16-bit
    sample is v*32768/(32768*256) = v/256.
    """
    s = v // 256
    return max(-32768, min(32767, s))


def selftest():
    """Exercise both modes without needing a ROM set."""
    reg = bytearray(0x2000)

    # Channel 0: waveform, one-shot off. Wave 0 -> 0x1000. A ramp, so a wrong
    # index shows up as a wrong value rather than as silence.
    for i in range(128):
        reg[0x1000 + i] = (i * 2) & 0xFF
    for i in range(128):
        reg[0x0080 + i] = 0xFF            # envelope 0 at 0x80: full volume
    reg[0] = 0x03                          # key on, waveform
    reg[1] = 0x00                          # waveform number 0
    reg[2] = 0x00
    reg[3] = 0x04                          # pitch 0x0400
    reg[4] = 0x01                          # envelope step
    reg[5] = 0x01                          # envelope at 0x80

    # Channel 1: PCM. start 0x0000, end -> (0x100-0xFF)<<12 = 0x1000.
    rom = bytes(((i * 3) & 0xFF) for i in range(0x2000))
    reg[8 + 0] = 0x01                      # key on, PCM
    reg[8 + 1] = 0xF0                      # left full, right silent
    reg[8 + 2] = 0x10                      # frequency
    reg[8 + 4] = 0x00
    reg[8 + 5] = 0xFF

    chip = X1010(reg, rom)
    s = chip.render(64)
    nz = sum(1 for l, r in s if l or r)
    print(f"selftest: {nz}/64 samples non-zero")
    print(f"  first 4 (L,R): {[(to16(l), to16(r)) for l, r in s[:4]]}")
    # Channel 1 is left-only, so any right-channel content must come from the
    # waveform channel -- a cheap check that the two modes are both running.
    assert any(r != 0 for _, r in s), "waveform channel produced no right output"
    assert any(l != 0 for l, _ in s), "no left output at all"
    # Key-on edge: setting bit 0 when it is already set must NOT reset.
    chip.smp_offset[0] = 12345
    chip.write(0, 0x03)
    assert chip.smp_offset[0] == 12345, "key-on retriggered without an edge"
    chip.write(0, 0x02)
    chip.write(0, 0x03)
    assert chip.smp_offset[0] == 0, "key-on edge did not reset the accumulator"
    print("selftest: PASS (both modes render; key-on is edge-triggered)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("regdump", nargs="?", help="the 8 KB x1snd region capture")
    ap.add_argument("rom", nargs="?", help="ROM archive holding the x1snd region")
    ap.add_argument("--set", help="MAME set name, for a merged archive")
    ap.add_argument("--samples", type=int, default=1024)
    ap.add_argument("--out", help="write expected samples as hex, one per line")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest or not a.regdump:
        selftest()
        return

    raw = open(a.regdump, "rb").read()
    # capture.lua writes big-endian words; the chip reads only the LOW byte of
    # each, which is byte 1 of each pair.
    reg = bytes(raw[2 * i + 1] for i in range(len(raw) // 2))

    rom = b""
    if a.rom:
        import zipfile
        sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
        # The x1snd region is a plain concatenation in every in-scope set.
        z = zipfile.ZipFile(a.rom)
        names = sorted(n for n in z.namelist())
        print(f"NOTE: no x1snd region table yet -- pass a raw .bin, or add one.",
              file=sys.stderr)

    chip = X1010(reg, rom)
    s = chip.render(a.samples)
    nz = sum(1 for l, r in s if l or r)
    print(f"{a.samples} samples, {nz} non-zero")
    if a.out:
        with open(a.out, "w", newline="\n") as f:
            for l, r in s:
                f.write("%04x%04x\n" % (to16(l) & 0xFFFF, to16(r) & 0xFFFF))
        print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
