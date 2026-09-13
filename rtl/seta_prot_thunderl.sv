// thunderl_protection_w: a write anywhere in 0x400000-0x41ffff latches eight
// bits derived from the write ADDRESS (the data is ignored); 0xb0000c reads
// them back. Transcribed bit for bit from seta.cpp.

`default_nettype none

module seta_prot_thunderl (
	input  wire        clk,
	input  wire        reset,

	input  wire        wr,          // write anywhere in the window
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
