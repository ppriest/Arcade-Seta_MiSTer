// thunderl's protection register — eight bits computed from a write ADDRESS.
//
// This is the only active protection anywhere in this project's scope, and it
// is four lines of combinational logic. From seta.cpp:
//
//     void thunderl_state::thunderl_protection_w(offs_t offset, u16 data)
//     {
//         // data byte written here is not used
//         const u32 addr = offset * 2;
//         m_thunderl_protection_reg = ...
//     }
//
// THE DATA IS DISCARDED. Only the address matters, and the driver says so in
// its own comment. A write anywhere in 0x400000-0x41ffff latches a value
// derived from that address's bits; a read at 0xb0000c returns it. The game
// writes to a chosen address and checks it gets the expected byte back.
//
// The expression is transcribed bit for bit rather than simplified. Three of
// the eight bits are functions of others -- bit 7 is bit 6 ANDed with bit 3,
// bit 6 is bit 5 ORed with ~A16 -- and folding them by hand is exactly the
// kind of tidy-up that produces a register that is right for the addresses you
// tried and wrong for the one the game uses.
//
// `addr` is the BYTE offset from the base of the write window, which is what
// `offset * 2` means for a handler mapped at 0x400000: MAME's offset is a WORD
// index from the start of the mapped range.

`default_nettype none

module seta_prot_thunderl (
	input  wire        clk,
	input  wire        reset,

	input  wire        wr,          // a write anywhere in the protection window
	input  wire [16:0] addr,        // byte offset within it

	output logic [7:0] value
);

	wire a2  = addr[2];
	wire a3  = addr[3];
	wire a6  = addr[6];
	wire a8  = addr[8];
	wire a11 = addr[11];
	wire a13 = addr[13];
	wire a15 = addr[15];
	wire a16 = addr[16];

	wire b2 =  a2 | ~a6;
	wire b3 =  a2 | ~a6 | ~a8;
	wire b5 =  a6 &  a13;
	wire b6 =  b5 | ~a16;

	always_ff @(posedge clk) begin
		if (reset) value <= 8'h00;
		else if (wr) value <= { b6 & b3,              // 7
		                        b6,                   // 6
		                        b5,                   // 5
		                        a3 & ~a11 & a15,      // 4
		                        b3,                   // 3
		                        b2,                   // 2
		                        a2 & ~a3,             // 1
		                        a2 };                 // 0
	end

endmodule

`default_nettype wire
