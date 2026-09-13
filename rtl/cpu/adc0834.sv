// ADC0834 serial ADC behind Zombie Raid's guns: MAME's adc083x.cpp state
// machine for the 0834. The 68000 bit-bangs CLK (bit 0), DI (bit 1) and /CS
// (bit 2) in one register write and reads DO. Within a write the /CS step is
// applied before the clock step, as MAME's gun_w orders them.

`default_nettype none

module adc0834 (
	input  wire       clk,
	input  wire       reset,
	input  wire       cs_n,      // bit 2 of the gun register
	input  wire       sclk,      // bit 0
	input  wire       di,        // bit 1
	output logic      dout,      // bit 0 of the read
	input  wire [7:0] ch0, ch1, ch2, ch3
);

	typedef enum logic [2:0] {
		S_IDLE, S_WAIT_START, S_SHIFT_MUX, S_MUX_SETTLE,
		S_OUT_MSB, S_WAIT_SE, S_OUT_LSB, S_FINISHED
	} state_t;

	state_t     state,   state_n;
	logic       cs_q, sclk_q;
	logic       sgl, odd, sel1,  sgl_n, odd_n, sel1_n;
	logic [1:0] mux_bit, mux_bit_n;
	logic [2:0] bit_n,   bit_nn;
	logic [7:0] result,  result_n;
	logic       do_n;

	wire cs_fall  = cs_q  & ~cs_n;
	wire cs_rise  = ~cs_q &  cs_n;
	wire clk_rise = ~sclk_q &  sclk;
	wire clk_fall =  sclk_q & ~sclk;

	// conversion(): single-ended ch[ODD + 2*SEL1]; differential minus its
	// neighbour, clamped at 0.
	wire [1:0] pos_ch = {sel1, odd};
	wire [7:0] chv [0:3];
	assign chv[0] = ch0; assign chv[1] = ch1; assign chv[2] = ch2; assign chv[3] = ch3;
	wire [7:0] pos = chv[pos_ch];
	wire [7:0] neg = chv[pos_ch ^ 2'b01];
	wire [8:0] diff = {1'b0, pos} - {1'b0, neg};
	wire [7:0] conv = sgl ? pos : (diff[8] ? 8'd0 : diff[7:0]);

	always_comb begin
		state_n = state; do_n = dout;
		sgl_n = sgl; odd_n = odd; sel1_n = sel1;
		mux_bit_n = mux_bit; bit_nn = bit_n; result_n = result;

		// cs_write
		if (cs_rise) begin state_n = S_IDLE;       do_n = 1'b1; end
		if (cs_fall) begin state_n = S_WAIT_START; do_n = 1'b1; end

		// clk_write, against the state cs_write left
		if (!cs_n) begin
			if (clk_rise) begin
				case (state_n)
					S_WAIT_START: if (di) begin
						state_n = S_SHIFT_MUX; mux_bit_n = 2'd0;
						sgl_n = 1'b0; odd_n = 1'b0; sel1_n = 1'b0;
					end
					S_SHIFT_MUX: begin
						case (mux_bit)
							2'd0: sgl_n  = di;
							2'd1: odd_n  = di;
							2'd2: sel1_n = di;
							default: ;
						endcase
						mux_bit_n = mux_bit + 2'd1;
						if (mux_bit == 2'd2) state_n = S_MUX_SETTLE;
					end
					S_WAIT_SE: begin
						state_n = S_OUT_LSB; bit_nn = 3'd1;
					end
					default: ;
				endcase
			end
			if (clk_fall) begin
				case (state_n)
					S_MUX_SETTLE: begin
						result_n = conv; state_n = S_OUT_MSB; bit_nn = 3'd7; do_n = 1'b0;
					end
					S_OUT_MSB: begin
						do_n = result[bit_n];
						bit_nn = bit_n - 3'd1;
						if (bit_n == 3'd0) state_n = S_WAIT_SE;
					end
					S_OUT_LSB: begin
						do_n = result[bit_n];
						bit_nn = bit_n + 3'd1;
						if (bit_n == 3'd7) state_n = S_FINISHED;
					end
					S_FINISHED: begin
						state_n = S_IDLE; do_n = 1'b0;
					end
					default: ;
				endcase
			end
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE; dout <= 1'b1; cs_q <= 1'b1; sclk_q <= 1'b0;
			sgl <= 1'b0; odd <= 1'b0; sel1 <= 1'b0;
			mux_bit <= 2'd0; bit_n <= 3'd0; result <= 8'd0;
		end else begin
			cs_q <= cs_n; sclk_q <= sclk;
			state <= state_n; dout <= do_n;
			sgl <= sgl_n; odd <= odd_n; sel1 <= sel1_n;
			mux_bit <= mux_bit_n; bit_n <= bit_nn; result <= result_n;
		end
	end

endmodule

`default_nettype wire
