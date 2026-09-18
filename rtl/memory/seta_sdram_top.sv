// SDRAM: every ROM the core reads at runtime, on one chip through sdram.sv's
// three fixed-priority ports (port 0 preempts 1, 1 preempts 2):
//   port 0  sprite and tile graphics   (arbiter, 3 clients)
//   port 1  X1-010 samples             (byte bridge), and with SUB the
//           downtown.cpp 65C02's ROM     (a second byte bridge)
//   port 2  CPU program, ROM download   (word bridge + download)
//
// Address map, per layout (bases below; scripts/build_mra.py reads the
// localparams, so every .mra loads to these offsets):
//   A  maincpu 0, gfx1 1M (2 MB), x1snd 3M
//   B  maincpu 0, gfx1 1M (1 MB), gfx2 2M, x1snd 4M
//   C  maincpu 0, gfx1 2M (4 MB), gfx2 6M, gfx3 8M, x1snd 10M
//   D  gfx1 2M, gfx2 4M (4 MB), gfx3 8M, x1snd 10M      6bpp sets
//   E  gfx1 2M (8 MB), gfx2 10M, gfx3 12M, x1snd 16M    gundhara
//   F  gfx1 2M, gfx2 4M, gfx3 7M, x1snd 10M (4 MB)      zombraid
//   G  maincpu 0, gfx1 1M (2 MB), gfx2 3M, x1snd 5M, sub 6M  downtown.cpp
//
// On the way in, the sprite region's word addresses are permuted
// (gfx_swizzle.sv) and, for ROMREGION_INVERT, its bytes inverted.

`default_nettype none

module seta_sdram_top #(
	parameter bit SUB = 1'b0
) (
	input  wire clk,

	// reset & ~ioctl_download: MiSTer holds reset for the whole download
	input  wire reset,

	// ~pll_locked; SDRAM initialisation only
	input  wire init,

	output wire [12:0] SDRAM_A,
	inout  wire [15:0] SDRAM_DQ,
	output wire        SDRAM_DQML,
	output wire        SDRAM_DQMH,
	output wire  [1:0] SDRAM_BA,
	output wire        SDRAM_nCS,
	output wire        SDRAM_nWE,
	output wire        SDRAM_nRAS,
	output wire        SDRAM_nCAS,
	output wire        SDRAM_CKE,
	output wire        SDRAM_CLK,

	input  wire        ioctl_download,
	input  wire [15:0] ioctl_index,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire  [7:0] ioctl_dout,
	output wire        ioctl_wait,

	// words in one RGN_FRAC half of gfx1 (region bytes / 4), per game
	input  wire [22:0] gfx_half_words,

	input  wire        cpu_req,
	input  wire [23:1] cpu_addr,      // word address within "maincpu"
	output wire        cpu_valid,
	output wire [15:0] cpu_data,

	// 0..5 = LAYOUT_A..F
	input  wire  [2:0] layout,
	// ROMREGION_INVERT on gfx1
	input  wire        gfx1_invert,

	input  wire        spr_req,
	input  wire [23:3] spr_addr,      // granule address within "gfx1"
	output wire        spr_valid,
	output wire [63:0] spr_data,

	// tile graphics, layer 0
	input  wire        tile_req,
	input  wire [23:3] tile_addr,     // granule address within "gfx2"
	output wire        tile_valid,
	output wire [63:0] tile_data,

	// layer 1
	input  wire        tile1_req,
	input  wire [23:3] tile1_addr,    // granule address within "gfx3"
	output wire        tile1_valid,
	output wire [63:0] tile1_data,

	input  wire        snd_req,
	// 22 bits: up to 4 MB through the X1-010 bank
	input  wire [21:0] snd_addr,      // byte address within "x1snd"
	output wire        snd_valid,
	output wire  [7:0] snd_data,

	// downtown.cpp "sub" region, byte address (SUB)
	input  wire        sub_req,
	input  wire [18:0] sub_addr,
	output wire        sub_valid,
	output wire  [7:0] sub_data,

	// fast ROM load (rom_loader.sv); Seta.sv starts it
	input  wire        ldr_start,
	output wire        ldr_active,      // copying: Seta.sv holds the core in reset
	output wire        ldr_ddr_req,
	output wire [27:0] ldr_ddr_addr,
	input  wire        ldr_ddr_busy,
	input  wire        ldr_ddr_valid,
	input  wire [63:0] ldr_ddr_rdata
);

	localparam logic [25:0] BASE_MAINCPU   = 26'h000_0000;
	localparam logic [25:0] BASE_GFX1_AB   = 26'h010_0000;   // 2 MB in A, 1 MB in B
	localparam logic [25:0] BASE_GFX1_C    = 26'h020_0000;   // 4 MB
	localparam logic [25:0] BASE_GFX2_B    = 26'h020_0000;   // 2 MB
	localparam logic [25:0] BASE_GFX2_C    = 26'h060_0000;   // 2 MB
	localparam logic [25:0] BASE_GFX3_C    = 26'h080_0000;   // 2 MB
	localparam logic [25:0] BASE_X1SND_C   = 26'h0a0_0000;

	// LAYOUT_D: zingzip, extdwnhl, sokonuke, jjsquawk, madshark
	localparam logic [25:0] BASE_GFX1_D    = 26'h020_0000;   // 2 MB
	localparam logic [25:0] BASE_GFX2_D    = 26'h040_0000;   // 4 MB
	localparam logic [25:0] BASE_GFX3_D    = 26'h080_0000;   // 2 MB
	localparam logic [25:0] BASE_X1SND_D   = 26'h0a0_0000;   // 1 MB

	// LAYOUT_E: gundhara
	localparam logic [25:0] BASE_GFX1_E    = 26'h020_0000;   // 8 MB
	localparam logic [25:0] BASE_GFX2_E    = 26'h0a0_0000;   // 2 MB
	localparam logic [25:0] BASE_GFX3_E    = 26'h0c0_0000;   // 4 MB
	localparam logic [25:0] BASE_X1SND_E   = 26'h100_0000;   // 1 MB

	// LAYOUT_F: zombraid
	localparam logic [25:0] BASE_GFX1_F    = 26'h020_0000;   // 2 MB
	localparam logic [25:0] BASE_GFX2_F    = 26'h040_0000;   // 3 MB
	localparam logic [25:0] BASE_GFX3_F    = 26'h070_0000;   // 3 MB
	localparam logic [25:0] BASE_X1SND_F   = 26'h0a0_0000;   // 4 MB

	wire layout_b = (layout == 3'd1);
	wire layout_c = (layout == 3'd2);
	wire layout_d = (layout == 3'd3);
	wire layout_e = (layout == 3'd4);
	wire layout_f = (layout == 3'd5);
	wire layout_g = (layout == 3'd6);

	// LAYOUT_G: downtown.cpp
	localparam logic [25:0] BASE_GFX2_G    = 26'h030_0000;   // 2 MB
	localparam logic [25:0] BASE_X1SND_G   = 26'h050_0000;   // 1 MB
	localparam logic [25:0] BASE_SUB_G     = 26'h060_0000;   // 512 KB

	wire   [25:0] BASE_GFX1 = layout_f ? BASE_GFX1_F :
	                          layout_e ? BASE_GFX1_E :
	                          layout_d ? BASE_GFX1_D :
	                          layout_c ? BASE_GFX1_C : BASE_GFX1_AB;
	wire   [25:0] BASE_GFX2 = layout_g ? BASE_GFX2_G :
	                          layout_f ? BASE_GFX2_F :
	                          layout_e ? BASE_GFX2_E :
	                          layout_d ? BASE_GFX2_D :
	                          layout_c ? BASE_GFX2_C : BASE_GFX2_B;
	// localparams, not wires, so build_mra.py can read them
	localparam logic [25:0] BASE_X1SND_A = 26'h030_0000;
	localparam logic [25:0] BASE_X1SND_B = 26'h040_0000;
	wire   [25:0] BASE_X1SND = layout_g ? BASE_X1SND_G :
	                           layout_f ? BASE_X1SND_F :
	                           layout_e ? BASE_X1SND_E :
	                           layout_d ? BASE_X1SND_D :
	                           layout_c ? BASE_X1SND_C :
	                           layout_b ? BASE_X1SND_B : BASE_X1SND_A;
	wire   [25:0] BASE_GFX3 = layout_f ? BASE_GFX3_F :
	                          layout_e ? BASE_GFX3_E :
	                          layout_d ? BASE_GFX3_D : BASE_GFX3_C;

	wire   [25:0] SIZE_GFX1 = layout_f ? 26'h020_0000 :
	                          layout_e ? 26'h080_0000 :
	                          layout_d ? 26'h020_0000 :
	                          layout_c ? 26'h040_0000 :
	                          layout_b ? 26'h010_0000 : 26'h020_0000;

	// Download: permute the sprite region's word addresses.
	wire in_gfx1 = (ioctl_addr[25:0] >= BASE_GFX1)
	            && (ioctl_addr[25:0] <  BASE_GFX1 + SIZE_GFX1);

	wire [22:0] swz_in  = (ioctl_addr[25:0] - BASE_GFX1) >> 1;
	wire [22:0] swz_out;

	gfx_swizzle #(.AW(23)) u_swz (
		.half_words(gfx_half_words),
		.word_in(swz_in),
		.word_out(swz_out)
	);

	// bit 0 (the byte within the word) is kept, so bytes still pair
	wire [26:0] ioctl_addr_swz_c =
		in_gfx1 ? {1'b0, BASE_GFX1 + {2'd0, swz_out, 1'b0} + {25'd0, ioctl_addr[0]}}
		        : ioctl_addr;

	// Registered (timing), with the index and download flag delayed alongside
	// so accept is judged against the same transfer.
	logic [26:0] ioctl_addr_swz;
	logic        ioctl_wr_q, ioctl_dl_q;
	logic [15:0] ioctl_index_q;
	logic  [7:0] ioctl_dout_q;
	always_ff @(posedge clk) begin
		ioctl_addr_swz <= ioctl_addr_swz_c;
		ioctl_wr_q     <= ioctl_wr;
		ioctl_dl_q     <= ioctl_download;
		ioctl_index_q  <= ioctl_index;
		ioctl_dout_q   <= (gfx1_invert && in_gfx1) ? ~ioctl_dout : ioctl_dout;
	end

	wire        sd_req, sd_we16;
	wire        dl_req, dl_we16, dl_busy;
	// wait also covers the write still in the pipeline register
	wire        dl_ioctl_wait;
	assign ioctl_wait = dl_ioctl_wait | ioctl_wr;
	wire [25:0] dl_addr, sd_addr;
	wire [15:0] dl_data, sd_data;

	sdram_download u_dl (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_dl_q), .ioctl_index(ioctl_index_q),
		.ioctl_wr(ioctl_wr_q), .ioctl_addr(ioctl_addr_swz),
		.ioctl_dout(ioctl_dout_q),
		.ioctl_wait(dl_ioctl_wait),
		.dl_req(sd_req), .dl_addr(sd_addr), .dl_data(sd_data),
		.dl_we16(sd_we16), .dl_busy(dl_busy)
	);

	// Fast ROM load. The copy ends at the top of the layout's last region
	// (x1snd; the sub region in G), where every .mra image for it ends.
	wire [27:0] ldr_length = {2'd0, layout_g ? BASE_SUB_G   + 26'h008_0000 :
	                                layout_f ? BASE_X1SND_F + 26'h040_0000 :
	                                layout_e ? BASE_X1SND_E + 26'h010_0000 :
	                                layout_d ? BASE_X1SND_D + 26'h010_0000 :
	                                layout_c ? BASE_X1SND_C + 26'h020_0000 :
	                                layout_b ? BASE_X1SND_B + 26'h010_0000 :
	                                           BASE_X1SND_A + 26'h010_0000};

	wire [25:0] ldr_raw_addr, ldr_xf_addr;
	wire [15:0] ldr_raw_word, ldr_xf_data;
	wire        ldr_req, ldr_we16;
	wire [25:0] ldr_addr;
	wire [15:0] ldr_data;

	// The byte path's transform, per word: move to BASE_GFX1 + 2*swizzle(word),
	// invert for gfx1_invert. raw_addr is even.
	wire        ldr_in_gfx1 = (ldr_raw_addr >= BASE_GFX1)
	                       && (ldr_raw_addr <  BASE_GFX1 + SIZE_GFX1);
	wire [22:0] ldr_swz_in  = (ldr_raw_addr - BASE_GFX1) >> 1;
	wire [22:0] ldr_swz_out;

	gfx_swizzle #(.AW(23)) u_swz_ldr (
		.half_words(gfx_half_words),
		.word_in(ldr_swz_in),
		.word_out(ldr_swz_out)
	);

	assign ldr_xf_addr = ldr_in_gfx1 ? BASE_GFX1 + {2'd0, ldr_swz_out, 1'b0} : ldr_raw_addr;
	assign ldr_xf_data = (gfx1_invert && ldr_in_gfx1) ? ~ldr_raw_word : ldr_raw_word;

	rom_loader u_ldr (
		.clk(clk), .reset(reset),
		.length(ldr_length),
		.start(ldr_start), .busy(ldr_active),
		.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
		.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
		.raw_addr(ldr_raw_addr), .raw_word(ldr_raw_word),
		.xf_addr(ldr_xf_addr), .xf_data(ldr_xf_data),
		.dl_req(ldr_req), .dl_addr(ldr_addr), .dl_data(ldr_data),
		.dl_we16(ldr_we16), .dl_busy(dl_busy)
	);

	// the byte path and the copy never write at the same time
	assign dl_req  = ldr_active ? ldr_req  : sd_req;
	assign dl_addr = ldr_active ? ldr_addr : sd_addr;
	assign dl_data = ldr_active ? ldr_data : sd_data;
	assign dl_we16 = ldr_active ? ldr_we16 : sd_we16;

	logic [25:1] p_addr [0:2];
	logic        p_wrl  [0:2], p_wrh [0:2], p_req [0:2];
	logic [15:0] p_din  [0:2];
	wire  [63:0] p_dout [0:2];
	wire         p_ack  [0:2];

	sdram u_sdram (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
		.init(init), .clk(clk),
		.addr0(p_addr[0]), .wrl0(p_wrl[0]), .wrh0(p_wrh[0]), .din0(p_din[0]),
		.dout0(p_dout[0]), .req0(p_req[0]), .ack0(p_ack[0]),
		.addr1(p_addr[1]), .wrl1(p_wrl[1]), .wrh1(p_wrh[1]), .din1(p_din[1]),
		.dout1(p_dout[1]), .req1(p_req[1]), .ack1(p_ack[1]),
		.addr2(p_addr[2]), .wrl2(p_wrl[2]), .wrh2(p_wrh[2]), .din2(p_din[2]),
		.dout2(p_dout[2]), .req2(p_req[2]), .ack2(p_ack[2])
	);

	logic        phy_req  [0:2], phy_we [0:2], phy_we16 [0:2];
	logic [25:0] phy_addr [0:2];
	logic [15:0] phy_wdata[0:2];
	wire         phy_busy [0:2], phy_valid[0:2];
	wire  [63:0] phy_rdata[0:2];

	genvar gi;
	generate
		for (gi = 0; gi < 3; gi = gi + 1) begin : g_phy
			sdram_phy u_phy (
				.clk(clk), .reset(reset),
				.port_addr(p_addr[gi]), .port_wrl(p_wrl[gi]), .port_wrh(p_wrh[gi]),
				.port_din(p_din[gi]), .port_dout(p_dout[gi]),
				.port_req(p_req[gi]), .port_ack(p_ack[gi]),
				.req(phy_req[gi]), .we(phy_we[gi]), .we16(phy_we16[gi]),
				.addr(phy_addr[gi]), .wdata(phy_wdata[gi]),
				.busy(phy_busy[gi]), .valid(phy_valid[gi]), .rdata(phy_rdata[gi])
			);
		end
	endgenerate

	// port 0: sprites and tile layers, direct arbiter clients (a row is one
	// granule). Arbiter requests are held until c_valid; the bridges below
	// take pulses.
	logic        spr_req_l;
	always_ff @(posedge clk) begin
		if (reset)          spr_req_l <= 1'b0;
		else if (spr_valid) spr_req_l <= 1'b0;
		else if (spr_req)   spr_req_l <= 1'b1;
	end

	logic tile_req_l = 1'b0;
	always_ff @(posedge clk) begin
		if (reset)               tile_req_l <= 1'b0;
		else if (tile_valid)     tile_req_l <= 1'b0;
		else if (tile_req)       tile_req_l <= 1'b1;
	end

	logic tile1_req_l = 1'b0;
	always_ff @(posedge clk) begin
		if (reset)            tile1_req_l <= 1'b0;
		else if (tile1_valid) tile1_req_l <= 1'b0;
		else if (tile1_req)   tile1_req_l <= 1'b1;
	end

	wire [2:0]  arb0_valid;
	wire [63:0] arb0_rdata;
	assign spr_valid   = arb0_valid[0];
	assign spr_data    = arb0_rdata;
	assign tile_valid  = arb0_valid[1];
	assign tile_data   = arb0_rdata;
	assign tile1_valid = arb0_valid[2];
	assign tile1_data  = arb0_rdata;

	sdram_arbiter #(.N(3)) u_arb0 (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[0]), .phy_we(phy_we[0]), .phy_we16(phy_we16[0]),
		.phy_addr(phy_addr[0]), .phy_wdata(phy_wdata[0]),
		.phy_busy(phy_busy[0]), .phy_valid(phy_valid[0]), .phy_rdata(phy_rdata[0]),
		.c_req({tile1_req_l, tile_req_l, spr_req_l}),
		.c_addr({{2'd0, tile1_addr, 3'd0} + BASE_GFX3,
		         {2'd0, tile_addr,  3'd0} + BASE_GFX2,
		         {2'd0, spr_addr,   3'd0} + BASE_GFX1}),
		.c_valid(arb0_valid), .c_rdata(arb0_rdata),
		.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// port 1: X1-010 samples, byte bridge (sequential reads share a granule)
	wire        snd_g_req;
	wire [25:0] snd_g_addr;
	wire        snd_g_valid;
	wire [63:0] snd_g_data;

	sdram_narrow_bridge #(.WORD_BYTES(1)) u_snd_bridge (
		.clk(clk), .reset(reset),
		.inval(ioctl_download),
		.req(snd_req), .addr({4'd0, snd_addr}),
		.valid(snd_valid), .data(snd_data),
		.g_req(snd_g_req), .g_addr(snd_g_addr),
		.g_valid(snd_g_valid), .g_data(snd_g_data)
	);

	generate
		if (SUB) begin : g_sub
			wire        sub_g_req;
			wire [25:0] sub_g_addr;
			wire  [1:0] arb1_valid;
			wire [63:0] arb1_rdata;

			sdram_narrow_bridge #(.WORD_BYTES(1)) u_sub_bridge (
				.clk(clk), .reset(reset),
				.inval(ioctl_download),
				.req(sub_req), .addr({7'd0, sub_addr}),
				.valid(sub_valid), .data(sub_data),
				.g_req(sub_g_req), .g_addr(sub_g_addr),
				.g_valid(arb1_valid[1]), .g_data(arb1_rdata)
			);

			assign snd_g_valid = arb1_valid[0];
			assign snd_g_data  = arb1_rdata;

			sdram_arbiter #(.N(2)) u_arb1 (
				.clk(clk), .reset(reset),
				.phy_req(phy_req[1]), .phy_we(phy_we[1]), .phy_we16(phy_we16[1]),
				.phy_addr(phy_addr[1]), .phy_wdata(phy_wdata[1]),
				.phy_busy(phy_busy[1]), .phy_valid(phy_valid[1]), .phy_rdata(phy_rdata[1]),
				.c_req({sub_g_req, snd_g_req}),
				.c_addr({sub_g_addr + BASE_SUB_G, snd_g_addr + BASE_X1SND}),
				.c_valid(arb1_valid), .c_rdata(arb1_rdata),
				.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
			);
		end else begin : g_nosub
			assign sub_valid = 1'b0;
			assign sub_data  = 8'h00;

			sdram_arbiter #(.N(1)) u_arb1 (
				.clk(clk), .reset(reset),
				.phy_req(phy_req[1]), .phy_we(phy_we[1]), .phy_we16(phy_we16[1]),
				.phy_addr(phy_addr[1]), .phy_wdata(phy_wdata[1]),
				.phy_busy(phy_busy[1]), .phy_valid(phy_valid[1]), .phy_rdata(phy_rdata[1]),
				.c_req(snd_g_req), .c_addr(snd_g_addr + BASE_X1SND),
				.c_valid(snd_g_valid), .c_rdata(snd_g_data),
				.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
			);
		end
	endgenerate

	// port 2: CPU program and the download
	wire        cpu_g_req;
	wire [25:0] cpu_g_addr;
	wire        cpu_g_valid;
	wire [63:0] cpu_g_data;

	sdram_narrow_bridge #(.WORD_BYTES(2)) u_cpu_bridge (
		.clk(clk), .reset(reset),
		.inval(ioctl_download),
		// 26 bits: 2 + 23 + 1
		.req(cpu_req), .addr({2'b00, cpu_addr, 1'b0}),
		.valid(cpu_valid), .data(cpu_data),
		.g_req(cpu_g_req), .g_addr(cpu_g_addr),
		.g_valid(cpu_g_valid), .g_data(cpu_g_data)
	);

	sdram_arbiter #(.N(1)) u_arb2 (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[2]), .phy_we(phy_we[2]), .phy_we16(phy_we16[2]),
		.phy_addr(phy_addr[2]), .phy_wdata(phy_wdata[2]),
		.phy_busy(phy_busy[2]), .phy_valid(phy_valid[2]), .phy_rdata(phy_rdata[2]),
		.c_req(cpu_g_req), .c_addr(cpu_g_addr + BASE_MAINCPU),
		.c_valid(cpu_g_valid), .c_rdata(cpu_g_data),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

endmodule

`default_nettype wire
