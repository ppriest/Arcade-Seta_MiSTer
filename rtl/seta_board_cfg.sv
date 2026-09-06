// Per-game constants, selected by the `.mra` mod byte.
//
// One index identifies the GAME, and everything the core needs follows from it
// -- including which of maincpu.sv's memory maps to use. The alternative, a mod
// byte that names the map and a second field for everything else, means two
// tables that can disagree; there is no case in this driver where two games
// share a map but differ in nothing else, so one index is enough.
//
// PHASE 1 ONLY. These eight are Group A: 68000 + X1-001 sprites + X1-010 sound
// and no X1-012 tilemap layers at all. The tilemap families get their entries
// when their RTL exists, sized against real games rather than reserved now.
//
// WHERE EACH FIELD COMES FROM, so it can be re-derived rather than trusted:
//
//   map board        rtl/cpu/maincpu.sv seta_board_pkg, and the `*_map`
//                    function each arm names
//   cpu divider      the M68000() clock in each machine_config: 16 MHz for
//                    umanclub/neobattl/atehate, 16_MHz_XTAL/2 for the rest
//   gfx1 size        scripts/build_region.py <set> --list, which reads the
//                    driver's ROM_REGION directly
//   code_mask        gfx_element wraps a code past the end of the region:
//                    elements = (gfx1/2) / 64 bytes per tile, and every
//                    in-scope region is a power of two, so it is a mask
//   gfx_half_words   gfx1 / 4 -- 16-bit words in one RGN_FRAC half, which is
//                    what rtl/memory/gfx_swizzle.sv needs
//   palette entries  PALETTE(...).set_entries() in each machine_config
//   colour base      the GFXDECODE_ENTRY base: 0 for gfx_sprites, 0x200 for
//                    gfx_pairlove
//   interrupts       each machine_config's scantimer or screen_vblank(), and
//                    the ack address in the `*_map`. See rtl/cpu/seta_irq.sv
//                    for why HOLD and ASSERT are not interchangeable, and for
//                    the pin-versus-level naming trap in seta.cpp's ack
//                    function names.
//
// The sprite kludges and the screen geometry are the same for all eight, so
// they are constants below rather than table columns -- every Group A
// machine_config calls set_fg_xoffsets(0, 0), set_fg_yoffsets(-0x12, 0x0e),
// set_bg_yoffsets(0x1, -0x1) and set_visarea(0*8, 48*8-1, 1*8, 31*8-1).

`default_nettype none

package seta_game_pkg;
	typedef enum logic [3:0] {
		GAME_THUNDERL  = 4'd0,
		GAME_THUNDERLA = 4'd1,
		GAME_WITS      = 4'd2,
		GAME_BLOCKCAR  = 4'd3,
		GAME_UMANCLUB  = 4'd4,
		GAME_NEOBATTL  = 4'd5,
		GAME_ATEHATE   = 4'd6,
		GAME_PAIRLOVE  = 4'd7
	} game_t;
endpackage

import seta_game_pkg::*;

module seta_board_cfg (
	input  wire  [3:0] game,

	// ---- which memory map maincpu.sv should use -----------------------------
	output logic [3:0] map_board,

	// ---- clock enables -------------------------------------------------------
	// clk_sys / cpu_div = the 68000 clock. 96 / 6 = 16 MHz, 96 / 12 = 8 MHz.
	output logic [4:0] cpu_div,

	// ---- sprite graphics ------------------------------------------------------
	output logic [22:0] gfx_half_words,
	output logic [15:0] code_mask,

	// ---- palette --------------------------------------------------------------
	output logic [11:0] pal_entries,
	output logic [10:0] colorbase_fg,
	output logic [10:0] colorbase_bg,

	// ---- interrupts -----------------------------------------------------------
	// Level 0 means "this source is not wired on this board".
	output logic  [2:0] irq_vbl_level,    // screen_vblank()
	output logic        irq_vbl_hold,     // 1 = HOLD_LINE, 0 = ASSERT_LINE
	output logic  [2:0] irq_sl240_level,  // seta_interrupt_1_and_2, scanline 240
	output logic  [2:0] irq_sl112_level,  // ...and scanline 112
	// Both scanline sources are HOLD_LINE wherever they are used, so there is
	// no per-source flag for them -- seta_interrupt_1_and_2 is the only user
	// and it passes HOLD_LINE for both.
	output logic        has_ack,          // an explicit ack address exists
	output logic [23:1] ack_addr,
	output logic  [2:0] ack_level,

	// ---- extras ---------------------------------------------------------------
	output logic        has_prot,         // pairlove's one-deep write history
	// thunderl's protection register: a write ANYWHERE in a 128 KB window
	// latches a value derived from the address, and one read address returns
	// it. See rtl/seta_prot_thunderl.sv.
	output logic        has_tl_prot,
	output logic [23:0] tl_prot_base,     // start of the write window
	output logic [23:0] tl_prot_size,
	output logic [23:0] tl_prot_rd,       // the byte address that reads it back

	// ---- constants, the same for every Group A board --------------------------
	output logic signed [8:0] fg_xoffs, fg_xoffs_flip, fg_yoffs, fg_yoffs_flip,
	output logic signed [8:0] bg_xoffs, bg_xoffs_flip, bg_yoffs, bg_yoffs_flip,
	output logic [12:0] bank_size,
	output logic  [8:0] spritelimit,
	output logic  [3:0] transpen,
	output logic  [8:0] screen_h,
	output logic [10:0] backdrop,
	output logic [15:0] line_budget,
	output logic  [9:0] htotal, hs_start, hs_end, hact_start, hact_end,
	output logic  [9:0] vtotal, vs_start, vs_end, vact_start, vact_end
);

	// set_fg_xoffsets(flip, noflip) and friends, from every Group A
	// machine_config. The flipped values are transcribed and are checked only
	// against scripts/x1_001_model.py -- no captured frame has flip screen set.
	assign fg_xoffs      =  9'sd0;
	assign fg_xoffs_flip =  9'sd0;
	assign fg_yoffs      =  9'sd14;      //  0x0e
	assign fg_yoffs_flip = -9'sd18;      // -0x12
	assign bg_xoffs      =  9'sd0;
	assign bg_xoffs_flip =  9'sd0;
	assign bg_yoffs      = -9'sd1;
	assign bg_yoffs_flip =  9'sd1;

	// draw_sprites(..., 0x1000) in screen_update_seta_no_layers; m_spritelimit
	// and m_transpen are device defaults, which no in-scope machine_config
	// overrides; screen.height() is 256, NOT the 240 visible; and
	// screen_update_seta_no_layers fills with pen 0x1f0 before drawing.
	assign bank_size   = 13'h1000;
	assign spritelimit = 9'h1ff;
	assign transpen    = 4'd0;
	assign screen_h    = 9'd256;
	assign backdrop    = 11'h1f0;

	// Screen timing. EVERY NUMBER IS A HYPOTHESIS -- see
	// rtl/video/seta_video_timing.sv's header and docs/ROADMAP.md. MAME has no
	// raw timings for this hardware; 8 MHz dot clock and htotal 512 are
	// inferred from the XTAL, and vtotal 260 is what reproduces the 60 Hz every
	// Group A machine_config declares. The sync positions inside the blanking
	// are plausible and self-consistent, not measured.
	assign htotal     = 10'd512;
	assign hact_start = 10'd0;
	assign hact_end   = 10'd383;
	assign hs_start   = 10'd400;
	assign hs_end     = 10'd448;
	assign vtotal     = 10'd260;
	assign vact_start = 10'd8;
	assign vact_end   = 10'd247;
	assign vs_start   = 10'd250;
	assign vs_end     = 10'd253;

	// The sprite engine's per-line cutoff, JUST BELOW the line period rather
	// than at it: at exactly 512 * 12 = 6144 the cutoff races the buffer swap
	// and the engine restarts mid-render instead of stopping cleanly. Measured
	// over 48 frames, 6100 gives zero overruns and identical output.
	assign line_budget = 16'd6100;

	always_comb begin
		// Defaults are thunderl's, so a missing arm is a plausible board rather
		// than an X -- and the assertion below names it in simulation.
		map_board       = 4'd8;
		cpu_div         = 5'd12;
		gfx_half_words  = 23'h20000;
		code_mask       = 16'h0fff;
		pal_entries     = 12'd512;
		colorbase_fg    = 11'd0;
		colorbase_bg    = 11'd0;
		irq_vbl_level   = 3'd0;
		irq_vbl_hold    = 1'b0;
		irq_sl240_level = 3'd0;
		irq_sl112_level = 3'd0;
		has_ack         = 1'b0;
		ack_addr        = 23'h000000;
		ack_level       = 3'd0;
		has_prot        = 1'b0;
		has_tl_prot     = 1'b0;
		tl_prot_base    = 24'h000000;
		tl_prot_size    = 24'h000000;
		tl_prot_rd      = 24'hFFFFFF;

		case (game)
		// thunderl / thunderla: 8 MHz, 0.5 MB sprites, vblank asserts IPL 2 and
		// stays asserted until ipl1_ack_w at 0x200000 -- which clears LEVEL 2,
		// not level 1; seta.cpp names those functions by PIN.
		GAME_THUNDERL, GAME_THUNDERLA: begin
			map_board = 4'd8;  cpu_div = 5'd12;
			gfx_half_words = 23'h20000;  code_mask = 16'h0fff;
			irq_vbl_level = 3'd2; irq_vbl_hold = 1'b0;
			has_ack = 1'b1; ack_addr = 23'h100000; ack_level = 3'd2;
			// thunderl_map: the protection WRITE window is 0x400000-0x41ffff
			// and the READ is at 0xb0000c -- which is four words above the
			// COINS port and outside maincpu.sv's inputs decode, so
			// seta_core.sv catches it off the io address directly.
			has_tl_prot  = 1'b1;
			tl_prot_base = 24'h400000;
			tl_prot_size = 24'h020000;
			tl_prot_rd   = 24'hB0000C;
		end

		GAME_WITS: begin
			map_board = 4'd9;  cpu_div = 5'd12;
			gfx_half_words = 23'h20000;  code_mask = 16'h0fff;
			irq_vbl_level = 3'd2; irq_vbl_hold = 1'b0;
			has_ack = 1'b1; ack_addr = 23'h100000; ack_level = 3'd2;
		end

		// blockcar: 8 MHz, and its vblank asserts IPL 3 with NO ack mapped
		// anywhere. MAME's three-argument set_inputline never clears on the
		// falling edge, so the request stays pending for good and the game
		// masks it in SR instead. Reproduced, not tidied.
		GAME_BLOCKCAR: begin
			map_board = 4'd11; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b0;
		end

		// umanclub / neobattl: 16 MHz, vblank HOLD_LINE at IPL 3.
		GAME_UMANCLUB, GAME_NEOBATTL: begin
			map_board = 4'd10; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b1;
		end

		// atehate: 16 MHz, 2 MB of sprites, seta_interrupt_1_and_2.
		GAME_ATEHATE: begin
			map_board = 4'd12; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// pairlove: 8 MHz, 2048 palette entries with the sprites based at
		// 0x200, seta_interrupt_1_and_2, and the 0x900000 write-history block
		// seta.cpp calls protection.
		GAME_PAIRLOVE: begin
			map_board = 4'd13; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			pal_entries = 12'd2048;
			colorbase_fg = 11'h200; colorbase_bg = 11'h200;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			has_prot = 1'b1;
		end

		default: ;
		endcase
	end

// synthesis translate_off
	initial begin
		if (game > GAME_PAIRLOVE)
			$display("seta_board_cfg: game=%0d has no entry; thunderl's is being used",
			         game);
	end
// synthesis translate_on

endmodule

`default_nettype wire
