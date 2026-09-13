// Fast ROM load: the .mra's address="0x30000000" has the HPS put the ROM in
// DDR3 (a download with no ioctl_wr); this copies it into SDRAM with the core
// in reset, one 8-byte granule to four 16-bit words. The caller applies the
// same sprite-region transform as the byte path (swizzle, oisipuzl's
// inversion) between raw_* and xf_*.
//
// From Arcade-Fuuki_MiSTer (562c3de), via Arcade-Psikyo_MiSTer; the transform
// stage is Seta's.
module rom_loader (
	input  logic clk,
	input  logic reset,

	input  logic [27:0] length,   // bytes to copy

	input  logic         start,   // pulse: begin the copy
	output logic         busy,    // 1 while copying; hold the core in reset

	// ddram_phy: byte offset from 0x30000000
	output logic         ddr_req,
	output logic [27:0]  ddr_addr,
	input  logic         ddr_busy,
	input  logic         ddr_valid,
	input  logic [63:0]  ddr_rdata,

	// transform: raw_* registered, xf_* the caller's result a cycle later
	output logic [25:0]  raw_addr,
	output logic [15:0]  raw_word,
	input  logic [25:0]  xf_addr,
	input  logic [15:0]  xf_data,

	// SDRAM download port
	output logic         dl_req,
	output logic [25:0]  dl_addr,
	output logic [15:0]  dl_data,
	output logic         dl_we16,
	input  logic         dl_busy
);

	typedef enum logic [3:0] {L_IDLE, L_RD, L_RDWAIT, L_XF0, L_XF1, L_WR, L_WRACK, L_NEXT} lstate_t;
	lstate_t state;

	logic [27:0] byte_addr;    // running offset, granule-aligned
	logic [63:0] gran;
	logic [1:0]  word_idx;     // which 16-bit word of the granule

	assign busy     = (state != L_IDLE);
	assign ddr_req  = (state == L_RD);
	assign ddr_addr = byte_addr;
	assign dl_req   = (state == L_WR);
	assign dl_we16  = 1'b1;     // both byte lanes, one SDRAM transaction per word

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state     <= L_IDLE;
			byte_addr <= 28'd0;
			word_idx  <= 2'd0;
		end else begin
			case (state)
				L_IDLE: if (start) begin
					byte_addr <= 28'd0;
					word_idx  <= 2'd0;
					state     <= L_RD;
				end

				L_RD: if (!ddr_busy) state <= L_RDWAIT;

				L_RDWAIT: if (ddr_valid) begin
					gran     <= ddr_rdata;
					word_idx <= 2'd0;
					state    <= L_XF0;
				end

				// little-endian granule: word k = gran[k*16 +: 16] at byte_addr + 2k
				L_XF0: begin
					raw_addr <= 26'(byte_addr) + {23'd0, word_idx, 1'b0};
					raw_word <= gran[{word_idx, 4'd0} +: 16];
					state    <= L_XF1;
				end
				L_XF1: begin
					dl_addr <= xf_addr;
					dl_data <= xf_data;
					state   <= L_WR;
				end

				L_WR:    if (dl_busy)  state <= L_WRACK;
				L_WRACK: if (!dl_busy) begin
					if (word_idx == 2'd3) state <= L_NEXT;
					else begin
						word_idx <= word_idx + 2'd1;
						state    <= L_XF0;
					end
				end

				L_NEXT: begin
					if (byte_addr + 28'd8 >= length) state <= L_IDLE;
					else begin
						byte_addr <= byte_addr + 28'd8;
						state     <= L_RD;
					end
				end

				default: state <= L_IDLE;
			endcase
		end
	end

endmodule
