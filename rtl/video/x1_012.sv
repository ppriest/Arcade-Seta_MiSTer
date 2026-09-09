// Seta X1-012 tile layer generator, one scanline at a time.
//
// The golden reference is scripts/x1_012_model.py, which is a line-by-line
// transcription of MAME's video/x1_012.cpp and is pixel-identical to MAME's
// own render on 12 of 12 frames across drgnunit, stg, qzkklogy and qzkklgy2.
// Everything here is written against that model, not against the C++ directly.
//
// WHAT THE CHIP IS
//
//   One tilemap, TILEMAP_SCAN_ROWS, 16x16 tiles, 64 columns by 32 rows --
//   1024x512 pixels, wrapping in both axes. Each layer's VRAM holds TWO
//   tilemaps and only one is displayed; vctrl[2] bit 3 picks it, and the second
//   lives at word offset 0x1000.
//
//   Per tile, from the selected bank:
//       code  = vram[i] & 0x3fff
//       attr  = vram[i + 0x800],  colour = attr & 0x1f
//   and the flip bits are bits 15 and 14 of the code word -- IN THAT ORDER.
//   MAME writes TILE_FLIPXY((word & 0xc000) >> 14), and that macro TRANSPOSES
//   its two bits:
//       TILE_FLIPXY(xy) = ((xy & 2) >> 1) | ((xy & 1) << 1)
//   with TILE_FLIPX = 1 and TILE_FLIPY = 2. So word bit 14 is FLIPY and bit 15
//   is FLIPX, the opposite way round to what the name reads like. Reading it
//   the natural way costs 2-5% of the pixels, only on frames that contain a
//   flipped tile, which is why it survived three of four sets looking correct.
//
// THE TILE FETCH, which is the whole reason this module is not trivial
//
//   layout_tilemap packs the four bitplanes together, and one 16-pixel ROW of
//   a tile is FOUR 16-BIT CHUNKS EIGHT WORDS APART inside the tile's 64 words:
//
//       w0 = (y >= 8 ? 32 : 0) + (y & 7)
//       chunks at w0, w0 + 8, w0 + 16, w0 + 24
//
//   The chunk at w0+24 holds pixels 0..3, w0+16 holds 4..7, w0+8 holds 8..11
//   and w0 holds 12..15 -- descending, because layout_tilemap's x offsets run
//   in descending groups of four.
//
//   Within a chunk, pixel i of the four takes one bit from each plane, and the
//   FIRST PLANE LISTED IS THE MOST SIGNIFICANT BIT of the pen:
//
//       pen[3] = chunk[15 - (i     )]
//       pen[2] = chunk[15 - (i +  4)]
//       pen[1] = chunk[15 - (i +  8)]
//       pen[0] = chunk[15 - (i + 12)]
//
//   VERIFIED, not derived: this formula was checked against the model's own
//   decoder over 1024 tile rows with zero mismatches before a line of this
//   module was written. Phase 1's record is that every graphics layout reasoned
//   out from byte order was wrong and every one tested against real data was
//   right.
//
//   Four granule reads per tile row, and only 16 of each granule's 64 bits are
//   used. That is wasteful and deliberate: a visible line spans at most 25
//   tiles, so 100 reads sit well inside the same per-line budget the sprite
//   engine lives on, and correctness comes before the download-time swizzle
//   that would fold each row into one granule.
//
// WHAT IS NOT HERE
//
//   draw_tilemap_palette_effect -- blandia's second-palette trick. Phase 5.
//   The colour-mode bit, vctrl[2] bit 4, selects a second gfx decode that does
//   not exist for any game in this phase; MAME popmessages and falls back to
//   0, and so does this.
module x1_012 #(
	parameter int LB_W = 11
) (
	input  wire         clk,
	input  wire         reset,

	// ---- CPU side ----------------------------------------------------------
	// Registered in, for the reason rtl/cpu/maincpu.sv's four-cycle access
	// exists: a peripheral RAM hanging combinationally off the CPU's outputs
	// was the critical path of the whole design twice over.
	input  wire         vram_we,
	input  wire  [12:0] vram_addr,          // word address into 0x2000 words
	input  wire  [15:0] vram_wdata,
	input  wire         vram_uds, vram_lds,
	output logic [15:0] vram_rdata,

	input  wire         vctrl_we,
	input  wire   [1:0] vctrl_addr,
	input  wire  [15:0] vctrl_wdata,
	input  wire         vctrl_uds, vctrl_lds,
	output logic [15:0] vctrl_rdata,

	// ---- configuration -----------------------------------------------------
	input  wire signed [8:0] xoffs,         // set_xoffsets(flip, noflip)
	input  wire signed [8:0] xoffs_flip,
	input  wire         flipscr,
	input  wire   [8:0] vis_dimy,           // visible_area height, 240
	input  wire [LB_W-1:0] colorbase,       // the GFXDECODE_ENTRY base
	input  wire  [15:0] code_mask,          // gfx_element wraps a code past the end

	// ---- line engine -------------------------------------------------------
	input  wire         line_start,
	input  wire   [8:0] line,
	input  wire  [15:0] line_budget,
	output logic        line_done,
	output logic        busy,

	// ---- tile ROM ----------------------------------------------------------
	output logic        rom_req,
	output logic [23:3] rom_addr,
	input  wire         rom_valid,
	input  wire  [63:0] rom_data,

	// ---- line buffer readback ---------------------------------------------
	input  wire   [8:0] lb_addr,
	output logic [LB_W-1:0] lb_data,

	output logic [15:0] dbg_lines   = '0,
	output logic [15:0] dbg_tiles   = '0,
	output logic [15:0] dbg_overrun = '0
);

	// =====================================================================
	// CPU-visible state
	// =====================================================================
	logic        v_we, v_uds, v_lds;
	logic [12:0] v_addr;
	logic [15:0] v_wdata;
	logic        c_we, c_uds, c_lds;
	logic  [1:0] c_addr;
	logic [15:0] c_wdata;

	always_ff @(posedge clk) begin
		v_we <= vram_we; v_addr <= vram_addr; v_wdata <= vram_wdata;
		v_uds <= vram_uds; v_lds <= vram_lds;
		c_we <= vctrl_we; c_addr <= vctrl_addr; c_wdata <= vctrl_wdata;
		c_uds <= vctrl_uds; c_lds <= vctrl_lds;
	end

	logic [15:0] vram [0:8191];
	logic [12:0] eng_vaddr;
	logic [15:0] eng_vq;

	always_ff @(posedge clk) begin
		if (v_we && v_lds) vram[v_addr][7:0]  <= v_wdata[7:0];
		if (v_we && v_uds) vram[v_addr][15:8] <= v_wdata[15:8];
		vram_rdata <= vram[v_addr];
	end
	always_ff @(posedge clk) eng_vq <= vram[eng_vaddr];

	// Three 16-bit control registers. vctrl[0] is scroll X, [1] scroll Y and
	// [2] the bank and colour-mode bits.
	logic [15:0] vctrl [0:2];
	always_ff @(posedge clk) begin
		if (c_we && c_addr < 2'd3) begin
			if (c_lds) vctrl[c_addr][7:0]  <= c_wdata[7:0];
			if (c_uds) vctrl[c_addr][15:8] <= c_wdata[15:8];
		end
		vctrl_rdata <= vctrl[c_addr < 2'd3 ? c_addr : 2'd0];
	end

	wire        bank_sel = vctrl[2][3];
	wire [12:0] bank_off = bank_sel ? 13'h1000 : 13'h0000;

	// =====================================================================
	// update_scroll, transcribed
	//
	//     x = vctrl[0] + 0x10 - xoffsets[flip]
	//     y = vctrl[1] - (256 - vis_dimy) / 2
	//     if (flip) { x = -x - 512; y = y - vis_dimy; }
	//
	// Latched once per line: nothing here changes within a line, and keeping
	// the arithmetic off the per-pixel path is the same lesson the sprite
	// engine's foreground hit test learned the expensive way.
	// =====================================================================
	wire signed [8:0] xo = flipscr ? xoffs_flip : xoffs;
	wire [15:0] sx_base = vctrl[0] + 16'h0010 - {{7{xo[8]}}, xo};
	wire [15:0] sy_base = vctrl[1] - {7'd0, (9'd256 - vis_dimy) >> 1};
	// if (flip) { x = -x - 512; y = y - vis_dimy; }
	//
	// SCREEN FLIP IS NOT VERIFIED and is parked. This is the transcription of
	// update_scroll's flipped branch and the map mirroring that goes with it,
	// but the model it would be checked against fails the only flipped capture
	// that exists by 29.6% -- and seta.cpp's own TODO says "drgnunit sprite/bg
	// unaligned when screen flipped" and "tilemap flipping is also kludged in
	// the video driver", so the reference is itself suspect. See
	// docs/MAME_DIVERGENCE.md. sim/x1_012_tb refuses a flipped fixture.
	//
	// PER-TILE FLIP IS A DIFFERENT THING AND IS CORRECT: the tile word's
	// flipx/flipy are exercised by 24 of 24 bench runs on frames that contain
	// flipped tiles.
	wire [15:0] scroll_x_raw = flipscr ? (16'd0 - sx_base - 16'd512) : sx_base;
	wire [15:0] scroll_y_raw = flipscr ? (sy_base - {7'd0, vis_dimy}) : sy_base;

	logic [9:0] scroll_x;
	logic [8:0] scroll_y;
	logic [8:0] cur_line;

	// =====================================================================
	// Line buffer, double buffered exactly as x1_001's is: the engine renders
	// one line ahead into the bank the display is not reading.
	// =====================================================================
	logic [LB_W-1:0] lbuf0 [0:511];
	logic [LB_W-1:0] lbuf1 [0:511];
	logic            render_bank = 1'b0;
	logic            disp_bank;

	logic            lb_we;
	logic      [8:0] lb_waddr;
	logic [LB_W-1:0] lb_wdata;
	logic [LB_W-1:0] lb_q0, lb_q1;

	always_ff @(posedge clk) begin
		if (lb_we && !render_bank) lbuf0[lb_waddr] <= lb_wdata;
		lb_q0 <= lbuf0[lb_addr];
	end
	always_ff @(posedge clk) begin
		if (lb_we && render_bank) lbuf1[lb_waddr] <= lb_wdata;
		lb_q1 <= lbuf1[lb_addr];
	end
	always_ff @(posedge clk) disp_bank <= ~render_bank;
	assign lb_data = disp_bank ? lb_q1 : lb_q0;

	// =====================================================================
	// The engine
	// =====================================================================
	typedef enum logic [3:0] {
		S_IDLE, S_LATCH, S_TILE, S_TILE2, S_ATTR, S_ATTR2,
		S_FETCH, S_WAIT, S_BLIT, S_NEXT, S_DONE
	} state_t;
	state_t state = S_IDLE;

	logic  [4:0] col;            // which of the tiles across this line
	logic  [9:0] px;             // first screen pixel of this tile column
	logic [13:0] tile_code;
	logic  [4:0] tile_color;
	logic        tile_fx, tile_fy;
	logic  [3:0] tile_row;
	logic  [1:0] chunk;
	logic [15:0] chunks [0:3];
	logic [15:0] line_cycles;

	// The tilemap row this scanline lands on, and the row within the tile.
	// set_flip(TILEMAP_FLIPX | TILEMAP_FLIPY) mirrors the WHOLE 1024x512 pixmap
	// about itself, and the scroll is applied to the mirrored map -- which the
	// model does as
	//     px = (1023 - (x + sx)) & 1023
	//     py = (511  - (y + sy)) & 511
	// so the same two subtractions land here, on the map coordinates rather
	// than on the tile lookup, and everything downstream is unchanged.
	wire  [8:0] map_y_u = cur_line + scroll_y;
	wire  [8:0] map_y   = flipscr ? (9'd511 - map_y_u) : map_y_u;
	wire  [4:0] map_row = map_y[8:4];
	wire  [3:0] row_in  = map_y[3:0];

	// The tilemap column for the current tile, and its index.
	wire  [9:0] map_x_u = px + scroll_x;
	wire  [9:0] map_x   = flipscr ? (10'd1023 - map_x_u) : map_x_u;
	wire  [5:0] map_col = map_x[9:4];
	wire [10:0] tile_ix = {map_row, map_col};      // TILEMAP_SCAN_ROWS

	// The row inside the tile, after the tile's own vertical flip.
	wire  [3:0] eff_row = tile_fy ? (4'd15 - row_in) : row_in;

	// w0 = (y >= 8 ? 32 : 0) + (y & 7), then chunk c is at w0 + c*8.
	wire  [5:0] w0      = {eff_row[3], 2'b00, eff_row[2:0]};
	wire  [5:0] w_sel   = w0 + {chunk, 3'b000};
	// 64 words per tile, and a granule is four words: the granule address is
	// (code * 64 + word) >> 2, and the word within it selects 16 of the 64 bits.
	wire [21:0] word_ix = {tile_code & code_mask[13:0], 6'd0} + {16'd0, w_sel};

	function automatic [3:0] pen_of(input [15:0] w, input [1:0] i);
		pen_of = { w[15 - {3'd0, i}],
		           w[15 - ({3'd0, i} + 3'd4)],
		           w[15 - ({3'd0, i} + 4'd8)],
		           w[15 - ({3'd0, i} + 4'd12)] };
	endfunction

	// The 16-bit word this granule read is for, in sdram.sv's order.
	wire [15:0] rom_word = word_ix[1:0] == 2'd0 ? rom_data[15:0]  :
	                       word_ix[1:0] == 2'd1 ? rom_data[31:16] :
	                       word_ix[1:0] == 2'd2 ? rom_data[47:32] :
	                                              rom_data[63:48];

	logic [4:0] blit_px;         // 0..15 within the tile

	always_ff @(posedge clk) begin
		lb_we    <= 1'b0;
		rom_req  <= 1'b0;
		line_done <= 1'b0;

		if (reset) begin
			state       <= S_IDLE;
			render_bank <= 1'b0;
			line_cycles <= '0;
		end else if (line_start) begin
			if (state != S_IDLE) dbg_overrun <= dbg_overrun + 16'd1;
			dbg_lines   <= dbg_lines + 16'd1;
			render_bank <= ~render_bank;
			cur_line    <= line;
			scroll_x    <= scroll_x_raw[9:0];
			scroll_y    <= scroll_y_raw[8:0];
			line_cycles <= '0;
			col         <= 5'd0;
			px          <= 10'd0;
			state       <= S_LATCH;
		end else begin
			if (state != S_IDLE) line_cycles <= line_cycles + 16'd1;

			if (line_budget != 16'd0 && line_cycles >= line_budget
			    && state != S_IDLE && state != S_DONE) begin
				state <= S_DONE;
			end else
			case (state)
			S_IDLE: ;

			// The scroll registers are latched; start the first tile.
			S_LATCH: begin
				eng_vaddr <= bank_off + {2'd0, tile_ix};
				state     <= S_TILE;
			end

			S_TILE:  state <= S_TILE2;                // RAM latency
			S_TILE2: begin
				tile_code <= eng_vq[13:0];
				// TILE_FLIPXY transposes: bit 15 is FLIPX, bit 14 is FLIPY.
				tile_fx   <= eng_vq[15];
				tile_fy   <= eng_vq[14];
				eng_vaddr <= bank_off + {2'd0, tile_ix} + 13'h800;
				state     <= S_ATTR;
			end

			S_ATTR:  state <= S_ATTR2;
			S_ATTR2: begin
				tile_color <= eng_vq[4:0];
				chunk      <= 2'd0;
				state      <= S_FETCH;
			end

			S_FETCH: begin
				rom_req  <= 1'b1;
				rom_addr <= {3'd0, word_ix[21:2]};
				state    <= S_WAIT;
			end

			S_WAIT: if (rom_valid) begin
				// TWO CONVENTIONS, BOTH EASY TO GET BACKWARDS.
				//
				// A granule is four consecutive 16-bit words with WORD 0 IN THE
				// LOW BITS -- rom_data[16*i +: 16] -- which is sdram.sv's order.
				//
				// And a word IN SDRAM is {odd byte, even byte}, while the tile
				// data is big-endian in the ROM, so the halves arrive swapped
				// and are swapped back here. Getting this wrong does not give
				// noise: it gives a plausible picture with every pair of pixels
				// exchanged, which reads as a layout bug. LESSONS_LEARNED
				// already carries it once, as "a behavioural ROM in a bench
				// must speak the transport's byte order".
				chunks[chunk] <= { rom_word[7:0], rom_word[15:8] };
				if (chunk == 2'd3) begin
					blit_px <= 5'd0;
					state   <= S_BLIT;
				end else begin
					chunk <= chunk + 2'd1;
					state <= S_FETCH;
				end
			end

			// Sixteen pixels, one per cycle. Chunk 3 holds pixels 0-3.
			S_BLIT: begin
				lb_we    <= 1'b1;
				lb_waddr <= px[8:0] + {5'd0, blit_px[3:0]}
				            - {5'd0, map_x[3:0]};   // align to the tile edge
				// FLIPX REVERSES THE CHUNK INDEX AS WELL as the position
				// within the chunk. Pixel j takes source pixel 15 - j, and
				// since chunk 3 holds pixels 0..3 the source chunk for a
				// flipped tile is j>>2, not 3 - (j>>2). Reversing only within
				// the chunk gives four-pixel groups in the right order but the
				// groups themselves in the wrong one -- which is why six of
				// twenty-four frames failed, all of them by small counts, on
				// exactly the frames that contain a flipped tile.
				lb_wdata <= colorbase + {2'd0, tile_color, 4'd0}
				            + {7'd0, pen_of(chunks[tile_fx ? blit_px[3:2]
				                                           : (2'd3 - blit_px[3:2])],
				                            tile_fx ? (2'd3 - blit_px[1:0])
				                                    : blit_px[1:0])};
				if (blit_px == 5'd15) state <= S_NEXT;
				else blit_px <= blit_px + 5'd1;
			end

			S_NEXT: begin
				dbg_tiles <= dbg_tiles + 16'd1;
				if (col == 5'd24) state <= S_DONE;
				else begin
					col   <= col + 5'd1;
					px    <= px + 10'd16;
					state <= S_LATCH;
				end
			end

			S_DONE: begin
				line_done <= 1'b1;
				state     <= S_IDLE;
			end
			endcase
		end
	end

	assign busy = (state != S_IDLE);

endmodule
