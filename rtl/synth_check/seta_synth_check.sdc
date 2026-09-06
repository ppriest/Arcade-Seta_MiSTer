# clk_sys = 96 MHz, the value docs/ROADMAP.md proposes: 6x the 16 MHz 68000 and
# 12x the believed 8 MHz dot clock, so both enables are exact integer dividers.
#
# Constraining it is the whole point. Quartus reports "Fitter was successful"
# on a design that grossly fails timing and nothing in the default flow warns;
# Psikyo shipped an .rbf at -8.879 ns setup slack that way. Read
# output_files/seta_synth_check.sta.summary, Fmax Summary first.
create_clock -name clk -period 10.4167 [get_ports clk]
derive_clock_uncertainty

# HARNESS ARTIFACT, not a core constraint. seta_synth_top XOR-reduces every DUT
# output onto one pin to keep the design alive without spending a pin per bit.
# That reduction tree is hundreds of bits deep and is not part of the core; the
# real top level consumes these outputs as ordinary distributed loads.
set_false_path -to [get_keepers {result*}]

# ---------------------------------------------------------------------------
# TG68K kernel multicycle -- WITH ITS AUDIT, because an unaudited multicycle is
# how a design passes timing and fails on silicon.
#
# MEASURED, unconstrained, on this device and speed grade: setup slack
# -8.763 ns against a 10.4167 ns period, so the worst path needs 19.18 ns --
# Fmax 52.1 MHz. That matches Psikyo's independently measured 48.74 MHz and
# Fuuki's 44.25 MHz for the same core. ALL 30 worst paths run
# execOPC -> TG68K_ALU|Flags[2], entirely inside the kernel; nothing in the
# X1-010, the SDRAM transport or maincpu's own logic fails at all.
#
# The core cannot run at clk_sys and does not need to: it advances ONLY on
# cpu_ce, which is 96 MHz / 6 = 16 MHz. Consecutive enables are exactly 6 clk
# apart, so 6 is what the hardware backs.
#
# Measured here: multicycle 4 took the slack from -8.763 to -1.816 ns. Raising
# it to 6 -- which the enable ratio does support -- measured slightly WORSE at
# -1.969, because by then the critical path had left the kernel entirely and
# ended on the X1-010's accumulators instead. Relaxing a constraint that is no
# longer the bottleneck buys nothing and lets the fitter spend its effort
# elsewhere. 4 is kept: it is what the two prior cores proved, and it is the
# more conservative of two values that measure the same.
#
# The gating audit below was still done on THIS copy rather than inherited,
# because it is what makes even 4 legitimate.
#
# GATING AUDIT (rtl/cpu/tg68k/TG68KdotC_Kernel.vhd). Thirteen `rising_edge(clk)`
# processes. Every one that carries a data path is gated:
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
#   * This design does not instantiate that wrapper. Audited on THIS vendored
#     copy, not assumed: `grep -ci falling_edge` returns 0 for both
#     TG68KdotC_Kernel.vhd and TG68K_ALU.vhd, and 2 for TG68K.vhd, which is not
#     compiled. There is no posedge-to-negedge path to mis-constrain.
#
# Scoped to kernel-internal paths only: the boundary into maincpu.sv's own
# logic is NOT relaxed, because that logic runs at full clk_sys.
# ---------------------------------------------------------------------------
set kernel [get_registers {*TG68KdotC_Kernel*}]
set_multicycle_path -setup -from $kernel -to $kernel 4
set_multicycle_path -hold  -from $kernel -to $kernel 3

# ---------------------------------------------------------------------------
# Board select is STATIC. It comes from the .mra mod byte: established during
# ROM download and never changed while the game runs. In this harness it is
# driven by the free-running pattern register, which would make every
# board-dependent decode a live timing path -- a harness artifact, but the
# underlying requirement is real and carries into the core: whatever drives
# `board` must be constrained as static, or the mode-dependent logic inside
# TG68K (VBR_Stackframe, extAddr_Mode, MUL/DIV width, BitField -- all
# "switchable with CPU") shows up as combinational depth nothing can close.
# ---------------------------------------------------------------------------
set_false_path -from [get_registers {*pat[19]*}]
set_false_path -from [get_registers {*pat[18]*}]
set_false_path -from [get_registers {*pat[17]*}]
set_false_path -from [get_registers {*pat[16]*}]
