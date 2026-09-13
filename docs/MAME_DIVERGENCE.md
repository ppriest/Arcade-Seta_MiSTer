# MAME hacks, and where this core diverges

Two lists:

1. **[Hacks in MAME](#hacks-in-mame)** — per-game behaviour with no hardware
   explanation, usually admitted in MAME's own comments. Candidates for
   removal: an FPGA rendering a real raster can often do the general thing a
   frame-at-a-time software renderer cannot.
2. **[Divergences in this core](#divergences-in-this-core)** — where the RTL
   deliberately does not match MAME.

Every entry cites a line of MAME, a measurement, or says "unverified".

---

## Hacks in MAME

### No partial updates — `x1_012.cpp`, `vctrl_w`

> HACK: In reality all MAME drivers should work with VIDEO_UPDATE_SCANLINE, ie
> a partial update every single line. However timing problems in various
> drivers means that registers (both here for the tilemap chip, but also in the
> sprite chip) end up being written at the wrong time, causing corruption if
> partial updates are allowed at all.

Named casualties: **Zombie Raid** (writes horizontal scroll mid-screen),
**Blandia** (Athena stage), **Strike Gunner STG**. The same comment records
that **Caliber 50** proves the chip reads its scroll registers every scanline,
for an underground-area raster effect.

This core renders per scanline: `x1_001.sv` and `x1_012.sv` latch scroll at
`line_start`. Raster effects MAME suppresses should work here without
special-casing.

*Unproven — none of the named games is in scope yet (Zombie Raid and Blandia
are Phase 5, Caliber 50 out of scope). Revisit when a Phase 3+ game writes
scroll mid-frame.*

### Screen flip is kludged — `seta.cpp` TODO

> - drgnunit sprite/bg unaligned when screen flipped (check I/O test in service mode)
> - oisipuzl doesn't support screen flip? tilemap flipping is also kludged in the video driver.
> - eightfrc has alignment problems both flipped and not
> - flip screen and mirror support not working correctly in zombraid

This is SCREEN flip, not per-tile or per-sprite flip. Those are verified:
tile flipx/flipy by `sim/x1_012_tb` across 24 runs on frames containing
flipped tiles, sprite flips by `sim/x1_001_tb` across 90.

*Replaced: see "Screen flip is the unflipped frame rotated 180 degrees" below.*

### `x1_010` zero-frequency substitution

```c
// Meta Fox does write the frequency register, but this is a hack to make it
// "work" with the current setup
// This is broken for Arbalester (it writes 8), but that'll be fixed later.
if (freq == 0) freq = 4;
```

Reproduced. Neither game is in scope; revisit before adding either.

### `x1_010` `VOL_BASE`

Magic scaling constant, no derivation in the source. Reproduced so levels match
MAME. Not defensible as hardware.

### `seta.cpp` "position kludges"

The per-game `set_fg_xoffsets` / `set_fg_yoffsets` / `set_bg_yoffsets` /
`set_xoffsets` calls sit under a comment reading `// position kludges`, several
annotated with how they were arrived at ("correct (test grid and I/O test)",
"sprites unknown, tilemaps correct").

The chips are identical across boards, so a per-game pixel offset is standing
in for something structural. **Candidate for generalisation** — one rule could
replace fourteen constants.

*Transcribed per game. Not investigated.*

### `seta_vregs_w`'s comment contradicts its code

The register documentation says:

```
    ---- --1-     Sprites Above Frontmost Layer
    ---- ---0     Layer 0 Above Layer 1
```

Bit 0 matches: `if (order & 1)` draws layer 1 opaque underneath and layer 0
over it. Bit 1 does not. `seta_layers_update` under `order & 2` draws the
sprites FIRST and the frontmost layer AFTER, so the bit set means the **layer**
is above the sprites -- the opposite of the comment.

This core follows the code. `rtl/video/seta_video.sv`:

```systemverilog
mixed_2l = vregs[1] ? (top_op ? top_px : (lb_hit ? lb_data : bot_px))
                    : (lb_hit ? lb_data : (top_op ? top_px : bot_px));
```

*Verified against `seta.cpp`'s `seta_layers_update`, both branches. Unresolved
which of the two is what the silicon does; no set in scope has been seen to
depend on it.*

### There is no layer-enable bit

`layers_ctrl` in `seta_layers_update` is `~0U` and is only ever narrowed inside
`#ifdef MAME_DEBUG`, by a keypress. It is a debugging aid, not hardware. Worth
recording because a black screen invites the theory that a layer is disabled,
and there is nothing there to disable.

### Colour mode 1 with no second decode

`get_tile_info` selects a gfx set from `vctrl[2]` bit 4; for a 4bpp game that
set does not exist, so MAME `popmessage`s and falls back to 0. Modelled, so a
game setting the bit does not silently render from the wrong place.

---

## Divergences in this core

### Screen timing: daioh's for every game

MAME declares 60 Hz for 28 sets, every one a bare number with no comment. Every
rate that came from a real board is 56.66–57.42 ("verified on PCB",
"approximation from PCB video", "taken from other games but seems to better
match PCB videos", "between 56 and 57 to match a real PCB's game speed").

This core runs 512 × 272 at 8 MHz = **57.4449 Hz for every game**, 0.043% from
daioh's verified 57.42. `daioh` declares the same `set_size` and `set_visarea`
as every Group A game on the same 16 MHz X1-001.

*Deliberate; believed more accurate than MAME's declared rates.*

### Everything the renderer reads is sampled at vblank

The X1-001 renders from a snapshot of its code, Y and control RAM taken late
in vblank, five lines before the frame wraps; the X1-012 latches its scroll
registers and bank bit at vblank, and the mixer its order register. MAME draws the whole frame at vblank from the
registers' values then, which is the same picture. The chip reads scroll per
scanline (MAME's own comment cites Caliber 50's underground raster effect),
so a game that changes scroll mid-frame ON PURPOSE will not show it here.
None of the twenty sets in scope does; Daioh and Eight Forces write scroll
and their whole sprite list from the scanline-112 handler, and rendered live
that showed as a tear across the middle of every frame.

The TILE VRAM itself is NOT buffered -- the engine reads it live, as the chip
does. Measured from MAME's write log: of Daioh's 151,802 mid-picture VRAM
writes, 76,460 go to the bank being displayed and only 16,829 of those to a
tile on screen at the current scroll -- about six visible-tile writes a frame
(Eight Forces: 15,180, the same order). A handful of 16-pixel squares, against
one scroll write that moves every line below it, which is what the split across
the middle actually was.

The sprite snapshot was first taken AT vblank, which is the line the games'
vblank interrupt fires on, so its 9216-cycle copy walked the list while the
handler rewrote it and a sprite drew with another sprite's tile or flip --
only while the CPU ran, worst on Mad Shark. It now starts five lines before
the wrap, and a CPU write during the copy goes to the snapshot too
(`sim/x1_001_tb` writes behind the copy's cursor and checks).

*Deliberate; matches MAME's picture. Caliber 50 would need per-line scroll.*

### One read window in the supported maps is still undecoded

Swept every map this core implements for ranges with a read handler and
compared against maincpu.sv's decode. One is not covered:

| map | range | MAME | status |
|-|-|-|-|
| `kamenrid_map` | `50000c-50000d` | `watchdog_timer_device::reset16_r` | harmless |

`reset16_r` returns `space.unmap()`, so MAME's value there is the unmapped
value too -- decoding it would change nothing.

The other two in this class are now implemented. extdwnhl's watchdog read at
0x40000c WAS load-bearing: the POST uses its value as a byte count. thunderl's
protection PAL at 0xb0000c is implemented in maincpu.sv -- the write window
0x400000-0x41ffff discards its data and derives an 8-bit register from the
write address, checked against `thunderl_protection_w` over all 131072
addresses with 0 mismatches.

An undecoded read is not automatically harmless just because the game boots
past it.

### extdwnhl's fourth work-RAM block is not decoded

`extdwnhl_map` declares four 64 KB blocks of plain RAM:

    map(0x200000, 0x20ffff).ram();
    map(0x210000, 0x21ffff).ram();
    map(0x220000, 0x23ffff).ram();   // "RAM (sokonuke)"

256 KB in all. This core decodes 128 KB (0x200000-0x21ffff) and leaves
0x220000-0x23ffff undecoded, because the work RAM is M10K and 128 KB of it is
already ~128 of the device's 553 blocks against 419 used by everything else.

Measured before deciding: a write tap over 0x220000-0x23ffff across 1440
frames of sokonuke's attract mode records zero accesses, and the set runs on
hardware. Both sets on this map are 6bpp and both were checked. If a mode
nobody has reached does use the block, the symptom is the one an unbacked
region always gives -- a failed power-on memory test, not corruption.

The two blocks that ARE decoded are backed separately rather than mirrored;
see the work-RAM comment in rtl/seta_core.sv for what mirroring them cost.

### The per-game position offsets are kludges, and they are carried verbatim

Every machine_config in `seta.cpp` calls some of

    m_spritegen->set_fg_xoffsets(flip, noflip)    the sprite chip's foreground
    m_spritegen->set_fg_yoffsets(flip, noflip)
    m_spritegen->set_bg_yoffsets(flip, noflip)    its floating tilemap
    X1_012(...).set_xoffsets(flip, noflip)        each tile layer

and the values differ per game on boards that are otherwise identical. The
driver's own comments say what they are: guesses checked against whatever
reference the author had.

| set | fg_xoffs | layer xoffs | what seta.cpp says |
|-|-|-|-|
| thunderl, wits, blockcar, pairlove | 0,0 | -- | "unknown" |
| umanclub, atehate | 0,0 | -- | "correct (test grid)" |
| drgnunit | 2,2 | -2,-2 | "correct (test grid and I/O test)" |
| stg | 0,0 | inherited | "sprites correct? (panel), tilemap correct" |
| qzkklogy | 1,1 | -1,-1 | "correct (timer, test grid)" |
| qzkklgy2 | 0,0 | -3,-1 | "sprites unknown, tilemaps correct (test grid)" |
| daioh, rezon, msgundam, kamenrid | 0,0 | -2,-2 | "correct (test grid, ...)" |
| wrofaero, gundhara | 0,0 | default (0,0) | "correct (test mode)" |
| eightfrc | 4,3 | default | "correct (test mode)" |
| oisipuzl | 1,1 | -1,-1 | "correct (test mode)", flip unsupported |
| magspeed | 0,0 | 0,-2 | "floating tilemap maybe 1px off in test grid" |
| zingzip | 0,0 | -2,-1 | "sprites unknown, tilemaps correct (test grid)" |
| extdwnhl, sokonuke | 0,0 | -2,-2 | "correct (test grid, background images)" |
| jjsquawk | 1,1 | -1,-1 | "correct (test mode)" |
| madshark | 0,0 | default | "unknown (wrong when flipped, but along y)" |

WHY THEY EXIST. Neither MAME nor this core models where a chip's output
actually lands relative to the raster. The X1-001 and the X1-012 each drive
pixels with their own notion of the screen's left edge, set by how the board
wires their sync inputs and by delays through the X1-011 on the way to the
palette; a game's data is then drawn wherever the PCB puts it. Rather than
model that, MAME adds a constant per game and per chip, tuned by eye until a
test grid lines up. That is why boards running the same map need different
values, why nine of them are marked "unknown" or "correct?", and why the driver
carries a TODO asking for a proper table covering flipped and non-flipped
cases.

WHAT THIS CORE DOES. Carries them verbatim from each machine_config, in
seta_board_cfg.sv. Deriving them instead would mean inventing a model of the
video seam that nothing can check, and matching MAME is at least reproducible.
They are a real divergence from hardware all the same: a PCB does not add a
constant, and the offsets marked "unknown" are as likely to be wrong as right.

They also cost real time when they are wrong, because a wrong offset is not a
broken picture -- it is the right picture one or two pixels across, which reads
as an engine bug. Two of them were caught by the full-frame fixtures during
Phase 4: jjsquawk's `set_xoffsets(-1, -1)`, which put 13836 pixels wrong while
looking correct, and gundhara's `set_fg_xoffsets(0, 0)`, which disagreed only
around the edge of every glyph. Both were the model's config, not the RTL --
which is the point of comparing whole frames against MAME rather than eyes
against a screenshot.

### Sprites drawn front to back, with a per-line budget

MAME draws back to front and overwrites. This core draws front to back into a
line buffer with a written bit, first writer wins — the dual, identical output.

It also stops after `line_budget` cycles (6100 of 6144), which MAME has no
equivalent of. A real sprite chip that runs out of line time drops sprites, and
drawing front to back makes the failure mode right: the bottom-most are lost,
where a back-to-front renderer would drop the ones on top.

*Measured: no visible cost across all captured frames at every ROM latency
tested. Only two boot states with 536 sprites on one line are affected.*

### `setac_eof` is not instantaneous

MAME copies 0x800 words at the vblank edge in zero time. This core copies a
word per cycle, ~21 µs at 96 MHz, holding the sprite RAM write port — so a CPU
write into the destination half during that window is lost where MAME keeps it.

*Alternative is a second write port on an 8192-word RAM. Revisit if a game
misbehaves in a way that points here.*

### atehate work RAM is 64 KB, not 1 MB

`atehate_map` declares a megabyte at 0x900000–0x9fffff. Measured from a capture
of the whole window during play: the game touches 0x900061–0x909a19 and
0x9fff7b–0x9ffffb only, which under a 64 KB mirror lands at 0x0061–0x9a19 and
0xff7b–0xfffb with zero collisions.

### zombraid's battery RAM is 256 bytes, saved when the OSD next opens

`zombraid_map` shares the whole of 0x300000–0x30ffff as `"nvram"` and MAME
writes all 64 KB to disk at exit. The game uses 128 bytes of it: the low
lane of 0x300100–0x3001ff behind a write-enable latch at 0x3000f0 (decoded
in docs/ROADMAP.md, "What the battery RAM actually holds"). The core saves
that 256-byte window through the framework's `<nvram index="4" size="256"/>`
file: restored by an index-4 download after the ROM, and requested for
upload when the game closes the latch after writing inside the window --
the end of its SAVE routine. MiSTer services the request when the OSD is
next opened (`MENU_SAVE_CHECK` polls `UIO_CHK_UPLOAD`) or on "Save
settings", so a calibration done in service mode reaches the SD card at the
next OSD visit, not at power-off. The latch itself is not modelled: the
window is plain RAM to the CPU.

### zombraid's guns are sticks and d-pads

seta.cpp's `GUNX1`/`GUNY1`/`GUNX2`/`GUNY2` are `IPT_LIGHTGUN_X/Y`, 0..255,
0x80 at rest, X `PORT_REVERSE`. The core holds a position per player and
moves it from hps_io's left analog stick (absolute, `0x7f - x`, `0x80 + y`,
past a dead zone of 8) or the d-pad (two units a frame, clamped); releasing
either leaves the position where it was, where MAME's analog port would
return to centre. Each axis is independent and takes its direction input
first: an earlier single condition wrote both axes from either one, which
reset Y on every left or right press.

Three kinds of controller say "left" three different ways here -- a digital
panel sets the joystick bit, an arcade panel behind a gamepad encoder sends
no bit and puts the stick on the left USB axis at full deflection, and a
real analog stick sends whatever it is pushed to -- so the OSD carries a
per-player setting. Auto reads a fully deflected axis as a direction and
anything less as a position; Aim always positions; D-pad never does. The ADC itself (`rtl/cpu/adc0834.sv`) is MAME's
`adc083x.cpp` state machine and is not a divergence -- `sim/adc0834_tb`
replays two frames of the game's own `gun_w` words through it -- the input
source is. A mouse or lightgun path is a follow-up.

### zombraid's OSD crosshair reads the game's aim out of work RAM

The game turns the ADC values into calibrated screen positions and keeps
them at 0x20c4aa/0x20c4ac (P1 X/Y) and 0x20c4ae/0x20c4b0 (P2), placing its
own reticle sprites from those words. The core's crosshair option reads the
same words through a second port on work RAM and draws at (X, 255 - Y):
measured against MAME snapshots of the name-entry reticle at five gun
positions (`scripts/gun_find.py`), the reticle's centre is at column X and
between rows 255-Y and 254-Y. This is the "pointer for zombraid crosshair
hack" MAME's work-RAM share comment refers to, revived: it ties the overlay
to one ROM revision's RAM layout (the US 9/28/95 set; the prototypes' code
is stated to be the same), and it can affect nothing the game does. The
raw-value alternative (MAME's PORT_CROSSHAIR convention) cannot match the
game's own reticle, because the calibration lives in the game.

### Screen flip is the unflipped frame rotated 180 degrees

The reference for flip screen is not MAME's render but the definition: a
flipped frame is the unflipped frame rotated 180 degrees about the visible
window. MAME is 128 px off on every flipped tile layer (64 on the 320-wide
sets) and 8 lines off on flipped foreground sprites of the 240-line sets.

How it was measured. `scripts/flip_sweep.py` captures each set with its flip
DIP off and on at the same frame. Where the tile RAM matched between the two,
the model's flipped layer, rotated, was compared with the unflipped one
(`debug/flipcheck_layers.py`, `debug/flipcheck_sprites.py`, not committed).
What the core now does:

- **Tile layers** mirror about the 512x256 bitmap, with the horizontal scroll
  inverted: screen (x, y) shows map pixel `(511 - x + sx, 255 - y + sy)`,
  `sx`/`sy` being `update_scroll`'s flipped values. Current MAME's
  `tilemap_t::draw` flips about the visible area (`x0 + x1 + 1`); `x1_012`'s
  `-512` in `update_scroll` predates that.
- **Layer `xoffs_flip`** that rotates exactly, where MAME's did not: madshark
  -3 (MAME 0), wrofaero -4 (0), magspeed -2 (0), eightfrc -4 (0). eightfrc
  writes the same flipped scroll to both layers at frame 900 where the
  unflipped values differ by 16, so no single value fits every frame; -4 is
  exact at frame 2000.
- **Foreground `fg_yoffs_flip`** -0x0a for the 240-line sets (MAME -0x12);
  the 224-line sets (madshark, eightfrc, oisipuzl) rotate with -0x12.
- **Foreground `fg_xoffs_flip`**: daioh 2 (MAME 0), drgnunit -2 (2), qzkklgy2
  2 (0), zingzip 1 (0), madshark 1 (0); madshark's `bg_xoffs_flip` 1 (0).

Layer pairs rotate with 0 mismatching pixels on every set except eightfrc
frame 900 and one daioh frame whose layer-1 RAM differed between the runs;
sprite pairs rotate with 0 on every set where the two runs' sprite state
matched. Not yet seen on hardware.

---

## Adding to this file

Cite the MAME line, the measurement, or state it is unverified. If a hack is
later replaced by general behaviour, keep the entry and say what replaced it.
