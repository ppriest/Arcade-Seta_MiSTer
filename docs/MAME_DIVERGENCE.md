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

`drgnunit` is a Phase 2 set, so the reference for screen flip is one MAME says
is wrong. A flipped `drgnunit` capture differs by 29.6%, all in the tilemap;
eight candidate mappings top out at 70.37% with three tied.

*Unresolved and parked. `sim/x1_012_tb` refuses a flipped fixture. A PCB video
may be the only usable reference.*

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

The X1-001 renders from a snapshot of its code, Y and control RAM taken at
vblank; the X1-012 latches its scroll registers and bank bit there, and the
mixer its order register. MAME draws the whole frame at vblank from the
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

*Deliberate; matches MAME's picture. Caliber 50 would need per-line scroll.*

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

---

## Adding to this file

Cite the MAME line, the measurement, or state it is unverified. If a hack is
later replaced by general behaviour, keep the entry and say what replaced it.
