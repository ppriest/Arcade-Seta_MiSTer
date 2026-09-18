// TG68K.C's pace against a 68000's: clock enables per instruction for the
// delay loop twineagl's boot uses to wait for the sub CPU (0x35e-0x364):
//
//     move.w #$2820, D0
//     nop
//     dbra   D0, *-2
//
// A 68000 takes NOP 4 clocks and DBRA 10 (taken) / 14 (expired), MC68000
// user's manual table 8-11: 14 per iteration, 0x2821 iterations = 143,832
// clocks, 17.98 ms at 8 MHz. MAME's m68000 core charges the same.
//
//     scripts/run_sim.sh tg68k_pace_tb
//
// The ROM answers on the enable after the address (as the smoke bench), so
// this is the kernel's pace alone; maincpu.sv adds its own waits for SDRAM
// and peripheral access on top.

`timescale 1ns / 1ps

module tb_tg68k_pace;
	logic clk = 0;
	always #5 clk = ~clk;
	logic nreset = 0;
	// one enable in six, as the smoke bench: the registered ROM read settles
	// well inside it
	logic [2:0] div = 0;
	always @(posedge clk) div <= (div == 3'd5) ? 3'd0 : div + 3'd1;
	wire clkena = (div == 3'd0);

	logic [31:0] addr_out;
	logic [15:0] data_in, data_write;
	logic        nWr, nUDS, nLDS, longword, nResetOut, clr_berr, skipFetch;
	logic [1:0]  busstate;
	logic [2:0]  fc;
	logic [31:0] regin_out, vbr_out;
	logic [3:0]  cacr_out;

	TG68KdotC_Kernel u_cpu (
		.clk(clk), .nReset(nreset), .clkena_in(clkena), .data_in(data_in),
		.IPL(3'b111), .IPL_autovector(1'b0), .berr(1'b0), .CPU(2'b00),
		.addr_out(addr_out), .data_write(data_write), .nWr(nWr),
		.nUDS(nUDS), .nLDS(nLDS), .busstate(busstate), .longword(longword),
		.nResetOut(nResetOut), .FC(fc), .clr_berr(clr_berr),
		.skipFetch(skipFetch), .regin_out(regin_out), .CACR_out(cacr_out),
		.VBR_out(vbr_out)
	);

	logic [15:0] mem [0:4095];
	logic [15:0] mem_q;
	always @(posedge clk) mem_q <= mem[addr_out[12:1]];
	assign data_in = mem_q;

	localparam int ITER = 16'h2821;

	initial begin
		for (int i = 0; i < 4096; i++) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;          // SP
		mem[2] = 16'h0000; mem[3] = 16'h0100;          // PC
		mem[16'h100 >> 1] = 16'h303C;                  // move.w #$2820, D0
		mem[16'h102 >> 1] = 16'h2820;
		mem[16'h104 >> 1] = 16'h4E71;                  // nop
		mem[16'h106 >> 1] = 16'h51C8;                  // dbra D0, $104
		mem[16'h108 >> 1] = 16'hFFFC;
		mem[16'h10A >> 1] = 16'h60FE;                  // bra.s *
	end

	// time between fetches of the nop: the first and the last give
	// ITER - 1 whole iterations (TG68K prefetches, so the bra's address is
	// read before the loop ends and cannot mark it)
	longint ce = 0, t_first = -1, t_second = -1, t_last = -1;
	int     loops = 0;
	logic   fetch_q = 0;
	always @(posedge clk) if (nreset && clkena) begin
		ce <= ce + 1;
		fetch_q <= busstate == 2'b00 && addr_out == 32'h104;
		if (busstate == 2'b00 && addr_out == 32'h104 && !fetch_q) begin
			loops <= loops + 1;
			t_last <= ce;
			if (t_first < 0) t_first <= ce;
			else if (t_second < 0) t_second <= ce;
		end
	end

	initial begin
		repeat (20) @(posedge clk);
		nreset <= 1;
		wait (loops == ITER);
		repeat (600) @(posedge clk);
		$display("fetches of the nop: %0d, expected %0d", loops, ITER);
		$display("one iteration: %0d enables (68000: 14)", t_second - t_first);
		$display("%0d iterations: %0d enables (68000: %0d)",
		         ITER - 1, t_last - t_first, (ITER - 1) * 14);
		$display("whole loop at 8 MHz: %0.2f ms (68000: %0.2f ms)",
		         (t_last - t_first) * ITER / (ITER - 1) / 8000.0, ITER * 14 / 8000.0);
		$finish;
	end

	initial begin
		#200ms;
		$display("TIMEOUT");
		$finish;
	end
endmodule
