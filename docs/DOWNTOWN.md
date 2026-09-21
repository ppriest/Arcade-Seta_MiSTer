# Seta_Downtown: MAME's `seta/downtown.cpp` as a second core

Same repository, second Quartus revision and top level (`Seta_Downtown.sv`),
sharing `rtl/` with the Seta core. Only what the hardware changes is new.

## Games

| set | board | main map | sub CPU map | video | sound | extras |
|-|-|-|-|-|-|-|
| `downtown` (4 sets) | P0-045A | `downtown_map` | `downtown_sub_map` | X1-001 + one X1-012, 57.42 Hz ("verified on pcb") | X1-010 on the 68000 | rotary joysticks read through the sub CPU; protection RAM at 0x200000 simulated in MAME |
| `arbalest` | P0-045A | `downtown_map` | `metafox_sub_map` | as downtown, 59.1845 Hz, 224 lines | X1-010 | -- |
| `metafox` | P1-036-A + P0-045-A + P1-049A | `downtown_map` | `metafox_sub_map` | as arbalest | X1-010 | protection at 0x21c000, "very simplified" in MAME |
| `twineagl` | P0-034A | `downtown_map` | `twineagl_sub_map` | as downtown, tile bank at 0x400000 | X1-010 | protection handler at 0x200100 |
| `calibr50` | P0-044B | `calibr50_map` | `calibr50_sub_map` | X1-012 scroll written mid-frame; 15.6250 kHz / 57.4449 Hz measured | X1-010 on the 65C02 | uPD4701 loop joysticks, battery RAM |
| `usclssic` | P0-046A | `usclssic_map` | `calibr50_sub_map` | 6bpp tiles, colour PROMs ("wrong colors"), tile bank | X1-010 on the 65C02 | two trackballs through a uPD4701 |
| `tndrcade` (2 sets) | P0-029-A | `tndrcade_map` | `tndrcade_sub_map` | X1-001 only; 15.21 kHz / 59.1845 Hz measured | YM2203 + YM3812 on the 65C02 | -- |

All ROT270, 68000 at 8 MHz, W65C02 at 2 MHz (16 MHz / 8).

## Shared with the Seta core, unchanged

fx68k and `maincpu.sv`'s bus sequencing, `x1_001.sv`, `x1_012.sv` (one
instance), `x1_010.sv`, `seta_palette.sv` (xRGB_555, 512 entries), the SDRAM
and DDR3 loader, `seta_video_timing.sv`, `seta_crt.sv`, `scripts/build_mra.py`'s
ROM_START reading, the capture and sweep tooling.

## New

- **65C02 sub CPU:** T65, extended with the 65C02 instructions these programs
  execute (`rtl/cpu/t65/PROVENANCE.md`, `sim/t65c02_tb`).
- **Sub CPU system:** 512 bytes of RAM at 0x0000; a 2 KB RAM at 0x5000 shared
  with the 68000, byte-wide there in the low half of words; a banked 16 KB ROM
  window at 0x8000 (bank = bits 7-4 of the 0x1000 write) over a fixed ROM;
  two sound latches written by the 68000 at `sub_ctrl` +4/+6; inputs at
  0x1000; NMI at line 240 and IRQ at line 112 (every 16 lines on tndrcade),
  cleared by the 0x1000 write. Caliber 50 / U.S. Classic differ: IRQ 4 a
  frame, NMI from the latch, the X1-010 in the 65C02's map.
- **Main-CPU maps** in `maincpu.sv`'s board table: `downtown_map` (18),
  `calibr50_map` (19), `tndrcade_map` (20).
- **Per game:** as the table's extras column.
- **Screen timing:** a second line timing for the 59.1845 Hz boards.

### Caliber 50 (`calibr50`)

- **X1-010 on the 65C02** (sub map 3): 0x0000-0x1fff is the chip at offset
  ^ 0x1000, so its wave RAM is the 65C02's zero page and stack. `seta_core`
  hands the X1-010's CPU port to the 65C02 for this board. 0x4000 reads
  latch 0 (the 68000's 0xb00001 write, which holds NMI until acknowledged)
  and takes the bank, NMI and IRQ acknowledges and /PCMMUTE; a write to
  0xc000 is latch 1, read back at 0xb00001. IRQ 240 times a second
  (`from_hz(4*60)`, not the screen's rate). The 68000 holds the 65C02 in
  reset through 0x500001 bit 4.
- **Interrupts:** level 4 at scanlines 0, 64, 128, 192, acked by reading
  0x100000; level 2 at line 248, acked at 0x300000.
- **Loop joysticks:** a uPD4701 at 0xa00010-0xa00019, two 12-bit counts. The
  game rounds a count to steps of 4 and masks it to 16 directions (68000 code
  at 0x64de and 0x81ab2). Controls are the Ikari Warriors core's: Rotate
  Left / Rotate Right (buttons 3, 4) step while held at the OSD's Rotary
  Speed; GRS Super Joystick keystroke mode takes the arrow keys (P1) and C/V
  (P2). A step is one direction, 4 counts. DownTown's 12-position switch
  uses the same controls (`rtl/downtown/rotary_input.sv`).
- **Battery RAM:** 4 KB at 0x200000, the `.mra`'s `<nvram index="4"
  size="4096"/>`; every write requests an upload, which MiSTer services when
  the OSD next opens.
- **Raster scroll:** MAME redraws at each scroll write (its trampoline).
  `x1_012.sv`'s raster mode takes scroll, bank and colour mode at every line
  start, and a scroll or bank write releases the VRAM queue, so the lines
  after it see VRAM as it stood then. Otherwise VRAM stays queued to vblank:
  in attract the game writes scroll only in vblank (MAME, 900 frames: 3
  writes a frame, all in vblank) and tiles right across the frame (10 a
  frame), and applied live -- the first version -- those tiles showed under
  the old scroll (hardware, glitching tiles on the title screen). The engine
  renders a line ahead, so a mid-frame write lands a line later than MAME's
  partial update.
- **Checked:** the 65C02 against MAME's trace, 199977 of 199977
  instructions (`sim/downtown_sub_tb`, `+SUB_MAP=3 +BANK_ENTRIES=16`).

### Thundercade (`tndrcade`, `tndrcadej`)

- **Sub map 4:** as downtown's, with 0x0800 reading 0xff, P1 / P2 / COINS at
  0x1000-0x1002, the YM2203 at 0x2000 and the YM3812 at 0x3000. IRQ every 16
  scanlines, NMI at line 240.
- **Sound:** jotego's jt03 (YM2203) and jtopl2 (YM3812), 4 MHz each, copied
  from Arcade-Fuuki_MiSTer (`rtl/sound/*/PROVENANCE.md`, GPL-3.0). The DIP
  switches are read through the YM2203's ports A and B, as MAME wires
  `dsw1_r` / `dsw2_r`. Mixed 0.35 and 0.5.
- **Main map:** no tile layer; sprites at 0x600000 and 0xc00000, palette at
  0x380000, 16 KB work RAM mirrored at 0xe00000 and 0xffc000; sub_ctrl at
  0x800000, shared RAM at 0xa00000. Timing: 224 lines at 59.1845 Hz (Guru's
  PCB measurement; MAME says 60).
- **Checked:** the 65C02 against MAME's trace, 95017 instructions to the
  point where MAME's 68000 resets it through sub_ctrl, which the bench does
  not model.
- **Sprites:** snapshot at line 240, where MAME draws. They flicker in
  attract because the vblank handler copies half of a work-RAM list each
  frame and the list is rebuilt between the two copies; a PCB recording
  flickers the same way. `docs/MAME_DIVERGENCE.md`, "Thundercade's sprite
  flicker is the game's".

## Order

1. Revision, top level and file lists; DownTown, Arbalester and Meta Fox
   first (one main map, X1-010 on the 68000).
2. Sub CPU system, checked by diffing the 65C02's trace against
   `scripts/mame_subtrace.py --keep`.
3. SDRAM layout and `.mra` generation for downtown.cpp.
4. Twin Eagle, then Caliber 50 (raster scroll, uPD4701, NVRAM), U.S. Classic
   (PROMs, trackballs), Thundercade (YM2203/YM3812 from the vendored jotego
   cores in Arcade-Fuuki_MiSTer).

The CPU pace question in `docs/MAME_DIVERGENCE.md` ("setac_eof is not
instantaneous") applies here too: two CPUs trading bytes through shared RAM
and latches depend on each other's timing.
