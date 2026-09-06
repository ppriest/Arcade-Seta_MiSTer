# Tooling

Capture and verification scripts for the Seta core, ported from
`Arcade-Fuuki_MiSTer` (which had ported much of it from `Arcade-Psikyo_MiSTer`).
The practices these implement, and why each exists, are in
[`docs/WORKFLOW.md`](../docs/WORKFLOW.md).

Reference data is **captured, not hand-made**, so any claim about the hardware
can be re-checked cheaply — and re-checked the same way by anyone else with a
MAME install and the ROM sets.

## Status

Each script is marked with what it needs. Nothing here silently half-works: a
script that cannot do its job on this core either refuses to run or says so in
its own `--help` and docstring.

| state | meaning |
| - | - |
| **works** | ported, adapted to Seta, and exercised against real ROM sets |
| **needs RTL** | mechanics carry over, but it talks to a probe, trace ring or testbench that does not exist yet. Carries a STATUS banner. Treat empty output as unexplained, not as an answer |
| **refuses** | still holds Fuuki's tables and would produce confident wrong output. Exits immediately |

## Build and deploy

| script | state | purpose |
| - | - | - |
| `build_staged.py` | works | compile HEAD in a git worktree at `build/`, so the tree is free during the run and Quartus scratch stays out of the repo root. Refuses a dirty tree, records the built commit, gates on negative slack on **every** clock. **Use this**; `build.sh` builds in-tree |
| `build.sh` | works | in-tree compile for the case that must see uncommitted work. Fails on negative slack rather than on the Fitter's opinion. `--map` is a fast syntax-only check |
| `deploy.py` | works | copy the `.rbf` and `.mra` files to a MiSTer. Prints every clock's slack first and refuses a bitstream the build did not actually produce. Cores land as `Arcade-Seta_NNNNNNNN.rbf`, numbered from 10000001 and read back from the device, so earlier builds stay as fallbacks — rename the newest to `.held` to drop back one |
| `report_worst_paths.tcl` | works | `quartus_sta -t scripts/report_worst_paths.tcl Seta` — the 15 worst `clk_sys` setup paths from the compiled database, no recompile |
| `run_sim.sh` | works | compile the RTL and run one testbench, from the repository root. Rebuilds the `work` library every run (a killed run leaves `work/_lock`, on which every later `vlog` waits silently). Adapted: a vcom step for TG68K.C (kernel only, not the bus wrapper), no T80, no jotego cores |
| `cfg.py` | works\* | set OSD status bits in a per-core `.CFG` by read-modify-write, so untouched bits survive. \*The bit map is PROVISIONAL until `Seta.sv` has a CONF_STR |
| `read_issp.tcl` | works\* | read the JTAG probe / write its source bus. \*The field table is PROVISIONAL — replace it from the real probe bus when one exists |

## MAME as a reference generator

| script | state | purpose |
| - | - | - |
| `mame_capture.py` | works | drive MAME headlessly and capture a reference frame: every region the video hardware reads, the screenshot MAME rendered from that exact state, and optionally a write log. **Holds the per-game region map** — 35 sets across 13 families, each transcribed from one `*_map` function in `seta.cpp`. An unlisted game fails loudly rather than dumping zeros from a plausible wrong address |
| `romset.py` | works | resolve a ROM inside a MERGED romset zip, by CRC32 from the driver's ROM_START. Both the lookup and an integrity check |
| `extract_romstart.py` | works | read maincpu ROM_START records straight from `seta.cpp` and emit `build_maincpu_hex.py`'s table. 43 in-scope sets parse with nothing unrecognised |
| `mame/capture.lua` | works | the Lua half. Holds no game knowledge; regions and tap ranges arrive in environment variables |
| `mame/run.lua` | works | autoboot wrapper that catches Lua syntax and runtime errors and writes them to a file the Python runner reads back — otherwise a broken script fails as a modal dialog that is invisible headlessly |
| `mame/probe.lua` | works | report which Lua API calls this MAME build actually provides, so the capture scripts are written against what exists rather than against the current online docs |
| `mame/boottrace.lua` | works | log the first N main-CPU bus accesses from reset, via read/write taps on the whole address space. `mame_capture.py --boot-trace N` drives it, and it needs no region map so it works for any set |
| `check_boot_trace.py` | works | check a boot trace against the image `build_maincpu_hex.py` assembles offline. Two paths sharing no code — ours from ROM_START, MAME's from its own loader and CPU |
| `prep_maincpu_tb.py` | works | build `sim/maincpu_tb`'s fixtures: the program image (packed the way `sdram_narrow_bridge` presents it, so the bench exercises the byte swap) and the expected fetch list |
| `maincpu_sweep.py` | works | boot one game from every memory-map family through `maincpu.sv` against MAME, at several ROM latencies. The point is the DECODE: a wrong base address shows up here as a divergence at a named address rather than as a black screen much later |
| `parse_mame_trace.py` | superseded | turns MAME's *debugger* trace into an expected fetch list. Kept from Fuuki, but `boottrace.lua` is the better source here: MAME's `trace` emits one line per instruction START, so reconstructing the actual bus accesses means guessing each instruction's length from the gap to the next PC — which its own docstring admits cannot work across a branch. A read tap records the accesses directly |

Two traps this MAME install carries, both already handled: `mame.ini` sets
`debug 1` and `window 1`, so every launch would otherwise halt in the debugger
while an autoboot script still appears to run. `mame_capture.py` passes
`-nodebug`, `-video none` and `-nowindow` explicitly.

## ROM and graphics analysis (no hardware, no build)

| script | state | purpose |
| - | - | - |
| `build_maincpu_hex.py` | works | build a 68000 program image from a ROM set and score its reset vectors. Ten sets transcribed from `ROM_START`, covering all three forms `seta.cpp` uses: `load16_byte`, `ROM_CONTINUE` and `load16_wswap` |
| `x1_010_model.py` | works | a reference model of the X1-010, transcribed from MAME. `--selftest` exercises both modes with no ROM set needed. The value is that it agrees with MAME by construction, so a disagreement with the RTL is the RTL's |
| `prep_x1_010_tb.py` | works | build `sim/x1_010_tb`'s fixtures from that model, synthetic or from a captured register dump |
| `decode_gfx.py` | works | decode graphics tiles to ASCII straight from the ROM zip. Implements MAME's `gfx_layout` semantics directly, with the four Seta layouts transcribed rather than derived; `--interleave 24` implements the driver-local `ROM_LOAD24_*` grouping the 6bpp layers use |
| `gfx_sheet.py` | works | render tiles to a PNG sheet, false-coloured by pen index. Imports its layouts from `decode_gfx.py` so the two cannot drift |
| `mra.py` | works | build the SDRAM image an `.mra` describes, the way mra-tools-c would, so an `.mra` can be checked byte-for-byte against an image built from `ROM_START` |
| `build_mra.py` | **refuses** | generate and prove every `.mra`. Still holds Fuuki's board tables; needs `rtl/memory/seta_sdram_top.sv` for the region offsets, which is the authority and must never be duplicated here |

### What has actually been checked

- **All 43 in-scope sets** (parents and clones), against the real ROM sets:
  every one yields an even reset PC inside the image, beginning on a canonical
  68000 boot instruction — `46FC 2700` (`move #$2700,SR`), `007C 0700`
  (`ori #$700,SR`) or `4E70` (`RESET`).
- **Those images against MAME's own fetches**, per set, with
  `check_boot_trace.py`. Every word MAME's CPU reads from the program region
  must equal the same address in our image. This is the interleave check
  LESSONS_LEARNED asks for, done mechanically over hundreds of words rather
  than by eye over a handful of instructions — and by a path that shares no
  code with the one that built the image.
- **Every game's reset SP against its family's work RAM.** This is the check
  that has caught the most: five wrong region entries in one pass
  (`atehate`'s RAM is 1 MB not 64 KB; `blockcar` and `umanclub` are not
  `thunderl`'s map; `zingzip_map` declares three work RAM blocks and
  `wrofaero`'s stack is in the third), plus `drgnunit`'s two blocks and
  `daiohp`/`blandiap` not sharing their parents' maps. 35/35 clean now.
- **The `gfx_layout` transcriptions**, two ways. Structurally, each maps
  `w*h*planes` pixel-planes onto exactly that many distinct bit offsets
  covering `[0, charincrement)` with no gaps or duplicates. And against real
  data: `rezon`'s 4bpp layer and `gundhara`'s `RGN_FRAC(1,2)` sprites both
  decode the same 16-pen colour-ramp test tile, from different ROMs through
  independently transcribed rules.
- **The 24-bit interleave**: `gundhara`'s `bpgh-009` + `bpgh-010` reproduce the
  declared `ROM_REGION(0x180000)` exactly and decode as real artwork.
- **The capture pipeline end to end** on `thunderl`: every region non-zero, a
  screenshot, and 459 X1-010 register writes logged with their scanline.
- **Every family's work RAM contains its reset stack pointer.** This caught a
  real error — `drgnunit_map` has two work RAM regions and the first pass
  captured only the one the stack is *not* in.

## Simulations

| bench | what it proves |
| - | - |
| `sim/tg68k_smoke_tb` | the vendored TG68K kernel elaborates and runs: reset vectors in order, real instructions executed, no X on the bus |
| `sim/maincpu_tb` | `maincpu.sv` boots a real program ROM and matches MAME's own fetches, against a behavioural ROM with a swept latency. 35/35 mapped sets |
| `sim/maincpu_sdram_tb` | the same boot through the PRODUCTION transport — real download path, arbiter, phy, controller and a command-decoding chip model. The latency sweep above is a proxy for this, not a substitute |
| `sim/x1_010_tb` | the X1-010 against `scripts/x1_010_model.py`, sample for sample. Both modes, envelopes, one-shot, divider; key-on edge semantics checked directly |

`sim/common/` holds models shared between benches (currently the SDRAM chip
model); `run_sim.sh` compiles it alongside the selected testbench.

## Hardware debugging (needs RTL)

| script | state | purpose |
| - | - | - |
| `memdump.py` | needs RTL | read SDRAM / VRAM / palette / sprite RAM / work RAM back from a running core over JTAG, CPU paused |
| `boot_trace.py` | needs RTL | capture the first N CPU accesses, or the N before an exception, and compare against MAME |
| `tracer_readout.py` | needs RTL | read the trace ring back through the screenshot path, as inverted bands whose pairs must XOR to all-ones, so a transform anywhere in the capture path is detected rather than read as data |
| `decode_debug_screenshot.py` | needs RTL | read exact 24-bit values out of a trace-overlay screenshot, one per scanline |
| `sdram_dump_check.py` | needs RTL | diff an SDRAM read-back against the program ROM, keyed by index so dropped rows cannot mis-attribute a word |
| `sdram_pattern_test.py` | needs RTL | known-pattern SDRAM write/read test through the real download path, so address-, data- and timing-dependent faults can be told apart |
| `phase_sweep.py` | needs RTL | walk the SDRAM_CLK phase at runtime and report errors against phase. Already stale on Fuuki — restore its probe field before use |
| `hw.py` | needs RTL | launch a game via MiSTer Remote's API (bouncing through `menu.rbf` so the FPGA is really reprogrammed) and pull screenshots |
| `wait_scene.py` | needs RTL | poll screenshots until the frame matches a reference crop, then hold the CPU paused there, so a dump is one instant of one chosen scene |
| `sweep.py` | needs RTL | launch every deployed set in turn and tabulate the probe side by side — one black screen is consistent with several faults, and comparing sets separates them |
| `soak.py` | needs RTL | run a game and sample the probe and a screenshot periodically; flag a hang |
| `prep_tilemap_tb.py`, `prep_sound_tb.py`, `tilemap_png.py`, `video_png.py` | needs RTL | testbench fixtures and renderers, for benches not yet written |

## Environment

- MAME lives wherever `MAME_DIR` points (default `C:\Emulation\Emulators\MAME`).
- `roms/` holds the 30 in-scope parent archives, gitignored; no ROM data is
  ever committed. The collection is **merged** — each parent zip also carries
  its clones' differing ROMs in named subdirectories, so all 43 in-scope sets
  (parents and clones) are assembled from those 30 files.
- `mame_capture.py` passes `-rompath` with `roms/` first and `mame.ini`'s own
  entries appended, so a capture does not depend on an external drive but a
  set that was not copied still resolves.
- Quartus 17.0.2. `quartus_sta` / `quartus_map` / `quartus_sh` are not on
  `PATH` — invoke by full path, and never wrap Quartus in `nohup ... &`.
- MiSTer connection settings come from `mister.env` (gitignored).

## A note for anyone automating MAME

Keep every Lua subscription — frame notifiers and write taps alike — in a
variable that outlives the call, or the garbage collector reclaims it and the
callback silently stops firing.

And **wrap every tap callback in `pcall`, with a hits counter beside a logged
counter**. An error inside a tap is swallowed: the first run of `capture.lua`
here produced 459 tap hits and zero logged lines, with no error anywhere, and
the obvious reading was that the game had not written to that range. See
LESSONS_LEARNED's `[Seta]` entries.
