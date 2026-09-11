// The X1-001 sprite engine against scripts/x1_001_model.py, pixel for pixel.
//
//     python scripts/mame_capture.py thunderl --frame 300 --name tl300
//     python scripts/prep_x1_001_tb.py thunderl debug/tl300
//     scripts/run_sim.sh x1_001_tb                (from the repository root)
//
// The RTL renders per SCANLINE from live RAM; MAME renders a whole frame at
// once from the state at the end of it. Those are different machines, so the
// chain is checked in two halves that each compare like with like:
//
//     x1_001.cpp  ==  x1_001_model.py     24 captured frames over 8 sets,
//                                         pixel-identical (x1_001_sweep.py)
//     model       ==  rtl/video/x1_001.sv this bench
//
// Both render the SAME fixed register state -- nothing writes to the chip
// while the frame is being drawn -- so the difference in WHEN they read it
// cannot arise.
//
// THE REGISTERS ARE LOADED THROUGH THE CPU PORTS, not backdoor-written, so a
// width or byte-lane error in the interface shows up here rather than on
// hardware. x1_010's bench learned this the other way round: loading after
// reset instead of under it made the comparison meaningless and read exactly
// like a dead engine.
//
// THE LINE BUFFER IS READ BACK THE WAY THE VIDEO SIDE WILL READ IT -- one line
// behind, out of the buffer the engine is not writing. Reading the buffer just
// rendered, before the next line_start has swapped it, would test a
// double-buffer that does not exist.

`timescale 1ns / 1ps

module tb_x1_001;

	localparam realtime CLK_PERIOD = 10.4167;    // 96 MHz clk_sys
	localparam int LB_W      = 11;
	// 1M words = the 2 MB region atehate has, which is the largest in Group A.
	// Sized to the phase rather than to seta.cpp's largest (gundhara's 8 MB):
	// ModelSim ASE allocates the whole array, and three quarters of it would
	// be zeroes slowing every run down.
	localparam int GFX_WORDS = 1 << 21;         // msgundam's 4 MB region

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;
	logic reset = 1;

	// ---- configuration, read positionally from cfg.hex ----------------------
	// The order MUST match scripts/prep_x1_001_tb.py's CFG list.
	logic [31:0] cfgv [0:31];
	localparam int C_FGX = 0, C_FGXF = 1, C_FGY = 2, C_FGYF = 3;
	localparam int C_BGX = 4, C_BGXF = 5, C_BGY = 6, C_BGYF = 7;
	localparam int C_BANKSZ = 8, C_SPRLIM = 9, C_TRANSPEN = 10, C_BGOPAQUE = 11;
	localparam int C_CB_FG = 12, C_CB_BG = 13, C_SCRH = 14, C_VISMAXY = 15;
	localparam int C_BACKDROP = 16, C_GFXHALF = 17, C_CODEMASK = 18;
	localparam int C_X0 = 19, C_X1 = 20, C_Y0 = 21, C_Y1 = 22;

	// ---- DUT ----------------------------------------------------------------
	logic        code_we = 0, code_uds = 0, code_lds = 0;
	logic [12:0] code_addr = 0;
	logic [15:0] code_wdata = 0;
	wire  [15:0] code_rdata;

	logic        ylow_we = 0;
	logic  [9:0] ylow_addr = 0;
	logic  [7:0] ylow_wdata = 0;
	wire   [7:0] ylow_rdata;

	logic        ctrl_we = 0;
	logic  [1:0] ctrl_addr = 0;
	logic  [7:0] ctrl_wdata = 0;
	wire   [7:0] ctrl_rdata;

	logic        line_start = 0;
	logic        vblank_rise = 0;
	// +nocopy: skip the setac_eof copy test (render straight from the dump).
	logic        copy_test = 1'b1;
	int          copy_bad = 0;
	logic  [8:0] line = 0;
	wire         line_done, busy;

	wire         rom_req;
	wire  [23:3] rom_addr;
	logic        rom_valid = 0;
	logic [63:0] rom_data = 0;

	logic  [8:0] lb_addr = 0;
	wire [LB_W-1:0] lb_data;

	wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun;
	wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped;
	// 0 = no cutoff, which is what the model comparison needs: the model has
	// no time limit either, so a capped engine would be diffing two different
	// pictures. +BUDGET=n turns it on to measure what the cap actually costs.
	logic [15:0] line_budget = 16'd0;

	x1_001 #(.LB_W(LB_W)) dut (
		.clk(clk), .reset(reset),
		.code_we(code_we), .code_addr(code_addr), .code_wdata(code_wdata),
		.code_uds(code_uds), .code_lds(code_lds), .code_rdata(code_rdata),
		.ylow_we(ylow_we), .ylow_addr(ylow_addr), .ylow_wdata(ylow_wdata),
		.ylow_rdata(ylow_rdata),
		.ctrl_we(ctrl_we), .ctrl_addr(ctrl_addr), .ctrl_wdata(ctrl_wdata),
		.ctrl_rdata(ctrl_rdata),
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
		.vblank_rise(vblank_rise), .buffer_sprites(copy_test),
		.line_start(line_start), .line(line),
		.line_done(line_done), .busy(busy),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.lb_addr(lb_addr), .lb_data(lb_data),
		.dbg_lines(dbg_lines), .dbg_sprites(dbg_sprites),
		.dbg_fetches(dbg_fetches), .dbg_overrun(dbg_overrun),
		.dbg_worst_line(dbg_worst_line), .dbg_worst_sprites(dbg_worst_sprites),
		.line_budget(line_budget), .dbg_dropped(dbg_dropped)
	);

	// ---- graphics ROM: 64-bit granules, with a settable latency -------------
	// Behavioural, but never instantaneous: the real path is an SDRAM round
	// trip and the engine must not depend on the answer arriving in any
	// particular cycle. The production transport is a separate, later test --
	// LESSONS_LEARNED is explicit that a latency sweep against a behavioural
	// model is a proxy, not a proof.
	//
	// A granule is four consecutive 16-bit words, word i at g_data[16*i], which
	// is sdram.sv's order as documented in sdram_narrow_bridge.sv.
	logic [15:0] gfxrom [0:GFX_WORDS-1];
	int   rom_latency = 12;
	int   rom_cnt = 0;
	logic rom_busy = 0;
	logic [23:3] rom_hold_a;
	int   rom_reads = 0;
	longint rom_wait_cycles = 0;

	always @(posedge clk) begin
		rom_valid <= 1'b0;
		if (reset) rom_busy <= 1'b0;
		else if (rom_req && !rom_busy) begin
			rom_busy <= 1'b1; rom_hold_a <= rom_addr; rom_cnt <= rom_latency;
		end else if (rom_busy) begin
			rom_wait_cycles <= rom_wait_cycles + 1;
			if (rom_cnt <= 1) begin
				// [21:3]. GFX_WORDS is 2^21 words (msgundam's 4 MB), so a word
				// index is 21 bits and a GRANULE index is 19. Slicing 17 dropped the
				// top bit -- invisible on thunderl's 0.5 MB region, which needs
				// 16, and wrong on atehate's 2 MB one, which needs all 18. It
				// failed as wrong pen values on exactly one game. Same shape as
				// the bridge width bug in LESSONS_LEARNED: harmless at 64 KB,
				// not at 2 MB.
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

	// ---- the download-time layout permutation, EXERCISED not assumed --------
	// gfx.hex is MAME's "gfx1" region as the driver loads it. The real core
	// permutes word addresses on the way into SDRAM so a sprite row is one
	// granule; this drives the SAME RTL module the downloader will, word by
	// word, and the engine then reads the result. If the permutation is wrong
	// the pixels are wrong -- there is no path where a broken swizzle passes.
	logic [15:0] gfxnat [0:GFX_WORDS-1];
	logic [22:0] swz_half_words, swz_in;
	wire  [22:0] swz_out;
	gfx_swizzle #(.AW(23)) u_swz (
		.half_words(swz_half_words), .word_in(swz_in), .word_out(swz_out)
	);

	// ---- expected pixels ----------------------------------------------------
	localparam int MAX_PIX = 384 * 256;
	logic [11:0] expect_mem [0:MAX_PIX-1];
	logic [15:0] codeimg [0:8191];
	logic  [7:0] ylowimg [0:1023];
	logic  [7:0] ctrlimg [0:3];

	int vis_x0, vis_x1, vis_y0, vis_y1, vis_w;
	int bad = 0, checked = 0;
	int first_bad_x = -1, first_bad_y = -1;
	logic [11:0] first_bad_got, first_bad_want;
	int worst_line_cycles = 0;

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

	// Read back one rendered line out of the buffer the engine is NOT writing,
	// and compare it against the model.
	//
	// THE ADDRESS LEADS THE DATA BY TWO CYCLES, not one. lb_addr is an input
	// that this bench registers, and the RAM output is registered again inside
	// the module -- so an address driven at the end of cycle k is presented to
	// the array during k+1 and its data is only readable in k+2. Assuming one
	// produced a picture that matched the model everywhere except shifted one
	// pixel left, which the mismatch count alone reported as 46% of the frame
	// wrong. The video timing generator needs the same two-cycle lead.
	// Every rendered pixel is also written to sim/x1_001_tb/got.hex, in the
	// same order as expect.hex. A count of mismatches says a renderer is
	// wrong; the two files side by side say HOW -- a constant offset, a
	// swapped nibble, one sprite missing -- which is the difference between a
	// diagnosis and a guess.
	int fh;

	task check_line(input int y);
		int x;
		logic [11:0] want, got;
		begin
			for (x = 0; x <= vis_x1 + 2; x++) begin
				@(posedge clk);
				lb_addr <= x[8:0];
				if (x >= vis_x0 + 2) begin
					got  = {1'b0, lb_data};
					want = expect_mem[(y - vis_y0) * vis_w + (x - 2 - vis_x0)];
					$fdisplay(fh, "%03x", got);
					checked++;
					if (got !== want) begin
						bad++;
						if (first_bad_x < 0) begin
							first_bad_x = x - 2; first_bad_y = y;
							first_bad_got = got; first_bad_want = want;
						end
					end
				end
			end
		end
	endtask

	int i, y;
	int t0;
	initial begin
		for (i = 0; i < MAX_PIX; i++)   expect_mem[i] = 12'hfff;
		for (i = 0; i < GFX_WORDS; i++) gfxrom[i] = 16'h0000;
		for (i = 0; i < GFX_WORDS; i++) gfxnat[i] = 16'h0000;
		for (i = 0; i < 8192; i++)      codeimg[i] = 16'hxxxx;
		for (i = 0; i < 1024; i++)      ylowimg[i] = 8'hxx;
		for (i = 0; i < 4; i++)         ctrlimg[i] = 8'hxx;
		for (i = 0; i < 32; i++)        cfgv[i] = 32'h0;

		// $readmemh resolves against the SIMULATOR's CWD, not this file.
		// scripts/run_sim.sh runs from the repository root.
		$readmemh("sim/x1_001_tb/cfg.hex",    cfgv);
		$readmemh("sim/x1_001_tb/code.hex",   codeimg);
		$readmemh("sim/x1_001_tb/ylow.hex",   ylowimg);
		$readmemh("sim/x1_001_tb/ctrl.hex",   ctrlimg);
		$readmemh("sim/x1_001_tb/gfx.hex",    gfxnat);
		$readmemh("sim/x1_001_tb/expect.hex", expect_mem);

		if ($isunknown(codeimg[0]) || $isunknown(ctrlimg[0])) begin
			$display("FAIL: fixtures missing -- run scripts/prep_x1_001_tb.py");
			$finish;
		end

		// cfg's gfx_half is the RGN_FRAC half in BYTES; the swizzle counts
		// 16-bit words, so half the value.
		swz_half_words = cfgv[C_GFXHALF][23:1];
		for (i = 0; i < 2 * int'(swz_half_words); i++) begin
			swz_in = i[22:0];
			#1 gfxrom[swz_out[20:0]] = gfxnat[i];
		end
		$display("  gfx swizzled: %0d words, half %0d",
		         2 * int'(swz_half_words), swz_half_words);

		vis_x0 = cfgv[C_X0];  vis_x1 = cfgv[C_X1];
		vis_y0 = cfgv[C_Y0];  vis_y1 = cfgv[C_Y1];
		vis_w  = vis_x1 - vis_x0 + 1;

		void'($value$plusargs("ROMLAT=%d", rom_latency));
		void'($value$plusargs("BUDGET=%d", line_budget));
		$display("=== X1-001 against scripts/x1_001_model.py ===");
		$display("  visible      x %0d..%0d  y %0d..%0d", vis_x0, vis_x1, vis_y0, vis_y1);
		$display("  spritectrl   %02x %02x %02x %02x",
		         ctrlimg[0], ctrlimg[1], ctrlimg[1], ctrlimg[3]);
		$display("  bank         %0d   numcol %0d",
		         ((ctrlimg[1] ^ (~ctrlimg[1] << 1)) & 8'h40) ? 1 : 0, ctrlimg[1] & 4'hf);
		$display("  ROM latency  %0d cycles", rom_latency);

		fh = $fopen("sim/x1_001_tb/got.hex", "w");

		repeat (8) @(posedge clk);
		reset <= 0;
		repeat (4) @(posedge clk);

		// Load through the CPU ports. Slow in simulation and deliberately so:
		// a backdoor $readmemh into the DUT's arrays would not exercise the
		// byte lanes, and the byte lanes are where a 16-bit peripheral on a
		// 68000 goes wrong.
		for (i = 0; i < 4; i++)      cpu_ctrl_write(i[1:0], ctrlimg[i]);
		for (i = 0; i < 'h300; i++)  cpu_ylow_write(i[9:0], ylowimg[i]);
		for (i = 0; i < 8192; i++)   cpu_code_write(i[12:0], codeimg[i]);
		$display("  registers loaded");

		// THE COPY IS EXERCISED, as a RAM check. The capture is mid-frame: bank 0
		// already holds the list the game is writing for the NEXT frame, so a
		// render after the copy cannot match MAME's frame. Blank the half the
		// chip copies into, let one vblank copy, and compare the halves word for
		// word; then put the dump back and render from it with the copy off.
		if (copy_test && !ctrlimg[1][5]) begin
			for (i = 0; i < 'h800; i++)
				cpu_code_write((ctrlimg[1][6] ? 13'h0000 : 13'h1000) + i[12:0], 16'h0000);
			vblank_rise <= 1'b1; @(posedge clk); vblank_rise <= 1'b0;
			repeat (12000) @(posedge clk);
			copy_bad = 0;
			for (i = 0; i < 'h800; i++)
				if (dut.codemem[(ctrlimg[1][6] ? 13'h0000 : 13'h1000) + i[12:0]] !==
				    dut.codemem[(ctrlimg[1][6] ? 13'h1000 : 13'h0000) + i[12:0]]) copy_bad++;
			$display("  setac_eof copy (ctrl2 = %02x): %0d of 2048 words differ", ctrlimg[1], copy_bad);
			for (i = 0; i < 8192; i++) cpu_code_write(i[12:0], codeimg[i]);
			copy_test = 1'b0;
		end

		// The engine renders from the snapshot taken at vblank: take one, and
		// wait out the 9216-cycle copy.
		vblank_rise <= 1'b1; @(posedge clk); vblank_rise <= 1'b0;
		repeat (12000) @(posedge clk);

		// Prime: render the first visible line into one buffer, then run the
		// real cadence -- start line L, read back line L-1 while it renders.
		line <= vis_y0[8:0];
		line_start <= 1'b1; @(posedge clk); line_start <= 1'b0;
		wait (line_done);
		@(posedge clk);

		for (y = vis_y0 + 1; y <= vis_y1 + 1; y++) begin
			t0 = $time / CLK_PERIOD;
			line <= y[8:0];
			line_start <= 1'b1; @(posedge clk); line_start <= 1'b0;
			check_line(y - 1);
			wait (!busy);
			if (($time / CLK_PERIOD) - t0 > worst_line_cycles)
				worst_line_cycles = ($time / CLK_PERIOD) - t0;
			@(posedge clk);
		end

		$fclose(fh);
		$display("");
		$display("  pixels checked   %0d", checked);
		$display("  mismatches       %0d", bad);
		$display("  lines rendered   %0d", dbg_lines);
		$display("  sprites blitted  %0d", dbg_sprites);
		$display("  ROM words read   %0d", dbg_fetches);
		$display("  line overruns    %0d", dbg_overrun);
		$display("  lines cut short  %0d (budget %0d)", dbg_dropped, line_budget);
		$display("  worst line       %0d clk_sys cycles (%0d sprites)",
		         dbg_worst_line, dbg_worst_sprites);
		$display("  ROM wait cycles  %0d of those, over %0d reads",
		         rom_wait_cycles, rom_reads);
		if (first_bad_x >= 0)
			$display("  FIRST at x=%0d y=%0d: RTL %03x, model %03x",
			         first_bad_x, first_bad_y, first_bad_got, first_bad_want);
		$display("");

		if (checked == 0)
			$display("FAIL: nothing was compared -- run scripts/prep_x1_001_tb.py");
		else if (copy_bad != 0)
			$display("FAIL: the setac_eof copy left %0d words wrong", copy_bad);
		else if (bad != 0)
			$display("FAIL: the RTL disagrees with the model");
		else if (dbg_overrun != 0)
			$display("FAIL: %0d line(s) were still rendering at the next line_start",
			         dbg_overrun);
		else
			$display("PASS: %0d pixels identical to the model", checked);
		$finish;
	end

	// A stuck engine is a hang, not a failure, unless it is bounded.
	initial begin
		#800ms;
		$display("FAIL: timed out -- engine state %0d, %0d lines done",
		         dut.state, dbg_lines);
		$finish;
	end

endmodule
