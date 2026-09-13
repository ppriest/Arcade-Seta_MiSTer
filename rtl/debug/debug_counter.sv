// Debug counter: saturating, no reset (the core reset may be what is being
// investigated); `clear` comes from the JTAG source bus. Not instantiated at
// present.

module debug_counter #(
	parameter int W = 16
) (
	input  logic         clk,
	input  logic         clear,   // from the JTAG source bus, NOT from core reset
	input  logic         ev,      // count one event per asserted cycle
	output logic [W-1:0] count = '0
);

	// power-up value from the port initialiser (an initial block would be a second driver)
	always_ff @(posedge clk) begin
		if (clear)                 count <= '0;
		else if (ev && ~&count)    count <= count + 1'b1;   // saturate at all-ones
	end

endmodule


// Sticky flag: set by an event, cleared only over JTAG.
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
