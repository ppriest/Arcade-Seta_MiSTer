// seta_sdram_top: download a real ROM set, then read every region back through
// the port the core actually uses it from.
//
//     python scripts/prep_sdram_tb.py thunderl
//     scripts/run_sim.sh sdram_top_tb            (from the repository root)
//
// This is the test that the whole memory path composes. The individual pieces
// already have theirs -- sdram.sv, sdram_phy, the arbiter, the narrow bridge
// and gfx_swizzle are all exercised elsewhere -- but nothing until now has run
// a real image through the loader and then asked all three consumers whether
// they can find their own data. LESSONS_LEARNED is blunt that a behavioural
// stand-in is a proxy, not a proof: Psikyo had a handshake bug that every
// module-level simulation passed and only the real controller's latency
// exposed.
//
// THREE THINGS ARE CHECKED, and each is a byte-order or address question that
// looks like something else when it is wrong:
//
//   1. The CPU reads big-endian 68000 words. Four conventions meet on that
//      path -- the ioctl stream ascending, sdram_download pairing {odd, even}
//      with the even byte LOW, the narrow bridge passing the word through, and
//      maincpu.sv's ROM_BYTESWAP. This bench checks the first three; the
//      fourth is maincpu's own and is checked by sim/maincpu_sdram_tb.
//   2. A SPRITE ROW IS ONE GRANULE, in the right order. gfx_swizzle permutes
//      word addresses during the download so that {tile, yh, yl} names eight
//      contiguous bytes; the expectation here is computed from the NATURAL
//      region using the same layout arithmetic x1_001.sv uses, so a wrong
//      permutation cannot agree with a wrong reader.
//   3. The X1-010 reads single bytes, ascending, through a granule cache.
//
// ONLY REAL DATA IS STREAMED, at its real address. A `.mra` has to pad each
// region out to the next base because ioctl is sequential; this bench jumps
// instead, which sdram_download handles (a pending even byte with no partner
// is flushed as a single-byte write). Padding writes zeros and cannot change
// what is checked, and skipping it turns a 4 MB stream into a 1.6 MB one.

`timescale 1ns / 1ps

module tb_sdram_top;

	localparam realtime CLK_PERIOD = 10.4167;   // 96 MHz
	localparam int MAX_WORDS = 1 << 20;         // 2 MB, the largest region here

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	// Two reset domains, deliberately. MiSTer holds core RESET for the WHOLE
	// download, so the memory path must not be gated by it -- see
	// seta_sdram_top's header for what that costs when it is.
	logic mem_reset = 1;
	logic pll_locked = 0;

	// Must match seta_sdram_top's LAYOUT_A.
	localparam logic [25:0] BASE_MAINCPU = 26'h000_0000;
	localparam logic [25:0] BASE_GFX1    = 26'h010_0000;
	localparam logic [25:0] BASE_X1SND   = 26'h030_0000;

	// ---- fixtures ------------------------------------------------------------
	logic [15:0] maincpu_img [0:MAX_WORDS-1];
	logic [15:0] gfx1_img    [0:MAX_WORDS-1];
	logic [15:0] x1snd_img   [0:MAX_WORDS-1];
	logic [31:0] cfgv [0:7];
	localparam int C_HALFW = 0, C_MAINCPU_B = 1, C_GFX1_B = 2, C_X1SND_B = 3;

	// ---- DUT -----------------------------------------------------------------
	wire [12:0] SDRAM_A;
	wire [15:0] SDRAM_DQ;
	wire  [1:0] SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS,
	            SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

	logic        ioctl_download = 0;
	logic [15:0] ioctl_index = 0;
	logic        ioctl_wr = 0;
	logic [26:0] ioctl_addr = 0;
	logic  [7:0] ioctl_dout = 0;
	wire         ioctl_wait;

	logic        cpu_req = 0;
	logic [23:1] cpu_addr = 0;
	wire         cpu_valid;
	wire  [15:0] cpu_data;

	logic        spr_req = 0;
	logic [23:3] spr_addr = 0;
	wire         spr_valid;
	wire  [63:0] spr_data;

	logic        snd_req = 0;
	logic [19:0] snd_addr = 0;
	wire         snd_valid;
	wire   [7:0] snd_data;

	seta_sdram_top dut (
		.clk(clk), .reset(mem_reset), .init(~pll_locked),
		.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.gfx_half_words(cfgv[C_HALFW][22:0]),
		.cpu_req(cpu_req), .cpu_addr(cpu_addr),
		.cpu_valid(cpu_valid), .cpu_data(cpu_data),
		.spr_req(spr_req), .spr_addr(spr_addr),
		.spr_valid(spr_valid), .spr_data(spr_data),
		.snd_req(snd_req), .snd_addr(snd_addr),
		.snd_valid(snd_valid), .snd_data(snd_data)
	);

	sdram_chip_model_wide u_chip (
		.clk(SDRAM_CLK), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// ---- helpers -------------------------------------------------------------
	int bad = 0, checked = 0;

	task automatic fail(input string why);
		begin
			$display("FAIL: %s", why);
			bad++;
		end
	endtask

	// One byte into the ioctl port, honouring backpressure.
	//
	// THE ASSIGNMENTS FOLLOW THE WAIT WITH NO EDGE BETWEEN THEM. Putting an
	// `@(posedge clk)` there lets ioctl_wait rise again in the gap, so the
	// write is asserted into a stalled port and lost. That is what the first
	// version did, and it presented as every ODD word of the program coming
	// back wrong -- which reads as a byte-lane or pairing bug in
	// sdram_download, not as testbench backpressure. Same shape as
	// sim/maincpu_sdram_tb's download task, which is where the correct form
	// already was.
	task automatic push(input [26:0] a, input [7:0] d);
		begin
			while (ioctl_wait) @(posedge clk);
			ioctl_addr <= a;
			ioctl_dout <= d;
			ioctl_wr   <= 1'b1;
			@(posedge clk);
			ioctl_wr   <= 1'b0;
			@(posedge clk);
		end
	endtask

	task automatic stream(input [25:0] base, input int nbytes, input int which);
		int k;
		logic [15:0] w;
		begin
			for (k = 0; k < nbytes; k = k + 2) begin
				case (which)
					0: w = maincpu_img[k >> 1];
					1: w = gfx1_img[k >> 1];
					default: w = x1snd_img[k >> 1];
				endcase
				push(base + k,     w[15:8]);     // ascending byte order,
				push(base + k + 1, w[7:0]);      // exactly as the HPS delivers
			end
		end
	endtask

	task automatic read_cpu(input [23:1] a, output [15:0] d);
		begin
			@(posedge clk);
			cpu_addr <= a; cpu_req <= 1'b1;
			@(posedge clk);
			cpu_req <= 1'b0;
			while (!cpu_valid) @(posedge clk);
			d = cpu_data;
		end
	endtask

	task automatic read_spr(input [23:3] a, output [63:0] d);
		begin
			@(posedge clk);
			spr_addr <= a; spr_req <= 1'b1;
			@(posedge clk);
			spr_req <= 1'b0;
			while (!spr_valid) @(posedge clk);
			d = spr_data;
		end
	endtask

	task automatic read_snd(input [19:0] a, output [7:0] d);
		begin
			@(posedge clk);
			snd_addr <= a; snd_req <= 1'b1;
			@(posedge clk);
			snd_req <= 1'b0;
			while (!snd_valid) @(posedge clk);
			d = snd_data;
		end
	endtask

	// A byte of the natural gfx1 region.
	function automatic logic [7:0] gfx_byte(input int off);
		gfx_byte = off[0] ? gfx1_img[off >> 1][7:0] : gfx1_img[off >> 1][15:8];
	endfunction

	int i, k;
	int maincpu_b, gfx1_b, x1snd_b, half_b;
	logic [15:0] got16, want16;
	logic [63:0] got64, want64;
	logic  [7:0] got8, want8;
	int tile, yh, yl, base1, base2, ntiles;

	initial begin
		for (i = 0; i < MAX_WORDS; i++) begin
			maincpu_img[i] = 16'h0000;
			gfx1_img[i]    = 16'h0000;
			x1snd_img[i]   = 16'h0000;
		end
		for (i = 0; i < 8; i++) cfgv[i] = 32'hxxxxxxxx;

		$readmemh("sim/sdram_top_tb/cfg.hex",     cfgv);
		$readmemh("sim/sdram_top_tb/maincpu.hex", maincpu_img);
		$readmemh("sim/sdram_top_tb/gfx1.hex",    gfx1_img);
		$readmemh("sim/sdram_top_tb/x1snd.hex",   x1snd_img);

		if ($isunknown(cfgv[C_HALFW])) begin
			$display("FAIL: fixtures missing -- run scripts/prep_sdram_tb.py");
			$finish;
		end

		maincpu_b = cfgv[C_MAINCPU_B];
		gfx1_b    = cfgv[C_GFX1_B];
		x1snd_b   = cfgv[C_X1SND_B];
		half_b    = gfx1_b / 2;
		ntiles    = half_b / 64;

		$display("=== seta_sdram_top: a real set, downloaded and read back ===");
		$display("  maincpu  %0d bytes", maincpu_b);
		$display("  gfx1     %0d bytes (%0d tiles per half)", gfx1_b, ntiles);
		$display("  x1snd    %0d bytes", x1snd_b);

		repeat (8) @(posedge clk);
		mem_reset <= 0;
		pll_locked <= 1;
		// The chip's own initialisation sequence has to finish before the
		// first write, or it is issued into a controller still counting out
		// its power-up delay.
		repeat (30000) @(posedge clk);

		ioctl_download <= 1'b1;
		@(posedge clk);
		stream(BASE_MAINCPU, maincpu_b, 0);
		stream(BASE_GFX1,    gfx1_b,    1);
		stream(BASE_X1SND,   x1snd_b,   2);
		while (ioctl_wait) @(posedge clk);
		repeat (64) @(posedge clk);
		ioctl_download <= 1'b0;
		repeat (64) @(posedge clk);
		$display("  downloaded %0d bytes", maincpu_b + gfx1_b + x1snd_b);

		// ---- 1. the CPU sees the program, word for word ---------------------
		// Every 251st word plus the first 64: 251 is prime, so the sample
		// walks the whole region rather than one granule alignment.
		for (i = 0; i < maincpu_b / 2; i = (i < 64) ? i + 1 : i + 251) begin
			read_cpu(i[22:0], got16);
			want16 = {maincpu_img[i][7:0], maincpu_img[i][15:8]};
			checked++;
			if (got16 !== want16) begin
				if (bad < 5)
					$display("  maincpu word %0d: got %04x want %04x", i, got16, want16);
				fail("maincpu readback");
			end
		end
		$display("  maincpu  %0d words checked", checked);

		// ---- 2. a sprite ROW is one granule, in the right order -------------
		// The granule at {tile, yh, yl} must hold, low word first:
		//   half1 xh=0, half1 xh=1, half2 xh=0, half2 xh=1
		// each word being {odd byte, even byte} of the natural pair. Computed
		// from the NATURAL region with x1_001.sv's own layout arithmetic, so a
		// wrong permutation cannot agree with a wrong reader.
		k = checked;
		for (tile = 0; tile < ntiles; tile = (tile < 8) ? tile + 1 : tile + 97) begin
			for (yh = 0; yh < 2; yh++) begin
				for (yl = 0; yl < 8; yl++) begin
					base1 = tile * 64 + yh * 32 + yl * 2;
					base2 = half_b + base1;
					want64 = { gfx_byte(base2 + 17), gfx_byte(base2 + 16),
					           gfx_byte(base2 +  1), gfx_byte(base2 +  0),
					           gfx_byte(base1 + 17), gfx_byte(base1 + 16),
					           gfx_byte(base1 +  1), gfx_byte(base1 +  0) };
					read_spr({tile[15:0], yh[0], yl[2:0]}, got64);
					checked++;
					if (got64 !== want64) begin
						if (bad < 5)
							$display("  sprite tile %0d yh %0d yl %0d: got %016x want %016x",
							         tile, yh, yl, got64, want64);
						fail("sprite granule");
					end
				end
			end
		end
		$display("  sprites  %0d rows checked", checked - k);

		// ---- 3. the X1-010 reads bytes, ascending ----------------------------
		k = checked;
		for (i = 0; i < 256; i++) begin
			read_snd(i[19:0], got8);
			want8 = x1snd_img[i >> 1][i[0] ? 7 : 15 -: 8];
			checked++;
			if (got8 !== want8) begin
				if (bad < 5)
					$display("  x1snd byte %0d: got %02x want %02x", i, got8, want8);
				fail("x1snd readback");
			end
		end
		for (i = 1000; i < x1snd_b; i = i + 4093) begin
			read_snd(i[19:0], got8);
			want8 = x1snd_img[i >> 1][i[0] ? 7 : 15 -: 8];
			checked++;
			if (got8 !== want8) fail("x1snd readback (scattered)");
		end
		$display("  x1snd    %0d bytes checked", checked - k);

		$display("");
		$display("  total checked %0d", checked);
		$display("  mismatches    %0d", bad);
		$display("");
		if (checked == 0)
			$display("FAIL: nothing was checked");
		else if (bad != 0)
			$display("FAIL: %0d readback(s) disagree with the image", bad);
		else
			$display("PASS: %0d reads, every region back exactly as it went in", checked);
		$finish;
	end

	initial begin
		#900ms;
		$display("FAIL: timed out after %0d checks", checked);
		$finish;
	end

endmodule
