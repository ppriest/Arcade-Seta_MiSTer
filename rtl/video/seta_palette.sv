// Seta X1-006 — palette RAM and the 5:5:5 decode.
//
// From seta.cpp's set_pens():
//     rgb_t(pal5bit(data >> 10), pal5bit(data >> 5), pal5bit(data >> 0))
// so the word is xRRRRRGGGGGBBBBB, and pal5bit is the standard
// 5-bit-to-8-bit expansion (v << 3) | (v >> 2) -- NOT a shift alone, which
// loses the top of the range and makes white read as 0xF8.
//
// MAME converts the whole palette once per frame into a pen table; there is no
// such step here, because there is nothing to convert -- the lookup is done
// per pixel, live, out of the same RAM the CPU writes. That also means a
// mid-frame palette write takes effect mid-frame, which is what the hardware
// does and what MAME's once-per-frame conversion cannot represent.
//
// SIZE. Group A is 512 entries; pairlove has 2048; Group C runs to 512*3 and
// the 6bpp families to 16*32 + 64*32*4 with an indirect step on top. 2048 is
// enough for every Phase 1 game and is what the parameter defaults to -- the
// later families get their own value, and the indirection is a Phase 4
// problem, deliberately not anticipated here.
//
// ONE WRITE PORT AND ONE READ PORT: the CPU writes (and reads back through the
// same port), the video side reads. A simple dual-port RAM, which an M10K
// provides directly. Asking for a second read ADDRESS is what made Quartus
// replicate x1_010's register file into logic -- see that module's header.

`default_nettype none

module seta_palette #(
	parameter int ENTRIES = 2048,
	parameter int AW      = $clog2(ENTRIES)
) (
	input  wire        clk,

	// ---- CPU: 16-bit words, byte lanes -------------------------------------
	input  wire        cpu_we,
	input  wire [AW-1:0] cpu_addr,
	input  wire [15:0] cpu_wdata,
	input  wire        cpu_uds, cpu_lds,
	output logic [15:0] cpu_rdata,

	// ---- video: index in, colour out, two cycles later ---------------------
	input  wire [AW-1:0] index,
	output logic [7:0] r, g, b
);

	logic [15:0] pal [0:ENTRIES-1];
	logic [15:0] vid_q;

	// THE CPU SIDE IS REGISTERED IN. A peripheral RAM whose data input hangs
	// combinationally off the CPU's data bus puts the CPU's slowest register
	// output in series with this decode and the array's setup time; on the
	// first whole-core build that shape was the critical path. maincpu.sv
	// spends three cycles on an io access and captures the read in the third,
	// so the stage costs nothing.
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

	// pal5bit: (v << 3) | (v >> 2), so 0x1f maps to 0xff and 0 to 0.
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
