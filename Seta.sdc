derive_pll_clocks
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# TG68K kernel multicycle -- WITH ITS AUDIT, because an unaudited multicycle is
# how a design passes timing and fails on silicon.
#
# THIS FILE WAS THE TEMPLATE'S DEFAULT UNTIL THE FIRST FULL BUILD. Phase 0
# measured and audited this constraint in rtl/synth_check/seta_synth_check.sdc,
# a standalone project, and closed at +0.011 ns there -- and none of it was
# ever carried into the real top level. The first whole-core compile came out
# at -7.954 ns with ALL THIRTY worst paths inside TG68KdotC_Kernel: the same
# shape, and the same magnitude, as the unconstrained Phase 0 measurement. Not
# the sprite engine, not the video path, not the SDRAM -- the constraint was
# simply absent. A measurement taken in a side project is not a property of the
# design until the constraint that produced it is in the design's own SDC.
#
# MEASURED, unconstrained, on this device and speed grade: setup slack
# -8.763 ns against a 10.4167 ns period, so the worst path needs 19.18 ns --
# Fmax 52.1 MHz. That matches Psikyo's independently measured 48.74 MHz and
# Fuuki's 44.25 MHz for the same core. All 30 worst paths run
# execOPC -> TG68K_ALU|Flags[2], entirely inside the kernel; nothing in the
# X1-010, the SDRAM transport or maincpu's own logic fails at all.
#
# The core cannot run at clk_sys and does not need to: it advances ONLY on
# cpu_ce, which is 96 MHz / 6 = 16 MHz on the fastest board here and / 12 on
# the rest. Consecutive enables are at least 6 clk apart, so 6 is what the
# hardware backs.
#
# Measured in the synth-check project: multicycle 4 took the slack from
# -8.763 to -1.816 ns. Raising it to 6 -- which the enable ratio does support
# -- measured slightly WORSE at -1.969, because by then the critical path had
# left the kernel entirely and ended on the X1-010's accumulators instead.
# Relaxing a constraint that is no longer the bottleneck buys nothing and lets
# the fitter spend its effort elsewhere. 4 is kept: it is what the two prior
# cores proved, and it is the more conservative of two values that measure the
# same.
#
# GATING AUDIT (rtl/cpu/tg68k/TG68KdotC_Kernel.vhd), done on THIS vendored copy
# rather than inherited, because it is what makes even 4 legitimate. Thirteen
# `rising_edge(clk)` processes. Every one that carries a data path is gated:
#     458  IF clkena_in='1'          484  IF clkena_lw='1' AND state="10"
#     560  IF clkena_lw='1'          870  IF clkena_lw='1'
#     941  IF clkena_in='1'          743  ELSIF clkena_lw='1'
#    1254  ELSIF clkena_lw='1'      1364  ELSIF clkena_lw='1'
#    1053  ELSE ... IF clkena_in='1'  (the state machine; reset branch first)
# The one exception is 464, `use_VBR_Stackframe`, a static decode of the
# CPU-mode generics -- and `CPU` is tied to a constant 2'b00 here, so it folds
# away. There is no ungated data path for a multicycle to mis-constrain.
#
# WHY THIS IS SAFE HERE, where LESSONS_LEARNED warns it is dangerous:
#   * That warning is about TG68K.vhd, the async-bus WRAPPER, which is full of
#     falling-edge registers -- a multicycle sweeping those grants a HALF-cycle
#     path four full cycles and the Fitter routes it that slowly.
#   * This design does not instantiate that wrapper. Audited, not assumed:
#     `grep -ci falling_edge` returns 0 for both TG68KdotC_Kernel.vhd and
#     TG68K_ALU.vhd, and 2 for TG68K.vhd, which is not compiled. There is no
#     posedge-to-negedge path to mis-constrain.
#
# Scoped to kernel-internal paths only: the boundary into maincpu.sv's own
# logic is NOT relaxed, because that logic runs at full clk_sys.
# ---------------------------------------------------------------------------
set kernel [get_registers {*TG68KdotC_Kernel*}]
set_multicycle_path -setup -from $kernel -to $kernel 4
set_multicycle_path -hold  -from $kernel -to $kernel 3

# ---------------------------------------------------------------------------
# The game selector is STATIC. It is the .mra mod byte, latched from ioctl
# index 1 during the ROM download and never changed while the game runs --
# and the download completes before the core comes out of reset.
#
# It has to be said, because rtl/seta_board_cfg.sv fans it out into every
# per-game constant and maincpu.sv's whole address decode, and inside TG68K it
# would otherwise reach the mode-dependent logic (VBR_Stackframe,
# extAddr_Mode, MUL/DIV width, BitField -- all "switchable with CPU") as a live
# path with combinational depth nothing can close.
# ---------------------------------------------------------------------------
set_false_path -from [get_registers {*mod_byte*}]
