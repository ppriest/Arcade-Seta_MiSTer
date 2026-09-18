// The video path: timing, the X1-001 sprite chip, up to two X1-012 tile
// layers, the X1-011 mix and the X1-006 palette. Region decode is maincpu's;
// this takes per-block ports.
//
// Each dot is launched on one ce_pix and captured on the next (line buffer,
// palette index, palette RAM: five clk_sys cycles of twelve), with the syncs
// delayed one dot to match.

`default_nettype none

import seta_pal_pkg::*;   // PAL_BLAND0 / PAL_BLAND1

module seta_video #(
	parameter int LB_W        = 11,     // palette index width
	parameter int PAL_ENTRIES = 2048
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,          // one pulse per dot

	input  wire  [9:0] htotal, hs_start, hs_end, hact_start, hact_end,
	input  wire  [9:0] vtotal, vs_start, vs_end, vact_start, vact_end,

	// sprite chip (x1_001.sv)
	input  wire signed [8:0] fg_xoffs, fg_xoffs_flip, fg_yoffs, fg_yoffs_flip,
	input  wire signed [8:0] bg_xoffs, bg_xoffs_flip, bg_yoffs, bg_yoffs_flip,
	input  wire [12:0] bank_size,
	input  wire  [8:0] spritelimit,
	input  wire  [3:0] transpen,
	input  wire        bgflag_opaque,
	// setac_eof, and whether MAME draws after it (x1_001.sv)
	input  wire        buffer_sprites,
	input  wire        copy_then_draw,
	input  wire  [9:0] spr_snap_line,
	input  wire [LB_W-1:0] colorbase_fg, colorbase_bg,
	input  wire  [8:0] screen_h, vis_max_y,
	input  wire [LB_W-1:0] backdrop,
	input  wire [15:0] code_mask,
	input  wire [15:0] line_budget,

	// layout_tilemap_6bpp, per layer
	input  wire        l0_bpp6, l1_bpp6,
	// x1_011_index.sv
	input  wire  [2:0] l0_pal_mode, l1_pal_mode,
	input  wire [LB_W-1:0] l0_pal_bank, l1_pal_bank,
	// blandia: second palette RAM at 0x600 and its offset effect
	input  wire        has_pal2,

	// Debug: blank a layer at the mix; its engine keeps running.
	input  wire        en_l0, en_l1,
	input  wire        tile_cache_en,

	// tile layer 0
	input  wire        has_l0,
	input  wire        l0_vram_we,
	input  wire [12:0] l0_vram_addr,
	input  wire [15:0] l0_vram_wdata,
	input  wire        l0_vram_uds, l0_vram_lds,
	output wire [15:0] l0_vram_rdata,
	input  wire        l0_vram_drain,
	output wire        l0_vram_busy,
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

	// tile layer 1
	input  wire        has_l1,
	input  wire        l1_vram_we,
	input  wire [12:0] l1_vram_addr,
	input  wire [15:0] l1_vram_wdata,
	input  wire        l1_vram_uds, l1_vram_lds,
	output wire [15:0] l1_vram_rdata,
	input  wire        l1_vram_drain,
	output wire        l1_vram_busy,
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
	// m_vregs: bit 0 swaps the layers, bit 1 sprites above both, bit 2 blandia's effect
	input  wire  [7:0] vregs,
	// twineagl_tile_offset (layer 0)
	input  wire        tile_bank_en,
	input  wire [31:0] tile_bank,
	// set_tilemaps_flip(1) (oisipuzl): layers flip on sprite flip XOR this
	input  wire        tilemaps_flip,

	// CPU: sprite chip
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

	// CPU: palette
	input  wire        pal_we,
	// 12 bits: blandia's second window reaches 0xbff; 0x800 and up are dropped
	input  wire [11:0] pal_addr,
	input  wire [15:0] pal_wdata,
	input  wire        pal_uds, pal_lds,
	output wire [15:0] pal_rdata,

	// sprite ROM, one granule per row
	output wire        rom_req,
	output wire [23:3] rom_addr,
	input  wire        rom_valid,
	input  wire [63:0] rom_data,

	output logic [7:0] vga_r, vga_g, vga_b,
	output logic       vga_hs, vga_vs, vga_hb, vga_vb, vga_de,
	output logic       vga_ce,

	output wire        irq_vblank_line, irq_mid_line, vblank_rise,

	output wire [23:3] dbg_l0_last_addr,
	output wire [63:0] dbg_l0_last_data,
	// per frame: tile lines cut at the budget, row-cache hits
	output wire [15:0] dbg_l0_cut, dbg_l0_hits, dbg_l0_overrun,
	output wire [15:0] dbg_l1_cut, dbg_l1_hits, dbg_l1_overrun,
	output wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun,
	output wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped,
	output wire [63:0] dbg_snap
);

	localparam int PAW = $clog2(PAL_ENTRIES);

	wire [9:0] hcount, vcount;
	wire       hsync, vsync, hblank, vblank, de;
	wire       line_start;
	wire [8:0] line;

	// declared before the instance (ModelSim)
	wire snap_start, snap_pre;
	// spr_snap_line: a pulse as that line begins
	logic snap_at_line = 1'b0;
	always_ff @(posedge clk)
		snap_at_line <= line_start && spr_snap_line != 10'd0
		             && {1'b0, line} == spr_snap_line;

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
		.vblank_rise(vblank_rise), .snap_start(snap_start), .snap_pre(snap_pre)
	);

	logic  [8:0] lb_addr;
	wire [LB_W-1:0] lb_data;
	wire         lb_hit;
	wire         flipscr_l0;
	// visible height, for update_scroll
	wire   [8:0] vis_dimy = vact_end[8:0] - vact_start[8:0] + 9'd1;
	// Flipped tilemaps mirror about the 512x256 bitmap, not MAME's visible
	// area: see docs/MAME_DIVERGENCE.md.
	wire   [9:0] xextent  = 10'd512;
	wire   [8:0] yextent  = 9'd256;
	wire         flip_layers = flipscr_l0 ^ tilemaps_flip;

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
		.buffer_sprites(buffer_sprites), .copy_then_draw(copy_then_draw),
		.snap_at_line(snap_at_line),
		.vblank_rise(vblank_rise), .snap_pre(snap_pre),
		.snap_start(snap_start),
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
		.dbg_dropped(dbg_dropped), .dbg_snap(dbg_snap)
	);

	logic [PAW-1:0] pal_index;
	wire      [7:0] pr, pg, pb;

	seta_palette #(.ENTRIES(PAL_ENTRIES)) u_pal (
		.clk(clk),
		.cpu_we(pal_we && !pal_addr[11]), .cpu_addr(pal_addr[PAW-1:0]),
		.cpu_wdata(pal_wdata),
		.cpu_uds(pal_uds), .cpu_lds(pal_lds), .cpu_rdata(pal_rdata),
		.index(pal_index), .r(pr), .g(pg), .b(pb)
	);

	// Line buffers are indexed by screen x, hcount.
	logic hs_d, vs_d, hb_d, vb_d, de_d;

	always_ff @(posedge clk) begin
		vga_ce <= 1'b0;
		if (reset) begin
			de_d <= 1'b0;
		end else if (ce_pix) begin
			vga_r  <= de_d ? pr : 8'd0;
			vga_g  <= de_d ? pg : 8'd0;
			vga_b  <= de_d ? pb : 8'd0;
			vga_hs <= hs_d;  vga_vs <= vs_d;
			vga_hb <= hb_d;  vga_vb <= vb_d;
			vga_de <= de_d;
			vga_ce <= 1'b1;

			lb_addr <= hcount[8:0];
			hs_d <= hsync;  vs_d <= vsync;
			hb_d <= hblank; vb_d <= vblank;
			de_d <= de;
		end
	end

	// tile layers, on the sprite engine's line_start
	wire        l0_cmode, l1_cmode;   // vctrl[2] bit 4, per layer
	wire [LB_W-1:0] l0_lb_data;

	x1_012 #(.LB_W(LB_W)) u_l0 (
		.clk(clk), .reset(reset | ~has_l0),
		.vram_we(l0_vram_we), .vram_addr(l0_vram_addr),
		.vram_wdata(l0_vram_wdata), .vram_uds(l0_vram_uds),
		.vram_lds(l0_vram_lds), .vram_rdata(l0_vram_rdata),
		.vram_drain(l0_vram_drain), .vram_busy(l0_vram_busy),
		.vctrl_we(l0_ctrl_we), .vctrl_addr(l0_ctrl_addr),
		.vctrl_wdata(l0_ctrl_wdata), .vctrl_uds(l0_ctrl_uds),
		.vctrl_lds(l0_ctrl_lds), .vctrl_rdata(l0_ctrl_rdata),
		.cmode(l0_cmode),
		.xoffs(l0_xoffs), .xoffs_flip(l0_xoffs_flip),
		.flipscr(flip_layers), .xextent(xextent), .yextent(yextent),
		.vis_dimy(vis_dimy), .colorbase(l0_colorbase), .code_limit(l0_code_limit),
		.tile_bank_en(tile_bank_en), .tile_bank(tile_bank),
		.bpp6(l0_bpp6),
		.vblank_rise(vblank_rise),
		.line_start(line_start & has_l0), .line(line),
		.line_budget(line_budget), .cache_en(tile_cache_en),
		.line_done(), .busy(),
		.rom_req(tile_req), .rom_addr(tile_addr),
		.rom_valid(tile_valid), .rom_data(tile_data),
		.lb_addr(lb_addr), .lb_data(l0_lb_data),
		.dbg_cut(dbg_l0_cut), .dbg_hits(dbg_l0_hits),
		.dbg_overrun(dbg_l0_overrun),
		.dbg_last_addr(dbg_l0_last_addr), .dbg_last_data(dbg_l0_last_data)
	);

	wire [LB_W-1:0] l1_lb_data;

	x1_012 #(.LB_W(LB_W)) u_l1 (
		.clk(clk), .reset(reset | ~has_l1),
		.vram_we(l1_vram_we), .vram_addr(l1_vram_addr),
		.vram_wdata(l1_vram_wdata), .vram_uds(l1_vram_uds),
		.vram_lds(l1_vram_lds), .vram_rdata(l1_vram_rdata),
		.vram_drain(l1_vram_drain), .vram_busy(l1_vram_busy),
		.vctrl_we(l1_ctrl_we), .vctrl_addr(l1_ctrl_addr),
		.vctrl_wdata(l1_ctrl_wdata), .vctrl_uds(l1_ctrl_uds),
		.vctrl_lds(l1_ctrl_lds), .vctrl_rdata(l1_ctrl_rdata),
		.cmode(l1_cmode),
		.xoffs(l1_xoffs), .xoffs_flip(l1_xoffs_flip),
		.flipscr(flip_layers), .xextent(xextent), .yextent(yextent),
		.vis_dimy(vis_dimy), .colorbase(l1_colorbase), .code_limit(l1_code_limit),
		.tile_bank_en(1'b0), .tile_bank(32'd0),
		.bpp6(l1_bpp6),
		.vblank_rise(vblank_rise),
		.line_start(line_start & has_l1), .line(line),
		.line_budget(line_budget), .cache_en(tile_cache_en),
		.line_done(), .busy(),
		.rom_req(tile1_req), .rom_addr(tile1_addr),
		.rom_valid(tile1_valid), .rom_data(tile1_data),
		.lb_addr(lb_addr), .lb_data(l1_lb_data),
		.dbg_cut(dbg_l1_cut), .dbg_hits(dbg_l1_hits),
		.dbg_overrun(dbg_l1_overrun),
		.dbg_last_addr(), .dbg_last_data()
	);

	// One layer: layer 0 opaque, sprites over it where they wrote (lb_hit).
	// A debug-disabled layer reads as pen 0.
	wire [LB_W-1:0] l0_raw = en_l0 ? l0_lb_data : '0;
	wire [LB_W-1:0] l1_raw = en_l1 ? l1_lb_data : '0;

	// blandia's colour-mode bit (vctrl[2] bit 4) selects PAL_BLAND1.
	wire [2:0] l0_mode = (l0_pal_mode == PAL_BLAND0 && l0_cmode)
	                   ? PAL_BLAND1 : l0_pal_mode;
	wire [2:0] l1_mode = (l1_pal_mode == PAL_BLAND0 && l1_cmode)
	                   ? PAL_BLAND1 : l1_pal_mode;

	wire [LB_W-1:0] l0_px_d, l1_px_d;
	x1_011_index #(.LB_W(LB_W)) u_l0_pal (
		.mode(l0_mode), .bank(l0_pal_bank), .idx(l0_raw), .entry(l0_px_d));
	x1_011_index #(.LB_W(LB_W)) u_l1_pal (
		.mode(l1_mode), .bank(l1_pal_bank), .idx(l1_raw), .entry(l1_px_d));

	// transparency is the pen, before the palette remap
	wire l0_op = l0_bpp6 ? |l0_raw[5:0] : |l0_raw[3:0];
	wire l1_op = l1_bpp6 ? |l1_raw[5:0] : |l1_raw[3:0];

	wire [LB_W-1:0] mixed_1l = (has_l0 && !lb_hit) ? l0_px_d : lb_data;

	// Two layers (seta_layers_update): vregs bit 0 puts layer 1 at the
	// bottom, bit 1 draws the sprites before the top layer. The bottom layer
	// is opaque, the top transparent on pen 0. vregs is latched at vblank.
	logic [7:0] vregs_lat = '0;
	always_ff @(posedge clk) if (vblank_rise) vregs_lat <= vregs;
	wire            swap    = vregs_lat[0];

	// blandia's draw_tilemap_palette_effect: when vregs bit 2 is set and the
	// layers are not swapped, a layer-1 pixel of colour 31 shows the pixel
	// underneath looked up at 0x600 + its low nine bits (the pre-remap index).
	wire eff_on  = has_pal2 && vregs_lat[2] && !swap;
	wire l1_eff  = eff_on && (l1_raw[10:6] == 5'd31);
	wire [LB_W-1:0] under_raw = (vregs_lat[1] && lb_hit) ? lb_data : l0_raw;
	wire [LB_W-1:0] l1_px_e   = l1_eff
	        ? (11'h600 + {2'd0, under_raw[8:0]}) : l1_px_d;

	wire [LB_W-1:0] bot_px  = swap ? l1_px_d : l0_px_d;
	wire [LB_W-1:0] top_px  = swap ? l0_px_d : l1_px_e;
	wire            top_op  = swap ? l0_op   : l1_op;

	wire [LB_W-1:0] under_spr = top_op ? top_px : bot_px;
	wire [LB_W-1:0] mixed_2l  = vregs_lat[1]
	        // sprites go on before the top layer, so the top layer covers them
	        ? (top_op ? top_px : (lb_hit ? lb_data : bot_px))
	        // sprites go on last, over everything
	        : (lb_hit ? lb_data : under_spr);

	wire [LB_W-1:0] mixed = has_l1 ? mixed_2l : mixed_1l;

	// Palette RAM holds blandia's 3072 CPU entries; the video index never
	// exceeds 0x7ff.
	always_ff @(posedge clk) pal_index <= mixed[PAW-1:0];

endmodule

`default_nettype wire
