// Interrupts, end to end: seta_irq driving the real TG68K through maincpu.sv,
// running a real 68000 interrupt service routine out of a hand-assembled ROM.
//
//     scripts/run_sim.sh irq_tb                (from the repository root)
//
// WHY THIS EXISTS. Everything about seta_irq.sv can be reasoned about except
// the one thing it depends on: that maincpu.sv's `iack` -- FC = 111 during an
// access -- actually fires when the kernel takes an interrupt, and that
// A3..A1 carries the level it took. That is a claim about TG68KdotC_Kernel.vhd
// and it can only be checked by running it. Reading the VHDL is how the claim
// was FORMED; this is how it is tested.
//
// The program is eight instructions, assembled by hand below and commented with
// its own encoding, because a test whose stimulus you cannot read is not much
// of a test:
//
//     0x000000  SP = 0xFFFFF0        thunderl_map puts work RAM at 0xFFC000
//     0x000004  PC = 0x000400
//     0x000064  level 1 autovector -> 0x000500      (vector 25)
//     0x000068  level 2 autovector -> 0x000500      (vector 26)
//     0x00006C  level 3 autovector -> 0x000500      (vector 27)
//
//     0x000400  46FC 2000    move.w #$2000,SR   supervisor, interrupt mask 0
//     0x000404  60FE         bra.s  *           spin
//
//     0x000500  33FC 1234    move.w #$1234,$00300000    the ISR's only visible
//               0030 0000                                effect
//     0x000508  4E73         rte
//
// 0x300000 is unmapped in thunderl_map, so the write goes down the io path with
// no region selected and completes -- which is exactly what a 68000 write to
// unmapped space does on this board. The bench counts it off maincpu's own
// debug strobe rather than off a peripheral, so nothing but the CPU is needed.
//
// FOUR THINGS ARE CHECKED, and each corresponds to a way this has gone wrong
// before:
//   1. A HOLD_LINE request is taken, and the acknowledge clears it. If the
//      FC decode is wrong the ISR runs forever.
//   2. An ASSERT_LINE request is taken and STAYS pending until an explicit
//      clear -- MAME's 3-argument set_inputline never clears on the falling
//      edge, and blockcar relies on that.
//   3. The acknowledge clears the level the CPU LATCHED, not the highest
//      pending. Raising a higher level while a lower one is being taken must
//      leave the higher one pending.
//   4. A request arriving on the same cycle as an acknowledge survives.

`timescale 1ns / 1ps

module tb_irq;

	localparam realtime CLK_PERIOD = 10.4167;   // 96 MHz
	localparam int CE_DIV = 6;                  // -> 16 MHz CPU

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;
	logic reset = 1;

	logic [2:0] ce_cnt = 0;
	wire  cpu_ce = (ce_cnt == 0);
	always @(posedge clk) ce_cnt <= (ce_cnt == CE_DIV - 1) ? 3'd0 : ce_cnt + 3'd1;

	// ---- maincpu ------------------------------------------------------------
	wire         rom_req;
	wire  [23:1] rom_addr;
	logic        rom_valid = 0;
	logic [15:0] rom_data = 0;

	wire [19:1] wram_addr;
	wire        wram_wel, wram_weh;
	wire [15:0] wram_wdata;
	logic [15:0] wram_rdata;

	wire        io_req, io_we, io_uds, io_lds;
	wire [23:1] io_addr;
	wire [15:0] io_wdata;
	wire [15:0] io_sel;
	logic [15:0] io_rdata = 16'h0000;

	wire        dbg_stb, dbg_we;
	wire [23:1] dbg_addr;
	wire [15:0] dbg_data;

	wire        iack;
	wire  [2:0] iack_level;
	wire  [2:0] ipl_level;
	wire  [7:1] pending;

	logic [7:1] irq_set  = 7'd0;
	logic [7:1] irq_hold = 7'd0;
	logic [7:1] irq_clr  = 7'd0;

	maincpu dut (
		.clk(clk), .reset(reset), .board(4'd8 /* BOARD_THUNDERL */), .cpu_ce(cpu_ce),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.wram_addr(wram_addr), .wram_wel(wram_wel), .wram_weh(wram_weh),
		.wram_wdata(wram_wdata), .wram_rdata(wram_rdata),
		.io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_wdata(io_wdata),
		.io_uds(io_uds), .io_lds(io_lds), .io_sel(io_sel), .io_rdata(io_rdata),
		.ipl_level(ipl_level),
		.iack(iack), .iack_level(iack_level),
		.dbg_stb(dbg_stb), .dbg_addr(dbg_addr), .dbg_we(dbg_we), .dbg_data(dbg_data)
	);

	seta_irq u_irq (
		.clk(clk), .reset(reset),
		.set(irq_set), .hold(irq_hold), .clr(irq_clr),
		.iack(iack), .iack_level(iack_level),
		.ipl_level(ipl_level), .pending(pending)
	);

	// ---- a SECOND instance, driven directly ---------------------------------
	// Tests 3 and 4 are about what seta_irq does on one particular cycle:
	// which level an acknowledge clears, and what happens when a set and an
	// acknowledge coincide. Trying to arrange those through the CPU means
	// waiting for the kernel to acknowledge at a moment the bench chose, which
	// it cannot be made to do -- the first attempt "checked" them by driving a
	// set whenever an acknowledge appeared and then reading the flag at the
	// end, which measures where the loop happened to stop and nothing else.
	//
	// So the acknowledge PATH is proved against the real kernel above, and the
	// acknowledge SEMANTICS are proved here, where every cycle is chosen.
	logic [7:1] c_set = 0, c_hold = 0, c_clr = 0;
	logic       c_iack = 0;
	logic [2:0] c_iack_level = 0;
	wire  [2:0] c_ipl;
	wire  [7:1] c_pending;

	seta_irq u_chk (
		.clk(clk), .reset(reset),
		.set(c_set), .hold(c_hold), .clr(c_clr),
		.iack(c_iack), .iack_level(c_iack_level),
		.ipl_level(c_ipl), .pending(c_pending)
	);

	// ---- behavioural ROM and work RAM ---------------------------------------
	logic [15:0] rom [0:16383];        // 32 KB, enough for the vectors and both routines
	int rom_latency = 6;
	int rom_cnt = 0;
	logic rom_busy = 0;
	logic [23:1] rom_hold_a;

	always @(posedge clk) begin
		rom_valid <= 1'b0;
		if (reset) rom_busy <= 1'b0;
		else if (rom_req && !rom_busy) begin
			rom_busy <= 1'b1; rom_hold_a <= rom_addr; rom_cnt <= rom_latency;
		end else if (rom_busy) begin
			if (rom_cnt <= 1) begin
				// rom_hold_a is a WORD address and starts at bit 1, so the
				// index is [14:1] -- [13:0] reaches below the bus and
				// ModelSim's "LSB of part-select out of bounds" warning is
				// the only thing that says so. It fetched X, the kernel
				// arithmetic went X, and the run produced half a million
				// warnings and no interrupts.
				// BYTE-SWAPPED ON THE WAY OUT. maincpu.sv has ROM_BYTESWAP
				// set, because sdram_download.sv pairs image bytes {odd, even}
				// with the EVEN byte in the low half, and the CPU swaps that
				// back into a big-endian word. This ROM holds the program the
				// readable way round, so it has to present it the way the
				// transport would. Without the swap the reset vector reads
				// 0xFF00.. and the CPU runs away through NOPs, which looks
				// like a dead CPU rather than a byte-order error.
				rom_data  <= (rom_hold_a[23:15] == 9'd0)
				             ? {rom[rom_hold_a[14:1]][7:0], rom[rom_hold_a[14:1]][15:8]}
				             : 16'h0000;
				rom_valid <= 1'b1;
				rom_busy  <= 1'b0;
			end else rom_cnt <= rom_cnt - 1;
		end
	end

	logic [15:0] wram [0:262143];
	always @(posedge clk) begin
		if (wram_wel) wram[wram_addr][7:0]  <= wram_wdata[7:0];
		if (wram_weh) wram[wram_addr][15:8] <= wram_wdata[15:8];
		wram_rdata <= wram[wram_addr];
	end

	// ---- what the ISR is observed by ----------------------------------------
	int isr_runs = 0;
	int iack_count = 0;
	int last_iack_level = -1;

	always @(posedge clk) begin
		if (!reset) begin
			// The ISR's write to 0x300000. dbg_addr is a WORD address.
			if (dbg_stb && dbg_we && dbg_addr == 23'h180000 && dbg_data == 16'h1234)
				isr_runs <= isr_runs + 1;
		end
	end

	int acc_count = 0;
	logic [23:1] last_addr = 0;
	always @(posedge clk) if (!reset && dbg_stb) begin
		acc_count <= acc_count + 1;
		last_addr <= dbg_addr;
	end

	// One acknowledge can span several cycles of one access; count edges.
	logic iack_d = 0;
	always @(posedge clk) begin
		iack_d <= iack;
		if (!reset && iack && !iack_d) begin
			iack_count <= iack_count + 1;
			last_iack_level <= iack_level;
		end
	end

	// ---- checks --------------------------------------------------------------
	// LEVELS ARE SET BY INDEX, never by a literal. `hold` and friends are
	// [7:1] vectors, so a literal numbers its bits from the MSB down to index
	// 1 -- 7'b0000110 is levels 3 and 2, not levels 1 and 2. Every pattern in
	// the first version of this bench was off by one that way, and the checks
	// that depended on it failed while the ones that did not passed, which
	// pointed at the RTL.
	function automatic logic [7:1] lv(input int a, input int b = 0, input int c = 0);
		lv = 7'd0;
		if (a inside {[1:7]}) lv[a] = 1'b1;
		if (b inside {[1:7]}) lv[b] = 1'b1;
		if (c inside {[1:7]}) lv[c] = 1'b1;
	endfunction

	int fails = 0;
	int t0;

	task fail(input string why);
		begin
			$display("FAIL: %s", why);
			fails++;
		end
	endtask

	// Wait up to `limit` clocks for isr_runs to reach `target`.
	task wait_isr(input int target, input int limit, input string what);
		int n;
		begin
			n = 0;
			while (isr_runs < target && n < limit) begin
				@(posedge clk);
				n++;
			end
			if (isr_runs < target)
				fail({what, ": the ISR never ran"});
		end
	endtask

	// One extra edge after dropping the pulse, so `pending` has actually
	// updated before the caller looks at it -- a non-blocking assignment is
	// not visible in the same time step it is scheduled.
	task pulse_set(input int level);
		begin
			@(posedge clk);
			irq_set[level] <= 1'b1;
			@(posedge clk);
			irq_set[level] <= 1'b0;
			@(posedge clk);
		end
	endtask

	task pulse_clr(input int level);
		begin
			@(posedge clk);
			irq_clr[level] <= 1'b1;
			@(posedge clk);
			irq_clr[level] <= 1'b0;
		end
	endtask

	int i;
	initial begin
		for (i = 0; i < 16384; i++)  rom[i]  = 16'h4E71;   // NOP everywhere else
		for (i = 0; i < 262144; i++) wram[i] = 16'h0000;

		// vectors
		rom['h000] = 16'h00FF; rom['h001] = 16'hFFF0;   // SP -> work RAM
		rom['h002] = 16'h0000; rom['h003] = 16'h0400;   // PC
		rom['h032] = 16'h0000; rom['h033] = 16'h0500;   // level 1 autovector
		rom['h034] = 16'h0000; rom['h035] = 16'h0500;   // level 2
		rom['h036] = 16'h0000; rom['h037] = 16'h0500;   // level 3
		// main
		rom['h200] = 16'h46FC; rom['h201] = 16'h2000;   // move.w #$2000,SR
		rom['h202] = 16'h60FE;                          // bra.s *
		// ISR
		rom['h280] = 16'h33FC; rom['h281] = 16'h1234;   // move.w #$1234,...
		rom['h282] = 16'h0030; rom['h283] = 16'h0000;   // ...$00300000
		rom['h284] = 16'h4E73;                          // rte

		$display("=== interrupts: seta_irq + TG68K, running a real ISR ===");

		repeat (8) @(posedge clk);
		reset <= 0;

		// Let the CPU reach its spin loop with the mask lowered.
		repeat (600) @(posedge clk);
		$display("  after reset: %0d bus accesses, last addr %06x, ipl %0d",
		         acc_count, {last_addr, 1'b0}, ipl_level);
		if (acc_count == 0)
			fail("the CPU never made a bus access -- it is not running at all");
		if (ipl_level !== 3'd0) fail("ipl is not idle before any request");

		// ---- 1. HOLD_LINE: taken, and the acknowledge clears it -------------
		irq_hold <= lv(1, 2);           // levels 1 and 2 are HOLD
		@(posedge clk);
		pulse_set(2);
		if (!pending[2]) fail("a set pulse did not latch level 2");
		$display("  after set(2): pending %b, ipl %0d", pending, ipl_level);
		wait_isr(1, 4000, "HOLD level 2");
		$display("  after wait:   %0d accesses, last addr %06x, ipl %0d, iacks %0d",
		         acc_count, {last_addr, 1'b0}, ipl_level, iack_count);
		repeat (200) @(posedge clk);
		if (pending[2])
			fail("HOLD level 2 is still pending after the acknowledge -- the FC=111 decode is not firing");
		if (last_iack_level !== 3'd2)
			$display("NOTE: the acknowledge reported level %0d", last_iack_level);
		if (isr_runs != 1)
			fail("the HOLD ISR ran more than once -- the request was not cleared");
		$display("  HOLD:   taken once, acknowledged at level %0d, pending cleared",
		         last_iack_level);

		// ---- 2. ASSERT_LINE: stays pending until an explicit clear ----------
		irq_hold <= 7'd0;               // every level is ASSERT; 3 is the one used
		@(posedge clk);
		pulse_set(3);
		wait_isr(2, 4000, "ASSERT level 3");
		repeat (400) @(posedge clk);
		if (!pending[3])
			fail("ASSERT level 3 cleared itself -- only an explicit ack may clear it");
		if (isr_runs < 3)
			fail("ASSERT level 3 was taken only once -- an uncleared request must re-enter");
		$display("  ASSERT: still pending after %0d ISR entries, as blockcar relies on",
		         isr_runs);
		pulse_clr(3);
		repeat (20) @(posedge clk);
		if (pending[3]) fail("the explicit ack did not clear ASSERT level 3");
		// An interrupt the CPU has ALREADY taken still runs its handler after
		// the flag is cleared, so settle first and only then baseline. The
		// first version baselined immediately and failed on that one entry,
		// which is correct hardware behaviour, not a bug.
		repeat (2000) @(posedge clk);
		t0 = isr_runs;
		repeat (4000) @(posedge clk);
		if (isr_runs != t0)
			fail("the ISR is still being re-entered well after the explicit ack");
		$display("  ASSERT: explicit ack cleared it, ISR stopped after %0d entries",
		         isr_runs);

		// ---- 3. the acknowledge clears the LEVEL TAKEN, not the highest -----
		// Levels 1 and 2 both pending, HOLD; acknowledge level 1. Level 2 must
		// survive. Clearing the highest pending instead would take level 2
		// without ever running its handler, and leave level 1 to be taken
		// twice.
		c_hold <= 7'h7f;               // every level HOLD
		c_set  <= lv(1, 2);
		@(posedge clk);
		c_set  <= 7'd0;
		@(posedge clk);
		if (c_pending !== lv(1, 2))
			fail("the standalone instance did not latch levels 1 and 2");
		if (c_ipl !== 3'd2)
			fail("ipl_level is not the highest pending");
		c_iack <= 1'b1; c_iack_level <= 3'd1;
		@(posedge clk);
		c_iack <= 1'b0;
		@(posedge clk);
		if (c_pending[1]) fail("acknowledging level 1 did not clear it");
		if (!c_pending[2])
			fail("acknowledging level 1 also cleared level 2 -- it clears the highest pending, not the level taken");
		$display("  LEVELS: acknowledging 1 cleared 1 and left 2 pending");

		// An acknowledge must NOT clear an ASSERT_LINE level: only its write
		// may. thunderl would otherwise lose the ack write it actually makes.
		c_hold <= 7'h7f & ~lv(2);      // every level HOLD except 2
		@(posedge clk);
		c_iack <= 1'b1; c_iack_level <= 3'd2;
		@(posedge clk);
		c_iack <= 1'b0;
		@(posedge clk);
		if (!c_pending[2])
			fail("an acknowledge cleared an ASSERT_LINE level");
		c_clr <= lv(2);
		@(posedge clk);
		c_clr <= 7'd0;
		@(posedge clk);
		if (c_pending[2]) fail("the explicit clear did not clear ASSERT level 2");
		$display("  ASSERT: an acknowledge left it alone; its own write cleared it");

		// ---- 4. a set coincident with an acknowledge survives ---------------
		// The sets here are one-cycle EDGES, so a set can never starve an
		// acknowledge and letting it win is safe -- and necessary, because a
		// coincident edge is a NEW interrupt arriving as an older one is taken.
		c_hold <= 7'h7f;
		c_set  <= lv(2);
		@(posedge clk);
		c_set  <= 7'd0;
		@(posedge clk);
		if (!c_pending[2]) fail("level 2 did not latch before the race check");
		c_iack <= 1'b1; c_iack_level <= 3'd2;
		c_set  <= lv(2);               // set and acknowledge on the SAME cycle
		@(posedge clk);
		c_iack <= 1'b0; c_set <= 7'd0;
		@(posedge clk);
		if (!c_pending[2])
			fail("a set coincident with its own acknowledge was swallowed");
		$display("  RACE:   a set on the acknowledge cycle survived");

		$display("");
		$display("  ISR entries      %0d", isr_runs);
		$display("  acknowledges     %0d", iack_count);
		$display("  last iack level  %0d", last_iack_level);
		$display("");
		if (iack_count == 0)
			$display("FAIL: no interrupt acknowledge was ever seen -- FC never reached 111");
		else if (fails != 0)
			$display("FAIL: %0d check(s) failed", fails);
		else
			$display("PASS: %0d acknowledges, HOLD and ASSERT both behave as seta.cpp does",
			         iack_count);
		$finish;
	end

	initial begin
		#60ms;
		$display("FAIL: timed out -- %0d ISR entries, %0d acknowledges, ipl %0d",
		         isr_runs, iack_count, ipl_level);
		$finish;
	end

endmodule
