derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# fx68k multicycle, with its audit.
#
# fx68k advances only on enPhi1 / enPhi2, which maincpu.sv generates cpu_half
# clk apart: 3 (16 MHz) or 6 (8 MHz), never closer (a held phi2 is later, not
# sooner). fx68k is written for enables on consecutive clocks, so its internal
# paths are single-cycle designs, and its README gives close to 40 MHz; at
# 96 MHz it needs this constraint.
#
# AUDIT (rtl/cpu/fx68k/fx68k.sv, fx68kAlu.sv): every always_ff that carries
# data assigns under enPhi1, enPhi2 or enT1..enT4 (themselves enPhi1/enPhi2
# qualified by tState), or under pwrUp / extReset, which are held for many
# clocks. The exceptions are the microcode and nanocode ROM output registers
# (uRom, nanoRom: `microOutput <= uRam[microAddr]` every clock). Their address
# latches on enT1 and microLatch / nanoLatch take the output on enT3, two
# phases (at least 6 clk) later, so the ROM register holds the settled value
# for at least 3 clk before it is used: 3 cycles is safe through it too.
#
# Scoped to fx68k-internal paths. The bus signals into and out of maincpu.sv
# (AS, strobes, eab, DTACK, iEdb, IPL) cross at full clk_sys.
# ---------------------------------------------------------------------------
set fx68k [get_registers {*maincpu:u_cpu|fx68k:u_cpu|*}]
set_multicycle_path -setup -from $fx68k -to $fx68k 3
set_multicycle_path -hold  -from $fx68k -to $fx68k 2

# ---------------------------------------------------------------------------
# The game selector is STATIC. It is the .mra mod byte, latched from ioctl
# index 1 during the ROM download and never changed while the game runs --
# and the download completes before the core comes out of reset.
#
# It has to be said, because rtl/seta_board_cfg.sv fans it out into every
# per-game constant and maincpu.sv's whole address decode.
# ---------------------------------------------------------------------------
set_false_path -from [get_registers {*mod_byte*}]

# ---------------------------------------------------------------------------
# SDRAM I/O TIMING -- so that STA can SEE the data-capture path at all.
#
# Until this block existed every SDRAM pin was "No input delay ... found" in
# the STA report: the sdram.sv capture registers are packed into the I/O
# cells (FAST_INPUT_REGISTER, sys.tcl), which fixes their location, but the
# pin-to-register setup/hold against the memory's clock was never checked.
# The capture edge at those IOEs moves with whatever global clock network the
# Fitter routes clk_sys over, and that choice changes from build to build.
# Measured consequence: a functionally inert RTL change produced a build on
# which bit 8 of the FIRST beat of every SDRAM read burst read 1 where the
# ROM held 0, in roughly half of samples (scripts/sdram_check.py), while STA
# reported every clock positive. The good and bad builds differed in nothing
# STA was looking at.
#
# CLOCKS. clk_sys is the main PLL's counter 0 (96 MHz). SDRAM_CLK is counter
# 1, the same 96 MHz shifted 180 degrees, wired straight to the pin. The
# memory launches and samples on SDRAM_CLK; the FPGA does both on clk_sys.
#
# NUMBERS ARE ASSUMED, NOT MEASURED, and are variables for that reason. They
# are MT48LC16M16A2 -7E values at CL=2 (tAC 6.0, tOH 2.7, tDS 1.5, tDH 0.8 ns)
# plus a nominal board/pin allowance, because three attempts to fetch the
# datasheet failed. The DE10-nano SDRAM module's actual part and speed grade
# are not recorded anywhere in this repository. Calibrate from the datasheet
# before treating a negative slack here as a hard failure -- until then this
# block is an INSTRUMENT: run quartus_sta on two fits and compare the slack
# on SDRAM_DQ[*], which is what it was written for.
# ---------------------------------------------------------------------------
set sdram_tAC   6.0    ;# memory CLK -> data valid, max
set sdram_tOH   2.7    ;# memory CLK -> data hold, min
set sdram_tDS   1.5    ;# memory input setup
set sdram_tDH   0.8    ;# memory input hold
set sdram_board 0.5    ;# trace + pin, max, each direction
set sdram_board_min 0.1

set sdram_pll_clk [get_clocks {*pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name sdram_clk_pin -source [get_pins -compatibility_mode {*pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports {SDRAM_CLK}]

# Reads: the memory drives DQ from its clock edge.
set_input_delay -clock sdram_clk_pin -max [expr {$sdram_tAC + $sdram_board}]     [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock sdram_clk_pin -min [expr {$sdram_tOH + $sdram_board_min}] [get_ports {SDRAM_DQ[*]}]

# THE FIRST BEAT IS CAPTURED TWO clk_sys EDGES AFTER THE MEMORY'S LAUNCH EDGE,
# not one. sdram.sv registers the READ command on a clk_sys edge; the memory
# sees it half a period later (SDRAM_CLK is the same 96 MHz at 180 degrees),
# drives the first word CL=2 memory clocks after that, and dq_in captures it
# on the clk_sys edge after the one STA would assume. Measured on the fit this
# was calibrated against: data arrival 28.0 ns against a single-cycle
# requirement of 18.8 (-9.2 ns), against the second edge +0.65 ns. That
# sub-nanosecond margin on beat 0 is the whole reason a capture register
# placed in the fabric, with 5-10 ns of routing in front of it, failed on
# hardware while an I/O-cell register passes. Hold is checked against the
# first edge, as it must be.
set sdram_dq_regs [get_registers {*sdram:u_sdram|dq_in[*]}]
set_multicycle_path -setup 2 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs
set_multicycle_path -hold  1 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs

# Writes and commands: the memory samples on its clock edge.
set sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk_pin -max [expr {$sdram_tDS + $sdram_board}]      $sdram_outs
set_output_delay -clock sdram_clk_pin -min [expr {-$sdram_tDH + $sdram_board_min}] $sdram_outs
