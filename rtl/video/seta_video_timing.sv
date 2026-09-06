// Screen timing generator, and the line cadence the sprite engine runs on.
//
// EVERY NUMBER HERE IS A HYPOTHESIS, and docs/ROADMAP.md says so at length.
// MAME has NO raw timings for this hardware -- it uses set_refresh_hz() plus
// set_size(64*8, 32*8) and a per-game set_visarea, so the totals are ours to
// derive and to verify. Of the refresh rates in the driver only daioh's 57.42
// is marked "verified on PCB"; the rest are approximations or MAME's 60 Hz
// default with no evidence either way.
//
// The working hypothesis, which is what these ports are fed with:
//     dot clock = 16 MHz / 2 = 8 MHz, htotal = 512
//     vtotal 260 -> 60.10 Hz    (the 60 Hz games, including all of Group A)
//     vtotal 272 -> 57.45 Hz    (0.05% from daioh's verified 57.42)
//     vtotal 276 -> 56.61 Hz    (msgundam's 56.66)
// Three of MAME's four distinct rates land within a rounding error on ONE
// consistent htotal, which is the kind of hypothesis worth preferring -- but
// the 8 MHz dot clock is inferred from the XTAL, not read anywhere.
//
// NOTE THE FRAME IS NOT MAME'S. MAME declares a 256-line screen and every
// offset in x1_001.cpp is written against that; the RTL's frame is ~260 lines
// because a real CRT needs the blanking MAME does not model. The two are
// different numbers and conflating them is a mistake docs/ROADMAP.md flags
// explicitly. `line` below is MAME's SCREEN-SPACE y, which is what the sprite
// engine wants; vcount is the RTL's own counter, and they are equal only
// inside the active area.
//
// THE LINE CADENCE. The sprite engine renders line L+1 while the video reads
// line L out of the other buffer, so line_start fires at the START of a line,
// not in hblank -- that gives the engine a whole line (512 dots = 6144 clk_sys
// cycles at 96 MHz) rather than the 128 dots of blanking. Getting that
// backwards costs a factor of four and shows up as sprite dropout.

`default_nettype none

module seta_video_timing (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,        // one pulse per dot (8 MHz from 96 MHz)

	// ---- geometry, from the board table ------------------------------------
	input  wire  [9:0] htotal,        // 512
	input  wire  [9:0] hs_start, hs_end,
	input  wire  [9:0] hact_start, hact_end,   // visarea min_x .. max_x
	input  wire  [9:0] vtotal,        // 260 for the 60 Hz games
	input  wire  [9:0] vs_start, vs_end,
	input  wire  [9:0] vact_start, vact_end,   // visarea min_y .. max_y

	// ---- counters ----------------------------------------------------------
	output logic [9:0] hcount,
	output logic [9:0] vcount,
	output logic       hsync, vsync,
	output logic       hblank, vblank,
	output logic       de,

	// ---- to the sprite engine ----------------------------------------------
	// One pulse at the start of every line, naming the line to PREPARE.
	//
	// THAT LINE IS TWO AHEAD, NOT ONE, and the arithmetic is worth writing out
	// because "one ahead" is the obvious answer and is wrong. The sprite engine
	// double-buffers: during any line it writes one buffer while the video
	// reads the other, and the buffers swap at line_start. So the buffer
	// written during line L is not read until line L+1 -- which means the
	// engine, started at the beginning of line L, has to be rendering line
	// L+1. line_start fires at the END of line L-1, so the line it names is
	// (L-1) + 2.
	//
	// Off by one, the whole picture is displayed one scanline late. It looks
	// like nothing at all on a static screen and like a few stray pixels along
	// every horizontal edge on a real frame: measured against MAME, 3,560 of
	// 92,160 pixels on 148 of 240 lines, in ones and twos -- which reads as
	// sprite dropout rather than a timing error. The tell was that shifting the
	// captured frame down one line made it match exactly.
	//
	// Screen space, so it is directly what x1_001.sv's y arithmetic is written
	// against.
	output logic       line_start,
	output logic [8:0] line,

	// ---- interrupts ---------------------------------------------------------
	// seta_interrupt_1_and_2 / _2_and_4 fire at MAME scanlines 240 and 112.
	// Emitted as one-cycle pulses at the start of those lines; what IPL they
	// drive, and whether the line is held or auto-clears, is the board's
	// business, not this module's.
	output logic       irq_vblank_line,   // MAME scanline 240
	output logic       irq_mid_line,      // MAME scanline 112
	output logic       vblank_rise
);

	wire h_last = (hcount == htotal - 10'd1);
	wire v_last = (vcount == vtotal - 10'd1);

	// The line about to begin, and the one the engine is asked to prepare.
	// Both wrapped against vtotal rather than against a power of two, because
	// vtotal is 260 -- there is no natural mask.
	wire [9:0] line_next  = v_last ? 10'd0 : (vcount + 10'd1);
	wire [9:0] line_p2raw = vcount + 10'd2;
	wire [9:0] line_plus2 = (line_p2raw >= vtotal) ? (line_p2raw - vtotal)
	                                               : line_p2raw;

	always_ff @(posedge clk) begin
		line_start      <= 1'b0;
		irq_vblank_line <= 1'b0;
		irq_mid_line    <= 1'b0;
		vblank_rise     <= 1'b0;

		if (reset) begin
			hcount <= 10'd0;
			vcount <= 10'd0;
		end else if (ce_pix) begin
			if (h_last) begin
				hcount <= 10'd0;
				vcount <= v_last ? 10'd0 : (vcount + 10'd1);
			end else begin
				hcount <= hcount + 10'd1;
			end

			// Start of a line: kick the engine off on the line two ahead (see
			// above), and raise whichever scanline events belong to the line
			// just begun.
			if (h_last) begin
				line_start <= 1'b1;
				line       <= line_plus2[8:0];

				if (line_next == 10'd240) irq_vblank_line <= 1'b1;
				if (line_next == 10'd112) irq_mid_line    <= 1'b1;
				if (line_next == vact_end + 10'd1) vblank_rise <= 1'b1;
			end
		end
	end

	always_comb begin
		hsync  = (hcount >= hs_start) && (hcount < hs_end);
		vsync  = (vcount >= vs_start) && (vcount < vs_end);
		hblank = (hcount < hact_start) || (hcount > hact_end);
		vblank = (vcount < vact_start) || (vcount > vact_end);
		de     = !hblank && !vblank;
	end

endmodule

`default_nettype wire
