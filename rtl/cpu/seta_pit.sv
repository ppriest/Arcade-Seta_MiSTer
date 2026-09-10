// The uPD71054C / 8254 programmable interval timer, CHANNEL 0 ONLY.
//
// Six machine_configs in seta.cpp instantiate one -- gundhara, kamenrid,
// madshark, magspeed, msgundam and wrofaero -- and every one of them wires
// exactly the same thing:
//
//     pit8254_device &pit(PIT8254(config, "pit"));   // uPD71054C
//     pit.set_clk<0>(16000000/2/8);                  // 1 MHz
//     pit.out_handler<0>().set(FUNC(seta_state::pit_out0));
//
//     void seta_state::pit_out0(int state)
//     {
//         if (state)
//             m_maincpu->set_input_line(4, ASSERT_LINE);
//     }
//
// So channel 0's OUT going high asserts IPL 4, and nothing else about the
// device is connected: channels 1 and 2 have no clock and no handler, and the
// gate inputs are tied high by default. IRQ 4 is cleared by ipl2_ack_w, which
// the memory map decodes separately -- this module does not clear it.
//
// WHAT IS IMPLEMENTED
//
//   Channel 0, binary counting, modes 0, 2 and 3, with the two-byte load
//   sequence (RW = 11, lo then hi) and the single-byte modes. That is what a
//   periodic interrupt needs and what these games program.
//
// WHAT IS NOT, and will assert in simulation rather than pretend
//
//   Channels 1 and 2, BCD counting, modes 1, 4 and 5, the read-back command,
//   and counter latching. None is reachable through the wiring above; if a
//   game turns out to use one, the $error says so instead of the timer
//   quietly running at the wrong rate.
`default_nettype none

module seta_pit (
	input  wire        clk,
	input  wire        reset,

	// One pulse per PIT clock. 16 MHz / 2 / 8 = 1 MHz on every board that has
	// one, so the divider lives in the core rather than here.
	input  wire        ce,

	// The CPU side. umask16(0x00ff) in every map, so this is the low byte of
	// a 16-bit write and addr picks the counter or the control word.
	input  wire        we,
	input  wire  [1:0] addr,           // 0 = counter 0, 3 = control
	input  wire  [7:0] wdata,

	output logic       out0
);

	logic [15:0] count;
	logic [15:0] latch_val;
	logic  [1:0] rw_mode;              // 1 = lo only, 2 = hi only, 3 = lo then hi
	logic  [2:0] mode;
	logic        loaded;               // a count has been written
	logic        msb_next;             // the lo byte of an RW=3 pair is in
	logic        running;

	always_ff @(posedge clk) begin
		if (reset) begin
			out0     <= 1'b0;
			loaded   <= 1'b0;
			running  <= 1'b0;
			msb_next <= 1'b0;
			rw_mode  <= 2'd3;
			mode     <= 3'd0;
			count    <= 16'd0;
			latch_val <= 16'd0;
		end else begin
			if (we) begin
				if (addr == 2'd3) begin
					// Control word: SC1 SC0 RW1 RW0 M2 M1 M0 BCD
					if (wdata[7:6] != 2'b00) begin
						// synthesis translate_off
						$error("seta_pit: counter %0d is not implemented",
						       wdata[7:6]);
						// synthesis translate_on
					end else if (wdata[5:4] == 2'b00) begin
						// synthesis translate_off
						$error("seta_pit: the read-back / latch command is not implemented");
						// synthesis translate_on
					end else begin
						if (wdata[0]) begin
							// synthesis translate_off
							$error("seta_pit: BCD counting is not implemented");
							// synthesis translate_on
						end
						rw_mode  <= wdata[5:4];
						mode     <= wdata[3:1];
						msb_next <= 1'b0;
						running  <= 1'b0;
						loaded   <= 1'b0;
						// Mode 0 takes OUT low on the control write; the rate
						// and square-wave modes take it high.
						out0     <= (wdata[3:1] != 3'd0);
					end
				end else if (addr == 2'd0) begin
					case (rw_mode)
					2'd1: begin latch_val <= {8'd0, wdata};
					            count <= {8'd0, wdata};
					            loaded <= 1'b1; running <= 1'b1; end
					2'd2: begin latch_val <= {wdata, 8'd0};
					            count <= {wdata, 8'd0};
					            loaded <= 1'b1; running <= 1'b1; end
					default:
						if (!msb_next) begin
							latch_val[7:0] <= wdata;
							msb_next <= 1'b1;
							running  <= 1'b0;
						end else begin
							latch_val[15:8] <= wdata;
							count    <= {wdata, latch_val[7:0]};
							msb_next <= 1'b0;
							loaded   <= 1'b1;
							running  <= 1'b1;
						end
					endcase
				end
			end else if (ce && running && loaded) begin
				// A count of 0 means 65536 -- the counter wraps through it.
				if (count == 16'd1 || count == 16'd0) begin
					case (mode)
					3'd0: begin
						// Interrupt on terminal count: OUT goes high and stays.
						out0    <= 1'b1;
						running <= 1'b0;
						count   <= 16'd0;
					end
					3'd2: begin
						// Rate generator: OUT low for one clock at the end.
						out0  <= 1'b1;
						count <= latch_val;
					end
					3'd3: begin
						// Square wave. Modelled at counter resolution rather
						// than half-count resolution: OUT toggles at terminal
						// count. The games use it for a periodic IRQ, and only
						// the RISING edge is wired, so the edge RATE is what
						// matters and it is right; the duty cycle is not.
						out0  <= ~out0;
						count <= latch_val;
					end
					default: begin
						// synthesis translate_off
						$error("seta_pit: mode %0d is not implemented", mode);
						// synthesis translate_on
						count <= latch_val;
					end
					endcase
				end else begin
					count <= count - 16'd1;
					if (mode == 3'd2) out0 <= 1'b0;
				end
			end
		end
	end

endmodule

`default_nettype wire
