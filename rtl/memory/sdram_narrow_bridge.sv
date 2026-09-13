// A byte- or word-wide read client on a 64-bit-granule arbiter port. Fetches
// the containing granule and keeps it: a request inside the cached granule is
// answered the next cycle without an SDRAM transaction. `inval` flushes the
// cache (held during the ROM download).
//
// Word i of a granule is g_data[16*i +: 16]; in a word the even byte address
// is the low byte. Clients pulse req and hold addr until valid.

module sdram_narrow_bridge #(
	parameter int WORD_BYTES = 2   // 1 = byte client, 2 = word client
) (
	input  logic clk,
	input  logic reset,

	input  logic inval,

	input  logic                     req,
	input  logic [25:0]              addr,    // byte address of the desired unit
	output logic                     valid,
	output logic [8*WORD_BYTES-1:0] data,

	output logic         g_req,
	output logic [25:0] g_addr,
	input  logic         g_valid,
	input  logic [63:0] g_data
);

	typedef enum logic [1:0] {B_IDLE, B_WAIT, B_HIT, B_DRAIN} bstate_t;
	bstate_t bstate;

	logic [1:0] word_sel;
	logic         byte_sel;

	logic [63:0] cache_data;
	logic [22:0] cache_tag;      // granule address, addr[25:3]
	logic         cache_valid;
	logic [22:0] tag_inflight;   // granule being fetched

	wire hit = cache_valid && (addr[25:3] == cache_tag);

	assign g_addr = {addr[25:3], 3'b000};
	assign g_req  = (bstate == B_WAIT);

	logic [15:0] sel_word;
	assign sel_word = (bstate == B_HIT) ? cache_data[16*word_sel +: 16]
										  : g_data[16*word_sel +: 16];

	generate
		if (WORD_BYTES == 1) begin : g_byte
			assign data = byte_sel ? sel_word[15:8] : sel_word[7:0];
		end else begin : g_word
			assign data = sel_word;
		end
	endgenerate

	assign valid = ((bstate == B_WAIT) && g_valid) || (bstate == B_HIT);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			bstate       <= B_IDLE;
			cache_valid <= 1'b0;
		end else begin
			if (inval) cache_valid <= 1'b0;

			case (bstate)
				B_IDLE: begin
					if (req) begin
						word_sel <= addr[2:1];
						byte_sel <= addr[0];
						// loaded on hits too: keeps `hit` off the enable (timing)
						tag_inflight <= addr[25:3];
						bstate <= (hit && !inval) ? B_HIT : B_WAIT;
					end
				end
				B_WAIT: begin
					if (g_valid) begin
						if (!inval) begin
							cache_data  <= g_data;
							cache_tag   <= tag_inflight;
							cache_valid <= 1'b1;
						end
						bstate <= B_IDLE;
					end
				end
				B_HIT: begin
					// valid pulses now; B_DRAIN waits for a held req to drop
					bstate <= B_DRAIN;
				end
				B_DRAIN: begin
					if (!req) bstate <= B_IDLE;
				end
				default: bstate <= B_IDLE;
			endcase
		end
	end

endmodule
