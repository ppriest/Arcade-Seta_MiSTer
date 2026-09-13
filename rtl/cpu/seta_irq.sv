// 68000 interrupt requests. Per level, HOLD_LINE sources clear when the CPU
// acknowledges that level (the level it latched, from A3..A1); ASSERT_LINE
// sources clear only on the board's acknowledge write. Sets are one-cycle
// edges and win over a same-cycle clear, so an interrupt arriving as an
// older one is taken is not lost. seta.cpp's ipl0/1/2_ack_w clear levels
// 1/2/4.

`default_nettype none

module seta_irq (
	input  wire        clk,
	input  wire        reset,

	input  wire  [7:1] set,           // one-cycle pulse per level
	input  wire  [7:1] hold,          // 1 = HOLD_LINE, 0 = ASSERT_LINE
	input  wire  [7:1] clr,           // board acknowledge, one-cycle pulse

	input  wire        iack,          // interrupt-acknowledge cycle
	input  wire  [2:0] iack_level,

	output logic [2:0] ipl_level,
	output logic [7:1] pending
);

	always_ff @(posedge clk) begin
		if (reset) begin
			pending <= 7'd0;
		end else begin
			if (iack && iack_level != 3'd0 && hold[iack_level])
				pending[iack_level] <= 1'b0;

			for (int n = 1; n <= 7; n++) begin
				if (!hold[n] && clr[n]) pending[n] <= 1'b0;
				if (set[n])             pending[n] <= 1'b1;
			end
		end
	end

	always_comb begin
		ipl_level = 3'd0;
		for (int n = 1; n <= 7; n++)
			if (pending[n]) ipl_level = n[2:0];
	end

endmodule

`default_nettype wire
