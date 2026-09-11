// Boot a REAL Seta program ROM through maincpu.sv, and diff the CPU's fetches
// against MAME's own.
//
//     python scripts/mame_capture.py thunderl --boot-trace 400 --name bt/thunderl
//     python scripts/prep_maincpu_tb.py thunderl debug/bt/thunderl/thunderl_boot.trace
//     scripts/run_sim.sh maincpu_tb                (from the repository root)
//
// This is Phase 0 spike 1's functional half. The smoke test
// (sim/tg68k_smoke_tb) proved the kernel runs a hand-written program; this
// proves maincpu.sv runs a real one and agrees with MAME instruction for
// instruction -- which catches a wrong interleave, a wrong reset vector, a
// wrong byte order and a wrong decode in one test, and names the first address
// where it stops agreeing.
//
// WHAT IS AND IS NOT MODELLED
// ---------------------------
// The ROM here is a behavioural model with a parameterised latency, NOT the
// production SDRAM stack. LESSONS_LEARNED is explicit that this is not enough
// on its own: "Re-run the failing case with the production transport in place
// of behavioural models" -- Psikyo had a protocol bug that every module-level
// sim passed because a short-latency model returned its response while the FSM
// was between states. So this bench proves the CPU and the decode; wiring
// psikyo/fuuki's sdram_narrow_bridge underneath is a separate, later step and
// the ROM_LATENCY sweep below is a cheap proxy for it in the meantime.
//
// Reads outside the program image return zero, which is what MAME does on this
// hardware -- checked, not assumed: thunderl's boot reads 0x200000, which
// thunderl_map does not map, and MAME returns 0x0000.

`timescale 1ns / 1ps

module tb_maincpu;

	localparam realtime CLK_PERIOD = 10.4167;    // 96 MHz
	localparam int      CE_DIV     = 6;          // -> 16 MHz CPU
	localparam int      ROM_WORDS  = 1 << 20;   // 2 MB, the largest set

	// Cycles the ROM takes to answer. The production transport is roughly 6-7
	// for a granule hit and more under contention; sweep it with +ROMLAT=n to
	// check the FSM does not depend on a particular value.
	int rom_latency = 6;
	int run_ms = 4;

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	logic reset = 1;
	logic [2:0] ce_cnt = 0;
	logic cpu_ce;
	always @(posedge clk) ce_cnt <= (ce_cnt == CE_DIV - 1) ? 3'd0 : ce_cnt + 3'd1;
	assign cpu_ce = (ce_cnt == 0);

	// ---- DUT ----------------------------------------------------------------
	logic        rom_req;
	logic [23:1] rom_addr;
	logic        rom_valid;
	logic [15:0] rom_data;

	logic [19:1] wram_addr;
	logic        wram_wel, wram_weh;
	logic [15:0] wram_wdata, wram_rdata;

	logic        io_req, io_we, io_uds, io_lds;
	logic [23:1] io_addr;
	logic [15:0] io_wdata;
	logic [15:0] io_sel;
	logic [15:0] io_rdata;

	logic        dbg_stb, dbg_we;
	logic [23:1] dbg_addr;
	logic [15:0] dbg_data;

	// The board comes from the FIXTURE, not from a default. scripts/
	// prep_maincpu_tb.py writes board.hex beside the other files, so a bare
	// run of this bench is always self-consistent with whatever fixture is
	// present. +BOARD=n still overrides, for deliberately trying a wrong one.
	//
	// The default used to be BOARD_THUNDERL and only the sweep passed +BOARD.
	// A bare run against another set's fixture then reported "the CPU stalled
	// or ran out of time" after 44 of 160 reads -- which names the CPU, and
	// the CPU was fine.
	logic [7:0] boardimg [0:0];
	int board_sel = 8;

	maincpu dut (
		.clk(clk), .reset(reset), .board(board_sel[4:0]), .cpu_ce(cpu_ce),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.wram_addr(wram_addr), .wram_wel(wram_wel), .wram_weh(wram_weh),
		.wram_wdata(wram_wdata), .wram_rdata(wram_rdata),
		.io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_wdata(io_wdata),
		.io_uds(io_uds), .io_lds(io_lds), .io_sel(io_sel), .io_rdata(io_rdata),
		.ipl_level(3'd0),
		.iack(), .iack_level(),
		.dbg_stb(dbg_stb), .dbg_addr(dbg_addr), .dbg_we(dbg_we), .dbg_data(dbg_data)
	);

	// ---- program ROM, behavioural, with latency ------------------------------
	logic [15:0] rom [0:ROM_WORDS-1];
	int          rom_cnt = 0;
	logic        rom_busy = 0;
	logic [23:1] rom_hold;

	always @(posedge clk) begin
		rom_valid <= 1'b0;
		if (reset) begin
			rom_busy <= 1'b0;
		end else if (rom_req && !rom_busy) begin
			rom_busy <= 1'b1;
			rom_hold <= rom_addr;
			rom_cnt  <= rom_latency;
		end else if (rom_busy) begin
			if (rom_cnt <= 1) begin
				rom_data  <= (rom_hold < ROM_WORDS) ? rom[rom_hold] : 16'h0000;
				rom_valid <= 1'b1;
				rom_busy  <= 1'b0;
			end else begin
				rom_cnt <= rom_cnt - 1;
			end
		end
	end

	// ---- work RAM -----------------------------------------------------------
	// Powers up ZERO, matching MAME -- gundhara reads 0x20F000 before writing
	// it and gets 0x0000. A different fill would diverge on the first such read
	// and look like a CPU fault.
	logic [15:0] wram [0:(1<<19)-1];
	always @(posedge clk) begin
		if (wram_wel) wram[wram_addr][7:0]  <= wram_wdata[7:0];
		if (wram_weh) wram[wram_addr][15:8] <= wram_wdata[15:8];
		wram_rdata <= wram[wram_addr];
	end

	// ---- backing store for the regions that really are RAM -------------------
	//
	// Most of what maincpu decodes onto the io bus is RAM on the board: the
	// second work-RAM block, the palette, both tilemap VRAMs, and all three
	// sprite arrays. Leaving them reading zero is not neutral -- blandia's boot
	// writes 0x5555 to 0x300000, reads it back, gets 0x0000 and takes its
	// RAM-test FAILURE branch. The CPU then executes a different program from
	// MAME's and the bench reports a stall 25 reads in, which looks like a bus
	// bug and is not one.
	//
	// One array, indexed by {region, offset}, is enough: these are separate
	// address spaces to the CPU and never alias each other here.
	localparam int SEL_WRAM2 = 12;
	logic [15:0] ioram [0:(1<<18)-1];
	logic  [3:0] io_region;
	always_comb begin
		io_region = 4'd15;                       // 15 = none selected
		for (int k = 0; k < 14; k++)
			if (io_sel[k]) io_region = k[3:0];
	end
	wire [17:0] ioram_a = {io_region, io_addr[14:1]};
	logic [15:0] ioram_q;
	always @(posedge clk) begin
		if (io_req && io_we && io_region != 4'd15) begin
			if (io_lds) ioram[ioram_a][7:0]  <= io_wdata[7:0];
			if (io_uds) ioram[ioram_a][15:8] <= io_wdata[15:8];
		end
		ioram_q <= ioram[ioram_a];
	end
	// A region with no sel bit reads zero, which is what MAME returns for an
	// unmapped access on this hardware -- checked, not assumed.
	assign io_rdata = (io_region == 4'd15) ? 16'h0000 : ioram_q;

	// ---- the expected fetch list --------------------------------------------
	// {word address[23:1], data[15:0]} per entry, in order, reads only.
	localparam int MAX_EXP = 4096;
	logic [38:0] expect_mem [0:MAX_EXP-1];
	// One flag per expected read, so the reordering window below can satisfy
	// entries out of order without losing track of which are still outstanding.
	logic        consumed   [0:MAX_EXP-1];
	int          n_exp = 0;
	int          exp_i = 0;
	int          matched = 0, mismatched = 0;
	logic [23:1] first_bad_addr;
	logic [15:0] first_bad_got, first_bad_want;
	logic        have_bad = 0;

	// ---- run ----------------------------------------------------------------
	string fixture;
	int    fh, i;

	initial begin
		for (i = 0; i < ROM_WORDS; i++) rom[i] = 16'h0000;
		for (i = 0; i < (1<<19); i++) wram[i] = 16'h0000;
		for (i = 0; i < MAX_EXP; i++) begin expect_mem[i] = '0; consumed[i] = 1'b0; end
		for (i = 0; i < (1<<18); i++) ioram[i] = 16'h0000;

		// $readmemh resolves against the SIMULATOR'S CWD, not this file --
		// scripts/run_sim.sh runs from the repository root and this path is
		// written for that. A wrong CWD leaves both arrays zeroed and fails
		// every check at once, which reads exactly like an RTL regression;
		// grep the log for `readmem` first (LESSONS_LEARNED).
		$readmemh("sim/maincpu_tb/rom.hex", rom);
		$readmemh("sim/maincpu_tb/expect.hex", expect_mem);

		if (rom[0] === 16'h0000 && rom[1] === 16'h0000) begin
			$display("FAIL: sim/maincpu_tb/rom.hex is missing or empty.");
			$display("      Run scripts/prep_maincpu_tb.py first, from the repo root.");
			$finish;
		end

		n_exp = 0;
		for (i = 0; i < MAX_EXP; i++)
			if (expect_mem[i] !== '0) n_exp = i + 1;

		if ($value$plusargs("ROMLAT=%d", rom_latency))
			$display("  ROM latency overridden to %0d cycles", rom_latency);
		boardimg[0] = 8'hxx;
		$readmemh("sim/maincpu_tb/board.hex", boardimg);
		if ($isunknown(boardimg[0])) begin
			$display("FAIL: sim/maincpu_tb/board.hex missing -- run scripts/prep_maincpu_tb.py");
			$finish;
		end
		board_sel = boardimg[0];
		void'($value$plusargs("BOARD=%d", board_sel));

		$display("=== maincpu boot, diffed against MAME ===");
		$display("  board            %0d", board_sel);
		$display("  expected reads   %0d", n_exp);
		$display("  ROM latency      %0d cycles", rom_latency);

		repeat (20) @(posedge clk);
		reset <= 0;

		// 4 ms is the whole boot for most sets. A game that boots and stops
		// LATER -- where every early access matches -- needs a deeper trace and
		// more time for it, so the limit is a plusarg rather than a recompile.
		void'($value$plusargs("MS=%d", run_ms));
		do @(posedge clk);
		while (exp_i < n_exp && !have_bad && $time < run_ms * 1ms);

		$display("");
		$display("  reads compared   %0d of %0d", exp_i, n_exp);
		$display("  matched          %0d", matched);
		$display("  mismatched       %0d", mismatched);
		$display("  RTL-only reads   %0d  (extra prefetches, not errors)", skipped);
		$display("  reordered        %0d  (matched out of order within the window)", reordered);
		if (have_bad)
			$display("  FIRST DIVERGENCE at byte address %06x: RTL fetched %04x, MAME %04x",
			         {first_bad_addr, 1'b0}, first_bad_got, first_bad_want);
		$display("");

		if (n_exp == 0)
			$display("FAIL: expect.hex is empty -- run scripts/prep_maincpu_tb.py");
		else if (have_bad)
			$display("FAIL: the CPU diverged from MAME");
		else if (exp_i < n_exp)
			$display("FAIL: only %0d of %0d expected reads happened -- the CPU stalled or ran out of time",
			         exp_i, n_exp);
		else
			$display("PASS: %0d reads, every one matching MAME's own fetch", matched);

		$finish;
	end

	// +VERBOSE prints every completed access. The first thing to want when the
	// comparison stops advancing is what the CPU actually did next, not what it
	// was supposed to do.
	logic verbose = 0;
	initial verbose = $test$plusargs("VERBOSE");
	int acc_n = 0;
	always @(posedge clk) begin
		if (!reset && dbg_stb) begin
			acc_n <= acc_n + 1;
			if (verbose && acc_n < 400)
				$display("  [%4d] %s %06x %04x", acc_n, dbg_we ? "w" : "r",
				         {dbg_addr, 1'b0}, dbg_data);
		end
	end

	// ORDERED MATCH WITH A REORDERING WINDOW.
	//
	// Three ways TG68K.C and MAME's 68000 differ on the same correct program,
	// each found by a test that first reported it as "the CPU stalled":
	//
	//   1. extra reads      after the reset vectors the RTL reads 0x000008,
	//                       which MAME never does;
	//   2. duplicate reads  MAME reads 0x00013E twice in a row, the RTL once;
	//   3. REORDERING       on sokonuke MAME reads 0x001742 before 0x00173A,
	//                       the RTL after -- a prefetch landing at a different
	//                       point in the stream.
	//
	// (3) is why a plain subsequence match is not enough: MAME's order is not a
	// subsequence of the RTL's at all. So each expected entry carries a
	// `consumed` flag and an incoming RTL read may satisfy any UNCONSUMED entry
	// within WINDOW of the current position; exp_i then advances over whatever
	// has been consumed. Every expected read must still happen, and the data
	// must still agree -- what is relaxed is only the order between nearby
	// prefetches, which is an implementation detail of each core rather than a
	// statement about the program.
	//
	// A real divergence -- a branch taken differently -- puts the RTL on
	// addresses MAME never reads, so the window empties and the run ends with
	// expected reads outstanding. That is still caught, and reported with the
	// address it stopped at.
	localparam int WINDOW = 16;

	int   skipped = 0, reordered = 0;

	// Collapse a read that repeats the one immediately before it, address and
	// data both: a repeat says nothing about whether the cores agree.
	logic [23:1] prev_addr = '1;
	logic [15:0] prev_data = '1;
	logic        have_prev = 0;
	wire         is_dup = have_prev && (dbg_addr == prev_addr) && (dbg_data == prev_data);

	int hit;
	always @(posedge clk) begin
		if (!reset && dbg_stb && !dbg_we) begin
			prev_addr <= dbg_addr;
			prev_data <= dbg_data;
			have_prev <= 1'b1;
		end

		if (!reset && dbg_stb && !dbg_we && !is_dup && exp_i < n_exp && !have_bad) begin
			hit = -1;
			for (int k = 0; k < WINDOW; k++) begin
				if (hit < 0 && (exp_i + k) < n_exp && !consumed[exp_i + k] &&
				    dbg_addr == expect_mem[exp_i + k][38:16])
					hit = exp_i + k;
			end

			if (hit >= 0) begin
				if (dbg_data == expect_mem[hit][15:0]) begin
					matched <= matched + 1;
				end else begin
					mismatched     <= mismatched + 1;
					have_bad       <= 1'b1;
					first_bad_addr <= dbg_addr;
					first_bad_got  <= dbg_data;
					first_bad_want <= expect_mem[hit][15:0];
				end
				consumed[hit] = 1'b1;
				if (hit != exp_i) reordered <= reordered + 1;
				while (exp_i < n_exp && consumed[exp_i]) exp_i = exp_i + 1;
			end else begin
				skipped <= skipped + 1;
			end
		end
	end

endmodule
