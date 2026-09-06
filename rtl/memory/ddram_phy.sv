// Single-port wrapper around MiSTer's real DDRAM_* interface.
//
// Vendored from Arcade-Psikyo_MiSTer, where the protocol was verified against
// a working reference (MiSTer-devel/TSConf_MiSTer's ddram.sv) rather than
// derived from the documentation alone. Unchanged except for this header.
//
// Presents a req/valid client interface, matching this project's convention
// for latency-agnostic external memory ports: one transaction in flight at a
// time, no arbitration of its own.
//
//   READ:  8-byte-aligned granule in, full 64-bit DDRAM_DOUT out (`addr`'s
//          low 3 bits are ignored).
//   WRITE: single BYTE in (`wdata`), `addr` selects the lane via DDRAM_BE.
//
// DDRAM_BURSTCNT is always 1 -- no multi-beat bursting. Here the only client
// is the ROM loader, whose copy is bounded by DDR3 latency per granule; wider
// bursts are the obvious throughput improvement if the copy ever needs one.

module ddram_phy (
	input  logic clk,
	input  logic reset,

	// physical DDRAM interface (sys/emu_ports.vh) -- DDRAM_CLK is driven
	// separately at the top level (assign DDRAM_CLK = clk;), not by this
	// module, matching the reference's own convention.
	input  logic         DDRAM_BUSY,
	output logic [7:0]  DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	input  logic [63:0] DDRAM_DOUT,
	input  logic         DDRAM_DOUT_READY,
	output logic         DDRAM_RD,
	output logic [63:0] DDRAM_DIN,
	output logic [7:0]  DDRAM_BE,
	output logic         DDRAM_WE,

	// client interface
	input  logic         req,      // pulse: start a transaction (only while !busy)
	input  logic         we,       // 0 = 8-byte-granule read, 1 = single-byte write
	input  logic [27:0] addr,     // byte offset from the 0x30000000 HPS extra-RAM base
	input  logic [7:0]  wdata,    // byte to write (we=1 only)
	output logic         busy,     // 1 while a transaction is in flight
	output logic         valid,    // 1-cycle pulse: rdata holds the requested granule (read only)
	output logic [63:0] rdata
);

	typedef enum logic [1:0] {S_IDLE, S_WAIT_READ, S_WAIT_WRITE} state_t;
	state_t state;

	logic [27:0] addr_r;
	logic         we_r;
	logic [7:0]  wdata_r;

	assign DDRAM_BURSTCNT = 8'd1;
	assign DDRAM_ADDR     = {4'b0011, addr_r[27:3]};
	assign DDRAM_BE       = we_r ? (8'd1 << addr_r[2:0]) : 8'hFF;
	assign DDRAM_DIN      = {8{wdata_r}};   // byte replicated across all 8 lanes; BE selects the real one

	logic read_issued, write_issued;

	assign DDRAM_RD = (state == S_WAIT_READ)  && !read_issued  && !DDRAM_BUSY;
	assign DDRAM_WE = (state == S_WAIT_WRITE) && !write_issued && !DDRAM_BUSY;

	assign busy  = (state != S_IDLE);
	assign valid = (state == S_WAIT_READ) && DDRAM_DOUT_READY;
	assign rdata = DDRAM_DOUT;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state        <= S_IDLE;
			read_issued  <= 1'b0;
			write_issued <= 1'b0;
		end else begin
			case (state)
				S_IDLE: begin
					if (req && !DDRAM_BUSY) begin
						addr_r       <= addr;
						we_r         <= we;
						wdata_r      <= wdata;
						read_issued  <= 1'b0;
						write_issued <= 1'b0;
						state        <= we ? S_WAIT_WRITE : S_WAIT_READ;
					end
				end

				S_WAIT_READ: begin
					if (!DDRAM_BUSY) read_issued <= 1'b1;   // RD pulsed this cycle -> don't repeat it
					if (DDRAM_DOUT_READY) state <= S_IDLE;
				end

				S_WAIT_WRITE: begin
					if (!DDRAM_BUSY) begin
						if (write_issued) state <= S_IDLE;   // WE was pulsed last cycle, and the
															  // controller has dropped busy again
						else              write_issued <= 1'b1;
					end
				end
			endcase
		end
	end

endmodule
