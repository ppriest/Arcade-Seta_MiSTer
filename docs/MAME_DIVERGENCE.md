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

*Transcribed per game. Analysed as signal delays in "The position offsets as
signal delays" below; not restructured.*

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

MAME draws each frame at once, at vblank, from the state then. This core
renders line by line, so it holds every input to a frame at its vblank value.
What the core does, where the timing comes from, and whether hardware
confirms it:

| input | the core | why | hardware |
|-|-|-|-|
| X1-012 scroll, bank, colour mode; mixer order | latched at vblank | Daioh and Eight Forces write scroll and their sprite list from the line-112 handler; rendered live that tore the middle of every frame | yes (release builds) |
| X1-012 tile VRAM | CPU writes queued to vblank, 128 deep, live past that (below) | scroll is latched at vblank, so a tile written mid-frame for the new scroll shows under the old one | Gundhara right with it (062), occasional wrong tiles without (064); Blandia boots with the read drain (eed6f5b) |
| X1-001 code, Y, control, unbuffered boards | snapshot 5 lines before the frame wraps, ~19 lines into vblank | the games write their lists in the first lines after vblank start (Mad Shark: over 90% in 8 lines); a snapshot at vblank drew sprites with each other's tiles | yes |
| X1-001, a hand-flipped page (26 of 31 parents) | codes copied at the flip, from the half it selects; they go live with Y and control at the board's usual point (below) | with `setac_eof` off the game owns the two halves and the flip is its "list complete"; stg flips at line 113 and writes across the whole frame, so no point near vblank is clean for both halves | Strike Gunner right, attract including the asteroid scene (9d830c7); the other 25 not yet re-checked |
| X1-001, other buffered boards | copy and snapshot at vblank, in each board's order | "`setac_eof`: the copy and the draw, in each board's order" | Quiz Kokology, Blandia, Mobile Suit Gundam right (e92059d); Strike Gunner's ship wrong on every order so far, the snapshot before vblank (0a0e86b) not yet built; Dragon Unit not yet tested |

The chip reads scroll per scanline (MAME's comment cites Caliber 50's raster
effect), so a game that changes scroll mid-frame on purpose would not show it
here. None of the sets in scope is known to.

#### Strike Gunner: the game's own page flip takes the snapshot

Its attract scene with the large grey ship shows wrong pieces of the ship on
every fixed snapshot placement tried: the release order, snapshot-then-copy at
vblank, the snapshot ending before vblank, and a snapshot at line 150. Probe G
rules out the two cheap explanations: `eof_lost` (CPU writes dropped under the
copy) sat at 14-16 and did not grow, and `lines_cut` (sprites dropped on a line
over its time budget) at 3. The renderer is not at fault either:
`x1_001_model.py` reproduces MAME's own screenshot pixel for pixel on ten
frames through that scene (320-680).

What the write log says (`debug/stg-sprlog`, frames 300-700, writes a frame
per scanline):

```
    0 |3666656555544333221110......         .....0011111111111111221232|
   64 |22100......0....  .                              ###############|
  128 |2 .. .0. ..                           13334455454554544544444344|
  192 |3333333321111232222211122211111111222233233333456666666666666666|
```

About 1000 words a frame: sprite Y from line 113 to 240, codes on nearly every
line, 3-6 a line through vblank (192-255) and on into 0-27. The two quiet spans
are mid-frame, lines 83-112 and 139-165. A snapshot takes about a line, so at
any fixed line it copies a half-written list.

The board tells the core when the list is complete. Strike Gunner sets
`spritectrl[1]` bit 5 -- `setac_eof`'s copy off, measured over 3000 frames --
and flips bit 6, the half the chip draws from, itself at line 113 on 2882 of
those frames. The two halves are the game's own double buffer, and the flip is
the game saying the half it has just written is ready.

This is not Strike Gunner's alone. `scripts/sprctrl_scan.py` (600 frames of
attract, every parent) finds 26 of 31 sets doing the same, one flip a frame:

| behaviour | sets |
|-|-|
| `setac_eof` copy on, no flips | qzkklogy, qzkklgy2, msgundam, blandia |
| copy off, no flips | eightfrc |
| flip mid-frame | stg 113, zombraid 112, extdwnhl 112/254, sokonuke 113, daioh 117/132/229, atehate 118, gundhara 118, jjsquawk 119, oisipuzl 120, drgnunit 130, pairlove 130-223, umanclub 1-176, zingzip 44/254, wits 11, magspeed 2-17, wrofaero 0-210, kamenrid 5-254, neobattl 2-255 |
| flip in vblank | madshark 246-255, downtown 254, thunderl 249, blockcar 251, arbalest 241, metafox 241, twineagl 0-1, rezon 0 |

So `x1_001.sv` follows the board's rule, not a per-game switch. Once a game
flips its own page (`page_flip`: a write to control byte 1 with bit 5 set and
bit 6 changed; `own_flip` until bit 5 is cleared):

- the codes are copied at the flip, from the half it selects, into the spare of
  two copies (`codesh_lo`/`codesh_hi`, indexed `{buf, addr}`). CPU writes to
  that half keep reaching the copy until the engine moves to it (`rbuf`).
- the Y bytes and control bytes are taken at the board's usual snapshot point,
  as before. Y is a single buffer, and Strike Gunner rewrites it from line 113
  to 240, after its flip; taking it at the flip would pair new codes with the
  previous frame's Y.
- the engine moves to the flip copy when that usual snapshot lands, so codes
  and Y change together. Moving at vblank instead (9d830c7) paired new Y with
  old codes for a frame whenever the flip fell between vblank and the usual
  snapshot: Mad Shark every frame (it writes its list and flips in the first
  lines of vblank; a mess on hardware), Gundhara in play when slowdown pushes
  its flip from line 118 towards vblank (468 of 3001 frames flip late in MAME
  with a coin in; an occasional full-screen glitch on hardware). A flip after
  the usual snapshot waits for the next one.

A game that never flips its own page is snapshotted exactly as before: codes,
Y and control together, used as they land.

Reading sprite RAM live instead -- which is what the chip does -- was tried and
does not work here, because this core renders a line at a time from RAM the
game is still writing:

- control bytes live: a line of garbage where bit 6 flipped mid-frame.
- Y live: the lower half of the screen a mess. Y is a single buffer, not two,
  rewritten from line 113 to 240.
- codes live: a corrupt quarter in some attract scenes. The game does not
  respect its own buffer everywhere -- in frames 300-700 it wrote 0 of 196854
  words to the displayed half, but across 3000 frames 322 frames wrote it,
  30-62 words at lines 47-76.

#### Tile VRAM writes are queued to vblank

MAME draws each tile layer at vblank from VRAM and scroll as they stand then.
This core latches scroll at vblank (above), so VRAM read live would pair this
frame's tiles with last frame's scroll wherever a game writes both mid-frame.
Gundhara writes its layers' scroll at lines 112-119 and tile VRAM right across
the frame (MAME, `scripts/write_timing.py gundhara`: about 73 words a frame).
With VRAM live it shows occasional wrong tiles on hardware (064); with CPU
writes queued to vblank it does not (062).

`x1_012.sv` queues up to 128 CPU writes a frame and applies them at vblank.
Past that the rest of the frame's writes go live, in order: Blandia and
Mobile Suit Gundam write thousands a frame. A CPU read of VRAM drains that
layer's queue first and is held (DTACK late) until the last queued write has
landed, so it always returns what was written. Blandia needs this: it tests
both layers' VRAM at boot (MAME: 12288 reads a layer, from PCs 0x20f2-0x217e),
and with reads returning the value as of the last vblank it stopped with a
black screen (hardware, 062 and 070). With the drain it boots and its intro
illustration is right (hardware, eed6f5b). The queue costs two RAM blocks.

The queue was first added for Strike Gunner's grey ship (ab152c6) and removed
when that turned out to be the X1-001's floating tilemap, which the queue does
not reach (289317b). Gundhara is the case that needs it.

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

### `setac_eof`: the copy and the draw, in each board's order

On the buffered boards the X1-001 draws sprite code/X from a half of its code
RAM that `setac_eof` copies at vblank, and Y live. Whether a frame shows the
half copied at that vblank or at the one before depends on whether the copy
comes before or after the draw, and the boards differ. This is not a per-game
kludge; each line below is either MAME's board definition or a measurement.

| sets | PCB (seta.cpp's list) | MAME's screen | order | core |
|-|-|-|-|-|
| drgnunit | P0-053-1 | vblank callback, draw at vblank start | draw, then copy | snapshot on the line before vblank, copy at vblank |
| stg, qzkklogy, qzkklgy2 | P0-053A | as drgnunit | draw, then copy | snapshot on the line before vblank, copy at vblank |
| msgundam | P0-081A | as drgnunit | draw, then copy | snapshot on the line before vblank, copy at vblank |
| blandia, blandiap | P0-078A, P0-072-2 | `VIDEO_UPDATE_AFTER_VBLANK`: the callback runs first | copy, then draw | copy at vblank, then snapshot |

`seta_board_cfg.sv`'s `copy_then_draw` selects the order (blandia, blandiap).
The snapshot copies the 4096 code words the engine reads and the 1024 Y bytes
(5120 cycles, under a line). On the draw-then-copy boards it starts once the
last visible line is rendered (`seta_video_timing.sv`'s `snap_pre`) and ends
before vblank, so, as in MAME, writes before vblank reach the frame and writes
from line 248 on do not; the copy (a word a clk, ~21 µs) runs at vblank. A CPU
write during the copy is lost where MAME, copying in zero time, keeps it.

**Evidence.**

- *MAME's definitions:* `seta.cpp` gives only blandia and blandiap
  `set_video_attributes(VIDEO_UPDATE_AFTER_VBLANK)`; all six connect
  `screen_vblank_seta_buffer_sprites` (`setac_eof` on the rising edge).
- *Rendering:* replaying MAME's Quiz Kokology write log over frames 2400-2800
  and rendering both pairings gives 94 differing frames; copy-then-draw
  reproduces the core's broken hardware screenshot, draw-then-copy is clean.
- *Write timing* (`scripts/write_timing.py`, `docs/write_timing_mame.txt`):
  - Quiz Kokology 1 and 2 write sprite Y, control and codes around line 112,
    nowhere near vblank, in attract and play: the order is all that matters.
  - Blandia writes Y and control in the 8 lines before vblank start and codes
    after it (intro: 16-39 lines after; play: mid-frame, about lines 48-192).
    Copying at vblank and drawing that half pairs this frame's Y with the codes
    written after the previous vblank, which is how the game lays its update
    out. Probe G on hardware agrees with MAME's lines (its counter is 2 ahead
    of the interrupts'; last write per frame 249, maximum 267).
  - Mobile Suit Gundam writes 23% of its Y in the first 2 lines after vblank
    start; Strike Gunner's codes in play straddle vblank (2.4% in the first 2
    lines, 18% in the first 24), Dragon Unit's partly (4% in the first 24).
    In the ship scene Strike Gunner writes both halves from line 248 (3942
    writes a half in the first 2 lines, frames 300-700), and on hardware
    probe G's late_frames (a sprite write during the copy or snapshot) rose
    every frame with the snapshot at vblank: pieces of the ship's floating
    tilemap drew from writes MAME's frame does not include. That is why the
    snapshot now ends before vblank.
- *Hardware* (fx68k; TG68K's 3.5x pace moved every write, see below):

| build | order | Quiz Kokology | Blandia |
|-|-|-|-|
| 1a6a0a5 | copy, then snapshot 5 lines before the wrap, all boards | glitching | attract right |
| ca940a3 | snapshot 5 lines before the wrap, then copy, all boards | right | intro and play glitchy |
| 62227db | snapshot at vblank, then copy, all boards | right | attract flickering, play glitchy |
| e92059d | per board, snapshot at vblank on draw-then-copy | right | right (intro and play) |
| 0a0e86b | per board, snapshot on the line before vblank | not yet built | not yet built |

Unverified: the physical reason. MAME models the order per board, and the
games' write timing and the hardware results agree with it, but no schematic
or PCB measurement here shows where the X1-001's buffer latches on each board.
On e92059d Mobile Suit Gundam looked right and Strike Gunner's ship glitched;
Dragon Unit is not yet tested.

The TG68K history, kept for the pace finding: TG68K ran a `nop; dbra` loop at
4 clock enables an iteration against a 68000's 14 (`sim/tg68k_pace_tb`), so the
core wrote sprite lists earlier in the frame than MAME, and every ordering
tried then (861a15a, f766e9c, 807cc87) fixed one of Quiz Kokology and Blandia
and broke the other. fx68k (`sim/fx68k_pace_tb`: 14) replaced it.

#### When the games write, in MAME

`scripts/write_timing.py` counts every write to sprite Y, sprite control,
sprite code/X and the tile layers by scanline, for the 31 parent sets, over
1800 frames of attract after 600 and 1800 frames of play (coin at 600,
counted from 1500; `docs/write_timing_mame.txt` lists the six sets whose
closing snapshot was not in play). MAME's frames are 256 lines; vblank starts
at 248 (240 on eightfrc, oisipuzl, madshark, metafox, arbalest). The sprite
list (Y, control) falls in the same place in attract and play, in three
groups:

| written | share | sets |
|-|-|-|
| in the first 24 lines after vblank start | 96-100%, 13-26% in the first 2 lines | thunderl, blockcar, umanclub, neobattl, rezon, wrofaero, msgundam, kamenrid, magspeed, zingzip, madshark, downtown, twineagl, metafox, arbalest (wits mostly) |
| around line 112, nowhere near vblank | all | atehate, pairlove, drgnunit, stg, qzkklogy, qzkklgy2, daioh, gundhara, jjsquawk, extdwnhl, sokonuke, zombraid, eightfrc, oisipuzl |
| the 8 lines before vblank start | Y and control; codes after vblank start | blandia |

The unbuffered sets (the first group but msgundam, and the second but the
drgnunit family) are snapshotted 5 lines before the core's frame wraps, about
19 lines into its vblank, after their update; the core shows each list a
frame before MAME does. Mad Shark, for one, writes over 90% of its Y in the
first 8 lines. No per-line measurement of the core yet (probe G gives only
the last write line).

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

### The position offsets as signal delays

Analysis of the X offsets in `rtl/seta_board_cfg.sv` (MAME's values plus the flip
corrections above). Nothing in the RTL has changed because of it.

**Screen space.** In MAME and in the RTL, +1 on any X offset moves that plane
one dot right on screen, flipped or not: tiles take `x += 0x10 - xoffs` before
the mirror, sprites `(sx + xoffs) & 0x1ff` after it. The flipped and unflipped
constants are therefore directly comparable. Layer 0 and layer 1 are equal in
every game.

| set | layers noflip / flip | sprites noflip / flip | sprite - tile noflip / flip |
|-|-|-|-|
| stg, rezon, extdwnhl, sokonuke, zombraid, msgundam, kamenrid, magspeed | -2 / -2 | 0 / 0 | 2 / 2 |
| qzkklogy, jjsquawk, oisipuzl | -1 / -1 | 1 / 1 | 2 / 2 |
| gundhara | 0 / 0 | 0 / 0 | 0 / 0 |
| daioh | -2 / -2 | 0 / 2 | 2 / 4 |
| blandia | -2 / 6 | 0 / 8 | 2 / 2 |
| qzkklgy2 | -3 / -1 | 0 / 2 | 3 / 3 |
| drgnunit | -2 / -2 | 2 / -2 | 4 / 0 |
| zingzip | -1 / -2 | 0 / 1 | 1 / 3 |
| madshark | 0 / -3 | 0 / 1 | 0 / 4 |
| wrofaero | 0 / -4 | 0 / 0 | 0 / 4 |
| eightfrc | 0 / -4 | 3 / 4 | 3 / 8 |

What a delay model accounts for:

- **Sprite to tile, 2 dots**, on 12 of the 19 layered boards, in both flip
  states: the X1-001's pixels reaching the X1-011 two dot-clock registers after
  the X1-012's. The two layers never differ: two identical X1-012 paths.
- **Whole picture, -2, -1 or 0** on the layers: the picture against the
  blanking window, visible only at the test grid's edge. An RGB-to-HBLANK delay,
  which could differ between PCB revisions.
- **Flipped equals unflipped** (slope 1, intercept 0) on 11 of 19 sets, which is
  what a delay requires: a propagation delay cannot depend on the flip bit.

What it does not:

- **The eight flip exceptions** differ between games on the same chipset
  (madshark -3 on the layers, blandia +8 on every plane), so they are not the
  chips and not the board. Most likely each game's own flipped scroll and
  position arithmetic; eightfrc is seen writing one flipped scroll to both
  layers. The madshark, wrofaero, eightfrc layer values and the daioh,
  drgnunit, qzkklgy2, zingzip, madshark sprite values were fitted in this core
  to make the flip a true rotation. If the board is only delays, a real PCB
  shows these games slightly misaligned when flipped and the core corrects
  them. Unverified: no PCB reference.
- **Y.** A delay in whole lines would need a line buffer. The sprite values,
  14 unflipped and -10 / -18 flipped for the 240- / 224-line sets, fit
  `flip = -2 - visible_min_y` exactly (top visible line 8 / 16): mirror
  arithmetic about the visible window, not a delay. The floating tilemap's
  -1 / +1 is symmetric the same way.

Modelling. A constant screen-space X offset is the same picture as delaying
that plane's pixel stream by N dot-clock registers against the others (a
negative one delays the others, or the blanking), at 2-4 registers the cost of
the current adders. It would reduce the eleven consistent sets to about three
parameters per board revision (sprite delay, tile delay, RGB-to-blank delay)
and leave the eight flip exceptions in an explicit per-game table, or drop
them to show what a real board presumably shows. The output is unchanged only
if the table is kept.

---

## Adding to this file

Cite the MAME line, the measurement, or state it is unverified. If a hack is
later replaced by general behaviour, keep the entry and say what replaced it.
