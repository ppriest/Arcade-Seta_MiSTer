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
		GAME_PAIRLOVE  = 4'd7,
		// ---- Group B, one 4bpp tilemap layer ----
		GAME_DRGNUNIT  = 4'd8,
		GAME_STG       = 4'd9,
		GAME_QZKKLOGY  = 4'd10,
		GAME_QZKKLGY2  = 4'd11
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
	// blockcar alone acknowledges on a DATA CONDITION rather than on the
	// write itself: blockcar_interrupt_w clears level 3 only when bit 0 of
	// the byte written is LOW. Off everywhere else, so no other board's
	// acknowledge behaviour changes.
	output logic        ack_d0_low,
	// The driver's own ROT for this set: 0 = ROT0, 1 = ROT90, 2 = ROT270.
	// Only the OSD's Auto rotation setting reads it. Nothing in the
	// rendering path is orientation-aware: the core always draws the board's
	// native raster and rotation is a framebuffer tap.
	output logic  [1:0] game_rot,

	// ---- Phase 2, the X1-012 tile layer ------------------------------------
	// Every Group A set leaves has_l0 low, which holds the layer in reset and
	// leaves the mixer taking the sprite buffer alone -- so adding this cannot
	// change a Group A picture. layout_b picks the SDRAM map that has a gfx2
	// region in it.
	output logic        has_l0,
	output logic        layout_b,
	output logic signed [8:0] l0_xoffs, l0_xoffs_flip,
	output logic [10:0] l0_colorbase,
	output logic [15:0] l0_code_mask,
	// screen_vblank_seta_buffer_sprites -> x1_001_device::setac_eof. NO GROUP A
	// GAME WIRES IT; every Group B set does, and qzkklogy and qzkklgy2 have
	// spritectrl bit 5 clear, so the copy actually runs on them every frame.
	output logic        buffer_sprites,
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

	// set_fg_yoffsets(flip, noflip) and friends. Every Group A AND Group B
	// machine_config uses these same y and bg values -- drgnunit's are
	// set_fg_yoffsets(-0x12, 0x0e) and set_bg_yoffsets(0x1, -0x1), identical to
	// thunderl's. The flipped values are transcribed and checked only against
	// scripts/x1_001_model.py; no captured frame has flip screen set.
	//
	// fg_xoffs is NOT here: it is the one of the eight that varies per game,
	// and Group B is the first family to move it. It lives in the case block.
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

	// Screen timing. MAME has no raw timings for this hardware: 8 MHz dot clock
	// and htotal 512 are inferred from the XTAL, and the sync positions inside
	// the blanking are plausible and self-consistent rather than measured.
	//
	// VTOTAL 272 GIVES 57.4449 Hz, WHICH IS DAIOH'S -- and daioh's is the only
	// refresh rate in seta.cpp that anyone measured. Counting what the driver
	// actually declares across all 33 machine_configs:
	//
	//     60        x28, every one of them a bare number with NO COMMENT
	//     57.42          "verified on PCB"          <- daioh
	//     57.42          "approximation from PCB video"
	//     57.42          "taken from other games but seems to better match
	//                     PCB videos"
	//     56.66          "between 56 and 57 to match a real PCB's game speed"
	//     59.1851        (crazyfgt, no comment, not Seta hardware)
	//
	// Every number that came from looking at a real board is between 56.66 and
	// 57.42. Every 60 is uncommented -- a nominal value, not a measurement. So
	// vtotal 260, chosen here originally to reproduce that 60, was reproducing
	// a placeholder to four significant figures.
	//
	// The geometry backs it up: daioh declares the SAME set_size(64*8, 32*8)
	// and the SAME set_visarea as every Group A game, on the same 16 MHz X1-001.
	// Nothing in the driver suggests these boards differed in video timing --
	// only in what someone typed for the refresh rate.
	//
	// 512 x 272 at 8 MHz = 57.4449 Hz, 0.043% from the verified 57.42, on the
	// same htotal as before. The active area is untouched, so every frame this
	// core has been diffed against MAME is unaffected; what changes is the
	// number of blanked lines after it, and therefore the refresh rate.
	//
	// Still a hypothesis in the details -- but now one anchored to the single
	// measurement that exists, instead of to a default.
	assign htotal     = 10'd512;
	assign hact_start = 10'd0;
	assign hact_end   = 10'd383;
	assign hs_start   = 10'd400;
	assign hs_end     = 10'd448;
	assign vtotal     = 10'd272;
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
		fg_xoffs        = 9'sd0;
		fg_xoffs_flip   = 9'sd0;
		buffer_sprites  = 1'b0;
		irq_sl112_level = 3'd0;
		has_ack         = 1'b0;
		ack_addr        = 23'h000000;
		ack_d0_low      = 1'b0;
		game_rot        = 2'd2;   // thunderl's ROT270, with the other defaults
		has_l0          = 1'b0;
		layout_b        = 1'b0;
		l0_xoffs        = 9'sd0;
		l0_xoffs_flip   = 9'sd0;
		l0_colorbase    = 11'd0;
		l0_code_mask    = 16'h1fff;
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
			game_rot = 2'd0;   // ROT0
			map_board = 4'd9;  cpu_div = 5'd12;
			gfx_half_words = 23'h20000;  code_mask = 16'h0fff;
			irq_vbl_level = 3'd2; irq_vbl_hold = 1'b0;
			has_ack = 1'b1; ack_addr = 23'h100000; ack_level = 3'd2;
		end

		// blockcar: 8 MHz, and its vblank asserts IPL 3 with NO ack mapped
		// anywhere. MAME's three-argument set_inputline never clears on the
		// blockcar: vblank asserts IPL 3 with ASSERT_LINE, and it IS
		// acknowledged -- blockcar_interrupt_w, mapped at byte 0x200001:
		//
		//     void seta_state::blockcar_interrupt_w(u8 data)
		//     {
		//         // ? 0/1 (IRQ acknowledge?)
		//         if (!BIT(data, 0))
		//             m_maincpu->set_input_line(3, CLEAR_LINE);
		//     }
		//
		// This was recorded here, and in docs/ROADMAP.md's list of behaviour
		// followed from MAME, as "no acknowledge is mapped anywhere, so the
		// request stays pending for good and the game masks it in SR instead".
		// That was wrong: the handler above is the acknowledge, and without it
		// the CPU re-enters the level 3 handler forever and the game cannot
		// reach its main loop. On hardware that looked like a game that draws
		// something and then does nothing useful.
		//
		// Byte 0x200001 is word 0x200000, which is 23'h100000 on a [23:1] bus
		// -- the same value thunderl uses for its own, different, acknowledge.
		GAME_BLOCKCAR: begin
			game_rot = 2'd1;   // ROT90
			map_board = 4'd11; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b0;
			has_ack = 1'b1; ack_addr = 23'h100000; ack_level = 3'd3;
			ack_d0_low = 1'b1;
		end

		// umanclub / neobattl: 16 MHz, vblank HOLD_LINE at IPL 3.
		// umanclub is ROT0 and neobattl ROT270: the two share a board and a
		// machine_config but NOT an orientation.
		GAME_UMANCLUB, GAME_NEOBATTL: begin
			game_rot = (game == GAME_NEOBATTL) ? 2'd2 : 2'd0;
			map_board = 4'd10; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b1;
		end

		// =================================================================
		// GROUP B -- drgnunit_map, one X1-012 layer. All four run the drgnunit
		// machine_config and then override; the overrides are the whole
		// difference between them, and in Phase 2's model assuming they were
		// absent cost 0.3% to 26% of the pixels on six of nine frames.
		//
		// Sprite offsets are set_fg_xoffsets, layer offsets set_xoffsets, both
		// (flip, noflip). Every one of the four is 8 MHz except qzkklgy2.
		// =================================================================
		GAME_DRGNUNIT: begin                 // ROT0
			map_board = 4'd7; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; layout_b = 1'b1;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l0_code_mask = 16'h1fff;
			fg_xoffs = 9'sd2;  fg_xoffs_flip = 9'sd2;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		GAME_STG: begin                      // ROT270, set_fg_xoffsets(0, 0)
			map_board = 4'd7; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; layout_b = 1'b1;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l0_code_mask = 16'h1fff;
			fg_xoffs = 9'sd0;  fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		GAME_QZKKLOGY: begin                 // ROT0, (1,1) and (-1,-1)
			map_board = 4'd7; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; layout_b = 1'b1;
			l0_xoffs = -9'sd1; l0_xoffs_flip = -9'sd1;
			l0_code_mask = 16'h1fff;
			fg_xoffs = 9'sd1;  fg_xoffs_flip = 9'sd1;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		// qzkklgy2 is the odd one twice over: a 16 MHz CPU, and 2 MB of tiles
		// where its three siblings have 1 MB -- which is why LAYOUT_B's gfx2
		// region is 2 MB and x1snd sits above it.
		GAME_QZKKLGY2: begin                 // ROT0, (0,0) and (-3,-1)
			map_board = 4'd7; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; layout_b = 1'b1;
			l0_xoffs = -9'sd3; l0_xoffs_flip = -9'sd1;
			l0_code_mask = 16'h3fff;
			fg_xoffs = 9'sd0;  fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		// atehate: 16 MHz, 2 MB of sprites, seta_interrupt_1_and_2.
		GAME_ATEHATE: begin
			game_rot = 2'd0;   // ROT0
			map_board = 4'd12; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// pairlove: 8 MHz, 2048 palette entries with the sprites based at
		// 0x200, seta_interrupt_1_and_2, and the 0x900000 write-history block
		// seta.cpp calls protection.
		GAME_PAIRLOVE: begin
			game_rot = 2'd2;   // ROT270
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
