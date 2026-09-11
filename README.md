# Seta core for MiSTer

MiSTer FPGA core for [Seta](https://en.wikipedia.org/wiki/Seta_Corporation)'s X1-010 arcade
hardware — MAME's `seta/seta.cpp` — built with Quartus Prime 17.0.2 Lite for the DE10-nano.

**Runs on MiSTer.** Twenty-five of the twenty-six built sets run on a DE10-nano and render with
correct colours. Strike Gunner flickers and Gundhara halts in its own error trap; the rest are
clean to the eye. Per-set results are in the table below.

## Contents

- [Games](#games)
- [Hardware](#hardware)
- [History](#history)
- [Installation](#installation)
- [Building](#building)
- [Status](#status)
  - [Todo](#todo)
  - [Resource usage](#resource-usage)
- [AI Attestation](#ai-attestation)
- [Verification](#verification)
- [Acknowledgements](#acknowledgements)
- [Layout](#layout)
- [License](#license)

## Games

The full scope is the X1-010 mainline of `seta.cpp` — 43 sets across 14 memory-map families.
Twenty-six are built, in 31 `.mra` files with the clones. Every one is 68000 + X1-001A/X1-002A
sprites + X1-006 palette + X1-010 sound; what separates the board groups is how many X1-012
tilemap layers sit behind the sprites, and at what depth.

| Name | Year | Manufacturer | Main CPU | Tilemaps | Notes | Status |
|-|-|-|-|-|-|-|
| Wit's | 1989 | Athena (Visco license) | M68000 @ 8 MHz | 0 | Four players | Good |
| Thunder & Lightning | 1990 | Seta | M68000 @ 8 MHz | 0 | Two sets. Has a protection register | Good |
| Pairs Love | 1991 | Athena / Nihon System | M68000 @ 8 MHz | 0 | 2048 palette entries, and a write-history block | Good |
| Block Carnival / Thunder & Lightning 2 | 1992 | Visco | M68000 @ 8 MHz | 0 | Inputs and DSW both move | Good |
| Ultraman Club | 1992 | Banpresto | M68000 @ 16 MHz | 0 | | Good |
| SD Gundam Neo Battling | 1992 | Banpresto | M68000 @ 16 MHz | 0 | | Good |
| Athena no Hatena? | 1993 | Athena | M68000 @ 16 MHz | 0 | 2 MB of sprites, 64 KB of work RAM mirrored | Good |
| Dragon Unit / Castle of Dragon | 1989 | Athena / Seta | M68000 @ 8 MHz | 1× 4bpp | | Good |
| Strike Gunner S.T.G | 1991 | Athena / Tecmo | M68000 @ 8 MHz | 1× 4bpp | | Flickers badly |
| Quiz Kokology | 1992 | Tecmo | M68000 @ 8 MHz | 1× 4bpp | | Good |
| Quiz Kokology 2 | 1992 | Tecmo | M68000 @ 8 MHz | 1× 4bpp | | Good |
| Rezon | 1991 | Allumer | M68000 @ 16 MHz | 2× 4bpp | | Good |
| Daioh | 1993 | Athena | M68000 @ 16 MHz | 2× 4bpp | The one refresh rate verified on a PCB | Good |
| Mobile Suit Gundam | 1993 | Banpresto | M68000 @ 16 MHz | 2× 4bpp | 4 MB of sprites, the largest in the driver | Good |
| War of Aero | 1993 | Yang Cheng | M68000 @ 16 MHz | 2× 4bpp | uPD71054C timer | Good |
| Oishii Puzzle Ha Irimasenka | 1993 | Sunsoft / Atlus | M68000 @ 16 MHz | 2× 4bpp | `ROMREGION_INVERT` sprites | Good |
| Kamen Rider Club Battle Race | 1993 | Banpresto | M68000 @ 16 MHz | 2× 4bpp | Timer; both tile layers carved out of one ROM | Good |
| Eight Forces | 1994 | Tecmo | M68000 @ 16 MHz | 2× 4bpp | 12 MB of ROM | Good |
| Magical Speed | 1994 | Allumer | M68000 @ 16 MHz | 2× 4bpp | Timer; as Kamen Rider | Good |
| Zing Zing Zip | 1992 | Allumer / Tecmo | M68000 @ 16 MHz | 6bpp + 4bpp | Its vblank IRQ is level 3; 10922 tiles, the one layer whose count is not a power of two | Good |
| J. J. Squawkers | 1993 | Athena / Able | M68000 @ 16 MHz | 2× 6bpp | One byte ROM shared between two word ROMs | Good |
| Mad Shark | 1993 | Allumer | M68000 @ 16 MHz | 2× 6bpp | Both tile regions `ROM_COPY`d out of one 3 MB block | Good |
| Extreme Downhill | 1995 | Sammy | M68000 @ 16 MHz | 6bpp + 4bpp | 320 wide; a 4 MB tile region | Good |
| Sokonuke Taisen Game | 1995 | Sammy | M68000 @ 16 MHz | 6bpp + 4bpp | Extreme Downhill's machine config; its second tile region is a 256-byte stub | Good |
| Gundhara | 1995 | Banpresto | M68000 @ 16 MHz | 2× 6bpp | 8 MB of sprites and 17 MB of ROM, the largest in the driver | Halts in its own error trap |

The two-layer boards also need the X1-011's full order resolution and, for five of them, a
uPD71054C timer. The 6bpp layers add a third: their tiles are 24 bits per four pixels, and the
palette address is formed by an adder rather than a concatenation — see
[`rtl/video/x1_011_index.sv`](rtl/video/x1_011_index.sv). What remains is `blandia` and
`zombraid`.

## Hardware

| Chip | Function | Status |
|-|-|-|
| X1-001A + X1-002A | Sprites, and the "floating tilemap" made of sprite columns | Written, verified against MAME |
| X1-006 | Palette, `xRRRRRGGGGGBBBBB` | Written |
| X1-007 | Video blanking | Written (timing is a hypothesis) |
| X1-010 | 16-voice PCM / wavetable sound | Written, verified sample for sample |
| X1-004 | Input handling | Folded into the address decode |
| X1-005 / X1-009 | NVRAM | No protection is emulated in `seta.cpp`; not needed in Group A |
| X1-011 | Graphics mixing | Written — full layer/sprite order resolution |
| X1-012 | Tilemaps | Written, verified against MAME across 24 runs |
| uPD71054C | Programmable interval timer (8254) | Channel 0, modes 0/2/3 — all any board wires |

Some links discussing the hardware:
* https://www.arcade-museum.com/manuf/Seta.html

## History

* **`Arcade-Seta_20260911.rbf`**
  * All twenty sets run: War of Aero's work RAM widened to the 64 KB its map declares, and
    Mobile Suit Gundam's sprites restored by fixing the `setac_eof` buffer copy
  * The renderer samples sprite RAM, scroll, tilemap bank and the mixer's order register at
    vblank, which is what fixed the mid-frame tear on Daioh and Eight Forces
  * DIP defaults and the six P1/P2 input layouts checked against MAME's `-listxml`; Kamen
    Rider's Country jumper and Daioh's buttons 4-6 reach the game for the first time
* **`Arcade-Seta_20260910.rbf`**
  * **Alpha release**
  * Support for a bunch of games in varying states of running

## Installation

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`
* Take the `*.mra` files from `releases/` and subdirs and put them in `_Arcade`
* Put the MAME merged or split ROMs in `games/mame`

## Building

Two Quartus revisions from one source. `Seta_stp` defines `DEBUG_ISSP`: it builds the six ISSP
probes and shows the OSD's Debug page, where Sprites, Tilemap 0 and Tilemap 1 can each be blanked
at the mixer -- the engines keep running, so turning a layer off changes nothing else in the
picture. `Seta` compiles both out.

```
python scripts/build_staged.py               # Seta_stp, the default
python scripts/build_staged.py --rev Seta    # the release build
python scripts/deploy.py --rbf-only --log build/q_staged.log \
    --rbf build/output_files/Seta_stp.rbf --sta build/output_files/Seta_stp.sta.summary
```

Builds run in a git worktree at `build/` from HEAD, not in the tree. See `docs/WORKFLOW.md`.

**The fitter seed is part of the build.** Build 10000019 and build 10000020 are the same commit at
seeds 2 and 7: seed 2 reported every clock domain positive (+0.950 on clk_sys) and killed four
games in boot, seed 7 has a worse worst slack (+0.446) and runs all twenty. Neither `Seta.sdc` nor
`sys/sys_top.sdc` constrains an SDRAM pin, so those paths are analysed on trust. Both `.qsf` files
pin `SEED 7`, and `build/BUILT_COMMIT` records the seed each build used. If a build regresses games
the diff cannot reach, rebuild the same commit at another seed before bisecting the source.

## Status

Hardware results, every set launched on a DE10-nano in turn, with the CPU probe read and a
screenshot taken:

| group | tilemaps | outcome |
|-|-|-|
| A | 0 | 7 of 7 play |
| B | 1× 4bpp | 4 of 4 play; Strike Gunner flickers |
| C | 2× 4bpp | 8 of 8 play |
| D | 6bpp | 5 of 6 play; Gundhara halts |

What is built and verified in simulation:

* **M68000** — TG68KdotC_Kernel driven directly, with address decode for all **14** of the memory
  maps in scope. Boot-diffed against MAME's own bus trace for 38 of 38 sets.
* **X1-001 sprites** (`rtl/video/x1_001.sv`) — 512 foreground entries plus the 16-column floating
  tilemap, rendered per scanline into a double-buffered 512-pixel line buffer. Front-to-back with
  a written bit, so running out of time drops the bottom-most sprites rather than the ones on top.
  One 64-bit SDRAM granule per 16-pixel row, via a download-time layout permutation. Includes
  `setac_eof` sprite buffering.
* **X1-012 tilemaps** (`rtl/video/x1_012.sv`) — one or two 4bpp layers, per scanline into a
  double-buffered line buffer, four granule reads per tile row. Pixel-identical to the model on
  24 of 24 fixture runs, on frames that contain flipped tiles.
* **X1-011 mixing** (`rtl/video/seta_video.sv`) — the layer swap and the sprites-above-front bit
  out of `vregs`, resolving sprite and both layers per pixel.
* **X1-010 sound** (`rtl/sound/x1_010.sv`) — 16 voices, PCM and wavetable, written from MAME
  because no FPGA implementation of this chip exists anywhere. Sample banking for the boards that
  window their samples through `vregs`.
* **uPD71054C** (`rtl/cpu/seta_pit.sv`) — channel 0, binary, modes 0/2/3. Everything else asserts
  in simulation rather than quietly running at the wrong rate.
* **Video path** — palette, timing generator, the two scanline interrupts, and HDMI rotation
  (Auto from the driver's `ROT`, or forced CW/CCW) at a 4:3 physical aspect.
* **Interrupts** — both of `seta.cpp`'s clearing rules: HOLD_LINE, cleared when the CPU
  acknowledges, and ASSERT_LINE, cleared only by the board's own write.
* **SDRAM backend** — every runtime ROM on one chip in three layouts (4 MB, 5 MB, 12 MB), ports
  assigned by deadline, with the sprite layout permutation applied on the way in.
* **`.mra` generation** — all 20 sets, each proved byte for byte against its `ROM_START`.

Known issues:

* **Gundhara halts in its own error trap.** Its ROM loads in full (17 MB, the largest in the
  driver), its CPU boots and matches MAME's bus trace, and it runs the work-RAM, palette and
  sound-RAM tests -- then takes an illegal-instruction exception and stops at the `bra.s *` every
  handler in the driver ends with. It never writes tile VRAM. The other five 6bpp sets share its
  board arm and code path and all run, so this is specific to it; what it alone has is LAYOUT_E,
  8 MB of sprites and a 17 MB image. Probe A records the last twenty control transfers and
  freezes at a halt loop, which is the next thing to read.
* **Strike Gunner flickers.** Cause unknown.
* **Sprites clip wrongly at the bottom edge** — one entering from the lowest scanline appears all
  at once. Affects every game. The sprite engine matches MAME across 90 simulation runs *inside the
  visible area*, so this is at the boundary of the rendered region. Parked.
* **Screen flip in the tilemap is unresolved.** Per-tile and per-sprite flipping are verified;
  whole-screen flip is not, because MAME's own `seta.cpp` TODO says its tilemap flip is kludged and
  wrong for three of the sets in scope. There is no reference to check against short of a PCB
  video. Parked; see `docs/MAME_DIVERGENCE.md`.
* **The screen timing is derived, not measured.** MAME publishes no raw timings for this hardware
  and declares a bare 60 Hz for 28 sets. This core runs 512 × 272 at 8 MHz — 57.4449 Hz — for
  every set, 0.043% from `daioh`'s 57.42, the one rate marked "verified on PCB". All 33 machine
  configs in the driver declare the same total, so the narrower and shorter games draw a smaller
  window inside the same raster rather than running at a different rate.
* **Some behaviour follows MAME rather than hardware.** `blockcar`'s IRQ 3 is asserted at vblank
  with no acknowledge mapped anywhere, so it stays pending forever and the game must mask it; the
  X1-010 carries MAME's own `if (freq == 0) freq = 4` hack, which its source says is broken for
  another game. Both are reproduced deliberately and flagged in the RTL.
  `docs/MAME_DIVERGENCE.md` keeps the list, in two halves: what MAME admits is a hack, and where
  this core deliberately differs.

### Todo

- [x] Close timing on every clock
- [x] Run on a DE10-nano
- [x] Phase 2: the X1-012 tilemap engine, one layer (`drgnunit`, `stg`, `qzkklogy`, `qzkklgy2`)
- [x] Phase 3: two layers, the X1-011 mixer, the PIT, X1-010 sample banking
- [x] Run Groups B and C on a DE10-nano
- [x] Group C on hardware: 8 of 8
- [x] War of Aero's illegal instruction -- its work RAM was a quarter of the declared size
- [x] Mobile Suit Gundam's sprites -- the `setac_eof` copy read the wrong control byte and moved
      the wrong distance
- [x] The mid-frame tear on Daioh and Eight Forces
- [ ] Strike Gunner's flicker
- [x] DIP switches checked against MAME's own `-listxml`, defaults included
- [x] Inputs: six P1/P2 layouts, daioh's EXTRA buttons, counts checked against MAME
- [ ] Screen flip in the tilemap, and the bottom-edge sprite clip
- [x] Phase 4: the 6bpp families, and the 24-bit `.mra` interleave they need. Five of six run;
      both palette-remap families are pixel-identical to MAME on a whole frame in simulation
- [ ] Gundhara's error trap
- [ ] Phase 5: `blandia`'s palette-offset effect, `zombraid`'s light gun and battery RAM
- [ ] `hiscore.v` support, CRT offset, savestates
- [x] `_alternatives` for the clones that share a parent's board config (`daioha`, `rezono`,
      `msgundam1`)
- [ ] `daiohc` — the `wrofaero` machine config with `daioh`-sized graphics, needs its own arm
- [ ] The three 14.318181 MHz games (`orbs`, `keroppi`, `krzybowl`) need a Bresenham clock enable

### Resource usage

Whole core, on the DE10-nano's Cyclone V 5CSEBA6, speed grade 7:

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 23,584 (56%) | 41,910 |
| Block memory bits | 3,300,545 (58%) | 5,662,720 |
| RAM blocks | 419 (76%) | 553 |
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
  * The ROM_START records, the DIP switches to generate the `.mra` titles

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
