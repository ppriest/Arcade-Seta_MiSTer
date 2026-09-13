// N read clients, round-robin, onto one sdram_phy port, plus the ROM download
// write path at absolute priority. Moves 64-bit granules at 8-byte-aligned
// addresses.
//
// A client request is captured on its rising edge, so pulse and held clients
// share the arbiter. c_valid follows phy_valid by one cycle, and rdata is
// latched on phy_valid: sdram.sv's port outputs share one register.

module sdram_arbiter #(
	parameter int N = 4
) (
	input  logic clk,
	input  logic reset,

	output logic         phy_req,
	output logic         phy_we,
	output logic         phy_we16,
	output logic [25:0]  phy_addr,
	output logic [15:0]  phy_wdata,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [63:0]  phy_rdata,

	input  logic [N-1:0]      c_req,
	input  logic [26*N-1:0]   c_addr,
	output logic [N-1:0]      c_valid,
	output logic [63:0]       c_rdata,     // shared; capture it on your own valid

	// download write path
	input  logic         dl_req,
	input  logic [25:0]  dl_addr,
	input  logic [15:0]  dl_data,
	input  logic         dl_we16,
	output logic         dl_busy
);

	typedef enum logic [1:0] {S_IDLE, S_READ, S_WRITE} state_t;
	state_t st;

	logic [$clog2(N)-1:0] rr_ptr;    // round-robin start point
	logic [$clog2(N)-1:0] serving;

	// set on c_req's rising edge, cleared when served
	logic [N-1:0] pend, c_req_d;

	logic       have_pick;
	logic [$clog2(N)-1:0] pick;

	always_comb begin
		have_pick = 1'b0;
		pick      = rr_ptr;
		for (int k = 0; k < N; k++) begin
			int unsigned idx;
			idx = (int'(rr_ptr) + k) % N;
			if (!have_pick && pend[idx]) begin
				have_pick = 1'b1;
				pick      = $bits(pick)'(idx);
			end
		end
	end

	logic [25:0] pick_addr;
	always_comb begin
		pick_addr = 26'd0;
		for (int k = 0; k < N; k++)
			if (k == int'(pick)) pick_addr = c_addr[26*k +: 26];
	end

	logic [63:0] rdata_l;
	assign c_rdata = rdata_l;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			st       <= S_IDLE;
			phy_req  <= 1'b0;
			c_valid  <= '0;
			dl_busy  <= 1'b0;
			rr_ptr   <= '0;
			serving  <= '0;
			pend     <= '0;
			c_req_d  <= '0;
		end else begin
			phy_req <= 1'b0;
			c_valid <= '0;

			// in every state, so a request during service is kept
			c_req_d <= c_req;
			pend    <= pend | (c_req & ~c_req_d);

			case (st)
			S_IDLE: begin
				if (!phy_busy) begin
					if (dl_req) begin
						phy_req   <= 1'b1;
						phy_we    <= 1'b1;
						phy_we16  <= dl_we16;
						phy_addr  <= dl_addr;
						phy_wdata <= dl_data;
						dl_busy   <= 1'b1;
						st        <= S_WRITE;
					end else if (have_pick) begin
						phy_req  <= 1'b1;
						phy_we   <= 1'b0;
						phy_we16 <= 1'b0;
						phy_addr <= pick_addr;
						serving  <= pick;
						pend[pick] <= 1'b0;
						st       <= S_READ;
					end
				end
			end

			S_READ: begin
				if (phy_valid) begin
					rdata_l <= phy_rdata;
					c_valid[serving] <= 1'b1;
					rr_ptr <= (int'(serving) == N-1) ? '0
					                                 : $bits(rr_ptr)'(int'(serving) + 1);
					st     <= S_IDLE;
				end
			end

			S_WRITE: begin
				if (!phy_busy) begin
					dl_busy <= 1'b0;
					st      <= S_IDLE;
				end
			end

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule
