// sdram.sv alone, against the command-decoding chip model: write a granule
// one word at a time, read it back as a burst, and require every lane to
// hold the word that was written at that address -- in that order.
//
//     scripts/run_sim.sh sdram_tb            (from the repository root)
//
// WHY THIS EXISTS. The controller captures the data bus into a single
// register, dq_in, and takes the four burst lanes from it a cycle later.
// That is a change to the read timeline (STATE_READ0 moved by one), and the
// failure a wrong timeline produces is not noise: it is every lane holding
// its neighbour's word, or the last lane holding whatever the bus floated to.
// A read-back of known data through the real command decoder is the only
// check that distinguishes "one cycle early" from "one cycle late" from
// "right", and LESSONS_LEARNED ("Verify a burst extension against a
// command-decoding chip model, not a latency stub") is why it is this model
// and not a latency stub.
//
// sim/sdram_top_tb is the whole memory path over a real image and is the
// stronger test, but its fixture is stale and it fails on the unmodified
// controller (4898 of 5497 read-backs, before this change), so it cannot
// judge a controller change. This bench can.
//
// Three granules are written and read: one at address 0, one straddling
// nothing but far away (a different row and bank), and one immediately
// after another read with no idle cycle, which is where a lane shift shows.

`timescale 1ns / 1ps

module tb_sdram;

	localparam realtime CLK_PERIOD = 10.4167;   // 96 MHz, as the core runs it

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	// ---- the chip ----------------------------------------------------------
	wire  [15:0] SDRAM_DQ;
	wire  [12:0] SDRAM_A;
	wire   [1:0] SDRAM_BA;
	wire         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
	wire         SDRAM_DQML, SDRAM_DQMH, SDRAM_CLK, SDRAM_CKE;

	sdram_chip_model_wide u_chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// ---- the controller, port 0 only --------------------------------------
	logic        init = 1;
	logic [25:1] addr0 = 0;
	logic        wrl0 = 0, wrh0 = 0;
	logic [15:0] din0 = 0;
	wire  [63:0] dout0;
	logic        req0 = 0;
	wire         ack0;

	sdram u_sdram (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
		.init(init), .clk(clk),
		.addr0(addr0), .wrl0(wrl0), .wrh0(wrh0), .din0(din0), .dout0(dout0),
		.req0(req0), .ack0(ack0),
		.addr1('0), .wrl1(1'b0), .wrh1(1'b0), .din1('0), .dout1(), .req1(1'b0), .ack1(),
		.addr2('0), .wrl2(1'b0), .wrh2(1'b0), .din2('0), .dout2(), .req2(1'b0), .ack2()
	);

	// The req/ack handshake is a toggle: flip req, wait until ack equals it.
	task automatic xfer(input [25:1] a, input we, input [15:0] d);
		@(posedge clk);
		addr0 <= a; din0 <= d; wrl0 <= we; wrh0 <= we;
		req0  <= ~req0;
		@(posedge clk);
		while (ack0 !== req0) @(posedge clk);
		wrl0 <= 0; wrh0 <= 0;
	endtask

	// Write eight bytes as four words at granule g (byte address g*8).
	task automatic write_granule(input [22:0] g, input [63:0] v);
		for (int i = 0; i < 4; i++)
			xfer({g, i[1:0]}, 1'b1, v[16*i +: 16]);
	endtask

	// Read the granule back; the controller presents the burst on dout0 once
	// ack toggles, lane 0 = lowest address = dout[15:0].
	task automatic read_granule(input [22:0] g, output [63:0] v);
		xfer({g, 2'b00}, 1'b0, 16'h0);
		@(posedge clk);
		v = dout0;
	endtask

	int bad = 0;
	logic [63:0] got;

	task automatic check(input string what, input [22:0] g, input [63:0] want);
		read_granule(g, got);
		if (got !== want) begin
			bad++;
			$display("FAIL %s: granule %06X got %016X want %016X", what, g, got, want);
			for (int i = 0; i < 4; i++)
				if (got[16*i +: 16] !== want[16*i +: 16])
					$display("       lane %0d: got %04X want %04X", i, got[16*i +: 16], want[16*i +: 16]);
		end else
			$display("ok   %s: granule %06X = %016X", what, g, got);
	endtask

	initial begin
		$display("=== sdram.sv against the chip model: granule write, burst read ===");
		// Bring the controller up: init pulses high then low, and the
		// controller's own reset/mode sequence runs from there.
		repeat (10) @(posedge clk);
		init <= 0;
		repeat (400) @(posedge clk);   // precharge, refreshes, load-mode

		write_granule(23'h000000, 64'h4444_3333_2222_1111);
		write_granule(23'h0A5A5A, 64'hDEAD_BEEF_C0DE_F00D);   // another row and bank
		write_granule(23'h000001, 64'h8888_7777_6666_5555);   // the next granule

		check("first",        23'h000000, 64'h4444_3333_2222_1111);
		check("far",          23'h0A5A5A, 64'hDEAD_BEEF_C0DE_F00D);
		// Back to back: a lane shift would leak one granule into the next.
		check("back-to-back", 23'h000000, 64'h4444_3333_2222_1111);
		check("back-to-back", 23'h000001, 64'h8888_7777_6666_5555);
		check("back-to-back", 23'h0A5A5A, 64'hDEAD_BEEF_C0DE_F00D);

		if (bad == 0) $display("PASS: every lane of every granule read back as written");
		else          $display("FAIL: %0d granule(s) disagree", bad);
		$finish;
	end

endmodule
