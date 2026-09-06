// The whole core: download a real ROM set through the ioctl port, release
// reset, and let the game run.
//
//     python scripts/prep_sdram_tb.py thunderl --out sim/seta_core_tb
//     scripts/run_sim.sh seta_core_tb            (from the repository root)
//     scripts/run_sim.sh seta_core_tb +FRAMES=40 +GAME=6
//
// TRACE MODE IS THE REAL GATE. +TRACE=n dumps the core's own bus trace and
// scripts/diff_core_trace.py aligns it against MAME's for the same game. That
// is the one comparison here with a reference: MAME with its real peripherals
// against this core with its real peripherals, so it follows the game as far
// as MAME's trace goes and a wrong DIP byte, a missing protection register or
// a mis-decoded region all show up as the point where the two part company.
//
// FRAME MODE IS A LIVENESS CHECK, NOT AN ACCEPTANCE TEST, and the difference
// is worth stating because the first version of this bench got it wrong. It
// required the palette and sprite RAM to have been written and an interrupt to
// have been taken within a few frames, and reported four failures when none of
// those had happened. They had not happened in MAME either: thunderl's start-up
// is a RAM fill that is still running at MAME's own 400,000th bus access, tens
// of frames in. Simulating that far is hours, so this bench cannot answer "does
// the game get to its title screen" and does not pretend to.
//
// What it CAN answer, and does fail on:
//   * the CPU executes at all, out of SDRAM, after a real download
//   * the video engine runs lines and the sprite engine fetches graphics
//   * no line overruns -- the budget is supposed to prevent those
// Everything else is reported as PROGRESS, because whether it has happened yet
// depends only on how far the game has got.

`timescale 1ns / 1ps

module tb_seta_core;

	localparam realtime CLK_PERIOD = 10.4167;   // 96 MHz
	localparam int MAX_WORDS = 1 << 20;

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	logic reset = 1;
	logic pll_locked = 0;

	localparam logic [25:0] BASE_MAINCPU = 26'h000_0000;
	localparam logic [25:0] BASE_GFX1    = 26'h010_0000;
	localparam logic [25:0] BASE_X1SND   = 26'h030_0000;

	logic [15:0] maincpu_img [0:MAX_WORDS-1];
	logic [15:0] gfx1_img    [0:MAX_WORDS-1];
	logic [15:0] x1snd_img   [0:MAX_WORDS-1];
	logic [31:0] cfgv [0:7];
	localparam int C_MAINCPU_B = 1, C_GFX1_B = 2, C_X1SND_B = 3;

	logic        ioctl_download = 0;
	logic [15:0] ioctl_index = 0;
	logic        ioctl_wr = 0;
	logic [26:0] ioctl_addr = 0;
	logic  [7:0] ioctl_dout = 0;
	wire         ioctl_wait;

	wire [12:0] SDRAM_A;
	wire [15:0] SDRAM_DQ;
	wire  [1:0] SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS,
	            SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

	wire [7:0] video_r, video_g, video_b;
	wire       video_hs, video_vs, video_hb, video_vb, video_de, video_ce;
	wire signed [15:0] audio_l, audio_r;

	wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun;
	wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped;
	wire [15:0] dbg_snd_samples, dbg_snd_overrun, dbg_snd_rom_reads;
	wire  [7:1] dbg_irq_pending;
	wire        dbg_cpu_stb, dbg_cpu_we;
	wire [23:1] dbg_cpu_addr;
	wire [15:0] dbg_cpu_data;

	logic [3:0] game = 4'd0;      // GAME_THUNDERL

	// MiSTer holds core RESET for the whole download; the memory path must not
	// be gated by it. That is the whole point of the two signals.
	wire core_reset = reset | ioctl_download;
	wire mem_reset  = reset & ~ioctl_download;

	seta_core dut (
		.clk(clk), .reset(core_reset), .mem_reset(mem_reset), .init(~pll_locked),
		.game(game),
		.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		// Active low, nothing pressed, DIPs all on -- the driver's defaults.
		.p1_in(16'hffff), .p2_in(16'hffff), .coins_in(16'hffff),
		.p3_in(16'hffff), .p4_in(16'hffff), .dsw_in(16'hffff),
		.pause_cpu(1'b0), .en_spr(1'b1), .en_pcm(1'b1),
		.video_r(video_r), .video_g(video_g), .video_b(video_b),
		.video_hs(video_hs), .video_vs(video_vs), .video_hb(video_hb),
		.video_vb(video_vb), .video_de(video_de), .video_ce(video_ce),
		.audio_l(audio_l), .audio_r(audio_r),
		.dbg_lines(dbg_lines), .dbg_sprites(dbg_sprites),
		.dbg_fetches(dbg_fetches), .dbg_overrun(dbg_overrun),
		.dbg_worst_line(dbg_worst_line), .dbg_worst_sprites(dbg_worst_sprites),
		.dbg_dropped(dbg_dropped),
		.dbg_snd_samples(dbg_snd_samples), .dbg_snd_overrun(dbg_snd_overrun),
		.dbg_snd_rom_reads(dbg_snd_rom_reads),
		.dbg_irq_pending(dbg_irq_pending),
		.dbg_cpu_stb(dbg_cpu_stb), .dbg_cpu_addr(dbg_cpu_addr),
		.dbg_cpu_we(dbg_cpu_we), .dbg_cpu_data(dbg_cpu_data)
	);

	sdram_chip_model_wide u_chip (
		.clk(SDRAM_CLK), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// ---- what the core is observed by ----------------------------------------
	// The io bus, not a peripheral: which region the CPU is writing to says
	// where it has got to in its own start-up, and nothing has to be reached
	// into to see it.
	// Direct taps on the interrupt path. "pending is 0" has three causes that
	// look identical from outside -- the pulse never fires, the set never
	// reaches the flag, or an acknowledge clears it as fast as it is set -- and
	// counting each separately is the difference between an answer and a guess.
	int n_vbl_pulse = 0, n_irq_set = 0, n_irq_clr = 0, n_sl240 = 0, n_sl112 = 0;
	always @(posedge clk) if (!core_reset) begin
		if (dut.irq_vbl_pulse)   n_vbl_pulse <= n_vbl_pulse + 1;
		if (dut.irq_sl240_pulse) n_sl240     <= n_sl240 + 1;
		if (dut.irq_sl112_pulse) n_sl112     <= n_sl112 + 1;
		if (|dut.irq_set)        n_irq_set   <= n_irq_set + 1;
		if (|dut.irq_clr)        n_irq_clr   <= n_irq_clr + 1;
	end

	// A ring of the last completed bus accesses. "The CPU is running but
	// getting nowhere" is not a number, it is a LOOP, and the only way to say
	// which loop is to look at the addresses. 64 entries is more than enough
	// for a poll loop and small enough to read.
	localparam int RING = 64;
	logic [23:1] ring_addr [0:RING-1];
	logic        ring_we   [0:RING-1];
	logic [15:0] ring_data [0:RING-1];
	int ring_p = 0;

	// A FULL BUS TRACE, for diffing against MAME's own. This is the test the
	// whole project leans on -- sim/maincpu_tb does it with a behavioural ROM
	// and no peripherals, which runs out of road as soon as the game reads a
	// DIP or the protection register. Here the peripherals are real, so the
	// comparison can run as far as MAME's trace goes.
	//
	// It also finishes in seconds rather than the ten-plus minutes a frame
	// costs: 20,000 accesses is a fraction of one frame, and the download in
	// front of it is most of the wall clock either way.
	int trace_n = 0;
	int trace_fh;
	int traced = 0;

	int cpu_accesses = 0, cpu_writes = 0;
	int pal_writes = 0, sprcode_writes = 0, sprctrl_writes = 0, x1_writes = 0;
	int iacks = 0;
	logic iack_d = 0;

	always @(posedge clk) begin
		if (!core_reset) begin
			if (dbg_cpu_stb) begin
				cpu_accesses <= cpu_accesses + 1;
				if (dbg_cpu_we) cpu_writes <= cpu_writes + 1;
				if (trace_n > 0 && traced < trace_n) begin
					$fdisplay(trace_fh, "%0d\t%s\t%06X\t%04X", traced + 1,
					          dbg_cpu_we ? "w" : "r",
					          {dbg_cpu_addr, 1'b0}, dbg_cpu_data);
					traced <= traced + 1;
				end
				ring_addr[ring_p] <= dbg_cpu_addr;
				ring_we[ring_p]   <= dbg_cpu_we;
				ring_data[ring_p] <= dbg_cpu_data;
				ring_p <= (ring_p == RING - 1) ? 0 : ring_p + 1;
			end
			if (dut.io_req && dut.io_we) begin
				if (dut.io_sel[0]) pal_writes     <= pal_writes + 1;
				if (dut.io_sel[3]) sprcode_writes <= sprcode_writes + 1;
				if (dut.io_sel[2]) sprctrl_writes <= sprctrl_writes + 1;
				if (dut.io_sel[8]) x1_writes      <= x1_writes + 1;
			end
			iack_d <= dut.iack;
			if (dut.iack && !iack_d) iacks <= iacks + 1;
		end
	end

	// ---- the frame, sampled the way the framework samples it -----------------
	localparam int MAX_PIX = 384 * 256;
	logic [23:0] frame [0:MAX_PIX-1];
	int px = 0, frames = 0;
	logic vs_prev = 0;
	int distinct = 0;

	always @(posedge clk) begin
		if (!reset && video_ce) begin
			vs_prev <= video_vs;
			if (video_vs && !vs_prev) begin
				frames <= frames + 1;
				px     <= 0;
			end else if (video_de) begin
				if (px < MAX_PIX) frame[px] <= {video_r, video_g, video_b};
				px <= px + 1;
			end
		end
	end

	// ---- ioctl ---------------------------------------------------------------
	// The wait loop and the assignments with NO edge between them: an extra
	// edge lets ioctl_wait rise again in the gap and the write lands in a
	// stalled port and is lost (LESSONS_LEARNED).
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
				push(base + k,     w[15:8]);
				push(base + k + 1, w[7:0]);
			end
		end
	endtask

	int i, n_frames = 20;
	int uniq;
	logic [23:0] c0;
	int fails = 0;

	initial begin
		for (i = 0; i < MAX_WORDS; i++) begin
			maincpu_img[i] = 16'h0000;
			gfx1_img[i]    = 16'h0000;
			x1snd_img[i]   = 16'h0000;
		end
		for (i = 0; i < MAX_PIX; i++) frame[i] = 24'h000000;
		for (i = 0; i < 8; i++) cfgv[i] = 32'hxxxxxxxx;

		$readmemh("sim/seta_core_tb/cfg.hex",     cfgv);
		$readmemh("sim/seta_core_tb/maincpu.hex", maincpu_img);
		$readmemh("sim/seta_core_tb/gfx1.hex",    gfx1_img);
		$readmemh("sim/seta_core_tb/x1snd.hex",   x1snd_img);

		if ($isunknown(cfgv[C_MAINCPU_B])) begin
			$display("FAIL: fixtures missing -- run scripts/prep_sdram_tb.py <set> --out sim/seta_core_tb");
			$finish;
		end

		void'($value$plusargs("FRAMES=%d", n_frames));
		void'($value$plusargs("GAME=%d", game));
		void'($value$plusargs("TRACE=%d", trace_n));
		if (trace_n > 0) begin
			trace_fh = $fopen("sim/seta_core_tb/core.trace", "w");
			$fdisplay(trace_fh, "# main-CPU bus accesses from reset, in order.");
			$fdisplay(trace_fh, "# seq\trw\taddr\tdata");
		end

		$display("=== the whole core, running a real ROM set ===");
		$display("  game index   %0d", game);
		$display("  maincpu      %0d bytes", cfgv[C_MAINCPU_B]);
		$display("  gfx1         %0d bytes", cfgv[C_GFX1_B]);
		$display("  x1snd        %0d bytes", cfgv[C_X1SND_B]);
		$display("  frames       %0d", n_frames);

		repeat (8) @(posedge clk);
		pll_locked <= 1;
		repeat (30000) @(posedge clk);      // the chip's power-up sequence

		ioctl_download <= 1'b1;
		@(posedge clk);
		stream(BASE_MAINCPU, cfgv[C_MAINCPU_B], 0);
		stream(BASE_GFX1,    cfgv[C_GFX1_B],    1);
		stream(BASE_X1SND,   cfgv[C_X1SND_B],   2);
		while (ioctl_wait) @(posedge clk);
		repeat (64) @(posedge clk);
		ioctl_download <= 1'b0;
		repeat (64) @(posedge clk);
		$display("  downloaded, releasing reset");

		reset <= 0;

		// Trace mode: collect the accesses and stop. Nothing else about the run
		// is interesting once the point is a diff against MAME.
		if (trace_n > 0) begin
			while (traced < trace_n) @(posedge clk);
			$fclose(trace_fh);
			$display("  traced %0d bus accesses to sim/seta_core_tb/core.trace",
			         traced);
			$finish;
		end

		// A LINE PER FRAME. Without it a long run is indistinguishable from a
		// hung one: the first version printed nothing between "releasing reset"
		// and the verdict, and after forty minutes there was no way to tell
		// whether the core was booting slowly or not running at all. The
		// numbers also show the boot happening -- CPU accesses climbing, then
		// the palette, then sprites -- which is worth more than the verdict.
		for (int f = 0; f < n_frames; f++) begin
			while (frames <= f) @(posedge clk);
			$display("  frame %0d: cpu %0d (%0d wr), pal %0d, sprcode %0d, x1 %0d, iack %0d, lines %0d, spr %0d",
			         f, cpu_accesses, cpu_writes, pal_writes, sprcode_writes,
			         x1_writes, iacks, dbg_lines, dbg_sprites);
			$display("           vbl_pulse %0d, sl240 %0d, sl112 %0d, irq_set %0d, irq_clr %0d, pending %b, ipl %0d",
			         n_vbl_pulse, n_sl240, n_sl112, n_irq_set, n_irq_clr,
			         dbg_irq_pending, dut.ipl_level);
		end

		// How many distinct colours are on screen? One means nothing was drawn
		// -- the backdrop and no more.
		uniq = 0;
		c0 = frame[0];
		for (i = 0; i < 384 * 240; i++)
			if (frame[i] !== c0) uniq++;

		$display("");
		$display("  frames rendered   %0d", frames);
		$display("  CPU bus accesses  %0d  (%0d writes)", cpu_accesses, cpu_writes);
		$display("  palette writes    %0d", pal_writes);
		$display("  sprite code wr    %0d", sprcode_writes);
		$display("  sprite ctrl wr    %0d", sprctrl_writes);
		$display("  X1-010 writes     %0d", x1_writes);
		$display("  interrupts taken  %0d   (pending now %b)", iacks, dbg_irq_pending);
		$display("  scanlines         %0d", dbg_lines);
		$display("  sprites blitted   %0d", dbg_sprites);
		$display("  sprite ROM reads  %0d", dbg_fetches);
		$display("  line overruns     %0d", dbg_overrun);
		$display("  lines cut short   %0d", dbg_dropped);
		$display("  worst line        %0d cycles (%0d sprites)",
		         dbg_worst_line, dbg_worst_sprites);
		$display("  sound samples     %0d  (PCM reads %0d, overruns %0d)",
		         dbg_snd_samples, dbg_snd_rom_reads, dbg_snd_overrun);
		$display("  pixels unlike [0] %0d of %0d", uniq, 384 * 240);
		$display("");
		$display("  the last %0d bus accesses, oldest first:", RING);
		for (i = 0; i < RING; i++) begin
			int j;
			j = (ring_p + i) % RING;
			$display("    %06x %s %04x", {ring_addr[j], 1'b0},
			         ring_we[j] ? "W" : "R", ring_data[j]);
		end
		$display("");

		// Hard failures: things that cannot be explained by the game still
		// booting.
		if (cpu_accesses < 1000)
			begin $display("FAIL: the CPU barely ran -- %0d accesses", cpu_accesses); fails++; end
		if (dbg_lines == 0)
			begin $display("FAIL: the video engine never ran a line"); fails++; end
		if (dbg_fetches == 0)
			begin $display("FAIL: the sprite engine never fetched a graphics granule"); fails++; end
		if (dbg_overrun != 0)
			begin $display("FAIL: %0d line overrun(s) -- the budget should prevent these",
			               dbg_overrun); fails++; end

		// Progress, not verdicts. thunderl's RAM fill is still running at
		// MAME's own 400,000th bus access, so none of these has to have
		// happened in a few frames of simulation.
		$display("  progress: palette %s, sprite RAM %s, interrupts %s",
		         pal_writes     ? "written" : "not yet",
		         sprcode_writes ? "written" : "not yet",
		         iacks          ? "taken"   : "not yet");

		if (fails == 0)
			$display("PASS: the core runs %0d -- CPU, video and sprite fetch all live", game);
		else
			$display("FAIL: %0d check(s) failed", fails);
		$finish;
	end

	initial begin
		#2000ms;
		$display("FAIL: timed out -- %0d frames, %0d CPU accesses", frames, cpu_accesses);
		$finish;
	end

endmodule
