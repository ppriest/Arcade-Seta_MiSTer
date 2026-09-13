// Per-game constants, selected by the .mra mod byte. Values come from each
// set's machine_config and memory map in seta.cpp: CPU clock (cpu_div), gfx1
// size (gfx_half_words = bytes / 4, code_mask), PALETTE entries, GFXDECODE
// bases, interrupt sources and acknowledges, set_*offsets (flip, noflip),
// set_visarea.

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
		// Group B: one 4bpp layer
		GAME_DRGNUNIT  = 5'd8,
		GAME_STG       = 5'd9,
		GAME_QZKKLOGY  = 5'd10,
		GAME_QZKKLGY2  = 5'd11,
		// Group C: two 4bpp layers
		GAME_DAIOH     = 5'd12,
		GAME_REZON     = 5'd13,
		GAME_WROFAERO  = 5'd14,
		GAME_MSGUNDAM  = 5'd15,
		GAME_EIGHTFRC  = 5'd16,
		GAME_OISIPUZL  = 5'd17,
		GAME_KAMENRID  = 5'd18,
		GAME_MAGSPEED  = 5'd19,
		// Group D: 6bpp layers
		GAME_GUNDHARA  = 5'd20,
		GAME_ZINGZIP   = 5'd21,
		GAME_JJSQUAWK  = 5'd22,
		GAME_EXTDWNHL  = 5'd23,
		GAME_SOKONUKE  = 5'd24,
		GAME_MADSHARK  = 5'd25,
		GAME_BLANDIA   = 5'd26,
		GAME_BLANDIAP  = 5'd27,
		GAME_ZOMBRAID  = 5'd28
	} game_t;
endpackage

import seta_game_pkg::*;

module seta_board_cfg (
	input  wire  [4:0] game,

	// maincpu.sv memory map
	output logic [4:0] map_board,

	// 68000 clock = clk_sys / cpu_div: 6 = 16 MHz, 12 = 8 MHz
	output logic [4:0] cpu_div,

	output logic [22:0] gfx_half_words,
	output logic [15:0] code_mask,

	output logic [11:0] pal_entries,
	output logic [10:0] colorbase_fg,
	output logic [10:0] colorbase_bg,

	// interrupt level 0 = not wired
	output logic  [2:0] irq_vbl_level,    // screen_vblank()
	output logic        irq_vbl_hold,     // 1 = HOLD_LINE, 0 = ASSERT_LINE
	output logic  [2:0] irq_sl240_level,  // seta_interrupt_1_and_2, scanline 240
	output logic  [2:0] irq_sl112_level,  // ...and scanline 112
	output logic        has_ack,          // an explicit ack address exists
	output logic [23:1] ack_addr,
	// second acknowledge (kamenrid, magspeed, msgundam)
	output logic        has_ack2,
	output logic [23:1] ack2_addr,
	output logic  [2:0] ack2_level,
	// blockcar_interrupt_w: acknowledge only when data bit 0 is low
	output logic        ack_d0_low,
	// acknowledge on writes only (msgundam reads P1/COINS at its ack addresses)
	output logic        ack_wr_only,
	// driver ROT: 0 ROT0, 1 ROT90, 2 ROT270 (Auto rotation only)
	output logic  [1:0] game_rot,

	output logic        has_l0, has_l1,
	// 0..5 = LAYOUT_A..F (seta_sdram_top.sv)
	output logic  [2:0] layout,
	output logic signed [8:0] l0_xoffs, l0_xoffs_flip,
	output logic [10:0] l0_colorbase,
	output logic [15:0] l0_code_limit,
	output logic signed [8:0] l1_xoffs, l1_xoffs_flip,
	output logic [10:0] l1_colorbase,
	output logic [15:0] l1_code_limit,
	// layout_tilemap_6bpp per layer
	output logic        l0_bpp6, l1_bpp6,
	// x1_011_index modes; the bank is the 512-entry block the layer lands in
	output logic  [2:0] l0_pal_mode, l1_pal_mode,
	// blandia's second palette RAM and offset effect
	output logic        has_pal2,
	output logic [10:0] l0_pal_bank, l1_pal_bank,
	// screen_vblank_seta_buffer_sprites (setac_eof)
	output logic        buffer_sprites,
	// X1-010 bank window: 0 none, 1 blandia_x1_map, 2 zombraid_x1_map
	output logic  [1:0] x1_bank_mode,
	// seta_vregs_w's byte offset in the vregs region (0x...3, 0x...5, 0x...15)
	output logic  [2:0] vregs_ofs,
	// set_tilemaps_flip(1)
	output logic        tilemaps_flip,
	// set_visarea: 320 wide, 224 lines
	output logic        narrow_320, short_224,
	// ROMREGION_INVERT on gfx1
	output logic        gfx1_invert,
	output logic  [2:0] ack_level,

	// P1/P2 word assembly in Seta.sv:
	//   0 JOY_TYPE1_2BUTTONS   1 JOY_TYPE1_1BUTTON   2 JOY_TYPE1_3BUTTONS
	//   3 four answer buttons (B3 B4 B1 B2 at 0-3)   4 as 3 plus BUTTON5 at 4
	//   5 magspeed cards 1-4 at 0-3, B1 B2 at 4-5
	// Bit 7 is START.
	output logic  [2:0] input_layout,
	output logic        has_prot,         // pairlove's one-deep write history
	// thunderl protection (seta_prot_thunderl.sv)
	output logic        has_tl_prot,
	output logic [23:0] tl_prot_base,     // start of the write window
	output logic [23:0] tl_prot_size,
	output logic [23:0] tl_prot_rd,       // the byte address that reads it back

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

	// set_fg_yoffsets(-0x12, 0x0e) and set_bg_yoffsets(0x1, -0x1) on every set.
	// Flipped foreground y is -0x0a on the 240-line sets: with MAME's -0x12 a
	// flipped frame is the rotated unflipped one moved 8 lines. The 224-line
	// sets rotate with -0x12.
	assign fg_yoffs      =  9'sd14;      //  0x0e
	assign fg_yoffs_flip = short_224 ? -9'sd18 : -9'sd10;   // -0x12 / -0x0a
	assign bg_xoffs      =  9'sd0;
	// madshark: flip value makes a flipped frame the unflipped one rotated 180 (MAME: 0)
	assign bg_xoffs_flip = (game == GAME_MADSHARK) ? 9'sd1 : 9'sd0;
	assign bg_yoffs      = -9'sd1;
	assign bg_yoffs_flip =  9'sd1;

	// draw_sprites(..., 0x1000); device default spritelimit and transpen;
	// screen.height() 256; the bitmap is filled with pen 0x1f0.
	assign bank_size   = 13'h1000;
	assign spritelimit = 9'h1ff;
	assign transpen    = 5'd0;
	assign screen_h    = 9'd256;
	assign backdrop    = 11'h1f0;

	// Timing: 8 MHz dot clock, htotal 512, vtotal 272 = 57.44 Hz, matching
	// daioh's rate, the only one seta.cpp marks as measured on a PCB (the 60 Hz
	// sets carry no comment). Sync positions are not measured.
	assign htotal     = 10'd512;
	assign hact_start = 10'd0;
	assign hact_end   = narrow_320 ? 10'd319 : 10'd383;
	assign hs_start   = 10'd400;
	assign hs_end     = 10'd448;
	assign vtotal     = 10'd272;
	assign vact_start = short_224 ? 10'd16  : 10'd8;
	assign vact_end   = short_224 ? 10'd239 : 10'd247;
	assign vs_start   = 10'd250;
	assign vs_end     = 10'd253;

	// sprite line cutoff, just under 512 * 12 so it stops before the buffer swap
	assign line_budget = 16'd6100;

	always_comb begin
		// defaults are thunderl's
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
		x1_bank_mode    = 2'd0;
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
		ack_wr_only     = 1'b0;
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
		// thunderl: 8 MHz, vblank IPL 2 ASSERT_LINE, ipl1_ack_w at 0x200000
		GAME_THUNDERL, GAME_THUNDERLA: begin
			map_board = 5'd8;  cpu_div = 5'd12;
			gfx_half_words = 23'h20000;  code_mask = 16'h0fff;
			irq_vbl_level = 3'd2; irq_vbl_hold = 1'b0;
			has_ack = 1'b1; ack_addr = 23'h100000; ack_level = 3'd2;
			// protection: write window 0x400000-0x41ffff, read 0xb0000c
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

		// blockcar: 8 MHz, vblank IPL 3 ASSERT_LINE, acknowledged by
		// blockcar_interrupt_w at byte 0x200001 when bit 0 is low
		GAME_BLOCKCAR: begin
			game_rot = 2'd1;   // ROT90
			map_board = 5'd11; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b0;
			has_ack = 1'b1; ack_addr = 23'h100000; ack_level = 3'd3;
			ack_d0_low = 1'b1;
		end

		// umanclub (ROT0) / neobattl (ROT270): 16 MHz, vblank IPL 3 HOLD_LINE
		GAME_UMANCLUB, GAME_NEOBATTL: begin
			if (game == GAME_NEOBATTL) input_layout = 3'd1;  // one button
			game_rot = (game == GAME_NEOBATTL) ? 2'd2 : 2'd0;
			map_board = 5'd10; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b1;
		end

		// Group B: drgnunit's machine_config and per-set overrides; 8 MHz except qzkklgy2
		GAME_DRGNUNIT: begin                 // ROT0
			input_layout = 3'd2;   // JOY_TYPE1_3BUTTONS
			map_board = 5'd7; cpu_div = 5'd12;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; layout = 3'd1;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l0_code_limit  = 16'h2000;
			// flip value makes a flipped frame the unflipped one rotated 180 (MAME: 2)
			fg_xoffs = 9'sd2;  fg_xoffs_flip = -9'sd2;
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

		// qzkklgy2: 16 MHz, 2 MB of tiles
		GAME_QZKKLGY2: begin                 // ROT0, (0,0) and (-3,-1)
			input_layout = 3'd3;   // qzkklogy without BUTTON5
			map_board = 5'd7; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; layout = 3'd1;
			l0_xoffs = -9'sd3; l0_xoffs_flip = -9'sd1;
			l0_code_limit  = 16'h4000;
			// flip value makes a flipped frame the unflipped one rotated 180 (MAME: 0)
			fg_xoffs = 9'sd0;  fg_xoffs_flip = 9'sd2;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
			buffer_sprites = 1'b1;
		end

		// Group C. daioh: 16 MHz, 2 MB sprites and tiles, set_xoffsets(-2, -2)
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
			// flip value makes a flipped frame the unflipped one rotated 180 (MAME: 0)
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd2;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

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

		// Group D. gundhara: wrofaero_map (PIT IPL 4, ipl2_ack_w at 0xf00000)
		GAME_GUNDHARA: begin
			input_layout = 3'd2;     // JOY_TYPE1_3BUTTONS
			has_ack = 1'b1; ack_addr = 23'h780000; ack_level = 3'd4;
			map_board = 5'd0; cpu_div = 5'd6;       // wrofaero_map, 16 MHz
			// 8 MB of sprites: LAYOUT_E
			gfx_half_words = 23'h200000;  code_mask = 16'hffff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd4;
			l0_bpp6 = 1'b1; l1_bpp6 = 1'b1;
			l0_xoffs = 9'sd0; l0_xoffs_flip = 9'sd0;
			l1_xoffs = 9'sd0; l1_xoffs_flip = 9'sd0;
			// 6bpp pixels leave the engine as {color, pen}
			l0_colorbase = 11'd0; l1_colorbase = 11'd0;
			l0_pal_mode = 3'd1; l1_pal_mode = 3'd1;     // masked
			l0_pal_bank = 11'h400; l1_pal_bank = 11'h200;
			// 192 bytes a tile
			l0_code_limit  = 16'h2000; l1_code_limit  = 16'h4000;
			pal_entries = 12'd1536;    // 0x600 of palette RAM
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// zingzip: vblank IPL 3 HOLD_LINE; layer 1 6bpp, layer 2 4bpp
		GAME_ZINGZIP: begin
			input_layout = 3'd0;
			map_board = 5'd0; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd3;
			l0_bpp6 = 1'b1;                 // layer 2 stays 4bpp
			l0_xoffs = -9'sd1; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd1; l1_xoffs_flip = -9'sd2;
			l0_colorbase = 11'd0;      l0_pal_mode = 3'd1; l0_pal_bank = 11'h400;
			l1_colorbase = 11'h200;    l1_pal_mode = 3'd0;
			// 0x200000 / 192 = 10922, not a power of two
			l0_code_limit = 16'd10922; l1_code_limit = 16'h4000;
			pal_entries = 12'd1536;
			// flip value makes a flipped frame the unflipped one rotated 180 (MAME: 0)
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd1;
			irq_vbl_level = 3'd3; irq_vbl_hold = 1'b1;
		end

		// jjsquawk: both layers 6bpp, plain remap
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

		// extdwnhl_map: palette 0x600400, sound 0xe00000, 320 wide
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
			// extdwnhl's gfx2 is 4 MB (21845 tiles); sokonuke's gfx3 is a stub
			l0_code_limit = (game == GAME_SOKONUKE) ? 16'h2000 : 16'd21845;
			l1_code_limit = (game == GAME_SOKONUKE) ? 16'd2    : 16'h4000;
			narrow_320 = 1'b1;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// madshark: 6bpp plain remap, vblank IPL 2 ASSERT_LINE
		GAME_MADSHARK: begin
			input_layout = 3'd0;
			map_board = 5'd16; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd3;
			l0_bpp6 = 1'b1; l1_bpp6 = 1'b1;
			// no set_xoffsets; flip value makes a flipped frame the unflipped one rotated 180 (MAME: 0)
			l0_xoffs = 9'sd0; l0_xoffs_flip = -9'sd3;
			l1_xoffs = 9'sd0; l1_xoffs_flip = -9'sd3;
			l0_colorbase = 11'd0; l1_colorbase = 11'd0;
			l0_pal_mode = 3'd2; l1_pal_mode = 3'd2;      // plain
			l0_pal_bank = 11'h400; l1_pal_bank = 11'h200;
			l0_code_limit = 16'h2000; l1_code_limit = 16'h2000;
			pal_entries = 12'd1536;
			// flip value makes a flipped frame the unflipped one rotated 180 (MAME: 0)
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd1;
			short_224 = 1'b1;
			irq_vbl_level = 3'd2; irq_vbl_hold = 1'b0;
			has_ack  = 1'b1; ack_addr  = 23'h300002; ack_level  = 3'd2;
			has_ack2 = 1'b1; ack2_addr = 23'h300003; ack2_level = 3'd4;
		end

		// blandia: two 6bpp layers, a second palette RAM (0x703c00-0x7047ff) with
		// the offset effect, colour-mode bit selecting PAL_BLAND0/1, 2 MB of banked
		// samples. LAYOUT_C for its 4 MB of sprites.
		GAME_BLANDIA, GAME_BLANDIAP: begin
			input_layout = 3'd0;
			map_board = (game == GAME_BLANDIA) ? 5'd5 : 5'd6;
			cpu_div = 5'd6;                          // 16 MHz
			gfx_half_words = 23'h100000; code_mask = 16'h7fff;   // 4 MB
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			l0_bpp6 = 1'b1; l1_bpp6 = 1'b1;
			l0_xoffs = -9'sd2; l0_xoffs_flip = 9'sd6;
			l1_xoffs = -9'sd2; l1_xoffs_flip = 9'sd6;
			l0_colorbase = 11'd0; l1_colorbase = 11'd0;
			l0_pal_mode = 3'd3; l1_pal_mode = 3'd3;   // PAL_BLAND0; bit 4 lifts
			l0_pal_bank = 11'h400; l1_pal_bank = 11'h200;
			// 0x180000 / 192 = 8192
			l0_code_limit = 16'h2000; l1_code_limit = 16'h2000;
			pal_entries = 12'd3072;      // 1536 of its own plus the effect's
			has_pal2 = 1'b1;
			// buffer_sprites on both configs; the game leaves spritectrl bit 5 clear
			buffer_sprites = 1'b1;
			x1_bank_mode = 2'd1;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd8;
			irq_sl240_level = 3'd2; irq_sl112_level = 3'd4;
		end

		// zombraid: gundhara's config without the PIT, zingzip_map plus the gun
		// ADC, 4 MB of samples through zombraid_x1_map.
		GAME_ZOMBRAID: begin
			input_layout = 3'd0;
			map_board = 5'd17; cpu_div = 5'd6;       // 16 MHz
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;   // 2 MB
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd5;
			l0_bpp6 = 1'b1; l1_bpp6 = 1'b1;
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd2; l1_xoffs_flip = -9'sd2;
			l0_colorbase = 11'd0; l1_colorbase = 11'd0;
			l0_pal_mode = 3'd1; l1_pal_mode = 3'd1;     // masked, as gundhara
			l0_pal_bank = 11'h400; l1_pal_bank = 11'h200;
			// 0x300000 / 192 = 16384
			l0_code_limit = 16'h4000; l1_code_limit = 16'h4000;
			pal_entries = 12'd1536;
			x1_bank_mode = 2'd2;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// wrofaero: no set_xoffsets; PIT IPL 4, ipl2_ack_w at 0xf00000
		GAME_WROFAERO: begin
			input_layout = 3'd2;
			has_ack = 1'b1; ack_addr = 23'h780000; ack_level = 3'd4;
			map_board = 5'd0; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd2;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			// flip value makes a flipped frame the unflipped one rotated 180 (MAME: 0)
			l0_xoffs = 9'sd0; l0_xoffs_flip = -9'sd4;
			l1_xoffs = 9'sd0; l1_xoffs_flip = -9'sd4;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h1000; l1_code_limit  = 16'h1000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd0; fg_xoffs_flip = 9'sd0;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// msgundam: 4 MB sprites, vregs at 0x500005. Vblank IPL 2 and PIT IPL 4,
		// both ASSERT_LINE, acknowledged at 0x400000 and 0x400004 (writes only).
		GAME_MSGUNDAM: begin
			map_board = 5'd4; cpu_div = 5'd6;
			irq_vbl_level = 3'd2; irq_vbl_hold = 1'b0;
			has_ack  = 1'b1; ack_addr  = 23'h200000; ack_level  = 3'd2;   // 0x400000
			has_ack2 = 1'b1; ack2_addr = 23'h200002; ack2_level = 3'd4;   // 0x400004
			ack_wr_only = 1'b1;
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
		end

		// eightfrc: 2 MB banked samples, set_fg_xoffsets(4, 3), no set_xoffsets
		GAME_EIGHTFRC: begin
			map_board = 5'd0; cpu_div = 5'd6;
			gfx_half_words = 23'h40000;  code_mask = 16'h1fff;
			game_rot = 2'd1;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			// flip -4 rotates frame 2000 exactly; the game's flipped scroll writes
			// are not consistent across frames (MAME: 0)
			l0_xoffs = 9'sd0; l0_xoffs_flip = -9'sd4;
			l1_xoffs = 9'sd0; l1_xoffs_flip = -9'sd4;
			l0_colorbase = 11'h400; l1_colorbase = 11'h200;
			l0_code_limit  = 16'h2000; l1_code_limit  = 16'h2000;
			pal_entries = 12'd1536;
			fg_xoffs = 9'sd3; fg_xoffs_flip = 9'sd4;
			short_224 = 1'b1;
			x1_bank_mode = 2'd1;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// oisipuzl: inverted sprites, tilemaps_flip, 320x224
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

		// kamenrid: tile regions 0x40000 each (ROM_COPY from user1), vregs 0x600003
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

		// magspeed: set_xoffsets(0, -2), vregs 0x500015
		GAME_MAGSPEED: begin
			input_layout = 3'd5;   // four card buttons
			map_board = 5'd15; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			game_rot = 2'd0;
			has_l0 = 1'b1; has_l1 = 1'b1; layout = 3'd2;
			// flip value makes a flipped frame the unflipped one rotated 180 (MAME: 0)
			l0_xoffs = -9'sd2; l0_xoffs_flip = -9'sd2;
			l1_xoffs = -9'sd2; l1_xoffs_flip = -9'sd2;
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

		// atehate: 16 MHz, 2 MB sprites, seta_interrupt_1_and_2
		GAME_ATEHATE: begin
			// default panel: four buttons
			input_layout = 3'd3;
			game_rot = 2'd0;   // ROT0
			map_board = 5'd12; cpu_div = 5'd6;
			gfx_half_words = 23'h80000;  code_mask = 16'h3fff;
			irq_sl240_level = 3'd1; irq_sl112_level = 3'd2;
		end

		// pairlove: 8 MHz, 2048 palette entries, sprites at 0x200, write-history block
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
