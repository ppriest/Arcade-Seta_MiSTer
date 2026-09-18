// X1-012 tile layer, rendered a scanline ahead into a double line buffer.
// Reference: scripts/x1_012_model.py (MAME's video/x1_012.cpp).
//
// One 64x32 tilemap of 16x16 tiles (1024x512, wrapping). VRAM holds two
// tilemaps; vctrl[2] bit 3 selects which (the second at word 0x1000). Per tile:
//     code = vram[i] & 0x3fff, colour = vram[i + 0x800] & 0x1f,
//     bit 15 FLIPX, bit 14 FLIPY (TILE_FLIPXY transposes them)
//
// 4bpp (layout_tilemap): a tile row is four 16-bit chunks at w0, w0+8, w0+16,
// w0+24 of the tile's 64 words, w0 = (y >= 8 ? 32 : 0) + (y & 7); the chunk at
// w0+24 holds pixels 0..3. Pixel i of a chunk: pen[3] = chunk[15-i],
// pen[2] = chunk[11-i], pen[1] = chunk[7-i], pen[0] = chunk[3-i].
// 6bpp (layout_tilemap_6bpp): 192 bytes a tile, 3-byte chunks.
//
// vctrl[2] bit 4 (colour mode) is only exported; blandia's use of it and its
// palette effect are in seta_video.sv / x1_011_index.sv.
module x1_012 #(
	parameter int LB_W = 11
) (
	input  wire         clk,
	input  wire         reset,

	// CPU (registered in)
	input  wire         vram_we,
	input  wire  [12:0] vram_addr,          // word address into 0x2000 words
	input  wire  [15:0] vram_wdata,
	input  wire         vram_uds, vram_lds,
	output logic [15:0] vram_rdata,
	// a CPU read of VRAM is waiting: the queue drains now, and vram_busy
	// holds the read until the last queued write has landed
	input  wire         vram_drain,
	output wire         vram_busy,

	input  wire         vctrl_we,
	input  wire   [1:0] vctrl_addr,
	input  wire  [15:0] vctrl_wdata,
	input  wire         vctrl_uds, vctrl_lds,
	output logic [15:0] vctrl_rdata,

	// vctrl[2] bit 4, latched at vblank
	output logic        cmode = 1'b0,

	input  wire signed [8:0] xoffs,         // set_xoffsets(flip, noflip)
	input  wire signed [8:0] xoffs_flip,
	input  wire         flipscr,
	input  wire   [8:0] vis_dimy,           // visible_area height, 240
	// flipped mirror size: 512 and 256
	input  wire   [9:0] xextent,
	input  wire   [8:0] yextent,
	input  wire [LB_W-1:0] colorbase,       // the GFXDECODE_ENTRY base
	// code %= elements(), not a mask
	input  wire  [15:0] code_limit,
	// downtown.cpp twineagl_tile_offset: codes 0x3exx take bits 13-7 from
	// one of four bank bytes (>> 1), selected by code bits 8-7
	input  wire         tile_bank_en,
	input  wire  [31:0] tile_bank,
	input  wire         bpp6,

	// bank select and scroll are latched at vblank_rise, as MAME draws the frame
	input  wire         vblank_rise,
	input  wire         line_start,
	input  wire   [8:0] line,
	input  wire  [15:0] line_budget,
	// tile row cache (Debug page)
	input  wire         cache_en,
	output logic        line_done,
	output logic        busy,

	output logic        rom_req,
	output logic [23:3] rom_addr,
	input  wire         rom_valid,
	input  wire  [63:0] rom_data,

	input  wire   [8:0] lb_addr,
	output logic [LB_W-1:0] lb_data,

	// per frame, latched at vblank: lines cut at the budget, rows served from the cache
	output logic [15:0] dbg_cut     = '0,
	output logic [15:0] dbg_hits    = '0,
	output logic [15:0] dbg_overrun = '0,
	// last granule received, for comparison with the ROM image
	output logic [23:3] dbg_last_addr = '0,
	output logic [63:0] dbg_last_data = '0
);

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

	// CPU writes are queued and applied at vblank_rise, so a frame renders
	// from VRAM as it stood at vblank, with the scroll latched there: MAME
	// draws the frame at vblank from both. Written live, a tile a game writes
	// mid-frame for its new scroll shows under the old one for a frame
	// (Gundhara on hardware; docs/MAME_DIVERGENCE.md, "Tile VRAM writes are
	// queued to vblank").
	//
	// The queue holds VQ_DEPTH writes. Past that, the frame's remaining writes
	// go live: the queue drains continuously, in order, until the next vblank
	// (Blandia and Mobile Suit Gundam write thousands a frame). A CPU read
	// returns VRAM as applied, so a word written this frame reads back old
	// until vblank -- except to the CPU: a read drains the queue first
	// (vram_drain / vram_busy). Blandia tests its VRAM at boot, 12288 reads a
	// layer in MAME, and read back old words it stopped with a black screen.
	localparam int VQ_DEPTH = 128;
	logic [30:0] vq_mem [0:VQ_DEPTH-1];      // {uds, lds, addr, data}
	logic  [6:0] vq_head = '0, vq_tail = '0;
	logic  [7:0] vq_count = '0, vq_allow = '0;
	logic        vq_live = 1'b0;             // overflowed this frame: drain on arrival
	logic [30:0] vq_q;
	logic        vq_pop_d = 1'b0, vq_pop_dd = 1'b0;

	wire vq_push = v_we;
	wire vq_pop  = (vq_count != 8'd0) && (vq_live || vq_allow != 8'd0 || vram_drain);
	// a popped write lands a cycle after the pop, and vram_rdata sees it a
	// cycle after that
	assign vram_busy = (vq_count != 8'd0) || vq_pop_d || vq_pop_dd;

	always_ff @(posedge clk) begin
		if (vq_push) vq_mem[vq_tail] <= {v_uds, v_lds, v_addr, v_wdata};
		vq_q <= vq_mem[vq_head];
	end

	always_ff @(posedge clk) begin
		vq_pop_d  <= vq_pop;
		vq_pop_dd <= vq_pop_d;
		if (vq_push) vq_tail <= vq_tail + 7'd1;
		if (vq_pop)  vq_head <= vq_head + 7'd1;
		vq_count <= vq_count + {7'd0, vq_push} - {7'd0, vq_pop};
		if (vblank_rise) begin
			// what was written before this vblank is this frame's
			vq_allow <= vq_count + {7'd0, vq_push} - {7'd0, vq_pop};
			vq_live  <= 1'b0;
		end else begin
			if (vq_pop && vq_allow != 8'd0) vq_allow <= vq_allow - 8'd1;
			if (vq_push && vq_count >= 8'(VQ_DEPTH - 2)) vq_live <= 1'b1;
		end
	end

	wire [12:0] vq_addr = vq_q[28:16];
	always_ff @(posedge clk) begin
		if (vq_pop_d && vq_q[29]) vram[vq_addr][7:0]  <= vq_q[7:0];
		if (vq_pop_d && vq_q[30]) vram[vq_addr][15:8] <= vq_q[15:8];
		vram_rdata <= vram[v_addr];
	end
	always_ff @(posedge clk) eng_vq <= vram[eng_vaddr];

	// vctrl[0] scroll X, [1] scroll Y, [2] bank and colour mode
	logic [15:0] vctrl [0:2];
	always_ff @(posedge clk) begin
		if (c_we && c_addr < 2'd3) begin
			if (c_lds) vctrl[c_addr][7:0]  <= c_wdata[7:0];
			if (c_uds) vctrl[c_addr][15:8] <= c_wdata[15:8];
		end
		vctrl_rdata <= vctrl[c_addr < 2'd3 ? c_addr : 2'd0];
	end

	logic       bank_sel = 1'b0;
	logic [15:0] vctrl0_lat = '0, vctrl1_lat = '0;
	always_ff @(posedge clk) if (vblank_rise) begin
		bank_sel   <= vctrl[2][3];
		cmode      <= vctrl[2][4];
		vctrl0_lat <= vctrl[0];
		vctrl1_lat <= vctrl[1];
	end
	wire [12:0] bank_off = bank_sel ? 13'h1000 : 13'h0000;

	// update_scroll:
	//     x = vctrl[0] + 0x10 - xoffsets[flip]
	//     y = vctrl[1] - (256 - vis_dimy) / 2
	wire signed [8:0] xo = flipscr ? xoffs_flip : xoffs;
	wire [15:0] sx_base = vctrl0_lat + 16'h0010 - {{7{xo[8]}}, xo};
	wire [15:0] sy_base = vctrl1_lat - {7'd0, (9'd256 - vis_dimy) >> 1};
	// if (flip) { x = -x - 512; y = y - vis_dimy; }
	wire [15:0] scroll_x_raw = flipscr ? (16'd0 - sx_base - 16'd512) : sx_base;
	wire [15:0] scroll_y_raw = flipscr ? (sy_base - {7'd0, vis_dimy}) : sy_base;

	logic [9:0] scroll_x;
	logic [8:0] scroll_y;
	logic [8:0] cur_line;
	logic       flip_l;                  // flipscr, latched per line
	logic [9:0] xe_m1;                   // xextent - 1, registered
	logic [8:0] ye_m1;
	always_ff @(posedge clk) begin
		xe_m1 <= xextent - 10'd1;
		ye_m1 <= yextent - 9'd1;
	end

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

	typedef enum logic [3:0] {
		S_IDLE, S_LATCH, S_TILE, S_TILE2, S_ATTR, S_ATTR2, S_CACHE, S_CHECK,
		S_FETCH, S_WAIT, S_FETCH2, S_WAIT2, S_BLIT, S_NEXT, S_DONE
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

	// Map pixel for screen (x, y): (x + sx, y + sy); flipped,
	// (xextent - 1 - x + sx, yextent - 1 - y + sy), the tiles drawn reversed.
	wire  [8:0] map_y   = flip_l ? (ye_m1 + scroll_y - cur_line) : (cur_line + scroll_y);
	wire  [4:0] map_row = map_y[8:4];
	wire  [3:0] row_in  = map_y[3:0];

	wire  [9:0] map_x   = flip_l ? (xe_m1 + scroll_x - px) : (px + scroll_x);
	// flipped, the tile starts 15 - map_x[3:0] left of px
	wire  [3:0] align   = flip_l ? ~map_x[3:0] : map_x[3:0];
	wire        fx      = tile_fx ^ flip_l;
	wire  [5:0] map_col = map_x[9:4];
	wire [10:0] tile_ix = {map_row, map_col};      // TILEMAP_SCAN_ROWS

	wire  [3:0] eff_row = tile_fy ? (4'd15 - row_in) : row_in;

	wire  [5:0] w0      = {eff_row[3], 2'b00, eff_row[2:0]};
	wire  [5:0] w_sel   = w0 + {chunk, 3'b000};
	// granule = (code * 64 + word) >> 2. One conditional subtract is the
	// modulo: every element count is over half the 14-bit code range
	// (zingzip's 10922 is not a power of two). Registered (timing).
	logic [15:0] tile_lim;
	wire  [15:0] tile_lim_c = (tile_code >= code_limit)
	                        ? (tile_code - code_limit) : tile_code;

	wire [21:0] word_ix = {tile_lim[13:0], 6'd0} + {16'd0, w_sel};

	// 6bpp byte offsets: tile*192 = tile*128 + tile*64, registered
	wire [13:0] code6   = tile_lim[13:0];
	logic [22:0] tile_b6;
	wire [22:0] tile_b6_c = {code6, 7'd0} + {1'b0, code6, 6'd0};
	// 96*h + 3*(y & 7)
	wire  [7:0] row_b6  = {eff_row[3], 6'd0} + {1'b0, eff_row[3], 5'd0}
	                    + {3'd0, eff_row[2:0], 1'b0} + {5'd0, eff_row[2:0]};
	wire  [6:0] chk_b6  = {chunk, 4'd0} + {1'b0, chunk, 3'd0};   // 24*chunk
	wire [22:0] byte_ix = tile_b6 + {15'd0, row_b6} + {16'd0, chk_b6};

	// three bytes from byte_ix, possibly across two granules
	wire  [2:0] sub6     = byte_ix[2:0];
	wire        strad6   = sub6 > 3'd5;

	// ROM byte i of a granule
	function automatic [7:0] gbyte(input [63:0] g, input [2:0] i);
		gbyte = g[{i, 3'd0} +: 8];
	endfunction

	// six planes, MSB first
	function automatic [5:0] pen6(input [23:0] v, input [1:0] i);
		pen6 = { v[23 - {4'd0, i}],
		         v[23 - ({4'd0, i} + 5'd4)],
		         v[23 - ({4'd0, i} + 5'd8)],
		         v[23 - ({4'd0, i} + 5'd12)],
		         v[23 - ({4'd0, i} + 5'd16)],
		         v[23 - ({4'd0, i} + 5'd20)] };
	endfunction

	function automatic [3:0] pen_of(input [15:0] w, input [1:0] i);
		pen_of = { w[15 - {3'd0, i}],
		           w[15 - ({3'd0, i} + 3'd4)],
		           w[15 - ({3'd0, i} + 4'd8)],
		           w[15 - ({3'd0, i} + 4'd12)] };
	endfunction

	wire [15:0] rom_word = word_ix[1:0] == 2'd0 ? rom_data[15:0]  :
	                       word_ix[1:0] == 2'd1 ? rom_data[31:16] :
	                       word_ix[1:0] == 2'd2 ? rom_data[47:32] :
	                                              rom_data[63:48];

	logic [4:0] blit_px;         // 0..15 within the tile

	// 6bpp chunks, and the first granule of a straddling pair
	logic [23:0] chunks6 [0:3];
	logic [63:0] gran_lo;

	// Tile row cache: the four chunks of a row depend only on the reduced code
	// and the row, so a direct-mapped cache skips the fetches for repeated
	// tiles (tile engines share an SDRAM port with the sprites and would
	// otherwise run out of line time). Entries carry an epoch that advances on
	// every reset release, so a newly loaded game never hits an old entry.
	localparam int TC_N = 64;
	logic [129:0] tcache [0:TC_N-1];          // {epoch 16, code 14, row 4, chunks 96}
	logic [129:0] tc_q, tc_wdata;
	logic   [5:0] tc_raddr, tc_waddr;
	logic         tc_we;
	logic  [15:0] tc_epoch = 16'd1;
	logic         reset_q = 1'b0;
	logic         from_cache;
	logic  [15:0] cut_acc = '0, hit_acc = '0;
	wire    [5:0] tc_idx = tile_lim[5:0] ^ tile_lim[11:6] ^ {eff_row, 2'b00};
	always_ff @(posedge clk) begin
		if (tc_we) tcache[tc_waddr] <= tc_wdata;
		tc_q <= tcache[tc_raddr];
	end
	always_ff @(posedge clk) begin
		reset_q <= reset;
		if (reset_q && !reset) tc_epoch <= tc_epoch + 16'd1;
	end

	always_ff @(posedge clk) begin
		lb_we    <= 1'b0;
		rom_req  <= 1'b0;
		line_done <= 1'b0;
		tc_we    <= 1'b0;

		if (vblank_rise) begin
			dbg_cut  <= cut_acc;  cut_acc <= '0;
			dbg_hits <= hit_acc;  hit_acc <= '0;
		end

		if (reset) begin
			state       <= S_IDLE;
			render_bank <= 1'b0;
			line_cycles <= '0;
		end else if (line_start) begin
			if (state != S_IDLE) dbg_overrun <= dbg_overrun + 16'd1;
			render_bank <= ~render_bank;
			cur_line    <= line;
			scroll_x    <= scroll_x_raw[9:0];
			scroll_y    <= scroll_y_raw[8:0];
			flip_l      <= flipscr;
			line_cycles <= '0;
			col         <= 5'd0;
			px          <= 10'd0;
			state       <= S_LATCH;
		end else begin
			if (state != S_IDLE) line_cycles <= line_cycles + 16'd1;

			if (line_budget != 16'd0 && line_cycles >= line_budget
			    && state != S_IDLE && state != S_DONE) begin
				cut_acc <= cut_acc + 16'd1;
				state   <= S_DONE;
			end else
			case (state)
			S_IDLE: ;

			S_LATCH: begin
				eng_vaddr <= bank_off + {2'd0, tile_ix};
				state     <= S_TILE;
			end

			S_TILE:  state <= S_TILE2;                // RAM latency
			S_TILE2: begin
				tile_code <= (tile_bank_en && eng_vq[13:9] == 5'h1f)
				           ? {tile_bank[{eng_vq[8:7], 3'd1} +: 7], eng_vq[6:0]}
				           : eng_vq[13:0];
				tile_fx   <= eng_vq[15];
				tile_fy   <= eng_vq[14];
				eng_vaddr <= bank_off + {2'd0, tile_ix} + 13'h800;
				state     <= S_ATTR;
			end

			S_ATTR: begin
				tile_lim <= tile_lim_c;
				state    <= S_ATTR2;
			end
			S_ATTR2: begin
				tile_color <= eng_vq[4:0];
				tile_b6    <= tile_b6_c;
				chunk      <= 2'd0;
				tc_raddr   <= tc_idx;
				from_cache <= 1'b0;
				state      <= cache_en ? S_CACHE : S_FETCH;
			end

			S_CACHE: state <= S_CHECK;                // RAM latency

			S_CHECK: begin
				if (tc_q[129:114] == tc_epoch && tc_q[113:100] == tile_lim[13:0]
				    && tc_q[99:96] == eff_row) begin
					chunks6[0] <= tc_q[23:0];   chunks6[1] <= tc_q[47:24];
					chunks6[2] <= tc_q[71:48];  chunks6[3] <= tc_q[95:72];
					chunks[0]  <= tc_q[15:0];   chunks[1]  <= tc_q[31:16];
					chunks[2]  <= tc_q[47:32];  chunks[3]  <= tc_q[63:48];
					from_cache <= 1'b1;
					hit_acc    <= hit_acc + 16'd1;
					blit_px    <= 5'd0;
					state      <= S_BLIT;
				end else
					state <= S_FETCH;
			end

			S_FETCH: begin
				rom_req  <= 1'b1;
				rom_addr <= bpp6 ? byte_ix[22:3] : {3'd0, word_ix[21:2]};
				state    <= S_WAIT;
			end

			// second granule of a straddling 6bpp chunk
			S_FETCH2: begin
				rom_req  <= 1'b1;
				rom_addr <= byte_ix[22:3] + 20'd1;
				state    <= S_WAIT2;
			end

			S_WAIT2: if (rom_valid) begin
				chunks6[chunk] <= sub6 == 3'd6
				    ? {gbyte(gran_lo, 3'd6), gbyte(gran_lo, 3'd7),
				       gbyte(rom_data, 3'd0)}
				    : {gbyte(gran_lo, 3'd7), gbyte(rom_data, 3'd0),
				       gbyte(rom_data, 3'd1)};
				if (chunk == 2'd3) begin
					blit_px <= 5'd0;
					state   <= S_BLIT;
				end else begin
					chunk <= chunk + 2'd1;
					state <= S_FETCH;
				end
			end

			S_WAIT: if (rom_valid) begin
				dbg_last_addr <= rom_addr;
				dbg_last_data <= rom_data;
				// word 0 in the low bits; SDRAM words are {odd, even}, the ROM big-endian
				chunks[chunk] <= { rom_word[7:0], rom_word[15:8] };
				if (bpp6) begin
					gran_lo <= rom_data;
					chunks6[chunk] <= {gbyte(rom_data, sub6),
					                   gbyte(rom_data, sub6 + 3'd1),
					                   gbyte(rom_data, sub6 + 3'd2)};
				end
				if (bpp6 && strad6) begin
					state <= S_FETCH2;
				end else if (chunk == 2'd3) begin
					blit_px <= 5'd0;
					state   <= S_BLIT;
				end else begin
					chunk <= chunk + 2'd1;
					state <= S_FETCH;
				end
			end

			// sixteen pixels, one per cycle
			S_BLIT: begin
				// an SDRAM row enters the cache on the first pixel
				if (blit_px == 5'd0 && cache_en && !from_cache) begin
					tc_we    <= 1'b1;
					tc_waddr <= tc_raddr;
					tc_wdata <= {tc_epoch, tile_lim[13:0], eff_row,
					             bpp6 ? {chunks6[3], chunks6[2], chunks6[1], chunks6[0]}
					                  : {32'd0, chunks[3], chunks[2], chunks[1], chunks[0]}};
				end
				lb_we    <= 1'b1;
				lb_waddr <= px[8:0] + {5'd0, blit_px[3:0]}
				            - {5'd0, align};        // align to the tile edge
				// flipped: source chunk j>>2, pixel 3 - (j & 3). 6bpp colour steps by 64.
				lb_wdata <= bpp6
				    ? colorbase + {tile_color, 6'd0}
				      + {5'd0, pen6(chunks6[fx ? blit_px[3:2]
				                                    : (2'd3 - blit_px[3:2])],
				                    fx ? (2'd3 - blit_px[1:0])
				                            : blit_px[1:0])}
				    : colorbase + {2'd0, tile_color, 4'd0}
				      + {7'd0, pen_of(chunks[fx ? blit_px[3:2]
				                                     : (2'd3 - blit_px[3:2])],
				                      fx ? (2'd3 - blit_px[1:0])
				                              : blit_px[1:0])};
				if (blit_px == 5'd15) state <= S_NEXT;
				else blit_px <= blit_px + 5'd1;
			end

			S_NEXT: begin
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
