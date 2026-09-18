// downtown_sub running DownTown's sub ROM from reset, 68000 side idle: each
// instruction's address against MAME's trace (prep.py), to the first
// difference. Interrupts are raised where MAME's trace took them (irq_at.hex),
// not off the bench's scanlines. The 68000 writes shared RAM and the latches
// in MAME, so the traces are expected to part where the program first reads a
// value it wrote; the report says where. At 0d0d9b3 + downtown_sub: 45565
// instructions, parting at 71bb `lda $5052` (shared RAM).
//     python sim/downtown_sub_tb/prep.py ; scripts/run_sim.sh downtown_sub_tb

`timescale 1ns/1ps
`default_nettype none

module tb_downtown_sub;
	logic clk = 0;
	always #5 clk = ~clk;
	logic reset = 1;

	// 2 MHz from 96 MHz
	logic [5:0] div = 0;
	always_ff @(posedge clk) div <= (div == 6'd47) ? 6'd0 : div + 6'd1;
	wire ce = (div == 6'd0);

	// scanline pulses: 512 dots x 12 clk, 272 lines
	int hcnt = 0, line = 0;
	logic l112 = 0, l240 = 0;
	always_ff @(posedge clk) begin
		l112 <= 0; l240 <= 0;
		if (hcnt == 6143) begin
			hcnt <= 0;
			line <= (line == 271) ? 0 : line + 1;
			if (line + 1 == 112) l112 <= 1;
			if (line + 1 == 240) l240 <= 1;
		end else hcnt <= hcnt + 1;
	end

	logic [7:0] region [0:32'h4bfff];
	wire        rom_req;
	wire [18:0] rom_addr;
	logic       rom_valid = 0;
	logic [7:0] rom_data;
	int         rom_cnt = 0;
	logic [18:0] rom_hold;
	always_ff @(posedge clk) begin
		rom_valid <= 0;
		if (rom_req) begin rom_cnt <= 6; rom_hold <= rom_addr; end
		else if (rom_cnt != 0) begin
			rom_cnt <= rom_cnt - 1;
			if (rom_cnt == 1) begin rom_valid <= 1; rom_data <= region[rom_hold]; end
		end
	end

	logic inj_nmi = 0, inj_irq = 0;
	int   inj_done = -1;

	// the set's downtown_board_cfg.sv values (prep.py --game)
	logic [1:0] sub_map = 2'd0;
	logic [4:0] bank_entries = 5'd16;
	int pa;
	initial begin
		if ($value$plusargs("SUB_MAP=%d", pa)) sub_map = pa[1:0];
		if ($value$plusargs("BANK_ENTRIES=%d", pa)) bank_entries = pa[4:0];
	end

	downtown_sub dut (
		.clk(clk), .reset(reset), .ce(ce),
		.sub_map(sub_map), .bank_entries(bank_entries),
		.m_shr_req(1'b0), .m_shr_we(1'b0), .m_shr_addr(11'd0), .m_shr_wdata(8'd0),
		.m_shr_rdata(),
		.m_ctrl_we(1'b0), .m_ctrl_addr(2'd0), .m_ctrl_wdata(8'd0),
		.p1_in(8'hff), .p2_in(8'hff), .coins_in(8'hff), .rot1(4'd0), .rot2(4'd0),
		.line_112(inj_irq), .line_240(inj_nmi),
		.rom_req(rom_req), .rom_addr(rom_addr), .rom_valid(rom_valid), .rom_data(rom_data)
	);

	logic [15:0] expect_pc [0:199999];
	logic  [1:0] irq_at [0:199999];
	int n = 0, first_bad = -1, total;
	logic [15:0] hist [0:15];
	initial begin
		for (int i = 0; i < 200000; i++) expect_pc[i] = 16'hxxxx;
		$readmemh("sim/downtown_sub_tb/sub.hex", region);
		$readmemh("sim/downtown_sub_tb/expect_pc.hex", expect_pc);
		$readmemh("sim/downtown_sub_tb/irq_at.hex", irq_at);
		total = 0;
		while (total < 200000 && expect_pc[total] !== 16'hxxxx) total++;
		repeat (20) @(posedge clk);
		reset = 0;
	end

	// T65 raises Sync for an interrupt's entry sequence too, at the
	// interrupted PC; MAME's trace has no line for it
	logic nmicyc, irqcyc;
	initial begin
		$init_signal_spy("/tb_downtown_sub/dut/u_cpu/u_t65/NMICycle", "/tb_downtown_sub/nmicyc", 1);
		$init_signal_spy("/tb_downtown_sub/dut/u_cpu/u_t65/IRQCycle", "/tb_downtown_sub/irqcyc", 1);
	end

	// one block with the count, so the injection reads n before it moves
	always @(posedge clk) begin
		inj_nmi <= 0;
		inj_irq <= 0;
		// raised before instruction n's first step, so T65 has seen it by the
		// end of that instruction however short
		if (!reset && !dut.step && dut.sync && !nmicyc && !irqcyc && n < total
		    && irq_at[n] != 2'd0 && inj_done != n) begin
			inj_done <= n;
			if (irq_at[n] == 2'd1) inj_nmi <= 1;
			if (irq_at[n] == 2'd2) inj_irq <= 1;
		end
		if (!reset && dut.step && dut.sync && !nmicyc && !irqcyc) begin
		hist[n % 16] = dut.a;
		if (first_bad < 0 && n < total && dut.a !== expect_pc[n]) begin
			first_bad = n;
			$display("first difference at instruction %0d: core %04x, MAME %04x (line %0d)",
			         n, dut.a, expect_pc[n], line);
			for (int k = 15; k >= 1; k--)
				if (n - k >= 0) $display("  %0d: core %04x  MAME %04x", n - k, hist[(n - k) % 16], expect_pc[n - k]);
			for (int k = 1; k <= 6; k++)
				if (n + k < total) $display("  %0d: MAME %04x", n + k, expect_pc[n + k]);
		end
		n++;
		if (n == total || (first_bad >= 0 && n > first_bad + 8)) begin
			if (first_bad < 0) $display("PASS: %0d instructions match MAME", n);
			else               $display("%0d instructions matched before the first difference", first_bad);
			$finish;
		end
		end
	end

	initial begin
		#20s;
		$display("TIMEOUT after %0d instructions", n);
		$finish;
	end
endmodule

`default_nettype wire
