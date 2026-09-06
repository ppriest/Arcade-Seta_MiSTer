// pairlove's 0x900000 block — a one-deep write history, not an algorithm.
//
// seta.cpp calls it protection and the handlers are four lines:
//
//     u16 prot_r(offs_t offset)          void prot_w(offs_t offset, u16 data)
//     {                                  {
//         u16 ret = m_protram[offset];       m_protram_old[offset] =
//         m_protram[offset] =                    m_protram[offset];
//             m_protram_old[offset];         m_protram[offset] = data;
//         return ret;                    }
//     }
//
// So a READ HAS A SIDE EFFECT: it returns the current value and then reverts
// that cell to the previous one written. Two RAMs of 0x200 words and no
// arithmetic anywhere -- which is worth saying, because "protection" in a
// driver usually means an MCU or a challenge/response and this is the whole of
// it. It is also the ONLY protection in this project's scope apart from
// thunderl's four-instruction register.
//
// TIMING. maincpu.sv asserts io_req for one cycle in S_MEM and captures
// io_rdata two cycles later in S_MEM3. With the input register below, the
// array is addressed in the second cycle and its output is back for the third
// -- exactly in time, with the write-back following behind it. The side effect
// fires on a READ ONLY, gated on `req && !we` rather than on `req` alone,
// because a write must not also revert the cell it just wrote.

`default_nettype none

module seta_prot_pairlove (
	input  wire        clk,

	input  wire        req,
	input  wire        we,
	input  wire  [8:0] addr,      // word address into 0x200 words
	input  wire [15:0] wdata,
	input  wire        uds, lds,
	output logic [15:0] rdata
);

	logic [15:0] cur [0:511];
	logic [15:0] old [0:511];

	// AN INPUT REGISTER STAGE FIRST. On the first whole-core build the critical
	// path ran from the TG68K register file straight into this module's RAM
	// data input -- the CPU's slowest register output in series with an address
	// decode and an array setup. That is the shape Phase 0 already fixed once,
	// on the X1-010, and it reappeared here because this module was written
	// after that lesson and did not apply it.
	logic        i_req, i_we, i_uds, i_lds;
	logic  [8:0] i_addr;
	logic [15:0] i_wdata;

	always_ff @(posedge clk) begin
		i_req <= req; i_we <= we; i_addr <= addr;
		i_wdata <= wdata; i_uds <= uds; i_lds <= lds;
	end

	logic       s1_req, s1_we;
	logic [8:0] s1_addr;
	logic [15:0] cur_q, old_q;

	always_ff @(posedge clk) begin
		s1_req  <= i_req;
		s1_we   <= i_we;
		s1_addr <= i_addr;

		// Stage 1: the write, and the reads that stage 2 needs.
		if (i_req && i_we) begin
			// prot_w saves the current value first, then overwrites it. Byte
			// lanes are honoured because the CPU is a 68000 and a byte write
			// to a 16-bit device must not disturb the other half; seta.cpp's
			// handler is declared u16 and MAME's word handler would write
			// both, but that is MAME's shortcut, not the board's.
			old[i_addr] <= cur[i_addr];
			if (i_lds) cur[i_addr][7:0]  <= i_wdata[7:0];
			if (i_uds) cur[i_addr][15:8] <= i_wdata[15:8];
		end
		cur_q <= cur[i_addr];
		old_q <= old[i_addr];

		// Stage 2: present the value, and revert the cell behind it. A write
		// must not do this, or it would undo itself.
		if (s1_req && !s1_we) cur[s1_addr] <= old_q;
	end

	assign rdata = cur_q;

endmodule

`default_nettype wire
