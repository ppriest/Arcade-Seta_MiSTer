// SDRAM backend: every ROM the core reads at runtime, on one physical chip.
//
// ---------------------------------------------------------------------------
// PORT ASSIGNMENT, AND WHY IT IS THE ONLY BANDWIDTH KNOB THERE IS.
//
// sdram.sv drives ONE physical chip. Its three "ports" are logical and
// time-multiplexed onto it with FIXED PRIORITY -- port 0 always preempts port
// 1, which always preempts port 2. So "use another port" buys no parallel
// bandwidth; the only thing to tune is which client sits behind which
// priority slot.
//
//   Port 0   sprite graphics                     (arbiter, 1 client)
//   Port 1   X1-010 PCM sample fetch             (arbiter, 1 client)
//   Port 2   main CPU program fetch + download   (arbiter, 1 client + dl)
//
// Sprites take the top slot because in Phase 1 they have the only hard
// deadline: the engine has one scanline to build a line and dropped sprites
// are visible. The X1-010 next -- a real deadline but a tiny one, one byte per
// voice per sample step at 31.25 kHz. The CPU sits last on purpose: starving
// it makes the game run slower, which degrades gracefully, where starving
// either of the others does not.
//
// THIS ASSIGNMENT IS FOR GROUP A AND WILL CHANGE. When the X1-012 tilemap
// engine arrives it has a harder deadline than sprites -- a late tilemap
// granule corrupts the scanline being drawn with no buffer of slack, where the
// sprite engine renders a line ahead. Fuuki puts tilemaps at port 0 and
// sprites at port 1 for exactly that reason. Re-partition then, WITH A
// MEASUREMENT: Psikyo's first re-partition measured worse, not better.
//
// The download shares port 2 and takes absolute priority within it, which
// costs nothing because it only runs before anything is drawn.
// ---------------------------------------------------------------------------
//
// ADDRESS MAP. This module is the authority; every `.mra` must load to these
// same offsets, and scripts/build_mra.py generates them from this table.
//
// One map per LAYOUT, not one map sized for the largest game. A single map
// sized for gundhara's 8 MB of sprites would make thunderl's `.mra` pad out to
// that base and ship megabytes of filler for a 1.5 MB game. Group A is the
// only layout defined here; the tilemap layouts arrive with the phases that
// need them, sized against real games rather than invented now.
//
//   LAYOUT_A -- Group A, no tilemap layers
//     maincpu  0x000000  1 MB   (atehate is 1 MB, every other set is smaller)
//     gfx1     0x100000  2 MB   (atehate; thunderl and wits are 0.5 MB)
//     x1snd    0x300000  1 MB   (every Group A set)
//     total             4 MB
//
// ---------------------------------------------------------------------------
// THE SPRITE LAYOUT PERMUTATION HAPPENS HERE, on the way in.
//
// rtl/memory/gfx_swizzle.sv turns MAME's RGN_FRAC(1,2) sprite region into one
// where a 16-pixel row is a single 64-bit granule. It is a pure WORD-address
// permutation -- the plane bit is the low bit of both the source and the
// destination byte address -- so it is applied to `ioctl_addr` BEFORE
// sdram_download.sv sees it, and that module is untouched.
//
// That the permutation preserves bit 0 is what makes this safe:
// sdram_download coalesces byte pairs by checking `ioctl_addr[0]` and that
// consecutive bytes share a word. Both survive, because the two bytes of a
// source word still land in one destination word.

`default_nettype none

module seta_sdram_top (
	input  wire clk,

	// MASKED OFF DURING THE DOWNLOAD. The caller must pass
	//
	//     reset & ~ioctl_download
	//
	// and NOT the framework's RESET, because MiSTer holds core RESET asserted
	// for the ENTIRE ROM download. Anything in the memory path gated by a
	// reset that includes it is dead for the whole transfer: the download FSM
	// sits in idle while the HPS delivers every byte, not one write reaches
	// the chip, and every later read returns power-up contents.
	//
	// This is not hypothetical. Psikyo hit it, LESSONS_LEARNED records it
	// ("Never hold the memory path in the core reset"), Fuuki's equivalent
	// module carries the same warning in its header -- and Fuuki's first
	// bitstream still shipped with plain `reset` wired here. It presented as a
	// correct raster that was 100% black, because video timing is independent
	// of memory and so the only symptom was that nothing was ever drawn.
	input  wire reset,

	// SDRAM power-up initialisation, SEPARATE from `reset` on purpose. This
	// drives the chip's init sequence and must NOT be asserted by a core reset
	// or a download -- pass `~pll_locked`.
	input  wire init,

	// ---- SDRAM pins ---------------------------------------------------------
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

	// ---- HPS ROM download ---------------------------------------------------
	input  wire        ioctl_download,
	input  wire [15:0] ioctl_index,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire  [7:0] ioctl_dout,
	output wire        ioctl_wait,

	// ---- per-game configuration ---------------------------------------------
	// Words in one RGN_FRAC half of "gfx1", i.e. the region size in bytes over
	// four. Per GAME, not per layout: Group A's sprite regions run from
	// thunderl's 0.5 MB to atehate's 2 MB, and the permutation depends on
	// where the halves split. Comes from the same board table that supplies
	// the sprite engine's code_mask, which is derived from the same number.
	input  wire [22:0] gfx_half_words,

	// ---- main CPU program fetch ---------------------------------------------
	input  wire        cpu_req,
	input  wire [23:1] cpu_addr,      // word address within "maincpu"
	output wire        cpu_valid,
	output wire [15:0] cpu_data,

	// ---- sprite graphics: one 64-bit granule per row ------------------------
	input  wire        spr_req,
	input  wire [23:3] spr_addr,      // granule address within "gfx1"
	output wire        spr_valid,
	output wire [63:0] spr_data,

	// ---- X1-010 PCM samples --------------------------------------------------
	input  wire        snd_req,
	input  wire [19:0] snd_addr,      // byte address within "x1snd"
	output wire        snd_valid,
	output wire  [7:0] snd_data
);

	// =====================================================================
	// LAYOUT_A. See the header.
	// =====================================================================
	localparam logic [25:0] BASE_MAINCPU = 26'h000_0000;   // 1 MB
	localparam logic [25:0] BASE_GFX1    = 26'h010_0000;   // 2 MB
	localparam logic [25:0] BASE_X1SND   = 26'h030_0000;   // 1 MB
	localparam logic [25:0] SIZE_GFX1    = 26'h020_0000;

	// =====================================================================
	// Download: swizzle the sprite region's word addresses on the way in.
	// =====================================================================
	wire in_gfx1 = (ioctl_addr[25:0] >= BASE_GFX1)
	            && (ioctl_addr[25:0] <  BASE_GFX1 + SIZE_GFX1);

	wire [22:0] swz_in  = (ioctl_addr[25:0] - BASE_GFX1) >> 1;
	wire [22:0] swz_out;

	gfx_swizzle #(.AW(23)) u_swz (
		.half_words(gfx_half_words),
		.word_in(swz_in),
		.word_out(swz_out)
	);

	// Bit 0 -- the bit plane within the byte pair -- is carried through
	// untouched, which is what lets sdram_download keep coalescing pairs.
	wire [26:0] ioctl_addr_swz =
		in_gfx1 ? {1'b0, BASE_GFX1 + {2'd0, swz_out, 1'b0} + {25'd0, ioctl_addr[0]}}
		        : ioctl_addr;

	wire        dl_req, dl_we16, dl_busy;
	wire [25:0] dl_addr;
	wire [15:0] dl_data;

	sdram_download u_dl (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr_swz),
		.ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

	// =====================================================================
	// The chip and its three ports
	// =====================================================================
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

	// One phy and one arbiter per port. The phy turns a byte address into the
	// chip's burst-of-four; the arbiter shares that phy between clients and
	// carries the download's write path.
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

	// ---- port 0: sprite graphics --------------------------------------------
	// A DIRECT arbiter client, not a narrow bridge: a swizzled sprite row is
	// exactly one granule and never straddles two, so there is nothing for a
	// granule cache to do except add a cycle.
	//
	// c_req is a LEVEL held until c_valid -- the arbiter's contract, and the
	// OPPOSITE of sdram_narrow_bridge's, which wants a pulse. Both conventions
	// are in this file; each client below is commented with the one it uses.
	logic        spr_req_l;
	always_ff @(posedge clk) begin
		if (reset)          spr_req_l <= 1'b0;
		else if (spr_valid) spr_req_l <= 1'b0;
		else if (spr_req)   spr_req_l <= 1'b1;
	end

	sdram_arbiter #(.N(1)) u_arb0 (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[0]), .phy_we(phy_we[0]), .phy_we16(phy_we16[0]),
		.phy_addr(phy_addr[0]), .phy_wdata(phy_wdata[0]),
		.phy_busy(phy_busy[0]), .phy_valid(phy_valid[0]), .phy_rdata(phy_rdata[0]),
		.c_req(spr_req_l), .c_addr({2'd0, spr_addr, 3'd0} + BASE_GFX1),
		.c_valid(spr_valid), .c_rdata(spr_data),
		.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// ---- port 1: X1-010 PCM --------------------------------------------------
	// Byte-wide through a granule cache: the chip walks a sample sequentially,
	// so eight consecutive bytes come out of one fetch. PULSED req.
	wire        snd_g_req;
	wire [25:0] snd_g_addr;
	wire        snd_g_valid;
	wire [63:0] snd_g_data;

	sdram_narrow_bridge #(.WORD_BYTES(1)) u_snd_bridge (
		.clk(clk), .reset(reset),
		.inval(ioctl_download),
		.req(snd_req), .addr({6'd0, snd_addr}),
		.valid(snd_valid), .data(snd_data),
		.g_req(snd_g_req), .g_addr(snd_g_addr),
		.g_valid(snd_g_valid), .g_data(snd_g_data)
	);

	sdram_arbiter #(.N(1)) u_arb1 (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[1]), .phy_we(phy_we[1]), .phy_we16(phy_we16[1]),
		.phy_addr(phy_addr[1]), .phy_wdata(phy_wdata[1]),
		.phy_busy(phy_busy[1]), .phy_valid(phy_valid[1]), .phy_rdata(phy_rdata[1]),
		.c_req(snd_g_req), .c_addr(snd_g_addr + BASE_X1SND),
		.c_valid(snd_g_valid), .c_rdata(snd_g_data),
		.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// ---- port 2: main CPU, and the download ----------------------------------
	wire        cpu_g_req;
	wire [25:0] cpu_g_addr;
	wire        cpu_g_valid;
	wire [63:0] cpu_g_data;

	sdram_narrow_bridge #(.WORD_BYTES(2)) u_cpu_bridge (
		.clk(clk), .reset(reset),
		.inval(ioctl_download),
		// 26 bits: 2 + 23 + 1. Writing 3'b000 here would make 27 and the top
		// bit would be silently truncated -- harmless for a 64 KB image and
		// not for a 2 MB one, which is exactly how a width bug hides.
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
