// The game: 68000, X1-001 sprites, X1-006 palette, X1-010 sound, and the SDRAM
// behind all three. Everything above this is MiSTer framework glue.
//
// GROUP A ONLY. These boards fit no X1-012 tilemap layers, so there is no
// compositor here -- screen_update_seta_no_layers is three lines, and the
// mixer, the layer ordering and the palette-offset effect arrive with the
// phases that need them rather than sitting unused now.
//
// THREE CLOCK ENABLES OFF ONE 96 MHz clk_sys:
//   cpu_ce   clk_sys / cpu_div, per game: 6 for the 16 MHz boards
//            (umanclub, neobattl, atehate), 12 for the 8 MHz ones
//   snd_ce   clk_sys / 6 = 16 MHz, the X1-010's clock on every board
//   ce_pix   clk_sys / 12 = 8 MHz, the believed dot clock
// 96 is divisible by all three, which is why it was chosen -- see
// docs/ROADMAP.md. The three games on a 14.318181 MHz XTAL need a Bresenham
// enable instead and are not in this phase.
//
// TWO RESETS, and they are not interchangeable. `reset` gates the CPU and the
// video; the SDRAM path takes `reset & ~ioctl_download` because MiSTer holds
// core RESET for the WHOLE download -- see seta_sdram_top.sv's port comment for
// what happens when that is got wrong, which is a perfectly timed, entirely
// black screen.

`default_nettype none

import seta_game_pkg::*;

module seta_core (
	input  wire        clk,            // 96 MHz
	input  wire        reset,          // CPU and video
	input  wire        mem_reset,      // reset & ~ioctl_download
	input  wire        init,           // ~pll_locked, for the SDRAM chip

	// ---- which game, from the .mra mod byte ---------------------------------
	input  wire  [4:0] game,

	// ---- SDRAM pins ----------------------------------------------------------
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

	// ---- HPS ROM download ----------------------------------------------------
	input  wire        ioctl_download,
	input  wire [15:0] ioctl_index,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire  [7:0] ioctl_dout,
	output wire        ioctl_wait,

	// ---- inputs, already assembled into the driver's port words -------------
	// Active LOW, as the driver's PORT_START blocks are.
	input  wire [15:0] p1_in, p2_in, coins_in,
	// daioh's EXTRA port at 0x500006: buttons 4-6 for both players.
	input  wire [15:0] extra_in,
	input  wire [15:0] p3_in, p4_in,     // wits only
	input  wire [15:0] dsw_in,

	input  wire        pause_cpu,

	// ---- debug switches, for bisecting a fault without a rebuild ------------
	input  wire        en_spr,
	input  wire        en_pcm,
	input  wire        en_l0, en_l1,   // blank a tile layer at the mixer

	// ---- video out ------------------------------------------------------------
	output wire  [7:0] video_r, video_g, video_b,
	output wire        video_hs, video_vs, video_hb, video_vb, video_de,
	output wire        video_ce,

	// ---- audio ----------------------------------------------------------------
	output wire signed [15:0] audio_l, audio_r,

	// ---- instrumentation ------------------------------------------------------
	output wire [23:3] dbg_l0_last_addr,
	output wire [63:0] dbg_l0_last_data,
	output wire [15:0] dbg_l0_lines, dbg_l0_tiles, dbg_l0_overrun,
	output wire [15:0] dbg_l1_lines, dbg_l1_tiles, dbg_l1_overrun,
	output wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun,
	output wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped,
	// The driver's ROT for this set, for the top level's Auto rotation.
	output wire  [1:0] game_rot,
	// Seta.sv assembles the P1/P2 words; see seta_board_cfg.sv.
	output wire  [2:0] input_layout,
	output wire [15:0] dbg_snd_samples, dbg_snd_overrun, dbg_snd_rom_reads,
	output wire  [7:1] dbg_irq_pending,

	// CPU WRITES PER VIDEO REGION. The other probe counts what the sprite
	// engine and the sound chip DO; these count what the CPU SENDS, which
	// is what a black screen asks first: a game that never writes the
	// palette and never writes VRAM is failing before the video path, not
	// inside it. Saturating, so a wrapped counter cannot read as a small
	// one.
	// WHERE THE CPU IS. dbg_last_rom is the byte address of the most recent
	// program fetch, sampled continuously: a CPU spinning in a loop parks it
	// in that loop's range, and a CPU that never started leaves it at 0.
	output logic [23:0] dbg_last_rom,
	output logic [15:0] dbg_rom_fetches,
	output logic [15:0] dbg_wram_writes,
	output logic [15:0] dbg_io_reads,
	// The address of the most recent peripheral READ. With dbg_io_reads
	// saturated this says what the CPU is polling, which a count alone
	// cannot.
	output logic [23:0] dbg_last_io,
	// The last program fetch from BELOW 0x400, i.e. out of the 68000 vector
	// table. Daioh sends illegal instruction, privilege violation and IRQ 4-7
	// all to 0x400, so a restart loop is invisible in the PC but obvious in
	// which vector was read: 0x10 illegal, 0x20 privilege, 0x64-0x7c the
	// autovectors, 0x08/0x0c a bus or address error.
	output logic [23:0] dbg_last_vec,
	// PC HISTORY. The last twenty ROM reads -- instruction fetches and ROM
	// data reads alike, newest in the low word -- frozen when a fetch lands
	// on exception vectors 4..11 (0x010-0x02f: illegal
	// instruction, zero divide, CHK, TRAPV, privilege, trace, line A/F).
	// What the CPU was doing on its way into a handler.
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
	output wire [15:0] dbg_cpu_data
);

	// =====================================================================
	// Board configuration
	// =====================================================================
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

	// DECLARED BEFORE THE INSTANCE. ModelSim implicitly declares a net at a
	// port connection, so a declaration further down is a DUPLICATE and the
	// error names the wrong line. LESSONS_LEARNED carries this one already.
	wire        buffer_sprites;
	wire        has_x1_bank;
	wire  [2:0] vregs_ofs;
	wire        tilemaps_flip;
	wire        gfx1_invert;
	wire        has_l0, has_l1;
	wire  [2:0] layout;
	wire        l0_bpp6, l1_bpp6;
	wire  [1:0] l0_pal_mode, l1_pal_mode;
	wire [10:0] l0_pal_bank, l1_pal_bank;
	wire signed [8:0] l0_xoffs, l0_xoffs_flip, l1_xoffs, l1_xoffs_flip;
	wire [10:0] l0_colorbase, l1_colorbase;
	wire [15:0] l0_code_limit, l1_code_limit;

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
		.ack_d0_low(ack_d0_low),
		.has_ack2(has_ack2), .ack2_addr(ack2_addr), .ack2_level(ack2_level),
		.has_l0(has_l0), .has_l1(has_l1), .layout(layout),
		.l0_bpp6(l0_bpp6), .l1_bpp6(l1_bpp6),
		.l0_pal_mode(l0_pal_mode), .l1_pal_mode(l1_pal_mode),
		.l0_pal_bank(l0_pal_bank), .l1_pal_bank(l1_pal_bank),
		.has_x1_bank(has_x1_bank),
		.vregs_ofs(vregs_ofs),
		.tilemaps_flip(tilemaps_flip),
		.narrow_320(), .short_224(),
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

	// =====================================================================
	// Clock enables
	// =====================================================================
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

	// Pausing stops the CPU and nothing else: the video keeps running, so the
	// picture stays up and the OSD stays usable.
	wire cpu_ce = cpu_tick && !pause_cpu;

	// =====================================================================
	// Main CPU
	// =====================================================================
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
	wire [10:0] pal_base_w;
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
		.pal_base_w(pal_base_w), .coins_at8(coins_at8),
		.io_extra(io_extra),
		.io_uds(io_uds), .io_lds(io_lds), .io_sel(io_sel), .io_rdata(io_rdata),
		.ipl_level(ipl_level), .iack(iack), .iack_level(iack_level),
		.dbg_stb(dbg_cpu_stb), .dbg_addr(dbg_cpu_addr),
		.dbg_we(dbg_cpu_we), .dbg_data(dbg_cpu_data)
	);

	// io_sel bit positions, from maincpu.sv. Written out there in full for the
	// same reason they are named here: a shifted index decodes to the wrong
	// peripheral and looks like a CPU fault.
	// THESE MUST MATCH rtl/cpu/maincpu.sv's io_region_t, which is where io_sel
	// is built. Two copies of the same index list is the arrangement that put
	// is_prot on IO_MISC's bit once already; they are written out in full at
	// both ends so a mismatch is visible rather than inferred.
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
				// A BRANCH TRACE, not every fetch. Twenty sequential words
				// is a quarter of a routine and says nothing about how the CPU
				// got there; twenty DISCONTINUITIES is twenty branches, jumps
				// and returns. gundhara halts in its own illegal-instruction
				// handler after executing from address 0, and by the time the
				// ring froze it held nothing but the walk up the vector table
				// -- the jump that started it had already been pushed out.
				if (!dbg_pc_frozen && rom_addr != dbg_last_rom[23:1] + 23'd1) begin
					dbg_pc_ring <= {dbg_pc_ring[455:0], rom_addr, 1'b0};
					// STOP AT A HALT LOOP. `bra.s *` is a discontinuity every
					// time round, so a stopped game fills the ring with one
					// address and erases the history that explains it -- which
					// is what gundhara did. Freezing on the second consecutive
					// identical entry keeps the nineteen branches before the
					// halt, and it needs no per-game address: every seta.cpp
					// error handler ends in `move #$2700,sr; bra.s *`.
					// FREEZE ON THE EXCEPTION ITSELF. Taking one reads the
					// vector's four bytes, and vectors 4..11 are the faults a
					// game does not expect -- illegal instruction, divide by
					// zero, CHK, TRAPV, privilege, trace. The reset sequence
					// reads 0..8 before the first instruction, so the window
					// starts above it.
					//
					// NOT on a repeated address: with a branch trace every
					// `dbra` looks like `bra.s *`, and gundhara froze the ring
					// on the first tight loop it entered, seventeen branches
					// after reset. What the ring holds at a vector fetch is the
					// last nineteen control transfers before the fault, which
					// is the thing worth having.
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

	// =====================================================================
	// Work RAM
	//
	// 128 KB, and MIRRORED where the map declares more. atehate_map declares a
	// megabyte at 0x900000-0x9fffff, which is MAME allocating the decoded
	// window; measured from a capture of that whole window during play, the
	// game touches 0x900061-0x909a19 and 0x9fff7b-0x9ffffb and nothing else,
	// and under a 64 KB mirror those land at 0x0061-0x9a19 and 0xff7b-0xfffb
	// with zero collisions. maincpu.sv applies the mask; this is just the RAM.
	//
	// 128 KB, NOT 64, because zingzip_map declares two blocks:
	//     map(0x200000, 0x20ffff).ram();
	//     map(0x210000, 0x21ffff).ram();   // "RAM (gundhara)"
	// and MAME's own comment names the one set that uses the second. At 64 KB
	// the two aliased, and gundhara's start-up RAM test walked the second
	// block -- clearing the first as it went, the stack at 0x20fffe with it.
	// The `rts` out of the test routine popped a zeroed return address, the
	// CPU ran from 0x000000 through the vector table (which disassembles as
	// 256 legal `ori.b #imm,D0` pairs) into the handler at 0x400, and halted
	// at the `bra.s *` every handler in the driver ends with. It read as an
	// illegal instruction and was not one: nothing had been mis-decoded, the
	// return address simply was not there any more.
	//
	// 64K words is ~102 M10K blocks, about 26% of the device.
	// =====================================================================
	// REGISTERED IN, like every other RAM the CPU drives. Without it the work
	// RAM's address, data and write enables hang combinationally off the TG68K,
	// and after x1_001 was fixed the whole design's fifteen worst paths were
	// this one: from the kernel's register file straight into
	// wram|porta_we_reg, at -2.087 ns.
	//
	// maincpu.sv spends three cycles on a RAM access -- S_MEM, S_MEM2, S_MEM3
	// -- and captures the read in the third, so the stage is free: the array is
	// addressed in S_MEM2 and its output is back for S_MEM3. Writes shift from
	// S_MEM to S_MEM2 with their address and data, so a read that follows a
	// write to the same word still sees the write.
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

	// The second block, where a board has one. In Group A only wits does:
	// 0xe04000-0xe07fff, 16 KB.
	// Registered in for the same reason, and on the same three-cycle budget.
	// 64 KB: zingzip_map's 0x300000-0x30ffff, which War of Aero uses as its
	// main work RAM. At 16 KB it aliased, and probe A caught the CPU jumping
	// through a null function pointer out of a table there.
	logic [15:0] wram2 [0:32767];
	logic [15:0] wram2_q;
	wire         w2_we = io_req && io_we && io_sel[IO_WRAM2];
	logic        n2_we, n2_lds, n2_uds;
	logic [15:1] n2_addr;
	logic [15:0] n2_wdata;
	always_ff @(posedge clk) begin
		n2_we <= w2_we; n2_lds <= io_lds; n2_uds <= io_uds;
		n2_addr <= io_addr[15:1]; n2_wdata <= io_wdata;
	end
	always_ff @(posedge clk) begin
		if (n2_we && n2_lds) wram2[n2_addr][7:0]  <= n2_wdata[7:0];
		if (n2_we && n2_uds) wram2[n2_addr][15:8] <= n2_wdata[15:8];
		wram2_q <= wram2[n2_addr];
	end

	// The palette SRAM, 16 KB at 0x?00000, on the boards maincpu.sv says
	// have one (has_xram). The palette proper is 0x400-0xFFF of it and is
	// ALSO written into seta_palette (IO_PALETTE is set alongside IO_XRAM
	// there); reads come from here, so the whole chip reads back.
	logic [15:0] xram [0:8191];
	logic [15:0] xram_q;
	wire         w3_we = io_req && io_we && io_sel[IO_XRAM];
	logic        n3_we, n3_lds, n3_uds;
	logic [12:0] n3_addr;
	logic [15:0] n3_wdata;
	always_ff @(posedge clk) begin
		n3_we <= w3_we; n3_lds <= io_lds; n3_uds <= io_uds;
		n3_addr <= io_addr[13:1]; n3_wdata <= io_wdata;
	end
	always_ff @(posedge clk) begin
		if (n3_we && n3_lds) xram[n3_addr][7:0]  <= n3_wdata[7:0];
		if (n3_we && n3_uds) xram[n3_addr][15:8] <= n3_wdata[15:8];
		xram_q <= xram[n3_addr];
	end

	// TAILS: the upper 16 KB of each 32 KB VRAM / sprite-code SRAM. The
	// chips use the lower half; kamenrid_map and magspeed_map mark the
	// upper half "tested", and the test says NG without it. maincpu.sv
	// widens the windows only where has_tails is set, so on every other
	// board io_addr[14] is never high inside them.
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

	// =====================================================================
	// Video
	// =====================================================================
	// The tile layer's fetch and CPU-side readback.
	wire         tile_req, tile1_req;
	wire  [23:3] tile_addr, tile1_addr;
	wire         tile_valid, tile1_valid;
	wire  [63:0] tile_data, tile1_data;
	wire  [15:0] l0_vram_rdata, l0_ctrl_rdata;
	wire  [15:0] l1_vram_rdata, l1_ctrl_rdata;

	// m_vregs, written by seta_vregs_w. Bits 3-5 are the X1-010 sample bank,
	// which is why this register is not purely a video one.
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

	// The sprite engine's ROM port, with the debug switch in front of it: with
	// en_spr low the engine still runs and still keeps its counters, it just
	// never gets a granule back, so the picture loses its sprites without the
	// timing changing. Bisecting a fault that way needs no rebuild.
	wire spr_valid_g = spr_valid & en_spr;

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
		.en_l0(en_l0), .en_l1(en_l1),
		.l0_bpp6(l0_bpp6), .l1_bpp6(l1_bpp6),
		.l0_pal_mode(l0_pal_mode), .l1_pal_mode(l1_pal_mode),
		.l0_pal_bank(l0_pal_bank), .l1_pal_bank(l1_pal_bank),

		// ---- the X1-012 tile layer, Phase 2 --------------------------------
		// has_l0 comes from the board config and is low for every Group A set,
		// which leaves the layer held in reset and the mixer taking the sprite
		// buffer alone. maincpu.sv has decoded IO_L0VRAM and IO_L0CTRL since
		// Phase 1; nothing was listening.
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
		.vregs(vregs),

		.code_we(io_req && io_we && io_sel[IO_SPRCODE] && !io_addr[14]),
		.code_addr(io_addr[13:1]), .code_wdata(io_wdata),
		.code_uds(io_uds), .code_lds(io_lds), .code_rdata(code_rdata),
		// spriteylow is a byte array the CPU sees as words, and
		// spriteylow_w16 takes only the low byte.
		.ylow_we(io_req && io_we && io_sel[IO_SPRYLOW] && io_lds),
		.ylow_addr(io_addr[10:1]), .ylow_wdata(io_wdata[7:0]),
		.ylow_rdata(ylow_rdata),
		.ctrl_we(io_req && io_we && io_sel[IO_SPRCTRL] && io_lds),
		.ctrl_addr(io_addr[2:1]), .ctrl_wdata(io_wdata[7:0]),
		.ctrl_rdata(ctrl_rdata),
		.pal_we(io_req && io_we && io_sel[IO_PALETTE]),
		// OFFSET from the window's base, not the raw address. See
		// pal_base_w in maincpu.sv: the palette is the one region whose base
		// is not aligned to its own size.
		.pal_addr(io_addr[11:1] - pal_base_w), .pal_wdata(io_wdata),
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
		.dbg_l0_lines(dbg_l0_lines), .dbg_l0_tiles(dbg_l0_tiles),
		.dbg_l0_overrun(dbg_l0_overrun),
		.dbg_l1_lines(dbg_l1_lines), .dbg_l1_tiles(dbg_l1_tiles),
		.dbg_l1_overrun(dbg_l1_overrun),
		.dbg_lines(dbg_lines), .dbg_sprites(dbg_sprites),
		.dbg_fetches(dbg_fetches), .dbg_overrun(dbg_overrun),
		.dbg_worst_line(dbg_worst_line), .dbg_worst_sprites(dbg_worst_sprites),
		.dbg_dropped(dbg_dropped)
	);

	// =====================================================================
	// Interrupts
	// =====================================================================
	// Declared before the IRQ assembly that reads it.
	wire pit_out0;
	logic pit_out0_d;
	always_ff @(posedge clk) pit_out0_d <= pit_out0;
	wire  pit_rise = pit_out0 & ~pit_out0_d;

	logic [7:1] irq_set, irq_hold, irq_clr;

	always_comb begin
		irq_set  = 7'd0;
		irq_hold = 7'd0;
		irq_clr  = 7'd0;

		// Levels are set BY INDEX, never with a literal: `hold` and friends are
		// [7:1] vectors, so a literal numbers its bits from the MSB down to 1
		// and 7'b0000110 means levels 3 and 2, not 1 and 2. That is a bug this
		// project has already had once (LESSONS_LEARNED).
		if (irq_vbl_level   != 3'd0 && irq_vbl_pulse)   irq_set[irq_vbl_level]   = 1'b1;
		if (irq_sl240_level != 3'd0 && irq_sl240_pulse) irq_set[irq_sl240_level] = 1'b1;
		if (irq_sl112_level != 3'd0 && irq_sl112_pulse) irq_set[irq_sl112_level] = 1'b1;

		// pit_out0 -> ASSERT_LINE on IPL 4, on the RISING edge, which is what
		// pit_out0() does. It is cleared by ipl2_ack_w, which the board's ack
		// address decodes -- not here.
		if (pit_rise) irq_set[3'd4] = 1'b1;

		if (irq_vbl_level   != 3'd0) irq_hold[irq_vbl_level]   = irq_vbl_hold;
		// seta_interrupt_1_and_2 passes HOLD_LINE for both of its scanlines.
		if (irq_sl240_level != 3'd0) irq_hold[irq_sl240_level] = 1'b1;
		if (irq_sl112_level != 3'd0) irq_hold[irq_sl112_level] = 1'b1;

		// The explicit acknowledge, where the board has one. thunderl and wits
		// map ipl1_ack_w -- which clears LEVEL 2; seta.cpp names those
		// functions by pin, not by level.
		//
		// ON A READ AS WELL AS A WRITE. seta.cpp maps it .rw(ipl1_ack_r,
		// ipl1_ack_w) and ipl1_ack_r's whole body is `ipl1_ack_w(); return 0;`
		// -- so a read acknowledges too, and a core that only decoded writes
		// would leave the request pending for a game that acknowledges by
		// reading.
		// ack_d0_low is blockcar's: it acknowledges only when bit 0 of the
		// byte written is low, so a write of 1 must NOT clear the request.
		if (has_ack && io_req && io_addr == ack_addr && ack_level != 3'd0
		    && (!ack_d0_low || !io_wdata[0]))
			irq_clr[ack_level] = 1'b1;

		// The second acknowledge, where the board has two. ack_d0_low is
		// blockcar's alone and blockcar has one ack, so it does not apply here.
		if (has_ack2 && io_req && io_addr == ack2_addr && ack2_level != 3'd0)
			irq_clr[ack2_level] = 1'b1;
	end

	seta_irq u_irq (
		.clk(clk), .reset(reset),
		.set(irq_set), .hold(irq_hold), .clr(irq_clr),
		.iack(iack), .iack_level(iack_level),
		.ipl_level(ipl_level), .pending(dbg_irq_pending)
	);

	// =====================================================================
	// The uPD71054C, channel 0 -> IPL 4
	//
	// 16 MHz / 2 / 8 = 1 MHz on every board that has one, and clk_sys is
	// 96 MHz, so the enable is one clock in 96. Derived from clk_sys rather
	// than from cpu_ce, because the PIT's clock is the board's, not the CPU's
	// -- the two differ on every 8 MHz set.
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

	// =====================================================================
	// Sound
	// =====================================================================
	wire        snd_rom_req;
	wire [19:0] snd_rom_addr;

	// X1-010 SAMPLE BANKING, from seta.cpp's blandia_x1_map:
	//
	//     map(0x00000, 0xbffff).rom();
	//     map(0xc0000, 0xfffff).bankr("x1_bank");
	//
	// with init_bankx1 configuring eight entries of 0x40000 from the start of
	// the region, and the entry selected by m_vregs bits 5:3. So the top
	// quarter of the chip's address space is a window onto any of eight
	// 256 KB slices of a 2 MB region, and the bottom three quarters are the
	// first 768 KB directly.
	//
	// Only the games whose machine_config calls set_addrmap(0,
	// blandia_x1_map) have it: blandia, eightfrc and zombraid. has_x1_bank is
	// low everywhere else, and then this is the identity.
	wire        snd_banked = has_x1_bank && (snd_rom_addr >= 20'hc0000);
	wire [20:0] snd_phys   = snd_banked
	        ? ({1'b0, vregs[5:3], 18'd0} + {1'b0, snd_rom_addr - 20'hc0000})
	        : {1'b0, snd_rom_addr};
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

	// =====================================================================
	// pairlove's write-history block
	// =====================================================================
	wire [15:0] prot_rdata;
	seta_prot_pairlove u_prot (
		.clk(clk),
		.req(io_req && io_sel[IO_PROT] && has_prot), .we(io_we),
		.addr(io_addr[9:1]), .wdata(io_wdata),
		.uds(io_uds), .lds(io_lds), .rdata(prot_rdata)
	);

	// =====================================================================
	// thunderl's protection register
	//
	// Neither end of it is a decoded region: the write window is 128 KB of
	// otherwise unmapped space, and the read address sits four words above the
	// COINS port, outside maincpu.sv's six-byte inputs decode. Both are caught
	// here off the raw io address instead of adding two regions to the CPU for
	// one game.
	// =====================================================================
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

	// =====================================================================
	// io read multiplexer
	//
	// Anything not driven reads as ZERO, which is what MAME returns for an
	// unmapped read on this hardware -- checked against real boot traces, where
	// thunderl reads 0x200000 (which thunderl_map does not map for reading) and
	// gets 0x0000.
	// =====================================================================
	always_comb begin
		io_rdata = 16'h0000;
		// The protection read comes FIRST: its address falls inside no region
		// maincpu.sv decodes, but putting it ahead of the mux makes that
		// independent of where the inputs window happens to end.
		if      (tl_prot_rd_hit)     io_rdata = {8'h00, tl_prot_value};
		// The palette SRAM before the palette: on a board that has it both
		// bits are set for a palette address and the SRAM holds the same
		// word.
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
			// P1 at +0, P2 at +2, COINS at +4, and wits alone adds P3 at +8 and
			// P4 at +0xa. Uniform across every Group A map; only the base moves.
			case (io_addr[3:1])
				3'd0:    io_rdata = p1_in;
				3'd1:    io_rdata = p2_in;
				3'd2:    io_rdata = coins_in;
				// kamenrid_map reads COINS here instead. It has no P3.
				3'd4:    io_rdata = coins_at8 ? coins_in : p3_in;
				3'd5:    io_rdata = p4_in;
				default: io_rdata = 16'hffff;   // active low: nothing pressed
			endcase
		end
		else if (io_sel[IO_DSW]) begin
			// seta_dsw_r: offset 0 is the HIGH byte, offset 1 the low one.
			// Backwards, the game reads a different DIP bank and misbehaves in
			// ways that look like anything but a byte order.
			io_rdata = io_addr[1] ? {8'h00, dsw_in[7:0]} : {8'h00, dsw_in[15:8]};
		end
	end

	// =====================================================================
	// SDRAM
	// =====================================================================
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
		.snd_valid(snd_rom_valid), .snd_data(snd_rom_data)
	);

endmodule

`default_nettype wire
