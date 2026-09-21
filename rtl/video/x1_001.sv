// X1-001A / X1-002A sprites and the sprite-built "floating tilemap", one
// scanline ahead into a double line buffer. Reference: scripts/x1_001_model.py
// (MAME's video/x1_001.cpp), checked by sim/x1_001_tb.
//
// draw_background: 16 columns x 32 tiles from spritecode[0x400..], per-column
// scroll. draw_foreground: up to 512 sprites from spritecode[0x000..], entry 0
// on top. This engine walks front to back (foreground from entry 0, then the
// background columns in reverse) and the line buffer's written bit makes the
// first writer win; a line out of time (line_budget) drops the bottom-most.
//
// Per scanline L, MAME's four wrap copies reduce to:
//   fg: covered iff ((L + Y) & 0xff) < 16, Y = (sy + fg_yoffs) & 0xff
//   bg: row r = (L - S0) >> 4, S0 = -(scrolly + bg_yoffs)
//   x:  (sx + xoffs) & 0x1ff on a 512-wide buffer
//
// Bank: (ctrl2 ^ (~ctrl2 << 1)) & 0x40, i.e. bits 6 and 5 of spritectrl[1]
// equal. setac_eof (buffer_sprites) copies half to half at vblank when bit 5
// is clear, through the engine's read port. The engine renders from a snapshot
// of the RAMs (the code words it reads, and Y); a CPU write during it holds it.
// When the snapshot is taken depends on the board (the setac_eof comment).
//
// A sprite row is one ROM granule after gfx_swizzle.sv: rom_data words are
// half1 xh=0, half1 xh=1, half2 xh=0, half2 xh=1, low to high.
//
// m_bgflag (opaque background) is an input only; no in-scope map writes it.

`default_nettype none

module x1_001 #(
		// palette index width
	parameter int LB_W = 11
) (
	input  wire         clk,
	input  wire         reset,

	// CPU side, registered in (maincpu reads in the third io cycle)
	input  wire         code_we,
	input  wire  [12:0] code_addr,      // word address into 0x2000 words
	input  wire  [15:0] code_wdata,
	input  wire         code_uds, code_lds,
	output logic [15:0] code_rdata,

	// spriteylow: bytes; the high byte of a word write is dropped
	input  wire         ylow_we,
	input  wire   [9:0] ylow_addr,
	input  wire   [7:0] ylow_wdata,
	output logic  [7:0] ylow_rdata,

	input  wire         ctrl_we,
	input  wire   [1:0] ctrl_addr,
	input  wire   [7:0] ctrl_wdata,
	output logic  [7:0] ctrl_rdata,

	// board configuration (machine_config / GFXDECODE)
	input  wire signed [8:0] fg_xoffs,      // set_fg_xoffsets(flip, noflip)
	input  wire signed [8:0] fg_xoffs_flip,
	input  wire signed [8:0] fg_yoffs,      // set_fg_yoffsets(flip, noflip)
	input  wire signed [8:0] fg_yoffs_flip,
	input  wire signed [8:0] bg_xoffs,      // set_bg_xoffsets(flip, noflip)
	input  wire signed [8:0] bg_xoffs_flip,
	input  wire signed [8:0] bg_yoffs,      // set_bg_yoffsets(flip, noflip)
	input  wire signed [8:0] bg_yoffs_flip,
	input  wire  [12:0] bank_size,          // draw_sprites()'s argument, 0x1000
	input  wire   [8:0] spritelimit,        // m_spritelimit, 0x1ff
	input  wire   [3:0] transpen,           // m_transpen, 0
	input  wire         bgflag_opaque,      // m_bgflag & 0x80 -- always 0 in scope
	// screen_vblank_seta_buffer_sprites
	input  wire         buffer_sprites,
	// VIDEO_UPDATE_AFTER_VBLANK: MAME runs the copy, then draws
	input  wire         copy_then_draw,
	// a pulse as seta_board_cfg's spr_snap_line begins: a line where a game
	// that writes its list all frame does not write
	input  wire         snap_at_line,
	// the board takes its snapshot at that line ONLY (seta_board_cfg /
	// downtown_board_cfg spr_snap_line nonzero). Without this the line was
	// an extra trigger beside the usual one, and the usual one -- later in
	// vblank -- overwrote it every frame (tndrcade, calibr50).
	input  wire         snap_line_mode,
	input  wire         vblank_rise,
	// snapshot, late in vblank (unbuffered boards)
	input  wire         snap_start,
	// snapshot, ending before vblank (buffered, draw-then-copy boards)
	input  wire         snap_pre,
	input  wire [LB_W-1:0] colorbase_fg,    // gfx colorbase + m_colorbase*16
	input  wire [LB_W-1:0] colorbase_bg,    // gfx colorbase alone
	input  wire   [8:0] screen_h,           // screen.height() -- 256, NOT 240
	input  wire   [8:0] vis_max_y,          // visible_area().max_y
	input  wire [LB_W-1:0] backdrop,        // the bitmap.fill() before drawing
	input  wire  [15:0] code_mask,          // tiles-per-half minus one
	// per-line cycle limit; 0 = none (model comparison)
	input  wire  [15:0] line_budget,

	// line_start names the line to render into the undisplayed buffer
	input  wire         line_start,
	input  wire   [8:0] line,
	output logic        line_done,
	output logic        busy,

	// sprite ROM: rom_req pulses, rom_addr (a granule) held until rom_valid
	output logic        rom_req,
	output logic [23:3] rom_addr,
	input  wire         rom_valid,
	input  wire  [63:0] rom_data,

	input  wire   [8:0] lb_addr,
	output logic [LB_W-1:0] lb_data,
	// a sprite wrote this dot
	output logic        lb_hit,
	// is_flipped(); the tile layers take their flip from it
	output wire         flipscr_out,

	// counters: port initialisers, saturating, not reset
	output logic [15:0] dbg_lines   = '0,
	output logic [15:0] dbg_sprites = '0,   // sprites blitted, saturating
	output logic [15:0] dbg_fetches = '0,   // ROM words read, saturating
	output logic [15:0] dbg_overrun = '0,   // lines still rendering at the next start
	// worst line in clk_sys cycles (a line is 6144)
	output logic [15:0] dbg_worst_line    = '0,   // clk_sys cycles, line_start to done
	output logic [15:0] dbg_worst_sprites = '0,   // sprites blitted in one line
	output logic [15:0] dbg_dropped       = '0,   // lines cut short by line_budget
	// {max, last} line of the last CPU sprite write before a snapshot, frames
	// with a CPU sprite write during setac_eof or the snapshot, code writes
	// dropped under the setac_eof copy
	output logic [63:0] dbg_snap          = '0
);

	// Chip RAM: one write and one read port each (block RAM inference).
	logic [15:0] codemem [0:8191];
	logic  [7:0] ylowmem [0:1023];
	logic  [7:0] ctrlmem [0:3];

	// Snapshot copies the engine renders from, taken before any setac_eof copy.
	// Games rewrite the list mid-frame (daioh, eightfrc at line 112); MAME draws
	// at vblank.
	// The engine reads one 0x800-word half of the code RAM (bank_off + 0..0x7ff)
	// and the 1024 Y bytes. The codes are held twice: a frame draws from one
	// copy while the other is filled, so a snapshot taken mid-frame (a
	// hand-flipped page, below) cannot tear it. One array a byte lane:
	// Quartus 17 infers no RAM for a byte-enabled array whose write index is
	// the complement of its read index.
	logic  [7:0] codesh_lo [0:4095];    // {buf, addr[10:0]}
	logic  [7:0] codesh_hi [0:4095];
	logic  [7:0] ylowsh [0:1023];
	logic        rbuf = 1'b0;           // the code copy the engine reads
	wire         wbuf = ~rbuf;
	// the half the chip draws from, live: (ctrl2 ^ (~ctrl2 << 1)) & 0x40
	wire         live_use_bank = ((ctrlmem[1] ^ (~ctrlmem[1] << 1)) & 8'h40) != 8'h00;
	wire         live_bank     = live_use_bank && bank_size[12];
	logic  [7:0] ctrlsh [0:3];
	logic [15:0] live_code_q;
	logic  [7:0] live_ylow_q;

	logic [12:0] eng_code_addr;
	logic  [9:0] eng_ylow_addr;
	logic [15:0] eng_code_q;
	logic  [7:0] eng_ylow_q;

	logic        c_we, c_uds, c_lds;
	logic [12:0] c_addr;
	logic [15:0] c_wdata;
	logic        y_we;
	logic  [9:0] y_addr;
	logic  [7:0] y_wdata;
	logic        k_we;
	logic  [1:0] k_addr;
	logic  [7:0] k_wdata;

	always_ff @(posedge clk) begin
		c_we <= code_we; c_addr <= code_addr; c_wdata <= code_wdata;
		c_uds <= code_uds; c_lds <= code_lds;
		y_we <= ylow_we; y_addr <= ylow_addr; y_wdata <= ylow_wdata;
		k_we <= ctrl_we; k_addr <= ctrl_addr; k_wdata <= ctrl_wdata;
	end

	// spritectrl[1], live: setac_eof reads it at vblank
	wire [7:0] eof_ctrl = ctrlmem[1];

	// setac_eof, at vblank, in MAME's order for the board
	// (docs/MAME_DIVERGENCE.md, "setac_eof: the copy and the draw").
	// Draw-then-copy boards (drgnunit, stg, qzkklogy, qzkklgy2, msgundam): MAME
	// draws at vblank start from the RAM as it stands, then copies. The
	// snapshot runs on the line before vblank (snap_pre, 5120 cycles, under a
	// line) and the copy at vblank, so writes the game makes from line 248 on
	// reach neither (Strike Gunner writes its list from line 248).
	// Copy-then-draw boards (blandia, blandiap: VIDEO_UPDATE_AFTER_VBLANK): the
	// copy runs at vblank and the snapshot straight after it.
	logic        eof_busy = 1'b0, eof_pending = 1'b0;
	logic        snap_done, eof_done;
	logic        snap_pending = 1'b0, snap_busy = 1'b0;
	logic [10:0] eof_i;
	logic        eof_dir;              // ctrl2 bit 6: 1 = 0x1000 -> 0x0000
	// word offsets: the halves are 0x1000 apart
	logic        eof_wr;
	logic [12:0] eof_waddr;

	wire [12:0] eof_src = { eof_dir, 1'b0, eof_i};
	wire [12:0] eof_dst = {~eof_dir, 1'b0, eof_i};

	always_ff @(posedge clk) begin
		eof_wr   <= 1'b0;
		eof_done <= 1'b0;
		if (reset) begin
			eof_busy    <= 1'b0;
			eof_pending <= 1'b0;
		end else if (!eof_busy) begin
			if (vblank_rise && buffer_sprites) eof_pending <= 1'b1;
			// ~ctrl2 & 0x20, read when the copy starts
			if (eof_pending && (copy_then_draw || (!snap_busy && !snap_pending))) begin
				eof_pending <= 1'b0;
				if (!eof_ctrl[5]) eof_busy <= 1'b1;
				eof_dir  <= eof_ctrl[6];
				eof_i    <= 11'd0;
			end
		end else begin
			eof_wr    <= 1'b1;
			eof_waddr <= eof_dst;
			if (eof_i == 11'h7ff) begin
				eof_busy <= 1'b0;
				eof_done <= 1'b1;
			end
			else eof_i <= eof_i + 11'd1;
		end
	end

	// A HAND-FLIPPED PAGE. With setac_eof disabled (spritectrl[1] bit 5 set)
	// the game owns the two halves and flips bit 6 -- the half the chip draws
	// -- itself, once the half it is about to show is written. 26 of the 31
	// parents do this, once a frame, some mid-frame (stg at line 113), some in
	// vblank (scripts/sprctrl_scan.py). MAME draws at vblank from the half
	// selected then, as it stands then; the game may keep writing other halves
	// right through the frame (stg does), so there is no settled moment to
	// copy both. So for such a game the codes are copied at the flip, from the
	// half it selects; CPU writes to that half keep reaching the copy until
	// vblank, when the engine moves to it. Y (one buffer, stg rewrites it from
	// line 113 to 240) and the control bytes are still taken at the board's
	// usual point.
	wire page_flip = k_we && k_addr == 2'd1 && k_wdata[5]
	              && (k_wdata[6] != ctrlmem[1][6]);
	logic own_flip = 1'b0;              // the game flips its own pages
	always_ff @(posedge clk)
		if (reset) own_flip <= 1'b0;
		else if (page_flip) own_flip <= 1'b1;
		else if (k_we && k_addr == 2'd1 && !k_wdata[5]) own_flip <= 1'b0;

	// Snapshot: the 0x800 code words of the drawn half then the 1024 Y bytes,
	// one a cycle: 3072 cycles. The codes fill the spare copy, and rbuf moves
	// to it when the frame it belongs to starts (below). A flip snapshot is
	// the codes alone; with own_flip the usual one is the Y bytes alone.
	// A CPU write during the copy holds it for that cycle, so the word is re-read
	// after the write.
	logic [13:0] snap_i, snap_wi;
	logic        snap_wr_code, snap_wr_ylow;
	logic        snap_bank;             // the half this copy came from
	logic        snap_ready = 1'b0;     // flip copy filled, waiting for vblank
	logic        snap_flip  = 1'b0;     // this snapshot is a flip's
	logic        flip_pending = 1'b0;
	wire         snap_hold = snap_busy && ((c_we && (c_uds || c_lds)) || y_we);
	always_ff @(posedge clk) begin
		snap_wr_code <= 1'b0;
		snap_wr_ylow <= 1'b0;
		snap_done    <= 1'b0;
		if (reset) begin
			snap_pending <= 1'b0;
			flip_pending <= 1'b0;
			snap_busy    <= 1'b0;
			snap_flip    <= 1'b0;
		end else begin
			if (snap_line_mode ? snap_at_line
			    : !buffer_sprites ? snap_start
			    : copy_then_draw ? eof_done : snap_pre) snap_pending <= 1'b1;
			if (page_flip) flip_pending <= 1'b1;
			if (snap_busy) begin
				if (!snap_hold) begin
					snap_wi      <= snap_i;
					snap_wr_code <= (snap_i < 14'h800);
					snap_wr_ylow <= (snap_i >= 14'h800);
					if (snap_i == (snap_flip ? 14'h7ff : 14'hbff)) begin
						snap_busy <= 1'b0;
						snap_done <= 1'b1;
					end
					else snap_i <= snap_i + 14'd1;
				end
			end else if (flip_pending && !eof_busy) begin
				// the codes of the half the flip selects
				flip_pending <= 1'b0;
				snap_busy    <= 1'b1;
				snap_flip    <= 1'b1;
				snap_i       <= 14'd0;
				snap_bank    <= live_bank;
			end else if (snap_pending && !eof_busy) begin
				snap_pending <= 1'b0;
				snap_busy    <= 1'b1;
				snap_flip    <= 1'b0;
				snap_i       <= own_flip ? 14'h800 : 14'd0;
				snap_bank    <= live_bank;
				ctrlsh[0] <= ctrlmem[0]; ctrlsh[1] <= ctrlmem[1];
				ctrlsh[2] <= ctrlmem[2]; ctrlsh[3] <= ctrlmem[3];
			end
			// control bytes are flops: a write during the copy goes to both
			if (snap_busy && !snap_flip && k_we) ctrlsh[k_addr] <= k_wdata;
		end
	end

	// one muxed write address, one always block (block RAM inference)
	wire [12:0] cw_addr = eof_wr ? eof_waddr  : c_addr;
	wire [15:0] cw_data = eof_wr ? live_code_q : c_wdata;
	wire        cw_lo   = eof_wr ? 1'b1 : (c_we && c_lds);
	wire        cw_hi   = eof_wr ? 1'b1 : (c_we && c_uds);

	always_ff @(posedge clk) begin
		if (cw_lo) codemem[cw_addr][7:0]  <= cw_data[7:0];
		if (cw_hi) codemem[cw_addr][15:8] <= cw_data[15:8];
		code_rdata <= codemem[c_addr];
	end

	// snap_i[11] is 0 while codes are copied. Not a constant 1'b0: with a
	// constant address bit Quartus 17 builds this second read port of codemem
	// from registers (64 Kbit of them) instead of a second RAM copy.
	wire [12:0] live_rd_addr  = eof_busy ? eof_src
	                                     : {snap_bank, snap_i[11:0]};
	always_ff @(posedge clk) live_code_q <= codemem[live_rd_addr];
	always_ff @(posedge clk) eng_code_q[7:0]  <= codesh_lo[{rbuf, eng_code_addr[10:0]}];
	always_ff @(posedge clk) eng_code_q[15:8] <= codesh_hi[{rbuf, eng_code_addr[10:0]}];

	// The engine moves to new codes when the board's usual snapshot -- the Y
	// bytes and control -- lands, so codes and Y always change together. That
	// snapshot's own codes, or with own_flip the last flip copy. Mad Shark
	// writes its list and flips in the first lines of vblank, before the
	// usual snapshot: moving at vblank_rise instead paired its new Y with the
	// old codes for a frame (hardware, 9d830c7). A flip after the usual
	// snapshot waits for the next one.
	always_ff @(posedge clk) begin
		if (reset) begin
			rbuf       <= 1'b0;
			snap_ready <= 1'b0;
		end else if (snap_done) begin
			if (snap_flip) snap_ready <= 1'b1;
			else if (!own_flip || snap_ready) begin
				rbuf       <= ~rbuf;
				snap_ready <= 1'b0;
			end
		end
	end

	// Shadow write port: the snapshot's, except on a CPU write to the half it
	// is copying -- a write behind the cursor would otherwise be left out --
	// and, for a flip copy, until the engine moves to it.
	wire        c_in_half  = (c_addr[12] == snap_bank) && !c_addr[11];
	wire        shc_open   = snap_busy ? (snap_flip || !own_flip) : snap_ready;
	wire        shc_cpu    = shc_open && c_we && c_in_half;
	wire [11:0] shc_addr   = shc_cpu ? {wbuf, c_addr[10:0]} : {wbuf, snap_wi[10:0]};
	wire [15:0] shc_data   = shc_cpu ? c_wdata : live_code_q;
	wire        shc_lo     = shc_cpu ? c_lds : snap_wr_code;
	wire        shc_hi     = shc_cpu ? c_uds : snap_wr_code;
	always_ff @(posedge clk) if (shc_lo) codesh_lo[shc_addr] <= shc_data[7:0];
	always_ff @(posedge clk) if (shc_hi) codesh_hi[shc_addr] <= shc_data[15:8];

	always_ff @(posedge clk) begin
		if (y_we) ylowmem[y_addr] <= y_wdata;
		ylow_rdata <= ylowmem[y_addr];
	end
	always_ff @(posedge clk) live_ylow_q <= ylowmem[snap_i[9:0]];
	always_ff @(posedge clk) eng_ylow_q  <= ylowsh[eng_ylow_addr];
	wire        shy_cpu  = snap_busy && !snap_flip && y_we;
	wire  [9:0] shy_addr = shy_cpu ? y_addr : snap_wi[9:0];
	wire  [7:0] shy_data = shy_cpu ? y_wdata : live_ylow_q;
	always_ff @(posedge clk)
		if (shy_cpu || snap_wr_ylow) ylowsh[shy_addr] <= shy_data;

	always_ff @(posedge clk) begin
		if (k_we) ctrlmem[k_addr] <= k_wdata;
		ctrl_rdata <= ctrlmem[k_addr];
	end

	// the engine uses the snapshot's control bytes
	wire [7:0] ctrl0 = ctrlsh[0];
	wire [7:0] ctrl1 = ctrlsh[1];
	wire [7:0] ctrl2 = ctrlsh[2];
	wire [7:0] ctrl3 = ctrlsh[3];

	// Two 512-entry line buffers of {written, pen}. The engine renders into one
	// while the video reads the other, so each needs one read address (muxed).
	localparam int LBE = LB_W + 1;
	logic [LBE-1:0] lbuf0 [0:511];
	logic [LBE-1:0] lbuf1 [0:511];
	logic           render_bank = 1'b0;

	logic           lb_we;
	logic     [8:0] lb_waddr;
	logic [LBE-1:0] lb_wdata;
	logic     [8:0] blit_raddr;          // the engine's read-modify-write probe

	wire  [8:0] rd0 = render_bank ? lb_addr : blit_raddr;
	wire  [8:0] rd1 = render_bank ? blit_raddr : lb_addr;

	logic [LBE-1:0] lb_q0, lb_q1;
	logic           disp_bank;
	always_ff @(posedge clk) begin
		if (lb_we && !render_bank) lbuf0[lb_waddr] <= lb_wdata;
		lb_q0 <= lbuf0[rd0];
	end
	always_ff @(posedge clk) begin
		if (lb_we && render_bank) lbuf1[lb_waddr] <= lb_wdata;
		lb_q1 <= lbuf1[rd1];
	end
	// video reads the buffer not being rendered, a cycle late for the RAM
	always_ff @(posedge clk) disp_bank <= ~render_bank;
	assign lb_data = disp_bank ? lb_q1[LB_W-1:0] : lb_q0[LB_W-1:0];
	assign lb_hit  = disp_bank ? lb_q1[LB_W]     : lb_q0[LB_W];
	wire [LBE-1:0] blit_q = render_bank ? lb_q1 : lb_q0;

	wire        use_bank = ((ctrl1 ^ (~ctrl1 << 1)) & 8'h40) != 8'h00;
	wire [12:0] bank_off = use_bank ? bank_size : 13'd0;
	wire        flipscr  = ctrl0[6];
	assign flipscr_out = flipscr;

	wire signed [8:0] fgx = flipscr ? fg_xoffs_flip : fg_xoffs;
	wire signed [8:0] fgy = flipscr ? fg_yoffs_flip : fg_yoffs;
	wire signed [8:0] bgx = flipscr ? bg_xoffs_flip : bg_xoffs;
	wire signed [8:0] bgy = flipscr ? bg_yoffs_flip : bg_yoffs;

	wire  [3:0] numcol_raw = ctrl1[3:0];
	wire  [4:0] numcol     = (numcol_raw == 4'd1) ? 5'd16 : {1'b0, numcol_raw};
	wire  [3:0] startcol   = (ctrl0[0] ? 4'd4 : 4'd0) + (ctrl0[1] ? 4'd8 : 4'd0);
	wire [15:0] upper      = {ctrl3, ctrl2};

	typedef enum logic [4:0] {
		S_IDLE,
		S_CLEAR,
		S_BG_S0, S_BG_S1, S_BG_S2, S_BG_S3,
		S_BG_E0, S_BG_E1, S_BG_E2,
		S_FG_PRIME, S_FG_SCAN, S_FG_E0, S_FG_E1, S_FG_E2,
		S_FETCH, S_FWAIT,
		S_BLIT,
		S_NEXT_BG, S_NEXT_FG,
		S_DONE
	} state_t;
	state_t state = S_IDLE;

	logic  [8:0] cur_line;
	logic  [9:0] clr_addr;

	logic  [4:0] bg_col;
	logic        bg_sub;
	logic  [7:0] bg_scrolly, bg_scrollx;
	logic  [3:0] bg_r, bg_row;

	// Foreground scan pipeline: one entry issued per cycle; its Y byte is
	// tested two cycles later (d2). On a hit the two in flight are rescanned.
	logic  [9:0] issue_i, d1_i, d2_i;
	logic        issue_v, d1_v, d2_v;
	logic  [9:0] fg_hit_i;
	logic  [3:0] fg_row;

	// sprite being drawn; 16-bit tile (gfxbank adds bank * 0x4000)
	logic [15:0] spr_tile;
	logic        spr_flipx;
	logic  [3:0] spr_row;            // AFTER flipy
	logic  [8:0] spr_x;
	logic [LB_W-1:0] spr_cbase;
	logic        spr_is_bg;

	logic [15:0] line_cycles, line_sprites;
	logic [63:0] row;                  // one sprite row, all four plane words
	logic  [4:0] blit_px;

	// Blit: read-modify-write on the line buffer (first writer wins), probe at
	// stage 0, write at stage 2.
	logic [8:0] p1_x, p2_x;
	logic [3:0] p1_pen, p2_pen;
	logic       p1_v, p2_v;

	// swizzled row granule: {tile, yh, yl}
	wire [23:3] row_granule = {1'b0, (spr_tile & code_mask), spr_row};

	// One-entry row cache: repeated rows (parked entries all use one tile) skip
	// the ROM fetch.
	logic        rc_v = 1'b0;
	logic [23:3] rc_addr;
	logic [63:0] rc_data;
	// an all-zero row draws nothing when pen 0 is transparent
	wire         row_blank = (transpen == 4'd0) && !(spr_is_bg && bgflag_opaque);

	// pen[3] = half2 odd byte, pen[2] = half2 even, pen[1] = half1 odd,
	// pen[0] = half1 even (planeoffset order; SDRAM words are {odd, even})
	wire  [3:0] src_x = spr_flipx ? (4'd15 - blit_px[3:0]) : blit_px[3:0];
	wire  [2:0] bitn  = 3'd7 - src_x[2:0];
	wire [15:0] wa    = src_x[3] ? row[31:16] : row[15:0];    // half1, this xh
	wire [15:0] wb    = src_x[3] ? row[63:48] : row[47:32];   // half2, same xh
	wire  [3:0] pen   = { wb[{1'b1, bitn}], wb[{1'b0, bitn}],
	                      wa[{1'b1, bitn}], wa[{1'b0, bitn}] };
	wire  [8:0] blit_x = spr_x + {5'd0, blit_px[3:0]};

	// Foreground hit, pre-added (timing), mod 256:
	//     fg_d = cur_line + fgy + sy                               unflipped
	//     fg_d = cur_line + fgy + 2*screen_h - vis_max_y - 1 - sy  flipped
	// fg_base is registered once per line.
	logic [7:0] fg_base;
	always_ff @(posedge clk)
		fg_base <= flipscr
		    ? (cur_line[7:0] + fgy[7:0] + screen_h[7:0] + screen_h[7:0]
		       - vis_max_y[7:0] - 8'd1)
		    : (cur_line[7:0] + fgy[7:0]);

	wire  [7:0] fg_d   = flipscr ? (fg_base - eng_ylow_q)
	                             : (fg_base + eng_ylow_q);
	wire        fg_hit = (fg_d[7:4] == 4'd0);

	// background row: S0 + 16r, or 0xf0 - (S0 + 16r) flipped; exactly one r
	// covers the line
	wire  [7:0] bg_S0 = -(bg_scrolly + bgy[7:0]);
	wire  [7:0] bg_f  = cur_line[7:0] - bg_S0;              // unflipped
	wire  [7:0] bg_e  = cur_line[7:0] - 8'hf0 + bg_S0;      // flipped
	wire  [3:0] bg_sel_r   = flipscr ? (4'd0 - bg_e[7:4]) : bg_f[7:4];
	wire  [3:0] bg_sel_row = flipscr ? bg_e[3:0]          : bg_f[3:0];

	wire  [3:0] bg_ent_i     = (bg_col[3:0] + startcol);
	wire  [4:0] bg_offs      = {bg_r, bg_sub};
	wire [12:0] bg_code_addr = {4'd0, bg_ent_i, bg_offs} + 13'h400 + bank_off;
	wire [12:0] bg_attr_addr = {4'd0, bg_ent_i, bg_offs} + 13'h600 + bank_off;

	// fg sx = attr[8:0] as signed, then (sx + xoffs) & 0x1ff
	wire signed [9:0] fg_sx = $signed({eng_code_q[8], eng_code_q[8:0]});
	wire        [8:0] fg_px = fg_sx[8:0] + fgx[8:0];
	// bg sx = scrollx + xoffs + (offs & 1) * 16, less 256 if the column's upper bit is set
	wire        [8:0] bg_px = {1'b0, bg_scrollx} + bgx[8:0]
	                        + (bg_sub ? 9'd16 : 9'd0)
	                        + (upper[bg_col[3:0]] ? 9'h100 : 9'd0);

	function automatic logic [15:0] sat_inc(input logic [15:0] v);
		sat_inc = (v == 16'hFFFF) ? v : v + 16'd1;
	endfunction

	logic [8:0] wr_line = '0;
	logic       wr_in_window = 1'b0, snap_busy_d = 1'b0;
	wire        spr_wr = (c_we && (c_uds || c_lds)) || y_we;
	always_ff @(posedge clk) begin
		snap_busy_d <= snap_busy;
		if (spr_wr) wr_line <= line;
		if (eof_wr && c_we && (c_uds || c_lds)) dbg_snap[15:0] <= sat_inc(dbg_snap[15:0]);
		if (spr_wr && (eof_busy || snap_pending || snap_busy)) wr_in_window <= 1'b1;
		if (snap_busy_d && !snap_busy) begin
			if (wr_in_window) dbg_snap[31:16] <= sat_inc(dbg_snap[31:16]);
			wr_in_window <= 1'b0;
		end
		if (snap_start) begin
			dbg_snap[47:32] <= {7'd0, wr_line};
			if ({7'd0, wr_line} > dbg_snap[63:48]) dbg_snap[63:48] <= {7'd0, wr_line};
		end
	end

	assign busy     = (state != S_IDLE);
	assign rom_addr = row_granule;

	always_ff @(posedge clk) begin
		line_done <= 1'b0;
		lb_we     <= 1'b0;
		rom_req   <= 1'b0;

		if (reset) begin
			state       <= S_IDLE;
			rc_v        <= 1'b0;   // a new ROM may be loaded under a reset
			render_bank <= 1'b0;
			line_cycles <= 16'd0;
		end else if (line_start) begin
			// counted; the new line starts anyway
			if (state != S_IDLE) dbg_overrun <= sat_inc(dbg_overrun);
			dbg_lines   <= sat_inc(dbg_lines);
			render_bank <= ~render_bank;
			cur_line     <= line;
			clr_addr     <= 10'd0;
			line_cycles  <= 16'd0;
			line_sprites <= 16'd0;
			state        <= S_CLEAR;
		end else begin
			if (state != S_IDLE) line_cycles <= sat_inc(line_cycles);

			// out of time: stop and display what is drawn (never mid-clear)
			if (line_budget != 16'd0 && line_cycles >= line_budget
			    && state != S_IDLE && state != S_CLEAR && state != S_DONE) begin
				dbg_dropped <= sat_inc(dbg_dropped);
				state <= S_DONE;
			end else
			case (state)

			S_IDLE: ;

			// fill with the backdrop pen (bitmap.fill(0x1f0))
			S_CLEAR: begin
				lb_we    <= 1'b1;
				lb_waddr <= clr_addr[8:0];
				lb_wdata <= {1'b0, backdrop};      // nothing written here yet
				clr_addr <= clr_addr + 10'd1;
				if (clr_addr == 10'd511) begin
					issue_i <= 10'd0;
					state   <= S_FG_PRIME;
				end
			end

			// background column: scrolly = ylow[0x200 + col*0x10], scrollx = +4
			S_BG_S0: begin
				eng_ylow_addr <= 10'h200 + {2'd0, bg_col[3:0], 4'd0};
				state <= S_BG_S1;
			end
			S_BG_S1: begin
				eng_ylow_addr <= 10'h204 + {2'd0, bg_col[3:0], 4'd0};
				state <= S_BG_S2;
			end
			S_BG_S2: begin
				bg_scrolly <= eng_ylow_q;
				state      <= S_BG_S3;
			end
			S_BG_S3: begin
				bg_scrollx <= eng_ylow_q;
				bg_r       <= bg_sel_r;
				bg_row     <= bg_sel_row;
				bg_sub     <= 1'b1;      // MAME draws offs 2r then 2r+1
				state      <= S_BG_E0;
			end

			S_BG_E0: begin
				eng_code_addr <= bg_code_addr;
				state <= S_BG_E1;
			end
			S_BG_E1: begin
				eng_code_addr <= bg_attr_addr;
				state <= S_BG_E2;
			end
			S_BG_E2: begin
				spr_tile  <= {2'b00, eng_code_q[13:0]};   // code &= 0x3fff, no bank
				spr_flipx <= eng_code_q[15] ^ flipscr;
				spr_row   <= (eng_code_q[14] ^ flipscr) ? (4'd15 - bg_row) : bg_row;
				spr_x     <= bg_px;
				spr_is_bg <= 1'b1;
				state     <= S_FETCH;
			end

			S_FG_PRIME: begin
				eng_ylow_addr <= issue_i;
				d1_i  <= issue_i;  d1_v <= 1'b1;
				d2_v  <= 1'b0;
				issue_v <= (issue_i != {1'b0, spritelimit});
				issue_i <= issue_i + 10'd1;
				state <= S_FG_SCAN;
			end
			S_FG_SCAN: begin
				// eng_ylow_q is ylow[d2_i]; the test reads the old d2_*
				eng_ylow_addr <= issue_i;
				d1_i <= issue_i;  d1_v <= issue_v;
				d2_i <= d1_i;     d2_v <= d1_v;
				if (issue_v) begin
					issue_v <= (issue_i != {1'b0, spritelimit});
					issue_i <= issue_i + 10'd1;
				end

				if (d2_v && fg_hit) begin
					fg_hit_i      <= d2_i;
					fg_row        <= fg_d[3:0];
					eng_code_addr <= {3'd0, d2_i} + bank_off;
					state         <= S_FG_E0;
				end else if (!issue_v && !d1_v && !d2_v) begin
					bg_col <= numcol - 5'd1;
					state  <= (numcol == 5'd0) ? S_DONE : S_BG_S0;
				end
			end
			S_FG_E0: begin
				eng_code_addr <= {3'd0, fg_hit_i} + 13'h200 + bank_off;
				state <= S_FG_E1;
			end
			S_FG_E1: begin
				spr_tile  <= {2'b00, eng_code_q[13:0]};
				spr_flipx <= eng_code_q[15] ^ flipscr;
				spr_row   <= (eng_code_q[14] ^ flipscr) ? (4'd15 - fg_row) : fg_row;
				state     <= S_FG_E2;
			end
			S_FG_E2: begin
				// attribute: colour 15:11, x 8:0, gfx bank 10:9
				// (setac_gfxbank_callback: code += ((color & 6) >> 1) * 0x4000)
				spr_tile  <= {eng_code_q[10:9], spr_tile[13:0]};
				spr_x     <= fg_px;
				spr_cbase <= colorbase_fg
				           + {{(LB_W - 9){1'b0}}, eng_code_q[15:11], 4'd0};
				spr_is_bg <= 1'b0;
				state     <= S_FETCH;
			end

			S_FETCH: begin
				// background colour uses colorbase_bg
				if (spr_is_bg)
					spr_cbase <= colorbase_bg
					           + {{(LB_W - 9){1'b0}}, eng_code_q[15:11], 4'd0};
				blit_px <= 5'd0;
				p1_v <= 1'b0; p2_v <= 1'b0;
				if (rc_v && rc_addr == row_granule) begin
					row   <= rc_data;
					state <= (row_blank && rc_data == 64'd0)
					         ? (spr_is_bg ? S_NEXT_BG : S_NEXT_FG) : S_BLIT;
				end else begin
					rom_req <= 1'b1;
					state   <= S_FWAIT;
				end
			end
			S_FWAIT: begin
				if (rom_valid) begin
					dbg_fetches <= sat_inc(dbg_fetches);
					row     <= rom_data;
					rc_v    <= 1'b1;
					rc_addr <= row_granule;
					rc_data <= rom_data;
					state   <= (row_blank && rom_data == 64'd0)
					           ? (spr_is_bg ? S_NEXT_BG : S_NEXT_FG) : S_BLIT;
				end
			end

			// 16 pixels, then two cycles to drain the pipeline
			S_BLIT: begin
				blit_raddr <= blit_x;
				p1_x <= blit_x;  p1_pen <= pen;     p1_v <= (blit_px < 5'd16);
				p2_x <= p1_x;    p2_pen <= p1_pen;  p2_v <= p1_v;

				if (p2_v && !blit_q[LB_W]
				    && (p2_pen != transpen || (spr_is_bg && bgflag_opaque))) begin
					lb_we    <= 1'b1;
					lb_waddr <= p2_x;
					lb_wdata <= {1'b1, spr_cbase + {{(LB_W - 4){1'b0}}, p2_pen}};
				end

				blit_px <= blit_px + 5'd1;
				if (blit_px == 5'd17) begin
					dbg_sprites  <= sat_inc(dbg_sprites);
					line_sprites <= sat_inc(line_sprites);
					state <= spr_is_bg ? S_NEXT_BG : S_NEXT_FG;
				end
			end

			S_NEXT_BG: begin
				if (bg_sub) begin
					bg_sub <= 1'b0;
					state  <= S_BG_E0;          // re-issues with the new bg_sub
				end else if (bg_col == 5'd0) begin
					state <= S_DONE;
				end else begin
					bg_col <= bg_col - 5'd1;
					state  <= S_BG_S0;
				end
			end
			S_NEXT_FG: begin
				// resume after the hit
				if (fg_hit_i == {1'b0, spritelimit}) begin
					bg_col <= numcol - 5'd1;
					state  <= (numcol == 5'd0) ? S_DONE : S_BG_S0;
				end else begin
					issue_i <= fg_hit_i + 10'd1;
					state   <= S_FG_PRIME;
				end
			end

			S_DONE: begin
				line_done <= 1'b1;
				if (line_cycles    > dbg_worst_line)    dbg_worst_line    <= line_cycles;
				if (line_sprites   > dbg_worst_sprites) dbg_worst_sprites <= line_sprites;
				state     <= S_IDLE;
			end

			default: state <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
