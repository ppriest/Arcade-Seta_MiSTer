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
//   LAYOUT_B -- Group B, one 4bpp tilemap layer
//     maincpu  0x000000  1 MB   (all four sets are 0.75 MB)
//     gfx1     0x100000  1 MB   (all four)
//     gfx2     0x200000  2 MB   (qzkklgy2; the other three are 1 MB)
//     x1snd    0x400000  1 MB   (all four)
//     total             5 MB
//
//   LAYOUT_C -- Group C, two 4bpp tilemap layers
//     maincpu  0x000000  2 MB   (rezon, wrofaero, msgundam)
//     gfx1     0x200000  4 MB   (msgundam; daioh is 2 MB, rezon 1 MB)
//     gfx2     0x600000  2 MB   (daioh)
//     gfx3     0x800000  2 MB   (daioh)
//     x1snd    0xa00000  2 MB   (eightfrc; daioh and rezon are 1 MB)
//     total            12 MB
//
//   Every size is the largest MEASURED across the sets in that group, from the
//   ROM_START records. The spread inside Group C is wide -- msgundam has four
//   times rezon's sprite ROM and daioh four times its tiles -- so a layout
//   sized from any one game would be wrong for the others.
//
//   X1SND MOVES BETWEEN THE LAYOUTS. gfx2 is 2 MB because qzkklgy2's is --
//   measured from the ROM_START records, not assumed from its three siblings,
//   which are 1 MB each. Sizing it at 1 MB would have overlapped x1snd with
//   the top half of qzkklgy2's tiles and broken exactly one game's graphics
//   and sound together.
//
//   Sizes come from the records rather than being rounded up for comfort:
//   scripts/build_mra.py reads this map out of THIS FILE, so a region declared
//   larger than it needs pads every .mra by the difference.
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
	// LAYOUT_B puts a tilemap region at 0x200000 and shrinks the swizzle
	// window to match. One bit, because the two layouts in scope differ only
	// in that.
	// 0 = LAYOUT_A (Group A), 1 = LAYOUT_B (Group B), 2 = LAYOUT_C (Group C).
	input  wire  [1:0] layout,
	// ROMREGION_INVERT on gfx1: every byte of the sprite region is inverted on
	// the way in. A .mra ships the ROM as dumped, so this is where MAME's
	// region flag is applied.
	input  wire        gfx1_invert,

	input  wire        spr_req,
	input  wire [23:3] spr_addr,      // granule address within "gfx1"
	output wire        spr_valid,
	output wire [63:0] spr_data,

	// Tile graphics, LAYOUT_B only. Shares the sprite phy: both are per-line
	// graphics fetches with the same deadline, and the tilemap asks for at
	// most 100 granules a line against the sprite engine's several hundred.
	input  wire        tile_req,
	input  wire [23:3] tile_addr,     // granule address within "gfx2"
	output wire        tile_valid,
	output wire [63:0] tile_data,

	// The second tile layer, LAYOUT_C only.
	input  wire        tile1_req,
	input  wire [23:3] tile1_addr,    // granule address within "gfx3"
	output wire        tile1_valid,
	output wire [63:0] tile1_data,

	// ---- X1-010 PCM samples --------------------------------------------------
	input  wire        snd_req,
	// 21 bits, not 20: eightfrc and blandia have 2 MB of samples, reached
	// through the X1-010's bank register.
	input  wire [20:0] snd_addr,      // byte address within "x1snd"
	output wire        snd_valid,
	output wire  [7:0] snd_data
);

	// =====================================================================
	// LAYOUT_A. See the header.
	// =====================================================================
	// LAYOUT_C moves everything, so the bases are per layout rather than one
	// set with exceptions.
	localparam logic [25:0] BASE_MAINCPU   = 26'h000_0000;
	localparam logic [25:0] BASE_GFX1_AB   = 26'h010_0000;   // 2 MB in A, 1 MB in B
	localparam logic [25:0] BASE_GFX1_C    = 26'h020_0000;   // 4 MB
	localparam logic [25:0] BASE_GFX2_B    = 26'h020_0000;   // 2 MB
	localparam logic [25:0] BASE_GFX2_C    = 26'h060_0000;   // 2 MB
	localparam logic [25:0] BASE_GFX3_C    = 26'h080_0000;   // 2 MB
	localparam logic [25:0] BASE_X1SND_C   = 26'h0a0_0000;

	wire layout_b = (layout == 2'd1);
	wire layout_c = (layout == 2'd2);

	wire   [25:0] BASE_GFX1 = layout_c ? BASE_GFX1_C : BASE_GFX1_AB;
	wire   [25:0] BASE_GFX2 = layout_c ? BASE_GFX2_C : BASE_GFX2_B;
	// x1snd sits above gfx2, which is only present in LAYOUT_B. BOTH VALUES
	// ARE localparams so scripts/build_mra.py can still read the map out of
	// this file -- it parses localparam declarations, and a bare wire would
	// have hidden the layout from the .mra generator, which is the one place
	// that must agree with it exactly.
	localparam logic [25:0] BASE_X1SND_A = 26'h030_0000;
	localparam logic [25:0] BASE_X1SND_B = 26'h040_0000;
	wire   [25:0] BASE_X1SND = layout_c ? BASE_X1SND_C :
	                           layout_b ? BASE_X1SND_B : BASE_X1SND_A;
	// The swizzle window. In LAYOUT_B gfx1 is only 1 MB, but permuting a 2 MB
	// window there would reach into gfx2 -- which must NOT be swizzled, because
	// layout_tilemap is RGN_FRAC(1,1) and its rows are already four chunks in
	// one region rather than two halves. So the window follows the layout.
	wire   [25:0] SIZE_GFX1 = layout_c ? 26'h040_0000 :
	                          layout_b ? 26'h010_0000 : 26'h020_0000;

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
		// Inverted for gfx1 when the region says so, at the same point the
		// swizzle is applied -- both are properties of how the region is laid
		// out, not of the file the .mra ships.
		.ioctl_dout(gfx1_invert && in_gfx1 ? ~ioctl_dout : ioctl_dout),
		.ioctl_wait(ioctl_wait),
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

	// The tile client, held the same way the sprite one is: c_req is a LEVEL
	// until the matching c_valid.
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
		.c_addr({{2'd0, tile1_addr, 3'd0} + BASE_GFX3_C,
		         {2'd0, tile_addr,  3'd0} + BASE_GFX2,
		         {2'd0, spr_addr,   3'd0} + BASE_GFX1}),
		.c_valid(arb0_valid), .c_rdata(arb0_rdata),
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
