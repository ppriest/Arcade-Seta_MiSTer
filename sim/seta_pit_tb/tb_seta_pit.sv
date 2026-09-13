// seta_pit: mode 3's rising edge comes once every N clocks.
//
//     scripts/run_verilator.sh seta_pit_tb
//     scripts/run_sim.sh seta_pit_tb
//
// Every PIT game in seta.cpp writes control 0x36 (counter 0, lo/hi, mode 3)
// and only OUT's rising edge is wired, to IPL 4 -- so the edge period is the
// game's timer tick. Counts include wrofaero's 0x8234 and gundhara's 0x5160
// (MAME write taps), an odd count, and 0 = 65536. Mode 2 is checked too.

`timescale 1ns / 1ps

module tb_seta_pit;

	logic clk = 0;
	always #5 clk = ~clk;

	logic       reset = 1, we = 0;
	logic [1:0] addr = 0;
	logic [7:0] wdata = 0;
	wire        out0;

	// ce every clock: the period is counted in PIT clocks directly.
	seta_pit dut (.clk(clk), .reset(reset), .ce(1'b1), .we(we), .addr(addr),
	              .wdata(wdata), .out0(out0));

	task automatic wr(input [1:0] a, input [7:0] d);
		@(posedge clk);
		addr <= a; wdata <= d; we <= 1'b1;
		@(posedge clk);
		we <= 1'b0;
	endtask

	int fails = 0;

	task automatic check(input [7:0] ctrl, input [15:0] n);
		int expect_p, t, last, p;
		bit  prev;
		expect_p = (n == 0) ? 65536 : n;
		wr(2'd3, ctrl);
		wr(2'd0, n[7:0]);
		wr(2'd0, n[15:8]);
		// Skip the first edge, then time three periods.
		last = -1; t = 0; prev = out0;
		for (int edges = 0; edges < 4; ) begin
			@(posedge clk);
			t++;
			if (out0 && !prev) begin
				if (last >= 0) begin
					p = t - last;
					if (p != expect_p) begin
						$display("FAIL: control %02x count %04x: rising edges %0d clocks apart, expected %0d",
						         ctrl, n, p, expect_p);
						fails++;
					end
				end
				last = t;
				edges++;
			end
			prev = out0;
			if (t > 4 * expect_p + 1000) begin
				$display("FAIL: control %02x count %04x: fewer than 4 rising edges", ctrl, n);
				fails++;
				break;
			end
		end
		$display("  control %02x count %04x: period %0d", ctrl, n, p);
	endtask

	initial begin
		$display("=== seta_pit: rising-edge period ===");
		repeat (4) @(posedge clk);
		reset <= 0;
		check(8'h36, 16'h8234);     // wrofaero
		check(8'h36, 16'h5160);     // gundhara
		check(8'h36, 16'h0005);     // odd
		check(8'h36, 16'h0000);     // 65536
		check(8'h34, 16'h8234);     // mode 2
		if (fails == 0) $display("PASS: rising edges once per count in modes 2 and 3");
		else            $display("FAIL: %0d period(s) wrong", fails);
		$finish;
	end

endmodule
