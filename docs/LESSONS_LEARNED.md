# Lessons Learned

**Provenance: carried over from `Arcade-Psikyo_MiSTer` and then `Arcade-Fuuki_MiSTer`** — two
completed MiSTer arcade cores built by the same author against the same toolchain, hardware and
framework. Nothing in it describes Seta hardware. It is the accumulated cost of finding each of
these the hard way, and the entire reason it is here is so that this core does not pay for them a
third time.

Entries are marked by where they were established:

- unmarked — Psikyo
- `[Fuuki]` — Fuuki
- `[Seta]` — **this core.** Append new findings with that mark, in the same shape the existing
  entries use: **the rule, the mechanism that made the wrong assumption plausible, and the evidence
  that settled it.** Never edit a Psikyo or Fuuki entry to say something this core found.

How to use it:

- **Read the section headings before starting a new subsystem**, not after it misbehaves. Most
  entries are cheap to obey up front and expensive to retrofit.
- Entries referencing another project's module names (`tilemap_line_engine`, `psikyo_top`,
  `fuuki_sdram_top`, `spriteram_dbuf`, ...) still state a *general* rule; the module name is
  evidence, not scope. The file it names does not exist in this repository.
- Cross-project rules that already bind decisions here are cited from `docs/ROADMAP.md` by section
  name.

The highest-value entries for the work this core is about to start, in rough order:

| If you are about to... | Read |
| --- | --- |
| Wire anything to the SDRAM controller | "Memory transport: req/valid contracts, latency, byte order" — all of it |
| Write a `.mra` | "ROM loading: .mra, byte order, deployment" |
| Instantiate the 68k core | "CPU cores (TG68K.C, T80)" — this core vendors TG68K.C, so that section applies directly, not by analogy |
| Build the first `.rbf` | "Timing closure" — especially the first entry |
| Believe a hardware-vs-simulation divergence | "When simulation passes and hardware fails" |
| Add a debug probe or a debug switch | "Debug instrumentation: how not to fool yourself" |
| Generate a reference from MAME | "Driving MAME as a reference generator (Lua)" |
| Run Quartus or ModelSim at all | "Tooling and workflow" |

Working practice built on top of these rules — staged builds, the probe, the debug switches, the
MAME capture pipeline — is in **[`docs/WORKFLOW.md`](WORKFLOW.md)**.

---

## Diagnosis discipline

### Suspect your own integration before any vendored module

TG68K.C, T80, Sorgelig's `sdram.sv`, MRA/ROM loading, `hps_io` and `sys_top` ship in many working
cores. One investigation suspected, in order: SDRAM pin assignments (38/38 correct), SDRAM_CLK phase
(byte-identical output a quarter period apart), the burst-4 controller, the `.mra` interleave
(correct; "fixed" wrongly, then reverted) and TG68K's exception microcode (a testbench bug). The
cause was integration glue this project wrote. Rank hypotheses by how many shipping cores would have
to be broken for them to be true.

### Treat a conspicuous omission in a vendored module as deliberate

Upstream `sdram.v` has no reset port at all -- it is driven purely by `init` -- precisely so a core
reset cannot disturb memory. This project's wrapper added one, which created the ROM-download
hazard below. Read the upstream intent before overriding it.

### Read both halves of a mechanism before changing it

Sprite depth ordering was inverted on the strength of MAME's draw loop alone
(`while (sprite_ptr != m_spritelist.get()) { sprite_ptr--; ... }` reads as "draws backward, so entry
0 lands on top"). Never checked: `sprite_frame_buffer`'s `write_en` is unconditional so later writes
win, and the *append* side of `get_sprites()`, which decides the net order. Hardware inverted; the
change was reverted. Half a mechanism is enough to build a confident wrong change.

### Read the framework's source instead of inferring its behaviour

DIP switches were assumed to arrive through the status word, and two fixes were built on that
assumption -- a `.CFG` generator and a `base="16"` attribute on `<switches>` -- both invented. One
read of `Main_MiSTer`'s `mra_loader.cpp` showed DIPs arrive as an ioctl download with index 254,
saved to `config/dips/<mra name>`, and that `<switches>` has no `base` attribute because
`hexstr_to_char()` is always hex.

### Copy a driver's register expression including its operators

`psikyo_v.cpp` enables a layer with `m_tilemap[layer]->enable(~layer_ctrl[layer] & 1);`.
`vreg_decode.sv` had `assign layer0_enable = l0_ctrl[0]` -- right bit, wrong sense -- so both layers
were off for every value the game writes, the compositor fell through to backdrop, only sprites
appeared, and the search went into fetch paths and VRAM contents. Where MAME writes `~x & 1`,
`!(x & 1)` or `x & 8 ? 0 : 15`, carry the sense across and comment it: a polarity error passes review
because the bit index looks correct.

### Make the hardware report its own state rather than re-reading the RTL

That polarity bug was found by extending the debug overlay to dump the video-register RAM. One
screenshot showed the control word the CPU had written (`0x00D0`, bit 0 clear) beside the core's
decoded `layer_enable` of 0. Dump the register, not the intent.

### Prefer a hypothesis that predicts the number exactly

Tilemaps rendered correct content across exactly 28 columns of every scanline, backdrop for the
other 292, with `fetch_overrun` set. Chased as memory bandwidth (contention, arbiter priority,
prefetch depth). Cause: `tilemap_line_engine` had no `ce_pix` port, so its display side advanced one
pixel per `clk` (85.909 MHz) instead of per pixel clock (85.909/12 = 7.159 MHz).

```
21 tiles x 16 px = 336 pixels, one per clk = 336 clk cycles
336 / 12 clk-per-pixel                     = 28 displayed pixels
```

28 of 320 is not "about an eighth", it is 336/12, and that division identifies the cause. Contention
would give a ragged, load-dependent boundary, not the same column every line. Corollary: any module
feeding the compositor directly must consume at `ce_pix`; only a module rendering a frame ahead into
a buffer (the sprite path) may run at full clock.

> **[Fuuki] Partially superseded by Psikyo's own later work.** The `ce_pix` rule stands. The
> parenthetical does not: Psikyo **retired** its whole-frame sprite buffer on 2026-08-30 for a
> per-scanline path (`sprite_line_list` + `sprite_line_engine` + `sprite_line_buffer`), because the
> frame buffer tore mid-scanout and its 71,680-cycle clear overlapped the next render pass. Read the
> rule as "only a module rendering *ahead* into a buffer -- line or frame -- may run at full clock".
> This core uses the line-buffer form; see `docs/ROADMAP.md`, "Sprite rendering architecture".

### Do not re-guess a sign from the reasoning that produced the wrong one

A one-tile X offset on both layers was patched with -16 on `base_x_scroll`, derived from
`tilemap_x(screen_col) = base_x_scroll + screen_col*16`. Hardware moved the wrong way. The patch was
removed rather than flipped: the derivation was internally consistent and still wrong, so +16 would
be a second guess wearing the first guess's confidence. The real cause was a `gfxrom_req`/
`gfxrom_valid` handshake bug -- not a scroll constant, not addressing math.

### Add runtime A/B switches when the alternative is a rebuild per bisection step

Following `sprite_frame_buffer`'s documented contract (pulse `frame_swap` at vblank, wait for
`swap_done`) stopped the core booting: holding render start across frames left the engine rendering
back-to-back, and it shares the SDRAM arbiter with CPU program fetches. A locally correct fix can
starve a shared resource. It was isolated without rebuilding, using OSD render-disable switches:
forcing both tilemap layers off in the same bitstream still hung, excluding the tilemap change and
the instrumentation and leaving only the sequencing change.

### A swap is not a copy

`spriteram_dbuf` ping-ponged two banks, arguing this was equivalent to MAME's copy as long as the
CPU never touches the render-role bank. That condition held and the claim was still wrong: under
ping-pong the CPU's view alternates between two memories, so any entry it does not rewrite every
frame reads back what was written two frames ago -- including the display list's end-of-list marker.
A long frame that missed the marker inherited a stale one further down and rendered far more
sprites, compounding under load. A real copy removed the ghosting and the per-scene sprite freeze.

## ROM loading: .mra, byte order, deployment

### Prove the interleave against MAME's disassembly offline, before building

"It boots" is weak evidence -- a wrong map can boot far enough to look plausible. Every interleave
here that was *derived* by reasoning about byte order was wrong; the working maincpu map came from
copying a shipped core's idiom (`Bucky O'Hare.mra`). Reconstruct known words from the ROM files and
score them against MAME's disassembly:

```
000404: lea $ffff7000.l,A0   -> 41F9 FFFF 7000
00040A: move A0,USP          -> 4E60
00040C: move.w #$1,D0        -> 303C 0001
000410: movec D0,CACR        -> 4E7B 0002
```

18/18 for one interleave model, 5/18 for the other -- offline, in seconds, no hardware.

### Treat the map-digit rule as mechanical and check it, do not reason about it

mra-tools-c decrements each map digit and emits bytes in that order, so `map="12"` is a pairwise
SWAP and `map="21"` is verbatim.

| MAME region macro | `.mra` form |
| --- | --- |
| `ROM_LOAD16_WORD_SWAP` | `<interleave output="16">` with `map="12"` |
| plain `ROM_LOAD` | bare `<part>`, no interleave |

Getting this backwards un-swaps tile ROMs silently: six `_alternatives` MRAs emitted tiles as a bare
`<part>` while their sprites were correctly swapped, rendering tile layers as garbage while sprites
looked fine. The inverse trap is real too -- tengai's gfx genuinely is plain `ROM_LOAD`, so its bare
parts are correct and must not be "fixed".

### Do not "fix" a loader or file format without hardware evidence of wrong bytes

The maincpu interleave was rewritten on a mental model predicting a corrupt stack pointer. Every
test that seemed to indict it had run against an SDRAM that was never written -- garbage compared
against garbage. The rewrite was also inert: swapping the four-digit maps produced byte-identical
hardware output, i.e. the loader ignored them.

### Verify content against a hardware trace, and know what that does not prove

`scripts/verify_rom_trace.py` takes a decoded on-hardware trace of ROM reads plus the ROM zip,
brute-forces the plausible interleaves, and reports which reproduces the observed data exactly. It
returned 128/128 for the shipped maincpu map, simultaneously proving the SDRAM read path returns
byte-perfect data at those addresses. It verifies *content*, not *address reach*: the trace address
is truncated, so a path aliasing high address bits still scores 100%.

### A hardware-vs-image comparison cannot detect a wrong image

An earlier 128/128 match of a hardware trace against the image assembled from the `.mra` was also
taken as evidence the `.mra` was right. It cannot be -- both sides were built from the same
byte-order assumption. The tell was dismissed: the reset vector had to be byte-swapped in the
analysis script to match MAME's `SP=FFFF8000 PC=00000400`, written off as a capture artifact. It was
real. The CPU received `PC=0x00000004`, executed the vector table as code, hit an illegal
instruction and looped; the "sequential sweep from address 0" that looked like a boot checksum was
the CPU running off the end of the vector table.

### List `<rom index="1">` before `<rom index="0">` when a mod byte gates download-time logic

The mod byte is sent in file order and `mod_board` powers up 0 on every FPGA reprogram. Listed after
`<rom index="0">`, any download-time consumer of it (here `needs_adpcma_swap`) sees 0 for the whole
download and silently does nothing; a runtime-only consumer never exposes this. The swap logic,
transform and address window were all verified correct while the feature did nothing at all -- the
gate opened after the data had passed. Confirmed by ear on hardware, same bitstream, byte last vs
first.

### Gate every deploy on an XML well-formedness check

An edited comment block left a `-->` that had already closed the comment, so new prose landed as
character data -- containing `<- u127`. A bare `<` is illegal XML, MiSTer rejected the file, and the
result was: DIPs gone from the OSD, ROM never loaded, core up on an all-zero image, black screen.
Every symptom pointed at the RTL; the only clue was an on-screen "XML parse" message.

```bash
python scripts/validate_mra.py "releases/*.mra" && <copy to device>
```

That script also flags stray element text, which is how a prematurely-closed comment shows up.
MiSTer's parser is *more lenient* than a strict one (this file carried `--` inside comments and two
leaking comment blocks for a long time), so "it loaded before" is not evidence of well-formedness.

### Force a genuine reload when testing an `.mra` change

Re-launching an already-loaded game reuses the cached ROM, so an `.mra` edit alone produces a
byte-identical trace -- which nearly caused a correct fix to be discarded. Bounce through the menu:

```
POST /api/launch {"path":"/media/fat/menu.rbf"}   # then wait
POST /api/launch {"path":"/media/fat/_Arcade/.../Game.mra"}
```

### Put the `.rbf` in the top-level cores directory

`.mra` files reference it via a bare `<rbf>Arcade-Psikyo</rbf>` tag and MiSTer resolves it by
prefix-matching filenames in `/media/fat/_Arcade/cores/` only, not a path relative to the `.mra`. A
misplaced `.rbf` gives a silent flash-and-return-to-menu, before ROM loading begins.

### Do not hand-write a `.CFG`

`/media/fat/config/<setname>.CFG` is the whole 128-bit status word, little-endian (byte N holds
`status[8N+7:8N]`), and the `.mra`'s `<switches>` bytes live in that same word (byte0 ->
`status[23:16]`, and so on upward). Writing 16 bytes with only a debug bit set zeroes every DIP,
which here silently enabled Service Mode. Use a read-modify-write script; the hand-written mistake
was made twice. Per-game defaults come from each `.mra`'s own `<switches default="...">` -- that
attribute is the authority, not prose in a doc. A DIP value that looks harmless can hang a game:
gunbird's boot polls `$C00004` bit 7 and spins until it clears, so a `0xFF` region byte never boots.

### Make the all-zero configuration the correct one

A fresh or missing `.CFG` is all zeroes, so any OSD option whose enabled state is required for
correct behaviour must be bit-inverted with its OSD order written to match (here `status[51]`,
"Sound IRQ", listed `On,Off`). Otherwise every first-run user gets the degraded path.

## MiSTer integration: reset and ioctl download

### Never hold the memory path in the core reset

MiSTer holds core `RESET` asserted for the ENTIRE ROM download, so anything in the memory path that
resets on `RESET` is dead for the whole transfer. Passing the core's composite reset into the SDRAM
backend pinned `sdram_download`'s FSM in `D_IDLE`: `dl_req` never asserted, the arbiter never
selected the download path, and not one `CMD_WRITE` reached the chip -- while the HPS delivered all
`0xE00000` bytes and the FSM's accept condition looked perfect. SDRAM was never written; every read
returned power-up contents.

Keep two reset domains: `core_reset = reset | ioctl_download` gates CPU and video only; the memory
backend keeps the plain `reset`. Signature: a downstream FSM stuck in idle while its trigger input
is visibly pulsing correctly.

### Measure at the pins, not at the intent

The decisive measurement for the reset bug was counting real commands on
`{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE}` (`CMD_WRITE = 3'b100`) -- top-level signals. Delivery counters
and FSM accept-condition counters both looked perfect; only the pin count revealed zero writes.
Measure the last observable stage, never an internal signal that merely implies it.

## Memory transport: req/valid contracts, latency, byte order

### Give a registered RAM its full read latency before consuming the data

An FSM that registers a RAM address in one state and reads the data in the next state gets the
PREVIOUS address's data: the RAM only samples the address at the end of the state that set it, so
the result is not valid until one state later. This is the same stale-read class as the duplicate
transaction below, and it is easy to write because the code reads as if the address were applied
combinationally.

The row-scroll table showed it: every scanline was scrolled by its PREDECESSOR's table entry,
because `S_ROWSCROLL_WAIT` consumed `rowscroll_data` the cycle after latching `rowscroll_addr`. A
smoothly varying table hides this completely -- it only becomes visible where consecutive entries
differ sharply, so it can sit unnoticed in games whose scroll changes gradually. The port's own
comment already documented "1-cycle synchronous read latency"; the FSM simply did not honour it.

Two habits that catch it: state the latency in the port comment AND spend the wait state, and
write the testbench RAM model as a registered read (`always_ff ... rdata <= mem[addr]`) so a
behavioural model cannot mask it. A testbench that never exercises the feature is the other half
of the problem -- the existing line-engine bench ran with row-scroll disabled throughout, so this
path had no coverage at all.

### Deassert a request combinationally on `valid`

`tilemap_line_engine` cleared `gfxrom_req` one clock AFTER `gfxrom_valid` (registered clear in
`S_GFXROM_WAIT`), while `sdram_phy.sv` returns to `S_IDLE` on the valid cycle itself and samples the
still-high stale request -- launching a duplicate transaction for the address it just served. Every
later response the engine consumed belonged to the previous request: position N rendered cell N-1's
tile shape with N's own correctly latched colour, appearing as a one-cell offset plus a
wrong-palette bug. Deterministic protocol bug, not a timing violation.

```systemverilog
assign gfxrom_req = gfxrom_req_r & ~gfxrom_valid;
```

Proved by `tb_tilemap_screen_sdram.sv`, which reproduced the hardware screen pixel-for-pixel and
whose transaction trace showed the phy serving the previous request's address from the second fetch
of every line. Live JTAG ISSP pokes into VRAM with the CPU paused had already established the
chained N/N+1 dependency in two games.

### Hold every request until acknowledged

A request/ack round-robin arbiter needs every port on a hold-until-acknowledged contract, not a
one-shot pulse: a pulse arriving while the arbiter services another client is silently lost. Applies
uniformly across `ddram_arbiter`, `sdram_arbiter5` and the HPS download path -- `ioctl_wr` from
`hps_io` is a genuine one-shot and needs a wrapper (`sdram_download.sv`) converting it with
`ioctl_wait` backpressure.

### Treat any direct, non-arbitrated connection to a req/valid transport as suspect

`sdram_phy.sv` asserts `valid` and returns to `S_IDLE` on the same cycle. Arbitrated consumers get a
cycle of margin because `c_valid` asserts one cycle before the arbiter's own state returns to idle;
a single-client port wired straight to the phy ("no arbiter needed for one client") skips it. Sprite
gfxrom's dedicated Port 1 did exactly that and silently returned the previous transaction's stale
data under contention -- not a hang, just wrong data, read on hardware as sprite corruption. Fixed
with a single-client pulse shim (`SP_IDLE`/`SP_ISSUE`/`SP_WAIT`) reproducing the arbiter's margin.
Third occurrence of this defect class in one project.

### Clear a request-tracking flag on the bus cycle ending, not on the data-valid pulse

A `rom_pending`-style flag must clear when the CPU's bus cycle actually ends, if the CPU can hold it
open longer than the fetch (real 68k cycles hold `as_n` low for several cycles after DTACK
releases). Clearing early fires a spurious second request for data already latched; under
multi-client contention another client can win that slot and overwrite a shared read-data register
before the original cycle finishes. Symptom looked like SDRAM corruption; cause was the CPU
wrapper's own request lifecycle. Check every request-tracking flag against the bus protocol's cycle
length, not its own "data arrived" signal.

### Capture read data on the valid pulse -- nothing in the path latches it

The whole path from `sdram.sv`'s `dout` to the CPU data bus is combinational and valid is a
one-cycle pulse: `dout0`/`dout1`/`dout2` come from one shared register (upstream does this too),
`sdram_arbiter5` assigns `c*_data`/`c*_valid` combinationally, and `sdram_narrow_bridge` selects its
word with no register anywhere. `maincpu.sv` got away with reading combinationally only because
TG68K.C re-captures `DATA` on every clock edge while parked in a wait state, so the one-cycle window
always landed -- an alignment that holds by exactly one cycle. **Any change to how often a consumer
samples (a clock enable, another clock domain, an extra pipeline stage) requires latching both the
data and the ready/DTACK level first.** Fixed with `rom_data_l`/`rom_ready` held until the CPU drops
`as_n`; once captured, the word cannot be clobbered by another port.

`dout0`/`dout1`/`dout2` being literally the same register makes this a correctness requirement, not
a style point: sampling later than your own valid/ack cycle reads another port's in-flight data.
Testbenches must obey the same discipline -- one that samples outside each port's ack-triggered
branch shows 100% failures that look like an RTL bug.

### DTACK/ready must be a held level, never a pulse, for any clock-enabled CPU

A core stepping at 16 MHz inside an 85.909091 MHz fabric looks at DTACK about once every 5.4 cycles;
a one-cycle assertion is missed on nearly every access and the bus cycle hangs forever. Check every
ready/ack feeding a gated core before enabling the gate.

### Fix byte order at the seam, with a dedicated adapter

Endianness bugs live at the seam between two independently correct modules. `sdram.sv`'s burst
capture packs bytes in ascending-address order; gfx-ROM consumers assumed MAME's MSB-first format;
the maincpu program ROM needs big-endian while `sdram_narrow_bridge.sv`'s generic word path is
little-endian (correct for genuinely little-endian regions like spritelut). Add a small adapter at
each seam rather than changing a shared module's convention out from under its other, correct
consumers. Any test using uniform or all-zero content is invariant under byte order and cannot catch
this: use synthetic data for a cheap wiring smoke test, but budget a real-content integration test
before trusting the result.

### Choose SDRAM over DDRAM for hard real-time fetch budgets

MiSTer's docs describe `DDRAM_*` as for "non-critical time purposes", with latency that can far
exceed the typical ~20 cycles and an unbounded worst case. `tb_video_pipeline_ddram.sv` measured ~26
combined cycles against a 16-cycle-per-tile budget under two-consumer contention. `SDRAM_*` gives
three independent ports at bounded ~6-7 cycles. If a design starts on DDRAM for convenience, budget
time to pivot rather than patching throughput afterwards.

### Verify a burst extension against a command-decoding chip model, not a latency stub

Adding burst-4 to a controller with no burst support needs a model that decodes
`nRAS`/`nCAS`/`nWE`/`SDRAM_A`. That caught three bugs: the row/column address split needed swapping
(a hardware burst auto-increments the *column*, so four consecutive word addresses must land in four
consecutive columns of the same row -- the non-bursting upstream had it the other way, which only
matters once bursting exists); the chip model silently ignoring the `DQML`/`DQMH` write mask; and an
off-by-one in burst-read CAS timing (a dropped `+1` registration-delay margin).

### Size a prefetch buffer for correlated consumers, not average bandwidth

Two tilemap layers with identical scanline timing request in near-lockstep, so a 2-entry ping-pong
buffer absorbs only one simultaneous loss and roughly one tile in five stalled. A parameterized
N-entry ring buffer (interface unchanged) absorbed them. That is a fix for the tested contention
pattern, not a guarantee; an independent fetch-ahead domain or pipelined controller remains the
complete answer.

## When simulation passes and hardware fails

### Re-run the failing case with the production transport in place of behavioural models

The `gfxrom_req` duplicate transaction fired in module-level simulation too, but the short-latency
behavioural ROM model returned its response while the FSM was between states, so it was silently
dropped. The real controller's ~12-cycle latency lands the duplicate in the next wait state, where
it corrupts the result. That is why every module-level sim passed while hardware failed. The
testbench that found it wired `psikyo_sdram_top` verbatim plus `sdram_chip_model_wide` into the
screen path. When sim and hardware disagree and timing is clean, swap behavioural models for the
real transport stack before blaming synthesis.

### Ask of every stimulus whether it is the shape the real system produces

`tb_maincpu.sv` pulsed `vblank` for one clock; hardware holds it for the whole 38-line blank
(~205,000 clk_sys cycles). That hid a genuine `maincpu.sv` bug for the whole project: the IRQ logic
was `if (vblank) set; else if (iack) clear;`, giving *set* priority, so an acknowledge arriving
while vblank was still high -- always the case on hardware -- was discarded. `irq_pending` never
cleared, `ipl` stayed at 4, and the CPU re-entered the ISR after every `RTE`. With a one-clock pulse
the acknowledge always landed after vblank fell, so the test passed every time.

Same blind spot, two siblings: a testbench drives its own reset and download sequencing, so it never
reproduces MiSTer holding RESET across a transfer, and `ioctl_index` was hardcoded to 0 so an index
mismatch could never surface.

### Give a held interrupt line's acknowledge priority

Match MAME's `irq4_line_hold`: assert on the rising edge of the source, hold until acknowledged, and
give the acknowledge priority. Ask of every level-sensitive input whether it is still asserted when
the consumer responds; if so, set-vs-clear priority is a real design decision.

### Check static timing before pursuing any hardware-vs-simulation divergence

The cheapest check, and it was skipped for days. See "Timing closure".

## Testbench discipline

- **Use `do @(posedge clk); while (signal);`, never `while (signal) @(posedge clk);`.** The latter
  races an `always_ff` updating the same signal on the same edge and either deadlocks on a signal
  that already cleared or returns before a transaction started. Recurred independently in
  `ddram_phy_tb`, the `sdram_download` integration test and the `psikyo_sdram_top` integration test
  before being recognised as systemic.
- **Grep the log for `readmem` before touching RTL when a testbench fails wholesale.** `vsim`
  launched from the wrong directory made `$readmemh` find nothing, the ROM stayed all zeroes, and
  every check failed -- reading exactly like a catastrophic RTL regression. ModelSim reports it as
  `** Warning: (vsim-7) Failed to open readmem file`, not an error. Failure in *every* check rather
  than one is the signature.
  The underlying cause is that `$readmemh` paths are relative to the simulator's CWD, not the
  testbench file: `tb_maincpu.sv` must run from the repo root, `tb_psikyo_core.sv`/`tb_psikyo_top.sv`
  from their own subdirectory plus `vmap work ../../work`.
- **Write preloaded vectors and tables AFTER `$readmemh`, never before.** `tb_maincpu.sv` installed
  the level-4 autovector at byte `0x70`, then `$readmemh`'d an image spanning that address whose
  empty `0x70`-`0xFF` region zeroed it. The CPU took the interrupt correctly, fetched the correct
  vector address, read zero, jumped to `0x00000000` and executed zeroes into an illegal instruction.
  This was recorded for weeks in two documents as a TG68K.C exception microcode bug and used as the
  standing reason interrupts "could not be trusted".
- **Confirm which column is address and which is data before blaming a CPU.** The trigger for that
  wrong conclusion was reading `0x00000000` in a bus trace as the fetch address; it was the *data*
  read back from the correct address `0x70`. Suspect a zeroed vector table long before microcode.
- **Do not assert on a sticky error output that has a benign first trigger.** `fetch_overrun` fires
  unavoidably on the first active line after reset (no prior hblank to prefetch into) and once
  latched is indistinguishable from a real later failure. Replicate the DUT's trigger condition with
  a non-sticky per-cycle check instead.
- **[Fuuki] A block-local variable WITH an initializer is implicitly STATIC, and the initializer
  runs once before time 0 -- not on entry to the block.** `bit seq_ok = ((start + 8) <= trace_i);`
  inside a `begin`/`end` evaluated against `trace_i == 0` at elaboration and stayed false forever,
  failing a check the RTL was passing. The trap is that it reads exactly like a local variable in
  any C-family language. ModelSim names it precisely -- `vlog-2244: Variable 'seq_ok' is implicitly
  static` -- and that warning was skipped past as noise on the way to a "real" failure. Split the
  declaration from the assignment. Same family as the Quartus rule below about non-blocking
  assignments to automatic variables: block-local storage class is not what it looks like.
- **[Fuuki] Before concluding an interrupt path is broken, check the CPU's interrupt MASK.** A
  68000 boots at SR mask 7 with every maskable level blocked, and a game may not lower it for a
  long time -- gogomile still had mask 7 after 952 instruction fetches. "No interrupt was taken"
  and "the interrupt was correctly masked" are indistinguishable from outside the core, so expose
  the mask in the testbench and test the IRQ path with a synthetic program that enables interrupts,
  rather than waiting on a real game's init and guessing.
- **Re-run the regression on a clean stash before debugging your change.** A missing or stale
  fixture looks identical to a real regression; `git stash` plus a re-run rules it out cheaply.
- **Write a smoke test (elaborate, run N cycles, check for crash and X-propagation) before a
  functional test** on any new top-level integration -- it catches port-width and wiring mistakes
  cheaply.

## Timing closure

### Open the STA summary before believing any hardware-vs-simulation divergence

Quartus reports "Fitter was successful" on a design that grossly fails timing; nothing in the
default flow fails, warns loudly, or blocks the `.rbf`. This project shipped an `.rbf` whose main
clock domain had -8.879 ns setup slack and -21,031 ns TNS -- thousands of failing endpoints, a worst
path nearly twice the clock period -- while every log line said "successful" and "0 errors". It
appears only in `output_files/<rev>.sta.summary` / `<rev>.sta.rpt`, which nothing forces you to open.

### Read the Fmax Summary first

`emu|pll|...divclk : 48.74 MHz` against an 85.909091 MHz clock is instantly diagnostic and needs no
path analysis. It is the highest-value number in the report.

### Treat "correct in sim, wrong on hardware, reproducible, insensitive to interface tuning" as a timing violation until proven otherwise

The symptom set was: boots but reads back wrong data; roughly half of golden-ROM comparisons
mismatch; reproducible across power cycles; unaffected by SDRAM_CLK phase; 100% correct in ModelSim
with identical ROM data. All of those are also what a timing failure produces -- deterministic
because placement is fixed per `.rbf`, phase-independent because the failing paths are internal
fabric the memory clock never touches, invisible in RTL simulation because simulation has no
propagation delay. Interface tuning (clock phase, drive strength, IOE registers) only moves
*external* margins by a fraction of a clock period; if a change that size makes no difference at
all, the problem is not at the interface.

### [Seta] A clean STA summary is a property of one placement, not of the design

Build 10000019 and build 10000020 are the same commit, d908cd9. 19 was fitted
with seed 2 and reported every clock domain positive -- worst clk_sys setup
+0.950, TNS 0.000. On hardware it was broken across the board: Daioh took the
illegal-instruction vector because the reset PC came back as 0x0008040A instead
of 0x0000040A, one wrong bit in a word read from SDRAM, and then hung in the
bus FSM's S_ROM waiting for a fetch that never returned; Kamen Rider, Rezon and
Oishii Puzzle died in boot; Mobile Suit Gundam ran with a black screen. Build
20, seed 7, reports a WORSE worst slack (+0.446) and every set runs.

Nothing in the three source changes between 18 and 19 could reach those games
-- Daioh has has_wram2 = 0 and buffer_sprites = 0 -- which is what ruled logic
out and made the seed the thing to vary. The SDRAM interface is the likely
victim: neither Seta.sdc nor sys/sys_top.sdc constrains a single SDRAM pin, so
those paths are analysed on trust and the fitter is free to move them.

So: when a build regresses games whose code paths the diff does not touch,
rebuild the SAME commit at another seed before bisecting the source. It costs
one compile and it separates logic from placement outright.

### [Seta] Estimate the worst case from the hardware, not from the frames you happened to look at

The sprite engine was budgeted against a count taken from the captured frames:
a quick script said 32-61 sprites per scanline, against a budget of 6144
clk_sys cycles, and the design that followed spent ~76 cycles per sprite and
looked comfortable.

The RTL's own per-line counter then measured **155 to 544 sprites on the
busiest line of every single capture** -- 24 of 24, every game, gameplay frames
included. Not a boot artefact. The reason is structural and obvious in
hindsight: the chip walks all 512 foreground entries every line, and a game
that uses 40 of them leaves the other 472 holding whatever they held last,
which is usually one value. Every unused entry therefore has the SAME y, and
they all land on the same sixteen scanlines.

The estimate was not slightly wrong, it was wrong by an order of magnitude, and
it was wrong in the direction that makes a design look finished. Two rules come
out of it:

  * A per-line worst case is a property of the HARDWARE's iteration, not of the
    art. Count what the engine must WALK, not what the game meant to draw.
  * Instrument the RTL rather than modelling the workload. `dbg_worst_line` and
    `dbg_worst_sprites` are four lines of Verilog, they run inside the real
    engine on real data, and they answer the question the Python script got
    wrong. The same counters work on hardware, where `$time` does not exist.

### [Seta] Never write a literal into a vector that does not start at bit 0

`logic [7:1] hold` indexes interrupt LEVELS, so level 2 is bit 2. Written as a
literal, `7'b0000110` numbers its bits from the MSB down to index 1 and means
levels 3 and 2 -- not levels 1 and 2. Every pattern in the first version of
sim/irq_tb was off by one that way.

The failure was worse than a plain wrong answer: the checks that happened to
use a level the wrong pattern also set PASSED, and the ones that did not
FAILED, so the report read as a partly-broken RTL module rather than a
mis-written stimulus. Two of four checks failing is a much more convincing lie
than four of four.

The fix is not to count more carefully, it is to stop counting: a two-line
helper that takes level numbers and sets those bits removes the whole class.
Anywhere a vector's indices mean something -- levels, channels, players -- name
them; a literal is only safe when the vector starts at 0 AND the bits have no
meaning worth writing down.

### [Seta] A behavioural ROM in a bench must speak the transport's byte order

sim/irq_tb hand-assembles a 68000 program into a behavioural ROM. Written the
readable way round -- 0x00FF, 0xFFF0 for a stack pointer -- the CPU read
0xFF00.. and ran away through NOPs across the whole address space, which looks
exactly like a CPU that never started.

maincpu.sv has ROM_BYTESWAP set, because sdram_download.sv pairs image bytes
{odd, even} with the EVEN byte in the low half and the CPU swaps that back into
a big-endian word. A behavioural ROM standing in for that transport has to
present the same order, or it is not standing in for it.

Same lesson as the fixtures for every other bench here, which are built by a
script that already knows the order -- the moment a bench builds its own data
by hand, that knowledge has to be restated. It is worth saying in the bench
where the swap happens and why, rather than silently pre-swapping the table and
leaving the next reader to work out why the program looks wrong.

### [Seta] Backpressure: assert the write in the SAME step the wait clears

A testbench feeding the ioctl port has to honour `ioctl_wait`. The obvious
shape is wrong:

    while (ioctl_wait) @(posedge clk);
    @(posedge clk);                      // <- this
    ioctl_addr <= a; ioctl_dout <= d; ioctl_wr <= 1;

The extra edge lets `ioctl_wait` rise again in the gap, so the write is
asserted into a stalled port and lost. The assignments have to follow the wait
loop with no edge between them.

It presented as every ODD word of the program coming back wrong, which reads as
a byte-lane or pairing fault in `sdram_download` -- a module that does pair
bytes {odd, even} and is exactly where you would start looking. The correct
form was already in `sim/maincpu_sdram_tb`, written months of commits earlier;
the new bench reinvented the wrong one.

When writing a second bench against an interface a first bench already drives,
copy the driver rather than rewriting it. The handshake details are the part
that was hard to get right the first time.

### [Seta] A liveness test needs a timescale, or it reports failure for being early

The whole-core bench asked, after six simulated frames, whether the palette had
been written, sprite RAM had been written, and an interrupt had been taken. All
three were no, and it printed four failures. Hours went into the interrupt path
before the obvious question got asked: WHAT DOES MAME DO IN SIX FRAMES?

The answer was the same thing. thunderl's start-up is a RAM fill that is still
running at MAME's own 400,000th bus access -- tens of frames -- and six frames
of the full core is thirteen minutes of ModelSim. The bench was not detecting a
dead core, it was detecting a live one that had not got there yet.

Two rules:

  * Before asserting that something should have happened by time T, MEASURE T
    against the reference. MAME will tell you, in one command
    (`mame_capture.py --boot-trace N`), how far a game gets in N accesses.
  * A test that cannot be run long enough to answer its question should not ask
    it. Split the checks: fail on what cannot be explained by being early (the
    CPU not running at all, no video lines, a line overrun) and REPORT the rest
    as progress.

### [Seta] A constraint proved in a side project is not in your design

Phase 0 built rtl/synth_check/ -- a standalone Quartus project holding the
CPU, the sound chip and the SDRAM transport -- to answer whether 96 MHz was
reachable. It was: +0.011 ns, after a TG68K kernel multicycle that took four
attempts and a written gating audit to justify.

The first compile of the REAL project came out at -7.954 ns with all thirty
worst paths inside TG68KdotC_Kernel: the same shape, and nearly the same
magnitude, as the UNCONSTRAINED Phase 0 measurement. Seta.sdc was still the
template's two lines. The constraint had never left the side project.

The measurement was not wrong and the audit was not wasted -- but neither was
a property of the design until the constraint that produced them was in the
design's own SDC. Two things follow:

  * When a side project establishes a constraint, MOVE THE CONSTRAINT, not
    just the conclusion, and do it in the same commit as the measurement.
  * The shape of a failure identifies its cause faster than its size. "All
    thirty worst paths inside one vendored module" is not a design problem,
    it is a missing constraint on that module -- and it reads identically to
    the measurement that led to writing the constraint in the first place.

### [Seta] Two MAME conventions that read backwards, and how the wrong pixels named them

The X1-012 model was transcribed from x1_012.cpp and got the whole structure
right first time -- banks, scroll, composition. Two conventions in MAME's own
framework, neither of them in the Seta source at all, cost most of a session.

  * IN A gfx_layout, THE FIRST PLANE LISTED IS THE MOST SIGNIFICANT BIT of the
    pen. Reading `{ STEP4(0,4) }` as plane 0 -> bit 0 does not produce a wrong
    picture; it produces a RECOGNISABLE picture with a third of the pixels
    wrong, which reads as a subtly bad layout rather than an inverted bit
    order. Scoring sixteen candidate layouts against MAME's render settled it
    in one run: every ascending-plane variant scored 33-34%, the transcription
    read MSB-first scored 100.00%.

  * TILE_FLIPXY TRANSPOSES ITS TWO BITS:
        TILE_FLIPXY(xy) = ((xy & 2) >> 1) | ((xy & 1) << 1)
    with TILE_FLIPX = 1 and TILE_FLIPY = 2. So for the usual
    TILE_FLIPXY((word & 0xc000) >> 14), bit 14 is FLIPY and bit 15 is FLIPX --
    the opposite way round to what the name reads like.

The second one is the more instructive failure. It costs 2-5% of the pixels,
only on frames containing a flipped tile, and only on those tiles -- so
drgnunit was pixel-exact on all three of its frames while the other three sets
failed on five frames out of nine. That pattern says "per-game configuration",
and two hours went into per-game offsets before anything looked at the pixels
themselves. The offsets were genuinely wrong too, which made the wrong
diagnosis fit.

What found it was asking what the WRONG PIXELS HAD IN COMMON rather than which
GAMES were wrong: every one of them was in a tile whose flip bits were
non-zero. Two cheap questions got there, and both are worth asking first next
time:

  * Are the differing pixels in the layer, or in the sprites? Rendering with
    and without the sprite pass and bucketing the mismatches by which one drew
    them said "0 wrong under sprites, all wrong in the tilemap" -- and killed
    a plausible sprite-buffering theory outright, since drgnunit and stg have
    spritectrl bit 5 set and never buffer at all.
  * Do they cluster? Contiguous 64-row bands are not a decode error smeared
    over the frame; they are specific map entries.

### [Seta] A branch no capture exercises is not covered, however many runs pass

x1_001's foreground Y arithmetic has two halves, flipped and unflipped, and
the RTL sweep reported 72 of 72 runs identical to the model. Checking what was
actually in those captures: spritectrl[0] bit 6 is CLEAR in all 24 of them. No
Group A game turns flip screen on by itself, so the flipped half had never
been compared against MAME at all. The sweep was not wrong -- it was answering
a narrower question than its summary line suggested.

Flip Screen is a DIP in these games, so the obvious fix is a capture that sets
it. mame_capture.py takes --dip "Flip Screen=On" and x1_001_sweep.py --flip
captures into debug/flip-*, which the RTL sweep picks up alongside the ordinary
ones. THE MECHANISM DOES NOT WORK YET, and the way it failed is the lesson.

First attempt: the DIP is set from the autoboot script, which runs after the
machine has already reset and begun executing. Six of seven sets came back with
spritectrl[0] = 0x10 -- unflipped -- and the sweep printed PASS for all six. A
capture that is not flipped cannot say anything about flipped rendering, however
well it compares.

Second attempt: soft_reset() from the same script, so the game re-reads the
switches. That HANGS the capture -- all seven sets failed outright, MAME never
reaching the target frame and never exiting. The frame notifier the script
installs does not survive the reset it asks for.

Where it stands: thunderl produced a genuinely flipped capture twice
(spritectrl[0] = 0x50), and on it the model was pixel-identical to MAME and the
RTL identical to the model at ROM latencies 6, 12 and 24. That result is real.
It is also NOT CURRENTLY REPRODUCIBLE: the same command now returns an
unflipped frame, with MAME's own log confirming the DIP was applied
(raw 0x200). So the flipped arithmetic has been checked against MAME once, by a
route that cannot presently be re-run, which is not the same as covered.

The remaining way in is MAME's own configuration -- DIP settings live in
cfg/<set>.cfg and are applied at power-on, before any Lua runs. Writing that
file from the Python side is the next thing to try.

Two smaller things fell out of it:

  * A DIP that is silently not ACTED ON is the worst outcome available. The
    capture succeeds, MAME renders unflipped, the RTL renders unflipped, they
    match, and the test proves nothing while printing PASS. Making the Lua
    setter's own failures fatal did not help at all -- the field was found and
    set every time. Only checking the RESULT does: x1_001_sweep.py --flip now
    fails any frame whose spritectrl[0] bit 6 is clear. Verify the effect, not
    the action.

  * The first count of flipped captures read byte 0 of the spritectrl dump and
    found 0 of 24. Right answer, wrong byte: these are byte-wide registers on
    odd addresses, so ctrl0 is byte 1 of the big-endian word dump. Byte 0
    would have said "no flip" for a flipped capture too.

### [Seta] Diff the whole core against MAME, not just the CPU

sim/maincpu_tb diffs the CPU's bus trace against MAME's, and it was the test
that proved the address decode. It cannot go far, because it runs against a
behavioural ROM with every peripheral reading zero -- the first DIP read or
protection read ends it.

Tracing the WHOLE core and aligning that against MAME is a strictly better
test and costs one plusarg plus a hundred lines of Python. On thunderl it
aligned 93,775 of 100,000 accesses with ZERO data mismatches, which says
something no component test can: every peripheral, every decoded region and
every DIP byte returns what MAME's does, in the order the game asks.

It also found two real gaps that no component test would have -- thunderl's
protection register, and that its IRQ acknowledge fires on a READ as well as a
write (seta.cpp maps `.rw(ipl1_ack_r, ipl1_ack_w)` and the read handler's whole
body calls the write one).

Two notes on building the comparison itself, both of which cost a run:

  * The alignment must be able to skip on BOTH sides. A window that only looks
    ahead in one stream stalls at the first access the other never makes; that
    version reported 27 matches out of 20,000, which reads as a dead core.
  * difflib does it correctly and is quadratic. At 100,000 entries it ran for
    ten minutes without finishing. A bounded two-pointer walk is O(n * window),
    and the window only has to cover a prefetch difference -- one or two
    entries.

### [Seta] A double buffer puts the renderer TWO lines ahead, not one

The sprite engine renders into one line buffer while the video reads the other,
and they swap at line_start. The obvious cadence -- "at the start of line L,
render line L+1" -- is wrong by one, and the arithmetic says why: the buffer
written during line L is not read until line L+1, so the engine running during
L must be producing L+1; line_start fires at the END of L-1, so the line it
names is (L-1)+2.

The failure is nasty because it does not look like a timing error. The whole
picture is displayed one scanline late, which on a real frame shows up as a
few stray pixels along every horizontal edge -- measured against MAME, 3,560 of
92,160 pixels, in ones and twos, on 148 of 240 lines. That reads as sprite
dropout, and the sprite engine had a known dropout mechanism to blame it on.

What named it was shifting the captured frame by a line and re-diffing: at
+1 line the difference was exactly zero. When a picture is *nearly* right,
check rigid transforms of it before reading any logic -- the same move that
settled MAME's snapshot orientation earlier in this project, and the second
time it has paid here.

### [Seta] Put a time budget just below the period, not at it

The sprite engine has a line_budget that stops it when it runs out of time, and
the natural value is the line period itself. At exactly the line period the
cutoff and the buffer swap race: the swap arrives first often enough that the
engine takes its "started while still busy" path, which RESTARTS it mid-render
rather than stopping it cleanly, and the partially rendered buffer goes to the
screen anyway. Measured, 49 lines a frame did that.

Setting the budget 44 cycles below the period (6100 against 6144) gives zero
overruns and 49 clean cutoffs, with identical output. A deadline that coincides
with the event it is meant to pre-empt is not a deadline.

### [Seta] Look for the permutation that lives above byte granularity

The sprite ROM fetch cost four SDRAM round trips per 16-pixel row, because
MAME's `RGN_FRAC(1,2)` layout puts the four words 16 bytes and half a region
apart. The obvious fix -- rewrite the data so a row is contiguous -- looked
expensive, because "rewrite the data" implies a byte-level shuffle somewhere in
the loader, and the loader pairs ioctl bytes into 16-bit words as they stream.

Writing the two addresses out side by side is what settled it:

    source byte = h*(S/2) + tile*64 + yh*32 + xh*16 + yl*2 + p
    dest   byte =          tile*128 + yh*64 + yl*8  + h*4  + xh*2 + p

The plane bit `p` is the low bit of BOTH. Nothing below a 16-bit word moves, so
there is no shuffle at all -- only a word-address bit permutation, which is
free wherever the address is already being computed.

Measured: reads per sprite row 4 to 1, worst line 39,497 to 20,017 cycles, and
sprites completed per line at a 6144-cycle budget 68 to 140 (ROM latency 12)
and 43 to 108 (latency 24). The last is the one that mattered -- before, a slow
SDRAM broke the picture (6 of 24 captures correct); after, it does not (22 of
24 at every latency tested).

Before assuming a data-layout change needs the data touched, write the source
and destination address expressions out and look for the shared low bits.

### [Seta] The same width truncation, in the testbench this time

The granule fetch indexed the behavioural ROM with `rom_hold_a[19:3]` where the
array needs `[20:3]`. thunderl's 0.5 MB sprite region only needs 16 bits of
granule index, so it passed; atehate's 2 MB region needs 18, and it failed --
as wrong PEN VALUES on one game out of eight, which reads like a decode bug
rather than an address one.

Third instance in this project of the same shape (see the entry on the SDRAM
bridge's 26-bit port taking a 27-bit connection): a slice wide enough for the
small cases that silently drops the top bit for the large one. The tell is that
exactly the biggest asset fails. When one game out of a set misbehaves, check
the widths against THAT game's sizes before reading any logic -- and note that
a part-select which is in range draws no warning from the simulator.

### [Seta] A back-to-front line buffer cannot drop the right sprites

Following on: 512 sprites in 6144 cycles is 12 cycles each, and the real chip
plainly managed it -- a 32-bit sprite ROM bus at 16 MHz delivers exactly 4096
bytes per 64 us line, which is 512 rows of 8 bytes with nothing to spare. So
the real X1-001 has a per-line limit too, and MAME's own comment says as much
("Draw up to 512 sprites, mjyuugi has glitches if you draw them all").

An engine that draws back-to-front and stops when it runs out of time drops the
sprites it has not reached yet -- and back-to-front means those are the LOWEST
indices, which the chip draws LAST and therefore puts ON TOP. Exactly
backwards: overflow would delete the player and keep the background.

The fix is to stop encoding priority in the write order. Give each line-buffer
entry the index that wrote it, write only when the new index is lower, and walk
the list front to back. Order stops depending on time, and running out of time
drops the bottom-most sprites, which is what an overflowing sprite chip does.

### [Seta] Relaxing a constraint that is no longer the bottleneck measures WORSE, not better

The TG68K kernel multicycle went from 4 to 6 -- a value the clock-enable ratio
genuinely supports at 96 MHz / 16 MHz -- and slack got worse: **-1.816 ns at 4,
-1.969 ns at 6**, with TNS rising from -963 to -1444.

Nothing was wrong with the constraint. By that point the critical path had left
the kernel entirely and ended on the sound chip's accumulators; relaxing the
kernel further bought nothing and let the fitter spend its effort somewhere
that no longer mattered. Re-read `report_timing` after every constraint change
rather than assuming the same block is still the problem, and do not raise a
multicycle just because the arithmetic permits it.

### [Seta] Register a peripheral's CPU interface, and give the access an extra cycle — do not constrain over it

The whole Phase 0 subsystem's critical path, after the CPU itself was
constrained, ran:

    TG68K register file -> maincpu data out -> the sound chip's address decode
    -> its key-on comparison -> a 32-bit accumulator clear

all in one clock. Registering the key-on path took slack from -1.816 to
-1.169 ns, and the remaining failures were the *same source* landing one step
further down, on that chip's register-RAM inputs.

Registering the whole CPU interface into the peripheral, and spending one more
cycle in the CPU's access state machine to match, took it to **+0.011 ns,
TNS 0.000** -- closed. The cost is nothing: the CPU is stalled for the whole
bus cycle and steps once every six clk_sys cycles, so there is room for four.

The general rule: a peripheral hanging combinationally off the CPU data bus
puts the CPU's slowest register output in series with the peripheral's decode
and its RAM setup. That is a structural problem, and a multicycle over it is a
promise about timing that the design does not actually make. One register stage
is cheaper, provable, and does not need an audit.

Note also the margin: +0.011 ns is closure with essentially none. The video
engines are still to come, and they will need their own budget.

### Discard measurements taken while the design fails timing

The "~51% of ROM words match" figure and the original SDRAM_CLK phase sweep were both taken while
the entire clk_sys domain failed by 8.9 ns, and both were used to rule the memory interface *out*.
Re-run any measurement that predates a timing fix.

### Get the failing paths with a `quartus_sta` Tcl run

The default `.sta.rpt` has only summaries, and the Timing Closure Recommendations panel is HTML-only
so it is empty in the text export. See `scripts/sta_failing_paths.tcl`:

```tcl
project_open Psikyo -revision Psikyo
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c   ; # NOT -slow_model / -speed 7
read_sdc
update_timing_netlist
report_timing -setup -npaths 50 -detail summary -from_clock $ck -to_clock $ck -file out.rpt
```

`create_timing_netlist -speed 7 -slow_model` is rejected outright, and the useful error ("Values
entered did not match any valid operating conditions") appears above the generic Tcl failure. Run
`-detail summary` first: 50 summary rows immediately showed every failing path shared one module,
which full-path detail would have buried.

### Never let a multicycle constraint touch a posedge-to-negedge path

A constraint matching `{*TG68K:*|*}` sweeps the wrapper's falling-edge registers into the collection
and grants a HALF-cycle path (~5.8 ns at 85.909091 MHz) two or four FULL cycles -- up to ~46 ns. The
Fitter routes it that slowly, the timing report stays clean, and the design fails only on silicon.
Two registers caught this way were `waitm` (the DTACK sample) and `data_akt_e` (which gates the DATA
tri-state), so relaxing them corrupts bus handshaking directly. If a multicycle is needed at all,
scope it to a block verified single-edge and explicitly `remove_from_collection` every falling-edge
register from BOTH ends.

### Know that the stock MiSTer `.sdc` constrains nothing external

`derive_pll_clocks` + `derive_clock_uncertainty` is the entire stock file. It constrains internal
register-to-register paths (which is how the CPU failure was caught) and leaves every external
interface, including all of SDRAM, unanalyzed. Non-empty Unconstrained Paths and Unconstrained I/O
panels are normal for MiSTer and not by themselves a bug -- but "timing passed" says nothing about
the memory interface.

## CPU cores (TG68K.C, T80)

### Budget for the 68k core to be the Fmax-limiting block

Measured Fmax on the real post-fit netlist, Cyclone V speed grade 7: 48.74 MHz. All 50 worst-slack
paths in the design were inside `TG68KdotC_Kernel` -- the `altsyncram` register file and the
`regfile_rtl_*_bypass` network, driven from `use_direct_data` and `exec[*]`, needing ~19.6 ns.
Nothing else (video, SDRAM, sound) failed timing at all. TG68K.C also has no clock-enable input of
its own to protect you.

### Instantiate `TG68KdotC_Kernel` directly and own the bus interface

`TG68K.vhd` is an async-68000-bus adapter, not the CPU: it wraps the core in a bus-protocol emulator
that assumes `CLK` *is* the CPU clock, hence its `falling_edge` registers (`as_e`, `rw_e`, `uds_e`,
`lds_e`, `clkena_e`, `data_akt_e`, `cpuIPL`, `waitm`, `E`). Slowing it down means fighting its
design. The kernel is entirely rising-edge (verified: zero `falling_edge` occurrences) and exposes
`clkena_in` for exactly this. `mist-devel/plus_too`'s `tg68k.v` is the canonical example:

```verilog
wire tg68_clkena = phi1 && (s_state == 7 || tg68_busstate == 2'b01);
```

Its own state machine handles DTACK and stalls the CPU purely by gating `clkena_in`; the interface
is `busstate`/`addr_out`/`data_in`/`nUDS`/`nLDS`/`nWr` (`busstate == 2'b01` means no memory access,
so the CPU free-runs). Nothing inside the core is modified.

What was tried instead and failed: adding `ext_clkena` to `TG68K.vhd` and gating every clocked
process. It appears to work (`tb_maincpu` passed, the real-ROM sim booted) but the two clock edges
need two separate enables -- a rising-edge register samples the enable held during the *preceding*
period, so one shared enable runs each emulated CPU cycle's halves in the wrong order -- and the
timing report then needs a `set_multicycle_path` to accept the result, which is where it turns
dangerous. Four layers of scaffolding on a battle-tested core, and it still did not boot.

### Derive the clock-enable ratio exactly rather than rounding

clk_sys here is the real 14.318181 MHz screen XTAL x 6 = 945/11 MHz and the 68EC020 wants 176/11
MHz, so the enable rate is exactly 176/945 and a Bresenham accumulator hits it with zero error. The
tempting integer divides are meaningfully wrong: /5 is 7.4% fast, /6 is 10.5% slow. (Alternatively
drop clk_sys to 42.954545 MHz = 14.318181 x 3, keeping the pixel divide exact at 6:1 and landing
under TG68K's measured Fmax outright.)

### Do not rely on Quartus resolving an open-collector net the way ModelSim does

`TG68K.vhd` drives `RESET <= '0' WHEN nResetOut='0' ELSE 'Z'` (same for `HALT`) because the core can
self-assert reset, while the wrapping SystemVerilog also drives these lines -- a genuine
open-collector bus, which `tri1` models correctly in simulation. Quartus 17.0 instead emits
`Warning (13048): Converted tri-state node "..." into a selector`, and that selector's behaviour for
the both-released-to-Z steady state is wrong on silicon: the resolved value sticks low, holding
permanent reset. Confirmed by a live hardware debug tap (VGA-colour-coded build) showing the kernel
reset stuck asserted on a DE10-nano while the same RTL simulated correctly.

Fix pattern: do NOT make either side of the shared net non-tri-state. Add a separate, single-driver
signal and OR it into the downstream computation that needs the correct value -- a new
`ext_force_run` port with `cpu1reset <= (RESET OR HALT) OR ext_force_run;`. `1 OR anything = 1`
forces the correct steady state without creating a second driver.

Then check every consumer, not just the first found. The wrapper's own bus-cycle state machine used
the same raw `RESET` as its async reset, so fixing only the kernel's `nReset` left the CPU out of
reset with bus-cycle generation still stuck. Signature of "fixed one consumer, missed another": the
CPU stops asserting reset but still generates no bus activity.

### Expose a new port rather than a hierarchical reference for a debug tap

SystemVerilog hierarchical references into VHDL internals work in ModelSim but do not elaborate for
Quartus at any depth -- both `u_cpu.cpu1reset` and `u_cpu.cpu1.Reset` gave
`Error (10207): can't resolve reference to object`. Add a real output port to the vendored entity;
unconnected new ports at other instantiation sites are legal, so no other caller needs touching.

### Add explicit zero initializers to vendored VHDL signals before simulating real programs

`TG68K_ALU.vhd`/`TG68KdotC_Kernel.vhd` have many `std_logic`/`std_logic_vector` signals with no
default. ModelSim's `'X'` propagates through arithmetic from time 0 and can cascade into multi-GB
allocation failures or SIGSEGV once a real program (not a four-instruction spike) exercises enough
logic. Known upstream issue (TobiFlex/TG68K.C#21); 123 signals initialized here. Simulation fidelity
only -- same class of fix as `sdram.sv`'s uninitialized `state`/`ack0..2`.

### Exercise the ISA extensions you depend on, deliberately

The Phase 0 spike ran 68020-only opcodes (MULU.L, DIVU.L, scaled-index addressing, BFEXTU) before
further work was committed. Two apparent "core bugs" during that spike turned out to be testbench
mistakes.

### Derive `WAIT_n` timing from the CPU's internal T-state behaviour, not external bus inference

A T80 ROM-interface design based on top-level signal tracing alone hit a reproducible bug -- a
multi-byte opcode whose own read M-cycle follows two operand fetches corrupted the destination
register, with no visible access to the target address anywhere in the external trace -- and was
reverted. Reading `T80.vhd`/`T80se.vhd` gave the facts that mattered: `TState` freezes while
`WAIT_n` reads 0 (resampled every cycle, no edge logic), data is captured on the exact edge that
condition first goes true, and `RD_n`/`MREQ_n` are registered outputs defaulting high every cycle,
so there is always a one-cycle gap between M-cycles even within one instruction -- which a
same-cycle edge-detector design cannot assume. The fix was a level-tracked `rom_pending` gated by a
glitch-free combinational `is_rom_read` level, confirmed by re-running the failing scenario with
hierarchical access to the core's own `MCycle`/`TState`, not by "the test passes now".

## Quartus synthesis gotchas (not visible in ModelSim)

- **Non-blocking assignments to block-local (`automatic`) variables are rejected**, even with the
  `static` keyword, in a pattern that compiles fine under ModelSim:
  `Error (10959): illegal assignment - automatic variables can't have non-blocking assignments`.
  Move them to module-level declarations, then re-run the full ModelSim regression.
- **Multi-driver conflicts on a shared tri-state net are a hard, unsynthesizable error**, not an
  ambiguity Quartus resolves. Making either side non-tri-state while the other still drives gives
  `Error (13076): "..." has multiple drivers due to the non-tri-state driver "..."`, and it can
  surface at a much deeper signal than the one you touched (fixing `cpu1reset` surfaced a conflict on
  `TG68KdotC_Kernel:cpu1|syncReset[3]`). Use the separate-signal OR pattern above.
- **A non-power-of-2 modulo synthesizes as a slow generic iterative divider and can dominate timing
  closure.** `sprite_index <= sram_data % 16'd768;` produced the worst timing path in the whole
  design (`Mod0|auto_generated|divider`), buried inside `sprite_display_list_walker.sv` and not an
  obvious suspect from a read-through. An explicit N-stage conditional-subtraction chain (subtract
  decreasing power-of-2 multiples of the modulus when they fit) kept the same one-cycle
  combinational timing and cut worst-case setup slack by 81%. Read `report_timing`'s worst path
  rather than guessing which module is at fault.
- **Negative PLL phase shifts are not legal for every PLL configuration.** `quartus_fit` rejected
  `-3000ps` outright; only `0ps` and positive values in fixed steps (~132.275 ps here) are legal.
  Convert to `period - abs(shift)`, rounded to the nearest legal step Quartus names in its own error.
- **Driving a dual-port RAM's second read port can silently REPLICATE the whole array.** A block
  RAM has one write port and one read port per physical port; asking for two independent read
  addresses plus a write is a shape the M10K cannot provide, so Quartus duplicates the memory and
  writes both copies. Symptom: a 128KB work RAM reporting 2,097,152 block memory bits, about 102
  extra M10K, and a design that had fitted the day before failing with
  `Error (170048): ... needs more than 553 to successfully fit`. The trigger looked harmless -- the
  second port had been tied to a constant address and was therefore optimized away entirely, so
  hooking a real address to it was read as "using a port that was already there". Give the new
  consumer the EXISTING port instead when the two can never collide (here the consumer only touched
  RAM with the CPU paused). Check `Block Memory Bits` per hierarchy node in the map report against
  the array's arithmetic size before assuming an unused port is free.
- **A design can be BRAM-bound while logic sits at 40%.** Budget features in M10K blocks, not ALMs.
  Bit occupancy is the number that matters: no memory packs at 100%, so a design at ~95% of the
  device's block memory bits cannot be made to fit by repacking, only by removing memory. Repacking
  a 12-bit-wide array as 8+4 to land on native widths is a real technique, but it is worth nothing
  if the true cause is an array that should not be there at all -- confirm where the bits went
  before restructuring anything.
- **`set_instance_assignment -name RAMSTYLE` is rejected by the .qsf parser in Quartus 17.0**
  (`Error (125048): Error reading Quartus Prime Settings File ... line N`, which aborts the whole
  project open). Use the HDL `(* ramstyle = "..." *)` attribute instead.
- **`quartus_map` (Analysis & Synthesis only) is a fast pre-check** (~2-3 min vs ~5-6 min for a full
  compile) for whether an RTL change even elaborates. Quartus auto-parallelizes across cores;
  ModelSim in this edition is single-threaded.

### [Seta] A true dual-port RAM must be ONE always block with both ports in it, or it is built out of logic

Two separate `always_ff` blocks writing the same array does not infer a
dual-port M10K. Quartus cannot see the shape, builds the array out of
registers and muxes, and says nothing about it.

An 8 KB register file written that way took the design to **122,886
combinational nodes against the 83,820 the device has** — it missed fitting by
47%, for one 8 KB array. What the tool reports is:

```
Error (170011): Design contains 122886 blocks of type combinational node.
                However, the device contains only 83820 blocks.
Error (11802): Can't fit design in device.
```

Nothing in that names the RAM, and the obvious reading — the design is simply
too big — sends you looking at the wrong thing entirely.

The template Quartus does recognise puts both ports in one block:

```systemverilog
always_ff @(posedge clk) begin
    if (we_a) mem[addr_a] <= din_a;
    q_a <= mem[addr_a];
    if (we_b) mem[addr_b] <= din_b;
    q_b <= mem[addr_b];
end
```

This is the neighbour of the existing entry about a second read port silently
REPLICATING an array: that one is about asking for two independent read
addresses plus a write, which an M10K cannot provide. Both end with block RAM
not being block RAM, and neither announces itself. Check `Block Memory Bits`
per hierarchy node in the fit report against the array's arithmetic size, on
any design with a RAM in it, before believing a resource number.

Corollary worth stating separately: a **synthesis harness is how you find
this**. The functional simulation passed before and after the fix — nothing
about the behaviour changed. Only a real fit on the real device says whether
what you wrote can exist.

## Debug instrumentation: how not to fool yourself

- **Never reset a debug counter with the reset you are investigating.** Two measurements read
  `0x000000` and were reported as findings before it was noticed the counters were cleared by
  `reset`, which is asserted for the whole measured window. Declare debug counters with `= 0`
  initialisers and no reset; Quartus powers registers to zero, so what they show is what genuinely
  happened since configuration.
- **Pair every "bad event" counter with a "total events" counter.** A zero can mean "did not happen"
  or "was never allowed to count"; counting only dropped bytes cannot tell those apart.
- **Sample registered signals, not combinational ones, and prove the probe on a known-good
  configuration first.** A tap on combinational `cpu_data` sampled at `cpu_ce && !as_n && !dtack_n`
  appeared to show the CPU latching byte-skewed data -- compelling and false. The same probe in a
  simulation that demonstrably boots showed the same skew. If a new probe reports a fault on a
  known-good setup, the probe is the fault.
- **Never let a probe's step size share a factor with the period you are measuring.** A BRAM tracer
  skipping `window * 256` events returned byte-identical captures for windows 0, 8 and 15 (skips of
  0, 2048, 3840), equally consistent with a CPU resetting every 256 reads and a read path aliasing
  every 256 words. The step is now `window * 8191` -- odd, so it cannot alias with a power-of-two
  period. When a probe gives the same answer at every setting, suspect the step.
- **Capture the full address.** Packing only `addr[7:0]` into a 24-bit pixel made a genuine linear
  sweep through ROM look exactly like a read path dropping its high address bits, destroying the
  distinction between "progressing" and "stuck". If address and data do not fit together, use two
  buffers strobed by the same event so entry N of each describes the same bus cycle.
- **[Fuuki] The framework applies the user's gamma LUT to the core's RGB before screenshots;
  force it off under a debug overlay.** Trace entries drawn as 24-bit pixels came back remapped:
  `0x40 -> 0x38`, `0x20 -> 0x1A`, `0x02 -> 0x01`, `0xBF -> 0xBA`, `0xFF -> 0xFF` -- a monotonic
  per-channel curve, lossy at the low end. That looked like SDRAM data-lane corruption (walking
  ones "smeared"), a quarter-period `SDRAM_CLK` phase change did not alter it, and the JTAG-read
  values matched the ROM throughout. The cause was `preset_default=Display Specific/Sony PVM` in
  the device's `MiSTer.ini`, whose preset sets `gamma=Pure_Gamma/gamma_110.txt`; every captured
  row equalled `gamma_110(expected)` exactly once that LUT was applied (240/240 rows, two
  patterns). `Fuuki.sv` now clears `gamma_bus[19]` (gamma_en, `sys/gamma_corr.sv`) whenever the
  overlay is on, leaving the user's display settings alone. Draw the value and its bitwise
  inverse in alternating bands (`scripts/tracer_readout.py`): the pair must XOR to `0xFFFFFF`
  whatever the memory holds, so any transform in the capture path is detected rather than read as
  data.
- **[Fuuki] A testbench that models the memory the core instantiates cannot see the core's
  indexing.** `sim/maincpu_tb` passed 84/84 boot fetches and its interrupt case, with its own
  `BRAM` macro standing in for work RAM. The core's work RAM indexed `workram_addr[16:1]` -- a
  word address halved again -- so consecutive words shared an entry. Nothing in the boot read RAM
  back until the first `rte`, which popped SR = 0 and PC = 0, and the hardware ran user-mode code
  at address 0 into vector 4. Found by freezing the trace ring on the first vector-2..4 read and
  reading the 255 ROM fetches before it (`scripts/boot_trace.py --trig`): the address sequence
  alone -- `rte` at `0xBFA` followed by a user-mode fetch at `0x000000` -- named the stack. Where
  a testbench substitutes its own model for a block, add a check that runs the real block, or
  treat that block as unverified.
- **[Fuuki] "The game plainly means no interrupt" is a guess; what MAME actually does is the
  spec.** The raster register parked at `0xFFFE` was read as "disable", and the RTL fired
  nothing. The game hung on hardware: its main loop waits on a flag only the level-5 handler
  sets, so it needs one IRQ5 per frame however the register is parked. MAME's `time_until_pos()`
  wraps the line modulo the screen height and fires it every frame, and the game is known to work
  there. Found in one JTAG probe read: `last_rom_addr` alternating over a 4-word loop, decoded
  from the ROM as `btst #1,$403446.l / beq`. Where a driver hands a register to a MAME
  framework call, follow the framework's arithmetic too, not just the driver's — **with the
  framework's numbers.** The first fix reduced modulo this core's 262-line frame and put the
  interrupt on line 34, mid-picture; the driver's screen is 256 lines, which puts it on 254, in
  vblank. The height that matters is the one the game was written against, and that is whatever
  the driver declares, not whatever the RTL's crystal produces.
- **[Fuuki] Freezing the display LIST is not freezing the display.** FG-2 sprites were drawn from
  the live sprite RAM on the reading that the once-per-frame candidate list already froze the
  frame. The list was frozen; each scanline then re-read the records from the live RAM while the
  game rewrote them, so a sprite could change tile or position mid-frame, and a record rewritten
  between the build and its scanline dropped out for a frame. MAME draws the sprites in one pass
  from one instant of the RAM. Everything a per-line renderer reads during the frame -- records
  and the registers that qualify them -- has to come from one snapshot taken at the frame
  boundary (`rtl/video/spriteram_dbuf.sv`).
- **[Fuuki] When widening an address, grep for every packed bus that carries it, and give the
  bench a read at a non-zero offset per client.** The 26-bit widening changed every declared
  `[24:0]`, but `sdram_arbiter` packs its clients' addresses as `[25*N-1:0]` / `c_addr[25*k +: 25]`
  -- a width written as arithmetic, not as a range -- and `fuuki_sdram_top` went on concatenating
  three sums that had become 26 bits. Layer 0 still lined up; layers 1 and 2 read from addresses
  shifted by one and two bits, and both boards drew garbage tilemaps while sprites (a single-client
  arbiter) stayed right. `sim/sdram_tb` passed because its layer-1/2 reads were at offset 0, where a
  shifted zero is still zero. It now reads every client at a non-zero offset inside its own region,
  and drives the top's `board` input -- an undriven select had turned the base addresses to `X`.
- **[Fuuki] One unsigned operand makes the whole comparison unsigned, and a coordinate that can
  go negative then wraps.** The sprite engine chose which sub-tile row covers a scanline with
  `line12 < (row_origin + 12'(dst_h))`. `row_origin` was signed and `dst_h` was not, so the
  addition and the comparison were evaluated unsigned: a sub-tile row entirely above the top of
  the screen has a negative end, which wrapped to ~4092 and made the test true on EVERY scanline.
  The row search then stopped at that row for the whole sprite and drew its tiles on every line --
  the same tiles repeated down the screen, on tall sprites only, and only while part of one was
  off the top. Nearby tests survived the same mistake by luck (their true sums were positive and
  fitted, so the wrapped bit pattern was still right), which is why one bug and not four. Make
  every operand of a signed comparison explicitly signed and wide enough not to overflow, and
  distrust "it works" where a coordinate has simply not gone negative yet.
- **[Fuuki] A debug gate that keys off the load path dies when the load path changes.** The trace
  sources and the memory walker were gated on `dl_done`, set by seeing `ioctl_wr` with index 0.
  Adding the fast DDR ROM load -- where the HPS DMAs straight into DDR3 and NO ioctl write ever
  reaches the core -- left that flag clear forever, so every dump came back as 256 zeros with the
  readout reporting no problems at all, because the buffer genuinely held zeros. The same omission
  would have held the core in reset via `rom_loaded`; that one was caught by reading, this one by
  a dump that had worked an hour earlier. When a transport is replaced, grep for every flag
  derived from the old one.
- **[Fuuki] `write_source_data -value` takes a binary string; pass `-value_in_hex`.** The ISSP
  Tcl wrote `-value 8`, printed "source set to 8", and the source read back `00`: a decimal string
  is silently rejected. Every page select, phase step and walker re-arm issued that way had been a
  no-op, while `clear` worked by accident ("1" and "0" are valid binary). Read the source back
  after every write and print it.
- **VGA-colour-override builds answer yes/no hardware questions without a logic analyzer.**
  Overriding `VGA_R/G/B` with a solid colour gated by an internal signal turns "is this condition
  true on real hardware" into one unambiguous screenshot -- used to confirm the video datapath works
  at all, then for a 3-way readout of CPU ROM-fetch activity via sticky latches and a 4-colour
  readout adding live kernel-reset state. Remove all `dbg_*` ports and wiring once the bug is fixed.
- **JTAG ISSP pokes test a hypothesis on live hardware without a rebuild.** With the CPU paused,
  `scripts/write_vram1.tcl` wrote single VRAM words and the screen response was read directly; that
  established the chained N/N+1 dependency behind the tilemap handshake bug, in two games, before
  any RTL changed.
- **Do not blind-enable an interrupt path you have no way to verify.** Enabling the YM2610 timer IRQ
  to the Z80 took its ROM-fetch counter to zero immediately -- a complete lockup, not "runs but
  silent", and a hang is a worse regression than the symptom it was meant to fix. Expose the CPU
  state needed to read the outcome (`halt_n`, ideally PC) in the same build that enables the path.
- **A sound CPU that programs the chip once and then goes quiet is an interrupt-path symptom.** 46
  YM2610 register writes were measured immediately after launch and zero over a later 15-second
  window: the init burst runs from boot code, and the chip's own timer interrupt -- how arcade
  drivers sequence music -- was not reaching the CPU. (The eventual cause was transport bugs
  elsewhere; the IRQ is required for music.)

### [Seta] Under a clock enable, a registered RAM needs NO wait state — and adding one shifts every capture by a register

"Give a registered RAM its full read latency before consuming the data" is right
and it does not apply to a block stepped by a clock enable. The X1-010 engine
advances one state per `ce`, one clock in six, while `eng_q <= regmem[eng_addr]`
runs every clock — so by the next engine step the read completed five clocks
ago, and each state can capture its own byte and set the next address with no
wait state at all.

Applying the rule anyway cost a full debug cycle. The extra lead-in state shifted
every capture by one: `r0` got register 1, `r1` got register 2, and so every
channel read its mode, key-on and divider bits out of its *volume* register. The
result was a silent mix and not one PCM voice ever requesting a sample — which
looks like a dead engine, not an off-by-one.

The dependency is worth writing down where the code is: this is only safe while
`CE_DIV > 1`. At one enable per clock the wait state genuinely would be needed.

### [Seta] A free-running engine emits samples before your test has finished configuring it

The X1-010 runs continuously — one output sample per 512 chip clocks, whatever
the registers hold. Loading an 8 KB register image through the CPU port takes far
longer than that, so the engine had already emitted several passes' worth of
samples from a zeroed register file before the first real register arrived. The
bench compared those against the reference's *first* samples and reported "the
RTL disagrees" at sample 0 with the RTL silent — indistinguishable from a dead
engine.

Load the configuration with the block in reset, release, and compare from there.
That also gives both sides the same starting accumulators, without which a
sample-for-sample comparison is not meaningful anyway. Whatever the reset
suppresses then needs its own directed check — here, key-on edge detection,
which a clean start cannot exercise.

### [Seta] Do not reach into the DUT with `force`/`release` when an ordinary write will do

The key-on check first forced an accumulator to a known value, released it, and
wrote the key-on register. It reported a failure the RTL did not have: the mirror
bit updated correctly and the accumulator did not clear, which read as a broken
reset path. Rewritten to drive the DUT the way hardware drives it — let the
channel run, then key off and on through the register — it passes.

`force` on an array element inside a clocked block is one more thing that can be
wrong, in a test whose whole purpose is to decide whether something else is
wrong. Prefer stimulus the design already accepts.

## Driving MAME as a reference generator (Lua)

- **[Fuuki] Keep every MAME Lua subscription in a variable that outlives the call.**
  `emu.add_machine_frame_notifier` and `install_write_tap` return subscription objects, and
  dropping the return value lets the garbage collector reclaim them, after which the callback
  **silently stops firing**. The failure is thoroughly misleading: a capture at frame 120 worked
  (the callback ran long before any collection), the identical capture at frame 1100 produced no
  files, no error, and MAME exited with status 0. Store them in a global.
- **[Fuuki] Check `mame.ini` for `debug 1` before automating anything.** With it set, every launch
  opens the debugger and halts at startup. An autoboot script still loads and still prints, so it
  looks like it is working, but the machine never advances a frame. Pass `-nodebug` explicitly
  rather than trusting the ini. Same for `window 1` when running headless.
- **[Fuuki] Snapshots work fine under `-video none`**, and land in
  `<snapshot_directory>/<system>/0000.png` -- one level deeper than the directory given. Search
  recursively for them rather than globbing the directory itself.
- **[Fuuki] Read dumps through the CPU's own address space**, not out of MAME's internal
  structures: `devices[":maincpu"].spaces["program"]:read_u16(addr)` returns what the CPU would
  read, device handlers included, which is the thing the RTL has to match.
- **[Fuuki] Reduce by the driver's screen height, not the RTL's.** MAME's `time_until_pos()` wraps
  a raster line modulo the *driver's* declared height, 256 for both Fuuki boards; the RTL's own
  frame is 262 lines. Reducing by 262 put gogomile's parked `0xFFFE` on line 34, in the picture,
  where MAME puts it on 254, in vblank — the title-cloud jitter. The value the game was written
  against is whatever the driver declares.
- **[Fuuki] Build from a snapshot, not from the tree you are editing.** Psikyo's
  `build_staged.py` was looked at, judged optional, and left unported. The bill arrived as a whole
  session of serialised work: every source edit waited on a thirteen-minute compile, a build died
  mid-Fitter with an edit in flight, and a `.qsf` hand-edit (`MISTER_FB=1`) was silently reverted
  by Quartus re-saving the project between builds. A worktree at `build/` costs one script.
- **[Fuuki] A vendored core that is silent in simulation may only be uninitialised.** jotego's
  jtopl and jt12 leave their envelope and operator pipelines without reset; hardware powers them up
  at zero, ModelSim leaves them X, and X through an envelope generator is a chip that takes every
  register write and never makes a sound. `$isunknown` on the output named it in one run;
  `+initreg=r+0 +initmem=r+0` on those files is the fix, not an edit to them.
- **[Fuuki] A chip select from an address decode alone takes memory writes too.** `WR_n` is
  asserted for memory and I/O cycles alike, so `cs_n = ~(a[7:1] == 0x28)` handed every RAM write to
  `0x6x50/51` to the OPL's register file. Qualify with `IORQ_n`.
- **[Fuuki] A bench that prints nothing has usually not run.** A ModelSim compile killed by a tool
  timeout leaves `work/_lock`, on which every later `vlog`/`vcom` waits silently; three "silent
  chip" investigations were a lock. `run_sim.sh` now recreates the library every run.
- **[Fuuki] When reading finds nothing, tag the data and let the hardware say where it went.**
  A one-line offset was argued over three pipeline stages without a conclusion. Tagging each line
  buffer with the row its engine set out to render and subtracting the display line, on the probe,
  answered the stage question in one read (delta 0); two white marker lines answered the framing
  question by eye. Both cost a few lines of RTL and one build.

- **[Seta] An error inside a MAME write tap is SWALLOWED, so a broken callback
  is indistinguishable from "no writes happened".** The ported capture script
  logged register writes with `scr:vpos()`. MAME 0.286's Lua screen binding has
  no `vpos()` (nor `hpos()`) -- both are `nil` -- so every callback raised
  "attempt to call a nil value" and MAME reported nothing at all: the log
  contained only its header, the run exited 0, and the obvious reading was that
  the game simply had not written to that range. It had: an instrumented
  rebuild counted **459 tap hits, 0 logged**. Two rules follow. Wrap every tap
  callback in `pcall`, keep a *hits* counter beside a *logged* counter, and
  write both plus the first error into the log -- the same bad-event/total-event
  pairing the hardware probe uses. And derive what the binding does not offer
  rather than assuming a documented method exists: the scanline now comes from
  `time_until_pos()`, which does exist —
  `line_period = time_until_pos(1) - time_until_pos(0)` (smallest positive
  sample, so a frame wrap cannot poison it), then
  `line = (frame_period - time_until_pos(0)) / line_period`.
- **[Seta] MAME's declared frame for this hardware is 256 lines, and that is the
  number the games' own arithmetic is written against.** The derivation above
  yields `frame_period / line_period` = 256.000 exactly on thunderl, gundhara
  and daioh. The RTL's frame will be ~262. This is the same trap Fuuki hit from
  the other side ("Reduce by the driver's screen height, not the RTL's"): where
  a value is compared against a raster position, the height that matters is the
  one the driver declares.

## ROM formats

- **[Seta] `ROM_LOAD24_*` is a driver-local macro, not a core one -- read its
  definition rather than inferring it from the name.** seta.cpp's 6bpp tile
  layers load through macros the driver defines itself at line ~9176:
  `ROM_LOAD24_BYTE` is `ROMX_LOAD(..., ROM_SKIP(2))` and
  `ROM_LOAD24_WORD_SWAP` is `ROMX_LOAD(..., ROM_GROUPWORD|ROM_REVERSE|ROM_SKIP(1))`.
  Loaded at offsets 0 and 1, that builds the region as 3-byte groups:

  ```
  dest[3g]   = byte_rom[g]
  dest[3g+1] = word_rom[2g+1]      # the word ROM, byte-swapped
  dest[3g+2] = word_rom[2g]
  ```

  Verified offline against gundhara: `bpgh-009` (0x80000) + `bpgh-010`
  (0x100000) gives exactly the declared `ROM_REGION(0x180000)`, and tiles then
  decode as real artwork with up to 26 of 64 pens rather than noise. Settling
  this before writing any `.mra` cost minutes; discovering it during hardware
  bring-up would not have.
- **[Seta] A `gfx_layout` transcription can be checked without any ROM: a
  well-formed one uses every bit of a tile exactly once.** Mapping every
  (x, y, plane) to its bit offset and counting should give
  `width * height * planes` distinct offsets covering `[0, charincrement)` with
  no gaps and no duplicates. All four Seta layouts pass, which catches a
  mistyped `STEP` or a wrong stride immediately -- before any ROM is available,
  and independently of whether the artwork "looks right", which is the
  judgement a wrong-but-plausible layout defeats.

## Hardware bring-up (MiSTer / DE10-nano)

- **The DE10-nano SDRAM pinout has an authoritative in-repo reference; do not go to the web.** The
  `.qsf` does `source sys/sys.tcl`, which is the vendor template's own SDRAM pin block; cross-check
  against `output_files/<rev>.pin`, which records where every signal actually landed post-fit (all
  38 matched across all three). The `.qsf` also *restates* every location assignment after the
  `source` line, because the IDE re-saved the project -- identical values today, but a future
  `sys.tcl` update would be silently overridden.
- **Audit an inherited `.srf`: it suppresses messages worth seeing.** This one came from another
  core, hides 15705 ("Ignored locations or region assignments") which could mask a dropped pin
  assignment, and still references a file that does not exist here.
- **Fitter warnings 176250/176251 ("Ignoring invalid fast I/O register assignments") are almost
  always benign, and the Ignored Assignments panel names exactly which** -- here pins already
  occupied by a DDIO primitive, tied to constants, or driven by a raw PLL output. Do not read them
  as evidence about the SDRAM *data* path: confirm instead by counting register-packing entries,
  which showed 16/16 fast input, output and output-enable registers packed on `SDRAM_DQ`.
- **The SDRAM_CLK phase shift is legitimate but a poor first suspect.** `-3 ns` is the standard
  MiSTer convention, expressed here as the equivalent positive `"8598 ps"` because this `altera_pll`
  rejects negative values. Sweeping it to `0 ps` gave byte-identical results, which was the clue the
  fault was not at the memory interface at all. Revert diagnostic PLL values immediately.
- **`/dev/fb0` is the ARM-side OSD overlay surface, not the FPGA's composited game video.** Do not
  use it as evidence about the core's video pipeline; use the screenshot API, which captures
  scaler-composited output.
- **MiSTer Remote API** (wizzomafizzo/mrext, port 8182) is documented, and its Go source is worth
  reading rather than guessing. `POST /api/launch {"path": "<abs path>"}` writes `load_core <path>`
  to MiSTer's own command-interface device file, the same primitive the menu uses.
  `POST /api/screenshots` returns an effectively empty body regardless of success: poll for a new
  file under `/media/fat/screenshots/<core-shortname>/` instead, often several seconds late.
- **An automated deploy-then-launch script needs an explicit settle gap** that manual multi-step
  testing gets for free. Back-to-back deploy then launch hit a real race (the new `.rbf` not
  reliably flushed) that never appeared when the same steps ran as separate manual calls seconds
  apart; add `sync` after deploy plus a short sleep. Generally, when a race is suspected in an
  automated tool, re-run the exact previously working manual sequence before assuming the deployed
  binary is stale.
- **`plink.exe`/`pscp.exe` are the practical non-interactive SSH/SCP path on Windows** (OpenSSH has
  no clean non-interactive password auth, `sshpass` is usually absent):
  `echo y | plink.exe -ssh -pw <password> user@host "command"`, where `echo y` auto-accepts an unseen
  host-key prompt.
- **MSYS/Git-Bash silently mangles POSIX-looking arguments** such as `/media/fat/...` into Windows
  paths when passed to a non-MSYS program, which made an automated deploy launch a garbage path with
  no error. Prefix invocations with `MSYS_NO_PATHCONV=1`.

### [Seta] Two cores that both boot correctly still fetch different words, so compare as a subsequence with duplicates collapsed

TG68K.C and MAME's 68000 do not prefetch identically, and the difference runs
**both** ways. After the reset vectors the RTL reads `0x000008`, which MAME never
does; MAME reads `0x00013E` twice in a row, which the RTL does once. So neither
access stream is a subsequence of the other, and a matcher that skips on only one
side wedges on the first duplicate.

Both failure modes reported themselves as *"only N of M expected reads happened —
the CPU stalled"*, while a verbose dump showed the CPU executing happily four
hundred accesses deep. The comparison was broken, not the design.

There is a third difference beyond extra and duplicated reads, and it defeats a
subsequence match outright: **reordering**. On `sokonuke`, MAME reads `0x001742`
*before* `0x00173A`, the RTL after — a prefetch landing at a different point in
the stream. MAME's order is then not a subsequence of the RTL's at all, and the
matcher stalls with 150 outstanding reads.

What works: give each expected read a `consumed` flag, and let an incoming RTL
read satisfy any unconsumed entry **within a window** (16 is ample — the observed
displacement is a handful). Collapse a read that repeats the one immediately
before it, address and data both. Every expected read must still occur and the
data must still agree; only the order between *nearby* prefetches is relaxed,
which is an implementation detail of each core rather than a statement about the
program. A real divergence — a branch taken differently — puts the RTL on
addresses MAME never reads, the window empties, and the run still ends with
expected reads outstanding.

Concretely, on this hardware a passing run reports large "extra prefetch" and
"reordered" counts alongside zero mismatches: sokonuke matches 196/197 with 150
RTL-only reads and 101 matched out of order. Those numbers are not warnings.

### [Seta] An unbacked RAM region does not read as garbage, it reads as a failed power-on memory test

`blandia`'s boot writes `0x5555` to `0x300000`, reads it back, and branches on the
result. With that region decoded but not backed by storage it read `0x0000`, the
test failed, and the CPU took its failure path — executing a *different program*
from MAME's, correctly. The bench reported a stall 25 reads in, which looks
exactly like a bus-sequencing bug.

So when a boot diverges, ask what the code was *testing* before assuming the
transport is wrong. And when standing up a CPU bench, back every region the
hardware backs — `blandia_map` has three separate work-RAM blocks plus palette,
two tilemap VRAMs and three sprite arrays, and the boot exercises them before it
does anything visible.

### [Seta] The self-tests walk the whole SRAM chip, not the window the custom chip uses

The Group C boards put a 16 KB SRAM behind the palette (0x?00000-0x?03fff, of
which 0x400-0xfff is the palette) and 32 KB SRAMs behind each VRAM and the
sprite code RAM, of which the X1-012 and X1-001 use the lower 16 KB. The
power-on tests walk the chips: `kamenrid_map` marks 0x700000-0x7003ff,
0x701000-0x703fff, 0x804000-0x807fff, 0x884000-0x887fff and 0xb04000-0xb07fff
"tested". A core that decodes only the windows the chips use passes every
simulation (the benches drive the chips, not the tests) and fails on hardware
with COLOR NG / PALETTE RAM NG / VRAM1 NG on a screen that then never
changes -- or, on Eight Forces, a plain black screen with the CPU running.

The boot-trace sweep cannot see it either: the tests happen after its 400
accesses. Model the chip, not the window (`has_xram`, `has_tails` in
`maincpu.sv`), and treat MAME's `.ram()` lines around a device as the size of
the physical SRAM.

### [Seta] A bidirectional bus captured into four lane registers gets one I/O register and three lottery tickets

Every build after a known-good one took an illegal or line-A instruction in
the power-on RAM test, on RTL changes that were provably inert for those
games. In order, ruled out with a test each: the `.mra` files, the DIP page,
the palette size, the fitter seed (worse, not different), a cold Quartus
`db/`, the PLL and `sys/` and every qsf/sdc (unchanged), the SDC clock groups
and multicycles, the global clock network carrying `clk_sys` (GCLK9 in both
fits). A bisect landed on a six-line palette-index refactor that is
functionally identical to what it replaced.

What made the bisect cheap was an oracle: `scripts/sdram_check.py` reads the
last gfx2 granule the layer-0 engine fetched, with its data, over JTAG, and
compares it against the ROM image. Bad builds: bit 8 of the FIRST beat of the
burst set where the ROM has 0, in roughly half of samples, at every address,
never another bit. Good build: 0 of 24. Sixty seconds per build, against a
game launch and a frame.

The mechanism was in the fit report all along, in a column nobody reads.
`sdram.sv` captured each burst lane straight from `SDRAM_DQ` into its own
register -- `dout[15:0]`, `[31:16]`, `[47:32]`, `[63:48]`. A pin's I/O cell has
ONE input register, so `FAST_INPUT_REGISTER ON -to SDRAM_DQ[*]` (sys.tcl) can
honour one lane per pin: `dout[0..7]` and `dout[24..31]` in every fit, the
other 48 capture flops in the fabric on a pin-to-register path that no
constraint timed, because the port had no input delay. Constrain the port and
STA says it plainly: on the bad fit `SDRAM_DQ[8] -> dout[8]` runs through
10.644 ns of interconnect, worst path in the design; `SDRAM_DQ[8] -> dout[24]`,
the lane that won the I/O register, 0.000 ns. Which lane wins and where the
others land is the fit's choice, so a change anywhere in the design can move
them. That is the seed sensitivity recorded earlier, with its cause.

The fix is structural, not a constraint: capture the bus ONCE, every cycle,
unconditionally -- `dq_in <= SDRAM_DQ` -- which is the only shape the I/O
register accepts, and take the lanes from `dq_in` a cycle later. The pin path
is then fixed by the I/O cell for all sixteen bits and `dq_in -> dout` is an
ordinary path STA times completely. Verified against the command-decoding
chip model by `sim/sdram_tb` (write a granule a word at a time, read it back
as a burst, every lane as written, including back to back), with a negative
control: one cycle early, the bench fails exactly as it must -- lane 0 reads
`zzzz` and every other lane holds its neighbour's word.

Confirmed on hardware: the rebuilt core reads 0 of 24 granules wrong on the
same oracle that gave 14, 11 and 6 of 24 on the three bad builds, and
thunderl, zingzip and stg -- the sets that died in their RAM tests -- boot
and render.

Three things to keep:

* When a functionally inert change breaks hardware and STA is clean, look for
  a path STA is not timing. The fit report's "Packed Register" table and the
  STA "Unconstrained Input Ports" section are where that shows.
* A per-bit oracle beats a per-game one. "bit 8, first beat, half the time"
  named the register; "games black-screen" named nothing.
* `sim/sdram_top_tb` fails 4898 of 5497 read-backs on the unmodified
  controller; its fixture predates the pipelined download and the D/E
  layouts. It cannot judge a controller change. `sim/sdram_tb` can.

### [Seta] An inferred RAM must have a power-of-two depth, or Quartus builds it out of registers

blandia needs 3072 palette entries. Declared as `logic [15:0] pal [0:3071]`
the array was not inferred as an M10K at all -- no altsyncram in the log, no
warning saying so -- and Quartus implemented 3072 sixteen-bit words in logic.
The build died in the fitter:

    Error (170012): Fitter requires 6497 LABs to implement the design,
    but the device contains only 4191 LABs

which reads as "the design grew too big" and is really "one array stopped
being memory". The give-away is the size of the miss: 55% over on a design
that had been at 59%, from a change that added 1024 words.

Rounding the depth up to 4096 infers cleanly and costs eight M10K blocks.
Timing analysis had nothing to say either way, because the design never
reached it.

Check the fit report's RAM-block count after any change to a memory's shape,
not just its total; a count that DROPS while a memory grows is the symptom.

### [Seta] A correct `.mra` DIP block still needs one line in CONF_STR

The switches were right in all 31 `.mra` files and checked against MAME's
`-listxml`, the core decoded them, and every game ran with the correct default
configuration -- and the OSD had no DIP page at all, for the whole project,
because CONF_STR was missing

    "DIP;",

The framework renders that page from the loaded `.mra`'s `<switches>` block;
the line is what asks for it. The switches are DELIVERED either way, as ioctl
index 254, so the defaults take effect and nothing misbehaves. There is no
error, no warning, and no wrong behaviour to notice -- only an absence, and an
absence is exactly what a checker that validates the `.mra` cannot see.

Two checks were both passing and neither covered it: `check_dips.py` compares
the `.mra` against MAME, and the hardware sweep looks at rendered frames.
Nothing looked at the menu. When a feature spans a data file and the core,
verify the end the user touches, not just the end that is easy to diff.

### [Seta] A mirrored work-RAM block reads as a CPU that executes an illegal instruction

`zingzip_map` declares two work-RAM blocks:

    map(0x200000, 0x20ffff).ram();
    map(0x210000, 0x21ffff).ram();   // "RAM (gundhara)"

The core backed both with one 64 KB array and mirrored the second onto the
first. Fifteen of the sixteen sets on that map never touch the second block,
so the alias was invisible; gundhara loads `A6` with 0x218000 in its first ten
instructions.

The symptom was not a wrong value read back. Gundhara's power-on RAM test
(`$8bce`: write -1 / $aaaaaaaa / $55555555 / 0, read each back) walks the
second block a long at a time, and under the mirror it was clearing the FIRST
block as it went -- including 0x20fffa, where the return address pushed by the
`jsr` into the test routine was sitting. The test passed, and then its `rts`
popped a zero. The CPU ran from 0x000000, where a 68000 vector table
disassembles as 256 legal `ori.b #imm,D0` pairs, fell into the exception
handler at 0x400, and halted at the `bra.s *` every handler in the driver ends
with. Probe A froze on a jump to address 0 and that was dismissed as the ring
reading back as zeros; it was the bug.

Two things to take from it. A stack that lives inside a mirrored region turns
an aliasing bug into a wild jump, so the fault appears nowhere near the region
that caused it -- "illegal instruction" was a conclusion drawn from the halt
address, never from a decoded opcode. And a self-test that PASSES is not
evidence the region is right: this one passed precisely because the alias was
self-consistent.

Count the `.ram()` lines in the map, not the bytes the game appears to use.

### [Seta] A region whose base is not aligned to its size must be indexed by subtraction, not by masking

Every region in `maincpu.sv` was indexed by the low address bits, which is
right only when the base's low bits are zero. The palette on every Group C
board is at 0x?00400: entry 0 landed at RAM index 0x200, sprite entries
0x000-0x1ff were never written (black sprites) and each layer read colours
meant for another (right art, wrong colours) -- on every Group C set, on
none of Group A or B, and in no simulation, because the benches write the
palette RAM directly. The one region with an unaligned base was the one that
failed; `pal_base_w` now exports the base and the consumer subtracts.

### [Seta] `bash` on a Windows dev box may be WSL's, which is a different operating system

`scripts/maincpu_sweep.py` spawned `bash` to run `run_sim.sh`. Every one of
thirteen sets failed identically with "no result" — which reads like a systematic
RTL fault — while running the same command by hand passed. The `bash` first on
`PATH` was **WSL's**: a Linux userland with `/mnt/c` instead of `/c`, unable to
execute the Windows ModelSim binaries at all. `shutil.which("bash")` even
reported the Git one; the exec did not use it.

Name the shell explicitly, and refuse WSL rather than emitting a wall of
confusing failures. Related: check the *first* failing command's stderr before
believing a pattern across many runs — one look at it said
"`/c/...vlib.exe`: No such file or directory", which is not something an RTL bug
can cause.

### [Seta] Shell scripts must be pinned to LF in `.gitattributes`, or a `git reset --hard` breaks them

With `core.autocrlf` on, `git reset --hard` rewrote the working tree and gave
every `.sh` file CRLF endings. `set -euo pipefail` then becomes
`set -euo pipefail\r`, and bash rejects it as "invalid option name" — the script
dies on its first line. It survived interactively (that bash tolerated it) and
failed from a wrapper, which is the worst way for it to fail.

`*.sh text eol=lf` in `.gitattributes`, plus the same for `.tcl` and `.lua`.
Note `git add --renormalize` fixes the *index* only; the working files need
rewriting too.

## Tooling and workflow (Quartus, ModelSim, and the shell around them)

- **Working directory does not reliably persist into backgrounded shell commands.** Launch every
  Quartus/ModelSim invocation as `cd <project dir> && <tool>` in one command line, or make it
  cwd-independent; for Tcl-driven tools put the `cd` inside the Tcl script. Symptoms:
  `Error (23018): Tcl Script File ... not found`, or
  `Error (12007): Top-level design entity "Psikyo" is undefined`.
- **`quartus_sta`/`quartus_map`/`quartus_sh` are not on `PATH`**; invoke by full path. Two Quartus
  installs exist on this machine; the project was built with 17.0.2, and using the other means the
  post-fit database will not match.
- **Never run Quartus wrapped in `nohup ... &`.** It detaches, the tool call reports "completed"
  immediately, and the real process runs untracked. Launch the tool directly and let the harness
  background it.
- **Never switch git branches while a Quartus process is reading the source tree.** It silently kills
  the run, leaving a truncated log that looks like a tool crash.
- **Never leave duplicate tool instances running against the same project.** Overlapping
  `quartus_map` runs corrupt the shared log; two `vsim` instances on the same testbench write the
  same output file, and killing one can take the other down (`Fatal: vish lost connection to vsim
  process`). Check before every launch.
- **Sweep for orphaned `vsimk.exe` kernels at the start of any session that runs simulations.**
  Killed ModelSim runs leave kernels spinning at 100% CPU indefinitely, across days -- six were once
  found from the previous day having burned ~90,000 CPU-seconds. Their working set drops to ~42-50 MB
  versus ~180 MB for an active kernel, so size is not a liveness signal, and `tasklist` has no CPU
  column:

  ```powershell
  Get-Process vsim,vsimk | Select-Object Id,ProcessName,CPU,WorkingSet64,StartTime
  ```

  `taskkill //PID <n> //F` fails against these; `Stop-Process -Force` succeeds. Left alone they
  starve every later simulation, which then looks like the new run being pathologically slow.
- **The ModelSim `work` library lives at the repo root**, mapped by each testbench directory's
  `modelsim.ini` via `work = ../../work`. Run `vsim` from the testbench directory so it is picked up.
  After an RTL change recompile only the changed files (`vcom`, `vlog -sv`) rather than rebuilding.
