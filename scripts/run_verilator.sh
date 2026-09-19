#!/usr/bin/env bash
# Build and run one testbench with Verilator. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/run_verilator.sh rom_loader_tb
#
# The bench's sources are listed in sim/<tb>/verilator.files -- unlike
# scripts/run_sim.sh this does not compile all of rtl/, because Verilator
# parses every file it is given and not all vendored code is clean for it.
# Output goes to obj_verilator/<tb>/ (git-ignored). Not build/: that is the
# staged Quartus worktree scripts/build_staged.py owns.
#
# Verilator 5 with --timing runs the same event-driven benches ModelSim does
# (clock generators, @(posedge), fork/join). rom_loader_tb takes 11 s here
# and 4 minutes in ModelSim ASE.
#
# TOOLS: the MSYS2 MinGW64 install (verilator, g++, make, perl). The script
# re-executes itself under that environment when started from Git bash, whose
# PATH has none of them. hwlock does not see Verilator: it never touches JTAG,
# and a Verilator run is not a Quartus/ModelSim process.
set -euo pipefail

TB="${1:?usage: scripts/run_verilator.sh <testbench-dir-name> [plusargs...]}"
shift

MSYS="${MSYS2_ROOT:-/e/msys64}"
if ! command -v verilator >/dev/null 2>&1; then
	[ -x "$MSYS/usr/bin/bash.exe" ] || { echo "MSYS2 not found. Set MSYS2_ROOT."; exit 1; }
	exec env MSYSTEM=MINGW64 CHERE_INVOKING=1 "$MSYS/usr/bin/bash.exe" -lc \
		'cd "$1" && shift && exec scripts/run_verilator.sh "$@"' _ "$(pwd -W 2>/dev/null || pwd)" "$TB" "$@"
fi

[ -d sys ] || { echo "run me from the repository root"; exit 1; }
[ -f "sim/$TB/verilator.files" ] || { echo "no sim/$TB/verilator.files"; exit 1; }

OUT="obj_verilator/$TB"
mkdir -p "$OUT"
# OPT_FAST, OPT_GLOBAL: verilated.mk builds the model and the runtime at -Os
# (Verilator's -O3 is not the C++ build), and MSYS2's g++ 16.2.0-3 cannot link
# -Os code that moves a std::string (undefined basic_string(&&), a C4
# constructor its libstdc++ does not export). -O2 links. As KonamiGX.
verilator --binary --timing -j 0 -O3 -DSIMULATION 	-MAKEFLAGS OPT_FAST=-O2 -MAKEFLAGS OPT_GLOBAL=-O2 \
	-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	--top-module "tb_${TB%_tb}" --Mdir "$OUT" -f "sim/$TB/verilator.files" \
	> "$OUT/build.log" 2>&1 || { grep -E "%Error|error:" "$OUT/build.log" | head -30; exit 1; }

"$OUT/Vtb_${TB%_tb}" "$@"
