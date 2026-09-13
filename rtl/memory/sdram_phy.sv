// One sdram.sv port behind a req/valid/busy client interface. Reads return
// an 8-byte granule (addr aligned to 8); writes are one byte (lane from
// addr[0]) or, with we16, both lanes of the word at an even addr.

module sdram_phy (
	input  logic clk,
	input  logic reset,

	output logic [25:1] port_addr,
	output logic         port_wrl,
	output logic         port_wrh,
	output logic [15:0] port_din,
	input  logic [63:0] port_dout,
	output logic         port_req,
	input  logic         port_ack,

	input  logic         req,      // pulse: start a transaction (only while !busy)
	input  logic         we,       // 0 = 8-byte-granule burst read, 1 = write
	input  logic         we16,     // write both lanes from wdata[15:0]
	input  logic [25:0] addr,     // byte offset
	input  logic [15:0] wdata,
	output logic         busy,     // 1 while a transaction is in flight
	output logic         valid,    // 1-cycle pulse: rdata holds the requested granule (read only)
	output logic [63:0] rdata
);

	typedef enum logic {S_IDLE, S_WAIT} state_t;
	state_t state;

	logic req_toggle;

	assign port_req = req_toggle;
	assign busy      = (state != S_IDLE);
	assign rdata      = port_dout;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state      <= S_IDLE;
			req_toggle <= 1'b0;
			valid      <= 1'b0;
		end else begin
			valid <= 1'b0;
			case (state)
				S_IDLE: begin
					if (req) begin
						port_addr  <= addr[25:1];
						port_wrl   <= we && (we16 || !addr[0]);
						port_wrh   <= we && (we16 ||  addr[0]);
						port_din   <= we16 ? wdata : {wdata[7:0], wdata[7:0]};
						req_toggle <= ~req_toggle;
						state      <= S_WAIT;
					end
				end

				S_WAIT: begin
					if (port_ack == req_toggle) begin
						if (!we) valid <= 1'b1;
						state <= S_IDLE;
					end
				end

				default: ;
			endcase
		end
	end

endmodule
