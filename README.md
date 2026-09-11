# Seta core for MiSTer

MiSTer FPGA core for [Seta](https://en.wikipedia.org/wiki/Seta_Corporation)'s X1-010 arcade
hardware — MAME's `seta/seta.cpp` — built with Quartus Prime 17.0.2 Lite for the DE10-nano.

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

The goal is to support the collection of hardware covered by MAME in `seta.cpp`. Minus bootlegs on differnet hardware, and betting hardware.

Blandia and Zombie Raid are not yet supported.

| Name | Year | Manufacturer | Main CPU | Tilemaps | Notes |
|-|-|-|-|-|-|
| Wit's | 1989 | Athena (Visco license) | M68000 @ 8 MHz | 0 | Four players |
| Thunder & Lightning | 1990 | Seta | M68000 @ 8 MHz | 0 | Has protection |
| Pairs Love | 1991 | Athena / Nihon System | M68000 @ 8 MHz | 0 | 2048 palette entries |
| Block Carnival / Thunder & Lightning 2 | 1992 | Visco | M68000 @ 8 MHz | 0 | |
| Ultraman Club | 1992 | Banpresto | M68000 @ 16 MHz | 0 | |
| SD Gundam Neo Battling | 1992 | Banpresto | M68000 @ 16 MHz | 0 | |
| Athena no Hatena? | 1993 | Athena | M68000 @ 16 MHz | 0 | 2 MB of sprites, 64 KB of work RAM mirrored |
| Dragon Unit / Castle of Dragon | 1989 | Athena / Seta | M68000 @ 8 MHz | 1× 4bpp | |
| Strike Gunner S.T.G | 1991 | Athena / Tecmo | M68000 @ 8 MHz | 1× 4bpp | | Flickers badly |
| Quiz Kokology | 1992 | Tecmo | M68000 @ 8 MHz | 1× 4bpp | |
| Quiz Kokology 2 | 1992 | Tecmo | M68000 @ 8 MHz | 1× 4bpp | |
| Rezon | 1991 | Allumer | M68000 @ 16 MHz | 2× 4bpp | |
| Daioh | 1993 | Athena | M68000 @ 16 MHz | 2× 4bpp |  |
| Mobile Suit Gundam | 1993 | Banpresto | M68000 @ 16 MHz | 2× 4bpp | 4 MB of sprites |
| War of Aero | 1993 | Yang Cheng | M68000 @ 16 MHz | 2× 4bpp | uPD71054C timer |
| Oishii Puzzle Ha Irimasenka | 1993 | Sunsoft / Atlus | M68000 @ 16 MHz | 2× 4bpp |  |
| Kamen Rider Club Battle Race | 1993 | Banpresto | M68000 @ 16 MHz | 2× 4bpp | Timer |
| Eight Forces | 1994 | Tecmo | M68000 @ 16 MHz | 2× 4bpp | 12 MB of ROM |
| Magical Speed | 1994 | Allumer | M68000 @ 16 MHz | 2× 4bpp | Timer; as Kamen Rider |
| Zing Zing Zip | 1992 | Allumer / Tecmo | M68000 @ 16 MHz | 6bpp + 4bpp | vblank IRQ is level 3 |
| J. J. Squawkers | 1993 | Athena / Able | M68000 @ 16 MHz | 2× 6bpp |  |
| Mad Shark | 1993 | Allumer | M68000 @ 16 MHz | 2× 6bpp |  |
| Extreme Downhill | 1995 | Sammy | M68000 @ 16 MHz | 6bpp + 4bpp | 320 wide; a 4 MB tile region |
| Sokonuke Taisen Game | 1995 | Sammy | M68000 @ 16 MHz | 6bpp + 4bpp |  |
| Gundhara | 1995 | Banpresto | M68000 @ 16 MHz | 2× 6bpp | 8 MB of sprites and 17 MB of ROM, a second work-RAM block |

### Out of scope

| MAME description | Why |
|-|-|
| Thunder & Lightning (bootleg with Tetris sound, set 1) | Z80 + YM2151 |
| Thunder & Lightning (bootleg with Tetris sound, set 2) | Z80 + YM2151 |
| Wiggie Waggie | Z80 + OKI M6295 |
| Super Bar | Z80 + OKI M6295 |
| Block Carnival / Thunder & Lightning 2 (bootleg) | Z80 + OKI M6295 + YM2151 |
| Zing Zing Zip (bootleg) | OKI M6295; video registers rearranged |
| Mad Shark (bootleg) | OKI M6295 |
| Triple Fun | OKI M6295 |
| Sum-eoitneun Deongdalireul Chat-ara! | OKI M6295 |
| J. J. Squawkers (bootleg) | X1-010 kept, own memory map |
| J. J. Squawkers (bootleg, Blandia Conversion) | X1-010 kept, own memory map |
| Simpson Junior (bootleg of J. J. Squawkers) | X1-010 kept, own memory map |
| Mobile Suit Gundam (bootleg) | X1-010 kept, own memory map |
| Jockey Club (v1.18) | Betting hardware: ACIA6850 serial, hoppers |
| International Toote (Germany, P523.V01) | Betting hardware |
| International Toote II (v1.24, P387.V01) | Betting hardware |
| Sport of Kings (France, P436.08) | Betting hardware |
| Gran Derby (Spanish hack of Jockey Club) | Betting hardware |
| Ultra Toukon Densetsu (Japan) | X1-010 **plus** a Z80 and YM3438 |
| Crazy Fight | YM3812 + OKI M6295 |
| Daioh (prototype, earliest) | `MACHINE_NOT_WORKING`: "needs correct program ROMs" |

## Hardware

| Chip | Function | Status |
|-|-|
| X1-001A + X1-002A | Sprites, and the "floating tilemap" made of sprite columns | Written, verified against MAME |
| X1-006 | Palette, `xRRRRRGGGGGBBBBB` | Written |
| X1-007 | Video blanking | Written |
| X1-010 | 16-voice PCM / wavetable sound | Written, verified against MAME |
| X1-004 | Input handling | Folded into the address decode |
| X1-005 / X1-009 | NVRAM |  |
| X1-011 | Graphics mixing | Written |
| X1-012 | Tilemaps | Written, verified against MAME |
| uPD71054C | Programmable interval timer (8254) |  |

Some links discussing the hardware:
* https://www.arcade-museum.com/manuf/Seta.html

## History

* **`Arcade-Seta_20260911.rbf`**
  * All twenty sets run
  * Tilemap tearing fixed
  * Inputs/DIPs all reviewed and corrected (6 button Daioh)
* **`Arcade-Seta_20260910.rbf`**
  * **Alpha release**
  * Support for a bunch of games in varying states of running

## Installation

* Take the latest `*.rbf` from `releases/` and put it in `_Arcade/cores`
* Take the `*.mra` files from `releases/` and subdirs and put them in `_Arcade`
* Put the MAME merged or split ROMs in `games/mame`

## Status

Known issues:
* Eight Forces - Check intro against MAME. Sprites too big?
* Extreme Downhill - boot screen background off? No sound.
* Mad Shark - Sprite glitching - reading whilst attributes being written
* Mobile Suit Gundam - resets in game (protection?)
* Oishii Puzzle - some broken tiles
* Sokonuke - No sound
* Zing Zing Zip - Occasionally sprite glitching
* JJ Squawkers - Reporting error at boot

See `docs/MAME_DIVERGENCE.md` for cases that are considered 'hacks' from MAME, and also any cases where we diverge from MAME.

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
- [x] Phase 4: the 6bpp families, and the 24-bit `.mra` interleave they need. Six of six run;
      both palette-remap families are pixel-identical to MAME on a whole frame in simulation
- [ ] Phase 5: `blandia`'s palette-offset effect, `zombraid`'s light gun and battery RAM
- [ ] CRT offset -- a per-game H/V shift in the OSD, so the picture can be centred on a
      real monitor without touching the core's own timing
- [ ] `hiscore.v` support, savestates
- [x] `_alternatives` for the six clones that share a parent's board config (`daioha`,
      `rezono`, `msgundam1`, `thunderla`, `gundharac`, `jjsquawko`)
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
