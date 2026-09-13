// pairlove's 0x900000 block (seta.cpp prot_r/prot_w): a write saves the
// cell's value and stores the new one; a read returns the value and then
// reverts the cell to the saved one. 0x200 words.
//
// Input register, then the array, then the write-back: the read is ready in
// maincpu's third io cycle.

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

		if (i_req && i_we) begin
			old[i_addr] <= cur[i_addr];
			if (i_lds) cur[i_addr][7:0]  <= i_wdata[7:0];
			if (i_uds) cur[i_addr][15:8] <= i_wdata[15:8];
		end
		cur_q <= cur[i_addr];
		old_q <= old[i_addr];

		// revert after a read only
		if (s1_req && !s1_we) cur[s1_addr] <= old_q;
	end

	assign rdata = cur_q;

endmodule

`default_nettype wire
