// Seta X1-001A / X1-002A — sprites, and the "floating tilemap" made of sprites.
//
// Transcribed from src/devices/video/x1_001.cpp. scripts/x1_001_model.py is a
// line-by-line transcription of the same file and is what sim/x1_001_tb checks
// this against; that model in turn reproduces MAME's own render of 24 captured
// frames across eight sets, pixel for pixel, so the chain from the C++ to here
// is closed at both ends.
//
// TWO INDEPENDENT THINGS SHARE THE CHIP
//   draw_background renders 16 columns x 32 sprites out of spritecode[0x400..]
//   with per-column scroll -- games use it as a background layer -- and
//   draw_foreground renders up to 512 ordinary sprites out of
//   spritecode[0x000..]. Background first, so foreground is on top; foreground
//   walks HIGH INDEX FIRST so entry 0 ends up on top of that. There is no
//   per-sprite priority anywhere in the chip, so a line buffer written
//   back-to-front, skipping the transparent pen, reproduces the order exactly.
//
// THE TWO HALVES POSITION Y OPPOSITELY, and this is not a tidying opportunity.
//   foreground:  y = max_y - ((sy + fg_yoffs) & 0xff), max_y = screen HEIGHT
//                (256 here, not the 240 visible)
//   background:  y = (-(scrolly + bg_yoffs) + (offs/2)*16) & 0xff, with no
//                reflection at all
//   Per scanline, with each sprite also drawn 256 lines higher, that becomes
//     fg: covered iff ((L + Y) & 0xff) < 16, row = (L + Y) & 0x0f
//     bg: covered iff ((L - S) & 0xff) < 16, row = (L - S) & 0x0f, and since
//         the 16 rows of a column are 16 pixels apart over exactly 256 lines,
//         EXACTLY ONE of them lands on any given line: r = ((L - S0) >> 4).
//   Both forms are asserted against the four-copy original in
//   x1_001_model.py's selftest, over all 256x256 combinations.
//
// THE ENGINE WALKS FRONT TO BACK, WHICH IS THE REVERSE OF MAME'S ORDER, and
//   the line buffer carries a written bit so the FIRST writer of a pixel wins.
//   That is the same picture -- MAME's back-to-front overwrite and this
//   front-to-back first-wins are duals -- but it is not the same behaviour when
//   the engine RUNS OUT OF TIME.
//
//   It runs out of time routinely. The chip walks all 512 foreground entries
//   every line, and a game using 40 of them leaves the other 472 holding one
//   stale y, so they all land on the same sixteen scanlines: measured over 24
//   captures, the busiest line of EVERY ONE carries between 155 and 544
//   sprites, gameplay frames included. 512 sprites in a 512-dot line at 8 MHz
//   is 12 clk_sys cycles each. The real chip has a limit too -- a 32-bit
//   sprite ROM bus at 16 MHz is exactly 512 rows of 8 bytes per 64 us line
//   with nothing spare, and x1_001.cpp's own comment says "Draw up to 512
//   sprites, mjyuugi has glitches if you draw them all".
//
//   Back-to-front with a time cutoff drops the sprites not reached yet, which
//   are the LOWEST indices -- the ones the chip draws last and therefore puts
//   ON TOP. Front-to-back drops the bottom-most instead, which is what an
//   overflowing sprite chip does. line_budget sets the cutoff and dbg_dropped
//   counts what it cost.
//
// THE FOUR WRAP COPIES COLLAPSE. MAME draws every sprite at (x, y), (x-512, y),
//   (x, y-256) and (x-512, y-256). Modulo a 512-wide line buffer and the
//   per-line y test above, those four are one draw at (x & 0x1ff) -- also
//   asserted in the model's selftest rather than assumed here.
//
// THE BANK EXPRESSION IS NOT `ctrl2 & 0x40`. `(ctrl2 ^ (~ctrl2 << 1)) & 0x40`
//   expands to bit6 XOR (NOT bit5), i.e. true when BITS 6 AND 5 AGREE. It is
//   copied verbatim below. thunderl's control bytes are `10 6c 00 ff` -- both
//   set -- so it draws from spritecode[0x1000] and, bit 5 being set, never
//   buffers; an implementation that read the expression as bit 6 alone would
//   draw an empty screen. LESSONS_LEARNED, "Copy a driver's register
//   expression including its operators".
//
// GRAPHICS FETCH: ONE 64-BIT GRANULE PER SPRITE ROW.
//   layout_sprites is RGN_FRAC(1,2) 4bpp -- the region splits in half and each
//   half carries two bit planes, a tile being 64 bytes per half laid out as
//   byte = 32*yh + 16*xh + 2*yl + p, MSB the leftmost pixel. In MAME's layout a
//   16-pixel ROW is four 16-bit words sitting 16 bytes and half a region apart:
//   four addresses, four different SDRAM granules, four round trips. Measured,
//   that was ~56 of the ~90 clk_sys cycles a sprite cost, and it capped the
//   engine at 68 sprites per line against the 512 the chip walks.
//
//   rtl/memory/gfx_swizzle.sv permutes the region's WORD ADDRESSES at download
//   time so a row is eight contiguous, 8-byte-aligned bytes. The whole address
//   calculation here then collapses to the granule at {tile, yh, yl}, and the
//   four words arrive in one read:
//       rom_data[15:0]  half1 xh=0      rom_data[31:16] half1 xh=1
//       rom_data[47:32] half2 xh=0      rom_data[63:48] half2 xh=1
//   Word order within a granule is sdram.sv's: g_data[16*i] is the word at the
//   LOWEST byte address, which sdram_narrow_bridge.sv documents and indexes
//   with addr[2:1].
//
// SPRITE BUFFERING -- setac_eof, added for Phase 2
//
//   void x1_001_device::setac_eof()
//   {
//       int const ctrl2 = m_spritectrl[1];
//       if (~ctrl2 & 0x20)
//       {
//           if (ctrl2 & 0x40)
//               std::copy_n(&m_spritecode[0x1000], 0x800, &m_spritecode[0x0000]);
//           else
//               std::copy_n(&m_spritecode[0x0000], 0x800, &m_spritecode[0x1000]);
//       }
//   }
//
//   Gated on BIT 5 CLEAR, direction on bit 6. No Group A game wires it, and
//   measured on the Phase 2 captures drgnunit and stg have bit 5 SET -- so the
//   copy never runs for them either. Only qzkklogy and qzkklgy2 buffer, and
//   they do it every frame. buffer_sprites keeps it off everywhere else.
//
//   IT USES THE ENGINE'S READ PORT, not the CPU's. The code RAM already has
//   two read ports -- one for the CPU, one for the engine -- and adding a
//   third would stop Quartus inferring block RAM for 8192 words and build it
//   out of logic instead. The engine is idle during vblank, which is exactly
//   when the copy runs, so its port is free.
//
//   WHERE THIS DIVERGES FROM MAME, stated rather than discovered later: MAME's
//   copy is instantaneous at the vblank edge. This one takes 2048 cycles --
//   about 21 us at 96 MHz -- and holds the write port for that time, so a CPU
//   write into the DESTINATION half during those first 21 us of vblank is
//   overwritten by the copy where MAME would keep it. The window is small and
//   the alternative is a second write port on a RAM this size.
//
// NOT IMPLEMENTED HERE, DELIBERATELY
//   * m_bgflag, which makes the background opaque, is written by exactly one
//     memory map in seta.cpp -- crazyfgt_map, which is out of scope. The input
//     exists so the omission is visible rather than silent.
//
// FLIP SCREEN is implemented, and is checked against the model only. No
//   captured frame has it set (every Group A capture reads ctrl0 = 0x10, bit 6
//   clear), so the path is a transcription that agrees with another
//   transcription -- unlike the unflipped path, which is checked against
//   MAME's own render.

`default_nettype none

module x1_001 #(
	// Palette index width. Group A needs 10 bits (pairlove's gfx colorbase is
	// 0x200, and a sprite reaches 0x200 + 31*16 + 15 = 0x3ff); Group C's
	// palette runs to 1536 entries. 11 bits covers both.
	parameter int LB_W = 11
) (
	input  wire         clk,
	input  wire         reset,

	// =====================================================================
	// CPU side. Three separate blocks, because seta.cpp maps them separately
	// and on several boards far apart.
	//
	// REGISTERED ONE CYCLE IN AND ONE OUT, the same shape x1_010.sv ended up
	// with after Phase 0's timing work: a peripheral hanging combinationally
	// off the CPU data bus puts the CPU's slowest register output in series
	// with this decode and a RAM setup, which measured -1.169 ns there. One
	// register stage is cheaper than a multicycle and needs no audit.
	//
	// This comment described the intent for a while before the code did. The
	// first whole-core build's critical path ran the TG68K register file
	// straight into a peripheral RAM's data input, which is exactly what the
	// paragraph above says not to do -- the input registers below were simply
	// never written. A comment is not a constraint.
	//
	// maincpu.sv spends three cycles on an io access and captures the read in
	// the third, so the extra stage is free: the address reaches the array in
	// the second cycle and the data is back in time for the third.
	// =====================================================================
	input  wire         code_we,
	input  wire  [12:0] code_addr,      // word address into 0x2000 words
	input  wire  [15:0] code_wdata,
	input  wire         code_uds, code_lds,
	output logic [15:0] code_rdata,

	// spriteylow is a BYTE array in MAME (0x300 of them) that the CPU sees as
	// words; spriteylow_w16 takes only ACCESSING_BITS_0_7, so the high byte is
	// not stored anywhere and reads back as zero.
	input  wire         ylow_we,
	input  wire   [9:0] ylow_addr,
	input  wire   [7:0] ylow_wdata,
	output logic  [7:0] ylow_rdata,

	input  wire         ctrl_we,
	input  wire   [1:0] ctrl_addr,
	input  wire   [7:0] ctrl_wdata,
	output logic  [7:0] ctrl_rdata,

	// =====================================================================
	// Board configuration. Every one of these is a machine_config call or a
	// GFXDECODE field in seta.cpp, not a tuning knob.
	// =====================================================================
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
	// screen_vblank_seta_buffer_sprites, on the RISING edge of vblank.
	input  wire         buffer_sprites,
	input  wire         vblank_rise,
	input  wire [LB_W-1:0] colorbase_fg,    // gfx colorbase + m_colorbase*16
	input  wire [LB_W-1:0] colorbase_bg,    // gfx colorbase alone
	input  wire   [8:0] screen_h,           // screen.height() -- 256, NOT 240
	input  wire   [8:0] vis_max_y,          // visible_area().max_y
	input  wire [LB_W-1:0] backdrop,        // the bitmap.fill() before drawing
	input  wire  [15:0] code_mask,          // tiles-per-half minus one
	// Cycles the engine may spend on one line before it gives up and displays
	// what it has. 0 disables the cutoff, which is what the model comparison
	// runs with -- the model has no time limit either, so a bench that capped
	// the engine would be diffing two different pictures.
	input  wire  [15:0] line_budget,

	// =====================================================================
	// Line engine. Pulse line_start with the line to PREPARE; the result
	// lands in the buffer the video side is not reading.
	// =====================================================================
	input  wire         line_start,
	input  wire   [8:0] line,
	output logic        line_done,
	output logic        busy,

	// ---- graphics ROM: one 64-bit granule per sprite row --------------------
	// rom_req is a one-cycle pulse with rom_addr held until rom_valid, which is
	// sdram_narrow_bridge.sv's contract and the OPPOSITE of the arbiter's.
	// rom_addr is a GRANULE address -- 8-byte units -- because a swizzled
	// sprite row is exactly one granule and never straddles two.
	output logic        rom_req,
	output logic [23:3] rom_addr,
	input  wire         rom_valid,
	input  wire  [63:0] rom_data,

	// ---- line buffer readback ----------------------------------------------
	input  wire   [8:0] lb_addr,
	output logic [LB_W-1:0] lb_data,
	// Whether a sprite actually wrote this dot. The line buffer already
	// carries the bit -- it is what makes front-to-back drawing work, first
	// writer wins -- and it was simply not brought out. Phase 2 needs it: a
	// tilemap layer is drawn OPAQUE underneath and the sprites go over, so the
	// mixer picks the sprite pixel only where there is one.
	output logic        lb_hit,
	// m_spritegen->is_flipped(). seta_layers_update takes the TILE LAYER's
	// flip from the sprite chip, not from a register of its own, so it has to
	// leave here.
	output wire         flipscr_out,

	// ---- instrumentation ---------------------------------------------------
	// Every bad-event counter is paired with a total, so a zero can be told
	// from "never ran" (LESSONS_LEARNED, "Pair every bad-event counter with a
	// total"). Port-declaration initialisers, no reset: an `initial` block
	// would be a second driver and Quartus rejects it -- see
	// rtl/debug/debug_counter.sv.
	output logic [15:0] dbg_lines   = '0,
	output logic [15:0] dbg_sprites = '0,   // sprites blitted, saturating
	output logic [15:0] dbg_fetches = '0,   // ROM words read, saturating
	output logic [15:0] dbg_overrun = '0,   // lines still rendering at the next start
	// The two numbers the line budget is judged on, measured in the RTL rather
	// than in a testbench's $time -- these also go on the OSD debug page, where
	// $time does not exist. A line is 512 dots at a believed 8 MHz dot clock =
	// 6144 clk_sys cycles at 96 MHz.
	output logic [15:0] dbg_worst_line    = '0,   // clk_sys cycles, line_start to done
	output logic [15:0] dbg_worst_sprites = '0,   // sprites blitted in one line
	output logic [15:0] dbg_dropped       = '0    // lines cut short by line_budget
);

	// =====================================================================
	// Chip RAM
	//
	// One write port and one read port each -- a SIMPLE dual-port RAM, which
	// an M10K provides directly. The CPU's own read shares its write port
	// rather than asking for a third address: x1_010.sv's provenance records
	// what the other shape costs here, which was an 8 KB array built out of
	// logic and the design missing the device by 47%.
	// =====================================================================
	logic [15:0] codemem [0:8191];
	logic  [7:0] ylowmem [0:1023];
	logic  [7:0] ctrlmem [0:3];

	logic [12:0] eng_code_addr;
	logic  [9:0] eng_ylow_addr;
	logic [15:0] eng_code_q;
	logic  [7:0] eng_ylow_q;

	// The input register stage. Everything the CPU drives is captured here and
	// nothing downstream sees the raw ports.
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

	// ctrl2 gates and directs the buffering copy as well as selecting the
	// bank, so it is declared before both uses.
	wire [7:0] ctrl2 = ctrlmem[2];

	// ---- setac_eof --------------------------------------------------------
	logic        eof_busy = 1'b0;
	logic [10:0] eof_i;
	logic        eof_dir;              // ctrl2 bit 6: 1 = 0x1000 -> 0x0000
	logic        eof_wr;
	logic [12:0] eof_waddr;

	wire [12:0] eof_src = {1'b0, ~eof_dir, eof_i};
	wire [12:0] eof_dst = {1'b0,  eof_dir, eof_i};

	always_ff @(posedge clk) begin
		eof_wr <= 1'b0;
		if (reset) begin
			eof_busy <= 1'b0;
		end else if (!eof_busy) begin
			// ~ctrl2 & 0x20 -- bit 5 CLEAR means buffer.
			if (vblank_rise && buffer_sprites && !ctrl2[5]) begin
				eof_busy <= 1'b1;
				eof_dir  <= ctrl2[6];
				eof_i    <= 11'd0;
			end
		end else begin
			// The word read on the previous cycle is written this one.
			eof_wr    <= 1'b1;
			eof_waddr <= eof_dst;
			if (eof_i == 11'h7ff) eof_busy <= 1'b0;
			else eof_i <= eof_i + 11'd1;
		end
	end

	// ONE WRITE ADDRESS, MUXED -- not two branches writing different addresses.
	// Written the obvious way, with the copy in an if and the CPU in the else,
	// this RAM stops inferring as block RAM and Quartus builds 8192 words out
	// of logic: the fit came back with 128,660 combinational nodes against the
	// device's 83,820. Same rule as LESSONS_LEARNED's "a true dual-port RAM
	// must be ONE always block with both ports in it".
	wire [12:0] cw_addr = eof_wr ? eof_waddr  : c_addr;
	wire [15:0] cw_data = eof_wr ? eng_code_q : c_wdata;
	wire        cw_lo   = eof_wr ? 1'b1 : (c_we && c_lds);
	wire        cw_hi   = eof_wr ? 1'b1 : (c_we && c_uds);

	always_ff @(posedge clk) begin
		if (cw_lo) codemem[cw_addr][7:0]  <= cw_data[7:0];
		if (cw_hi) codemem[cw_addr][15:8] <= cw_data[15:8];
		code_rdata <= codemem[c_addr];
	end

	// The engine's read port, borrowed by the copy while the engine is idle.
	wire [12:0] eng_rd_addr = eof_busy ? eof_src : eng_code_addr;
	always_ff @(posedge clk) eng_code_q <= codemem[eng_rd_addr];

	always_ff @(posedge clk) begin
		if (y_we) ylowmem[y_addr] <= y_wdata;
		ylow_rdata <= ylowmem[y_addr];
	end
	always_ff @(posedge clk) eng_ylow_q <= ylowmem[eng_ylow_addr];

	always_ff @(posedge clk) begin
		if (k_we) ctrlmem[k_addr] <= k_wdata;
		ctrl_rdata <= ctrlmem[k_addr];
	end

	// The four control bytes are read continuously rather than through a port:
	// the engine needs all of them at once, and a four-entry array is flops
	// however it is written.
	wire [7:0] ctrl0 = ctrlmem[0];
	wire [7:0] ctrl1 = ctrlmem[1];
	wire [7:0] ctrl3 = ctrlmem[3];

	// =====================================================================
	// Line buffers: two of 512, written by the engine, read by the video side.
	// 512 rather than the 384 visible, because a sprite's x wraps modulo 512
	// and the off-screen part has to land somewhere harmless.
	// =====================================================================
	// Each entry is { written, pen }. Walking front to back, the FIRST writer
	// of a pixel wins, so one bit replaces what would otherwise be a stored
	// sprite index and a comparator.
	//
	// ONE READ PORT AND ONE WRITE PORT EACH, still -- a simple dual-port RAM,
	// which an M10K provides. The engine's read-modify-write and the video
	// side's readback never happen on the SAME buffer at the same time (the
	// engine renders into one while the video reads the other), so the read
	// address is a mux, not a second port. Asking for two read addresses is
	// what made Quartus replicate x1_010's register file into logic.
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
	// The video side reads whichever buffer the engine is not writing. Delayed
	// by one cycle to line up with the registered RAM output above.
	always_ff @(posedge clk) disp_bank <= ~render_bank;
	assign lb_data = disp_bank ? lb_q1[LB_W-1:0] : lb_q0[LB_W-1:0];
	assign lb_hit  = disp_bank ? lb_q1[LB_W]     : lb_q0[LB_W];
	// ...and the engine probes the one it IS writing.
	wire [LBE-1:0] blit_q = render_bank ? lb_q1 : lb_q0;

	// =====================================================================
	// Control-register decode
	// =====================================================================
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

	// =====================================================================
	// The engine
	// =====================================================================
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

	// The foreground scan is PIPELINED: one entry issued per cycle, and the
	// entry under test trails the address by TWO -- eng_ylow_addr is a
	// register, so an address set at the end of cycle k is only presented to
	// the RAM during k+1 and its data is only readable in k+2. Scanning 512
	// entries two cycles each would cost 1024 of a line's ~6100 clk_sys
	// cycles, which is most of the sprite budget on its own.
	//
	// issue_* is the address side, d1_*/d2_* the two delay stages. Every stage
	// carries a valid bit so the tail of the scan drains correctly, and so a
	// hit -- which abandons the two entries in flight and re-primes below
	// them -- cannot leave a stale index looking testable.
	logic  [9:0] issue_i, d1_i, d2_i;
	logic        issue_v, d1_v, d2_v;
	logic  [9:0] fg_hit_i;
	logic  [3:0] fg_row;

	// The sprite currently being drawn, all fields already resolved.
	// 16 bits: setac_gfxbank_callback adds bank * 0x4000 to a 14-bit code.
	logic [15:0] spr_tile;
	logic        spr_flipx;
	logic  [3:0] spr_row;            // AFTER flipy
	logic  [8:0] spr_x;
	logic [LB_W-1:0] spr_cbase;
	logic        spr_is_bg;

	logic [15:0] line_cycles, line_sprites;
	logic [63:0] row;                  // one sprite row, all four plane words
	logic  [4:0] blit_px;

	// The blit is a two-stage pipeline because the line buffer needs a
	// READ-MODIFY-WRITE: front-to-back means the first writer of a pixel wins,
	// so each write has to see whether one already happened. blit_raddr probes
	// at stage 0 and blit_q answers two cycles later, so the pen and address
	// are carried along beside it. No intra-sprite hazard exists -- the 16
	// pixels of one sprite are 16 distinct addresses.
	logic [8:0] p1_x, p2_x;
	logic [3:0] p1_pen, p2_pen;
	logic       p1_v, p2_v;

	// ---- the row's granule -------------------------------------------------
	// Swizzled, a row's eight bytes start at tile*128 + yh*64 + yl*8, so the
	// granule index is just {tile, yh, yl}. No offsets, no half base, no
	// per-word arithmetic -- that is the whole point of gfx_swizzle.sv.
	wire [23:3] row_granule = {1'b0, (spr_tile & code_mask), spr_row};

	// ---- pixel extraction ---------------------------------------------------
	// planeoffset is { RGN_FRAC(1,2)+8, RGN_FRAC(1,2)+0, 8, 0 } and MAME's
	// planeoffset[0] is the MOST significant bit of the pen. The +8 selects the
	// odd byte of the pair, which the ROM loader put in the HIGH half of the
	// word (sdram_download pairs {odd, even}, even byte low). So per pixel:
	//     pen[3] = half2 odd byte      pen[2] = half2 even byte
	//     pen[1] = half1 odd byte      pen[0] = half1 even byte
	// Backwards, this produces artwork in the wrong colours rather than noise,
	// which is why the model asserts the byte layout structurally.
	wire  [3:0] src_x = spr_flipx ? (4'd15 - blit_px[3:0]) : blit_px[3:0];
	wire  [2:0] bitn  = 3'd7 - src_x[2:0];
	wire [15:0] wa    = src_x[3] ? row[31:16] : row[15:0];    // half1, this xh
	wire [15:0] wb    = src_x[3] ? row[63:48] : row[47:32];   // half2, same xh
	wire  [3:0] pen   = { wb[{1'b1, bitn}], wb[{1'b0, bitn}],
	                      wa[{1'b1, bitn}], wa[{1'b0, bitn}] };
	wire  [8:0] blit_x = spr_x + {5'd0, blit_px[3:0]};

	// ---- foreground scanline test ------------------------------------------
	// sy = spriteylow[i]; with flip screen, sy = 2*screen_h - sy - vis_max_y - 1
	// first (MAME: max_y - sy + (height - (visarea.max_y + 1)), max_y = height).
	// Then Y = (sy + fg_yoffs) & 0xff and the line is covered iff
	// ((L + Y) & 0xff) < 16.
	// PRE-ADDED, because everything here except the RAM byte is constant for
	// the whole scan. Written the obvious way -- fg_sy, then + fgy, then
	// + cur_line -- this is three 8-bit adders in series hanging off the
	// spriteylow RAM's output, and the second whole-core build's fifteen worst
	// paths were all exactly that: from ylowmem's port B out, through Add2,
	// Add3 and Add4, into fg_hit_i and eng_code_addr. -1.751 ns, and by then
	// the TG68K was no longer the critical path at all.
	//
	// All of it is mod-256, so the regrouping is exact:
	//     unflipped: fg_d = cur_line + fgy + sy
	//     flipped:   fg_d = cur_line + fgy + 2*screen_h - vis_max_y - 1 - sy
	// which is fg_base +/- sy with fg_base holding every term but sy. One
	// adder off the RAM instead of three.
	//
	// fg_base is registered and safe to be a cycle behind: cur_line is latched
	// at line_start and S_CLEAR then runs 512 cycles before S_FG_SCAN can
	// evaluate anything, and flipscr, fgy, screen_h and vis_max_y do not move
	// within a line.
	logic [7:0] fg_base;
	always_ff @(posedge clk)
		fg_base <= flipscr
		    ? (cur_line[7:0] + fgy[7:0] + screen_h[7:0] + screen_h[7:0]
		       - vis_max_y[7:0] - 8'd1)
		    : (cur_line[7:0] + fgy[7:0]);

	wire  [7:0] fg_d   = flipscr ? (fg_base - eng_ylow_q)
	                             : (fg_base + eng_ylow_q);
	wire        fg_hit = (fg_d[7:4] == 4'd0);

	// ---- background scanline test ------------------------------------------
	// S0 = -(scrolly + bg_yoffs); row r of the column sits at S0 + 16r, or at
	// 0xf0 - (S0 + 16r) with flip screen. Either way exactly one r lands on
	// this line, and both the row and which r fall out of one subtraction.
	wire  [7:0] bg_S0 = -(bg_scrolly + bgy[7:0]);
	wire  [7:0] bg_f  = cur_line[7:0] - bg_S0;              // unflipped
	wire  [7:0] bg_e  = cur_line[7:0] - 8'hf0 + bg_S0;      // flipped
	wire  [3:0] bg_sel_r   = flipscr ? (4'd0 - bg_e[7:4]) : bg_f[7:4];
	wire  [3:0] bg_sel_row = flipscr ? bg_e[3:0]          : bg_f[3:0];

	wire  [3:0] bg_ent_i     = (bg_col[3:0] + startcol);
	wire  [4:0] bg_offs      = {bg_r, bg_sub};
	wire [12:0] bg_code_addr = {4'd0, bg_ent_i, bg_offs} + 13'h400 + bank_off;
	wire [12:0] bg_attr_addr = {4'd0, bg_ent_i, bg_offs} + 13'h600 + bank_off;

	// ---- x for each half ----------------------------------------------------
	// foreground: sx = (attr & 0xff) - (attr & 0x100), i.e. attr[8:0] read as
	// two's complement; then (sx + xoffs) & 0x1ff.
	wire signed [9:0] fg_sx = $signed({eng_code_q[8], eng_code_q[8:0]});
	wire        [8:0] fg_px = fg_sx[8:0] + fgx[8:0];
	// background: sx = scrollx + xoffs + (offs & 1) * 16, minus 256 if this
	// column's high bit is set in spritectrl[2..3].
	wire        [8:0] bg_px = {1'b0, bg_scrollx} + bgx[8:0]
	                        + (bg_sub ? 9'd16 : 9'd0)
	                        + (upper[bg_col[3:0]] ? 9'h100 : 9'd0);

	function automatic logic [15:0] sat_inc(input logic [15:0] v);
		sat_inc = (v == 16'hFFFF) ? v : v + 16'd1;
	endfunction

	assign busy     = (state != S_IDLE);
	assign rom_addr = row_granule;

	always_ff @(posedge clk) begin
		line_done <= 1'b0;
		lb_we     <= 1'b0;
		rom_req   <= 1'b0;

		if (reset) begin
			state       <= S_IDLE;
			render_bank <= 1'b0;
			line_cycles <= 16'd0;
		end else if (line_start) begin
			// A line_start while still rendering is a real fault, not a
			// rounding error: the previous line's buffer is incomplete and
			// half of it will be displayed. Counted, and the new line still
			// starts -- dropping it would hide the same fault differently.
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

			// OUT OF TIME. Stop where we are and display what has been drawn.
			// Front to back, that leaves the topmost sprites and drops the
			// bottom-most, which is what an overflowing sprite chip does; the
			// same cutoff on a back-to-front renderer would drop the ones on
			// top. Never cut during S_CLEAR -- a half-cleared buffer shows the
			// previous frame's line, which is worse than any sprite dropout and
			// looks like a completely different fault.
			if (line_budget != 16'd0 && line_cycles >= line_budget
			    && state != S_IDLE && state != S_CLEAR && state != S_DONE) begin
				dbg_dropped <= sat_inc(dbg_dropped);
				state <= S_DONE;
			end else
			case (state)

			S_IDLE: ;

			// ---- fill the render buffer with the backdrop pen ---------------
			// screen_update_seta_no_layers does bitmap.fill(0x1f0) before
			// drawing anything, and 0x1f0 is a real palette entry, not black.
			S_CLEAR: begin
				lb_we    <= 1'b1;
				lb_waddr <= clr_addr[8:0];
				lb_wdata <= {1'b0, backdrop};      // nothing written here yet
				clr_addr <= clr_addr + 10'd1;
				if (clr_addr == 10'd511) begin
					// FRONT TO BACK: foreground entry 0 is the topmost thing on
					// the screen, so it is drawn first and every later write to
					// one of its pixels is discarded. The floating tilemap sits
					// under all of it and comes afterwards, its columns in
					// reverse -- MAME draws column 0 first and lets later
					// columns overwrite it.
					issue_i <= 10'd0;
					state   <= S_FG_PRIME;
				end
			end

			// ---- background: this column's scroll pair ----------------------
			// scrollram = &m_spriteylow[0x200]
			// scrolly = scrollram[col*0x10];  scrollx = scrollram[col*0x10 + 4]
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
				// bg_scrolly landed last cycle, so bg_sel_r/bg_sel_row are
				// valid now; bg_scrollx is this cycle's read.
				bg_scrollx <= eng_ylow_q;
				bg_r       <= bg_sel_r;
				bg_row     <= bg_sel_row;
				bg_sub     <= 1'b1;      // MAME draws offs 2r then 2r+1
				state      <= S_BG_E0;
			end

			// bg_r/bg_sub are registered, so the address they form is only
			// valid the cycle after they are written -- hence a state whose
			// whole job is to issue it.
			S_BG_E0: begin
				eng_code_addr <= bg_code_addr;
				state <= S_BG_E1;
			end
			S_BG_E1: begin
				eng_code_addr <= bg_attr_addr;
				state <= S_BG_E2;
			end
			S_BG_E2: begin
				// eng_code_q is the CODE word; the attribute arrives next
				// cycle, which is why the fields below split across two states.
				spr_tile  <= {2'b00, eng_code_q[13:0]};   // code &= 0x3fff, no bank
				spr_flipx <= eng_code_q[15] ^ flipscr;
				spr_row   <= (eng_code_q[14] ^ flipscr) ? (4'd15 - bg_row) : bg_row;
				spr_x     <= bg_px;
				spr_is_bg <= 1'b1;
				state     <= S_FETCH;
			end

			// ---- foreground: scan spriteylow, one entry per cycle ------------
			S_FG_PRIME: begin
				eng_ylow_addr <= issue_i;
				d1_i  <= issue_i;  d1_v <= 1'b1;
				d2_v  <= 1'b0;
				issue_v <= (issue_i != {1'b0, spritelimit});
				issue_i <= issue_i + 10'd1;
				state <= S_FG_SCAN;
			end
			S_FG_SCAN: begin
				// eng_ylow_q is ylow[d2_i] this cycle. The shift happens
				// regardless; the hit test below reads the OLD d2_*, which is
				// what lines up with it.
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
					// Foreground exhausted; the floating tilemap is next, its
					// columns walked in reverse so the topmost is drawn first.
					bg_col <= numcol - 5'd1;
					state  <= (numcol == 5'd0) ? S_DONE : S_BG_S0;
				end
			end
			S_FG_E0: begin
				eng_code_addr <= {3'd0, fg_hit_i} + 13'h200 + bank_off;
				state <= S_FG_E1;
			end
			S_FG_E1: begin
				// the CODE word
				spr_tile  <= {2'b00, eng_code_q[13:0]};
				spr_flipx <= eng_code_q[15] ^ flipscr;
				spr_row   <= (eng_code_q[14] ^ flipscr) ? (4'd15 - fg_row) : fg_row;
				state     <= S_FG_E2;
			end
			S_FG_E2: begin
				// the ATTRIBUTE word: colour in 15:11, x in 8:0, and the gfx
				// bank in 10:9. setac_gfxbank_callback -- the only callback any
				// in-scope game installs -- is
				//     bank = (color & 0x06) >> 1;
				//     code = (code & 0x3fff) + bank * 0x4000;
				// with `color` being x_pointer[i] >> 8, so bits 10:9 here. The
				// tile index is therefore 16 bits wide, and code_mask wraps it
				// to the region the way gfx_element does.
				spr_tile  <= {eng_code_q[10:9], spr_tile[13:0]};
				spr_x     <= fg_px;
				spr_cbase <= colorbase_fg
				           + {{(LB_W - 9){1'b0}}, eng_code_q[15:11], 4'd0};
				spr_is_bg <= 1'b0;
				state     <= S_FETCH;
			end

			// ---- fetch one 16-pixel row: four 16-bit words -------------------
			S_FETCH: begin
				// The background's colour comes from the SAME word position as
				// the foreground's but takes colorbase_bg -- draw_background
				// adds no m_colorbase. Latched here because S_BG_E2 needed
				// eng_code_q for the code word.
				if (spr_is_bg)
					spr_cbase <= colorbase_bg
					           + {{(LB_W - 9){1'b0}}, eng_code_q[15:11], 4'd0};
				rom_req <= 1'b1;
				state   <= S_FWAIT;
			end
			S_FWAIT: begin
				if (rom_valid) begin
					dbg_fetches <= sat_inc(dbg_fetches);
					row     <= rom_data;
					blit_px <= 5'd0;
					p1_v <= 1'b0; p2_v <= 1'b0;
					state   <= S_BLIT;
				end
			end

			// ---- blit 16 pixels, transparent pen skipped ---------------------
			// 16 pixels issued, then two cycles to drain the read pipeline.
			// Stage 0 probes the line buffer, stage 2 writes it if the pixel is
			// not the transparent pen AND nothing has claimed it yet.
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

			// ---- iteration ---------------------------------------------------
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
				// Resume BELOW the hit. The two entries that were in flight
				// when it fired were never tested, and re-priming here retests
				// them -- two cycles per drawn sprite, against the 1024 a
				// two-cycle scan would have cost every line.
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
