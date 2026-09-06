// A counter for debug instrumentation, with the two properties that make one
// trustworthy: it SATURATES rather than wrapping, and it has NO RESET.
//
// Saturating, because a wrapped counter is ambiguous -- 3 could mean "three
// times" or "65,539 times", and those lead to opposite conclusions.
//
// No reset, because of the trap in docs/LESSONS_LEARNED.md: "Never reset a
// debug counter with the reset you are investigating." On the Psikyo core two
// measurements read zero and were reported as findings before anyone noticed
// the counters were being cleared by a reset that was asserted for the entire
// measured window. Quartus powers registers to zero, so a counter with no
// reset shows what genuinely happened since the FPGA was configured -- which
// is the question being asked. The optional `clear` is driven from the JTAG
// source bus, i.e. by the person watching, never by core logic.
//
// Pair every "bad event" counter with a "total events" counter. A zero here
// means "never happened" only if you can also see that the thing was given
// the chance to happen.

module debug_counter #(
	parameter int W = 16
) (
	input  logic         clk,
	input  logic         clear,   // from the JTAG source bus, NOT from core reset
	input  logic         ev,      // count one event per asserted cycle
	output logic [W-1:0] count = '0
);

	// The declaration initialiser (on the port) is what gives the power-up
	// value. It must NOT be an `initial` block: that counts as a second
	// process driving the same variable and Quartus/ModelSim reject it
	// (vlog-7061). Quartus powers registers to zero regardless, so this is
	// belt and braces for simulation.
	always_ff @(posedge clk) begin
		if (clear)                 count <= '0;
		else if (ev && ~&count)    count <= count + 1'b1;   // saturate at all-ones
	end

endmodule


// Latch that a thing happened at least once. Same reset discipline: sticky
// from configuration until explicitly cleared over JTAG.
//
// Useful for the questions that are genuinely yes/no ("did the download ever
// start", "did any read return non-zero"), where a count would be noise. Note
// a sticky flag cannot distinguish once from constantly -- if that matters,
// use a counter.
module debug_sticky (
	input  logic clk,
	input  logic clear,
	input  logic ev,
	output logic seen = 1'b0
);

	always_ff @(posedge clk) begin
		if (clear)   seen <= 1'b0;
		else if (ev) seen <= 1'b1;
	end

endmodule
