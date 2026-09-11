// The whole Group A video path against MAME's own render, in RGB.
//
//     python scripts/mame_capture.py umanclub --frame 900 --name uc900
//     python scripts/prep_video_tb.py umanclub debug/uc900
//     scripts/run_sim.sh seta_video_tb            (from the repository root)
//
// sim/x1_001_tb checks the sprite engine against scripts/x1_001_model.py in PEN
// INDICES. This checks the picture: timing generator, line-buffer readout,
// palette decode and all, against the frame MAME rendered from exactly this
// register state. It is the first test here whose reference is the actual
// image rather than an intermediate.
//
// THE FRAME IS SAMPLED THE WAY THE MiSTer FRAMEWORK SAMPLES IT -- on vga_ce
// with vga_de high -- rather than by reaching into the line buffer. Anything
// that is wrong about WHEN a pixel is presented is then a real failure here,
// which is the point: the same off-by-one that a direct readback hides shifted
// the whole picture one pixel in sim/x1_001_tb and read as 46% of the frame
// being wrong.
//
// TWO FRAMES ARE RENDERED AND THE SECOND IS CHECKED. The first line of the
// first frame has nothing behind it -- the engine has not run yet, and the
// buffer being displayed was never written. Hardware has the same property and
// nobody sees it; a bench that compared frame one would report a one-line
// difference forever.

`timescale 1ns / 1ps

module tb_seta_video;

	localparam realtime CLK_PERIOD = 10.4167;   // 96 MHz clk_sys
	localparam int CE_DIV    = 12;              // -> 8 MHz dot clock
	localparam int LB_W      = 11;
	localparam int PAL_MAX   = 2048;
	localparam int GFX_WORDS = 1 << 21;         // msgundam's 4 MB region
	localparam int MAX_PIX   = 384 * 256;

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;
	logic reset = 1;

	logic [3:0] ce_cnt = 0;
	wire  ce_pix = (ce_cnt == 0);
	always @(posedge clk) ce_cnt <= (ce_cnt == CE_DIV - 1) ? 4'd0 : ce_cnt + 4'd1;

	// ---- configuration, positional; matches scripts/prep_video_tb.py CFG ----
	logic [31:0] cfgv [0:63];
	localparam int C_FGX = 0, C_FGXF = 1, C_FGY = 2, C_FGYF = 3;
	localparam int C_BGX = 4, C_BGXF = 5, C_BGY = 6, C_BGYF = 7;
	localparam int C_BANKSZ = 8, C_SPRLIM = 9, C_TRANSPEN = 10, C_BGOPAQUE = 11;
	localparam int C_CB_FG = 12, C_CB_BG = 13, C_SCRH = 14, C_VISMAXY = 15;
	localparam int C_BACKDROP = 16, C_GFXHALF = 17, C_CODEMASK = 18, C_BUDGET = 19;
	localparam int C_HTOTAL = 20, C_HSS = 21, C_HSE = 22, C_HAS = 23, C_HAE = 24;
	localparam int C_VTOTAL = 25, C_VSS = 26, C_VSE = 27, C_VAS = 28, C_VAE = 29;
	localparam int C_HAS_L0 = 31, C_L0X = 32, C_L0XF = 33, C_L0CB = 34,
	               C_L0MASK = 35, C_HAS_L1 = 36, C_L1X = 37, C_L1XF = 38,
	               C_L1CB = 39, C_L1MASK = 40, C_VREGS = 41;
	localparam int C_PALENT = 30;

	// ---- DUT ----------------------------------------------------------------
	logic        code_we = 0, code_uds = 0, code_lds = 0;
	logic [12:0] code_addr = 0;
	logic [15:0] code_wdata = 0;
	logic        ylow_we = 0;
	logic  [9:0] ylow_addr = 0;
	logic  [7:0] ylow_wdata = 0;
	logic        ctrl_we = 0;
	logic  [1:0] ctrl_addr = 0;
	logic  [7:0] ctrl_wdata = 0;
	logic        pal_we = 0, pal_uds = 0, pal_lds = 0;
	logic [10:0] pal_addr = 0;
	logic [15:0] pal_wdata = 0;

	wire         rom_req;
	wire  [23:3] rom_addr;
	logic        rom_valid = 0;
	logic [63:0] rom_data = 0;

	wire [7:0] vga_r, vga_g, vga_b;
	wire       vga_hs, vga_vs, vga_hb, vga_vb, vga_de, vga_ce;
	wire       irq_vblank_line, irq_mid_line, vblank_rise;
	wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun;
	wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped;

	// Shared by all three ROM models; +ROMLAT overrides.
	int   rom_latency = 12;

	// ---- the tile ROMs -----------------------------------------------------
	// Same granule convention as the sprite ROM above: four 16-bit words, word
	// i in bits [16*i +: 16], and gfx2/gfx3.hex are already in SDRAM byte
	// order. Two independent models because the two layers fetch at once.
	localparam int TILE_WORDS = 1 << 20;
	logic [15:0] gfx2rom [0:TILE_WORDS-1];
	logic [15:0] gfx3rom [0:TILE_WORDS-1];

	logic        tile_req, tile1_req;
	logic [23:3] tile_addr, tile1_addr;
	logic        tile_valid = 0, tile1_valid = 0;
	logic [63:0] tile_data = 0, tile1_data = 0;

	int   t0_cnt = 0, t1_cnt = 0;
	logic t0_busy = 0, t1_busy = 0;
	logic [23:3] t0_hold, t1_hold;

	always @(posedge clk) begin
		tile_valid <= 1'b0;
		if (reset) t0_busy <= 1'b0;
		else if (tile_req && !t0_busy) begin
			t0_busy <= 1'b1; t0_hold <= tile_addr; t0_cnt <= rom_latency;
		end else if (t0_busy) begin
			if (t0_cnt <= 1) begin
				tile_data <= { gfx2rom[{t0_hold[20:3], 2'd3}],
				               gfx2rom[{t0_hold[20:3], 2'd2}],
				               gfx2rom[{t0_hold[20:3], 2'd1}],
				               gfx2rom[{t0_hold[20:3], 2'd0}] };
				tile_valid <= 1'b1; t0_busy <= 1'b0;
			end else t0_cnt <= t0_cnt - 1;
		end
	end

	always @(posedge clk) begin
		tile1_valid <= 1'b0;
		if (reset) t1_busy <= 1'b0;
		else if (tile1_req && !t1_busy) begin
			t1_busy <= 1'b1; t1_hold <= tile1_addr; t1_cnt <= rom_latency;
		end else if (t1_busy) begin
			if (t1_cnt <= 1) begin
				tile1_data <= { gfx3rom[{t1_hold[20:3], 2'd3}],
				                gfx3rom[{t1_hold[20:3], 2'd2}],
				                gfx3rom[{t1_hold[20:3], 2'd1}],
				                gfx3rom[{t1_hold[20:3], 2'd0}] };
				tile1_valid <= 1'b1; t1_busy <= 1'b0;
			end else t1_cnt <= t1_cnt - 1;
		end
	end

	// ---- the layers' CPU side ----------------------------------------------
	logic        l0v_we = 0, l0c_we = 0, l1v_we = 0, l1c_we = 0;
	logic [12:0] l0v_addr = 0, l1v_addr = 0;
	logic [15:0] l0v_wdata = 0, l1v_wdata = 0;
	logic  [1:0] l0c_addr = 0, l1c_addr = 0;
	logic [15:0] l0c_wdata = 0, l1c_wdata = 0;

	seta_video #(.LB_W(LB_W), .PAL_ENTRIES(PAL_MAX)) dut (
		.clk(clk), .reset(reset), .ce_pix(ce_pix),
		.htotal(cfgv[C_HTOTAL][9:0]),
		.hs_start(cfgv[C_HSS][9:0]),   .hs_end(cfgv[C_HSE][9:0]),
		.hact_start(cfgv[C_HAS][9:0]), .hact_end(cfgv[C_HAE][9:0]),
		.vtotal(cfgv[C_VTOTAL][9:0]),
		.vs_start(cfgv[C_VSS][9:0]),   .vs_end(cfgv[C_VSE][9:0]),
		.vact_start(cfgv[C_VAS][9:0]), .vact_end(cfgv[C_VAE][9:0]),
		.fg_xoffs(cfgv[C_FGX][8:0]),   .fg_xoffs_flip(cfgv[C_FGXF][8:0]),
		.fg_yoffs(cfgv[C_FGY][8:0]),   .fg_yoffs_flip(cfgv[C_FGYF][8:0]),
		.bg_xoffs(cfgv[C_BGX][8:0]),   .bg_xoffs_flip(cfgv[C_BGXF][8:0]),
		.bg_yoffs(cfgv[C_BGY][8:0]),   .bg_yoffs_flip(cfgv[C_BGYF][8:0]),
		.bank_size(cfgv[C_BANKSZ][12:0]),
		.spritelimit(cfgv[C_SPRLIM][8:0]),
		.transpen(cfgv[C_TRANSPEN][3:0]),
		.bgflag_opaque(cfgv[C_BGOPAQUE][0]),
		.colorbase_fg(cfgv[C_CB_FG][LB_W-1:0]),
		.colorbase_bg(cfgv[C_CB_BG][LB_W-1:0]),
		.screen_h(cfgv[C_SCRH][8:0]), .vis_max_y(cfgv[C_VISMAXY][8:0]),
		.backdrop(cfgv[C_BACKDROP][LB_W-1:0]),
		.code_mask(cfgv[C_CODEMASK][15:0]),
		.line_budget(cfgv[C_BUDGET][15:0]),
		.en_l0(1'b1), .en_l1(1'b1),
		.code_we(code_we), .code_addr(code_addr), .code_wdata(code_wdata),
		.code_uds(code_uds), .code_lds(code_lds), .code_rdata(),
		.ylow_we(ylow_we), .ylow_addr(ylow_addr), .ylow_wdata(ylow_wdata),
		.ylow_rdata(),
		.ctrl_we(ctrl_we), .ctrl_addr(ctrl_addr), .ctrl_wdata(ctrl_wdata),
		.ctrl_rdata(),
		.pal_we(pal_we), .pal_addr(pal_addr), .pal_wdata(pal_wdata),
		.pal_uds(pal_uds), .pal_lds(pal_lds), .pal_rdata(),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),

		.buffer_sprites(1'b0),
		.has_l0(cfgv[C_HAS_L0][0]),
		.l0_vram_we(l0v_we), .l0_vram_addr(l0v_addr),
		.l0_vram_wdata(l0v_wdata), .l0_vram_uds(1'b1), .l0_vram_lds(1'b1),
		.l0_vram_rdata(),
		.l0_ctrl_we(l0c_we), .l0_ctrl_addr(l0c_addr),
		.l0_ctrl_wdata(l0c_wdata), .l0_ctrl_uds(1'b1), .l0_ctrl_lds(1'b1),
		.l0_ctrl_rdata(),
		.l0_xoffs(cfgv[C_L0X][8:0]), .l0_xoffs_flip(cfgv[C_L0XF][8:0]),
		.l0_colorbase(cfgv[C_L0CB][LB_W-1:0]),
		.l0_code_mask(cfgv[C_L0MASK][15:0]),
		.tile_req(tile_req), .tile_addr(tile_addr),
		.tile_valid(tile_valid), .tile_data(tile_data),

		.has_l1(cfgv[C_HAS_L1][0]),
		.l1_vram_we(l1v_we), .l1_vram_addr(l1v_addr),
		.l1_vram_wdata(l1v_wdata), .l1_vram_uds(1'b1), .l1_vram_lds(1'b1),
		.l1_vram_rdata(),
		.l1_ctrl_we(l1c_we), .l1_ctrl_addr(l1c_addr),
		.l1_ctrl_wdata(l1c_wdata), .l1_ctrl_uds(1'b1), .l1_ctrl_lds(1'b1),
		.l1_ctrl_rdata(),
		.l1_xoffs(cfgv[C_L1X][8:0]), .l1_xoffs_flip(cfgv[C_L1XF][8:0]),
		.l1_colorbase(cfgv[C_L1CB][LB_W-1:0]),
		.l1_code_mask(cfgv[C_L1MASK][15:0]),
		.tile1_req(tile1_req), .tile1_addr(tile1_addr),
		.tile1_valid(tile1_valid), .tile1_data(tile1_data),
		.vregs(cfgv[C_VREGS][7:0]),
		.vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
		.vga_hs(vga_hs), .vga_vs(vga_vs), .vga_hb(vga_hb), .vga_vb(vga_vb),
		.vga_de(vga_de), .vga_ce(vga_ce),
		.irq_vblank_line(irq_vblank_line), .irq_mid_line(irq_mid_line),
		.vblank_rise(vblank_rise),
		.dbg_lines(dbg_lines), .dbg_sprites(dbg_sprites),
		.dbg_fetches(dbg_fetches), .dbg_overrun(dbg_overrun),
		.dbg_worst_line(dbg_worst_line), .dbg_worst_sprites(dbg_worst_sprites),
		.dbg_dropped(dbg_dropped)
	);

	// ---- graphics ROM: 64-bit granules, settable latency --------------------
	logic [15:0] gfxrom [0:GFX_WORDS-1];
	logic [15:0] l0v_init [0:8191];
	logic [15:0] l1v_init [0:8191];
	logic [15:0] l0c_init [0:2];
	logic [15:0] l1c_init [0:2];
	logic [15:0] gfxnat [0:GFX_WORDS-1];
	int   rom_cnt = 0;
	logic rom_busy = 0;
	logic [23:3] rom_hold_a;
	int   rom_reads = 0;

	always @(posedge clk) begin
		rom_valid <= 1'b0;
		if (reset) rom_busy <= 1'b0;
		else if (rom_req && !rom_busy) begin
			rom_busy <= 1'b1; rom_hold_a <= rom_addr; rom_cnt <= rom_latency;
		end else if (rom_busy) begin
			if (rom_cnt <= 1) begin
				rom_data  <= { gfxrom[{rom_hold_a[21:3], 2'd3}],
				               gfxrom[{rom_hold_a[21:3], 2'd2}],
				               gfxrom[{rom_hold_a[21:3], 2'd1}],
				               gfxrom[{rom_hold_a[21:3], 2'd0}] };
				rom_valid <= 1'b1;
				rom_busy  <= 1'b0;
				rom_reads <= rom_reads + 1;
			end else rom_cnt <= rom_cnt - 1;
		end
	end

	// The download-time layout permutation, driven through the same RTL module
	// the real downloader will use.
	logic [22:0] swz_half_words, swz_in;
	wire  [22:0] swz_out;
	gfx_swizzle #(.AW(23)) u_swz (
		.half_words(swz_half_words), .word_in(swz_in), .word_out(swz_out)
	);

	// ---- fixtures -----------------------------------------------------------
	logic [23:0] expect_rgb [0:MAX_PIX-1];
	logic [15:0] codeimg [0:8191];
	logic  [7:0] ylowimg [0:1023];
	logic  [7:0] ctrlimg [0:3];
	logic [15:0] palimg  [0:PAL_MAX-1];

	int vis_x0, vis_x1, vis_y0, vis_y1, vis_w, vis_h, pal_entries;
	int bad = 0, checked = 0, frame = 0;
	int first_bad_x = -1, first_bad_y = -1;
	logic [23:0] first_bad_got, first_bad_want;

	task l0_vram_write(input [12:0] a, input [15:0] d);
		@(posedge clk);
		l0v_addr <= a; l0v_wdata <= d; l0v_we <= 1'b1;
		@(posedge clk);
		l0v_we <= 1'b0;
	endtask
	task l1_vram_write(input [12:0] a, input [15:0] d);
		@(posedge clk);
		l1v_addr <= a; l1v_wdata <= d; l1v_we <= 1'b1;
		@(posedge clk);
		l1v_we <= 1'b0;
	endtask
	task l0_ctrl_write(input [1:0] a, input [15:0] d);
		@(posedge clk);
		l0c_addr <= a; l0c_wdata <= d; l0c_we <= 1'b1;
		@(posedge clk);
		l0c_we <= 1'b0;
	endtask
	task l1_ctrl_write(input [1:0] a, input [15:0] d);
		@(posedge clk);
		l1c_addr <= a; l1c_wdata <= d; l1c_we <= 1'b1;
		@(posedge clk);
		l1c_we <= 1'b0;
	endtask

	task cpu_code_write(input [12:0] a, input [15:0] d);
		@(posedge clk);
		code_addr <= a; code_wdata <= d;
		code_uds <= 1'b1; code_lds <= 1'b1; code_we <= 1'b1;
		@(posedge clk);
		code_we <= 1'b0; code_uds <= 1'b0; code_lds <= 1'b0;
	endtask
	task cpu_ylow_write(input [9:0] a, input [7:0] d);
		@(posedge clk);
		ylow_addr <= a; ylow_wdata <= d; ylow_we <= 1'b1;
		@(posedge clk);
		ylow_we <= 1'b0;
	endtask
	task cpu_ctrl_write(input [1:0] a, input [7:0] d);
		@(posedge clk);
		ctrl_addr <= a; ctrl_wdata <= d; ctrl_we <= 1'b1;
		@(posedge clk);
		ctrl_we <= 1'b0;
	endtask
	task cpu_pal_write(input [10:0] a, input [15:0] d);
		@(posedge clk);
		pal_addr <= a; pal_wdata <= d;
		pal_uds <= 1'b1; pal_lds <= 1'b1; pal_we <= 1'b1;
		@(posedge clk);
		pal_we <= 1'b0; pal_uds <= 1'b0; pal_lds <= 1'b0;
	endtask

	// ---- sample the frame the way the framework does -------------------------
	// On vga_ce with vga_de high, in order. Nothing here knows about hcount or
	// the line buffer; if the picture is presented at the wrong time, it is
	// wrong here.
	int px_x = 0, px_y = 0;
	logic vs_prev = 0;
	logic [23:0] got_rgb [0:MAX_PIX-1];
	int got_count = 0;

	always @(posedge clk) begin
		if (!reset && vga_ce) begin
			vs_prev <= vga_vs;
			// Rising edge of vsync starts a new frame.
			if (vga_vs && !vs_prev) begin
				frame     <= frame + 1;
				px_x      <= 0;
				px_y      <= 0;
				got_count <= 0;
			end else if (vga_de) begin
				if (got_count < MAX_PIX) got_rgb[got_count] <= {vga_r, vga_g, vga_b};
				got_count <= got_count + 1;
			end
		end
	end

	int i, k;
	initial begin
		for (i = 0; i < MAX_PIX; i++)   expect_rgb[i] = 24'hxxxxxx;
		for (i = 0; i < MAX_PIX; i++)   got_rgb[i]    = 24'h000000;
		for (i = 0; i < GFX_WORDS; i++) begin gfxrom[i] = 16'h0; gfxnat[i] = 16'h0; end
		for (i = 0; i < 8192; i++)      codeimg[i] = 16'hxxxx;
		for (i = 0; i < 1024; i++)      ylowimg[i] = 8'hxx;
		for (i = 0; i < 4; i++)         ctrlimg[i] = 8'hxx;
		for (i = 0; i < PAL_MAX; i++)   palimg[i]  = 16'h0;
		for (i = 0; i < 64; i++)        cfgv[i]    = 32'h0;

		// $readmemh resolves against the SIMULATOR's CWD; run_sim.sh runs from
		// the repository root.
		$readmemh("sim/seta_video_tb/cfg.hex",  cfgv);
		$readmemh("sim/seta_video_tb/code.hex", codeimg);
		$readmemh("sim/seta_video_tb/ylow.hex", ylowimg);
		$readmemh("sim/seta_video_tb/ctrl.hex", ctrlimg);
		$readmemh("sim/seta_video_tb/pal.hex",  palimg);
		$readmemh("sim/seta_video_tb/gfx.hex",  gfxnat);
		$readmemh("sim/seta_video_tb/gfx2.hex", gfx2rom);
		$readmemh("sim/seta_video_tb/gfx3.hex", gfx3rom);
		$readmemh("sim/seta_video_tb/l0vram.hex", l0v_init);
		$readmemh("sim/seta_video_tb/l0ctrl.hex", l0c_init);
		$readmemh("sim/seta_video_tb/l1vram.hex", l1v_init);
		$readmemh("sim/seta_video_tb/l1ctrl.hex", l1c_init);
		$readmemh("sim/seta_video_tb/rgb.hex",  expect_rgb);

		if ($isunknown(codeimg[0]) || $isunknown(expect_rgb[0])) begin
			$display("FAIL: fixtures missing -- run scripts/prep_video_tb.py");
			$finish;
		end

		vis_x0 = cfgv[C_HAS];  vis_x1 = cfgv[C_HAE];
		vis_y0 = cfgv[C_VAS];  vis_y1 = cfgv[C_VAE];
		vis_w  = vis_x1 - vis_x0 + 1;
		vis_h  = vis_y1 - vis_y0 + 1;
		pal_entries = cfgv[C_PALENT];

		swz_half_words = cfgv[C_GFXHALF][23:1];
		for (i = 0; i < 2 * int'(swz_half_words); i++) begin
			swz_in = i[22:0];
			#1 gfxrom[swz_out[20:0]] = gfxnat[i];
		end

		void'($value$plusargs("ROMLAT=%d", rom_latency));
		$display("=== the video path against MAME's own render ===");
		$display("  visible      %0dx%0d at x %0d y %0d", vis_w, vis_h, vis_x0, vis_y0);
		$display("  timing       htotal %0d vtotal %0d", cfgv[C_HTOTAL], cfgv[C_VTOTAL]);
		$display("  palette      %0d entries", pal_entries);
		$display("  line budget  %0d", cfgv[C_BUDGET]);
		$display("  ROM latency  %0d cycles", rom_latency);

		repeat (8) @(posedge clk);
		reset <= 0;
		repeat (4) @(posedge clk);

		for (i = 0; i < 4; i++)          cpu_ctrl_write(i[1:0], ctrlimg[i]);

		// The tile layers, where the fixture has them. has_l0 / has_l1 low
		// leaves both idle and the mixer on the sprite buffer alone.
		if (cfgv[C_HAS_L0][0]) begin
			for (i = 0; i < 8192; i++) l0_vram_write(i[12:0], l0v_init[i]);
			for (i = 0; i < 3; i++)    l0_ctrl_write(i[1:0], l0c_init[i]);
		end
		if (cfgv[C_HAS_L1][0]) begin
			for (i = 0; i < 8192; i++) l1_vram_write(i[12:0], l1v_init[i]);
			for (i = 0; i < 3; i++)    l1_ctrl_write(i[1:0], l1c_init[i]);
		end
		for (i = 0; i < 'h300; i++)      cpu_ylow_write(i[9:0], ylowimg[i]);
		for (i = 0; i < 8192; i++)       cpu_code_write(i[12:0], codeimg[i]);
		for (i = 0; i < pal_entries; i++) cpu_pal_write(i[10:0], palimg[i]);
		$display("  registers loaded at frame %0d", frame);

		// Let the frame in progress finish, then capture the NEXT whole one.
		@(negedge vga_vs);
		@(posedge vga_vs);
		@(negedge vga_vs);
		@(posedge vga_vs);
		@(posedge clk);

		$display("");
		$display("  pixels presented %0d (expected %0d)", got_count, vis_w * vis_h);
		if (got_count != vis_w * vis_h) begin
			$display("FAIL: the active window is the wrong size -- htotal/vtotal or the visarea does not match the fixture");
			$finish;
		end

		for (k = 0; k < vis_w * vis_h; k++) begin
			checked++;
			if (got_rgb[k] !== expect_rgb[k]) begin
				bad++;
				if (first_bad_x < 0) begin
					first_bad_x = k % vis_w;
					first_bad_y = k / vis_w;
					first_bad_got  = got_rgb[k];
					first_bad_want = expect_rgb[k];
				end
			end
		end

		begin
			int fh;
			fh = $fopen("sim/seta_video_tb/got.hex", "w");
			for (k = 0; k < vis_w * vis_h; k++) $fdisplay(fh, "%06x", got_rgb[k]);
			$fclose(fh);
		end
		$display("  pixels checked   %0d", checked);
		$display("  mismatches       %0d", bad);
		$display("  lines rendered   %0d", dbg_lines);
		$display("  sprites blitted  %0d", dbg_sprites);
		$display("  ROM granules     %0d", dbg_fetches);
		$display("  line overruns    %0d", dbg_overrun);
		$display("  lines cut short  %0d", dbg_dropped);
		$display("  worst line       %0d cycles (%0d sprites)",
		         dbg_worst_line, dbg_worst_sprites);
		if (first_bad_x >= 0)
			$display("  FIRST at x=%0d y=%0d: RTL %06x, MAME %06x",
			         first_bad_x, first_bad_y, first_bad_got, first_bad_want);
		$display("");

		if (checked == 0)
			$display("FAIL: nothing was compared");
		else if (bad != 0)
			$display("FAIL: the video path disagrees with MAME");
		else if (dbg_overrun != 0)
			$display("FAIL: %0d line(s) were still rendering at the next line_start",
			         dbg_overrun);
		else
			$display("PASS: %0d pixels identical to MAME's own render", checked);
		$finish;
	end

	initial begin
		#900ms;
		$display("FAIL: timed out -- %0d lines rendered, %0d pixels presented",
		         dbg_lines, got_count);
		$finish;
	end

endmodule
