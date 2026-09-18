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
- **Main-CPU maps** for the four map functions, in `maincpu.sv`'s board
  table.
- **Per game:** as the table's extras column.
- **Screen timing:** a second line timing for the 59.1845 Hz boards.

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
