// CRT adjust (crt_adjust.sv, vendored) with the Arcade-Raiden_MiSTer glue:
// moves and stretches the picture through a line buffer with native syncs.
// H-Position is an index into 0, +1..+48, -48..-1 (wraps at 97).

`default_nettype none

module seta_crt (
	input  wire       clk,            // 96 MHz
	input  wire       ce,             // core pixel, one per 12 clk
	input  wire       adjust,         // CRT adjust On
	input  wire [4:0] hsize_idx,
	input  wire [6:0] hpos_idx,
	input  wire [5:0] vshift_idx,

	input  wire [7:0] r_in, g_in, b_in,
	input  wire       hs_in, vs_in, hb_in, vb_in,

	output wire       active,         // module in the path
	output wire       ce_out,         // two clk wide
	output wire [7:0] r_out, g_out, b_out,
	output wire       hs_out, vs_out, hb_out, vb_out
);

	assign active = adjust;

	reg  signed [4:0] hsize = 5'sd0;
	reg         [6:0] hpos = 7'd0;
	always @(posedge clk) if (ce) begin
		hsize  <= adjust ? $signed(hsize_idx) : 5'sd0;
		hpos   <= adjust ? hpos_idx : 7'd0;
	end
	wire signed [8:0] hoffset = (hpos <= 7'd48)
		? $signed({2'b00, hpos})
		: $signed({2'b00, hpos}) - 9'sd97;
	wire signed [5:0] voffset = adjust ? $signed(vshift_idx) : 6'sd0;

	// read enable in twentieths of a cycle: 240 per pixel, +5 per H-Size step
	// (a quarter cycle); restarted on hs_ref.
	wire       hs_ref;
	reg        hs_ref_d = 1'b0;
	reg  [8:0] acc = 9'd0;
	wire [8:0] period = 9'd240
	                  + {{2{hsize[4]}}, hsize, 2'b00} + {{4{hsize[4]}}, hsize};
	wire       tick = (acc + 9'd20) >= period;
	always @(posedge clk) begin
		hs_ref_d <= hs_ref;
		if (hs_ref & ~hs_ref_d) acc <= 9'd0;
		else if (tick)          acc <= acc + 9'd20 - period;
		else                    acc <= acc + 9'd20;
	end
	wire pxl2_cen = (hsize == 5'sd0) ? ce : tick;

	reg pxl2_cen_d = 1'b0;
	always @(posedge clk) pxl2_cen_d <= pxl2_cen;
	assign ce_out = pxl2_cen | pxl2_cen_d;

	crt_adjust #(.VTOTAL(272), .HTOTAL(512), .HPOS_MODE(1)) u_crt_adjust (
		.clk(clk), .pxl_cen(ce), .pxl2_cen(pxl2_cen),
		.active(active), .hsize(hsize),
		.hoffset(hoffset), .voffset(voffset),
		.r_in(r_in), .g_in(g_in), .b_in(b_in),
		.hs_in(hs_in), .vs_in(vs_in), .hb_in(hb_in), .vb_in(vb_in),
		.r_out(r_out), .g_out(g_out), .b_out(b_out),
		.hs_out(hs_out), .vs_out(vs_out), .hb_out(hb_out), .vb_out(vb_out),
		.hs_ref_out(hs_ref)
	);

endmodule

`default_nettype wire
