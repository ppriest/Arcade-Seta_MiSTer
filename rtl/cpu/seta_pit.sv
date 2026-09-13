// uPD71054C (8254) PIT, channel 0 only: seta.cpp clocks channel 0 at 1 MHz
// and wires OUT0's rising edge to IPL 4 (pit_out0); channels 1 and 2 are
// unconnected. IRQ 4 is acknowledged in the memory map, not here.
//
// Binary counting, modes 0, 2 and 3. Anything else is a simulation $error.
`default_nettype none

module seta_pit (
	input  wire        clk,
	input  wire        reset,

	input  wire        ce,                // 1 MHz

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

	// Mode 3 half-periods for a count of n (0 = 65536): high for the larger
	// half, low for the smaller, one rising edge every n clocks.
	function automatic [15:0] half_hi(input [15:0] n);
		half_hi = 16'(({n == 16'd0, n} + 17'd1) >> 1);
	endfunction
	function automatic [15:0] half_lo(input [15:0] n);
		half_lo = 16'({n == 16'd0, n} >> 1);
	endfunction

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
						out0     <= (wdata[3:1] != 3'd0);   // mode 0 starts low
					end
				end else if (addr == 2'd0) begin
					case (rw_mode)
					2'd1: begin latch_val <= {8'd0, wdata};
					            count <= (mode == 3'd3) ? half_hi({8'd0, wdata}) : {8'd0, wdata};
					            loaded <= 1'b1; running <= 1'b1; end
					2'd2: begin latch_val <= {wdata, 8'd0};
					            count <= (mode == 3'd3) ? half_hi({wdata, 8'd0}) : {wdata, 8'd0};
					            loaded <= 1'b1; running <= 1'b1; end
					default:
						if (!msb_next) begin
							latch_val[7:0] <= wdata;
							msb_next <= 1'b1;
							running  <= 1'b0;
						end else begin
							latch_val[15:8] <= wdata;
							count    <= (mode == 3'd3) ? half_hi({wdata, latch_val[7:0]})
							                           : {wdata, latch_val[7:0]};
							msb_next <= 1'b0;
							loaded   <= 1'b1;
							running  <= 1'b1;
						end
					endcase
				end
			end else if (ce && running && loaded) begin
				if (count == 16'd1 || count == 16'd0) begin      // 0 = 65536
					case (mode)
					3'd0: begin                    // terminal count: high and stop
						out0    <= 1'b1;
						running <= 1'b0;
						count   <= 16'd0;
					end
					3'd2: begin                    // rate generator: low for one clock
						out0  <= 1'b1;
						count <= latch_val;
					end
					3'd3: begin                    // square wave: toggle each half period
						out0  <= ~out0;
						count <= out0 ? half_lo(latch_val) : half_hi(latch_val);
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
