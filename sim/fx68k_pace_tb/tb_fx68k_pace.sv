// fx68k's pace, and the enable hold maincpu.sv uses so a slow access costs
// 96 MHz cycles instead of a 68000 wait state.
//
//     scripts/run_sim.sh fx68k_pace_tb [+LAT=n] [+HALF=n]
//
// Runs twineagl's boot delay loop (move.w #$2820,D0; nop; dbra D0) and counts
// CPU clocks (phi1 enables) between fetches of the nop: a 68000 takes 14 an
// iteration (NOP 4, DBRA taken 10). The memory answers LAT clk after AS and
// the data strobes assert; HALF is clk per phase (6 = 8 MHz, 3 = 16 MHz at
// 96 MHz). With LAT past the DTACK sample, the hold must keep the count at 14
// and no bus cycle may see DTACK late (wait states).

`timescale 1ns / 1ps

module tb_fx68k_pace;
	logic clk = 0;
	always #5 clk = ~clk;
	logic reset = 1;

	int HALF = 6, LAT = 4;
	initial begin
		void'($value$plusargs("HALF=%d", HALF));
		void'($value$plusargs("LAT=%d", LAT));
	end

	wire        ASn, UDSn, LDSn, eRWn, FC0, FC1, FC2;
	wire [23:1] eab;
	wire [15:0] oEdb;
	logic [15:0] iEdb;
	logic       ready = 0;
	wire        cyc = !ASn && !(UDSn && LDSn);
	wire        DTACKn = !(ready && !ASn);

	// enables: phi1 and phi2 alternate every HALF clk; a phi2 that would
	// sample DTACK while the access is not ready is held until it is
	logic [4:0] cnt = 0;
	logic       next_phi2 = 0;
	int         phi2_in_cyc = 0;
	wire        due  = (cnt == HALF - 1);
	wire        hold = next_phi2 && cyc && !ready && phi2_in_cyc >= 1;
	wire        en1  = due && !next_phi2;
	wire        en2  = due && next_phi2 && !hold;
	always @(posedge clk) begin
		if (!due) cnt <= cnt + 1;
		else if (!hold) begin cnt <= 0; next_phi2 <= ~next_phi2; end
		if (!cyc) phi2_in_cyc <= 0;
		else if (en2) phi2_in_cyc <= phi2_in_cyc + 1;
	end

	fx68k u_cpu (
		.clk(clk), .HALTn(1'b1), .extReset(reset), .pwrUp(reset),
		.enPhi1(en1), .enPhi2(en2),
		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(),
		.FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(), .oRESETn(), .oHALTEDn(),
		.DTACKn(DTACKn), .VPAn(1'b1), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(1'b1), .IPL1n(1'b1), .IPL2n(1'b1),
		.iEdb(iEdb), .oEdb(oEdb), .eab(eab)
	);

	logic [15:0] mem [0:4095];
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

	// memory: ready LAT clk into the cycle, until AS rises
	int age = 0;
	always @(posedge clk) begin
		if (!cyc && ASn) begin age <= 0; ready <= 0; end
		else if (cyc) begin
			age <= age + 1;
			if (age + 1 >= LAT) begin
				ready <= 1;
				iEdb  <= mem[eab[12:1]];
			end
		end
	end

	// clocks per iteration: phi1 enables between fetches of the nop
	longint clocks = 0, t_first = -1, t_second = -1, t_last = -1;
	int     loops = 0, as_clocks = 0, as_max = 0;
	logic   as_q = 1;
	// CPU clocks (phi1) seen with AS low in one cycle: 2 without wait states
	always @(posedge clk) begin
		if (ASn) as_clocks <= 0;
		else if (en1) begin
			as_clocks <= as_clocks + 1;
			if (as_clocks + 1 > as_max) as_max <= as_clocks + 1;
		end
	end
	always @(posedge clk) begin
		if (en1) clocks <= clocks + 1;
		as_q <= ASn;
		if (as_q && !ASn && {FC2, FC1, FC0} == 3'b110 && eab == 23'h82) begin
			loops <= loops + 1;
			t_last <= clocks;
			if (t_first < 0) t_first <= clocks;
			else if (t_second < 0) t_second <= clocks;
		end
	end

	initial begin
		repeat (40) @(posedge clk);
		reset = 0;
		wait (loops == ITER + 1);            // + the prefetch at the loop's exit
		repeat (2000) @(posedge clk);
		$display("HALF %0d, LAT %0d: nop fetches %0d of %0d", HALF, LAT, loops, ITER + 1);
		$display("one iteration: %0d clocks (68000: 14)", t_second - t_first);
		$display("%0d iterations: %0d clocks (68000: %0d)", ITER,
		         t_last - t_first, ITER * 14);
		$display("most CPU clocks with AS low in one cycle: %0d (2 = no wait states)", as_max);
		if (t_last - t_first == ITER * 14 && as_max == 2) $display("PASS");
		else $display("FAIL");
		$finish;
	end

	initial begin
		#2s;
		$display("TIMEOUT: %0d nop fetches", loops);
		$finish;
	end
endmodule
