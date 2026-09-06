# Seta core for MiSTer

MiSTer FPGA core for [Seta](https://en.wikipedia.org/wiki/Seta_Corporation)'s X1-010 arcade
hardware — MAME's `seta/seta.cpp` — built with Quartus Prime 17.0.2 Lite for the DE10-nano.

**This core does not run yet.** It compiles, it fits, and every block is verified in simulation
against MAME; it does not close timing and has never been on hardware. See
[Status](#status) for exactly where it stands.

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

| Name | Year | Manufacturer | Main CPU | Notes |
|-|-|-|-|-|
| Wit's | 1989 | Athena (Visco license) | M68000 @ 8 MHz | Four players |
| Thunder & Lightning | 1990 | Seta | M68000 @ 8 MHz | Two sets. Has a protection register |
| Pairs Love | 1991 | Athena / Nihon System | M68000 @ 8 MHz | 2048 palette entries, and a write-history block |
| Block Carnival / Thunder & Lightning 2 | 1992 | Visco | M68000 @ 8 MHz | |
| Ultraman Club | 1992 | Banpresto | M68000 @ 16 MHz | |
| SD Gundam Neo Battling | 1992 | Banpresto | M68000 @ 16 MHz | |
| Athena no Hatena? | 1993 | Athena | M68000 @ 16 MHz | 2 MB of sprites |

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

No releases yet. The core has not been run on a DE10-nano.

## Installation

There is no `.rbf` to install yet. The `.mra` files for the eight Group A sets are in
`releases/`. When there is a core to go with them:

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`
* Take the `*.mra` files from `releases/` and put them in `_Arcade/_Seta`
* Put the MAME merged or split ROMs in `games/mame`

## Status

**Compiles and fits; does not close timing; never run on hardware.**

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

* **Timing does not close.** The first whole-core build measured **−7.954 ns** on `clk_sys` with
  all thirty worst paths inside the vendored TG68K kernel — because `Seta.sdc` was still the
  template's two lines and Phase 0's multicycle constraint had only ever existed in a standalone
  synthesis-check project. Carrying it across took that to **−3.956 ns**, and registering the CPU
  interface into the sprite chip, the palette and `pairlove`'s block took it to **−1.751 ns**.

  The critical path has left the CPU: all fifteen worst paths now run from the sprite chip's
  `spriteylow` RAM output through three chained 8-bit adders into the foreground hit test. That
  arithmetic is loop-invariant apart from the RAM byte itself, so it is now pre-added once per
  line — one adder off the RAM instead of three.
* **The screen timing is a hypothesis.** MAME has no raw timings for this hardware. An 8 MHz dot
  clock, htotal 512 and vtotal 260 reproduce the refresh rates the driver declares, and the sync
  positions inside the blanking are plausible rather than measured. Only `daioh`'s 57.42 Hz is
  marked "verified on PCB" anywhere.
* **Some behaviour follows MAME where MAME itself is unsure.** `blockcar`'s IRQ 3 is asserted at
  vblank and no acknowledge is mapped anywhere, so it stays pending forever and the game must mask
  it; the X1-010 carries MAME's own `if (freq == 0) freq = 4` hack, which its source says is broken
  for another game. Both are reproduced deliberately and flagged in the RTL. `docs/ROADMAP.md`
  keeps the list.

### Todo

- [ ] Close timing on `clk_sys`
- [ ] Run on a DE10-nano
- [ ] Phase 2: the X1-012 tilemap engine, one layer (`drgnunit`, `stg`, `qzkklogy`, `qzkklgy2`)
- [ ] Phase 3: two layers, the X1-011 mixer, the PIT, X1-010 sample banking
- [ ] Phase 4: the 6bpp families, and the 24-bit `.mra` interleave they need
- [ ] Phase 5: `blandia`'s palette-offset effect, `zombraid`'s light gun and battery RAM
- [ ] Hiscore support, CRT offset, savestates
- [ ] The three 14.318181 MHz games (`orbs`, `keroppi`, `krzybowl`) need a Bresenham clock enable

### Resource usage

Whole core, on the DE10-nano's Cyclone V 5CSEBA6, speed grade 7, from the last completed build:

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 20,871 (50%) | 41,910 |
| Block memory bits | 1,699,009 (30%) | 5,662,720 |
| RAM blocks | 222 (40%) | 553 |
| DSP blocks | 44 (39%) | 112 |
| PLLs | 3 | 6 |

**−1.751 ns** of setup slack on `clk_sys` (96 MHz). This is a timing problem, not a capacity one.

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant.

What the assistant is held to, and what shows in the repository:

* Hardware facts come from the MAME driver. Every ROM interleave, graphics layout, register map
  and timing constant is traced to a line of source or to a measurement.
* Claims are checked before they are written down. Graphics layouts were decoded from real ROM
  data before any RTL used them; the CPU is diffed against a real MAME trace; the sprite engine and
  the video path are diffed against MAME's own render; the sound is diffed against a line-by-line
  transcription of MAME's mixer.
* Values are **extracted, not typed**. The ROM_START records, the DIP switches, the `.mra` titles
  and the address map are all read out of the driver or out of the RTL by script, because
  transcribing seventy-two DIP settings by hand is a coin flip repeated seventy-two times.
* Where the reference and the hardware disagree, or where MAME's own comments disclaim accuracy,
  that is recorded as an open question rather than silently resolved. The list is in
  [Status](#status) and in `docs/ROADMAP.md`.

`docs/LESSONS_LEARNED.md` carries the rules this work accumulated. Several are about the
assistant's own mistakes — a test that reported failure for being early, a comment that described a
register stage the code did not have, a constraint proved in a side project and never carried
across.

## Verification

Not PCB-validated. MAME is the accuracy reference, with its own acknowledged uncertainties noted
where they matter.

Every number below was produced by a script in this repository and can be reproduced:

| what | against | result |
|-|-|-|
| ROM interleaves, 43 sets | MAME's own CPU fetches | ~9,000 words, zero mismatches |
| `maincpu.sv` boot | MAME's bus trace, 36 sets | 36 of 36, at three ROM latencies |
| Sprite model | MAME's own render, 8 sets × 3 frames | 24 of 24 frames pixel-identical |
| `x1_001.sv` | the sprite model | 72 of 72 runs, 92,160 pixels each |
| Video path | MAME's own render, in RGB | 44 of 48 frames pixel-identical |
| `x1_010.sv` | a transcription of MAME's mixer | 4,096 of 4,096 samples, latencies 2–40 |
| SDRAM backend | the image that went in | 1,523 and 5,497 reads, zero mismatches |
| **Whole core** | **MAME, with real peripherals** | **93,775 of 100,000 accesses aligned, zero data mismatches** |
| `.mra` files | the ROM_START ground truth | 8 of 8 byte-for-byte |

The four video frames that are not identical are all the same thing: `thunderl` and `thunderla`
at frame 300, a boot state with 536 sprites on one line, where the per-line budget drops the
bottom-most of them. 460 and 565 pixels of 92,160 — 0.5–0.6% — and no gameplay frame is affected
at any ROM latency.

The last two rows are the ones worth reading twice.

* **The whole-core bus diff** (`scripts/diff_core_trace.py`) runs the real core with its real
  peripherals against MAME with its real peripherals, so it follows a game past its own start-up
  where a CPU-only test cannot. Zero data mismatches means every DIP byte, every input port, the
  protection register and every decoded region return exactly what MAME's do. It found two real
  gaps nothing else would have.
* **The `.mra` files are proved, not written.** Each region's image is built from the driver's
  ROM_START semantics, candidate interleave forms are *tested* against it — the list deliberately
  includes the wrong ones — and the finished file is re-read and compared byte for byte. Deriving an
  interleave by reasoning about byte order has a far worse record than testing every candidate.

Other tooling:

* **Ground truth captured from MAME automatically.** `scripts/mame_capture.py` drives MAME
  headlessly over its Lua interface and dumps every region the video hardware reads, plus the frame
  MAME rendered from exactly that state.
* **The `sim/` suite** — a ModelSim testbench for every project-authored block, plus integration
  benches that run the whole memory path through the real SDRAM controller and a command-decoding
  chip model, and one that boots a real ROM set through the entire core.
* **Instruments built in from the start** — saturating counters paired with totals, a per-line
  budget monitor, and OSD debug switches, so a fault on hardware can be read off rather than
  guessed at.

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
