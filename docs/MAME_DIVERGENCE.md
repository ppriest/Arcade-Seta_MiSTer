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
