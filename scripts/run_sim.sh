#!/usr/bin/env bash
# Compile and run one testbench. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/run_sim.sh maincpu_tb
#     scripts/run_sim.sh video_tb +LAYERS=2      # extra args go to vsim
#
# $readmemh paths resolve against the simulator's CWD, not the testbench
# file, so every bench in this project is written to be run from the repo
# root and this script enforces it. A wrong CWD leaves ROMs all zeroes and
# fails every check at once, which reads exactly like an RTL regression --
# grep the log for `readmem` first (LESSONS_LEARNED, "Testbench discipline").
#
# PORTED FROM THE FUUKI CORE. One thing differs and the difference is
# deliberate:
#   * Fuuki compiled TG68K.C and T80 with vcom. This core vendors TG68K.C but
#     NOT T80 -- no in-scope Seta board has a sound CPU, the X1-010 is driven
#     directly by the 68000. So the vcom step below covers TG68K only. It must
#     stay ABOVE the vlog step: ModelSim needs TG68K_Pack compiled first, and
#     the package before the units that use it.
#   * Fuuki compiled the jotego sound cores with
#     `+define+SIMULATION +initreg=r+0 +initmem=r+0`, because their un-reset
#     pipelines are X in a four-state simulator and zero in hardware, and X
#     through an envelope generator is a chip that takes every register write
#     and never makes a sound. This core's X1-010 is written here, so it does
#     not need that -- but the flags are kept below, applied to everything,
#     because they only ever make simulation match hardware more closely.
set -euo pipefail

TB="${1:?usage: scripts/run_sim.sh <testbench-dir-name> [vsim args...]}"
shift
# TOOL PATH RESOLUTION.
#
# Probed rather than asserted, because "bash" on this machine is ambiguous:
# PATH also contains WSL's bash, which is a different OS with /mnt/c instead of
# /c and cannot run Windows .exe tools at all. A Python wrapper that spawns
# plain `bash` gets THAT one, so a script passes when you run it by hand and
# fails from the wrapper, reporting "No such file or directory" for a path that
# plainly exists. scripts/maincpu_sweep.py now names the Git bash explicitly;
# this probe is the second line of defence, and covers a machine where the
# tools simply live elsewhere.
MS=""
for _c in "${MODELSIM_BIN:-}"           /c/intelFPGA_lite/17.0/modelsim_ase/win32aloem           C:/intelFPGA_lite/17.0/modelsim_ase/win32aloem           /e/msys64/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem ; do
	[ -n "$_c" ] && [ -x "$_c/vlib.exe" ] && MS="$_c" && break
done
[ -n "$MS" ] || { echo "ModelSim not found. Set MODELSIM_BIN."; exit 1; }

[ -d sys ] || { echo "run me from the repository root"; exit 1; }
[ -d "sim/$TB" ] || { echo "no such testbench: sim/$TB"; exit 1; }

# Orphaned kernels from killed runs spin at 100% CPU indefinitely and make
# every later simulation look pathologically slow. Sweep before launching.
if command -v powershell.exe >/dev/null 2>&1; then
  n=$(powershell.exe -NoProfile -Command \
      "(Get-Process vsim,vsimk -ErrorAction SilentlyContinue).Count" 2>/dev/null | tr -d '\r' || echo 0)
  [ "${n:-0}" != "0" ] && echo "WARNING: $n vsim/vsimk process(es) already running."
fi

# A FRESH library every run. Everything is recompiled anyway, and a run that
# dies mid-compile (a tool timeout, a crash) leaves work/_lock behind, on
# which every later vlog/vcom waits silently and forever -- which looked
# exactly like a bench that printed nothing.
#
# The corollary: ONE RUN AT A TIME. Two concurrent invocations delete and
# rebuild the same library underneath each other, and the loser prints
# nothing at all.
rm -rf work
"$MS/vlib.exe" work

# TG68K.C is VHDL-2008 for the kernel and its ALU; the package first.
# Order matters -- ModelSim resolves the package at compile time, not at
# elaboration.
if [ -d rtl/cpu/tg68k ]; then
  echo "--- vcom: TG68K.C ---"
  "$MS/vcom.exe" -quiet -2008 -work work       rtl/cpu/tg68k/TG68K_Pack.vhd       rtl/cpu/tg68k/TG68K_ALU.vhd       rtl/cpu/tg68k/TG68KdotC_Kernel.vhd
  # TG68K.vhd itself is DELIBERATELY not compiled: it is an async-68000-bus
  # adapter that assumes CLK is the CPU clock, and this core instantiates the
  # kernel directly instead. See rtl/cpu/tg68k/PROVENANCE.md.
fi

echo "--- vlog: RTL + testbench ---"
# Compile the whole core RTL every time rather than a per-bench file list.
# It costs seconds and removes an entire class of "the bench passed against a
# stale module" failure.
#
# Deliberate exclusions:
#   synth_check/            a Quartus-only harness with its own top level
#   screen_rotate*.sv       vendored MiSTer-devel code that references signals
#                           before declaring them. Quartus accepts it, ModelSim
#                           does not (vlog-2730), and it must stay UNTOUCHED --
#                           so it is left out of simulation rather than patched.
#                           It is still in files.qip and still synthesized.
#   *_upstream_reference.sv pristine upstream copies kept beside the vendored
#                           modules purely so local changes can be diffed.
#                           They are not part of any design.
#   cos.sv, lfsr.v, mycore.v  Template_MiSTer's demo core. lfsr.v uses the
#                           Altera `lcell` primitive and references a parameter
#                           before declaring it -- Quartus accepts both,
#                           ModelSim rejects them. They are still instantiated
#                           by the unmodified Seta.sv and go when the real top
#                           level is written; until then they are not simulated.
RTL=$(find rtl -name '*.sv' \
        -not -path '*/synth_check/*' \
        -not -name 'screen_rotate*.sv' \
        -not -name '*_upstream_reference.sv' \
        -not -name 'cos.sv' | sort)
VLOG=$(find rtl -name '*.v' \
        -not -path '*/synth_check/*' \
        -not -name 'pll*.v' \
        -not -name 'lfsr.v' -not -name 'mycore.v' \
        -not -name '*_upstream_reference.v' | sort)

# shellcheck disable=SC2086
# +initreg/+initmem =r+0 give every un-reset variable and array the power-up
# zero that hardware has and a four-state simulator does not.
"$MS/vlog.exe" -quiet -sv -work work +define+SIMULATION +initreg=r+0 +initmem=r+0 \
    $VLOG $RTL $(ls sim/common/*.sv 2>/dev/null) "sim/$TB"/*.sv

echo "--- vsim: tb_${TB%_tb} ---"
"$MS/vsim.exe" -c -do "run -all; quit -f" "work.tb_${TB%_tb}" "$@" 2>&1 \
  | grep -v "arithmetic operand\|^# Loading"
