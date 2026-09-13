// X1-006 palette RAM: xRRRRRGGGGGBBBBB words, looked up per pixel, expanded
// with MAME's pal5bit, (v << 3) | (v >> 2). The CPU port is registered in.

`default_nettype none

module seta_palette #(
	parameter int ENTRIES = 2048,
	parameter int AW      = $clog2(ENTRIES)
) (
	input  wire        clk,

	input  wire        cpu_we,
	input  wire [AW-1:0] cpu_addr,
	input  wire [15:0] cpu_wdata,
	input  wire        cpu_uds, cpu_lds,
	output logic [15:0] cpu_rdata,

	// video: colour two cycles after index
	input  wire [AW-1:0] index,
	output logic [7:0] r, g, b
);

	logic [15:0] pal [0:ENTRIES-1];
	logic [15:0] vid_q;

	logic        w_we, w_uds, w_lds;
	logic [AW-1:0] w_addr;
	logic [15:0] w_wdata;

	always_ff @(posedge clk) begin
		w_we <= cpu_we; w_addr <= cpu_addr; w_wdata <= cpu_wdata;
		w_uds <= cpu_uds; w_lds <= cpu_lds;
	end

	always_ff @(posedge clk) begin
		if (w_we && w_lds) pal[w_addr][7:0]  <= w_wdata[7:0];
		if (w_we && w_uds) pal[w_addr][15:8] <= w_wdata[15:8];
		cpu_rdata <= pal[w_addr];
	end

	always_ff @(posedge clk) vid_q <= pal[index];

	function automatic logic [7:0] pal5(input logic [4:0] v);
		pal5 = {v, v[4:2]};
	endfunction

	always_ff @(posedge clk) begin
		r <= pal5(vid_q[14:10]);
		g <= pal5(vid_q[9:5]);
		b <= pal5(vid_q[4:0]);
	end

endmodule

`default_nettype wire
