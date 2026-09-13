# Seta core for MiSTer

MiSTer FPGA core for [Seta](https://en.wikipedia.org/wiki/Seta_Corporation)'s X1-010 arcade
hardware — MAME's `seta/seta.cpp` — built with Quartus Prime 17.0.2 Lite for the DE10-nano.

## Contents

- [Games](#games)
  - [Game Notes](#game-notes)
  - [Supported](#supported)
  - [Out of scope for now](#out-of-scope-for-now)
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

The goal is to support the collection of hardware covered by MAME in `seta.cpp`. Minus bootlegs on different hardware, and betting hardware.

### Game Notes

* **Daioh** - You can flip between the USA 6 button and the Japanese 2 button arrangement from the DIP menu

* **Zombie Raid** - There is options to help with simulating a lightgun
  * P1 stick / P2 stick (Auto / Aim / D-pad) — 'Auto' reads a fully deflected axis as a direction and a partial one as a position. 'D-pad' for when using e.g. an arcade stick simulating an analogue left-stick. 'Aim' is absolute behaviour for a real analog stick.
  * Crosshair - (P1 / P2 / P1+P2) - Self-explanatory. Matches the location the game knows the cursor to be. Red is P1, Blue is P2. It's hack.
  * Mouse aims (P1 / P2 / Off) — a mouse moves that player's aim, with left button as Trigger and right as Reload. Relative, so it inherits the game's own calibration.
  * The gun calibration is kept in battery RAM, which is saved to the `.nvm` file when the OSD is next opened (or from `Save settings`).

* **CRT adjust** (all games) - H-Size, H-Position and V-Shift for an analog CRT, from rmonic79's [Arcade-Raiden_MiSTer](https://github.com/rmonic79/Arcade-Raiden_MiSTer).
  * **CRT width: Match 384** (320-wide games only: Extreme Downhill, Sokonuke Taisen, Oishii Puzzle) - The option holds each pixel 1.2x as long, so the picture covers the 384-wide games' area, while the line (15.625 kHz), frame rate (57.44 Hz) and syncs stay the same. 
  * V-Size is left out: the core already uses 542 of the device's 553 RAM blocks.

### Supported

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
| Strike Gunner S.T.G | 1991 | Athena / Tecmo | M68000 @ 8 MHz | 1× 4bpp | |
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
| Blandia | 1992 | Allumer | M68000 @ 16 MHz | 2× 6bpp | Second palette bank and its offset effect; banked samples |
| J. J. Squawkers | 1993 | Athena / Able | M68000 @ 16 MHz | 2× 6bpp |  |
| Mad Shark | 1993 | Allumer | M68000 @ 16 MHz | 2× 6bpp |  |
| Extreme Downhill | 1995 | Sammy | M68000 @ 16 MHz | 6bpp + 4bpp | 320 wide; a 4 MB tile region |
| Sokonuke Taisen Game | 1995 | Sammy | M68000 @ 16 MHz | 6bpp + 4bpp |  |
| Gundhara | 1995 | Banpresto | M68000 @ 16 MHz | 2× 6bpp | 8 MB of sprites and 17 MB of ROM, a second work-RAM block |
| Zombie Raid | 1995 | American Sammy | M68000 @ 16 MHz | 2× 6bpp | ADC0834 light gun, battery-backed RAM, 4 MB of samples |

### Out of scope for now

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
| J. J. Squawkers (bootleg) | X1-010, own memory map |
| J. J. Squawkers (bootleg, Blandia Conversion) | X1-010, own memory map |
| Simpson Junior (bootleg of J. J. Squawkers) | X1-010, own memory map |
| Mobile Suit Gundam (bootleg) | X1-010, own memory map |
| Jockey Club (v1.18) | Betting hardware: ACIA6850 serial, hoppers |
| International Toote (Germany, P523.V01) | Betting hardware |
| International Toote II (v1.24, P387.V01) | Betting hardware |
| Sport of Kings (France, P436.08) | Betting hardware |
| Gran Derby (Spanish hack of Jockey Club) | Betting hardware |
| Ultra Toukon Densetsu (Japan) | X1-010 + Z80 and YM3438 |
| Crazy Fight | YM3812 + OKI M6295 |
| Daioh (prototype, earliest) | missing program ROMs |

## Hardware

| Chip | Function | Status |
|-|-|-|
| X1-001A + X1-002A | Sprites, and the "floating tilemap" made of sprite columns | Written, verified against MAME |
| X1-006 | Palette, `xRRRRRGGGGGBBBBB` | Written |
| X1-007 | Video blanking | Written |
| X1-010 | 16-voice PCM / wavetable sound | Written, verified against MAME |
| X1-004 | Input handling | Folded into the address decode |
| X1-005 / X1-009 | NVRAM | Zombie Raid's battery RAM, saved to the `.nvm` file |
| X1-011 | Graphics mixing | Written |
| X1-012 | Tilemaps | Written, verified against MAME |
| uPD71054C | Programmable interval timer (8254) | Written, channel 0 (the IRQ 4 timer) |
| ADC0834 | Zombie Raid's light gun ADC | Written |

Some links discussing the hardware:
* https://www.arcade-museum.com/manuf/Seta.html

## History

* **`Arcade-Seta_20260913.rbf`**
  * Fast ROM loading
  * Timer interrupt ran at half rate: music at the right speed in War of Aero and the other five timer games
  * Flip screen DIP now works for all games that have one, as a true 180 degree rotation (MAME is 128 px / 8 lines out, see `docs/MAME_DIVERGENCE.md`)
  * Oishii Puzzle tile layers no longer flipped with the sprites
  * Mobile Suit Gundam interrupts fixed
  * Extreme Downhill boot screen black
  * Tile row cache for busy 6bpp lines
  * CRT adjust: H-Size, H-Position, V-Shift
  * CRT width: Match 384 for the 320-wide games

* **`Arcade-Seta_20260912.rbf`**
  * Blandia and Zombie Raid added
  * Sound in Extreme Downhill and Sokonuke Taisen
  * J. J. Squawkers passes its boot RAM test

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
* **Thunder & Lightning** - Character sprites in attract glitch in at the edge of the screen. The same in MAME. Appears to be an original game bug.

See `docs/MAME_DIVERGENCE.md` for cases that are considered 'hacks' from MAME, and also any cases where we diverge from MAME.

### Todo

- [ ] `hiscore.v` support, savestates
- [ ] `zombraidp` / `zombraidpj` `.mra` files -- ERASE00 regions loaded in three byte lanes
- [ ] `daiohc` — the `wrofaero` machine config with `daioh`-sized graphics, needs its own arm
- [ ] The three 14.318181 MHz games (`orbs`, `keroppi`, `krzybowl`) need a Bresenham clock enable
- [ ] Upstream to MAME: flip screen as the unflipped frame rotated 180 -- the x1_012 tilemap mirror about the 512x256 bitmap, and the per-game flip offsets (`fg_yoffs`, `fg_xoffs`, layer `xoffs`) in `docs/MAME_DIVERGENCE.md`

### Resource usage

Whole core (`Arcade-Seta_20260913.rbf`), on the DE10-nano's Cyclone V 5CSEBA6, speed grade 7:

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 26,348 (63%) | 41,910 |
| Block memory bits | 4,261,313 (75%) | 5,662,720 |
| RAM blocks | 542 (98%) | 553 |
| DSP blocks | 44 (39%) | 112 |
| PLLs | 3 | 6 |

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant.

## Verification

Not PCB-validated. MAME is the accuracy reference for the most part, with its own acknowledged uncertainties noted where they matter. Goal is to reconcile the inconsistencies and unlikely behaviour. The exception so far is flip screen, checked against the unflipped picture rotated 180 degrees rather than against MAME.

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
- **Umberto Parisi** ([rmonic79](https://github.com/rmonic79)) for `crt_adjust.sv`, from
  [Arcade-Raiden_MiSTer](https://github.com/rmonic79/Arcade-Raiden_MiSTer).

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| - | - |
| `sys` | MiSTer framework, vendored from the template |
| `rtl` | core source |
| `releases` | `.mra` files, and the current `.rbf` |
| `docs` | design notes and hard-won debugging lessons |
| `sim` | ModelSim and Verilator testbenches |
| `scripts` | capture/verification tooling (see [`scripts/README.md`](scripts/README.md)) |
| `debug` | reference captures from MAME used as ground truth (gitignored) |
| `roms` | your own MAME sets (gitignored, never committed) |

## License

GPL v3 (see `LICENSE`). Imported components keep their own licences and are GPLv3-compatible:
TG68K.C (LGPLv3+), the adapted SDR SDRAM controller (Sorgelig, GPL-3.0-or-later),
`screen_rotate_two.sv` (Sorgelig, GPLv2), `crt_adjust.sv` (rmonic79, GPL-3.0-or-later), and the MiSTer
framework in `sys/`.

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
