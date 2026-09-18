// Per-game constants for the downtown.cpp boards, selected by the .mra mod
// byte: the same outputs as seta_board_cfg.sv (seta_core picks this module
// under SETA_DOWNTOWN), plus the sub CPU's. Values from each set's
// machine_config and memory map in MAME's seta/downtown.cpp.

`default_nettype none

package downtown_game_pkg;
	typedef enum logic [4:0] {
		DT_DOWNTOWN  = 5'd0,
		DT_DOWNTOWN2 = 5'd1,
		DT_DOWNTOWNJ = 5'd2,
		DT_DOWNTOWNP = 5'd3,
		DT_TWINEAGL  = 5'd4,
		DT_METAFOX   = 5'd5,
		DT_ARBALEST  = 5'd6
	} dt_game_t;
endpackage

import downtown_game_pkg::*;

module downtown_board_cfg (
	input  wire  [4:0] game,

	output logic [4:0] map_board,
	output logic [4:0] cpu_div,
	output logic [22:0] gfx_half_words,
	output logic [15:0] code_mask,
	output logic [11:0] pal_entries,
	output logic [10:0] colorbase_fg,
	output logic [10:0] colorbase_bg,
	output logic  [2:0] irq_vbl_level,
	output logic        irq_vbl_hold,
	output logic  [2:0] irq_sl240_level,
	output logic  [2:0] irq_sl112_level,
	output logic        has_ack,
	output logic [23:1] ack_addr,
	output logic        has_ack2,
	output logic [23:1] ack2_addr,
	output logic  [2:0] ack2_level,
	output logic        ack_d0_low,
	output logic        ack_wr_only,
	output logic  [1:0] game_rot,
	output logic        has_l0, has_l1,
	output logic  [2:0] layout,
	output logic signed [8:0] l0_xoffs, l0_xoffs_flip,
	output logic [10:0] l0_colorbase,
	output logic [15:0] l0_code_limit,
	output logic signed [8:0] l1_xoffs, l1_xoffs_flip,
	output logic [10:0] l1_colorbase,
	output logic [15:0] l1_code_limit,
	output logic        l0_bpp6, l1_bpp6,
	output logic  [2:0] l0_pal_mode, l1_pal_mode,
	output logic        has_pal2,
	output logic [10:0] l0_pal_bank, l1_pal_bank,
	output logic        buffer_sprites,
	output logic        copy_then_draw,
	output logic  [9:0] spr_snap_line,
	output logic  [1:0] x1_bank_mode,
	output logic  [2:0] vregs_ofs,
	output logic        tilemaps_flip,
	output logic        narrow_320, short_224,
	output logic        gfx1_invert,
	output logic  [2:0] ack_level,
	output logic  [2:0] input_layout,
	output logic        has_prot,
	output logic        has_tl_prot,
	output logic [23:0] tl_prot_base,
	output logic [23:0] tl_prot_size,
	output logic [23:0] tl_prot_rd,
	output logic signed [8:0] fg_xoffs, fg_xoffs_flip, fg_yoffs, fg_yoffs_flip,
	output logic signed [8:0] bg_xoffs, bg_xoffs_flip, bg_yoffs, bg_yoffs_flip,
	output logic [12:0] bank_size,
	output logic  [8:0] spritelimit,
	output logic  [3:0] transpen,
	output logic  [8:0] screen_h,
	output logic [10:0] backdrop,
	output logic [15:0] line_budget,
	output logic  [9:0] htotal, hs_start, hs_end, hact_start, hact_end,
	output logic  [9:0] vtotal, vs_start, vs_end, vact_start, vact_end,

	// sub CPU: 0 downtown_sub_map, 1 twineagl_sub_map, 2 metafox_sub_map
	output logic  [1:0] sub_map,
	// ROM window entries: (sub region bytes - 0xc000) / 0x4000, 1 = unbanked
	output logic  [4:0] sub_bank_entries,
	// twineagl_tile_offset, used by every downtown_map set
	output logic        tile_bank_en,
	// downtown_protection_r (downtown), twineagl_200100 (twineagl),
	// metafox_protection_r (metafox)
	output logic  [1:0] dt_prot
);

	// ROT270 everywhere; one X1-012; xRGB_555 x 512 with no colour bases.
	// ROM sizes per set below.
	assign map_board       = 5'd18;       // BOARD_DOWNTOWN
	assign cpu_div         = 5'd12;       // 8 MHz
	assign pal_entries     = 12'd512;
	assign colorbase_fg    = 11'd0;
	assign colorbase_bg    = 11'd0;
	assign irq_vbl_hold    = 1'b0;        // ASSERT_LINE
	assign irq_sl240_level = 3'd0;
	assign irq_sl112_level = 3'd0;
	// ipl1_ack_w at 0x300000 clears level 2; twineagl_ctrl_w clears 1 and 3
	// (seta_core)
	assign has_ack         = 1'b1;
	assign ack_addr        = 23'h180000;
	assign ack_level       = 3'd2;
	assign has_ack2        = 1'b0;
	assign ack2_addr       = 23'h0;
	assign ack2_level      = 3'd0;
	assign ack_d0_low      = 1'b0;
	assign ack_wr_only     = 1'b1;
	assign game_rot        = 2'd2;
	assign has_l0          = 1'b1;
	assign has_l1          = 1'b0;
	assign layout          = 3'd6;        // LAYOUT_G
	assign l0_colorbase    = 11'd0;
	assign l1_xoffs        = 9'sd0;
	assign l1_xoffs_flip   = 9'sd0;
	assign l1_colorbase    = 11'd0;
	assign l1_code_limit   = 16'h0;
	assign l0_bpp6         = 1'b0;
	assign l1_bpp6         = 1'b0;
	assign l0_pal_mode     = 3'd0;
	assign l1_pal_mode     = 3'd0;
	assign has_pal2        = 1'b0;
	assign l0_pal_bank     = 11'd0;
	assign l1_pal_bank     = 11'd0;
	assign buffer_sprites  = 1'b0;        // no setac_eof on these boards
	assign copy_then_draw  = 1'b0;
	assign spr_snap_line   = 10'd0;
	assign x1_bank_mode    = 2'd0;
	assign vregs_ofs       = 3'd3;
	assign tilemaps_flip   = 1'b0;
	assign narrow_320      = 1'b0;
	assign gfx1_invert     = 1'b0;
	assign has_prot        = 1'b0;
	assign has_tl_prot     = 1'b0;
	assign tl_prot_base    = 24'h0;
	assign tl_prot_size    = 24'h0;
	assign tl_prot_rd      = 24'hFFFFFF;
	assign tile_bank_en    = 1'b1;

	// as seta_board_cfg.sv
	assign fg_yoffs      =  9'sd14;
	assign fg_yoffs_flip = short_224 ? -9'sd18 : -9'sd10;
	assign bg_xoffs      =  9'sd0;
	assign bg_xoffs_flip =  9'sd0;
	assign bg_yoffs      = -9'sd1;
	assign bg_yoffs_flip =  9'sd1;
	assign bank_size     = 13'h1000;
	assign spritelimit   = 9'h1ff;
	assign transpen      = 4'd0;
	assign screen_h      = 9'd256;
	assign backdrop      = 11'h1f0;
	assign line_budget   = 16'd6100;

	// 8 MHz, 512 dots. 272 lines = 57.44 Hz (downtown, twineagl: 57.42 in
	// MAME, "verified on pcb" for downtown); 264 lines = 59.19 Hz (metafox,
	// arbalest: MAME's 59.1845, Thundercade's PCB measurement).
	assign htotal     = 10'd512;
	assign hact_start = 10'd0;
	assign hact_end   = 10'd383;
	assign hs_start   = 10'd400;
	assign hs_end     = 10'd448;
	assign vact_start = short_224 ? 10'd16  : 10'd8;
	assign vact_end   = short_224 ? 10'd239 : 10'd247;
	assign vs_start   = 10'd250;
	assign vs_end     = 10'd253;

	always_comb begin
		sub_map       = 2'd0;
		input_layout  = 3'd1;                   // common_type2
		dt_prot       = 2'd0;
		irq_vbl_level = 3'd2;
		short_224     = 1'b0;
		vtotal        = 10'd272;
		l0_xoffs      = -9'sd1;  l0_xoffs_flip = 9'sd0;    // set_xoffsets(0, -1)
		fg_xoffs      = 9'sd1;   fg_xoffs_flip = 9'sd0;    // set_fg_xoffsets(0, 1)
		// downtown: sprites 2 MB (0x4000 codes a half), tiles 1 MB (0x2000
		// codes, 128 bytes each), sub region 0x4c000 (16 bank entries).
		// twineagl, metafox, arbalest: sprites 1 MB, tiles 2 MB, sub region
		// 0x10000 (machine_start: one entry at 0xc000 for every bank).
		gfx_half_words   = 23'h80000;
		code_mask        = 16'h3fff;
		l0_code_limit    = 16'h2000;
		sub_bank_entries = 5'd16;

		if (game == DT_TWINEAGL || game == DT_METAFOX || game == DT_ARBALEST) begin
			gfx_half_words   = 23'h40000;
			code_mask        = 16'h1fff;
			l0_code_limit    = 16'h4000;
			sub_bank_entries = 5'd1;
		end

		case (game)
			DT_DOWNTOWN, DT_DOWNTOWN2, DT_DOWNTOWNJ, DT_DOWNTOWNP: begin
				dt_prot = 2'd1;
			end
			DT_TWINEAGL: begin
				sub_map = 2'd1;
				input_layout = 3'd0;                // common_type1
				dt_prot = 2'd2;
				irq_vbl_level = 3'd3;
				l0_xoffs = 9'sd0;  l0_xoffs_flip = -9'sd3;     // (-3, 0)
				fg_xoffs = 9'sd0;  fg_xoffs_flip = 9'sd0;
			end
			DT_METAFOX: begin
				sub_map = 2'd2;
				dt_prot = 2'd3;
				irq_vbl_level = 3'd3;
				short_224 = 1'b1;
				vtotal = 10'd264;
				l0_xoffs = 9'sd16; l0_xoffs_flip = -9'sd19;    // (-19, 16)
				fg_xoffs = 9'sd0;  fg_xoffs_flip = 9'sd0;
			end
			DT_ARBALEST: begin
				sub_map = 2'd2;
				irq_vbl_level = 3'd3;
				short_224 = 1'b1;
				vtotal = 10'd264;
				l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd1;     // (-1, -2)
				fg_xoffs = 9'sd0;  fg_xoffs_flip = 9'sd1;      // (1, 0)
			end
			default: ;
		endcase
	end

endmodule

`default_nettype wire
