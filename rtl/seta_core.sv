// The game: 68000 (maincpu.sv), video (seta_video.sv), X1-010 sound, PIT,
// RAMs, protection, and the SDRAM backend. Per-game constants come from
// seta_board_cfg.sv.
//
// Clock enables from clk_sys (96 MHz): CPU clk_sys / cpu_div (16 or 8 MHz),
// X1-010 / 6 (16 MHz), dot clock / 12 (8 MHz), PIT / 96 (1 MHz).
//
// `reset` gates the CPU and video; the SDRAM path takes reset & ~ioctl_download,
// because MiSTer holds reset through the ROM download.

`default_nettype none

import seta_game_pkg::*;

module seta_core (
	input  wire        clk,            // 96 MHz
	input  wire        reset,          // CPU and video
	input  wire        mem_reset,      // reset & ~ioctl_download
	input  wire        init,           // ~pll_locked, for the SDRAM chip

	// .mra mod byte
	input  wire  [4:0] game,

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
	// battery RAM file (index 4): the 256 bytes at 0x300100-0x3001ff
	output wire  [7:0] ioctl_din,
	output logic       nvram_save,
	// fast ROM load: Seta.sv owns the trigger and the DDR3 pins
	input  wire        ldr_start,
	output wire        ldr_active,
	output wire        ldr_ddr_req,
	output wire [27:0] ldr_ddr_addr,
	input  wire        ldr_ddr_busy,
	input  wire        ldr_ddr_valid,
	input  wire [63:0] ldr_ddr_rdata,

	// driver port words, active low
	input  wire [15:0] p1_in, p2_in, coins_in,
	// daioh's EXTRA port at 0x500006
	input  wire [15:0] extra_in,
	input  wire [15:0] p3_in, p4_in,     // wits only
	input  wire [15:0] dsw_in,
	// zombraid ADC0834 channels: {GUNY2, GUNX2, GUNY1, GUNX1}
	input  wire [31:0] gun_ch,

	input  wire        pause_cpu,

	// debug switches
	input  wire        en_spr,
	input  wire        en_pcm,
	input  wire        en_l0, en_l1,   // blank a tile layer at the mixer
	input  wire        tile_cache_en,  // x1_012's tile row cache

	output wire  [7:0] video_r, video_g, video_b,
	output wire        video_hs, video_vs, video_hb, video_vb, video_de,
	output wire        video_ce,

	output wire signed [15:0] audio_l, audio_r,

	output wire [23:3] dbg_l0_last_addr,
	output wire [63:0] dbg_l0_last_data,
	output wire [15:0] dbg_l0_cut, dbg_l0_hits, dbg_l0_overrun,
	output wire [15:0] dbg_l1_cut, dbg_l1_hits, dbg_l1_overrun,
	output wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun,
	output wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped,
	// driver ROT
	output wire  [1:0] game_rot,
	output wire  [2:0] input_layout,
	output wire        gun_game,
	output wire        narrow_320,     // 320-wide visible area
	// zombraid's aim in screen pixels, {Y2, X2, Y1, X1}, from work RAM
	output wire [35:0] gun_aim,
	output wire [15:0] dbg_snd_samples, dbg_snd_overrun, dbg_snd_rom_reads,
	output wire  [7:1] dbg_irq_pending,

	// CPU writes per video region (saturating); last program fetch address
	output logic [23:0] dbg_last_rom,
	output logic [15:0] dbg_rom_fetches,
	output logic [15:0] dbg_wram_writes,
	output logic [15:0] dbg_io_reads,
	// last peripheral read address
	output logic [23:0] dbg_last_io,
	// last fetch below 0x400: which exception vector was taken
	output logic [23:0] dbg_last_vec,
	// last twenty ROM-read discontinuities, newest low, frozen at a fetch of
	// vectors 4..11
	output logic [479:0] dbg_pc_ring,
	output logic         dbg_pc_frozen,
	output logic [15:0] dbg_w_pal,
	                    dbg_w_l0v,
	                    dbg_w_l1v,
	                    dbg_w_l0c,
	                    dbg_w_l1c,
	                    dbg_w_vregs,
	                    dbg_w_sprc,
	                    dbg_w_x1snd,
	output wire        dbg_cpu_stb,
	output wire [23:1] dbg_cpu_addr,
	output wire        dbg_cpu_we,
	output wire [15:0] dbg_cpu_data,
	// nvram save path: latch armed, write seen in the window, requests raised
	output wire  [1:0] dbg_nv_state,
	output logic [7:0] dbg_nv_saves
);

	wire  [4:0] map_board;
	wire  [4:0] cpu_div;
	wire [22:0] gfx_half_words;
	wire [15:0] code_mask;
	wire [11:0] pal_entries;
	wire [10:0] colorbase_fg, colorbase_bg;
	wire  [2:0] irq_vbl_level, irq_sl240_level, irq_sl112_level;
	wire        irq_vbl_hold, has_ack, has_prot, has_tl_prot;
	wire [23:1] ack_addr;
	wire        ack_d0_low;
	wire        ack_wr_only;
	wire        has_ack2;
	wire [23:1] ack2_addr;
	wire  [2:0] ack2_level;
	wire  [2:0] ack_level;
	wire [23:0] tl_prot_base, tl_prot_size, tl_prot_rd;
	wire signed [8:0] fg_xoffs, fg_xoffs_flip, fg_yoffs, fg_yoffs_flip;
	wire signed [8:0] bg_xoffs, bg_xoffs_flip, bg_yoffs, bg_yoffs_flip;
	wire [12:0] bank_size;
	wire  [8:0] spritelimit;
	wire  [3:0] transpen;
	wire  [8:0] screen_h;
	wire [10:0] backdrop;
	wire [15:0] line_budget;
	wire  [9:0] htotal, hs_start, hs_end, hact_start, hact_end;
	wire  [9:0] vtotal, vs_start, vs_end, vact_start, vact_end;

	// declared before the instance (ModelSim)
	wire        buffer_sprites;
	wire  [1:0] x1_bank_mode;
	wire  [2:0] vregs_ofs;
	wire        tilemaps_flip;
	wire        gfx1_invert;
	wire        has_l0, has_l1;
	wire  [2:0] layout;
	wire        l0_bpp6, l1_bpp6;
	wire  [2:0] l0_pal_mode, l1_pal_mode;
	wire        has_pal2;
	wire [10:0] l0_pal_bank, l1_pal_bank;
	wire signed [8:0] l0_xoffs, l0_xoffs_flip, l1_xoffs, l1_xoffs_flip;
	wire [10:0] l0_colorbase, l1_colorbase;
	wire [15:0] l0_code_limit, l1_code_limit;

	assign gun_game = (game == GAME_ZOMBRAID);

	seta_board_cfg u_cfg (
		.game(game),
		.game_rot(game_rot), .input_layout(input_layout),
		.map_board(map_board), .cpu_div(cpu_div),
		.gfx_half_words(gfx_half_words), .code_mask(code_mask),
		.pal_entries(pal_entries),
		.colorbase_fg(colorbase_fg), .colorbase_bg(colorbase_bg),
		.irq_vbl_level(irq_vbl_level), .irq_vbl_hold(irq_vbl_hold),
		.irq_sl240_level(irq_sl240_level), .irq_sl112_level(irq_sl112_level),
		.has_ack(has_ack), .ack_addr(ack_addr), .ack_level(ack_level),
		.ack_d0_low(ack_d0_low), .ack_wr_only(ack_wr_only),
		.has_ack2(has_ack2), .ack2_addr(ack2_addr), .ack2_level(ack2_level),
		.has_l0(has_l0), .has_l1(has_l1), .layout(layout),
		.l0_bpp6(l0_bpp6), .l1_bpp6(l1_bpp6),
		.l0_pal_mode(l0_pal_mode), .l1_pal_mode(l1_pal_mode),
		.has_pal2(has_pal2),
		.l0_pal_bank(l0_pal_bank), .l1_pal_bank(l1_pal_bank),
		.x1_bank_mode(x1_bank_mode),
		.vregs_ofs(vregs_ofs),
		.tilemaps_flip(tilemaps_flip),
		.narrow_320(narrow_320), .short_224(),
		.gfx1_invert(gfx1_invert),
		.buffer_sprites(buffer_sprites),
		.l0_xoffs(l0_xoffs), .l0_xoffs_flip(l0_xoffs_flip),
		.l0_colorbase(l0_colorbase), .l0_code_limit(l0_code_limit),
		.l1_xoffs(l1_xoffs), .l1_xoffs_flip(l1_xoffs_flip),
		.l1_colorbase(l1_colorbase), .l1_code_limit(l1_code_limit),
		.has_prot(has_prot),
		.has_tl_prot(has_tl_prot), .tl_prot_base(tl_prot_base),
		.tl_prot_size(tl_prot_size), .tl_prot_rd(tl_prot_rd),
		.fg_xoffs(fg_xoffs), .fg_xoffs_flip(fg_xoffs_flip),
		.fg_yoffs(fg_yoffs), .fg_yoffs_flip(fg_yoffs_flip),
		.bg_xoffs(bg_xoffs), .bg_xoffs_flip(bg_xoffs_flip),
		.bg_yoffs(bg_yoffs), .bg_yoffs_flip(bg_yoffs_flip),
		.bank_size(bank_size), .spritelimit(spritelimit), .transpen(transpen),
		.screen_h(screen_h), .backdrop(backdrop), .line_budget(line_budget),
		.htotal(htotal), .hs_start(hs_start), .hs_end(hs_end),
		.hact_start(hact_start), .hact_end(hact_end),
		.vtotal(vtotal), .vs_start(vs_start), .vs_end(vs_end),
		.vact_start(vact_start), .vact_end(vact_end)
	);

	logic [4:0] cpu_cnt = 0;
	logic [3:0] snd_cnt = 0, pix_cnt = 0;
	wire cpu_tick = (cpu_cnt == 5'd0);
	wire snd_ce   = (snd_cnt == 4'd0);
	wire ce_pix   = (pix_cnt == 4'd0);

	always_ff @(posedge clk) begin
		cpu_cnt <= (cpu_cnt + 5'd1 >= cpu_div) ? 5'd0 : cpu_cnt + 5'd1;
		snd_cnt <= (snd_cnt == 4'd5)  ? 4'd0 : snd_cnt + 4'd1;
		pix_cnt <= (pix_cnt == 4'd11) ? 4'd0 : pix_cnt + 4'd1;
	end

	// pause stops the CPU only
	wire cpu_ce = cpu_tick && !pause_cpu;

	wire        rom_req;
	wire [23:1] rom_addr;
	wire        rom_valid;
	wire [15:0] rom_data;

	wire [19:1] wram_addr;
	wire        wram_wel, wram_weh;
	wire [15:0] wram_wdata;
	logic [15:0] wram_rdata;

	wire        io_req, io_we, io_uds, io_lds;
	wire [23:1] io_addr;
	wire [11:0] pal_index_w;
	wire        coins_at8;
	wire        io_extra;
	wire [15:0] io_wdata;
	wire [15:0] io_sel;
	logic [15:0] io_rdata;

	wire        iack;
	wire  [2:0] iack_level, ipl_level;

	maincpu u_cpu (
		.clk(clk), .reset(reset), .board(map_board), .cpu_ce(cpu_ce),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.wram_addr(wram_addr), .wram_wel(wram_wel), .wram_weh(wram_weh),
		.wram_wdata(wram_wdata), .wram_rdata(wram_rdata),
		.io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_wdata(io_wdata),
		.pal_index_w(pal_index_w), .coins_at8(coins_at8),
		.io_extra(io_extra),
		.io_uds(io_uds), .io_lds(io_lds), .io_sel(io_sel), .io_rdata(io_rdata),
		.gun_ch(gun_ch),
		.ipl_level(ipl_level), .iack(iack), .iack_level(iack_level),
		.dbg_stb(dbg_cpu_stb), .dbg_addr(dbg_cpu_addr),
		.dbg_we(dbg_cpu_we), .dbg_data(dbg_cpu_data)
	);

	// io_sel bits: must match maincpu.sv's io_region_t
	localparam int IO_PALETTE = 0, IO_SPRYLOW = 1, IO_SPRCTRL = 2, IO_SPRCODE = 3;
	localparam int IO_L0VRAM = 4, IO_L1VRAM = 5, IO_L0CTRL = 6, IO_L1CTRL = 7;
	localparam int IO_VREGS = 9;
	localparam int IO_PIT = 15;
	localparam int IO_X1SND = 8, IO_INPUTS = 10, IO_DSW = 11, IO_WRAM2 = 12;
	localparam int IO_PROT = 14;
	localparam int IO_XRAM = 13;

	always_ff @(posedge clk) begin
		if (reset) begin
			dbg_last_rom    <= 24'd0;
			dbg_rom_fetches <= 16'd0;
			dbg_wram_writes <= 16'd0;
			dbg_io_reads    <= 16'd0;
			dbg_last_io     <= 24'd0;
			dbg_last_vec    <= 24'd0;
			dbg_pc_ring     <= '0;
			dbg_pc_frozen   <= 1'b0;
		end else begin
			if (rom_req) begin
				dbg_last_rom <= {rom_addr, 1'b0};
				if ({rom_addr, 1'b0} < 24'h000400 && {rom_addr, 1'b0} >= 24'h000008)
					dbg_last_vec <= {rom_addr, 1'b0};
				if (~&dbg_rom_fetches) dbg_rom_fetches <= dbg_rom_fetches + 16'd1;
				// branch trace: only fetches that are not the next word
				if (!dbg_pc_frozen && rom_addr != dbg_last_rom[23:1] + 23'd1) begin
					dbg_pc_ring <= {dbg_pc_ring[455:0], rom_addr, 1'b0};
					// freeze on a fetch of vectors 4..11 (reset reads 0..8 first)
					if ({rom_addr, 1'b0} >= 24'h000010 && {rom_addr, 1'b0} < 24'h000030)
						dbg_pc_frozen <= 1'b1;
				end
			end
			if (wram_wel | wram_weh)
				if (~&dbg_wram_writes) dbg_wram_writes <= dbg_wram_writes + 16'd1;
			if (io_req && !io_we) begin
				dbg_last_io <= {io_addr, 1'b0};
				if (~&dbg_io_reads) dbg_io_reads <= dbg_io_reads + 16'd1;
			end
		end
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			dbg_w_pal <= 16'd0;
			dbg_w_l0v <= 16'd0;
			dbg_w_l1v <= 16'd0;
			dbg_w_l0c <= 16'd0;
			dbg_w_l1c <= 16'd0;
			dbg_w_vregs <= 16'd0;
			dbg_w_sprc <= 16'd0;
			dbg_w_x1snd <= 16'd0;
		end else if (io_req && io_we) begin
			if (io_sel[IO_PALETTE] && dbg_w_pal != 16'hFFFF) dbg_w_pal <= dbg_w_pal + 16'd1;
			if (io_sel[IO_L0VRAM] && dbg_w_l0v != 16'hFFFF) dbg_w_l0v <= dbg_w_l0v + 16'd1;
			if (io_sel[IO_L1VRAM] && dbg_w_l1v != 16'hFFFF) dbg_w_l1v <= dbg_w_l1v + 16'd1;
			if (io_sel[IO_L0CTRL] && dbg_w_l0c != 16'hFFFF) dbg_w_l0c <= dbg_w_l0c + 16'd1;
			if (io_sel[IO_L1CTRL] && dbg_w_l1c != 16'hFFFF) dbg_w_l1c <= dbg_w_l1c + 16'd1;
			if (io_sel[IO_VREGS] && dbg_w_vregs != 16'hFFFF) dbg_w_vregs <= dbg_w_vregs + 16'd1;
			if (io_sel[IO_SPRCODE] && dbg_w_sprc != 16'hFFFF) dbg_w_sprc <= dbg_w_sprc + 16'd1;
			if (io_sel[IO_X1SND] && dbg_w_x1snd != 16'hFFFF) dbg_w_x1snd <= dbg_w_x1snd + 16'd1;
		end
	end

	// Work RAM, 128 KB (zingzip_map's two 64 KB blocks; gundhara uses the
	// second). Larger declared windows (atehate's 1 MB) are mirrored by
	// maincpu.sv. Registered in: maincpu reads in the third cycle of a RAM
	// access.
	logic        m_wel, m_weh;
	logic [19:1] m_addr;
	logic [15:0] m_wdata;
	always_ff @(posedge clk) begin
		m_wel <= wram_wel; m_weh <= wram_weh;
		m_addr <= wram_addr; m_wdata <= wram_wdata;
	end

	logic [15:0] wram [0:65535];
	always_ff @(posedge clk) begin
		if (m_wel) wram[m_addr[16:1]][7:0]  <= m_wdata[7:0];
		if (m_weh) wram[m_addr[16:1]][15:8] <= m_wdata[15:8];
		wram_rdata <= wram[m_addr[16:1]];
	end

	// zombraid's calibrated aim words, 0x20c4aa P1 X, 0x20c4ac P1 Y, 0x20c4ae
	// P2 X, 0x20c4b0 P2 Y (scripts/gun_find.py), read through a second port for
	// the crosshair overlay.
	logic  [1:0] aim_i;
	logic [15:0] aim_q;
	logic  [8:0] aim_x1, aim_y1, aim_x2, aim_y2;
	wire  [15:0] aim_addr = 16'h6255 + {14'd0, aim_i};    // (0x20c4aa - 0x200000) / 2
	always_ff @(posedge clk) begin
		aim_q <= wram[aim_addr];
		aim_i <= aim_i + 2'd1;
		case (aim_i - 2'd1)                                // aim_q is the previous index
			2'd0: aim_x1 <= aim_q[8:0];
			2'd1: aim_y1 <= aim_q[8:0];
			2'd2: aim_x2 <= aim_q[8:0];
			2'd3: aim_y2 <= aim_q[8:0];
		endcase
	end
	assign gun_aim = {aim_y2, aim_x2, aim_y1, aim_x1};

	// Second work RAM block, 64 KB (zingzip_map's 0x300000; wits' 0xe04000).
	logic [15:0] wram2 [0:32767];
	logic [15:0] wram2_q;
	wire         w2_we = io_req && io_we && io_sel[IO_WRAM2];
	wire         has_nvram = (game == GAME_ZOMBRAID);
	logic        n2_we, n2_lds, n2_uds;
	logic [15:1] n2_addr;
	logic [15:0] n2_wdata;
	// The nvram file is written through this port: the CPU is in reset for
	// any download, and Quartus will not infer a second write port.
	wire         nv_dl    = ioctl_download && (ioctl_index == 16'd4) && has_nvram;
	wire  [14:0] nv_addr  = 15'h0080 + {8'd0, ioctl_addr[7:1]};
	always_ff @(posedge clk) begin
		if (nv_dl) begin
			n2_we <= ioctl_wr; n2_lds <= ioctl_addr[0]; n2_uds <= ~ioctl_addr[0];
			n2_addr <= nv_addr; n2_wdata <= {ioctl_dout, ioctl_dout};
		end else begin
			n2_we <= w2_we; n2_lds <= io_lds; n2_uds <= io_uds;
			n2_addr <= io_addr[15:1]; n2_wdata <= io_wdata;
		end
	end
	always_ff @(posedge clk) begin
		if (n2_we && n2_lds) wram2[n2_addr][7:0]  <= n2_wdata[7:0];
		if (n2_we && n2_uds) wram2[n2_addr][15:8] <= n2_wdata[15:8];
		wram2_q <= wram2[n2_addr];
	end

	// zombraid's battery RAM: the low lanes of 0x300100-0x3001ff behind a
	// write-enable latch at 0x3000f0. The game opens it with $00a3 and closes
	// it with $ffff; a close after a write inside the window pulses nvram_save
	// so the HPS reads the file back. Boot's load writes nothing and fires
	// nothing.
	wire         nv_latch  = w2_we && has_nvram && io_addr[15:1] == 15'h0078;   // 0x3000f0
	wire         nv_inside = w2_we && has_nvram && io_addr[15:8] == 8'h01;      // 0x3001xx
	logic        nv_armed, nv_dirty;
	always_ff @(posedge clk) begin
		nvram_save <= 1'b0;
		if (reset) begin
			nv_armed <= 1'b0; nv_dirty <= 1'b0;
		end else if (nv_latch) begin
			if (io_wdata == 16'h00a3) begin nv_armed <= 1'b1; nv_dirty <= 1'b0; end
			if (io_wdata == 16'hffff) begin nv_armed <= 1'b0; nvram_save <= nv_dirty; end
		end else if (nv_inside && nv_armed)
			nv_dirty <= 1'b1;
	end
	assign dbg_nv_state = {nv_dirty, nv_armed};
	always_ff @(posedge clk) begin
		if (reset) dbg_nv_saves <= 8'd0;
		else if (nvram_save && dbg_nv_saves != 8'hff) dbg_nv_saves <= dbg_nv_saves + 8'd1;
	end

	// upload through a read-only port; the HPS strobes a byte every few microseconds
	logic [15:0] nv_q;
	always_ff @(posedge clk) nv_q <= wram2[nv_addr];
	assign ioctl_din = ioctl_addr[0] ? nv_q[7:0] : nv_q[15:8];

	// Palette SRAM (has_xram). Palette writes also go to seta_palette; reads
	// come from here.
	logic [15:0] xram [0:32767];   // 64 KB: the largest chip any map declares
	logic [15:0] xram_q;
	wire         w3_we = io_req && io_we && io_sel[IO_XRAM];
	logic        n3_we, n3_lds, n3_uds;
	logic [14:0] n3_addr;         // 32K words -- see the xram declaration
	logic [15:0] n3_wdata;
	always_ff @(posedge clk) begin
		n3_we <= w3_we; n3_lds <= io_lds; n3_uds <= io_uds;
		n3_addr <= io_addr[15:1]; n3_wdata <= io_wdata;
	end
	always_ff @(posedge clk) begin
		if (n3_we && n3_lds) xram[n3_addr][7:0]  <= n3_wdata[7:0];
		if (n3_we && n3_uds) xram[n3_addr][15:8] <= n3_wdata[15:8];
		xram_q <= xram[n3_addr];
	end

	// Upper 16 KB of the 32 KB VRAM and sprite-code SRAMs: kamenrid and
	// magspeed test it (has_tails).
	logic [15:0] l0_tail [0:8191], l1_tail [0:8191], code_tail [0:8191];
	logic [15:0] l0_tail_q, l1_tail_q, code_tail_q;
	logic        t_l0_we, t_l1_we, t_code_we, t_lds, t_uds;
	logic [12:0] t_addr;
	logic [15:0] t_wdata;
	always_ff @(posedge clk) begin
		t_l0_we   <= io_req && io_we && io_addr[14] && io_sel[IO_L0VRAM];
		t_l1_we   <= io_req && io_we && io_addr[14] && io_sel[IO_L1VRAM];
		t_code_we <= io_req && io_we && io_addr[14] && io_sel[IO_SPRCODE];
		t_lds <= io_lds; t_uds <= io_uds;
		t_addr <= io_addr[13:1]; t_wdata <= io_wdata;
	end
	always_ff @(posedge clk) begin
		if (t_l0_we && t_lds) l0_tail[t_addr][7:0]  <= t_wdata[7:0];
		if (t_l0_we && t_uds) l0_tail[t_addr][15:8] <= t_wdata[15:8];
		l0_tail_q <= l0_tail[t_addr];
		if (t_l1_we && t_lds) l1_tail[t_addr][7:0]  <= t_wdata[7:0];
		if (t_l1_we && t_uds) l1_tail[t_addr][15:8] <= t_wdata[15:8];
		l1_tail_q <= l1_tail[t_addr];
		if (t_code_we && t_lds) code_tail[t_addr][7:0]  <= t_wdata[7:0];
		if (t_code_we && t_uds) code_tail[t_addr][15:8] <= t_wdata[15:8];
		code_tail_q <= code_tail[t_addr];
	end

	wire         tile_req, tile1_req;
	wire  [23:3] tile_addr, tile1_addr;
	wire         tile_valid, tile1_valid;
	wire  [63:0] tile_data, tile1_data;
	wire  [15:0] l0_vram_rdata, l0_ctrl_rdata;
	wire  [15:0] l1_vram_rdata, l1_ctrl_rdata;

	// m_vregs; bits 3-5 are the X1-010 sample bank
	logic  [7:0] vregs = 8'd0;
	always_ff @(posedge clk) begin
		if (reset) vregs <= 8'd0;
		else if (io_req && io_we && io_sel[IO_VREGS] && io_lds
		         && io_addr[2:1] == vregs_ofs[2:1])
			vregs <= io_wdata[7:0];
	end

	wire        spr_req;
	wire [23:3] spr_addr;
	wire        spr_valid;
	wire [63:0] spr_data;

	wire [15:0] pal_rdata, code_rdata;
	wire  [7:0] ylow_rdata, ctrl_rdata;
	wire        irq_vbl_pulse, irq_sl240_pulse, irq_sl112_pulse;

	// en_spr withholds the sprite engine's ROM data; the engine keeps running
	wire spr_valid_g = spr_valid & en_spr;

	// 2048 entries: blandia's second window writes 0x600-0xbff but only
	// 0x600-0x7ff is read; seta_video drops the writes above.
	seta_video #(.LB_W(11), .PAL_ENTRIES(2048)) u_video (
		.clk(clk), .reset(reset), .ce_pix(ce_pix),
		.htotal(htotal), .hs_start(hs_start), .hs_end(hs_end),
		.hact_start(hact_start), .hact_end(hact_end),
		.vtotal(vtotal), .vs_start(vs_start), .vs_end(vs_end),
		.vact_start(vact_start), .vact_end(vact_end),
		.fg_xoffs(fg_xoffs), .fg_xoffs_flip(fg_xoffs_flip),
		.fg_yoffs(fg_yoffs), .fg_yoffs_flip(fg_yoffs_flip),
		.bg_xoffs(bg_xoffs), .bg_xoffs_flip(bg_xoffs_flip),
		.bg_yoffs(bg_yoffs), .bg_yoffs_flip(bg_yoffs_flip),
		.bank_size(bank_size), .spritelimit(spritelimit), .transpen(transpen),
		.bgflag_opaque(1'b0),
		.buffer_sprites(buffer_sprites),
		.colorbase_fg(colorbase_fg), .colorbase_bg(colorbase_bg),
		.screen_h(screen_h), .vis_max_y(vact_end[8:0]), .backdrop(backdrop),
		.code_mask(code_mask), .line_budget(line_budget),
		.en_l0(en_l0), .en_l1(en_l1), .tile_cache_en(tile_cache_en),
		.l0_bpp6(l0_bpp6), .l1_bpp6(l1_bpp6),
		.l0_pal_mode(l0_pal_mode), .l1_pal_mode(l1_pal_mode),
		.has_pal2(has_pal2),
		.l0_pal_bank(l0_pal_bank), .l1_pal_bank(l1_pal_bank),

		.has_l0(has_l0),
		.l0_vram_we(io_req && io_we && io_sel[IO_L0VRAM] && !io_addr[14]),
		.l0_vram_addr(io_addr[13:1]), .l0_vram_wdata(io_wdata),
		.l0_vram_uds(io_uds), .l0_vram_lds(io_lds),
		.l0_vram_rdata(l0_vram_rdata),
		.l0_ctrl_we(io_req && io_we && io_sel[IO_L0CTRL]),
		.l0_ctrl_addr(io_addr[2:1]), .l0_ctrl_wdata(io_wdata),
		.l0_ctrl_uds(io_uds), .l0_ctrl_lds(io_lds),
		.l0_ctrl_rdata(l0_ctrl_rdata),
		.l0_xoffs(l0_xoffs), .l0_xoffs_flip(l0_xoffs_flip),
		.l0_colorbase(l0_colorbase), .l0_code_limit(l0_code_limit),
		.tile_req(tile_req), .tile_addr(tile_addr),
		.tile_valid(tile_valid), .tile_data(tile_data),

		.has_l1(has_l1),
		.l1_vram_we(io_req && io_we && io_sel[IO_L1VRAM] && !io_addr[14]),
		.l1_vram_addr(io_addr[13:1]), .l1_vram_wdata(io_wdata),
		.l1_vram_uds(io_uds), .l1_vram_lds(io_lds),
		.l1_vram_rdata(l1_vram_rdata),
		.l1_ctrl_we(io_req && io_we && io_sel[IO_L1CTRL]),
		.l1_ctrl_addr(io_addr[2:1]), .l1_ctrl_wdata(io_wdata),
		.l1_ctrl_uds(io_uds), .l1_ctrl_lds(io_lds),
		.l1_ctrl_rdata(l1_ctrl_rdata),
		.l1_xoffs(l1_xoffs), .l1_xoffs_flip(l1_xoffs_flip),
		.l1_colorbase(l1_colorbase), .l1_code_limit(l1_code_limit),
		.tile1_req(tile1_req), .tile1_addr(tile1_addr),
		.tile1_valid(tile1_valid), .tile1_data(tile1_data),
		.vregs(vregs), .tilemaps_flip(tilemaps_flip),

		.code_we(io_req && io_we && io_sel[IO_SPRCODE] && !io_addr[14]),
		.code_addr(io_addr[13:1]), .code_wdata(io_wdata),
		.code_uds(io_uds), .code_lds(io_lds), .code_rdata(code_rdata),
		// spriteylow_w16 takes the low byte
		.ylow_we(io_req && io_we && io_sel[IO_SPRYLOW] && io_lds),
		.ylow_addr(io_addr[10:1]), .ylow_wdata(io_wdata[7:0]),
		.ylow_rdata(ylow_rdata),
		.ctrl_we(io_req && io_we && io_sel[IO_SPRCTRL] && io_lds),
		.ctrl_addr(io_addr[2:1]), .ctrl_wdata(io_wdata[7:0]),
		.ctrl_rdata(ctrl_rdata),
		.pal_we(io_req && io_we && io_sel[IO_PALETTE]),
		// index formed in maincpu.sv (pal_index_w)
		.pal_addr(pal_index_w), .pal_wdata(io_wdata),
		.pal_uds(io_uds), .pal_lds(io_lds), .pal_rdata(pal_rdata),
		.rom_req(spr_req), .rom_addr(spr_addr),
		.rom_valid(spr_valid_g), .rom_data(spr_data),
		.vga_r(video_r), .vga_g(video_g), .vga_b(video_b),
		.vga_hs(video_hs), .vga_vs(video_vs), .vga_hb(video_hb),
		.vga_vb(video_vb), .vga_de(video_de), .vga_ce(video_ce),
		.irq_vblank_line(irq_sl240_pulse), .irq_mid_line(irq_sl112_pulse),
		.vblank_rise(irq_vbl_pulse),
		.dbg_l0_last_addr(dbg_l0_last_addr),
		.dbg_l0_last_data(dbg_l0_last_data),
		.dbg_l0_cut(dbg_l0_cut), .dbg_l0_hits(dbg_l0_hits),
		.dbg_l0_overrun(dbg_l0_overrun),
		.dbg_l1_cut(dbg_l1_cut), .dbg_l1_hits(dbg_l1_hits),
		.dbg_l1_overrun(dbg_l1_overrun),
		.dbg_lines(dbg_lines), .dbg_sprites(dbg_sprites),
		.dbg_fetches(dbg_fetches), .dbg_overrun(dbg_overrun),
		.dbg_worst_line(dbg_worst_line), .dbg_worst_sprites(dbg_worst_sprites),
		.dbg_dropped(dbg_dropped)
	);

	wire pit_out0;
	logic pit_out0_d;
	always_ff @(posedge clk) pit_out0_d <= pit_out0;
	wire  pit_rise = pit_out0 & ~pit_out0_d;

	logic [7:1] irq_set, irq_hold, irq_clr;

	always_comb begin
		irq_set  = 7'd0;
		irq_hold = 7'd0;
		irq_clr  = 7'd0;

		// set by index: [7:1] vectors number from 1
		if (irq_vbl_level   != 3'd0 && irq_vbl_pulse)   irq_set[irq_vbl_level]   = 1'b1;
		if (irq_sl240_level != 3'd0 && irq_sl240_pulse) irq_set[irq_sl240_level] = 1'b1;
		if (irq_sl112_level != 3'd0 && irq_sl112_pulse) irq_set[irq_sl112_level] = 1'b1;

		// PIT OUT0 rising edge -> IPL 4, ASSERT_LINE
		if (pit_rise) irq_set[3'd4] = 1'b1;

		if (irq_vbl_level   != 3'd0) irq_hold[irq_vbl_level]   = irq_vbl_hold;
		// seta_interrupt_1_and_2: HOLD_LINE
		if (irq_sl240_level != 3'd0) irq_hold[irq_sl240_level] = 1'b1;
		if (irq_sl112_level != 3'd0) irq_hold[irq_sl112_level] = 1'b1;

		// Board acknowledge, on read or write (ipl1_ack_r calls ipl1_ack_w)
		// unless ack_wr_only. ack_d0_low: blockcar acknowledges only on a 0.
		if (has_ack && io_req && io_addr == ack_addr && ack_level != 3'd0
		    && (!ack_d0_low || !io_wdata[0]) && (!ack_wr_only || io_we))
			irq_clr[ack_level] = 1'b1;

		if (has_ack2 && io_req && io_addr == ack2_addr && ack2_level != 3'd0
		    && (!ack_wr_only || io_we))
			irq_clr[ack2_level] = 1'b1;
	end

	seta_irq u_irq (
		.clk(clk), .reset(reset),
		.set(irq_set), .hold(irq_hold), .clr(irq_clr),
		.iack(iack), .iack_level(iack_level),
		.ipl_level(ipl_level), .pending(dbg_irq_pending)
	);

	// uPD71054C: 1 MHz from clk_sys (the board's clock, not the CPU's)
	logic  [6:0] pit_div = 7'd0;
	wire         pit_ce  = (pit_div == 7'd0);
	always_ff @(posedge clk) begin
		if (reset)               pit_div <= 7'd0;
		else if (pit_div == 7'd95) pit_div <= 7'd0;
		else                     pit_div <= pit_div + 7'd1;
	end

	seta_pit u_pit (
		.clk(clk), .reset(reset), .ce(pit_ce),
		.we(io_req && io_we && io_sel[IO_PIT] && io_lds),
		.addr(io_addr[2:1]), .wdata(io_wdata[7:0]),
		.out0(pit_out0)
	);

	wire        snd_rom_req;
	wire [19:0] snd_rom_addr;

	// X1-010 sample banking (m_vregs bits 5:3):
	//   mode 1, blandia_x1_map (blandia, eightfrc): 0xc0000-0xfffff is a window
	//          onto 0x40000-byte entries of 2 MB
	//   mode 2, zombraid_x1_map: 0x80000-0xfffff onto 0x80000-byte entries of
	//          4 MB, entry 0 aliasing entry 1
	//   mode 0: identity
	wire  [2:0] snd_bank   = vregs[5:3];
	wire  [2:0] snd_bank_z = (snd_bank == 3'd0) ? 3'd1 : snd_bank;
	wire        snd_bank_b = (x1_bank_mode == 2'd1) && (snd_rom_addr >= 20'hc0000);
	wire        snd_bank_2 = (x1_bank_mode == 2'd2) && snd_rom_addr[19];
	wire [21:0] snd_phys   = snd_bank_b
	        ? ({1'b0, snd_bank, 18'd0} + {2'b0, snd_rom_addr - 20'hc0000})
	        : snd_bank_2
	        ? {snd_bank_z, snd_rom_addr[18:0]}
	        : {2'b0, snd_rom_addr};
	wire        snd_rom_valid;
	wire  [7:0] snd_rom_data;
	wire [15:0] x1_rdata;
	wire signed [15:0] x1_l, x1_r;

	x1_010 u_snd (
		.clk(clk), .reset(reset), .ce(snd_ce),
		.cpu_req(io_req && io_sel[IO_X1SND]), .cpu_we(io_we),
		.cpu_addr(io_addr[13:1]), .cpu_wdata(io_wdata),
		.cpu_uds(io_uds), .cpu_lds(io_lds), .cpu_rdata(x1_rdata),
		.rom_req(snd_rom_req), .rom_addr(snd_rom_addr),
		.rom_valid(snd_rom_valid), .rom_data(snd_rom_data),
		.audio_l(x1_l), .audio_r(x1_r), .audio_stb(),
		.dbg_samples(dbg_snd_samples), .dbg_overrun(dbg_snd_overrun),
		.dbg_rom_reads(dbg_snd_rom_reads)
	);

	assign audio_l = en_pcm ? x1_l : 16'sd0;
	assign audio_r = en_pcm ? x1_r : 16'sd0;

	wire [15:0] prot_rdata;
	seta_prot_pairlove u_prot (
		.clk(clk),
		.req(io_req && io_sel[IO_PROT] && has_prot), .we(io_we),
		.addr(io_addr[9:1]), .wdata(io_wdata),
		.uds(io_uds), .lds(io_lds), .rdata(prot_rdata)
	);

	// thunderl protection: write window 0x400000-0x41ffff, read at 0xb0000c,
	// both outside maincpu's decoded regions.
	wire [23:0] io_byte = {io_addr, 1'b0};
	wire tl_prot_wr = has_tl_prot && io_req && io_we
	               && (io_byte >= tl_prot_base)
	               && (io_byte <  tl_prot_base + tl_prot_size);
	wire tl_prot_rd_hit = has_tl_prot && (io_byte == tl_prot_rd);
	wire  [7:0] tl_prot_value;

	seta_prot_thunderl u_tl_prot (
		.clk(clk), .reset(reset),
		.wr(tl_prot_wr), .addr((io_byte - tl_prot_base)),
		.value(tl_prot_value)
	);

	// io read mux; unmapped reads are zero
	always_comb begin
		io_rdata = 16'h0000;
		if      (tl_prot_rd_hit)     io_rdata = {8'h00, tl_prot_value};
		// palette SRAM first: both bits are set on a palette address
		else if (io_sel[IO_XRAM])    io_rdata = xram_q;
		else if (io_sel[IO_PALETTE]) io_rdata = pal_rdata;
		else if (io_sel[IO_L0VRAM])  io_rdata = io_addr[14] ? l0_tail_q : l0_vram_rdata;
		else if (io_sel[IO_L0CTRL])  io_rdata = l0_ctrl_rdata;
		else if (io_sel[IO_L1VRAM])  io_rdata = io_addr[14] ? l1_tail_q : l1_vram_rdata;
		else if (io_sel[IO_L1CTRL])  io_rdata = l1_ctrl_rdata;
		else if (io_sel[IO_SPRCODE]) io_rdata = io_addr[14] ? code_tail_q : code_rdata;
		else if (io_sel[IO_SPRYLOW]) io_rdata = {8'h00, ylow_rdata};
		else if (io_sel[IO_SPRCTRL]) io_rdata = {8'h00, ctrl_rdata};
		else if (io_sel[IO_X1SND])   io_rdata = x1_rdata;
		else if (io_sel[IO_WRAM2])   io_rdata = wram2_q;
		else if (io_sel[IO_PROT])    io_rdata = prot_rdata;
		else if (io_sel[IO_INPUTS] && io_extra) io_rdata = extra_in;
		else if (io_sel[IO_INPUTS])  begin
			// P1 +0, P2 +2, COINS +4; wits adds P3 +8, P4 +0xa
			case (io_addr[3:1])
				3'd0:    io_rdata = p1_in;
				3'd1:    io_rdata = p2_in;
				3'd2:    io_rdata = coins_in;
				// kamenrid: COINS here
				3'd4:    io_rdata = coins_at8 ? coins_in : p3_in;
				3'd5:    io_rdata = p4_in;
				default: io_rdata = 16'hffff;   // active low: nothing pressed
			endcase
		end
		else if (io_sel[IO_DSW]) begin
			// seta_dsw_r: offset 0 is the high byte
			io_rdata = io_addr[1] ? {8'h00, dsw_in[7:0]} : {8'h00, dsw_in[15:8]};
		end
	end

	seta_sdram_top u_sdram (
		.clk(clk), .reset(mem_reset), .init(init),
		.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.gfx_half_words(gfx_half_words),
		.cpu_req(rom_req), .cpu_addr(rom_addr),
		.cpu_valid(rom_valid), .cpu_data(rom_data),
		.layout(layout), .gfx1_invert(gfx1_invert),
		.tile_req(tile_req), .tile_addr(tile_addr),
		.tile_valid(tile_valid), .tile_data(tile_data),
		.tile1_req(tile1_req), .tile1_addr(tile1_addr),
		.tile1_valid(tile1_valid), .tile1_data(tile1_data),
		.spr_req(spr_req), .spr_addr(spr_addr),
		.spr_valid(spr_valid), .spr_data(spr_data),
		.snd_req(snd_rom_req), .snd_addr(snd_phys),
		.snd_valid(snd_rom_valid), .snd_data(snd_rom_data),
		.ldr_start(ldr_start), .ldr_active(ldr_active),
		.ldr_ddr_req(ldr_ddr_req), .ldr_ddr_addr(ldr_ddr_addr),
		.ldr_ddr_busy(ldr_ddr_busy), .ldr_ddr_valid(ldr_ddr_valid),
		.ldr_ddr_rdata(ldr_ddr_rdata)
	);

endmodule

`default_nettype wire
