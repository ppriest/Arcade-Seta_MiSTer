# Seta X1-010 Hardware — MiSTer Core Roadmap

## Context

Goal: a DE10-nano MiSTer core for the Seta/Allumer 68000 arcade boards emulated by MAME's
`src/mame/seta/seta.cpp` — a Quartus 17.0.2 Verilog/SystemVerilog project producing one `.rbf` and
a `.mra` per supported set, reusing proven open MiSTer components where they exist and building
custom RTL for the four Seta ASICs that have no FPGA implementation anywhere: **X1-001A/X1-002A**
(sprites), **X1-012** (tilemaps), **X1-011** (mixing) and **X1-010** (16-voice PCM/wavetable sound).

Two web searches for prior art — one for a MiSTer core on this hardware, one for a Verilog X1-010 —
returned nothing relevant. That is a negative search result, not proof none exists, but it is the
basis for planning all four ASICs as from-scratch work. MAME's C++
(`src/devices/video/x1_001.cpp`, `src/mame/seta/x1_012.cpp`, `src/devices/sound/x1_010.cpp`) plus
the register documentation in `seta.cpp`'s own header is then the whole specification we have. No Seta PCB is available here, so **MAME's own output is the accuracy
target**, including its acknowledged uncertainties — which the driver lists explicitly in its
`TODO:` block (per-game sprite/tilemap alignment offsets, flip-screen misalignment in several
games, `MACHINE_IMPERFECT_GRAPHICS` on blandia/extdwnhl).

Scope decision (see "Game scope" below): the **X1-010 mainline** — genuine Seta boards running
68000 + X1-001 sprites + X1-010 sound with 0, 1 or 2 X1-012 tilemap layers. Bootlegs, gambling and
medal machines, and Crazy Fight are out.

Three documents come with this one and are carried over from the two completed cores in this series,
`Arcade-Psikyo_MiSTer` and `Arcade-Fuuki_MiSTer`. Each carries a provenance header saying so; they
are inherited evidence about MiSTer, Quartus, ModelSim and SDRAM transports, not claims about Seta
hardware.

- **[`docs/LESSONS_LEARNED.md`](LESSONS_LEARNED.md)** — the rules, each with the mechanism that made
  the wrong assumption plausible and the evidence that settled it. Entries are marked by origin
  (unmarked = Psikyo, `[Fuuki]`, and `[Seta]` for anything this core establishes). Read the relevant
  section **before** starting a subsystem; most entries are cheap to obey up front and expensive to
  retrofit.
- **[`docs/WORKFLOW.md`](WORKFLOW.md)** — the working practice built on top of those rules: staged
  builds out of `build/`, slack-gated deploys, OSD debug switches, the JTAG probe, the trace ring,
  memory read-back from a running core, and MAME as a reference generator. **Adopted in full from
  the start**, not incrementally. Fuuki judged `build_staged.py` optional and paid for that
  judgement with a whole session of serialised work.
- **[`docs/mister_framework_notes.md`](mister_framework_notes.md)** — CONF_STR/status-word
  mechanics, the `.CFG` format, DIP delivery via ioctl index 254, and the video output chain.

## Progress

**Phase 0 is under way.** What exists and has been exercised:

- **Workflow, ported and proven.** `scripts/` and `rtl/debug/` from Fuuki, adapted (see
  [`WORKFLOW.md`](WORKFLOW.md)). The MAME capture pipeline runs end to end against real ROM sets;
  `roms/` holds the 30 in-scope parent archives, from which all 43 in-scope sets resolve.
- **The project builds.** Revision renamed `Template` → `Seta`; `scripts/build.sh --map` completes
  with 0 errors.
- **TG68K.C vendored** (`rtl/cpu/tg68k/`, from Fuuki, unmodified) and **its smoke test passes** —
  68000 mode, 1-in-6 clock enable, reset vectors fetched in order, real instructions executed, the
  right result written, no X on the bus (`scripts/run_sim.sh tg68k_smoke_tb`).
- **`rtl/cpu/maincpu.sv` written and passing against MAME.** The kernel plus address decode for all
  thirteen memory-map families, and bus sequencing with no DTACK (the CPU is stalled purely by
  holding `clkena` low). `sim/maincpu_tb` boots a real program ROM and diffs the CPU's fetches
  against a MAME boot trace; `scripts/maincpu_sweep.py` runs that per set at several ROM latencies.
  **35/35 mapped sets pass at latencies 3, 6 and 12** — every family, every clone. The sweep found
  two decode errors the earlier reset-SP cross-check could not: `blandia_map`'s work RAM truncated
  at `0x20FFFF` when it runs to `0x21FFFF`, and `msgundam_map`'s `.mirror(0x70000)` unhandled.
- **SDRAM transport vendored and exercised end to end** (`rtl/memory/`, from Fuuki: 26-bit
  addressing, one parameterised arbiter). `sim/maincpu_sdram_tb` boots the CPU through the real
  stack — ioctl stream → `sdram_download` → `sdram_arbiter` → `sdram_phy` → `sdram.sv` → a
  command-decoding chip model, with the fetch path coming back through `sdram_narrow_bridge`. This
  is the test LESSONS_LEARNED insists on: Psikyo had a handshake bug that every module-level
  simulation passed because a short-latency behavioural model answered while the FSM was between
  states. It also proves four byte-order conventions compose (ioctl ascending → download pairs
  even-byte-low → bridge unchanged → `ROM_BYTESWAP` to big-endian), and runs the download under
  MiSTer's real discipline: **two reset domains**, with the CPU held in reset across the whole
  transfer while the memory path is not.
- **Every interleave confirmed against MAME itself.** `mame_capture.py --boot-trace` taps the
  main CPU's bus accesses from reset; `check_boot_trace.py` compares them against the image
  `build_maincpu_hex.py` assembles from `ROM_START`. **43/43 sets pass**, ~9,000 words, zero
  mismatches — including the awkward forms (`ROM_CONTINUE` on jjsquawk, `ROM_LOAD16_WORD_SWAP` on
  msgundam and qzkklgy2). Two code paths sharing nothing agree, which is a stronger statement than
  the reset-vector check alone.
- **Graphics formats settled.** The four `gfx_layout` transcriptions are verified structurally and
  against real ROM data; the 6bpp `ROM_LOAD24` grouping is confirmed.

- **`rtl/sound/x1_010.sv` written and matching MAME sample for sample.** All 16 voices, both PCM
  and wavetable modes, envelopes, one-shot key-off, the frequency divider, and MAME's own
  frequency-zero hack (carried deliberately and flagged as a hack, not hardware behaviour).
  `scripts/x1_010_model.py` is a line-by-line transcription of `sound_stream_update()`;
  `sim/x1_010_tb` loads the same register image and sample ROM into the RTL and requires identical
  stereo output. **4096/4096 samples identical**, at PCM ROM latencies from 2 to 40 cycles, with
  key-on edge semantics checked directly. This is the whole of Phase 0 spike 2.

- **96 MHz closes on the real device, measured.** `rtl/synth_check/` is a standalone Quartus
  project that fits the whole Phase 0 subsystem -- maincpu with TG68K under it, the X1-010, and
  the SDRAM transport they both fetch through -- on the real 5CSEBA6U23I7 speed grade 7, with
  inputs from a pattern register and outputs XOR-reduced onto one pin so nothing optimises away.

  | step | worst setup slack | TNS |
  |---|---|---|
  | unconstrained | −8.763 ns (Fmax 52.1 MHz) | −7517 |
  | + audited TG68K kernel multicycle 4 | −1.816 ns | −963 |
  | + multicycle 6 instead | −1.969 ns | −1444 |
  | + registered key-on path | −1.169 ns | −14.2 |
  | + registered io interface, 3-cycle access | **+0.011 ns** | **0.000** |

  All 30 worst paths were inside `TG68KdotC_Kernel` unconstrained, matching Psikyo's 48.74 MHz and
  Fuuki's 44.25 MHz for the same core. Resources: **3,219 ALMs (8%), 26 RAM blocks (5%), 10 DSPs**.

  Two caveats stated plainly. The margin is **+0.011 ns** — closure with essentially none, and the
  video engines still have to fit in the same period. And multicycle 6, which the 96/16 enable
  ratio does support, measured *worse* than 4, because by then the bottleneck had left the kernel.

**Phase 0 is complete.**

### Phase 1 so far: the sprite engine renders correctly, and does not yet fit in a scanline

- **The golden reference is closed at both ends.** `scripts/x1_001_model.py` transcribes
  `x1_001.cpp` and reproduces MAME's own render of **24 captured frames across all eight Group A
  sets, pixel for pixel** (`scripts/x1_001_sweep.py`). `rtl/video/x1_001.sv` then reproduces the
  model over the same 24 frames at ROM latencies 6/12/24 — **72 of 72 runs, 92,160 pixels each,
  zero mismatches** (`scripts/x1_001_rtl_sweep.py`). The two halves are compared separately
  because MAME renders a whole frame from end-of-frame state while the RTL renders per scanline
  from live RAM; each half compares like with like.

- **Three findings that the register map does not give you**, all now transcribed rather than
  reasoned: the bank expression `(ctrl2 ^ (~ctrl2 << 1)) & 0x40` means *bits 6 and 5 agree*, not
  *bit 6 set* (thunderl draws from `spritecode[0x1000]` and never buffers); foreground and
  background position y oppositely, one reflected through `screen.height()` and the other not; and
  **no Group A game buffers sprites at all** — `setac_eof` is wired up by four `machine_config`s in
  seta.cpp and none of them is in this phase.

- **The line budget does not close, and this is the open problem.** A line is 512 dots at the
  believed 8 MHz dot clock = **6144 clk_sys cycles**. Measured by the engine's own counters over
  all 24 captures at latency 12:

  | | worst line |
  |---|---|
  | cycles | 13,269 – 44,000 |
  | sprites on that line | 155 – 544 |

  Every capture, gameplay frames included. The cause is structural: the chip walks all 512
  foreground entries every line, and a game using 40 of them leaves the other 472 holding one
  stale y — so they all land on the same sixteen scanlines. An earlier estimate of 32–61 taken
  from the frames rather than from the iteration was wrong by an order of magnitude, in the
  direction that makes a design look finished.

  **The engine walks front to back, takes a cutoff, and fetches a sprite row in one SDRAM
  granule.** Reversing the walk and giving the line buffer a written bit -- first writer wins --
  produces the identical picture (the two orders are duals), but changes what happens when time
  runs out: the sprites dropped are the bottom-most rather than the ones on top. Then
  `rtl/memory/gfx_swizzle.sv` permutes the sprite region's word addresses at download time so a
  row is eight contiguous, 8-byte-aligned bytes -- one read instead of four.

  Measured over the same 24 captures, `line_budget` = 6144, shown as *before the swizzle* to
  *after*:

  | ROM latency | identical to the model | sprites the worst line completed | pixels changed |
  |---|---|---|---|
  | 6  | 22/24 to **22/24** | 97 to **165** | 1,200 to **720** |
  | 12 | 22/24 to **22/24** | 68 to **140** | 1,448 to **910** |
  | 24 | 6/24 to **22/24**  | 43 to **108** | 168,094 to **1,120** |

  The latency-24 row is the point: before the swizzle the picture fell apart if the SDRAM was
  slow, and now it does not. Unbudgeted it is **72 of 72 runs pixel-identical** at all three
  latencies.

  The only capture that still loses anything at any latency is thunderl/thunderla frame 300 -- a
  boot state with 536 entries stacked on one scanline -- losing 360 to 560 pixels of 92,160
  (0.4-0.6%) on six lines at the bottom of the screen. Every gameplay frame in every set is
  unchanged. **The cutoff now costs nothing visible across the whole plausible latency range.**

  512 sprites in 6144 cycles is **12 cycles each**. The real chip evidently managed it: a 32-bit
  sprite ROM bus at 16 MHz delivers 4096 bytes per 64 µs line, which is 512 rows of 8 bytes with
  nothing spare — so it has a per-line limit too, and MAME's own comment agrees ("Draw up to 512
  sprites, mjyuugi has glitches if you draw them all"). Three changes are needed and none is
  speculative:

  1. **DONE — front to back, first writer wins, with a cutoff.** A written bit per line-buffer
     pixel replaces the write order as the priority mechanism, so running out of time drops the
     bottom-most sprites instead of the ones on top.
  2. **DONE — one ROM read per sprite row, not four** (`rtl/memory/gfx_swizzle.sv`). The
     permutation is a **pure word-address bit permutation**: source word `{h, tile, yh, xh, yl}`
     becomes destination `{tile, yh, yl, h, xh}`, and the plane bit — the only thing below word
     granularity — is the low bit of both. Nothing needs shuffling inside a word, so the download
     path can do it by rearranging address bits alone, leaving `sdram_download.sv`'s byte pairing
     untouched. The engine's whole address calculation collapses to the granule `{tile, yh, yl}`.

     The `.mra` could not have expressed it: `mra-tools-c` would have to extract a 16-on/16-off
     stride, which is not one of its interleave forms. A 2-byte interleave of the two `RGN_FRAC`
     halves *is* expressible and would have given two reads per row rather than one — worth
     remembering for Phase 4, where the 6bpp layers raise the same question.

     **Still to wire up:** the swizzle is verified through `sim/x1_001_tb`, which pushes the
     natural region through the RTL module word by word and requires the engine reading the result
     to match the model reading the natural region. It is not yet in the real download path —
     that needs `rtl/memory/seta_sdram_top.sv` and its region map, which do not exist yet.
  3. **NOT NEEDED YET — more than one pixel written per cycle**, so a 16-pixel blit costs 4 cycles
     rather than 18. After (2) the blit is the largest remaining term, but with 108 sprites a line
     at the worst plausible latency and every gameplay frame already unaffected, there is nothing
     left for it to buy. An unaligned 16-pixel run spans five 4-pixel words, so it is not cheap.
     Revisit only if a real game turns out to need it.

- **The whole video path matches MAME's render, in RGB.** `rtl/video/seta_palette.sv` (X1-006,
  5:5:5 with pal5bit), `rtl/video/seta_video_timing.sv` (counters, sync, the line cadence and the
  two scanline interrupts) and `rtl/video/seta_video.sv` (the three tied together) are checked by
  `sim/seta_video_tb`, which samples the output **the way the MiSTer framework does** -- on
  `vga_ce` with `vga_de` high -- rather than reaching into the line buffer. Anything wrong about
  *when* a pixel is presented is a real failure there.

  **44 of 48 frames pixel-identical to MAME's own render**, over all eight Group A sets at three
  frames each, at ROM latencies 12 and 24, with the line budget in force and **zero line
  overruns**. The only failures are thunderl and thunderla at frame 300 -- the 536-sprite boot
  state again -- at 460 and 565 pixels of 92,160 (0.5-0.6%).

  Two things this test caught that nothing before it could:

  * **The double buffer needs the engine TWO lines ahead, not one.** The buffers swap at
    `line_start`, so the buffer written during line L is not read until L+1, which means the
    engine started at the beginning of line L must be rendering L+1 -- and `line_start` fires at
    the end of L-1, so the line it names is (L-1)+2. One short, the whole picture is displayed one
    scanline late: 3,560 of 92,160 pixels wrong, spread as ones and twos along every horizontal
    edge of 148 of 240 lines, which reads as sprite dropout rather than a timing error. Shifting
    the captured frame down one line made it match exactly, which is what named it.
  * **The line budget has to sit just below the line period, not at it.** At exactly 6144 the
    cutoff and the buffer swap race, and the overrun path restarts the engine mid-render instead
    of stopping it cleanly. 6100 gives 0 overruns and 49 clean cutoffs a frame, costing nothing
    visible on any gameplay frame.

- **Interrupts work against the real kernel.** `rtl/cpu/seta_irq.sv` holds a pending flag per
  level with both of seta.cpp's clearing rules — HOLD_LINE, cleared when the CPU acknowledges, and
  ASSERT_LINE, cleared only by the board's own ack write. `maincpu.sv` now connects the kernel's
  `FC` and exposes `iack` (FC = 111 during an access) with the level the CPU latched off A3..A1.

  `sim/irq_tb` runs a hand-assembled 68000 ISR through the real TG68K and checks four things: a
  HOLD request is taken once and the acknowledge clears it; an ASSERT request re-enters until an
  explicit write clears it (which is what blockcar relies on — it maps no ack at all); an
  acknowledge clears the level the CPU *took*, not the highest pending; and a request arriving on
  the acknowledge cycle survives. All pass, with 5 acknowledges observed at the right levels.

  Two details had to be read rather than assumed. MAME's three-argument
  `set_inputline(tag, line, value)` is `if (data) exec.set_input_line(linenum, value)` — it fires
  on the rising edge only and never clears, so an ASSERT vblank source stays asserted after vblank
  ends. And seta.cpp's ack names are by PIN, not level: `ipl0_ack_w` clears level 1, `ipl1_ack_w`
  level 2, `ipl2_ack_w` level 4. Reading those as levels puts every acknowledge one step out.

- **The memory backend composes.** `rtl/memory/seta_sdram_top.sv` puts every runtime ROM on the
  one chip, with a fixed address map that `.mra` generation will be driven from, and applies the
  sprite layout permutation on the way IN so `sdram_download.sv` itself is untouched — the
  permutation preserves bit 0, so that module's byte-pair coalescing still works.

  Port assignment is by deadline, not by convenience: sprites at port 0 (one scanline to build a
  line, dropped sprites visible), the X1-010 at port 1 (a real deadline but one byte per voice per
  sample step), and the CPU plus the download at port 2, because starving the CPU degrades
  gracefully where starving either of the others does not. **This will change in Phase 2** — a
  tilemap granule has a harder deadline than a sprite one, since the sprite engine renders a line
  ahead and the tilemap engine does not. Re-partition then, with a measurement.

  LAYOUT_A, the only map defined so far: maincpu 1 MB at 0x000000, gfx1 2 MB at 0x100000, x1snd
  1 MB at 0x300000 — 4 MB. One map per layout rather than one sized for the largest game, or
  thunderl's `.mra` would pad out to gundhara's 8 MB sprite base and ship megabytes of filler for
  a 1.5 MB game.

  `sim/sdram_top_tb` streams a real set in through the ioctl port and reads every region back
  through the port the core will use it from. **thunderl: 1,523 reads, zero mismatches. atehate
  (a 2 MB sprite region and a 1 MB program): 5,497 reads, zero mismatches.** The sprite check is
  the interesting one — 816 and 2,832 sprite rows respectively, each required to be one 64-bit
  granule in the right word order, with the expectation computed from the NATURAL region using
  x1_001.sv's own layout arithmetic so a wrong permutation cannot agree with a wrong reader.

- **The core exists, and it runs a real game.** `rtl/seta_core.sv` ties the CPU, interrupts,
  sprites, palette, video timing, sound and SDRAM together; `rtl/seta_board_cfg.sv` turns the
  `.mra` mod byte into every per-game constant, including which of maincpu.sv's memory maps to
  use; `Seta.sv` is now the real top level (hps_io, PLL, inputs, DIPs, arcade_video, rotation)
  with Template_MiSTer's demo core deleted.

  Two pieces of game-specific hardware came out of this: thunderl's protection register
  (`rtl/seta_prot_thunderl.sv` — a write anywhere in a 128 KB window latches eight bits derived
  from the *address*, and one read address returns them) and pairlove's 0x900000 block
  (`rtl/seta_prot_pairlove.sv` — a one-deep write history, where a read returns the current value
  and reverts the cell to the previous one). pairlove also got its own memory map,
  `BOARD_PAIRLOVE`; the maincpu boot sweep is **36 of 36 sets** with it.

  **The acceptance test is a bus-trace diff against MAME.** `sim/seta_core_tb +TRACE=n` dumps the
  core's own trace and `scripts/diff_core_trace.py` aligns it against MAME's for the same game.
  Unlike `sim/maincpu_tb`, which uses a behavioural ROM and reads zero from every peripheral, this
  is the real core against real peripherals and can follow a game past its own start-up:

  > **thunderl: 93,775 of 100,000 accesses aligned (93.8%), and every matched access carried the
  > same data.** The 6.2% unmatched are TG68K's prefetch and read-modify-write ordering, which
  > `sim/maincpu_tb` already established as expected.

  Zero data mismatches is the load-bearing number: it means the DIP bytes, the protection
  register, the input ports and every decoded region return exactly what MAME's do.

- **What the whole-core simulation cannot answer, and why.** The first version of that bench
  required the palette and sprite RAM to have been written and an interrupt taken within a few
  frames, and reported four failures when none had. None had happened in MAME either —
  thunderl's start-up is a RAM fill still running at MAME's own **400,000th** bus access, tens of
  frames in, and six frames of the full core takes thirteen minutes to simulate. So the bench now
  fails only on things that cannot be explained by the game still booting (the CPU not running,
  no video lines, no sprite fetches, any line overrun) and reports the rest as progress. "Does it
  reach the title screen" is a hardware question.

- **The `.mra` files exist, and each is proved byte for byte.** `scripts/build_mra.py` builds every
  region's image from the driver's ROM_START semantics, TESTS candidate interleave forms against
  that rather than deriving map digits, then re-reads the finished file with `scripts/mra.py` and
  compares the whole assembled image, padding included. **8 of 8 Group A sets verified.**

  Almost nothing is transcribed: region records from `extract_romstart`, the address map parsed out
  of `seta_sdram_top.sv` (the RTL is the authority -- a `.mra` loading to different offsets than the
  core reads from gives a black screen and no other symptom), DIP switches from the new
  `scripts/extract_dips.py`, and title/year/manufacturer/parent/rotation from the `GAME()` line.

- **The core fits, and the first full build found a missing constraint.** On the 5CSEBA6U23I7:
  **20,871 / 41,910 ALMs (50%)**, 222/553 RAM blocks, 44/112 DSPs, 3/6 PLLs.

  The first compile missed timing by **-7.954 ns** with **all thirty worst paths inside
  `TG68KdotC_Kernel`** -- the same shape as Phase 0's *unconstrained* measurement. Not the sprite
  engine, not the video path, not the SDRAM: `Seta.sdc` was still the template's two lines, and
  Phase 0's audited multicycle had only ever existed in `rtl/synth_check/`. Carrying it across:
  **-7.954 -> -3.956**. Registering the CPU interface into `x1_001`, `seta_palette` and
  `seta_prot_pairlove`: **-3.956 -> -1.751**.

  At that point the critical path left the CPU. All fifteen worst paths ran from `x1_001`'s
  `spriteylow` RAM output through three chained 8-bit adders into the foreground hit test -- and
  every term but the RAM byte is constant for the whole scan, so it is now pre-added once per line.
  Verified 72/72 against the model, and by exhaustive equivalence of the old and new expressions
  over 8,865,792 input combinations across both the flipped and unflipped branches. **The rebuild
  that measures it is still running; -1.751 ns is the last completed measurement.**

- **The flipped half of the sprite Y arithmetic is covered for six of the seven sets.** No Group A
  game sets flip screen by itself, so all 24 ordinary captures have `spritectrl[0]` bit 6 clear and
  the sweep's 72/72 never exercised it against MAME at all.

  What works is MAME's own configuration file. `cfg/<set>.cfg` is applied at POWER-ON, before any
  autoboot script runs, which is the only moment early enough for a game that reads the switches
  once during its own initialisation. `mame_capture.py --dip "Flip Screen=On"` now runs a seed pass
  (`scripts/mame/setdip.lua`) into a per-capture cfg directory, so nothing touches the user's own
  MAME configuration. Two earlier attempts did not work: setting the DIP from the capture script is
  too late for six of the seven, and `soft_reset()` from that script hangs the capture outright.

  MAME saves a DIPSWITCH entry only when the wanted value is non-zero -- `thunderl`'s "On" is 0x200
  and persisted, while `wits` and `blockcar` have "On" = 0, the same switch with the opposite sense,
  and nothing was written. So the seed pass reports the port tag, mask and defvalue it used and the
  `<input>` section is built from that, keeping the `mameconfig version` out of the file MAME itself
  wrote.

  **`wits`, `blockcar`, `umanclub`, `neobattl`, `atehate` and `pairlove` all produce genuinely
  flipped frames** -- `ctrl0 = 0x50`, 48 to 314 foreground sprites, 12 to 16 floating-tilemap
  columns -- and the model is pixel-identical to MAME on every one. The RTL sweep, now covering
  those alongside the ordinary captures, is **90 of 90 runs identical to the model** at ROM
  latencies 6, 12 and 24.

  `thunderl` is the exception and is NOT covered: the cfg is loaded and honoured, but the game does
  not set the sprite chip's flip bit at frame 300, 900 or 1800 -- at f900 `ctrl0` reads 0x00, so it
  is mid-transition with the control register not yet written. It is the one set that DID flip
  through the earlier runtime route, so its behaviour is timing-dependent in a way that is not
  pinned down. `x1_001_sweep.py --flip` fails it explicitly rather than passing it.

Not started: any hardware.
`Seta.sv` is still Template_MiSTer's demo core. The rest of this document is a plan, not a status
report.

What *has* been done is the driver analysis this document records: the hardware tables, the memory
map, the ROM inventory and the clock/bandwidth arithmetic in "Design decisions" are all derived
from the MAME source at `E:\mame\src\mame\seta\`, and each is attributed to the file and mechanism
it came from.

## Game scope

In scope — genuine Seta boards, 68000 + X1-001 + X1-010, grouped by the video work each group adds.
Parent sets named; MAME clones of each are in scope for `.mra` purposes unless noted.

**Group A — sprites only, no tilemap layer** (10 sets)

| set | title | 68000 clock | notes |
|---|---|---|---|
| `thunderl` `thunderla` | Thunder & Lightning | 16 MHz / 2 | small protection register (`thunderl_protection_r/w`) |
| `wits` | Wit's | 16 MHz / 2 | |
| `blockcar` | Block Carnival / Thunder & Lightning 2 | 16 MHz / 2 | |
| `umanclub` | Ultraman Club | 16 MHz | |
| `neobattl` | SD Gundam Neo Battling | 16 MHz | shares `umanclub` machine config |
| `atehate` | Athena no Hatena? | 16 MHz | |
| `pairlove` | Pairs Love | 16 MHz / 2 | 2048 palette entries (palette bank switch) |
| `orbs` | Orbs | 14.318181 MHz / 2 | **different XTAL** |
| `keroppi` `keroppij` | Kero Kero Keroppi | 14.318181 MHz / 2 | **different XTAL** |
| `krzybowl` | Krazy Bowl | 14.318181 MHz | **different XTAL**; uPD4701 trackball |

**Group B — one X1-012 layer, 4bpp** (4 sets): `drgnunit` (Dragon Unit / Castle of Dragon), `stg`
(Strike Gunner S.T.G), `qzkklogy` (Quiz Kokology), `qzkklgy2` (Quiz Kokology 2). All 16 MHz / 2
except qzkklgy2. Sprite buffering enabled (`screen_vblank_seta_buffer_sprites`).

**Group C — two X1-012 layers, both 4bpp** (8 sets)

| set | title | notes |
|---|---|---|
| `rezon` `rezono` | Rezon | 57.42 Hz ("approximation from PCB video") |
| `daioh` `daioha` `daiohc` `daiohp` `daiohp2` | Daioh | **57.42 Hz "verified on PCB"** |
| `msgundam` `msgundam1` | Mobile Suit Gundam | 56.66 Hz, explicitly a game-speed fudge, not measured |
| `kamenrid` | Masked Riders Club Battle Race | vregs at `0x600003`, not `0x500003` |
| `eightfrc` | Eight Forces | X1-010 sample ROM banking (`init_bankx1`) |
| `oisipuzl` | Oishii Puzzle | 320×224 visible; driver says flip screen unsupported |
| `wrofaero` | War of Aero | uPD71054 (8254) PIT drives a level-4 IRQ |
| `magspeed` | Magical Speed | registers at `0x5000xx`; lamp outputs |

**Group D — two layers with 6bpp tile data** (7 sets)

| set | title | layer depth | notes |
|---|---|---|---|
| `zingzip` | Zing Zing Zip | L1 6bpp, L2 4bpp | 57.42 Hz (inferred, not measured) |
| `extdwnhl` | Extreme Downhill | L1 6bpp, L2 4bpp | 320×240 visible |
| `sokonuke` | Sokonuke Taisen Game | L1 6bpp only | shares `extdwnhl` config, no gfx3 |
| `gundhara` `gundharac` | Gundhara | both 6bpp | PIT; largest ROM set at 15.5 MB |
| `jjsquawk` `jjsquawko` | J. J. Squawkers | both 6bpp | different palette remap to gundhara |
| `madshark` | Mad Shark | both 6bpp | |
| `blandia` `blandiap` | Blandia | both 6bpp | second palette bank + palette-offset effect; sample banking |
| `zombraid` | Zombie Raid | both 6bpp | ADC0834 light gun, battery-backed RAM |

Out of scope, and why:

- **Bootlegs** — `thunderlbl` `thunderlbl2` `blockcarb` `wiggie` `superbar` `msgundamb` `jjsquawkb`
  `jjsquawkb2` `simpsonjr` `triplfun` `triplfunk` `zingzipbl` `madsharkbl`. All replace the X1-010
  with OKI M6295 and/or YM2151, several drop the Seta customs entirely, and `zingzipbl` has
  different video registers and a bad Oki dump. Different hardware, no coverage benefit. Same call
  the Psikyo project made, for the same reasons.
- **Gambling / medal machines** — `setaroul` `setaroula` `setaroulm` `jockeyc` `inttoote`
  `inttoote2` `spkings` `gderby`. Hoppers, ticket dispensers, lamp/LED artwork layouts, RTC
  (uPD4992), 8bpp tiles for the roulette wheel, and MAME `.lay` files that carry a meaningful part
  of the presentation. A different project.
- **`crazyfgt`** (Subsino) — unemulated protection, tickets, "find correct clocks",
  `MACHINE_IMPERFECT_GRAPHICS | MACHINE_IMPERFECT_SOUND`, and no X1-010.
- **`utoukond`** — genuine Seta board and otherwise in family, but adds a Z80 sound CPU plus a
  YM3438 alongside the X1-010. Deferred rather than rejected: it is the obvious first extension
  once the mainline works (T80 and jt12 are both already proven MiSTer components), and it is the
  only in-family game that needs them.
- **`daiohp3`** — `MACHINE_NOT_WORKING`, "needs correct program ROMs".

## Hardware reality (from the driver, not assumption)

Unlike Psikyo's two-sound-system split, `seta.cpp`'s in-scope hardware is **one board family with
three video build options**. Every in-scope set is 68000 + X1-001A/X1-002A sprites + X1-006 palette
+ X1-007 blanking + X1-010 sound; the variation is how many X1-012 tile layers are fitted, how deep
the tile data is, and how the palette is indexed.

### Custom chips

| Chip | Package | Function | Our plan |
|---|---|---|---|
| X1-001A + X1-002A | SDIP64 (pair) | Sprites, and the "floating tilemap" made of sprite columns | Custom RTL |
| X1-004 | SDIP52 | Input handling (joysticks/controls) | Fold into the address decoder; no separate model |
| X1-005 / X1-009 | DIP48 | NVRAM / "simple protection" | **No protection is emulated in `seta.cpp`.** Treated as NVRAM only |
| X1-006 | SDIP64 | Palette | Palette RAM + 5:5:5 decode |
| X1-007 | SDIP42 | Video blanking, feeds the RGB DACs | Video timing generator |
| X1-010 | QFP80 | 16-voice PCM/wavetable sound | Custom RTL — the biggest single sound job |
| X1-011 | QFP80 | Graphics mixing | The compositor: a 3-bit priority/order register |
| X1-012 | QFP100 | Tilemaps | Custom RTL, instantiated 0/1/2 times |

**There is no MCU and no active protection anywhere in scope.** `thunderl` has a four-instruction
protection register and that is the whole of it. This removes an entire risk class that Psikyo had
(the PIC16C57 FSM) — worth stating plainly because it changes the shape of the project.

### Sprites (X1-001A/X1-002A, `src/devices/video/x1_001.cpp`)

Two independent things share the chip:

- **Foreground sprites** — up to 512 entries (`m_spritelimit`, default `0x1ff`), each one 16×16
  4bpp, **no zoom, no per-sprite priority**. Drawn `for (i = spritelimit; i >= 0; i--)`, so entry 0
  lands on top. Attributes come from three arrays: `spritecode[i]` (code + flipx/flipy),
  `spritecode[0x200+i]` (colour, X, sign bit) and `spriteylow[i]` (Y). Every sprite is additionally
  drawn at `x-512`, `y-256` and `x-512,y-256` for wraparound.
- **The "floating tilemap"** — 16 columns of 32 sprites each, from `spritecode[0x400..0x7ff]`, with
  per-column X and Y scroll from `spriteylow[0x200..]` and a per-column high X bit from the control
  registers. Drawn *before* the foreground sprites. This is not a tilemap in the X1-012 sense; it is
  a fixed-shape sprite arrangement, and it is what several games use as their background layer.

Four control bytes at `spritectrl[0..3]`. From the chip's own comment block: bit 6 of byte 0 is
flip screen, byte 1 bits carry the buffering control and the column count (`0x0` disabled, `0x1`
means 16, otherwise the literal count), bytes 2-3 are the per-column high X bits. Banking and
buffering both key off `(ctrl2 ^ (~ctrl2 << 1)) & 0x40` — **copy that expression across including
its operators** (LESSONS_LEARNED, "Copy a driver's register expression including its operators";
this exact class of bug cost the Psikyo project a layer-enable polarity hunt).

Buffering is a **copy**, not a bank swap: `setac_eof()` does
`std::copy_n(&m_spritecode[0x1000], 0x800, &m_spritecode[0x0000])` on the vblank rising edge, in
whichever direction bit 0x40 selects. LESSONS_LEARNED has an entry titled "A swap is not a copy"
describing exactly the ghosting this produces if implemented as a ping-pong — do not repeat it.

The sprite code goes through one game-independent bank function before addressing graphics:

```cpp
// setac_gfxbank_callback — used by every in-scope game
const int bank = (color & 0x06) >> 1;
code = (code & 0x3fff) + (bank * 0x4000);
```

No in-scope game sets a `tile_offset_callback` (that mechanism is used only by `downtown.cpp`).

### Tilemaps (X1-012, `src/mame/seta/x1_012.cpp`)

Genuinely simple, and much less work than Psikyo's engine — no zoom, no per-line row-scroll table,
no selectable geometry:

- Fixed **64×32 tiles of 16×16 pixels = 1024×512 pixels** per layer.
- **Two tilemaps per layer**, only one displayed; `vctrl[2]` bit 3 selects which (`m_rambank`).
  Games flip between them continuously.
- Tile word at `vram[i]`: bit 15 flipx, bit 14 flipy, bits 13:0 code. Attribute word at
  `vram[i + 0x800]`: bits 4:0 colour.
- `vctrl[0]` = X scroll, `vctrl[1]` = Y scroll, `vctrl[2]` = bank/colour-mode bits. Scroll is
  applied as `x += 0x10 - xoffset[flip]` and `y -= (256 - visible_height)/2`, with a separate
  flipped form (`x = -x - 512; y = y - visible_height`).
- `vctrl[2]` bit 4 selects **colour mode 0 or 1**, which is a different palette-index mapping for
  the same tile data, not a different tile format. Only `blandia` uses both; every other 6bpp game
  uses mode 1, so **mode 0 is effectively untested in MAME itself** (the driver says so).
- Transparent pen is 0.

The device carries a long comment saying the real chip reads its scroll registers **every
scanline** (proved by Caliber 50's raster effect in `downtown.cpp`) but that MAME deliberately does
not do partial updates because several games write registers at the wrong time. Zombie Raid writes
horizontal scroll mid-screen. **An FPGA core is naturally per-scanline and will therefore be
*more* accurate than MAME here** — which also means MAME's output is not a valid reference for
those specific cases. Flagged in Open items.

### Mixing (X1-011) and priority

`seta_layers_update()` in `seta.cpp` is the whole of it. One 8-bit register written to
`0x500003` (or `0x600003`, or `0x500015` — game dependent):

```
76-- ----   -
--54 3---   X1-010 sample ROM bank (blandia, eightfrc, zombraid)
---- -2--   palette-offset effect enable (with bit 1)
---- --1-   sprites above the frontmost layer
---- ---0   layer 0 above layer 1
```

That yields eight draw orders over {layer0, layer1, sprites}. No per-pixel priority masks, no
`pdrawgfx` convention, nothing like Psikyo's `primask` table. The compositor is a small
combinational priority resolver.

### Palette (X1-006)

Palette RAM is 16-bit, format `xRRRRRGGGGGBBBBB` — from
`rgb_t(pal5bit(data >> 10), pal5bit(data >> 5), pal5bit(data >> 0))`. Sizes and indexing vary:

| family | palette entries | indexing |
|---|---|---|
| Group A / B | 512 | direct |
| Group C (4bpp × 2) | 512 × 3 (sprites, layer1, layer2) | direct |
| `zingzip`/`extdwnhl` | `16*32 + 16*32 + 64*32*2`, indirect via 0x600 | 6bpp layer 1 remapped |
| `gundhara`/`zombraid` | `16*32 + 64*32*4`, indirect via 0x600 | `0x400 + (((color & ~3) << 4) + pen) & 0x1ff` |
| `jjsquawk`/`madshark` | same size | `0x400 + ((color << 4) + pen) & 0x1ff` — **no `& ~3`** |
| `blandia` | doubled, plus effect table | mode 0: `(color << 4) \| (pen & 0x0f)`; mode 1: `pen` alone |
| `pairlove` | 2048 | palette bank |

These are four small arithmetic index functions, selectable at runtime from the `.mra` mod byte.
Note that `gundhara` and `jjsquawk` differ by two characters (`color & ~3` vs `color`) and that
`gundhara` and `jjsquawk` also swap which layer sits at which palette base — the kind of detail
that reads as a typo and is not.

### Sound (X1-010, `src/devices/sound/x1_010.cpp`)

16 voices, stereo, clocked at 16 MHz, one output sample every 512 clocks = **31.25 kHz**. 8 KB of
RAM visible to the 68000 as 16-bit words (low byte is the real register, high byte is a read-back
shadow the chip ignores):

```
0x0000-0x007f   16 channels x 8 register bytes
0x0080-0x0fff   envelope data
0x1000-0x1fff   waveform data (128 bytes per waveform, 8-bit signed)
```

Per channel, register 0 bit 0 is key-on (rising edge resets the sample and envelope accumulators),
bit 1 selects PCM vs waveform, bit 2 is the one-shot flag, bit 7 a frequency divider. In **PCM
mode** the sample plays from external ROM between `start << 12` and `(0x100 - end) << 12`, stepping
a 4.4 fixed-point accumulator, with independent 4-bit left/right volumes. In **waveform mode** a
128-byte wave at `0x1000 + (volume << 7)` is stepped by a 6.10 fixed-point pitch while a 128-entry
envelope at `end << 7` is stepped by `start`, and the envelope byte supplies both channel volumes.

This is a well-bounded RTL job: 16 channels in 512 clocks is 32 clocks per channel, ample for one
ROM fetch each. It is nothing like the from-scratch YMF278B the Psikyo project took on.

Sample ROM is 1 MB for most games; `blandia`, `eightfrc` and `zombraid` bank the top quarter
(`0xc0000-0xfffff`) from a larger region, selected by the video register's bits 5:3.

### Screen timing — derived, and mostly unverified

MAME has **no raw timings for this hardware**. It uses `set_refresh_hz()` plus
`set_size(64*8, 32*8)` and a per-game `set_visarea`, which means the totals below are ours to
derive and to verify:

| game(s) | MAME refresh | provenance (quoted from the driver) |
|---|---|---|
| `daioh` | 57.42 | **"verified on PCB"** |
| `rezon` | 57.42 | "approximation from PCB video" |
| `zingzip` | 57.42 | "taken from other games but seems to better match PCB videos" |
| `msgundam` | 56.66 | "between 56 and 57 to match a real PCB's game speed" — a fudge, not a measurement |
| everything else | 60 | MAME's default; no evidence either way |

Visible areas actually used: 384×240 (most), 320×240 (`extdwnhl`, `keroppi`), 320×224 (`oisipuzl`),
384×224 (`eightfrc`, `madshark`, `utoukond`), 304×240 (`orbs`, `krzybowl`).

Working hypothesis, to be checked rather than assumed: dot clock = 16 MHz / 2 = **8 MHz**,
htotal = 512. Then vtotal 272 gives 57.446 Hz (0.05% from the verified 57.42), vtotal 260 gives
60.10 Hz, vtotal 276 gives 56.61 Hz. All three land within a rounding error of MAME's numbers on a
single consistent htotal, which is the kind of "hypothesis that predicts the number exactly" that
LESSONS_LEARNED recommends preferring. It is still a hypothesis — the 8 MHz dot clock is inferred
from the XTAL, not read anywhere.

The three 14.318181 MHz games (`orbs`, `keroppi`, `krzybowl`) presumably run a 7.159 MHz dot clock
and are a separate timing family.

### Interrupts

Two scanline-driven IRQs, from `seta_interrupt_1_and_2` / `seta_interrupt_2_and_4`:

- scanline 240 → IPL 1 (or 2) — vblank
- scanline 112 → IPL 2 (or 4) — mid-frame

`_1_and_2` uses `HOLD_LINE` (auto-clearing); `_2_and_4` uses `ASSERT_LINE` with explicit acks at
`ipl1_ack_w` / `ipl2_ack_w`. `wrofaero` and `gundhara` additionally have a uPD71054/8254 PIT whose
output 0 asserts IPL 4, clocked at 16 MHz / 2 / 8 = 1 MHz. Read LESSONS_LEARNED's "Give a held
interrupt line's acknowledge priority" and "Ask of every stimulus whether it is the shape the real
system produces" before writing either the RTL or its testbench: the Psikyo project shipped a
set-vs-clear priority bug for the whole project because its testbench pulsed vblank for one clock
where hardware holds it for the entire blanking interval.

### Memory map

Highly uniform. The Group C/D map (`rezon`/`zingzip`/`wrofaero`/`gundhara`/…):

| range | contents |
|---|---|
| `000000-1fffff` | ROM (up to 2 MB) |
| `200000-20ffff` | work RAM |
| `210000-21ffff` | work RAM (gundhara) |
| `300000-30ffff` | work RAM (blandia, wrofaero) / NVRAM (zombraid) |
| `400000-400005` | P1, P2, COINS |
| `500001` | coin counter |
| `500003` | video/mix register (`0x600003` on kamenrid/madshark, `0x500015` on magspeed) |
| `600000-600003` | DSW, split as two bytes (`seta_dsw_r`: offset 0 = high byte, 1 = low) |
| `700400-700fff` | palette RAM |
| `800000-803fff` | layer 0 VRAM (2 banks × 0x1000 words) |
| `880000-883fff` | layer 1 VRAM |
| `900000-900005` | layer 0 control (3 words) |
| `980000-980005` | layer 1 control |
| `a00000-a005ff` | sprite Y low + column scroll |
| `a00600-a00607` | sprite control (4 bytes) |
| `b00000-b03fff` | sprite code / X / attributes |
| `c00000-c03fff` | X1-010 |
| `d00000-d00007` | PIT (wrofaero, gundhara) |
| `e00000` / `f00000` | watchdog / IRQ acks |

Group A and B use the same regions at different base addresses (`atehate` in particular is
scattered). One address decoder with a per-game base table, selected by the mod byte, covers all
of it.

### ROM inventory

Total ROM per set, from the `ROM_START` blocks:

| set | maincpu | sprites | layer 1 | layer 2 | X1-010 | total |
|---|---|---|---|---|---|---|
| `gundhara` | 2 MB | 8 MB | 1.5 MB | 3 MB | 1 MB | **15.5 MB** |
| `zombraid` | 2 MB | 2 MB | 3 MB | 3 MB | 4 MB | 14.1 MB |
| `blandia` | 2 MB | 4 MB | 1.5 MB | 1.5 MB | 2 MB | 11 MB |
| `extdwnhl` | 1 MB | 2 MB | 4 MB | 2 MB | 1 MB | 10 MB |
| `jjsquawk` | 2 MB | 2 MB | 1.5 MB | 1.5 MB | 1 MB | 8 MB |
| `rezon` | 2 MB | 1 MB | 0.5 MB | 0.5 MB | 1 MB | 5 MB |
| `drgnunit` | 0.75 MB | 1 MB | 1 MB | — | 1 MB | 3.75 MB |
| `thunderl` | 64 KB | 0.5 MB | — | — | 1 MB | 1.56 MB |

The largest in-scope set is 15.5 MB, comfortably inside the DE10-nano's 32 MB SDRAM with room for a
fixed per-region address map that does not need to be re-laid-out per game.

### Graphics data formats

Decoded from the `gfx_layout` structures, and load-bearing for both the `.mra` and the fetch design.

**4bpp tiles** (`layout_tilemap`): one 16-bit word holds **4 pixels**, bit-plane interleaved — pixel
*n* of the group takes bits *n*, *n+4*, *n+8*, *n+12*. A 16×16 tile is 128 bytes. One 16-pixel row
is 8 bytes = 4 words = exactly one burst-4 SDRAM read.

**6bpp tiles** (`layout_tilemap_6bpp`): 24 bits (3 bytes) per 4 pixels, planes at bit offsets
0,4,8,12,16,20. A tile is 192 bytes; a row is 12 bytes = 6 words = two burst-4 reads.

**Sprites** (`layout_sprites`): `RGN_FRAC(1,2)` — the region splits in half, two bit-planes in each
half. Classic packed-planar: within a half, byte *n* supplies plane 0 for 8 pixels and byte *n+1*
plane 1. A 16×16 sprite is 64 bytes per half, 128 total.

**`ROM_LOAD24_BYTE` + `ROM_LOAD24_WORD_SWAP`** is how the 6bpp layers load. These are macros
seta.cpp defines itself (line ~9176) — `ROM_SKIP(2)` and
`ROM_GROUPWORD|ROM_REVERSE|ROM_SKIP(1)` — so at offsets 0 and 1 they build the region as 3-byte
groups:

```
dest[3g]   = byte_rom[g]
dest[3g+1] = word_rom[2g+1]     # the word ROM, byte-swapped
dest[3g+2] = word_rom[2g]
```

Confirmed offline against gundhara: `bpgh-009` (0x80000) + `bpgh-010` (0x100000) reproduces the
declared `ROM_REGION(0x180000)` exactly, and the tiles then decode as real artwork.
`scripts/decode_gfx.py --interleave 24` implements it, which makes it the ground truth any
candidate `.mra` gets scored against. **Whether `mra-tools-c` can express that grouping is still
open** — see Open items.

## Component reuse map

| Block | Plan | Source |
|---|---|---|
| 68000 | **TG68K.C**, kernel instantiated directly and clock-enabled — the same core both prior projects vendored, and Fuuki has already proved this exact copy in 68000 mode (`CPU = "00"`) | vendored from `Arcade-Fuuki_MiSTer`; see `rtl/cpu/tg68k/PROVENANCE.md` |
| X1-001A/X1-002A sprites | **Custom RTL.** No zoom, no per-sprite priority — substantially simpler than the Psikyo zoom engine | `src/devices/video/x1_001.cpp` |
| X1-012 tilemaps | **Custom RTL**, one module instantiated 0/1/2 times | `src/mame/seta/x1_012.cpp` |
| X1-011 mixing | **Custom RTL** — combinational, one 3-bit order register | `seta_layers_update()` |
| X1-010 sound | **Custom RTL.** No existing implementation anywhere; MAME's C++ is the spec | `src/devices/sound/x1_010.cpp` |
| uPD71054 (8254) PIT | **Custom RTL**, one channel in mode 0/2 — only `wrofaero`/`gundhara` need it | `machine/pit8253.h` usage |
| uPD4701 trackball | Small counter pair — only `krzybowl` | `machine/upd4701.h` usage |
| ADC0834 | 4-channel SAR ADC model — only `zombraid` light gun | `machine/adc083x.h` usage |
| SDRAM controller + arbiters + HPS download | **Vendor from Arcade-Psikyo_MiSTer** (`rtl/memory/sdram/sdram.sv` burst-4 + `sdram_arbiter*.sv` + `sdram_download.sv`) with its `PROVENANCE.md`. Verified against a command-decoding chip model and on hardware | `E:\Arcade-Psikyo_MiSTer\rtl\memory\` |
| Screen rotation | `screen_rotate_two.sv` (Sorgelig, GPL v2) — a DDRAM tap, not a filter | vendored via Psikyo, originally Arcade-SKNS_MiSTer |
| Video output | `sys/arcade_video.v` (scandoubler, gamma, `video_freak` aspect/crop) | already in `sys/` |
| High score save | `hiscore.v` | MiSTer-devel standard; both prior cores have a working integration to copy |
| Pause | `pause_control.sv` | `D:\Arcade-Fuuki_MiSTer\rtl\pause_control.sv` |
| **Debug instrumentation** | **Vendor `issp_probe.sv`, `debug_tracer.sv`, `debug_counter.sv` with their header comments intact** — the rationale in those headers is why they have no reset port and why the counters saturate | `D:\Arcade-Fuuki_MiSTer\rtl\debug\` |
| **Build / deploy / capture tooling** | **Vendor the Fuuki `scripts/` set** — `build_staged.py`, `deploy.py`, `run_sim.sh`, `cfg.py`, `build_mra.py`/`mra.py`, `mame_capture.py` + `mame/*.lua`, `memdump.py`, `boot_trace.py`, `read_issp.tcl`, `report_worst_paths.tcl`, `sweep.py`, `soak.py`. Full inventory and rationale in [`WORKFLOW.md`](WORKFLOW.md) | `D:\Arcade-Fuuki_MiSTer\scripts\` |
| Top-level framework | `MiSTer-devel/Template_MiSTer` (already checked out) | this repository |

## Design decisions

### Clocking

The board runs from one 16 MHz XTAL (three Group A games use 14.318181 MHz instead). CPU is 16 MHz
or 8 MHz; dot clock is believed to be 8 MHz.

**Proposal: `clk_sys` = 96 MHz.** That is 6× the 16 MHz CPU and 12× the 8 MHz dot clock, so both
clock enables are exact integer dividers with no accumulator error — LESSONS_LEARNED's "Derive the
clock-enable ratio exactly rather than rounding" is satisfied trivially for the 16 MHz family. The
14.318181 MHz family does not divide 96 MHz; those three games need either a Bresenham accumulator
(176/945-style, as Psikyo used) or a second PLL configuration selected at load time. Recommend the
Bresenham enable — a clock mux is a synthesis hazard for no benefit.

**On TG68K and Fmax.** Both prior cores measured `TG68KdotC_Kernel` as the Fmax-limiting block —
48.74 MHz on Psikyo, 44.25 MHz on Fuuki, post-fit on Cyclone V speed grade 7 — and both shipped a
design running an ~86 MHz `clk_sys` anyway. The raw figure is not the binding constraint, because
**the kernel is clock-enabled and does not step every cycle**: a 16 MHz 68000 inside 96 MHz
advances once every 6 cycles, so its paths genuinely have 6 cycles to settle and a multicycle
constraint saying so is correct rather than a fudge. Fuuki closed at +0.927 ns that way.

So the Phase 0 question is not "does the CPU reach 96 MHz" — it does not, and does not need to. It
is **"does the whole design close at 96 MHz with the kernel multicycle-constrained, and does the
video engine have margin left"**. Two conditions carry over verbatim and are not optional: scope
the constraint to the KERNEL and never `TG68K.vhd`'s wrapper (its falling-edge `waitm` and
`data_akt_e` are the DTACK sample and the DATA tri-state enable, and relaxing them corrupts bus
handshaking while the timing report stays clean), and write the audit reasoning into the `.sdc`
beside each constraint. If 96 MHz still will not close, the fallback is 64 MHz (8× dot, 4× CPU) —
workable by the bandwidth arithmetic below, but with no margin, which would put the line-based
sprite renderer back in question.

### Sprite rendering: line-based, not frame-buffered

Psikyo needed a sprite frame buffer because its engine had per-sprite zoom and a variable
sub-tile count. Seta's sprites are fixed 16×16 with no zoom, which makes the worst case
computable:

```
per scanline, worst case:
  512 foreground sprites x one 16-pixel row       = 512 x 8 bytes  = 512 burst-4 reads
  2 tilemap layers x 25 tiles x one 16-pixel row  =  50 burst-4 reads (4bpp)
                                                  = 100 burst-4 reads (6bpp)
  at ~7 clk per burst-4                           ~ 4,300 clk

available per scanline at 96 MHz, htotal 512, 8 MHz dots:
  512 dots x 12 clk/dot                           = 6,144 clk    -> ~30% margin
at 64 MHz:
  512 dots x 8 clk/dot                            = 4,096 clk    -> does not fit
```

So: **double line buffers** (384 × 9 bits × 2 ≈ 7 Kbit, negligible) rather than a frame buffer
(384 × 240 × 9 × 2 ≈ 1.7 Mbit, 30% of the device's block RAM). This is the decision that keeps the
BRAM budget open. It is contingent on `clk_sys` = 96 MHz closing timing; if it does not, revisit.

Two constraints follow from the MAME source and must be respected by any line renderer:
sprites draw high-index-first so **later writes win** and entry 0 lands on top, and the floating
tilemap columns draw **before** all foreground sprites.

### Memory partitioning

SDRAM (vendored burst-4 controller, three physical ports, **fixed priority port0 > port1 > port2** —
not round-robin; Psikyo learned this the expensive way):

- **Port 0** — tilemap layer 0 + layer 1, 2-way arbitrated. Highest priority, hard per-scanline deadline.
- **Port 1** — sprite graphics fetch. Also a per-scanline deadline.
- **Port 2** — 68000 program ROM + X1-010 sample ROM + HPS download, arbitrated. Latency-tolerant.

BRAM inventory, to be tracked from the first build (LESSONS_LEARNED: "A design can be BRAM-bound
while logic sits at 40%"):

| region | size | note |
|---|---|---|
| work RAM | up to 192 KB | the union of `200000-21ffff` and `300000-30ffff` |
| layer VRAM | 2 × 16 KB | 2 banks × 0x1000 words each |
| sprite RAM | 16 KB + 0x300 B | `spritecode` + `spriteylow`/column scroll |
| palette RAM | 3-6 KB | doubled for blandia |
| X1-010 RAM | 8 KB + 8 KB shadow | the shadow is read-back only |
| sprite line buffers | ~1 KB | double-buffered |

That is roughly 2.1 Mbit of the device's 5.66 Mbit before any margin. Work RAM is the dominant
term; if it becomes the binding constraint, size it per-game from the mod byte rather than
allocating the union, and only then consider moving a region to SDRAM.

### One `.rbf`, runtime board selection

As with Psikyo: a single bitstream, with the board variant selected at runtime from the `.mra` mod
byte. The variant word needs to carry, at minimum: layer count (0/1/2), per-layer bit depth
(4/6bpp), palette-remap family (direct / zingzip / gundhara / jjsquawk / blandia), memory-map base
set, CPU divider, screen timing family, and the presence of the PIT / trackball / ADC.

**If any of those gate download-time logic, list `<rom index="1">` before `<rom index="0">` in the
`.mra`** — the mod byte is sent in file order and powers up 0, so a download-time consumer listed
after the data sees 0 for the whole transfer and silently does nothing. That defect wasted real
effort on Psikyo and is trivially avoidable here.

### Instrumentation this core needs

Planned from the start rather than added when something breaks. Mechanics and the rules that make
each trustworthy are in [`WORKFLOW.md`](WORKFLOW.md); this is the Seta-specific list.

**OSD Debug page** (every line `H`-prefixed so it hides in release builds):

- Render disable per element: **layer 0, layer 1, foreground sprites, floating tilemap**. The
  floating tilemap gets its own switch because it lives in the sprite chip but behaves like a
  background — separating it from foreground sprites is exactly the bisection a black or garbled
  screen needs.
- Force the X1-011 order register to a fixed value, overriding the game — the eight draw orders are
  the whole priority system, and pinning one answers "is this a priority bug or a render bug".
- Trace overlay: source select, window, ring/first-N mode, re-arm, trigger, line markers.
- Sprite index limit override, since `m_spritelimit` and the sprite-0 question are genuinely
  unresolved in MAME (see Open items).

**Probe counters** (saturating, no reset, each "bad" counter paired with a "total"):

- frames, scanlines, per-layer tile fetches, sprite records examined vs. drawn, **line-buffer
  overrun** (the one number that says whether the line-based sprite architecture is holding),
  SDRAM stall cycles per client and worst single wait, CPU bus cycles, X1-010 sample fetches.
- The line-buffer overrun counter is the acceptance test for the "Sprite rendering: line-based"
  decision above. If it is ever non-zero in real gameplay, that decision is wrong and the frame
  buffer is back on the table — so it exists from the first sprite build, not later.

**Trace sources**: download address, CPU address+FC, CPU address+data, SDRAM read-back walker,
sprite record stream. Plus `memdump.py` reach into work RAM, VRAM, palette, sprite RAM and the
video register with the CPU paused.

## Phased roadmap

**Phase 0 — tooling, then spikes.** Nothing here produces a playable core.

0. **Stand up the workflow before writing RTL** — `build_staged.py` + `deploy.py` + `run_sim.sh` +
   `cfg.py`, the `rtl/debug/` trio, an OSD Debug page with the trace-overlay switches, and
   `mame_capture.py` with a working Lua capture. This is deliberately item zero: both prior cores
   established that the instruments pay for themselves inside the first bring-up, and Fuuki's
   record of deferring the staged build is the argument.
1. **TG68K**: vendored (`rtl/cpu/tg68k/`). Instantiate `TG68KdotC_Kernel` directly with
   `CPU = "00"`, own the bus interface, and boot a real program out of SDRAM through the production
   transport stack — not a behavioural ROM model. Diff the ModelSim bus trace against a MAME boot
   trace of the same ROM. Then take it through a full Quartus fit with the kernel multicycle
   constraint in place, and **read `output_files/<rev>.sta.summary` and the Fmax Summary** — the
   deliverable is whether the design closes at 96 MHz, not whether it boots.
2. **X1-010**: build the sound core against captured register traffic and wave-RAM dumps, both PCM
   and waveform modes, and confirm the 512-clock sample cadence.

Exit: a working build-and-deploy loop with instrumentation live, a closing (or honestly reported
non-closing) `clk_sys` on a real post-fit netlist, a boot trace that matches MAME's, and an X1-010
that reproduces a reference waveform.

**Phase 1 — Group A, sprites only.** `thunderl`, `wits`, `blockcar`, `umanclub`, `neobattl`,
`atehate`, `pairlove` (and the three 14.318181 MHz games once the Bresenham enable exists). This is
the smallest slice that exercises the entire vertical: 68000 + address decode + IRQs + sprite engine
+ floating tilemap + palette + X1-010 + `hps_io` + ROM download + `.mra` + DIPs + video output.
Exit: booting on real hardware with correct sprites and sound.

**Phase 2 — Group B, one 4bpp layer.** `drgnunit`, `stg`, `qzkklogy`, `qzkklgy2`. Adds the X1-012
engine, tile fetch, scroll, the two-tilemap bank select, and sprite buffering.

**Phase 3 — Group C, two 4bpp layers.** `rezon`, `daioh`, `msgundam`, `kamenrid`, `eightfrc`,
`oisipuzl`, `wrofaero`, `magspeed`. Adds the second layer, the full X1-011 order resolution, the PIT,
and X1-010 sample banking.

**Phase 4 — Group D, 6bpp. DONE except gundhara.** `zingzip`, `extdwnhl`, `sokonuke`, `gundhara`,
`jjsquawk`, `madshark`. Five run on hardware; gundhara halts in its own error trap. The
3-bytes-per-4-pixels fetch is pixel-identical to MAME, and so is the whole video path on a frame
of gundhara (masked remap) and one of jjsquawk (plain) -- which is what checks
`rtl/video/x1_011_index.sv`, the adder the per-family index remaps turn out to be. The 24-bit
`.mra` interleave was the real risk and it landed: the format needed no guessing, but each set
arranges the loads differently -- a shared byte ROM, a distant ROM_CONTINUE, a ROM_COPY out of a
24-bit block, three lanes in three chips, an erased region.

**Phase 5 — the two remaining specials.** `blandia` (second palette bank, palette-offset effect,
colour mode 0) and `zombraid` (ADC0834 light gun, battery-backed RAM).

**Phase 6 — polish.** `hiscore.v`, CRT offset, pause, savestates. CRT offset is a per-game
H/V shift exposed in the OSD and applied at the video output, not in the core's timing --
the point is to centre the picture on a real monitor without changing what the game sees. Savestates should be scoped
against `docs/savestates.md` in the Psikyo repo, which already establishes what the MiSTer API does
and does not do — short version, it reserves and persists a DDR3 slot and serializes nothing.
Note that this core is in a much better savestate position than Psikyo: no jt10 (whose FM state
circulates in unreachable shift registers), and the X1-010's entire state is an 8 KB RAM plus 16
accumulator pairs.

## Verification strategy

**Simulation first, with instruments built to answer hardware questions directly.** Every component
gets its own ModelSim testbench and each integration step gets one too. But the honest record of
both prior cores is that several real bugs were only ever visible on the machine — work RAM indexed
one bit too narrowly, an arbiter still packing 25-bit addresses after a widening, a sprite depth
order that hardware settled against a reading of the driver. So the probe, the trace ring and the
memory read-back go in **early**, not when something breaks. Mechanics are in
[`WORKFLOW.md`](WORKFLOW.md); this section is what gets verified and when.

### Golden references from MAME

Captured, not hand-made, so any claim can be re-checked the same way by anyone with MAME and the
ROM sets (`scripts/mame_capture.py`). This is a large fraction of what makes the Seta video engines
provable before hardware exists:

| Reference | Validates | Phase |
|---|---|---|
| Boot program trace (bus accesses) | The CPU spike end to end — diff the ModelSim trace against MAME's rather than eyeballing "it looks like it is running". Catches wrong interleave, wrong reset vector, wrong IRQ timing and wrong DTACK behaviour in one test. **Available now**: `mame_capture.py --boot-trace N` taps the address space directly, and `check_boot_trace.py` already validates the offline image against it | 0 |
| Program ROM disassembly at known offsets | The `.mra` interleave, offline, before any build | 0/1 |
| Sprite RAM + control-register dump at a known frame | The sprite engine and the floating tilemap: preload the dump, render one frame in sim, compare against MAME's screenshot of that frame | 1 |
| VRAM + `vctrl` dump at a known frame | The X1-012 engine, the two-tilemap bank select and scroll | 2 |
| Palette RAM dump | The 5:5:5 colour path, and each family's 6bpp index remap | 2/4 |
| X1-010 register + wave RAM dump, plus a register write log | The sound core against real register traffic rather than synthetic vectors | 0 |

Two cautions on what a comparison proves: a hardware-vs-image comparison **cannot detect a wrong
image** when both sides were built from the same byte-order assumption, and any test using uniform
or all-zero content is invariant under byte order and cannot catch endianness bugs at all. Use real
content.

### Other gates

- **Testbenches use the production transport**, not behavioural ROM models, for anything touching
  SDRAM. Psikyo had module-level sims pass while hardware failed for exactly this reason: a
  short-latency behavioural model returned data in a window the real controller never hits.
- **Stimulus must be the shape the real system produces** — hold vblank for the whole blanking
  interval, drive reset and download the way MiSTer actually does (reset asserted for the entire
  transfer), and exercise both request conventions on any port with two clients.
- Every new module gets a **smoke test** (elaborate, run N cycles, check for X propagation) before a
  functional test.
- **`.mra` correctness proved offline before building**, and each generated file re-read and
  compared byte-for-byte against an image built from the driver's `ROM_START`. Every interleave
  Psikyo *derived by reasoning* was wrong; the ones it *scored against disassembly* were right, in
  seconds, with no hardware.
- **Every deploy gated on XML well-formedness.** A single stray `<` in a comment gives a black
  screen and symptoms that all point at the RTL.
- **Every build gated on negative slack, and `<rev>.sta.summary` read.** Quartus reports "Fitter was
  successful" on a design that grossly fails timing, and nothing in the default flow warns. Read the
  Fmax Summary first.
- **Every deploy gated on the `.rbf` actually coming from that build** — not older than the log, log
  says success. A Psikyo build died mid-Fitter and the deploy after it verified the previous build's
  stale `.rbf` as green.
- **Accuracy target is MAME's output**, A/B'd frame by frame — with the explicit exception of the
  per-scanline scroll behaviour, where MAME is knowingly wrong and this core will be right, and the
  flipped-screen alignment the driver itself disclaims.

## Repository setup

This repository (`E:\Arcade-Seta_MiSTer`, branch `master`) is a `Template_MiSTer` checkout. It
adopts the Psikyo/Fuuki conventions in full — see [`WORKFLOW.md`](WORKFLOW.md) for the reasoning
behind each; this is the summary.

- Rename the revision `Template` → `Seta` (`.qpf`, `.qsf`, `.sdc`, `.srf`, `.sv`, `files.qip`).
- **Branching**: `develop` is the working branch and carries granular commits; that work is
  **squashed onto `master`** at meaningful milestones, and `master` is what gets pushed. Never
  switch branches while a Quartus process is reading the tree — it silently kills the run and
  leaves a truncated log that reads like a tool crash.
- **Builds are staged, never in-tree.** `scripts/build_staged.py` snapshots HEAD into a git worktree
  at `build/` (gitignored) and runs Quartus there, so the main tree stays editable for the whole
  compile and Quartus's scratch stays out of the repo root. A dirty tree is refused: the build is
  exactly HEAD, recorded in `build/BUILT_COMMIT`. It gates on negative slack on every clock, not on
  the Fitter's opinion. Keep `scripts/build.sh` for the exceptional in-tree case.
- **Deploys are gated**: `scripts/deploy.py` refuses a `.rbf` unless the log says success, the
  `.rbf` is not older than the log, and no clock has negative slack; it prints every clock's slack
  first. Cores land as `Arcade-Seta_NNNNNNNN.rbf` with an incrementing number read back from the
  device, so earlier builds stay on the machine as fallbacks (rename the newest to `.held` to drop
  back one).
- `releases/` holds the generated per-game `.mra` files — parents at the top level, clones under
  `releases/_alternatives/` — all produced by `scripts/build_mra.py` from the RTL's own SDRAM
  offsets, never hand-written.
- `roms/` is **gitignored**. No ROM data is ever committed.
- Quartus **17.0.2** specifically — the version the MiSTer documentation names, and the version
  whose post-fit database the STA scripts expect. Two installs on this machine; invoke
  `quartus_sta`/`quartus_map`/`quartus_sh` by full path, they are not on `PATH`, and never wrap
  Quartus in `nohup ... &`.
- The `.rbf` must land in `/media/fat/_Arcade/cores/`; `.mra` files resolve `<rbf>` by
  prefix-matching filenames there, not by a path relative to the `.mra`.

## Open items

- **DIP switches -- checked, two faults fixed, one open.** `scripts/check_dips.py` compares every
  `.mra`'s `<switches>` block against MAME's own `-listxml` (a different source from
  `extract_dips.py`'s parse of `INPUT_PORTS_START`), bit positions, setting order and defaults.
  All 19 sets are structurally clean. Two faults it found: the default byte was built with OR from
  zero, so every bit no DIP covered read as an ASSERTED switch -- `sw[2]` was 0x00 for thirteen
  sets where the pulled-up hardware reads 0xF0; and kamenrid's COINS port is at `in_base+8`, above
  its own DSW, outside the core's flat six-byte input window, which is why its Country jumper read
  0 and the game came up Japanese whatever the `.mra` said. Still open: the installed MAME (0.286)
  and the source tree the `.mra`s are generated from (0.289) disagree on some Coinage LABELS --
  0.289 renamed them -- so the checker reports those separately; decide which version this core
  tracks.
- **Inputs -- checked, three faults fixed.** `scripts/check_inputs.py` compares every `.mra`'s
  `<buttons count>` against MAME's `-listxml`; all 19 agree. The core assembled every P1/P2 word
  as `JOY_TYPE1_2BUTTONS`, so: the five three-button games (drgnunit, stg, daioh, rezon, wrofaero)
  could not press button 3, since bit 6 was tied low; atehate, qzkklogy and qzkklgy2 read their
  four answer buttons off the joystick directions, and magspeed its four card buttons; and daioh's
  EXTRA port at 0x500006, buttons 4-6 for both players, was undecoded -- it sits inside the vregs
  window, which has no read branch, so the read returned seta_core's 0x0000 default and the game
  saw all six held down. `input_layout` in seta_board_cfg.sv now picks one of six assemblies.
  Untested on hardware beyond the boot sweep: nobody has played these with a pad.
- **`hiscore.v` support** (the framework's high-score save), per set: the RAM range and the
  signature MAME's `hiscore.dat` uses.
- **Screen timing is a hypothesis.** htotal 512 with vtotal 272/260/276 reproduces MAME's 57.42 /
  60 / 56.66 to within 0.1%, on an inferred 8 MHz dot clock. Only `daioh`'s 57.42 has any stated
  provenance ("verified on PCB"); the 60 Hz figures are MAME defaults with no evidence behind them
  and `msgundam`'s 56.66 is explicitly a game-speed fudge. Needs deriving properly — PCB video
  captures or a measurement from someone with the hardware. One data point has since been added,
  from MAME rather than hardware: its emulated frame is **256 lines** for thunderl, gundhara and
  daioh alike (measured with `time_until_pos()` — see LESSONS_LEARNED). That is the height the
  games' own raster arithmetic is written against, and it is NOT the RTL's expected ~262; keep the
  two apart wherever a value is compared against a line number.
- **24-bit `.mra` interleave for the 6bpp layers — the FORMAT is now settled; only its `.mra`
  expression is open.** `ROM_LOAD24_BYTE` and `ROM_LOAD24_WORD_SWAP` are macros seta.cpp defines
  itself (line ~9176): `ROM_SKIP(2)` and `ROM_GROUPWORD|ROM_REVERSE|ROM_SKIP(1)`. Loaded at offsets
  0 and 1 they build the region as 3-byte groups — `dest[3g] = byte_rom[g]`,
  `dest[3g+1] = word_rom[2g+1]`, `dest[3g+2] = word_rom[2g]`. Verified offline against gundhara:
  `bpgh-009` + `bpgh-010` gives exactly the declared `ROM_REGION(0x180000)`, and the tiles then
  decode as real artwork rather than noise (`scripts/decode_gfx.py ... tile6 --interleave 24`).
  What remains is whether `mra-tools-c` can express that grouping — check `<interleave output="24">`
  against the tool's source before Phase 4. Because the ground truth now exists in `decode_gfx.py`,
  any candidate `.mra` can be scored against it byte-for-byte instead of tested on hardware.
  Fallback if the tool cannot: load the two ROMs as separate regions and interleave in the download
  path, gated by a mod byte — the same shape as Psikyo's ADPCM-A byte swap, which is known to work.
- **Does 96 MHz close on a speed-grade-7 Cyclone V?** The whole line-buffer sprite architecture
  rests on it. Answered by Phase 0, before any video RTL is written.
- **Work RAM at 192 KB may be the binding BRAM constraint.** Mitigation is per-game sizing from the
  mod byte before considering SDRAM.
- **Per-scanline register reads make this core more accurate than MAME**, and therefore make MAME
  an invalid reference for Zombie Raid's mid-screen scroll writes, Blandia's Athena stage and
  Strike Gunner. The x1_012 device documents this at length. Decide per game whether to match the
  chip or match MAME; matching the chip is the right answer and will look like a bug in A/B tests.
- **Per-game alignment offsets.** `set_fg_xoffsets`/`set_fg_yoffsets`/`set_bg_yoffsets`/
  `set_xoffsets` are per-game kludges in MAME, and the driver's own TODO says the right fix is a
  proper table covering flipped and non-flipped cases. Several games are known misaligned when
  flipped (`krzybowl`, `zombraid`, `eightfrc`, `oisipuzl`). Carry MAME's values, do not try to
  derive them. Every value, and MAME's own comment on it -- nine are "unknown" or "correct?" --
  is tabulated in docs/MAME_DIVERGENCE.md along with why they exist at all. Phase 4 lost time to
  two of them: a wrong offset is not a broken picture but the right picture a pixel across, which
  reads as an engine bug until a whole frame is diffed against MAME.
- **Sprite limits are not understood.** `m_spritelimit` is 0x1ff by default, the chip comment says
  "understand sprite limits / how sprite 0 sometimes must be skipped", and `jjsquawk` renders a
  garbage tile from never-initialised sprite entry 0. Whatever we do here should be recorded as a
  deliberate choice, not left implicit.
- **Colour mode 0 is untested in MAME** for every 6bpp game except `blandia`. If a game selects it,
  MAME `popmessage`s and falls back. Treat any mode-0 rendering as unverified on both sides.
  Confirmed by capture: gundhara runs **both** layers with `vctrl[2] = 0x0010`, i.e. bit 4 set —
  colour mode 1 — throughout attract.
- **Some games write sample-bank bits that do nothing, and honouring them would break the sound.**
  `seta_vregs_w` decodes bits 5:3 as the X1-010 sample bank but only applies them
  `if (m_x1_bank != nullptr)` — which is true only for the games given `init_bankx1`
  (`blandia`, `eightfrc`) and `zombraid`. Captured from gundhara: its video register alternates
  between `0x0000` and `0x0020`, i.e. it asks for bank 4, and MAME discards that. A core that
  banks unconditionally would point gundhara's sample reads at a region that does not exist.
  The bank must be gated per game, from the `.mra` mod byte.
- **`utoukond`** — deferred, needs T80 + a YM3438. The cheapest expansion of scope once the
  mainline works.
- **Savestates** — not scoped. See the note in Phase 6.

## Next steps

1. Rename the project revision `Template` → `Seta` and get an unmodified template building under
   Quartus 17.0.2, so the toolchain is known good before any RTL exists.
2. **Port the workflow** — `scripts/` from Fuuki and `rtl/debug/` with their header comments intact,
   plus the `.gitignore` entries for `build/`, `roms/` and Quartus scratch. Prove `build_staged.py`
   and `deploy.py` end to end on the unmodified template: a `.rbf` that does nothing, built out of
   a worktree, slack-checked, numbered and landed on the device. See [`WORKFLOW.md`](WORKFLOW.md).
3. Vendor the SDRAM stack (Psikyo's, via Fuuki's 26-bit widening) with its `PROVENANCE.md` intact.
4. Get `mame_capture.py` producing a boot trace and a video-region dump for one set, so Phase 0's
   CPU spike has something to diff against.
5. **Phase 0 spike 1**: TG68K booting real code through the real SDRAM transport, diffed against
   that MAME trace, and the Fmax number from a full fit. This gates the clocking and
   sprite-architecture decisions above.
6. **Phase 0 spike 2**: X1-010 against captured register traffic.
7. Settle the 24-bit interleave question against `mra-tools-c` — it is cheap now and expensive in
   Phase 4.
8. Build one `.mra` (`thunderl`, the smallest set at 1.56 MB) with `build_mra.py` and prove its
   interleave offline against MAME's disassembly before any hardware is involved.
