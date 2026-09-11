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
	typedef enum logic [4:0] {
		GAME_THUNDERL  = 5'd0,
		GAME_THUNDERLA = 5'd1,
		GAME_WITS      = 5'd2,
		GAME_BLOCKCAR  = 5'd3,
		GAME_UMANCLUB  = 5'd4,
		GAME_NEOBATTL  = 5'd5,
		GAME_ATEHATE   = 5'd6,
		GAME_PAIRLOVE  = 5'd7,
		// ---- Group B, one 4bpp tilemap layer ----
		GAME_DRGNUNIT  = 5'd8,
		GAME_STG       = 5'd9,
		GAME_QZKKLOGY  = 5'd10,
		GAME_QZKKLGY2  = 5'd11,
		// ---- Group C, two 4bpp tilemap layers ----
		GAME_DAIOH     = 5'd12,
		GAME_REZON     = 5'd13,
		GAME_WROFAERO  = 5'd14,
		GAME_MSGUNDAM  = 5'd15,
		GAME_EIGHTFRC  = 5'd16,
		GAME_OISIPUZL  = 5'd17,
		GAME_KAMENRID  = 5'd18,
		GAME_MAGSPEED  = 5'd19,
		// ---- Group D, 6bpp tile layers ----
		GAME_GUNDHARA  = 5'd20,
		GAME_ZINGZIP   = 5'd21,
		GAME_JJSQUAWK  = 5'd22,
		GAME_EXTDWNHL  = 5'd23,
		GAME_SOKONUKE  = 5'd24,
		GAME_MADSHARK  = 5'd25,
		GAME_BLANDIA   = 5'd26,
		GAME_BLANDIAP  = 5'd27
	} game_t;
endpackage

import seta_game_pkg::*;

module seta_board_cfg (
	// FIVE BITS. Group A is eight games, B four and C eight; the driver has
	// 43 sets in scope, so four bits was never going to reach the end.
	input  wire  [4:0] game,

	// ---- which memory map maincpu.sv should use -----------------------------
	output logic [4:0] map_board,

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
	// A SECOND acknowledge. kamenrid, magspeed and msgundam each map two --
	// ipl1_ack_w and ipl2_ack_w, clearing levels 2 and 4 -- and with only
	// one decoded the other level stays asserted for ever.
	output logic        has_ack2,
	output logic [23:1] ack2_addr,
	output logic  [2:0] ack2_level,
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
	output logic        has_l0, has_l1,
	// 0 = LAYOUT_A, 1 = LAYOUT_B, 2 = LAYOUT_C.
	// 0 = LAYOUT_A ... 4 = LAYOUT_E. THREE bits: the 6bpp sets added two
	// more maps, and gundhara's 8 MB of sprites needs one of its own.
	output logic  [2:0] layout,
	output logic signed [8:0] l0_xoffs, l0_xoffs_flip,
	output logic [10:0] l0_colorbase,
	output logic [15:0] l0_code_limit,
	output logic signed [8:0] l1_xoffs, l1_xoffs_flip,
	output logic [10:0] l1_colorbase,
	output logic [15:0] l1_code_limit,
	// layout_tilemap_6bpp per layer. zingzip and extdwnhl decode layer 1 at
	// 6bpp and layer 2 at 4bpp; gundhara, jjsquawk and madshark use 6bpp for
	// both. Phase 4.
	output logic        l0_bpp6, l1_bpp6,
	// Palette address formation per layer -- rtl/video/x1_011_index.sv.
	// 0 direct (every 4bpp game), 1 masked (gundhara, zingzip), 2 plain
	// (jjsquawk, madshark). The bank is the 512-entry block the layer lands
	// in, which is NOT the GFXDECODE base the engine would have added.
	output logic  [2:0] l0_pal_mode, l1_pal_mode,
	// blandia's second palette RAM and the effect that reads it.
	output logic        has_pal2,
	output logic [10:0] l0_pal_bank, l1_pal_bank,
	// screen_vblank_seta_buffer_sprites -> x1_001_device::setac_eof. NO GROUP A
	// GAME WIRES IT; every Group B set does, and qzkklogy and qzkklgy2 have
	// spritectrl bit 5 clear, so the copy actually runs on them every frame.
	output logic        buffer_sprites,
	// set_addrmap(0, blandia_x1_map): the X1-010's top quarter is a bank
	// window. blandia, eightfrc and zombraid only.
	output logic        has_x1_bank,
	// seta_vregs_w's BYTE offset inside the vregs region. It is not the same
	// on every board -- 0x500003 on rezon and oisipuzl, 0x500005 on msgundam,
	// 0x600003 on kamenrid -- and the neighbouring bytes are other registers,
	// so accepting any write in the region would set the layer order from a
	// coin-lockout write.
	output logic  [2:0] vregs_ofs,
	// set_tilemaps_flip(1): seta_layers_update computes the layers' flip as
	// m_spritegen->is_flipped() ^ m_tilemaps_flip, so on oisipuzl the sprites
	// flip and the layers do not.
	output logic        tilemaps_flip,
	// set_visarea: 320 wide on oisipuzl, 224 lines on it and eightfrc.
	output logic        narrow_320, short_224,
	// ROMREGION_INVERT on "gfx1". MAME inverts every byte of the region after
	// loading; a .mra ships the ROM as dumped, so the core does it on the way
	// into SDRAM. oisipuzl is the only set in scope with it.
	output logic        gfx1_invert,
	output logic  [2:0] ack_level,

	// ---- extras ---------------------------------------------------------------
	// HOW THE P1/P2 WORD IS PUT TOGETHER. seta.cpp has three joystick macros
	// and three one-off panels among the sets in scope, and Seta.sv assembles
	// the word from this code:
	//
	//   0 JOY2    JOY_TYPE1_2BUTTONS -- LRUD at 0-3, B1 B2 at 4-5
	//   1 JOY1    JOY_TYPE1_1BUTTON  -- B1 only; 5 and 6 read as unpressed
	//   2 JOY3    JOY_TYPE1_3BUTTONS -- BUTTON3 at bit 6, which was tied low
	//   3 PANEL4  four answer buttons at 0-3, in the order B3 B4 B1 B2
	//   4 PANEL5  PANEL4 plus BUTTON5 at bit 4 (qzkklogy's pause cheat)
	//   5 CARDS   magspeed: Card 1-4 at 0-3, B1 B2 at 4-5
	//
	// Bit 7 is START in every one of them.
	output logic  [2:0] input_layout,
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
	assign transpen    = 5'd0;
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
	// THE VISIBLE AREA IS PER GAME. Most sets are 384x240 -- set_visarea(0,
	// 48*8-1, 1*8, 31*8-1) -- but eightfrc is 384x224 and oisipuzl 320x224.
	// The rest of the timing is the same hypothesis for all of them.
	assign hact_end   = narrow_320 ? 10'd319 : 10'd383;
	assign hs_start   = 10'd400;
	assign hs_end     = 10'd448;
	assign vtotal     = 10'd272;
	assign vact_start = short_224 ? 10'd16  : 10'd8;
	assign vact_end   = short_224 ? 10'd239 : 10'd247;
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
		map_board       = 5'd8;
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
		input_layout    = 3'd0;   // JOY_TYPE1_2BUTTONS
		has_x1_bank     = 1'b0;
		vregs_ofs       = 3'd3;
		tilemaps_flip   = 1'b0;
		narrow_320      = 1'b0;
		short_224       = 1'b0;
		gfx1_invert     = 1'b0;
		irq_sl112_level = 3'd0;
		has_ack         = 1'b0;
		ack_addr        = 23'h000000;
		has_ack2        = 1'b0;
		ack2_addr       = 23'h000000;
		ack2_level      = 3'd0;
		ack_d0_low      = 1'b0;
		game_rot        = 2'd2;   // thunderl's ROT270, with the other defaults
		has_l0          = 1'b0;
		has_l1          = 1'b0;
		layout          = 3'd0;
		l0_bpp6         = 1'b0;   l1_bpp6 = 1'b0;
		l0_pal_mode     = 3'd0;   l1_pal_mode = 3'd0;
		has_pal2        = 1'b0;
		l0_pal_bank     = 11'd0;  l1_pal_bank = 11'd0;
		l1_xoffs        = 9'sd0;
		l1_xoffs_flip   = 9'sd0;
		l1_colorbase    = 11'd0;
		l1_code_limit     = 16'h2000;
		l0_xoffs        = 9'sd0;
		l0_xoffs_flip   = 9'sd0;
		l0_colorbase    = 11'd0;
		l0_code_limit     = 16'h2000;
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
			map_board = 5'd8;  cpu_div = 5'd12;
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
			map_board = 5'd9;  cpu_div = 5'd12;
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
			map_board = 5'd11; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b0;
			has_ack = 1'b1; ack_addr = 23'h100000; ack_level = 3'd3;
			ack_d0_low = 1'b1;
		end

		// umanclub / neobattl: 16 MHz, vblank HOLD_LINE at IPL 3.
		// umanclub is ROT0 and neobattl ROT270: the two share a board and a
		// machine_config but NOT an orientation.
		GAME_UMANCLUB, GAME_NEOBATTL: begin
			if (game == GAME_NEOBATTL) input_layout = 3'd1;  // one button
			game_rot = (game == GAME_NEOBATTL) ? 2'd2 : 2'd0;
			map_board = 5'd10; cpu_div = 5'd6;
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
			input_layout = 3'd2;   // JOY_TYPE1_3BUTTONS
			map_board = 5'd7; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; layout = 3'd1;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l0_code_limit  = 16'h2000;
			fg_xoffs = 9'sd2;  fg_xoffs_flip = 9'sd2;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		GAME_STG: begin                      // ROT270, set_fg_xoffsets(0, 0)
			input_layout = 3'd2;
			map_board = 5'd7; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; layout = 3'd1;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l0_code_limit  = 16'h2000;
			fg_xoffs = 9'sd0;  fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		GAME_QZKKLOGY: begin                 // ROT0, (1,1) and (-1,-1)
			input_layout = 3'd4;   // four answers plus the pause cheat
			map_board = 5'd7; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; layout = 3'd1;
			l0_xoffs = -9'sd1; l0_xoffs_flip = -9'sd1;
			l0_code_limit  = 16'h2000;
			fg_xoffs = 9'sd1;  fg_xoffs_flip = 9'sd1;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		// qzkklgy2 is the odd one twice over: a 16 MHz CPU, and 2 MB of tiles
		// where its three siblings have 1 MB -- which is why LAYOUT_B's gfx2
		// region is 2 MB and x1snd sits above it.
		GAME_QZKKLGY2: begin                 // ROT0, (0,0) and (-3,-1)
			input_layout = 3'd3;   // qzkklogy without BUTTON5
			map_board = 5'd7; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; layout = 3'd1;
			l0_xoffs = -9'sd3; l0_xoffs_flip = -9'sd1;
			l0_code_limit  = 16'h4000;
			fg_xoffs = 9'sd0;  fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		// =================================================================
		// GROUP C -- two X1-012 layers, the X1-011 order register, a palette
		// split three ways (sprites 0, layer 0 0x400, layer 1 0x200 of 512*3).
		// =================================================================
		// daioh: 16 MHz verified from PCB, 2 MB each of sprites and both tile
		// regions. Both layers set_xoffsets(-2, -2).
		GAME_DAIOH: begin
			input_layout = 3'd2;
			map_board = 5'd1; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd2; l1_xoffs_flip = -9'sd2;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h4000; l1_code_limit  = 16'h4000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// rezon: 1 MB of sprites, 0.5 MB per tile region.
		GAME_REZON: begin
			input_layout = 3'd2;
			map_board = 5'd0; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd2; l1_xoffs_flip = -9'sd2;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h1000; l1_code_limit  = 16'h1000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// wrofaero DOES NOT CALL set_xoffsets, so both layers keep the device
		// default {0, 0}. Assuming daioh's cost 5.54% of the pixels in the
		// model before it was checked.
		// wrofaero: the PIT drives IPL 4 and ipl2_ack_w at 0xf00000 clears it.
		// Byte 0xf00000 is word 0xf00000, so 23'h780000 on a [23:1] bus.
		// =================================================================
		// GROUP D -- 6bpp tile layers.
		// =================================================================
		GAME_GUNDHARA: begin
			input_layout = 3'd2;     // JOY_TYPE1_3BUTTONS
			has_ack = 1'b1; ack_addr = 23'h780000; ack_level = 3'd4;
			map_board = 5'd0; cpu_div = 5'd6;       // wrofaero_map, 16 MHz
			// 8 MB of sprites, the largest in the driver: LAYOUT_E exists for
			// this one set.
			gfx_half_words = 23'h200000;  code_mask = 16'hffff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd4;
			l0_bpp6 = 1'b1; l1_bpp6 = 1'b1;
			l0_xoffs = 9'sd0; l0_xoffs_flip = 9'sd0;
			l1_xoffs = 9'sd0; l1_xoffs_flip = 9'sd0;
			// No base: a 6bpp layer's pixel leaves the engine as {color, pen}
			// and x1_011_index forms the palette address.
			l0_colorbase = 11'd0; l1_colorbase = 11'd0;
			l0_pal_mode = 3'd1; l1_pal_mode = 3'd1;     // masked
			l0_pal_bank = 11'h400; l1_pal_bank = 11'h200;
			// 192 bytes a tile: gfx2 is 0x2000 of them, gfx3 0x4000.
			l0_code_limit  = 16'h2000; l1_code_limit  = 16'h4000;
			pal_entries = 12'd1536;    // 0x600 of palette RAM
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// zingzip_map, 16 MHz, and the only Phase 4 set whose interrupt is a
		// vblank rather than the scanline timer: screen_vblank -> level 3,
		// HOLD_LINE. Layer 1 is 6bpp and layer 2 is 4bpp.
		GAME_ZINGZIP: begin
			input_layout = 3'd0;
			map_board = 5'd0; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd3;
			l0_bpp6 = 1'b1;                 // layer 2 stays 4bpp
			// set_xoffsets(-2, -1) on both: (flip, noflip).
			l0_xoffs = -9'sd1; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd1; l1_xoffs_flip = -9'sd2;
			l0_colorbase = 11'd0;      l0_pal_mode = 3'd1; l0_pal_bank = 11'h400;
			l1_colorbase = 11'h200;    l1_pal_mode = 3'd0;
			// 0x200000 / 192 = 10922 elements, NOT a power of two -- the one
			// layer in the driver where the wrap has to be a real modulo.
			l0_code_limit = 16'd10922; l1_code_limit = 16'h4000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b1;
		end

		// zingzip_map, both layers 6bpp, and the palette remap that does not
		// mask the colour code.
		GAME_JJSQUAWK: begin
			input_layout = 3'd0;
			map_board = 5'd0; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd3;
			l0_bpp6 = 1'b1; l1_bpp6 = 1'b1;
			l0_xoffs = -9'sd1; l0_xoffs_flip = -9'sd1;
			l1_xoffs = -9'sd1; l1_xoffs_flip = -9'sd1;
			l0_colorbase = 11'd0; l1_colorbase = 11'd0;
			l0_pal_mode = 3'd2; l1_pal_mode = 3'd2;      // plain
			l0_pal_bank = 11'h400; l1_pal_bank = 11'h200;
			l0_code_limit = 16'h2000; l1_code_limit = 16'h2000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd1; fg_xoffs_flip = 9'sd1;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// extdwnhl_map: palette at 0x600400, sound at 0xe00000, 320 wide.
		GAME_EXTDWNHL, GAME_SOKONUKE: begin
			input_layout = 3'd0;
			map_board = 5'd2; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd3;
			l0_bpp6 = 1'b1;                 // layer 2 is 4bpp on both
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd2; l1_xoffs_flip = -9'sd2;
			l0_colorbase = 11'd0;   l0_pal_mode = 3'd1; l0_pal_bank = 11'h400;
			l1_colorbase = 11'h200; l1_pal_mode = 3'd0;
			// extdwnhl's gfx2 is 4 MB -- 21845 elements, more than a 14-bit
			// code can reach. sokonuke's is 1.5 MB, and its gfx3 is a 256-byte
			// stub that MAME still hangs a layer on.
			l0_code_limit = (game == GAME_SOKONUKE) ? 16'h2000 : 16'd21845;
			l1_code_limit = (game == GAME_SOKONUKE) ? 16'd2    : 16'h4000;
			narrow_320 = 1'b1;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// madshark_map, both layers 6bpp with jjsquawk's plain remap, and a
		// third kind of interrupt again: screen_vblank -> level 2, ASSERT_LINE,
		// which stays asserted until the board's own ipl1_ack_w write.
		GAME_MADSHARK: begin
			input_layout = 3'd0;
			map_board = 5'd16; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd3;
			l0_bpp6 = 1'b1; l1_bpp6 = 1'b1;
			// No set_xoffsets at all: both layers keep the device default.
			l0_xoffs = 9'sd0; l0_xoffs_flip = 9'sd0;
			l1_xoffs = 9'sd0; l1_xoffs_flip = 9'sd0;
			l0_colorbase = 11'd0; l1_colorbase = 11'd0;
			l0_pal_mode = 3'd2; l1_pal_mode = 3'd2;      // plain
			l0_pal_bank = 11'h400; l1_pal_bank = 11'h200;
			l0_code_limit = 16'h2000; l1_code_limit = 16'h2000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			short_224 = 1'b1;
			irq_vbl_level = 3'd2; irq_vbl_hold = 1'b0;
			has_ack  = 1'b1; ack_addr  = 23'h300002; ack_level  = 3'd2;
			has_ack2 = 1'b1; ack2_addr = 23'h300003; ack2_level = 3'd4;
		end

		// blandia_map / blandiap_map. Two 6bpp layers like jjsquawk, and then
		// three things no other set has.
		//
		// A SECOND PALETTE RAM at 0x703c00-0x7047ff, 1536 words landing above
		// the first window's in one 4096-entry array, and the palette-offset
		// effect in seta_video.sv that reads it. has_pal2 turns both on.
		//
		// TWO COLOUR MODES. vctrl[2] bit 4 is a real choice here, not the
		// no-op it is on the other four 6bpp games -- PAL_BLAND0 is what the
		// config names and x1_012's cmode output promotes it to PAL_BLAND1.
		// seta.cpp notes that nothing else selects mode 0, so it is untested
		// in MAME too.
		//
		// BANKED SAMPLES: 2 MB of x1snd with the top quarter of the chip's
		// window switched by vregs[5:3], which seta_core.sv already has for
		// eightfrc.
		//
		// LAYOUT_C, not D: 4 MB of sprites is what that layout sizes gfx1 for,
		// and the 6bpp tile regions are not swizzled either way.
		GAME_BLANDIA, GAME_BLANDIAP: begin
			input_layout = 3'd0;
			map_board = (game == GAME_BLANDIA) ? 5'd5 : 5'd6;
			cpu_div = 5'd6;                          // 16 MHz
			gfx_half_words = 23'h100000; code_mask = 16'h7fff;   // 4 MB
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_bpp6 = 1'b1; l1_bpp6 = 1'b1;
			// set_xoffsets(6, -2) on both layers: (flip, noflip).
			l0_xoffs = -9'sd2; l0_xoffs_flip = 9'sd6;
			l1_xoffs = -9'sd2; l1_xoffs_flip = 9'sd6;
			l0_colorbase = 11'd0; l1_colorbase = 11'd0;
			l0_pal_mode = 3'd3; l1_pal_mode = 3'd3;   // PAL_BLAND0; bit 4 lifts
			l0_pal_bank = 11'h400; l1_pal_bank = 11'h200;
			// 0x180000 / 192 = 8192 tiles in each region.
			l0_code_limit = 16'h2000; l1_code_limit = 16'h2000;
			pal_entries = 12'd3072;      // 1536 of its own plus the effect's
			has_pal2 = 1'b1;
			has_x1_bank = 1'b1;
			// set_fg_xoffsets(8, 0): "correct (test grid, startup bg)".
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd8;
			// seta_interrupt_2_and_4, NOT the 1-and-2 the other 6bpp sets use.
			irq_sl240_level = 3'd2; irq_sl112_level = 3'd4;
		end

		GAME_WROFAERO: begin
			input_layout = 3'd2;
			has_ack = 1'b1; ack_addr = 23'h780000; ack_level = 3'd4;
			map_board = 5'd0; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_xoffs = 9'sd0; l0_xoffs_flip = 9'sd0;
			l1_xoffs = 9'sd0; l1_xoffs_flip = 9'sd0;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h1000; l1_code_limit  = 16'h1000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// msgundam: 4 MB of sprites, the largest in the driver, and vregs at
		// 0x500005 rather than 0x500003.
		GAME_MSGUNDAM: begin
			map_board = 5'd4; cpu_div = 5'd6;
			// msgundam's machine_config has screen_vblank_seta_buffer_sprites.
			buffer_sprites = 1'b1;
			gfx_half_words = 23'h100000;  code_mask = 16'h7fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd2; l1_xoffs_flip = -9'sd2;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h2000; l1_code_limit  = 16'h1000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			vregs_ofs = 3'd5;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// eightfrc: 2 MB of samples through the X1-010's bank window, and
		// set_fg_xoffsets(4, 3) -- the only set whose flip and noflip SPRITE
		// offsets differ. Neither layer calls set_xoffsets.
		GAME_EIGHTFRC: begin
			map_board = 5'd0; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd1;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_xoffs = 9'sd0; l0_xoffs_flip = 9'sd0;
			l1_xoffs = 9'sd0; l1_xoffs_flip = 9'sd0;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h2000; l1_code_limit  = 16'h2000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd3; fg_xoffs_flip = 9'sd4;
			short_224 = 1'b1;
			has_x1_bank = 1'b1;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// oisipuzl: sprites are ROMREGION_INVERT, the tilemaps flip
		// independently of them, and the visible area is 320x224.
		GAME_OISIPUZL: begin
			map_board = 5'd14; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_xoffs = -9'sd1; l0_xoffs_flip = -9'sd1;
			l1_xoffs = -9'sd1; l1_xoffs_flip = -9'sd1;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h2000; l1_code_limit  = 16'h1000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd1; fg_xoffs_flip = 9'sd1;
			tilemaps_flip = 1'b1;
			narrow_320 = 1'b1; short_224 = 1'b1;
			gfx1_invert = 1'b1;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// kamenrid: both tile regions are carved out of one "user1" region by
		// ROM_COPY, so they are 0x40000 each. vregs at 0x600003.
		GAME_KAMENRID: begin
			map_board = 5'd3; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd2; l1_xoffs_flip = -9'sd2;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h0800; l1_code_limit  = 16'h0800;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			has_ack = 1'b1;
			ack_addr = 23'h300002;
			ack_level = 3'd2;
			has_ack2 = 1'b1;
			ack2_addr = 23'h300003;
			ack2_level = 3'd4;
		end

		// magspeed: set_xoffsets(0, -2) -- the only set whose flip and noflip
		// LAYER offsets differ -- and vregs at 0x500015.
		GAME_MAGSPEED: begin
			input_layout = 3'd5;   // four card buttons
			map_board = 5'd15; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_xoffs = -9'sd2; l0_xoffs_flip = 9'sd0;
			l1_xoffs = -9'sd2; l1_xoffs_flip = 9'sd0;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h1000; l1_code_limit  = 16'h1000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			vregs_ofs = 3'd5;
			has_ack = 1'b1;
			ack_addr = 23'h28000C;
			ack_level = 3'd2;
			has_ack2 = 1'b1;
			ack2_addr = 23'h28000E;
			ack2_level = 3'd4;
		end

		// atehate: 16 MHz, 2 MB of sprites, seta_interrupt_1_and_2.
		GAME_ATEHATE: begin
			// Its DEFAULT control panel is the four-button one; MAME's
			// joystick layout is behind an INPUT_TYPE config marked
			// "for Debug" and is not the shipped cabinet.
			input_layout = 3'd3;
			game_rot = 2'd0;   // ROT0
			map_board = 5'd12; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// pairlove: 8 MHz, 2048 palette entries with the sprites based at
		// 0x200, seta_interrupt_1_and_2, and the 0x900000 write-history block
		// seta.cpp calls protection.
		GAME_PAIRLOVE: begin
			game_rot = 2'd2;   // ROT270
			map_board = 5'd13; cpu_div = 5'd12;
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
