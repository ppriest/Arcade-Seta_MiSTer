// N-way round-robin arbiter onto one sdram_phy port, plus an absolute-priority
// write path for the ROM download.
//
// One parameterised module rather than the several near-identical copies this
// design would otherwise grow: the read clients differ only in count.
//
// ---------------------------------------------------------------------------
// EVERY CLIENT IS ON A HOLD-UNTIL-ACKNOWLEDGED CONTRACT.
//
// `c_req[i]` must stay asserted until `c_valid[i]` pulses. A one-shot pulse
// arriving while the arbiter is servicing someone else is silently LOST -- the
// scan simply never sees it, and the client waits forever for a response to a
// request that was never made. This bit Psikyo across `ddram_arbiter`,
// `sdram_arbiter5` and the HPS download path, which is why `hps_io`'s genuinely
// one-shot `ioctl_wr` gets `sdram_download.sv` as a converter rather than being
// wired straight in (LESSONS_LEARNED, "Hold every request until acknowledged").
//
// The corollary matters as much: a client with a DEDICATED port still needs a
// shim, because `sdram_phy` returns to idle on the valid cycle itself and will
// re-sample a still-high request as a second transaction. Arbitrated clients
// get a cycle of margin for free; a direct connection does not, and the symptom
// is stale data rather than a hang (LESSONS_LEARNED, "Treat any direct,
// non-arbitrated connection to a req/valid transport as suspect"). Use
// N_CLIENTS = 1 here rather than wiring a lone client to the phy.
// ---------------------------------------------------------------------------
//
// The download write path takes absolute priority over every read. That costs
// nothing at runtime because it is only active while ROM is loading, before
// anything is being drawn -- the same reasoning Psikyo's arbiters record.
//
// This module knows nothing about regions or widths. It moves 64-bit granules
// at 8-byte-aligned addresses, which is exactly what `sdram_phy` provides;
// clients narrower than that sit behind `sdram_narrow_bridge`.

module sdram_arbiter #(
	parameter int N = 4
) (
	input  logic clk,
	input  logic reset,

	// ---- physical port (to sdram_phy) ----
	output logic         phy_req,
	output logic         phy_we,
	output logic         phy_we16,
	output logic [25:0]  phy_addr,
	output logic [15:0]  phy_wdata,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [63:0]  phy_rdata,

	// ---- read clients, packed ----
	// c_req is a LEVEL held until the matching c_valid pulses.
	input  logic [N-1:0]      c_req,
	input  logic [26*N-1:0]   c_addr,
	output logic [N-1:0]      c_valid,
	output logic [63:0]       c_rdata,     // shared; capture it on your own valid

	// ---- download write path, absolute priority ----
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

	// Pick the next requesting client at or after rr_ptr, wrapping.
	//
	// The width here is deliberate: Psikyo's 6-client arbiter used a 3-bit
	// counter to scan 6 clients and the wrap arithmetic overflowed, so one
	// client was never reached from one particular rr_ptr value. It presented
	// as a solo-requester deadlock -- the hardest kind to spot, because it only
	// happens when exactly that client asks from exactly that pointer. Using
	// an integer loop over N avoids hand-rolling the wrap at all.
	// Pending requests: set by a RISING EDGE on c_req, cleared when served.
	// This is what lets pulse clients and level clients share one arbiter.
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
				pick      = ($clog2(N))'(idx);
			end
		end
	end

	// Address slice for the chosen client.
	logic [25:0] pick_addr;
	always_comb begin
		pick_addr = 26'd0;
		for (int k = 0; k < N; k++)
			if (k == int'(pick)) pick_addr = c_addr[26*k +: 26];
	end

	// LATCH THE DATA ON phy_valid. Nothing in the path from sdram.sv's dout to
	// here registers it, and `dout0`/`dout1`/`dout2` are literally the SAME
	// register inside the controller -- so a consumer that samples even one
	// cycle after its own valid reads whatever another port has in flight.
	//
	// c_valid is registered and therefore asserts one cycle AFTER phy_valid,
	// which is deliberate (it is the margin that stops a held request being
	// re-sampled). Passing rdata combinationally alongside it means the data
	// and the valid describe different cycles. The symptom is not a hang: the
	// first access to each new granule quietly returns the PREVIOUS granule,
	// which stays invisible everywhere consecutive granules happen to hold the
	// same bytes -- here it hid in 62 of 64 words of a vector table full of
	// 0xFFFF. LESSONS_LEARNED, "Capture read data on the valid pulse".
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

			// Edge capture, in EVERY state -- a request arriving mid-service
			// must still be recorded, which is the whole point of doing it here
			// rather than in the idle branch.
			c_req_d <= c_req;
			pend    <= pend | (c_req & ~c_req_d);

			case (st)
			S_IDLE: begin
				if (!phy_busy) begin
					if (dl_req) begin
						// Download wins outright. Only live during loading.
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
					// The client's valid asserts one cycle before this state
					// machine returns to idle, which is the margin that keeps
					// a still-high held request from being re-sampled as a
					// second transaction.
					c_valid[serving] <= 1'b1;
					rr_ptr <= (int'(serving) == N-1) ? '0
					                                 : ($clog2(N))'(int'(serving) + 1);
					st     <= S_IDLE;
				end
			end

			S_WRITE: begin
				// Writes have no valid; the phy drops busy when done.
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
