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
# Everything is compiled with +define+SIMULATION +initreg=r+0 +initmem=r+0:
# un-reset registers and memories start at zero, as they do on the FPGA,
# rather than X.
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
# plainly exists. scripts/maincpu_sweep.py names the Git bash explicitly;
# this probe also covers a machine where the tools live elsewhere.
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

# T65 (65C02 sub CPU of the downtown.cpp boards), VHDL-93, package first, then
# its plain-port wrapper.
if [ -d rtl/cpu/t65 ]; then
  echo "--- vcom: T65 ---"
  "$MS/vcom.exe" -quiet -93 -work work       rtl/cpu/t65/T65_Pack.vhd       rtl/cpu/t65/T65_ALU.vhd       rtl/cpu/t65/T65_MCode.vhd       rtl/cpu/t65/T65.vhd       rtl/cpu/t65c02.vhd
fi

echo "--- vlog: RTL + testbench ---"
# Compile the whole core RTL every time rather than a per-bench file list.
# It costs seconds and removes an entire class of "the bench passed against a
# stale module" failure.
#
# Deliberate exclusions:
#   screen_rotate*.sv       vendored MiSTer-devel code that references signals
#                           before declaring them. Quartus accepts it, ModelSim
#                           does not (vlog-2730), and it must stay UNTOUCHED --
#                           so it is left out of simulation rather than patched.
#                           It is still in files.qip and still synthesized.
#   *_upstream_reference.sv pristine upstream copies kept beside the vendored
#                           modules purely so local changes can be diffed.
#                           They are not part of any design.
#   cos.sv, lfsr.v, mycore.v  Template_MiSTer's demo core, should a copy
#                           reappear.
RTL=$(find rtl -name '*.sv' \
\
        -not -name 'screen_rotate*.sv' \
        -not -name '*_upstream_reference.sv' \
        -not -name 'cos.sv' | sort)
VLOG=$(find rtl -name '*.v' \
\
        -not -name 'pll*.v' \
        -not -name 'lfsr.v' -not -name 'mycore.v' \
        -not -name '*_upstream_reference.v' | sort)

# shellcheck disable=SC2086
# +initreg/+initmem =r+0 give every un-reset variable and array the power-up
# zero that hardware has and a four-state simulator does not.
# -suppress 7061: fx68k drives parts of its register arrays from more than one
# always_ff (Quartus accepts it; ModelSim refuses by default).
"$MS/vlog.exe" -quiet -sv -work work -suppress 7061 +define+SIMULATION +initreg=r+0 +initmem=r+0 \
    $VLOG $RTL $(ls sim/common/*.sv 2>/dev/null) "sim/$TB"/*.sv

echo "--- vsim: tb_${TB%_tb} ---"
"$MS/vsim.exe" -c -do "run -all; quit -f" "work.tb_${TB%_tb}" "$@" 2>&1 \
  | grep -v "arithmetic operand\|^# Loading"
