// rtl/cpu/adc0834.sv driven the way zombraid's gun_w drives it: one register
// write per bit transition, /CS in bit 2, DI in bit 1, CLK in bit 0.
//
//     scripts/run_sim.sh adc0834_tb
//
// Reads every channel single-ended, three differential pairs, aborts a
// conversion with /CS mid-stream, and clocks with DI low before a start bit.
// The expected bit stream is the one MAME's adc083x.cpp produces for the
// same writes: eight bits MSB first, then seven LSB first (bit 1 to bit 7),
// DO high while selected and waiting, low after the last bit.

`timescale 1ns / 1ps

module tb_adc0834;

	logic clk = 0;
	always #5 clk = ~clk;

	logic       reset = 1;
	logic [2:0] gun = 3'b100;      // /CS high, DI 0, CLK 0
	wire        dout;
	logic [7:0] ch [0:3];

	adc0834 dut (
		.clk(clk), .reset(reset),
		.cs_n(gun[2]), .sclk(gun[0]), .di(gun[1]), .dout(dout),
		.ch0(ch[0]), .ch1(ch[1]), .ch2(ch[2]), .ch3(ch[3])
	);

	int bad = 0;

	// One gun_w: the register is written, the ADC sees it on the next edge,
	// and the game's next access is many cycles later.
	task automatic gun_w(input [2:0] v);
		@(posedge clk); gun <= v;
		repeat (3) @(posedge clk);
	endtask

	// Clock one DI bit in: DI set with CLK low, then CLK high, then low.
	task automatic clock_in(input bit d);
		gun_w({1'b0, d, 1'b0});
		gun_w({1'b0, d, 1'b1});
		gun_w({1'b0, d, 1'b0});
	endtask

	// Clock one DO bit out: the bit changes on the FALLING edge.
	task automatic clock_out(output bit d);
		gun_w(3'b001);
		gun_w(3'b000);
		d = dout;
	endtask

	// A whole conversion, the sequence adc083x.cpp expects for the 0834.
	task automatic convert(input bit sgl, input bit odd, input bit sel1,
	                       input string what, input [7:0] want);
		bit b;
		logic [7:0] msb, lsb;
		gun_w(3'b100);
		gun_w(3'b000);                       // /CS falls
		if (dout !== 1'b1) begin bad++; $display("FAIL %s: DO not high after /CS", what); end
		clock_in(1'b1);                      // start
		clock_in(sgl); clock_in(odd); clock_in(sel1);
		for (int i = 7; i >= 0; i--) begin clock_out(b); msb[i] = b; end
		gun_w(3'b001);                       // the SE rising edge
		lsb[0] = msb[0];
		for (int i = 1; i <= 7; i++) begin clock_out(b); lsb[i] = b; end
		gun_w(3'b001); gun_w(3'b000);        // FINISHED -> IDLE
		if (dout !== 1'b0) begin bad++; $display("FAIL %s: DO not low after the last bit", what); end
		gun_w(3'b100);                       // /CS rises
		if (msb !== want || lsb !== want) begin
			bad++;
			$display("FAIL %s: msb-first %02X lsb-first %02X want %02X", what, msb, lsb, want);
		end else
			$display("ok   %s: %02X both ways", what, want);
	endtask

	bit b;

	initial begin
		$display("=== adc0834 against the gun_w protocol ===");
		ch[0] = 8'h3c; ch[1] = 8'hc3; ch[2] = 8'h80; ch[3] = 8'hff;
		repeat (4) @(posedge clk);
		reset <= 0;
		repeat (4) @(posedge clk);

		convert(1, 0, 0, "CH0 single", 8'h3c);
		convert(1, 1, 0, "CH1 single", 8'hc3);
		convert(1, 0, 1, "CH2 single", 8'h80);
		convert(1, 1, 1, "CH3 single", 8'hff);
		convert(0, 1, 0, "CH1-CH0 diff", 8'hc3 - 8'h3c);
		convert(0, 0, 0, "CH0-CH1 diff (clamped)", 8'h00);
		convert(0, 1, 1, "CH3-CH2 diff", 8'h7f);

		// Abort: /CS up after three data bits, then a fresh conversion.
		gun_w(3'b000); clock_in(1'b1); clock_in(1'b1); clock_in(1'b0); clock_in(1'b0);
		clock_out(b); clock_out(b); clock_out(b);
		gun_w(3'b100);
		if (dout !== 1'b1) begin bad++; $display("FAIL abort: DO not high after /CS rose"); end
		ch[0] = 8'ha5;
		convert(1, 0, 0, "CH0 after abort", 8'ha5);

		// No start bit: clocks with DI low leave it waiting.
		gun_w(3'b000); clock_in(1'b0); clock_in(1'b0);
		if (dout !== 1'b1) begin bad++; $display("FAIL no-start: DO changed"); end
		clock_in(1'b1); clock_in(1'b1); clock_in(1'b1); clock_in(1'b1);   // start, SGL, ODD, SEL1
		for (int i = 7; i >= 0; i--) begin
			clock_out(b);
			if (b !== ch[3][i]) begin bad++; $display("FAIL late start: bit %0d", i); end
		end
		gun_w(3'b100);

		// THE GAME'S OWN SEQUENCE. sim/adc0834_tb/gun_writes.hex is every
		// gun_w word MAME logged for zombraid over frames 500 and 501
		// (scripts/mame_capture.py zombraid --frame 600 --wlog --tap
		// f00000:f00003), low byte per line. The game clocks 14 bits for
		// CH0 and 13 for CH1 -- not the canonical count above -- so this
		// replays the words verbatim and decodes DO the way the game must:
		// MSB first, one bit per falling edge after the mux settles. Every
		// conversion in the two frames has to come out as the channel its
		// own DI bits selected.
		begin
			logic [7:0] w [0:4095];
			int n, conv, falls, rises;
			bit in_conv, r_sgl, r_odd, r_sel1, rise, fall;
			logic [7:0] acc, want;
			for (int i = 0; i < 4096; i++) w[i] = 8'hxx;
			$readmemh("sim/adc0834_tb/gun_writes.hex", w);
			while (n < 4096 && w[n] !== 8'hxx) n++;
			$display("--- replaying %0d gun_w words from the game ---", n);
			n = 0; conv = 0; falls = 0; rises = 0;
			in_conv = 0; r_sgl = 0; r_odd = 0; r_sel1 = 0; acc = 8'h00;
			ch[0] = 8'h12; ch[1] = 8'h9a; ch[2] = 8'h45; ch[3] = 8'hcd;
			gun_w(3'b100);
			for (int i = 0; i < n; i++) begin
				rise = !gun[0] && w[i][0];
				fall =  gun[0] && !w[i][0];
				if (w[i][2]) begin in_conv = 0; end
				else if (!in_conv && gun[2]) begin
					// /CS just went low: a conversion starts on the next start bit
					in_conv = 1; falls = 0; rises = 0;
				end
				if (in_conv && rise) begin
					rises++;
					case (rises)
						2: r_sgl  = w[i][1];
						3: r_odd  = w[i][1];
						4: r_sel1 = w[i][1];
						default: ;
					endcase
				end
				gun_w(w[i][2:0]);
				if (in_conv && fall && rises >= 4) begin
					falls++;
					// fall 1: the mux settles and DO drops; falls 2..9: bits 7..0
					if (falls >= 2 && falls <= 9) acc[9 - falls] = dout;
					if (falls == 9) begin
						want = ch[{r_sel1, r_odd}];
						conv++;
						if (!r_sgl || acc !== want) begin
							bad++;
							$display("FAIL game word %0d: sgl=%0d odd=%0d sel1=%0d got %02X want %02X",
							         i, r_sgl, r_odd, r_sel1, acc, want);
						end
					end
				end
			end
			$display("  %0d conversions replayed from the game, all as selected", conv);
			if (conv < 4) begin bad++; $display("FAIL: expected at least 4 conversions"); end
		end

		if (bad == 0) $display("PASS: every conversion matched");
		else          $display("FAIL: %0d check(s)", bad);
		$finish;
	end

endmodule
