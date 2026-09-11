// The Group A video path: timing generator + X1-001 sprites + X1-006 palette.
//
// Group A boards fit no X1-012 tilemap layers at all, so there is nothing to
// composite -- screen_update_seta_no_layers is three lines: fill with pen
// 0x1f0, draw the sprites, done. The X1-011 mixer, the layer ordering and the
// palette-offset effect all arrive with Phase 2 and 3; this module deliberately
// has no place for them yet rather than an unused one.
//
// NO ADDRESS DECODE HERE. maincpu.sv already decodes every region and drives a
// one-hot io_sel; fanning that out is the core's job, so this module takes
// per-block write ports instead. Duplicating the region indices in two files
// is exactly the kind of thing that goes quietly out of step.
//
// THE PIXEL PIPELINE IS ONE DOT LONG, and that is a deliberate simplification.
// From an address presented to the line buffer to a colour out of the palette
// is five clk_sys cycles:
//     lb_addr registered -> line-buffer RAM -> lb_data
//         -> palette index registered -> palette RAM -> vid_q -> r/g/b
// A dot is twelve clk_sys cycles at 96 MHz / 8 MHz, so rather than distributing
// those five stages against the sync signals, everything is launched on one
// ce_pix and captured on the next. The syncs are delayed by exactly one dot to
// match. It costs one dot of latency, which the scaler neither sees nor cares
// about, and it removes a whole class of off-by-one between the colour and the
// blanking that produced a one-pixel shift the FIRST time this was written
// against the sprite engine on its own (sim/x1_001_tb's header records it).

`default_nettype none

import seta_pal_pkg::*;   // PAL_BLAND0 / PAL_BLAND1

module seta_video #(
	parameter int LB_W        = 11,     // palette index width
	parameter int PAL_ENTRIES = 2048
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,          // one pulse per dot

	// ---- geometry ----------------------------------------------------------
	input  wire  [9:0] htotal, hs_start, hs_end, hact_start, hact_end,
	input  wire  [9:0] vtotal, vs_start, vs_end, vact_start, vact_end,

	// ---- sprite chip configuration (see rtl/video/x1_001.sv) ---------------
	input  wire signed [8:0] fg_xoffs, fg_xoffs_flip, fg_yoffs, fg_yoffs_flip,
	input  wire signed [8:0] bg_xoffs, bg_xoffs_flip, bg_yoffs, bg_yoffs_flip,
	input  wire [12:0] bank_size,
	input  wire  [8:0] spritelimit,
	input  wire  [3:0] transpen,
	input  wire        bgflag_opaque,
	// setac_eof, for the Group B sets that buffer their sprite RAM.
	input  wire        buffer_sprites,
	input  wire [LB_W-1:0] colorbase_fg, colorbase_bg,
	input  wire  [8:0] screen_h, vis_max_y,
	input  wire [LB_W-1:0] backdrop,
	input  wire [15:0] code_mask,
	input  wire [15:0] line_budget,

	// layout_tilemap_6bpp, PER LAYER: zingzip and extdwnhl have a 6bpp layer 1
	// and a 4bpp layer 2, gundhara and jjsquawk have both 6bpp.
	input  wire        l0_bpp6, l1_bpp6,
	// The palette address formation each layer needs; see x1_011_index.sv.
	input  wire  [2:0] l0_pal_mode, l1_pal_mode,
	input  wire [LB_W-1:0] l0_pal_bank, l1_pal_bank,
	// blandia alone: a second palette RAM at entry 0x600 and the effect
	// that reads it. Low everywhere else, and the whole path folds away.
	input  wire        has_pal2,

	// DEBUG SWITCHES, from the OSD's Debug page. Each blanks one layer AT THE
	// MIXER, not at its engine: the engines keep running, keep their counters
	// and keep their SDRAM traffic, so turning a layer off does not change the
	// timing of anything else and what is left on screen is the other layers
	// exactly as they were. The sprite switch is en_spr in seta_core and works
	// the other way round -- it starves the engine's ROM port -- because there
	// the question being answered is usually "is the engine even fetching".
	input  wire        en_l0, en_l1,

	// ---- the X1-012 tile layer, LAYOUT_B only ------------------------------
	// has_l0 low leaves the whole layer idle and the mixer takes the sprite
	// buffer alone, which is exactly Group A's behaviour -- so the one video
	// path serves both phases and Group A cannot regress into a tilemap it
	// does not have.
	input  wire        has_l0,
	input  wire        l0_vram_we,
	input  wire [12:0] l0_vram_addr,
	input  wire [15:0] l0_vram_wdata,
	input  wire        l0_vram_uds, l0_vram_lds,
	output wire [15:0] l0_vram_rdata,
	input  wire        l0_ctrl_we,
	input  wire  [1:0] l0_ctrl_addr,
	input  wire [15:0] l0_ctrl_wdata,
	input  wire        l0_ctrl_uds, l0_ctrl_lds,
	output wire [15:0] l0_ctrl_rdata,
	input  wire signed [8:0] l0_xoffs, l0_xoffs_flip,
	input  wire [LB_W-1:0]   l0_colorbase,
	input  wire [15:0] l0_code_limit,
	output wire        tile_req,
	output wire [23:3] tile_addr,
	input  wire        tile_valid,
	input  wire [63:0] tile_data,

	// ---- the second X1-012, LAYOUT_C only ---------------------------------
	input  wire        has_l1,
	input  wire        l1_vram_we,
	input  wire [12:0] l1_vram_addr,
	input  wire [15:0] l1_vram_wdata,
	input  wire        l1_vram_uds, l1_vram_lds,
	output wire [15:0] l1_vram_rdata,
	input  wire        l1_ctrl_we,
	input  wire  [1:0] l1_ctrl_addr,
	input  wire [15:0] l1_ctrl_wdata,
	input  wire        l1_ctrl_uds, l1_ctrl_lds,
	output wire [15:0] l1_ctrl_rdata,
	input  wire signed [8:0] l1_xoffs, l1_xoffs_flip,
	input  wire [LB_W-1:0]   l1_colorbase,
	input  wire [15:0] l1_code_limit,
	output wire        tile1_req,
	output wire [23:3] tile1_addr,
	input  wire        tile1_valid,
	input  wire [63:0] tile1_data,
	// m_vregs. Bit 0 swaps the layers, bit 1 puts the sprites above the
	// frontmost one. Bit 2 is blandia's palette effect -- Phase 5.
	input  wire  [7:0] vregs,

	// ---- CPU: sprite chip --------------------------------------------------
	input  wire        code_we,
	input  wire [12:0] code_addr,
	input  wire [15:0] code_wdata,
	input  wire        code_uds, code_lds,
	output wire [15:0] code_rdata,

	input  wire        ylow_we,
	input  wire  [9:0] ylow_addr,
	input  wire  [7:0] ylow_wdata,
	output wire  [7:0] ylow_rdata,

	input  wire        ctrl_we,
	input  wire  [1:0] ctrl_addr,
	input  wire  [7:0] ctrl_wdata,
	output wire  [7:0] ctrl_rdata,

	// ---- CPU: palette ------------------------------------------------------
	input  wire        pal_we,
	input  wire [$clog2(PAL_ENTRIES)-1:0] pal_addr,
	input  wire [15:0] pal_wdata,
	input  wire        pal_uds, pal_lds,
	output wire [15:0] pal_rdata,

	// ---- sprite graphics ROM, one 64-bit granule per row -------------------
	output wire        rom_req,
	output wire [23:3] rom_addr,
	input  wire        rom_valid,
	input  wire [63:0] rom_data,

	// ---- video out ---------------------------------------------------------
	output logic [7:0] vga_r, vga_g, vga_b,
	output logic       vga_hs, vga_vs, vga_hb, vga_vb, vga_de,
	output logic       vga_ce,

	// ---- interrupts --------------------------------------------------------
	output wire        irq_vblank_line, irq_mid_line, vblank_rise,

	// ---- instrumentation ---------------------------------------------------
	// The TILEMAP engines' own counters. dbg_l*_overrun counts line_start
	// arriving while the engine is still rendering the previous line --
	// i.e. it did not finish in time. Built into x1_012 from the start and
	// connected to () until now, which is why nothing could say whether the
	// layers were starved on hardware.
	output wire [23:3] dbg_l0_last_addr,
	output wire [63:0] dbg_l0_last_data,
	output wire [15:0] dbg_l0_lines, dbg_l0_tiles, dbg_l0_overrun,
	output wire [15:0] dbg_l1_lines, dbg_l1_tiles, dbg_l1_overrun,
	output wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun,
	output wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped
);

	localparam int PAW = $clog2(PAL_ENTRIES);

	// ---- timing -------------------------------------------------------------
	wire [9:0] hcount, vcount;
	wire       hsync, vsync, hblank, vblank, de;
	wire       line_start;
	wire [8:0] line;

	seta_video_timing u_timing (
		.clk(clk), .reset(reset), .ce_pix(ce_pix),
		.htotal(htotal), .hs_start(hs_start), .hs_end(hs_end),
		.hact_start(hact_start), .hact_end(hact_end),
		.vtotal(vtotal), .vs_start(vs_start), .vs_end(vs_end),
		.vact_start(vact_start), .vact_end(vact_end),
		.hcount(hcount), .vcount(vcount),
		.hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
		.line_start(line_start), .line(line),
		.irq_vblank_line(irq_vblank_line), .irq_mid_line(irq_mid_line),
		.vblank_rise(vblank_rise)
	);

	// ---- sprites ------------------------------------------------------------
	logic  [8:0] lb_addr;
	wire [LB_W-1:0] lb_data;
	wire         lb_hit;
	// The sprite chip's flip bit, which is where the layer's comes from.
	wire         flipscr_l0;
	// visible_area().height(), which update_scroll centres the map against.
	wire   [8:0] vis_dimy = vact_end[8:0] - vact_start[8:0] + 9'd1;

	x1_001 #(.LB_W(LB_W)) u_spr (
		.clk(clk), .reset(reset),
		.code_we(code_we), .code_addr(code_addr), .code_wdata(code_wdata),
		.code_uds(code_uds), .code_lds(code_lds), .code_rdata(code_rdata),
		.ylow_we(ylow_we), .ylow_addr(ylow_addr), .ylow_wdata(ylow_wdata),
		.ylow_rdata(ylow_rdata),
		.ctrl_we(ctrl_we), .ctrl_addr(ctrl_addr), .ctrl_wdata(ctrl_wdata),
		.ctrl_rdata(ctrl_rdata),
		.fg_xoffs(fg_xoffs), .fg_xoffs_flip(fg_xoffs_flip),
		.fg_yoffs(fg_yoffs), .fg_yoffs_flip(fg_yoffs_flip),
		.bg_xoffs(bg_xoffs), .bg_xoffs_flip(bg_xoffs_flip),
		.bg_yoffs(bg_yoffs), .bg_yoffs_flip(bg_yoffs_flip),
		.bank_size(bank_size), .spritelimit(spritelimit), .transpen(transpen),
		.bgflag_opaque(bgflag_opaque),
		.buffer_sprites(buffer_sprites), .vblank_rise(vblank_rise),
		.colorbase_fg(colorbase_fg), .colorbase_bg(colorbase_bg),
		.screen_h(screen_h), .vis_max_y(vis_max_y), .backdrop(backdrop),
		.code_mask(code_mask), .line_budget(line_budget),
		.line_start(line_start), .line(line), .line_done(), .busy(),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.lb_addr(lb_addr), .lb_data(lb_data), .lb_hit(lb_hit),
		.flipscr_out(flipscr_l0),
		.dbg_lines(dbg_lines), .dbg_sprites(dbg_sprites),
		.dbg_fetches(dbg_fetches), .dbg_overrun(dbg_overrun),
		.dbg_worst_line(dbg_worst_line), .dbg_worst_sprites(dbg_worst_sprites),
		.dbg_dropped(dbg_dropped)
	);

	// ---- palette ------------------------------------------------------------
	logic [PAW-1:0] pal_index;
	wire      [7:0] pr, pg, pb;

	seta_palette #(.ENTRIES(PAL_ENTRIES)) u_pal (
		.clk(clk),
		.cpu_we(pal_we), .cpu_addr(pal_addr), .cpu_wdata(pal_wdata),
		.cpu_uds(pal_uds), .cpu_lds(pal_lds), .cpu_rdata(pal_rdata),
		.index(pal_index), .r(pr), .g(pg), .b(pb)
	);

	// ---- the one-dot pipeline ------------------------------------------------
	// Launch on one ce_pix, capture on the next. The line buffer is indexed by
	// SCREEN-SPACE x, which is hcount directly -- the visible window starts at
	// hact_start and the buffer is 512 wide for the same reason the chip's x
	// wraps modulo 512.
	logic hs_d, vs_d, hb_d, vb_d, de_d;

	always_ff @(posedge clk) begin
		vga_ce <= 1'b0;
		if (reset) begin
			de_d <= 1'b0;
		end else if (ce_pix) begin
			// capture the dot launched on the previous ce_pix...
			vga_r  <= de_d ? pr : 8'd0;
			vga_g  <= de_d ? pg : 8'd0;
			vga_b  <= de_d ? pb : 8'd0;
			vga_hs <= hs_d;  vga_vs <= vs_d;
			vga_hb <= hb_d;  vga_vb <= vb_d;
			vga_de <= de_d;
			vga_ce <= 1'b1;

			// ...and launch this one.
			lb_addr <= hcount[8:0];
			hs_d <= hsync;  vs_d <= vsync;
			hb_d <= hblank; vb_d <= vblank;
			de_d <= de;
		end
	end

	// ---- the tile layer ----------------------------------------------------
	// Driven from the SAME line_start and line as the sprite engine, so the two
	// line buffers are always for the same scanline and the mixer needs no
	// alignment of its own.
	wire        l0_cmode, l1_cmode;   // vctrl[2] bit 4, per layer
	wire [LB_W-1:0] l0_lb_data;

	x1_012 #(.LB_W(LB_W)) u_l0 (
		.clk(clk), .reset(reset | ~has_l0),
		.vram_we(l0_vram_we), .vram_addr(l0_vram_addr),
		.vram_wdata(l0_vram_wdata), .vram_uds(l0_vram_uds),
		.vram_lds(l0_vram_lds), .vram_rdata(l0_vram_rdata),
		.vctrl_we(l0_ctrl_we), .vctrl_addr(l0_ctrl_addr),
		.vctrl_wdata(l0_ctrl_wdata), .vctrl_uds(l0_ctrl_uds),
		.vctrl_lds(l0_ctrl_lds), .vctrl_rdata(l0_ctrl_rdata),
		.cmode(l0_cmode),
		.xoffs(l0_xoffs), .xoffs_flip(l0_xoffs_flip),
		.flipscr(flipscr_l0),
		.vis_dimy(vis_dimy), .colorbase(l0_colorbase), .code_limit(l0_code_limit),
		.bpp6(l0_bpp6),
		.vblank_rise(vblank_rise),
		.line_start(line_start & has_l0), .line(line),
		.line_budget(line_budget), .line_done(), .busy(),
		.rom_req(tile_req), .rom_addr(tile_addr),
		.rom_valid(tile_valid), .rom_data(tile_data),
		.lb_addr(lb_addr), .lb_data(l0_lb_data),
		.dbg_lines(dbg_l0_lines), .dbg_tiles(dbg_l0_tiles),
		.dbg_overrun(dbg_l0_overrun),
		.dbg_last_addr(dbg_l0_last_addr), .dbg_last_data(dbg_l0_last_data)
	);

	wire [LB_W-1:0] l1_lb_data;

	x1_012 #(.LB_W(LB_W)) u_l1 (
		.clk(clk), .reset(reset | ~has_l1),
		.vram_we(l1_vram_we), .vram_addr(l1_vram_addr),
		.vram_wdata(l1_vram_wdata), .vram_uds(l1_vram_uds),
		.vram_lds(l1_vram_lds), .vram_rdata(l1_vram_rdata),
		.vctrl_we(l1_ctrl_we), .vctrl_addr(l1_ctrl_addr),
		.vctrl_wdata(l1_ctrl_wdata), .vctrl_uds(l1_ctrl_uds),
		.vctrl_lds(l1_ctrl_lds), .vctrl_rdata(l1_ctrl_rdata),
		.cmode(l1_cmode),
		.xoffs(l1_xoffs), .xoffs_flip(l1_xoffs_flip),
		.flipscr(flipscr_l0),
		.vis_dimy(vis_dimy), .colorbase(l1_colorbase), .code_limit(l1_code_limit),
		.bpp6(l1_bpp6),
		.vblank_rise(vblank_rise),
		.line_start(line_start & has_l1), .line(line),
		.line_budget(line_budget), .line_done(), .busy(),
		.rom_req(tile1_req), .rom_addr(tile1_addr),
		.rom_valid(tile1_valid), .rom_data(tile1_data),
		.lb_addr(lb_addr), .lb_data(l1_lb_data),
		.dbg_lines(dbg_l1_lines), .dbg_tiles(dbg_l1_tiles),
		.dbg_overrun(dbg_l1_overrun),
		.dbg_last_addr(), .dbg_last_data()
	);

	// COMPOSITION, for a one-layer game:
	//
	//     seta_layers_update -> bitmap.fill(0)
	//                        -> layer 0 drawn OPAQUE
	//                        -> sprites over it
	//
	// so the sprite pixel wins wherever a sprite actually wrote one, and the
	// layer shows through everywhere else. lb_hit is that "actually wrote",
	// which is the same bit the sprite engine uses to make front-to-back
	// drawing work. With has_l0 low the mixer takes the sprite buffer alone --
	// Group A, unchanged.
	// The debug switches land here, on the line-buffer data and nowhere else.
	// Zero is what seta_layers_update's bitmap.fill(0) leaves behind, so a
	// disabled layer reads as pen 0: transparent where the mixer tests the low
	// four bits, and palette entry 0 where it does not.
	wire [LB_W-1:0] l0_raw = en_l0 ? l0_lb_data : '0;
	wire [LB_W-1:0] l1_raw = en_l1 ? l1_lb_data : '0;

	// PALETTE ADDRESS FORMATION, per layer. Pass-through for every 4bpp game;
	// for the 6bpp ones it is the adder rtl/video/x1_011_index.sv describes,
	// and the engine hands it {color, pen} with no base.
	// COLOUR MODE, which is a runtime bit and not a board property. The board
	// config names PAL_BLAND0; vctrl[2] bit 4 promotes it to PAL_BLAND1 per
	// layer, per frame. Every other mode ignores the bit -- see the header of
	// x1_011_index.sv for why only blandia's two entries differ.
	wire [2:0] l0_mode = (l0_pal_mode == PAL_BLAND0 && l0_cmode)
	                   ? PAL_BLAND1 : l0_pal_mode;
	wire [2:0] l1_mode = (l1_pal_mode == PAL_BLAND0 && l1_cmode)
	                   ? PAL_BLAND1 : l1_pal_mode;

	wire [LB_W-1:0] l0_px_d, l1_px_d;
	x1_011_index #(.LB_W(LB_W)) u_l0_pal (
		.mode(l0_mode), .bank(l0_pal_bank), .idx(l0_raw), .entry(l0_px_d));
	x1_011_index #(.LB_W(LB_W)) u_l1_pal (
		.mode(l1_mode), .bank(l1_pal_bank), .idx(l1_raw), .entry(l1_px_d));

	// TRANSPARENCY IS THE TILE'S PEN, and a 6bpp pen is six bits wide. Tested
	// on the index before the remap, which is where the pen still is: after
	// it, a transparent pixel of colour 1 is bank + 0x10, whose low bits are
	// not zero at all.
	wire l0_op = l0_bpp6 ? |l0_raw[5:0] : |l0_raw[3:0];
	wire l1_op = l1_bpp6 ? |l1_raw[5:0] : |l1_raw[3:0];

	wire [LB_W-1:0] mixed_1l = (has_l0 && !lb_hit) ? l0_px_d : lb_data;

	// TWO LAYERS -- seta_layers_update's order, resolved per dot.
	//
	//   order = vregs
	//   bit 0  Layer 0 Above Layer 1   (swap: layer 1 becomes the bottom)
	//   bit 1  Sprites Above Frontmost Layer
	//
	// The BOTTOM layer is drawn TILEMAP_DRAW_OPAQUE, so it always has a pixel;
	// the TOP layer is transparent on pen 0, and pen 0 of a tile is
	// colorbase + colour*16 + 0 -- which is why "did the top layer draw here"
	// is its low four bits being non-zero, not a written bit.
	// vregs latched at vblank, with the scroll and the sprite snapshot: the
	// order bits are written mid-frame too, and MAME reads them at the draw.
	logic [7:0] vregs_lat = '0;
	always_ff @(posedge clk) if (vblank_rise) vregs_lat <= vregs;
	wire            swap    = vregs_lat[0];

	// THE PALETTE-OFFSET EFFECT (draw_tilemap_palette_effect), blandia only.
	//
	// vregs bit 2 turns it on, and it applies to LAYER 1 -- the device, not
	// whichever layer is on top. An opaque layer-1 pixel whose colour code is
	// 31 is not drawn; instead the pixel ALREADY UNDERNEATH is re-looked-up in
	// the second palette RAM, at 0x600 + its low nine bits.
	//
	// Colour 31 is what MAME's mask test comes to. It reads
	//     (p & (colorbase + (colors-1) * granularity)) == that
	// which for layer 1's two gfx entries is (p & 0x9c0) == 0x9c0 and
	// (p & 0x19c0) == 0x19c0. p is colorbase + color*64 + pen and pen never
	// carries into bit 6, so in units of 64 the test is on 8 + color and on
	// 72 + color -- satisfied by 39 and 0x67 respectively, both color == 31.
	//
	// The index it re-looks-up is MAME's colortable index, which is the pen
	// BEFORE x1_011_index, not the palette entry after: a layer pixel's
	// colortable base (0xa00, 0x1a00) is a multiple of 0x200 and vanishes
	// under the mask, and a sprite's is zero. So this takes l0_raw and
	// lb_data, not l0_px_d and a remapped sprite.
	//
	// ONLY UNSWAPPED. MAME's order-bit-0 branch does not implement the effect
	// at all -- it popmessages "Missing palette effect" and draws layer 0
	// normally -- so a swapped frame has no effect to reproduce.
	wire eff_on  = has_pal2 && vregs_lat[2] && !swap;
	wire l1_eff  = eff_on && (l1_raw[10:6] == 5'd31);
	// What is under layer 1 at that moment: layer 0, which is drawn opaque,
	// plus the sprites when they go on before the top layer.
	wire [LB_W-1:0] under_raw = (vregs_lat[1] && lb_hit) ? lb_data : l0_raw;
	wire [LB_W-1:0] l1_px_e   = l1_eff
	        ? (11'h600 + {2'd0, under_raw[8:0]}) : l1_px_d;

	wire [LB_W-1:0] bot_px  = swap ? l1_px_d : l0_px_d;
	wire [LB_W-1:0] top_px  = swap ? l0_px_d : l1_px_e;
	wire            top_op  = swap ? l0_op   : l1_op;

	// Sprites above the frontmost layer, or between the two.
	wire [LB_W-1:0] under_spr = top_op ? top_px : bot_px;
	wire [LB_W-1:0] mixed_2l  = vregs_lat[1]
	        // sprites go on before the top layer, so the top layer covers them
	        ? (top_op ? top_px : (lb_hit ? lb_data : bot_px))
	        // sprites go on last, over everything
	        : (lb_hit ? lb_data : under_spr);

	wire [LB_W-1:0] mixed = has_l1 ? mixed_2l : mixed_1l;

	// lb_data lands two cycles after lb_addr is registered; the palette needs
	// its index registered too, and both are settled long before the next
	// ce_pix twelve cycles later.
	// PAW CAN EXCEED LB_W. blandia's palette RAM is 3072 entries -- 1536 of
	// its own plus 1536 the second window writes -- but nothing the video
	// side can produce reaches past 0x7ff: a normal entry is at most 0xbff's
	// worth of bank plus a 9-bit offset, and the palette effect tops out at
	// 0x600 + 0x1ff. The extra entries exist so the CPU's writes land
	// somewhere real, not because the index needs the width.
	logic [PAW-1:0] mixed_w;
	always_comb mixed_w = mixed;          // zero-extends; PAW >= LB_W
	always_ff @(posedge clk) pal_index <= mixed_w;

endmodule

`default_nettype wire
