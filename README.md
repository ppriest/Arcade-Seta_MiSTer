# Seta core for MiSTer

MiSTer FPGA core for [Seta](https://en.wikipedia.org/wiki/Seta_Corporation)'s X1-010 arcade
hardware — MAME's `seta/seta.cpp` — built with Quartus Prime 17.0.2 Lite for the DE10-nano.

**Runs on MiSTer.** Thunder & Lightning and Wit's play on a DE10-nano with correct graphics,
sound and controls. Four of the other six Group A sets have known faults; see
[History](#history).

## Contents

- [Games](#games)
- [Hardware](#hardware)
- [History](#history)
- [Installation](#installation)
- [Status](#status)
  - [Todo](#todo)
  - [Resource usage](#resource-usage)
- [AI Attestation](#ai-attestation)
- [Verification](#verification)
- [Acknowledgements](#acknowledgements)
- [Layout](#layout)
- [License](#license)

## Games

The full scope is the X1-010 mainline of `seta.cpp` — 43 sets across 14 memory-map families. The
first phase covers **Group A**, the boards with no tilemap layers at all:

| Name | Year | Manufacturer | Main CPU | Notes | Status |
|-|-|-|-|-|-|
| Wit's | 1989 | Athena (Visco license) | M68000 @ 8 MHz | Four players | Working! |
| Thunder & Lightning | 1990 | Seta | M68000 @ 8 MHz | Two sets. Has a protection register | Working! |
| Pairs Love | 1991 | Athena / Nihon System | M68000 @ 8 MHz | 2048 palette entries, and a write-history block | |
| Block Carnival / Thunder & Lightning 2 | 1992 | Visco | M68000 @ 8 MHz | | |
| Ultraman Club | 1992 | Banpresto | M68000 @ 16 MHz | | |
| SD Gundam Neo Battling | 1992 | Banpresto | M68000 @ 16 MHz | | |
| Athena no Hatena? | 1993 | Athena | M68000 @ 16 MHz | 2 MB of sprites | Renders |

Every one of them is 68000 + X1-001A/X1-002A sprites + X1-006 palette + X1-010 sound. The
remaining phases add the X1-012 tilemap engine (one layer, then two), then the 6bpp families, then
`blandia` and `zombraid`.

## Hardware

| Chip | Function | Status |
|-|-|-|
| X1-001A + X1-002A | Sprites, and the "floating tilemap" made of sprite columns | Written, verified against MAME |
| X1-006 | Palette, `xRRRRRGGGGGBBBBB` | Written |
| X1-007 | Video blanking | Written (timing is a hypothesis) |
| X1-010 | 16-voice PCM / wavetable sound | Written, verified sample for sample |
| X1-004 | Input handling | Folded into the address decode |
| X1-005 / X1-009 | NVRAM | No protection is emulated in `seta.cpp`; not needed in Group A |
| X1-011 | Graphics mixing | Phase 3 — nothing to mix with no tilemap layers |
| X1-012 | Tilemaps | Phase 2 |

**There is no MCU and no active protection anywhere in scope.** `thunderl` has an eight-bit
register whose value is a function of the *address* written to it, and `pairlove` has a block that
returns the current value and reverts the cell to the previous one. Both are a few lines of logic.

Some links discussing the hardware:
* https://www.arcade-museum.com/manuf/Seta.html
* MAME's `seta/seta.cpp`, `video/x1_001.cpp`, `video/x1_012.cpp` and `sound/x1_010.cpp`

## History

**`Arcade-Seta_20260909.rbf`** — first hardware release. **+0.972 ns** setup slack on `clk_sys`
(96 MHz) and **+3.655 ns** on `clk_video` (48 MHz); 22,829 / 41,910 ALMs.

*Playing on hardware:* Thunder & Lightning, Wit's — graphics, sound and controls all correct.

*Fixed after the first hardware run:*

* **Five of the eight sets rendered the wrong tiles.** The `.mra` emitted the ROM data before the
  mod byte, and the core does not merely record which game it is — `seta_board_cfg` turns the mod
  byte into `gfx_half_words` and the sprite ROM is **permuted with it as the data arrives**. With
  the id last, every game's sprites were laid out using the config's defaults, which are
  thunderl's — so thunderl, thunderla and Wit's were correct and nothing else was. The mod byte is
  now emitted first, as Psikyo does for the same reason. `.mra`-only, confirmed on hardware.

* Every game booted into service mode and stayed there. `PORT_SERVICE_DIPLOC` is not a
  `PORT_DIPNAME`, so the DIP extractor never saw the bit and it shipped as 0 — which for
  `IP_ACTIVE_LOW` means service mode on. The DSW high byte was `E8` where it should be `E9`.
* Start inserted a coin and Coin did nothing: the `.mra` `<buttons>` name list is positional
  (entry *i* is joystick bit 4+*i*), so a two-button game's names landed Start on the core's COIN1
  bit. Both sides now use fixed positions — Start 10, Coin 11, Pause 12, Service 13.
* Block Carnival showed the wrong title: `blockcar_map` moves both the inputs (0x500000) and the
  DSW (0x300000) and the board arm overrode neither. The driver's note on that set is "Title: DSW".
* SD Gundam reported a colour error at boot: the 3 KB of plain RAM above the palette
  (`0x300400–0x300fff`) was not decoded at all.

*Known broken:*

* **Sprites clip wrongly at the bottom edge** — one entering from the lowest scanline appears all
  at once. Affects every game. The sprite engine matches MAME across 90 simulation runs *inside the
  visible area*, so this is most likely at the boundary of the rendered region.
* Pairs Love and Ultraman Club have not been tried on hardware.

The `.rbf` and the `.mra` files are a matched pair — the button bits moved, so an older `.mra`
with this core puts Start and Coin in the wrong places.

## Installation

Take the `.rbf` and the `.mra` files from the same release — see [History](#history).

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`
* Take the `*.mra` files from `releases/` and put them in `_Arcade/_Seta`
* Put the MAME merged or split ROMs in `games/mame`

## Status

**Meets timing on every clock. Not yet run on hardware.**

What is built and verified in simulation:

* **M68000** — TG68KdotC_Kernel driven directly, with address decode for all **14** of the memory
  maps in scope. Boot-diffed against MAME's own bus trace for 36 of 36 sets.
* **X1-001 sprites** (`rtl/video/x1_001.sv`) — 512 foreground entries plus the 16-column floating
  tilemap, rendered per scanline into a double-buffered 512-pixel line buffer. Front-to-back with
  a written bit, so running out of time drops the bottom-most sprites rather than the ones on top.
  One 64-bit SDRAM granule per 16-pixel row, via a download-time layout permutation.
* **X1-010 sound** (`rtl/sound/x1_010.sv`) — 16 voices, PCM and wavetable, written from MAME
  because no FPGA implementation of this chip exists anywhere.
* **Video path** — palette, timing generator, and the two scanline interrupts.
* **Interrupts** — both of `seta.cpp`'s clearing rules: HOLD_LINE, cleared when the CPU
  acknowledges, and ASSERT_LINE, cleared only by the board's own write.
* **SDRAM backend** — every runtime ROM on one chip, ports assigned by deadline, with the sprite
  layout permutation applied on the way in.
* **`.mra` generation** — all eight Group A sets, each proved byte for byte.

Known issues:

* **The screen timing is a hypothesis.** MAME has no raw timings for this hardware. An 8 MHz dot
  clock, htotal 512 and vtotal 260 reproduce the refresh rates the driver declares, and the sync
  positions inside the blanking are plausible rather than measured. Only `daioh`'s 57.42 Hz is
  marked "verified on PCB" anywhere.
* **Some behaviour follows MAME** `blockcar`'s IRQ 3 is asserted at
  vblank and no acknowledge is mapped anywhere, so it stays pending forever and the game must mask it; the X1-010 carries MAME's own `if (freq == 0) freq = 4` hack, which its source says is broken for another game. Both are reproduced deliberately and flagged in the RTL. `docs/ROADMAP.md` keeps the list.

### Todo

- [x] Close timing on every clock
- [ ] Run on a DE10-nano
- [ ] Phase 2 RTL: `rtl/video/x1_012.sv` against the model, plus sprite buffering (`setac_eof`)
- [ ] Phase 2: the X1-012 tilemap engine, one layer (`drgnunit`, `stg`, `qzkklogy`, `qzkklgy2`)
- [ ] Phase 3: two layers, the X1-011 mixer, the PIT, X1-010 sample banking
- [ ] Phase 4: the 6bpp families, and the 24-bit `.mra` interleave they need
- [ ] Phase 5: `blandia`'s palette-offset effect, `zombraid`'s light gun and battery RAM
- [ ] Hiscore support, CRT offset, savestates
- [ ] The three 14.318181 MHz games (`orbs`, `keroppi`, `krzybowl`) need a Bresenham clock enable

### Resource usage

Whole core, on the DE10-nano's Cyclone V 5CSEBA6, speed grade 7:

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 21,315 (51%) | 41,910 |
| Block memory bits | 1,699,009 (30%) | 5,662,720 |
| RAM blocks | 222 (40%) | 553 |
| DSP blocks | 44 (39%) | 112 |
| PLLs | 3 | 6 |

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant.

## Verification

Not PCB-validated. MAME is the accuracy reference, with its own acknowledged uncertainties noted where they matter. Goal is to reconcile the inconsistencies and unlikely behaviour.

* Hardware facts come from the MAME driver and verified against it.
  * Graphics layouts were decoded from real ROM data before any RTL used them
  * The CPU is diffed against a real MAME trace
  * The sprite engine and the video path are diffed against MAME's own render
  * The sound is diffed against a line-by-line transcription of MAME's mixer.
  * The ROM_START records, the DIP switches to gernerate the `.mra` titles

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for
  - the [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework this project
    is seeded from
  - the SDRAM controller (`sdram.sv`, vendored via
    [Arcade-Jackal_MiSTer](https://github.com/MiSTer-devel/Arcade-Jackal_MiSTer), with burst-4
    reads added)
  - the screen-rotation module (`screen_rotate_two.sv`, from
    [Arcade-SKNS_MiSTer](https://github.com/MiSTer-devel/Arcade-SKNS_MiSTer))
- The **MAMEdev team** — in particular **Luca Elia** and **David Haywood** — for
  [MAME](https://github.com/mamedev/mame)'s `seta/seta.cpp`, `video/x1_001.cpp` and
  `sound/x1_010.cpp`. There is no FPGA implementation of the X1-010 anywhere, so MAME's C++ is the
  whole specification for the sound chip.
- **Tobias Gubener** ([TobiFlex](https://github.com/TobiFlex)) for
  [TG68K.C](https://github.com/TobiFlex/TG68K.C).
- **Arcade-Psikyo_MiSTer** and **Arcade-Fuuki_MiSTer**, which this project takes its CPU wrapper,
  SDRAM stack, debug instrumentation and build tooling from.

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| - | - |
| `sys` | MiSTer framework, vendored from the template |
| `rtl` | core source |
| `releases` | `.mra` files, and the current `.rbf` |
| `docs` | design notes and hard-won debugging lessons |
| `sim` | ModelSim testbenches |
| `scripts` | capture/verification tooling (see [`scripts/README.md`](scripts/README.md)) |
| `debug` | reference captures from MAME used as ground truth (gitignored) |
| `roms` | your own MAME sets (gitignored, never committed) |

## License

GPL v3 (see `LICENSE`). Imported components keep their own licences and are GPLv3-compatible:
TG68K.C (LGPLv3+), the adapted SDR SDRAM controller (Sorgelig, GPL-3.0-or-later),
`screen_rotate_two.sv` (Sorgelig, GPLv2), and the MiSTer framework in `sys/`.

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
