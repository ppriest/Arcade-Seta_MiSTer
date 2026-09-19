// x1_012 against scripts/x1_012_model.py, one captured frame at a time.
//
//     python scripts/prep_x1_012_tb.py drgnunit debug/p2-drgnunit-f900
//     scripts/run_sim.sh x1_012_tb +ROMLAT=12
//
// The expected image is THE LAYER ALONE. This bench tests one chip; the
// sprites have their own bench, and the composite of the two is what gets
// compared against MAME's own render.
//
// WHAT THIS DOES NOT COVER: flip screen. The bench refuses a flipped fixture;
// flipped layers are checked against MAME through sim/seta_video_tb by
// scripts/flip_sweep.py.
`timescale 1ns / 1ps

module tb_x1_012;

	localparam int LB_W = 11;

	logic clk = 0;
	logic reset = 1;
	always #5 clk = ~clk;              // 100 MHz, period irrelevant here

	// ---- configuration, from cfg.hex ---------------------------------------
	logic [31:0] cfgmem [0:10];
	logic signed [8:0] xoffs, xoffs_flip;
	logic        flipscr;
	logic  [8:0] vis_dimy;
	logic [LB_W-1:0] colorbase;
	logic [15:0] code_limit;
	logic        bpp6;
	int          vis_x0, vis_x1, vis_y0, vis_y1;

	// ---- DUT ---------------------------------------------------------------
	logic        vram_we = 0;
	logic        vram_drain = 0;
	wire         vram_busy;
	wire  [15:0] vram_rdata;
	logic [12:0] vram_addr = 0;
	logic [15:0] vram_wdata = 0;
	logic        vctrl_we = 0;
	logic  [1:0] vctrl_addr = 0;
	logic [15:0] vctrl_wdata = 0;

	logic        line_start = 0;
	logic        vblank_rise = 0;
	logic  [8:0] line = 0;
	logic        line_done, busy;

	logic        rom_req;
	logic [23:3] rom_addr;
	logic        rom_valid = 0;
	logic [63:0] rom_data = 0;

	logic  [8:0] lb_addr = 0;
	logic [LB_W-1:0] lb_data;

	x1_012 #(.LB_W(LB_W)) dut (
		.clk(clk), .reset(reset),
		.vram_we(vram_we), .vram_addr(vram_addr), .vram_wdata(vram_wdata),
		.vram_uds(1'b1), .vram_lds(1'b1), .vram_rdata(vram_rdata),
		.vram_drain(vram_drain), .vram_busy(vram_busy),
		.vctrl_we(vctrl_we), .vctrl_addr(vctrl_addr), .vctrl_wdata(vctrl_wdata),
		.vctrl_uds(1'b1), .vctrl_lds(1'b1), .vctrl_rdata(),
		.xoffs(xoffs), .xoffs_flip(xoffs_flip), .flipscr(flipscr),
		// Only used flipped, and this bench refuses a flipped fixture: flip is
		// covered end to end by scripts/flip_sweep.py through sim/seta_video_tb.
		.xextent(10'd384), .yextent(9'd256),
		.vis_dimy(vis_dimy), .colorbase(colorbase), .code_limit(code_limit),
		.tile_bank_en(1'b0), .tile_bank(32'd0),
		.bpp6(bpp6),
		.vblank_rise(vblank_rise), .raster(1'b0),
		.line_start(line_start), .line(line), .line_budget(16'd0), .cache_en(1'b1),
		.line_done(line_done), .busy(busy),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.lb_addr(lb_addr), .lb_data(lb_data),
		.dbg_cut(), .dbg_hits(), .dbg_overrun()
	);

	// ---- the tile ROM ------------------------------------------------------
	// A granule is four consecutive 16-bit words, word i in bits [16*i +: 16],
	// which is sdram.sv's order. gfx2.hex is already in SDRAM byte order.
	localparam int GFX_WORDS = 1 << 20;      // 2 MB of region, in words
	logic [15:0] gfxrom [0:GFX_WORDS-1];
	int   rom_latency = 12;
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
				rom_data  <= { gfxrom[{rom_hold_a[20:3], 2'd3}],
				               gfxrom[{rom_hold_a[20:3], 2'd2}],
				               gfxrom[{rom_hold_a[20:3], 2'd1}],
				               gfxrom[{rom_hold_a[20:3], 2'd0}] };
				rom_valid <= 1'b1;
				rom_busy  <= 1'b0;
				rom_reads <= rom_reads + 1;
			end else rom_cnt <= rom_cnt - 1;
		end
	end

	// ---- expected image ----------------------------------------------------
	localparam int MAXPIX = 384 * 240;
	logic [11:0] expect_mem [0:MAXPIX-1];

	int mismatches = 0;
	int checked = 0;
	int first_x = -1, first_y = -1;
	logic [11:0] first_want, first_got;

	task cpu_vram_write(input [12:0] a, input [15:0] d);
		begin
			@(posedge clk);
			vram_we <= 1'b1; vram_addr <= a; vram_wdata <= d;
			@(posedge clk);
			vram_we <= 1'b0;
		end
	endtask

	task cpu_vctrl_write(input [1:0] a, input [15:0] d);
		begin
			@(posedge clk);
			vctrl_we <= 1'b1; vctrl_addr <= a; vctrl_wdata <= d;
			@(posedge clk);
			vctrl_we <= 1'b0;
		end
	endtask

	// Render one visible line and compare it.
	task do_line(input int y);
		int x;
		logic [11:0] want, got;
		begin
			// RENDERED TWICE, ON PURPOSE. The line buffer is double buffered:
			// line_start toggles render_bank and the readback side shows the
			// OTHER bank, so reading straight after one render reads the bank
			// that was not written. In the real video path that is what makes
			// the picture work -- the engine runs ahead of the display -- and
			// in a bench it means a second start is needed before the first
			// render is visible. Both renders are identical, so this costs
			// only time. Reading the wrong bank looked exactly like a colour
			// decode fault: every pixel came back 0.
			@(posedge clk);
			line       <= y[8:0];
			line_start <= 1'b1;
			@(posedge clk);
			line_start <= 1'b0;
			wait (line_done);
			@(posedge clk);

			@(posedge clk);
			line_start <= 1'b1;
			@(posedge clk);
			line_start <= 1'b0;
			wait (line_done);
			@(posedge clk);

			for (x = vis_x0; x <= vis_x1; x = x + 1) begin
				lb_addr <= x[8:0];
				@(posedge clk);
				@(posedge clk);          // one cycle of RAM, one of the mux
				got  = {1'b0, lb_data};
				want = expect_mem[(y - vis_y0) * (vis_x1 - vis_x0 + 1)
				                  + (x - vis_x0)];
				checked = checked + 1;
				if (got !== want) begin
					mismatches = mismatches + 1;
					if (first_x < 0) begin
						first_x = x; first_y = y;
						first_want = want; first_got = got;
					end
				end
			end
		end
	endtask

	int i;
	initial begin
		$readmemh("sim/x1_012_tb/cfg.hex",    cfgmem);
		$readmemh("sim/x1_012_tb/gfx2.hex",   gfxrom);
		$readmemh("sim/x1_012_tb/expect.hex", expect_mem);

		xoffs      = cfgmem[0][8:0];
		xoffs_flip = cfgmem[1][8:0];
		flipscr    = cfgmem[2][0];
		vis_dimy   = cfgmem[3][8:0];
		colorbase  = cfgmem[4][LB_W-1:0];
		code_limit = cfgmem[5][15:0];
		// From the fixture: prep_x1_012_tb.py knows which layout the game's
		// GFXDECODE names, and a plusarg would let the two disagree.
		bpp6       = cfgmem[10][0];
		vis_x0     = cfgmem[6];
		vis_x1     = cfgmem[7];
		vis_y0     = cfgmem[8];
		vis_y1     = cfgmem[9];

		void'($value$plusargs("ROMLAT=%d", rom_latency));

		// Flip screen is checked through sim/seta_video_tb by
		// scripts/flip_sweep.py; this bench's prep has no flipped reference.
		if (flipscr) begin
			$display("SKIP: flip screen is set in this fixture -- use scripts/flip_sweep.py");
			$finish;
		end

		repeat (8) @(posedge clk);
		reset = 0;
		repeat (4) @(posedge clk);

		// Load VRAM and the control registers the way the CPU would.
		for (i = 0; i < 8192; i = i + 1) begin
			cpu_vram_write(i[12:0], vram_init[i]);
		end
		for (i = 0; i < 3; i = i + 1) begin
			cpu_vctrl_write(i[1:0], vctrl_init[i]);
		end
		repeat (4) @(posedge clk);
		// The bank bit is latched at frame start; give it one, after the
		// registered control write has landed.
		vblank_rise <= 1'b1; @(posedge clk); vblank_rise <= 1'b0;
		repeat (2) @(posedge clk);

		for (i = vis_y0; i <= vis_y1; i = i + 1) do_line(i);

		// VRAM write queue: a write mid-frame is applied at the next vblank;
		// past the queue's depth a frame's writes go live, in order.
		begin
			logic [15:0] prev_w;
			int wait_bad = 0, live_bad = 0;
			prev_w = dut.vram[13'h0123];
			cpu_vram_write(13'h0123, ~prev_w);
			repeat (20) @(posedge clk);
			if (dut.vram[13'h0123] !== prev_w) wait_bad = 1;
			vblank_rise <= 1'b1; @(posedge clk); vblank_rise <= 1'b0;
			repeat (4) @(posedge clk);
			if (dut.vram[13'h0123] !== ~prev_w) wait_bad = wait_bad + 2;
			for (i = 0; i < 200; i = i + 1) cpu_vram_write(13'h0400 + i[12:0], 16'h1000 + i[15:0]);
			// and a later write to an address already queued must win
			cpu_vram_write(13'h0400, 16'hBEEF);
			// the queue drains a word a cycle; this bench writes every 2
			repeat (300) @(posedge clk);
			for (i = 1; i < 200; i = i + 1)
				if (dut.vram[13'h0400 + i[12:0]] !== 16'h1000 + i[15:0]) live_bad = live_bad + 1;
			if (dut.vram[13'h0400] !== 16'hBEEF) live_bad = live_bad + 1;
			$display("  queue: deferred write %s, overflowed frame %0d of 200 wrong",
			         wait_bad == 0 ? "held to vblank" : "WRONG", live_bad);
			if (wait_bad != 0 || live_bad != 0) mismatches = mismatches + 1;
		end
		// A CPU READ drains the queue first: a RAM test (Blandia at boot)
		// writes a block and reads it back within the frame.
		begin
			int rd_bad = 0;
			vblank_rise <= 1'b1; @(posedge clk); vblank_rise <= 1'b0;
			repeat (4) @(posedge clk);
			for (i = 0; i < 16; i = i + 1) cpu_vram_write(13'h0800 + i[12:0], 16'h5A00 + i[15:0]);
			for (i = 0; i < 16; i = i + 1) begin
				@(posedge clk);
				vram_addr <= 13'h0800 + i[12:0];
				vram_drain <= 1'b1;
				@(posedge clk);
				while (vram_busy) @(posedge clk);
				repeat (2) @(posedge clk);       // address, then data register
				if (vram_rdata !== 16'h5A00 + i[15:0]) rd_bad = rd_bad + 1;
				vram_drain <= 1'b0;
			end
			$display("  queue: CPU read after a queued write, %0d of 16 old", rd_bad);
			if (rd_bad != 0) mismatches = mismatches + 1;
		end

		$display("  ROM reads       %0d", rom_reads);
		$display("  pixels checked  %0d", checked);
		$display("  mismatches      %0d", mismatches);
		if (mismatches == 0)
			$display("PASS: %0d pixels identical to the model", checked);
		else
			$display("FAIL: %0d of %0d pixels differ; first at %0d,%0d: model %03x rtl %03x",
			         mismatches, checked, first_x, first_y, first_want, first_got);
		$finish;
	end

	// The fixture's own copies, read separately so the CPU-side writes above
	// exercise the real port rather than back-dooring the array.
	logic [15:0] vram_init  [0:8191];
	logic [15:0] vctrl_init [0:2];
	initial begin
		$readmemh("sim/x1_012_tb/vram.hex",  vram_init);
		$readmemh("sim/x1_012_tb/vctrl.hex", vctrl_init);
	end

	initial begin
		#200000000;
		$display("FAIL: timeout");
		$finish;
	end

endmodule
