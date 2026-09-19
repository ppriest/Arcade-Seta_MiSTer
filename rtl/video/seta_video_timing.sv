// Video timing and the sprite engine's line cadence. MAME gives only refresh
// rates and visible areas; the totals come from seta_board_cfg.sv (8 MHz dot
// clock, htotal 512). `line` is MAME screen-space y.

`default_nettype none

module seta_video_timing (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,        // one pulse per dot (8 MHz from 96 MHz)

	input  wire  [9:0] htotal,        // 512
	input  wire  [9:0] hs_start, hs_end,
	input  wire  [9:0] hact_start, hact_end,   // visarea min_x .. max_x
	input  wire  [9:0] vtotal,
	input  wire  [9:0] vs_start, vs_end,
	input  wire  [9:0] vact_start, vact_end,   // visarea min_y .. max_y

	output logic [9:0] hcount,
	output logic [9:0] vcount,
	output logic       hsync, vsync,
	output logic       hblank, vblank,
	output logic       de,

	// At the start of each line, the line to render: two ahead, because the
	// engine's buffer is displayed on the line after it is written.
	output logic       line_start,
	output logic [8:0] line,

	// the line starting, as MAME numbers it (scanline timers), with line_start
	output logic [9:0] scan_line = 10'd0,
	output logic       irq_vblank_line,   // MAME scanline 240
	output logic       irq_mid_line,      // MAME scanline 112
	output logic       vblank_rise,
	output logic       snap_start,     // sprite snapshot, 5 lines before the wrap
	// the line the last visible line is displayed on begins: its render is done
	output logic       snap_pre
);

	wire h_last = (hcount == htotal - 10'd1);
	wire v_last = (vcount == vtotal - 10'd1);

	wire [9:0] line_next  = v_last ? 10'd0 : (vcount + 10'd1);
	wire [9:0] line_p2raw = vcount + 10'd2;
	wire [9:0] line_plus2 = (line_p2raw >= vtotal) ? (line_p2raw - vtotal)
	                                               : line_p2raw;

	always_ff @(posedge clk) begin
		line_start      <= 1'b0;
		irq_vblank_line <= 1'b0;
		irq_mid_line    <= 1'b0;
		vblank_rise     <= 1'b0;
		snap_start      <= 1'b0;
		snap_pre        <= 1'b0;

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

			if (h_last) begin
				line_start <= 1'b1;
				line       <= line_plus2[8:0];
				scan_line  <= line_next;

				if (line_next == 10'd240) irq_vblank_line <= 1'b1;
				if (line_next == 10'd112) irq_mid_line    <= 1'b1;
				if (line_next == vact_end + 10'd1) vblank_rise <= 1'b1;
				// late in vblank, after the games' vblank handlers have written
				if (line_next == vtotal - 10'd5) snap_start <= 1'b1;
				// a line is rendered on the line before it is shown: from here to
				// vblank_rise the engine renders only the first line of vblank
				if (line_next == vact_end) snap_pre <= 1'b1;
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
