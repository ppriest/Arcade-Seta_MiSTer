// The X1-010 against scripts/x1_010_model.py, sample for sample.
//
//     python scripts/prep_x1_010_tb.py --selftest
//     scripts/run_sim.sh x1_010_tb              (from the repository root)
//
// There is no existing FPGA X1-010 anywhere, so there is nothing to diff
// against except MAME. The Python model is a line-by-line transcription of
// `sound_stream_update()`; this bench loads the SAME register/wave image and
// the SAME sample ROM into the RTL and requires the SAME stereo samples.
//
// The registers are written through the CPU port rather than backdoor-loaded,
// so the key-on edge detection is exercised on the way in. That matters more
// than it looks: key-on resets both accumulators AT THE WRITE, and a design
// that instead resets when it notices key-on set produces audio that is
// plausible, phase-shifted, and wrong.

`timescale 1ns / 1ps

module tb_x1_010;

	localparam realtime CLK_PERIOD = 10.4167;   // 96 MHz clk_sys
	localparam int      CE_DIV     = 6;         // -> 16 MHz chip clock
	localparam int      MAX_SAMPLES = 4096;
	localparam int      ROM_BYTES   = 1 << 20;  // the chip addresses 1 MB

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	logic reset = 1;
	logic [2:0] ce_cnt = 0;
	wire  ce = (ce_cnt == 0);
	always @(posedge clk) ce_cnt <= (ce_cnt == CE_DIV - 1) ? 3'd0 : ce_cnt + 3'd1;

	// ---- DUT ----------------------------------------------------------------
	logic        cpu_req = 0, cpu_we = 0, cpu_uds = 0, cpu_lds = 0;
	logic [12:0] cpu_addr = 0;
	logic [15:0] cpu_wdata = 0;
	wire  [15:0] cpu_rdata;

	wire         rom_req;
	wire  [19:0] rom_addr;
	logic        rom_valid = 0;
	logic  [7:0] rom_data = 0;

	wire signed [15:0] audio_l, audio_r;
	wire         audio_stb;
	wire  [15:0] dbg_samples, dbg_overrun, dbg_rom_reads;

	x1_010 dut (
		.clk(clk), .reset(reset), .ce(ce),
		.cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
		.cpu_wdata(cpu_wdata), .cpu_uds(cpu_uds), .cpu_lds(cpu_lds),
		.cpu_rdata(cpu_rdata),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.audio_l(audio_l), .audio_r(audio_r), .audio_stb(audio_stb),
		.dbg_samples(dbg_samples), .dbg_overrun(dbg_overrun),
		.dbg_rom_reads(dbg_rom_reads)
	);

	// ---- PCM sample ROM, with a latency ---------------------------------------
	// Behavioural, but with a settable delay: the real path is an SDRAM round
	// trip and the engine must not depend on the answer being immediate. The
	// production transport is a separate, later test -- LESSONS_LEARNED is clear
	// this is a proxy, not a substitute.
	logic [7:0] rom [0:ROM_BYTES-1];
	int rom_latency = 8;
	int rom_cnt = 0;
	logic rom_busy = 0;
	logic [19:0] rom_hold_a;

	always @(posedge clk) begin
		rom_valid <= 1'b0;
		if (reset) rom_busy <= 1'b0;
		else if (rom_req && !rom_busy) begin
			rom_busy <= 1'b1; rom_hold_a <= rom_addr; rom_cnt <= rom_latency;
		end else if (rom_busy) begin
			if (rom_cnt <= 1) begin
				rom_data  <= rom[rom_hold_a];
				rom_valid <= 1'b1;
				rom_busy  <= 1'b0;
			end else rom_cnt <= rom_cnt - 1;
		end
	end

	// ---- expected samples ----------------------------------------------------
	logic [31:0] expect_mem [0:MAX_SAMPLES-1];   // {left[15:0], right[15:0]}
	logic [15:0] regimg     [0:8191];            // one register byte per entry
	int n_exp = 0, got = 0, bad = 0;
	int keyon_fail = 0;
	int first_bad_i = -1;
	logic signed [15:0] first_bad_l, first_bad_r, want_l, want_r;

	task cpu_write(input [12:0] a, input [7:0] d);
		@(posedge clk);
		cpu_addr  <= a;
		cpu_wdata <= {8'h00, d};
		cpu_we    <= 1'b1;
		cpu_lds   <= 1'b1;
		cpu_uds   <= 1'b0;
		cpu_req   <= 1'b1;
		@(posedge clk);
		cpu_req <= 1'b0;
		cpu_we  <= 1'b0;
		cpu_lds <= 1'b0;
	endtask

	int i;
	initial begin
		for (i = 0; i < ROM_BYTES; i++)   rom[i] = 8'h00;
		for (i = 0; i < MAX_SAMPLES; i++) expect_mem[i] = 32'hxxxxxxxx;
		for (i = 0; i < 8192; i++)        regimg[i] = 16'hxxxx;

		// $readmemh resolves against the SIMULATOR's CWD, not this file.
		// scripts/run_sim.sh runs from the repository root.
		$readmemh("sim/x1_010_tb/regs.hex",   regimg);
		$readmemh("sim/x1_010_tb/rom.hex",    rom);
		$readmemh("sim/x1_010_tb/expect.hex", expect_mem);

		if ($isunknown(regimg[0])) begin
			$display("FAIL: sim/x1_010_tb/regs.hex missing -- run scripts/prep_x1_010_tb.py");
			$finish;
		end
		n_exp = 0;
		for (i = 0; i < MAX_SAMPLES; i++)
			if (!$isunknown(expect_mem[i])) n_exp = i + 1;

		void'($value$plusargs("ROMLAT=%d", rom_latency));
		$display("=== X1-010 against scripts/x1_010_model.py ===");
		$display("  expected samples %0d", n_exp);
		$display("  ROM latency      %0d cycles", rom_latency);

		// THE REGISTERS ARE LOADED WITH THE CHIP IN RESET, and the comparison
		// starts only afterwards.
		//
		// The first version released reset first and loaded afterwards. The
		// engine free-runs -- a sample period is 512 chip clocks, the load
		// takes far longer -- so it had already emitted several passes' worth
		// of samples from a zeroed register file before the first real
		// register arrived, and the bench dutifully compared those against the
		// model's first samples. It reported "the RTL disagrees" at sample 0
		// with the RTL silent, which looks exactly like a dead engine. The
		// engine was fine; the bench was comparing the wrong samples.
		//
		// Loading under reset also gives both sides the same starting
		// accumulators, which is what makes a sample-for-sample comparison
		// meaningful at all. Key-on edge detection is checked separately
		// below, since a clean start does not exercise it.
		repeat (20) @(posedge clk);
		for (i = 128; i < 8192; i++)
			if (!$isunknown(regimg[i])) cpu_write(i[12:0], regimg[i][7:0]);
		for (i = 0; i < 128; i++)
			if (!$isunknown(regimg[i])) cpu_write(i[12:0], regimg[i][7:0]);

		$display("  registers loaded: regmem[0]=%02x [8]=%02x [0x1000]=%02x",
		         dut.regmem[0], dut.regmem[8], dut.regmem[13'h1000]);

		repeat (4) @(posedge clk);
		reset <= 0;
		$display("  [%0t] reset released, running", $time);

		do @(posedge clk); while (got < n_exp && bad == 0 && $time < 400ms);

		$display("");
		$display("  samples compared %0d of %0d", got, n_exp);
		$display("  mismatches       %0d", bad);
		$display("  chip samples     %0d", dbg_samples);
		$display("  pass overruns    %0d", dbg_overrun);
		$display("  PCM ROM reads    %0d", dbg_rom_reads);
		if (first_bad_i >= 0)
			$display("  FIRST at %0d: RTL %0d/%0d, model %0d/%0d",
			         first_bad_i, first_bad_l, first_bad_r, want_l, want_r);
		$display("");

		check_keyon();

		if (n_exp == 0)
			$display("FAIL: expect.hex empty -- run scripts/prep_x1_010_tb.py");
		else if (bad != 0)
			$display("FAIL: the RTL disagrees with the model");
		else if (got < n_exp)
			$display("FAIL: only %0d of %0d samples produced", got, n_exp);
		else if (dbg_overrun != 0)
			$display("FAIL: %0d channel passes overran their sample period", dbg_overrun);
		else if (keyon_fail != 0)
			$display("FAIL: key-on edge semantics are wrong");
		else
			$display("PASS: %0d samples identical to the model, key-on edge correct", got);
		$finish;
	end

	// Key-on is EDGE-triggered at the write: MAME resets both accumulators
	// inside write() when bit 0 of register 0 goes 0 -> 1. Writing a 1 over an
	// existing 1 must NOT reset. A clean start cannot tell the two apart, so
	// check it directly.
	// Key-on is EDGE-triggered at the write: MAME resets both accumulators
	// inside write() when bit 0 of register 0 goes 0 -> 1. Writing a 1 over an
	// existing 1 must NOT reset. A clean start cannot tell the two apart.
	//
	// Checked on a channel that has been RUNNING, using ordinary register
	// writes -- no force/release. An earlier version forced an accumulator to a
	// known value and released it before writing; the release did not behave as
	// intended and the check reported a failure the RTL did not have. Driving
	// the DUT the way the hardware is driven avoids inventing a second thing
	// that can be wrong.
	task check_keyon();
		logic [31:0] before_off;
		@(posedge clk);
		before_off = dut.smp_offset[0];
		if (before_off == 0) begin
			$display("  key-on check SKIPPED: channel 0 never accumulated");
			keyon_fail = keyon_fail + 1;
			return;
		end

		// 1 over 1 is NOT an edge: the accumulator must keep running.
		cpu_write(13'h00, 8'h03);
		repeat (8) @(posedge clk);
		if (dut.smp_offset[0] == 32'd0) begin
			$display("  KEY-ON: writing 1 over 1 reset the accumulator; it must not");
			keyon_fail = keyon_fail + 1;
		end

		// key off, then on: that IS an edge, and both accumulators must clear.
		cpu_write(13'h00, 8'h02);
		repeat (4) @(posedge clk);
		cpu_write(13'h00, 8'h03);
		repeat (4) @(posedge clk);
		if (dut.smp_offset[0] !== 32'd0 || dut.env_offset[0] !== 32'd0) begin
			$display("  KEY-ON: the 0->1 edge did not reset the accumulators (%0d/%0d)",
			         dut.smp_offset[0], dut.env_offset[0]);
			keyon_fail = keyon_fail + 1;
		end
		$display("  key-on edge check: %s   (accumulator was %0d before)",
		         keyon_fail ? "FAIL" : "ok", before_off);
	endtask

	// +TRACE dumps the engine's own state machine. The first question when the
	// mix is silent is whether the engine is running at all, not what the
	// arithmetic produced.
	int tn = 0;
	always @(posedge clk) begin
		if (!reset && ce && dut.st != 0 && $test$plusargs("TRACE") && tn < 90) begin
			tn <= tn + 1;
			$display("  t=%0d st=%0d ch=%0d r0=%02x eng_a=%04x eng_q=%02x mem[a]=%02x",
			         dut.tick, dut.st, dut.ch, dut.r0, dut.eng_addr, dut.eng_q,
			         dut.regmem[dut.eng_addr]);
		end
	end

	always @(posedge clk) begin
		if (!reset && audio_stb && got < n_exp) begin
			want_l = expect_mem[got][31:16];
			want_r = expect_mem[got][15:0];
			if (audio_l !== want_l || audio_r !== want_r) begin
				if (bad == 0) begin
					first_bad_i <= got;
					first_bad_l <= audio_l;
					first_bad_r <= audio_r;
				end
				bad <= bad + 1;
			end
			got <= got + 1;
		end
	end

endmodule
