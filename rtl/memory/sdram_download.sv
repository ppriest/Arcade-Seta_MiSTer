// hps_io ROM download (index 0) to the SDRAM arbiter's download port. An even
// byte is held; its odd partner writes both lanes in one transaction. A held
// byte without a partner (non-sequential address, end of download) is written
// alone. ioctl_wait covers only real transactions.

module sdram_download (
	input  logic clk,
	input  logic reset,

	input  logic         ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic         ioctl_wr,
	input  logic [26:0] ioctl_addr,   // hps_io's width; bit 26 unused
	input  logic [7:0]  ioctl_dout,
	output logic         ioctl_wait,

	output logic         dl_req,
	output logic [25:0] dl_addr,
	output logic [15:0] dl_data,
	output logic         dl_we16,
	input  logic         dl_busy
);

	typedef enum logic [1:0] {D_IDLE, D_REQ, D_WAIT} dstate_t;
	dstate_t dstate;

	logic [25:0] addr_r;
	logic [15:0] data_r;
	logic        we16_r;

	// held even byte
	logic        pend_valid;
	logic [25:0] pend_addr;
	logic [7:0]  pend_data;

	wire         accept = ioctl_download && (ioctl_index == 16'd0) && ioctl_wr;
	wire         pairs  = pend_valid && !pend_addr[0] && ioctl_addr[0]
	                     && (ioctl_addr[25:1] == pend_addr[25:1]);

	assign dl_addr = addr_r;
	assign dl_data = data_r;
	assign dl_we16 = we16_r;
	assign dl_req  = (dstate == D_REQ);
	assign ioctl_wait = (dstate != D_IDLE);

	logic dl_active_d;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			dstate     <= D_IDLE;
			pend_valid <= 1'b0;
			we16_r     <= 1'b0;
			dl_active_d <= 1'b0;
		end else begin
			dl_active_d <= ioctl_download;

			case (dstate)
				D_IDLE: begin
					if (accept) begin
						if (pairs) begin
							addr_r     <= pend_addr;
							data_r     <= {ioctl_dout, pend_data};
							we16_r     <= 1'b1;   // both lanes, one transaction
							pend_valid <= 1'b0;
							dstate     <= D_REQ;
						end else if (pend_valid) begin
							// no pair: write the held byte alone, hold the new one
							addr_r     <= pend_addr;
							data_r     <= {8'd0, pend_data};
							we16_r     <= 1'b0;
							pend_addr  <= ioctl_addr;
							pend_data  <= ioctl_dout;
							dstate     <= D_REQ;
						end else begin
							pend_addr  <= ioctl_addr;
							pend_data  <= ioctl_dout;
							pend_valid <= 1'b1;
						end
					end else if (pend_valid && dl_active_d && !ioctl_download) begin
						// download ended with a byte still held
						addr_r     <= pend_addr;
						data_r     <= {8'd0, pend_data};
						we16_r     <= 1'b0;
						pend_valid <= 1'b0;
						dstate     <= D_REQ;
					end
				end

				D_REQ: begin
					if (dl_busy) dstate <= D_WAIT;
				end

				D_WAIT: begin
					if (!dl_busy) dstate <= D_IDLE;
				end
			endcase
		end
	end

endmodule
