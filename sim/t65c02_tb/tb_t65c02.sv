// T65 in 65C02 mode (rtl/cpu/t65c02.vhd) running sim/t65c02_tb/prog.hex: the
// instructions added to T65 leave the results in expect.txt ("M addr byte")
// and take the WDC cycle counts ("C pc opcode cycles", Sync to Sync).
//     python sim/t65c02_tb/make_prog.py ; scripts/run_sim.sh t65c02_tb

`timescale 1ns/1ps
`default_nettype none

module tb_t65c02;
	logic clk = 0;
	always #5 clk = ~clk;

	logic        reset_n = 0;
	wire  [15:0] addr;
	wire   [7:0] dout;
	wire         rw_n, sync;
	logic  [7:0] mem [0:65535];
	logic  [7:0] rom [0:16383];

	wire [7:0] din = !rw_n ? dout : (addr >= 16'hC000) ? rom[addr - 16'hC000] : mem[addr];

	t65c02 u_cpu (
		.clk(clk), .ce(1'b1), .reset_n(reset_n), .irq_n(1'b1), .nmi_n(1'b1),
		.addr(addr), .din(din), .dout(dout), .rw_n(rw_n), .sync(sync)
	);

	always @(posedge clk) if (!rw_n) mem[addr] <= dout;

	// cycles per instruction, keyed by the opcode's address
	int          cyc_at [int];
	int          count = 0, last_pc = -1;
	always @(posedge clk) if (reset_n) begin
		if (sync) begin
			if (last_pc >= 0) cyc_at[last_pc] = count;
			last_pc = addr;
			count = 1;
		end else count++;
	end

	int fd, a, v, op, c, n, fails = 0, checks = 0;
	string kind;
	initial begin
		for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
		$readmemh("sim/t65c02_tb/prog.hex", rom);
		repeat (5) @(posedge clk);
		reset_n = 1;

		fork
			wait (mem[16'h0200] == 8'h01);
			begin repeat (200000) @(posedge clk); $display("FAIL: timed out, PC %04x", addr); end
		join_any
		disable fork;
		repeat (20) @(posedge clk);

		fd = $fopen("sim/t65c02_tb/expect.txt", "r");
		while ($fscanf(fd, "%s", kind) == 1) begin
			if (kind == "M") begin
				n = $fscanf(fd, "%h %h", a, v);
				checks++;
				if (mem[a] !== v[7:0]) begin
					$display("FAIL mem[%04x] = %02x, expected %02x", a, mem[a], v);
					fails++;
				end
			end else begin
				n = $fscanf(fd, "%h %h %d", a, op, c);
				checks++;
				if (!cyc_at.exists(a)) begin
					$display("FAIL opcode %02x at %04x never completed", op, a);
					fails++;
				end else if (cyc_at[a] != c) begin
					$display("FAIL opcode %02x at %04x took %0d cycles, expected %0d", op, a, cyc_at[a], c);
					fails++;
				end
			end
		end
		$fclose(fd);
		if (fails == 0) $display("PASS: %0d checks", checks);
		else            $display("FAIL: %0d of %0d checks", fails, checks);
		$finish;
	end
endmodule

`default_nettype wire
