`timescale 1ns/10ps
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'  -- clk_sys, 96 MHz
	output wire outclk_0,

	// interface 'outclk1'  -- SDRAM_CLK, the same 96 MHz shifted 180 degrees
	//
	// The physical SDRAM clock pin is driven from HERE, not from sdram.sv --
	// that module's own comment says so ("Real SDRAM_CLK phase generation is
	// top-level") and it simply assigns SDRAM_CLK = clk, which is right for a
	// simulation and wrong for a board.
	//
	// 180 degrees is 5208 ps of the 10417 ps period, and it is the value the
	// Psikyo core proved on real MiSTer hardware; Fuuki took it unchanged for
	// the same reason. At 266 degrees -- tuned for a different controller --
	// Psikyo came up as a frozen pattern with the CPU never booting, because
	// commands and read data were latched on the wrong edge. NO SIMULATION CAN
	// CATCH THIS: the chip model has no notion of clock phase, which is why
	// this is a value carried over from something that ran rather than one
	// derived here.
	output wire outclk_1,

	// interface 'outclk2' -- clk_video, 48 MHz, EXACTLY HALF of clk_sys.
	//
	// The scandoubler and the HQ2x blender run on this instead of clk_sys.
	// After the four-cycle io access landed, every path still failing in the
	// whole design was inside arcade_video's Hq2x|Blend -- vendored framework
	// logic, nothing of this core's -- at -0.229 ns. The blender needs about
	// 10.65 ns; at 48 MHz it has 20.83.
	//
	// HALF, specifically, so this stays SYNCHRONOUS: every 48 MHz edge is also
	// a 96 MHz edge, so there is no clock-domain crossing to get wrong and no
	// SDC exception to justify. A 64 MHz output would have divided the pixel
	// more evenly but 96:64 is 3:2, which is a real CDC.
	//
	// The uneven division does not matter: scandoubler.v MEASURES the input
	// pixel length itself (pixsz <= pl, then pixsz2 = pl/2, pixsz4 = pl/4) and
	// fires its four sub-phase enables from that, so it adapts to whatever
	// ratio it is given. At 96 MHz an 8 MHz pixel is 12 cycles and the enables
	// land on 3/6/9/12; at 48 MHz it is 6 cycles and they land on 1/3/4/6.
	output wire outclk_2,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("96.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("96.000000 MHz"),
		.phase_shift1("5208 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("48.000000 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		// THE BUS, NOT JUST THE PARAMETERS. number_of_clocks(3) and
		// output_clock_frequency2 are not enough on their own: this
		// concatenation is the actual wiring, and leaving it two wide left
		// outclk_2 dangling. clk_video was then undriven, every register in
		// arcade_video went "Stuck at GND due to stuck port clock", and the
		// whole video chain was optimised away -- 4,000 ALMs, 35 RAM blocks
		// and 9 DSPs lighter, reporting +0.238 ns and TIMING MET.
		.outclk	({outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

