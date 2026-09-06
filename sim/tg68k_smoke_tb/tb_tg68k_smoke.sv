// Smoke test for the vendored TG68K.C kernel, in 68000 mode.
//
//     scripts/run_sim.sh tg68k_smoke_tb        (from the repository root)
//
// LESSONS_LEARNED, "Testbench discipline": write a smoke test -- elaborate,
// run N cycles, check for a crash and for X-propagation -- BEFORE a functional
// test, on any new top-level integration. It catches port-width and wiring
// mistakes cheaply. This is that test, and it deliberately proves only:
//
//   1. the vendored VHDL compiles and elaborates under ModelSim in this tree,
//      mixed-language against a SystemVerilog bench;
//   2. the kernel comes out of reset and fetches the reset vectors in the
//      right order, from the right addresses;
//   3. it then executes real instructions and reaches a known landmark;
//   4. nothing on the bus goes X after reset.
//
// It does NOT prove the memory transport, the clock-enable ratio, DTACK
// handling, or interrupts. Those need the production SDRAM stack and a MAME
// boot trace to diff against -- Phase 0 spike 1 proper. A zero-wait-state
// combinational ROM like the one below is exactly the "behavioural model that
// absorbs a protocol bug" the lessons warn about, so nothing here should be
// read as evidence about timing.

`timescale 1ns / 1ps

module tb_tg68k_smoke;

	// 96 MHz, the clk_sys docs/ROADMAP.md proposes. Nothing here depends on
	// the frequency; it is written this way so the numbers match the design.
	localparam realtime CLK_PERIOD = 10.4167;

	// A 16 MHz 68000 inside 96 MHz steps once every 6 cycles. The kernel is
	// advanced by clkena_in, NOT by a gated clock -- see
	// rtl/cpu/tg68k/PROVENANCE.md, "How this core is used".
	localparam int CE_DIV = 6;

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	logic nreset = 0;
	logic [2:0] ce_cnt = 0;
	logic clkena;

	always @(posedge clk) ce_cnt <= (ce_cnt == CE_DIV - 1) ? 3'd0 : ce_cnt + 3'd1;
	assign clkena = (ce_cnt == 0);

	// ---- CPU ----------------------------------------------------------------
	logic [31:0] addr_out;
	logic [15:0] data_in, data_write;
	logic        nWr, nUDS, nLDS, longword, nResetOut, clr_berr, skipFetch;
	logic [1:0]  busstate;
	logic [2:0]  fc;
	logic [31:0] regin_out, vbr_out;
	logic [3:0]  cacr_out;

	TG68KdotC_Kernel u_cpu (
		.clk            (clk),
		.nReset         (nreset),
		.clkena_in      (clkena),
		.data_in        (data_in),
		.IPL            (3'b111),          // no interrupt pending
		.IPL_autovector (1'b0),
		.berr           (1'b0),
		.CPU            (2'b00),           // 68000 -- every in-scope Seta board
		.addr_out       (addr_out),
		.data_write     (data_write),
		.nWr            (nWr),
		.nUDS           (nUDS),
		.nLDS           (nLDS),
		.busstate       (busstate),
		.longword       (longword),
		.nResetOut      (nResetOut),
		.FC             (fc),
		.clr_berr       (clr_berr),
		.skipFetch      (skipFetch),
		.regin_out      (regin_out),
		.CACR_out       (cacr_out),
		.VBR_out        (vbr_out)
	);

	// ---- a tiny zero-wait-state ROM/RAM -------------------------------------
	// 8 KB as 4096 words, word-addressed. Registered read, NOT combinational:
	// LESSONS_LEARNED, "Give a registered RAM its full read latency" -- a
	// behavioural model that answers combinationally hides a whole class of
	// latency bug, and writing it registered is the cheap way not to.
	logic [15:0] mem [0:4095];
	logic [15:0] mem_q;
	wire  [11:0] word_addr = addr_out[12:1];

	// The READ is registered on every clk, NOT gated by clkena. That is the
	// whole subtlety of a clock-enabled CPU against a registered memory, and
	// getting it wrong is what the first run of this bench did: with the read
	// clocked by clkena the data arrived one ENABLE late, so the kernel latched
	// the previous word every time. It fetched the reset vectors correctly
	// (those are just the first four reads) and then executed garbage -- which
	// looked exactly like a CPU that boots and then fails, and would have been
	// blamed on the vendored core.
	//
	// Ungated, the address is stable for CE_DIV cycles and the RAM's one-cycle
	// latency is absorbed long before the next enable. LESSONS_LEARNED, "Give a
	// registered RAM its full read latency before consuming the data" -- the
	// rule holds, the fix is to spend the latency somewhere it is free.
	//
	// The WRITE stays gated by clkena: it is a real bus cycle and must happen
	// once, not CE_DIV times.
	always @(posedge clk) begin
		if (clkena && busstate == 2'b11) begin      // write data
			if (!nUDS) mem[word_addr][15:8] <= data_write[15:8];
			if (!nLDS) mem[word_addr][7:0]  <= data_write[7:0];
		end
		mem_q <= mem[word_addr];
	end
	assign data_in = mem_q;

	// ---- the program --------------------------------------------------------
	// Written directly rather than $readmemh'd: LESSONS_LEARNED, "Write
	// preloaded vectors and tables AFTER $readmemh, never before" -- a load
	// spanning the vector table silently zeroed it on Psikyo and was recorded
	// for weeks as a CPU microcode bug. With no $readmemh there is nothing to
	// order wrongly.
	localparam logic [31:0] RESET_SP = 32'h0000_1000;
	localparam logic [31:0] RESET_PC = 32'h0000_0100;
	localparam logic [31:0] LANDMARK = 32'h0000_0110;

	initial begin
		for (int i = 0; i < 4096; i++) mem[i] = 16'h4E71;   // NOP everywhere

		mem[0] = RESET_SP[31:16];      // 000000: initial SP
		mem[1] = RESET_SP[15:0];
		mem[2] = RESET_PC[31:16];      // 000004: initial PC
		mem[3] = RESET_PC[15:0];

		// 000100: the canonical Seta boot opening -- seven of the ten sets
		// checked by scripts/build_maincpu_hex.py start with exactly this.
		mem[16'h100 >> 1] = 16'h46FC;  // move #$2700,SR   supervisor, IRQs off
		mem[16'h102 >> 1] = 16'h2700;
		mem[16'h104 >> 1] = 16'h7001;  // moveq #1,d0
		mem[16'h106 >> 1] = 16'h7202;  // moveq #2,d1
		mem[16'h108 >> 1] = 16'hD041;  // add.w d1,d0        -> d0 = 3
		mem[16'h10A >> 1] = 16'h33C0;  // move.w d0,$00000200
		mem[16'h10C >> 1] = 16'h0000;
		mem[16'h10E >> 1] = 16'h0200;
		// 000110: LANDMARK -- branch to self
		mem[16'h110 >> 1] = 16'h60FE;  // bra.s *
	end

	// ---- observation --------------------------------------------------------
	int      cycles = 0;
	int      fetches = 0;
	logic    seen_sp_hi, seen_sp_lo, seen_pc_hi, seen_pc_lo, reached_landmark;
	logic    x_seen;
	int      order_err;
	int      vec_step;

	initial begin
		seen_sp_hi = 0; seen_sp_lo = 0; seen_pc_hi = 0; seen_pc_lo = 0;
		reached_landmark = 0; x_seen = 0; order_err = 0; vec_step = 0;
	end

	always @(posedge clk) begin
		cycles <= cycles + 1;

		if (nreset && clkena) begin
			// X-propagation. Checked only while out of reset and only on the
			// signals the bus actually depends on -- the kernel's debug
			// outputs are not part of the contract.
			if ($isunknown({addr_out, busstate, nWr, nUDS, nLDS}))
				x_seen <= 1;

			if (busstate != 2'b01) begin      // 01 = no memory access
				fetches <= fetches + 1;

				// The reset sequence must read 0,2,4,6 in that order.
				case (addr_out[31:0])
					32'h0000_0000: begin seen_sp_hi <= 1;
						if (vec_step != 0) order_err <= order_err + 1;
						vec_step <= 1; end
					32'h0000_0002: begin seen_sp_lo <= 1;
						if (vec_step != 1) order_err <= order_err + 1;
						vec_step <= 2; end
					32'h0000_0004: begin seen_pc_hi <= 1;
						if (vec_step != 2) order_err <= order_err + 1;
						vec_step <= 3; end
					32'h0000_0006: begin seen_pc_lo <= 1;
						if (vec_step != 3) order_err <= order_err + 1;
						vec_step <= 4; end
					LANDMARK:      reached_landmark <= 1;
					default: ;
				endcase
			end
		end
	end

	// ---- run ----------------------------------------------------------------
	initial begin
		$display("=== TG68K.C smoke test, CPU=00 (68000), clkena 1-in-%0d ===", CE_DIV);
		repeat (20) @(posedge clk);
		nreset <= 1;
		$display("[%0t] reset released", $time);

		// Generous: at 1-in-6 clock enable the vector fetch alone is dozens of
		// clk_sys cycles, and this is a smoke test, not a timing measurement.
		// `do @(posedge clk); while (...)` -- NOT `while (...) @(posedge clk)`,
		// which races an always_ff updating the same signal on the same edge
		// (LESSONS_LEARNED, "Testbench discipline", first entry).
		fork
			begin
				do @(posedge clk); while (!reached_landmark && cycles < 20000);
			end
		join

		// THE LANDMARK IS A FETCH, NOT A RETIREMENT. TG68K prefetches, so the
		// word at LANDMARK is read while the preceding `move.w d0,$200` is
		// still in flight -- the first version of this bench stopped here and
		// reported the write as missing, which reads exactly like a broken
		// store. Let the pipeline drain before believing memory.
		repeat (200) @(posedge clk);

		$display("");
		$display("  cycles run        %0d", cycles);
		$display("  bus accesses      %0d", fetches);
		$display("  reset SP fetched  %s / %s",
		         seen_sp_hi ? "hi" : "--", seen_sp_lo ? "lo" : "--");
		$display("  reset PC fetched  %s / %s",
		         seen_pc_hi ? "hi" : "--", seen_pc_lo ? "lo" : "--");
		$display("  landmark reached  %s", reached_landmark ? "yes" : "NO");
		$display("  vector order errs %0d", order_err);
		$display("  X on the bus      %s", x_seen ? "YES" : "no");
		$display("  mem[$200] (d0=3)  %0d", mem[16'h200 >> 1]);
		$display("  VBR / CACR        %08x / %01x", vbr_out, cacr_out);
		$display("");

		if (!seen_sp_hi || !seen_sp_lo || !seen_pc_hi || !seen_pc_lo)
			$display("FAIL: the reset vectors were not all fetched");
		else if (order_err != 0)
			$display("FAIL: reset vectors fetched out of order (%0d)", order_err);
		else if (!reached_landmark)
			$display("FAIL: never reached the landmark at %08x -- the CPU did not execute the program", LANDMARK);
		else if (x_seen)
			$display("FAIL: X propagated onto the bus after reset");
		else if (mem[16'h200 >> 1] !== 16'd3)
			$display("FAIL: the program wrote %0d to $200, expected 3",
			         mem[16'h200 >> 1]);
		else
			$display("PASS: kernel boots, executes, and writes the right result");

		$finish;
	end

endmodule
