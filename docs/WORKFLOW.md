# Working practice

The build, deploy, instrumentation and reference-capture practices this core adopts, carried over
from `Arcade-Psikyo_MiSTer` and `Arcade-Fuuki_MiSTer`. **These are not suggestions.** Each one
exists because its absence cost one of those projects real time, and
[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) records what it cost. The single clearest example: Fuuki
looked at Psikyo's `build_staged.py`, judged it optional, and left it unported — the bill was a
whole session of serialised work, a build that died mid-Fitter with an edit in flight, and a `.qsf`
hand-edit silently reverted by Quartus re-saving the project between builds.

Adopt the whole set at the start, not the parts that seem needed yet.

---

## 1. Build out of a snapshot, never in the tree

`scripts/build_staged.py` snapshots HEAD into a **git worktree at `build/`** (gitignored) and runs
the Quartus flow there. The main tree stays editable for the whole compile, every scrap of Quartus
scratch stays out of the repo root, and the build is exactly HEAD — a dirty tree is refused by
default. The built commit is recorded in `build/BUILT_COMMIT` beside the log.

Three properties matter and must survive the port:

- **Refuses a dirty tree.** "What was in that build?" has to be answerable.
- **Gates on negative slack on every clock**, not on the Fitter's opinion. Quartus reports "Fitter
  was successful" on a design that grossly fails timing; Psikyo shipped an `.rbf` at −8.879 ns
  setup slack with every log line saying "successful".
- **Keeps `output_files/` and the log under `build/`**, so a failed build cannot be mistaken for
  the previous good one.

Keep an in-tree `scripts/build.sh` for the one case that needs it — a compile that must see
uncommitted work — and treat it as the exception.

Do not run Quartus wrapped in `nohup ... &` (it detaches and the run becomes untracked), do not
switch branches while a Quartus process is reading the tree (it silently kills the run), and
invoke `quartus_sta` / `quartus_map` / `quartus_sh` by full path — they are not on `PATH`.

## 2. Deploy only what the build actually produced

`scripts/deploy.py` refuses to copy a `.rbf` unless:

- the build log says the compile succeeded,
- the `.rbf` is **not older than that log**, and
- the timing summary has **no negative slack** on any clock.

It prints every clock's slack before copying anything. This exists because a Psikyo build died
mid-Fitter and the deploy that followed happily verified the *previous* build's stale `.rbf` as
green.

Cores land as `Arcade-Seta_NNNNNNNN.rbf` with an **incrementing number read back from the device**,
so earlier builds stay on the machine as fallbacks. MiSTer launches the highest-numbered one, so
renaming the newest to `.held` drops back one — a one-command bisection across deployed builds.

The `.rbf` must be in `/media/fat/_Arcade/cores/`: `.mra` files resolve `<rbf>` by prefix-matching
filenames there, not by a path relative to the `.mra`. A misplaced `.rbf` gives a silent
flash-and-return-to-menu before ROM loading even begins.

Deploying and launching back-to-back needs an explicit `sync` plus a settle gap; the race does not
appear when the same steps are run manually seconds apart.

## 3. Debug switches live in the OSD, on a hidden page

A full compile took roughly 13 minutes on both prior cores, so **anything that might need changing
during an investigation belongs on a runtime switch, not in the RTL.** LESSONS_LEARNED puts it as
"Add runtime A/B switches when the alternative is a rebuild per bisection step".

The pattern, from `Fuuki.sv`:

```
"P1,Debug;",
"P1-;",
"P1O[40],Tilemap 0,On,Off;",      // per-layer render disable
"P1O[41],Tilemap 1,On,Off;",
"P1O[43],Sprites,On,Off;",
"P1-;",
"P1O[50],Trace overlay,Off,On;",   // trace-to-screen controls
"P1O[52:51],Trace source,...;",
"P1O[56:53],Trace window,0,...,15;",
"P1O[57],Trace mode,First N,Ring (latest);",
"P1O[58],Re-arm capture,A,B;",
"P1O[59],Ring trigger,Off,<event>;",
"P1O[60],Line markers,Off,On;",
```

Rules that come with it:

- **Every debug line carries an `H<n>` prefix** so the whole page hides in release builds, with the
  menumask bit tracking a macro defined only by the instrumented revision. The instrumented build
  shows the page; the release build hides it and compiles the tracer out.
- **Render-disable switches per layer and for sprites** are the cheapest bisection tool there is:
  forcing layers off in the same bitstream isolates a fault to an engine without a rebuild.
- **Make the all-zero configuration the correct one.** A fresh or missing `.CFG` is all zeroes, so
  invert any switch whose enabled state is required, and write the OSD option order to match.
- `scripts/cfg.py` sets bits by **read-modify-write** on `/media/fat/config/<setname>.CFG` (16
  bytes = the 128-bit status word, little-endian, byte N = `status[8N+7:8N]`). Never hand-write a
  `.CFG` — the mistake of zeroing every DIP while setting one debug bit was made twice on Psikyo,
  and it silently enabled Service Mode. The CFG is only read when the core loads.
- Validate bit assignments with <https://agg23.github.io/mister-config/> rather than reasoning
  about ranges. Collisions are silent; the symptom is an option that simply does not respond.
- **`status[0]` is Soft Reset.** Never use it for anything else.

## 4. The JTAG probe

`rtl/debug/issp_probe.sv` — In-System Sources and Probes, read and poked over JTAG with
`quartus_stp -t scripts/read_issp.tcl`.

**Why ISSP and not SignalTap:** SignalTap acquisition is not scriptable in Quartus Prime Lite 17.0
— GUI only. ISSP is (`start_insystem_source_probe`, `read_probe_data`, `write_source_data`), which
is what a headless workflow needs. It also suits the questions a bring-up actually asks, which are
rarely "what does this waveform look like" and usually "did this ever happen, and how often".

Keep the wrapper generic and build the probe bus in the module that owns the signals, so the
instrumentation sits next to what it instruments and the wrapper stays stable. The Tcl decoder must
be kept in step with the bit layout — say so in a comment at both ends.

The **source** direction is as valuable as the probe direction: pausing the CPU, selecting a memory
page to dump, re-arming a capture and stepping the SDRAM clock phase are all runtime pokes that
would otherwise be rebuilds. One trap, paid for on Fuuki: `write_source_data -value` takes a
**binary string**, and a decimal one is silently rejected while still printing "source set to N".
Pass `-value_in_hex`, and read every source back after writing it.

## 5. Counters and the trace ring

`rtl/debug/debug_counter.sv` and `rtl/debug/debug_tracer.sv`, both carried over with their design
rationale in the file headers. The properties are the point:

- **No reset port at all.** Quartus powers registers to zero at configuration, so a counter with no
  reset shows what genuinely happened since the FPGA was programmed. Two Psikyo measurements read
  `0x000000` and were reported as findings before anyone noticed the counters were cleared by the
  reset under investigation — which MiSTer asserts for the entire ROM download.
- **Counters saturate rather than wrap.** A wrapped 3 could mean "three times" or "65,539 times",
  and those lead to opposite conclusions.
- **Every "bad event" counter is paired with a "total events" counter.** A zero otherwise cannot
  distinguish "did not happen" from "was never allowed to count".
- The tracer takes an explicit one-cycle `cap_stb` from the caller, so the capture point is a
  deliberate decision — and it must be proven in simulation against a known-good run before its
  hardware output is trusted. If a new probe reports a fault on a known-good setup, the probe is
  the fault.
- **`ctl_window` walks the capture across a long boot sequence from the OSD with no rebuild.** Make
  the step size odd (`window * 8191`) so it cannot alias with a power-of-two period; a
  `window * 256` step once returned byte-identical captures for three different windows, equally
  consistent with a CPU resetting every 256 reads and a read path aliasing every 256 words.
- **Capture the full address.** Packing only `addr[7:0]` into a pixel made a genuine linear ROM
  sweep look exactly like a read path dropping its high bits.

## 6. Reading the trace out through the video output

The trace ring is read back as pixels on the screen and decoded from a screenshot
(`scripts/decode_debug_screenshot.py`, `scripts/tracer_readout.py`). Two things must be right:

- **Force the gamma LUT off under the overlay.** The framework applies the user's gamma curve to
  the core's RGB before the scaler and before screenshots. Fuuki's trace values came back remapped
  (`0x40 → 0x38`, `0x02 → 0x01`), which read exactly like SDRAM data-lane corruption and survived
  an `SDRAM_CLK` phase change. Clear `gamma_bus[19]` whenever the overlay is on, leaving the user's
  display settings alone.
- **Draw each value and its bitwise inverse in alternating bands.** The pair must XOR to
  `0xFFFFFF` whatever the memory holds, so any transform anywhere in the capture path is *detected*
  rather than read as data.

`/dev/fb0` is the ARM-side OSD overlay surface, not the FPGA's composited video — never use it as
evidence about the core's video pipeline. Use the screenshot API, and poll for a new file under
`/media/fat/screenshots/<core-shortname>/` because `POST /api/screenshots` returns an effectively
empty body regardless of success.

VGA-colour-override builds remain the crudest and most reliable instrument for a yes/no question:
override `VGA_R/G/B` with a solid colour gated by an internal signal and take one screenshot.

## 7. Reading memory back out of a running core

`scripts/memdump.py` reads SDRAM, VRAM, palette, sprite RAM, video registers and work RAM back out
of the running core over JTAG with the CPU paused, optionally diffing against an expected image.
`scripts/boot_trace.py` captures the first N CPU accesses, or the N before the first exception, or
the N before a JTAG pause, and compares against MAME.

This is the instrument that settled several Fuuki bugs simulation could not see — work RAM indexed
one bit too narrowly, an arbiter still packing 25-bit addresses after a widening. Build it early;
its value is that it answers hardware questions directly instead of arguing from simulation.

`scripts/wait_scene.py` polls screenshots until the frame matches a reference crop and then holds
the CPU paused there, so a dump is one instant of one chosen scene rather than whatever happened to
be on screen.

`scripts/sweep.py` launches every deployed set in turn and tabulates the probe side by side —
one black screen is consistent with several different faults, and comparing sets separates them.
`scripts/soak.py` runs a game for N seconds sampling the probe and a screenshot periodically, and
flags a hang.

## 8. MAME as a reference generator

Reference data is **captured, not hand-made**, so any claim about the hardware can be re-checked
cheaply and the same way by anyone else with a MAME install and the ROM sets. `scripts/mame_capture.py`
drives MAME headlessly through `scripts/mame/*.lua` and captures video regions, screenshots and
register write logs.

What this makes provable offline, before hardware exists:

| Reference | Validates |
|---|---|
| Boot program trace (PC / bus cycles) | The CPU spike end to end — diffed against the ModelSim trace rather than eyeballing "it looks like it is running". Catches wrong interleave, wrong reset vector, wrong IRQ timing and wrong DTACK behaviour in one test. |
| Program ROM disassembly at known offsets | The `.mra` interleave, with no build and no hardware |
| VRAM / vregs / spriteram dumps at a known frame | Tilemap and sprite engines: preload the dump, render one frame in sim, compare against MAME's output for that frame |
| Palette RAM dump | The colour path |

Traps, all paid for on Fuuki:

- **Keep every Lua subscription in a variable that outlives the call.** `add_machine_frame_notifier`
  and `install_write_tap` return subscription objects; dropping the return value lets the GC reclaim
  them and the callback **silently stops firing**. A capture at frame 120 worked and the identical
  capture at frame 1100 produced no files, no error, and exit status 0.
- **Check `mame.ini` for `debug 1` and pass `-nodebug` explicitly.** Otherwise every launch halts in
  the debugger while the autoboot script still loads and still prints, so it looks like it is
  working while the machine never advances a frame. Same for `window 1` when headless.
- **Wrap the Lua in an error-catching runner** that writes failures to a file the Python side reads
  back — otherwise a broken script fails as a modal dialog that is invisible headlessly.
- **Probe which Lua API this MAME build actually provides** rather than writing against the current
  online docs.
- **Read dumps through the CPU's own address space** (`spaces["program"]:read_u16(addr)`), not out
  of MAME's internal structures — that returns what the CPU would read, device handlers included,
  which is the thing the RTL has to match.
- Snapshots work under `-video none` and land one directory deeper than the one given; search
  recursively.

Two cautions on what a comparison proves: a hardware-vs-image comparison **cannot detect a wrong
image** when both sides were built from the same byte-order assumption, and any test using uniform
or all-zero content is invariant under byte order and cannot catch endianness bugs at all. Use real
content.

## 9. Simulation

`scripts/run_sim.sh` compiles the RTL and runs one testbench from the repository root, and
**rebuilds the `work` library every run**. That last part is not tidiness: a ModelSim compile killed
by a tool timeout leaves `work/_lock`, on which every later `vlog`/`vcom` waits silently — three
Fuuki "silent chip" investigations were a lock. A bench that prints nothing has usually not run.

Vendored jotego cores need `+define+SIMULATION +initreg=r+0 +initmem=r+0`: their un-reset pipelines
are X in a four-state simulator and zero in hardware, and X through an envelope generator is a chip
that accepts every register write and never makes a sound.

Sweep for orphaned `vsimk.exe` kernels at the start of any session that runs simulations — killed
runs leave them spinning at 100% CPU indefinitely, and their working set is not a liveness signal:

```powershell
Get-Process vsim,vsimk | Select-Object Id,ProcessName,CPU,WorkingSet64,StartTime
```

`taskkill //PID <n> //F` fails against these; `Stop-Process -Force` succeeds.

The rest of testbench discipline is in LESSONS_LEARNED's "Testbench discipline" section — read it
before writing a new bench rather than after one gives a confident wrong answer.

## 10. `.mra` generation

Generate every `.mra` from a script (`scripts/build_mra.py`), not by hand:

- Each region is built from the driver's `ROM_START` semantics, and **the map digits are found by
  testing against that**, not derived by reasoning. Every interleave Psikyo derived by reasoning
  was wrong.
- The finished file is **re-read and compared byte-for-byte** against an image built directly from
  the driver's `ROM_START` (`scripts/mra.py` reimplements what mra-tools-c does).
- SDRAM offsets come from the RTL's own address map, never duplicated into the generator.
- Parents land in `releases/`, clones in `releases/_alternatives/`.
- Every `.mra` is gated on an **XML well-formedness check** before deploy. A stray `<` inside a
  prematurely-closed comment once gave a black screen whose every symptom pointed at the RTL, with
  the only clue an on-screen "XML parse" message. MiSTer's parser is more lenient than a strict
  one, so "it loaded before" is not evidence.
- Pad every game to a fixed button count with `-` so Start, Coin and Pause always land on the same
  joystick bits whatever the game's real button count — that is what lets the pause logic hard-code
  a bit position. The CONF_STR `J1` list **must** agree with the `.mra` `<buttons>` positions,
  because the `.mra` is what actually assigns them.
- When testing an `.mra` change, **force a genuine reload** by bouncing through `menu.rbf` — a
  relaunch reuses the cached ROM and produces a byte-identical trace.

## 11. Branching and history

`develop` is the working branch and carries granular commits. At intervals that work is **squashed
onto `master`**, which is what gets pushed. `master` is a curated history of meaningful milestones,
not a replay of every bisection step.

ROMs live in `roms/` and are **gitignored** — no ROM data is ever committed.

## Script inventory to port

From `D:\Arcade-Fuuki_MiSTer\scripts\` (the more evolved set) and `E:\Arcade-Psikyo_MiSTer\scripts\`:

| script | why |
|---|---|
| `build_staged.py` | worktree build at `build/`, refuses dirty tree, gates on slack |
| `deploy.py` | slack-gated deploy, incrementing `.rbf` numbering, fallbacks on device |
| `run_sim.sh` | one testbench, fresh `work` library every run |
| `cfg.py` | read-modify-write of the per-core `.CFG` status word |
| `read_issp.tcl` | read the probe / write the source bus over JTAG |
| `report_worst_paths.tcl`, `sta_failing_paths.tcl` | worst setup paths from the compiled database |
| `mame_capture.py` + `mame/*.lua` | headless MAME reference capture |
| `parse_mame_trace.py`, `boot_trace.py` | MAME boot trace → expected fetch list, and the on-hardware counterpart |
| `build_mra.py`, `mra.py`, `validate_mra.py` | generate, verify byte-for-byte, and well-formedness-check every `.mra` |
| `decode_gfx.py`, `gfx_sheet.py` | decode tiles straight from the ROM zip |
| `memdump.py` | read any CPU-visible memory out of a running core |
| `decode_debug_screenshot.py`, `tracer_readout.py` | trace ring readout through the video path |
| `hw.py`, `wait_scene.py`, `sweep.py`, `soak.py` | launch, hold a chosen scene, compare sets, detect hangs |
| `sdram_pattern_test.py`, `sdram_dump_check.py` | known-pattern SDRAM test through the real download path |

And from `rtl/debug/`: `issp_probe.sv`, `debug_tracer.sv`, `debug_counter.sv`, plus
`pause_control.sv`.

Port them with their header comments intact. The rationale in those headers is the reason they have
the shape they do, and a stripped copy invites someone to add the reset port back.
