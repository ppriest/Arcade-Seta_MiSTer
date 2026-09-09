// x1_012 against scripts/x1_012_model.py, one captured frame at a time.
//
//     python scripts/prep_x1_012_tb.py drgnunit debug/p2-drgnunit-f900
//     scripts/run_sim.sh x1_012_tb +ROMLAT=12
//
// The expected image is THE LAYER ALONE. This bench tests one chip; the
// sprites have their own bench, and the composite of the two is what gets
// compared against MAME's own render.
//
// WHAT THIS DOES NOT COVER YET: flip screen. update_scroll's flipped branch
// and the tilemap's whole-map mirroring are not implemented in x1_012.sv, and
// every Phase 2 capture has flipscr clear -- so a pass here says nothing about
// them either way. The bench refuses a flipped fixture rather than reporting a
// green it has not earned.
`timescale 1ns / 1ps

module tb_x1_012;

	localparam int LB_W = 11;

	logic clk = 0;
	logic reset = 1;
	always #5 clk = ~clk;              // 100 MHz, period irrelevant here

	// ---- configuration, from cfg.hex ---------------------------------------
	logic [31:0] cfgmem [0:9];
	logic signed [8:0] xoffs, xoffs_flip;
	logic        flipscr;
	logic  [8:0] vis_dimy;
	logic [LB_W-1:0] colorbase;
	logic [15:0] code_mask;
	int          vis_x0, vis_x1, vis_y0, vis_y1;

	// ---- DUT ---------------------------------------------------------------
	logic        vram_we = 0;
	logic [12:0] vram_addr = 0;
	logic [15:0] vram_wdata = 0;
	logic        vctrl_we = 0;
	logic  [1:0] vctrl_addr = 0;
	logic [15:0] vctrl_wdata = 0;

	logic        line_start = 0;
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
		.vram_uds(1'b1), .vram_lds(1'b1), .vram_rdata(),
		.vctrl_we(vctrl_we), .vctrl_addr(vctrl_addr), .vctrl_wdata(vctrl_wdata),
		.vctrl_uds(1'b1), .vctrl_lds(1'b1), .vctrl_rdata(),
		.xoffs(xoffs), .xoffs_flip(xoffs_flip), .flipscr(flipscr),
		.vis_dimy(vis_dimy), .colorbase(colorbase), .code_mask(code_mask),
		.line_start(line_start), .line(line), .line_budget(16'd0),
		.line_done(line_done), .busy(busy),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.lb_addr(lb_addr), .lb_data(lb_data),
		.dbg_lines(), .dbg_tiles(), .dbg_overrun()
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
		code_mask  = cfgmem[5][15:0];
		vis_x0     = cfgmem[6];
		vis_x1     = cfgmem[7];
		vis_y0     = cfgmem[8];
		vis_y1     = cfgmem[9];

		void'($value$plusargs("ROMLAT=%d", rom_latency));

		// FLIP SCREEN IS NOT IMPLEMENTED in x1_012.sv -- neither update_scroll's
		// flipped branch nor the whole-map mirroring. Refuse rather than report
		// a pass that would mean nothing.
		if (flipscr) begin
			$display("SKIP: flip screen is set in this fixture and x1_012.sv does not implement it yet -- a pass would be vacuous");
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

		for (i = vis_y0; i <= vis_y1; i = i + 1) do_line(i);

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
