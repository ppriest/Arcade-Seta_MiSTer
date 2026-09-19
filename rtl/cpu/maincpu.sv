// Main CPU: fx68k (cycle-accurate 68000, rtl/cpu/fx68k/PROVENANCE.md) plus
// address decode and bus sequencing for every in-scope memory map, selected
// by `board`. Autovectored interrupts only (VPA in the acknowledge cycle).
//
// Clock: phi1 and phi2 enables alternate every cpu_half clk (6 = 8 MHz, 3 =
// 16 MHz). An access starts when AS and a data strobe are low and DTACK
// follows acc_ready. A phi2 that would sample DTACK while the access is not
// ready is held until it is, so a slow SDRAM read costs clk cycles rather
// than a 68000 wait state (sim/fx68k_pace_tb).

`default_nettype none

package seta_board_pkg;
	// Memory maps. Must agree with scripts/mame_capture.py's FAMILIES table.
	typedef enum logic [4:0] {
		BOARD_TWO_LAYER = 5'd0,   // rezon_map / zingzip_map / wrofaero_map
		BOARD_DAIOH     = 5'd1,   // daioh_map      -- work RAM at 0x100000
		BOARD_EXTDWNHL  = 5'd2,   // extdwnhl_map   -- palette at 0x600400
		BOARD_KAMENRID  = 5'd3,   // kamenrid_map   -- vregs at 0x600003
		BOARD_MSGUNDAM  = 5'd4,   // msgundam_map   -- sprites and tilemaps swap
		BOARD_BLANDIA   = 5'd5,   // blandia_map
		BOARD_BLANDIAP  = 5'd6,   // blandiap_map   -- NOT blandia_map
		BOARD_DRGNUNIT  = 5'd7,   // drgnunit_map   -- one layer, two work RAMs
		BOARD_THUNDERL  = 5'd8,   // thunderl_map   -- no layers
		BOARD_WITS      = 5'd9,   // wits_map       -- thunderl plus spare RAM
		BOARD_UMANCLUB  = 5'd10,  // umanclub_map   -- NOT thunderl_map
		BOARD_BLOCKCAR  = 5'd11,  // blockcar_map
		BOARD_OISIPUZL  = 5'd14,  // oisipuzl_map   -- palette and sound swap
		BOARD_MAGSPEED  = 5'd15,  // magspeed_map   -- almost every base moves
		BOARD_ATEHATE   = 5'd12,  // atehate_map    -- 1 MB of work RAM
		BOARD_PAIRLOVE  = 5'd13,  // pairlove_map   -- 2048 palette entries,
		                          //                   plus a protection RAM
		BOARD_MADSHARK  = 5'd16,  // madshark_map   -- kamenrid's registers,
		                          //                   magspeed's inputs
		BOARD_ZOMBRAID  = 5'd17,  // zombraid_map   -- zingzip_map plus the
		                          //                   gun ADC at 0xf00000
		// downtown.cpp downtown_map (downtown, twineagl, metafox, arbalest);
		// its sub CPU, tile bank and control registers are decoded in seta_core
		BOARD_DOWNTOWN  = 5'd18,
		// downtown.cpp calibr50_map: X1-010 on the 65C02, battery RAM, uPD4701
		BOARD_CALIBR50  = 5'd19,
		// downtown.cpp tndrcade_map: no tile layer, sound on the 65C02
		BOARD_TNDRCADE  = 5'd20
	} board_t;
endpackage

import seta_board_pkg::*;

module maincpu (
	input  wire         clk,
	input  wire         reset,

	input  wire  [4:0]  board,

	// clk per phase (half a CPU clock); cpu_run low freezes the CPU (pause)
	input  wire  [3:0]  cpu_half,
	input  wire         cpu_run,

	// program ROM (sdram_narrow_bridge): rom_req pulses, rom_addr held until rom_valid
	output logic        rom_req,
	output logic [23:1] rom_addr,      // WORD address
	input  wire         rom_valid,
	input  wire  [15:0] rom_data,

	// work RAM, up to atehate's 1 MB window (masked by wram_mask)
	output logic [19:1] wram_addr,
	output logic        wram_wel, wram_weh,
	output logic [15:0] wram_wdata,
	input  wire  [15:0] wram_rdata,

	// Other regions: one-hot io_sel over the IO_* indices, read data due within
	// the access. Undriven reads are zero, as MAME's unmapped reads.
	output logic        io_req,
	output logic        io_we,
	output logic [23:1] io_addr,
	// palette index as a word, formed here where the full address exists
	// (blandia's second window straddles 4 KB pages)
	output logic [11:0] pal_index_w,
	// COINS at in_base+8 (kamenrid)
	output wire         coins_at8,
	// daioh's EXTRA port
	output logic        io_extra,
	output logic [15:0] io_wdata,
	output logic        io_uds, io_lds,
	output logic [15:0] io_sel,
	input  wire  [15:0] io_rdata,
	// hold the access in S_MEM3 (DTACK late) until the read data is current
	input  wire         io_hold,

	// zombraid ADC0834 inputs {GUNY2, GUNX2, GUNY1, GUNX1}, decoded here: io_sel
	// is full
	input  wire  [31:0] gun_ch,

	// 0 = none
	input  wire  [2:0]  ipl_level,

	// Trace strobe per completed access, for comparison with
	// mame_capture.py --boot-trace. iack: FC = 111 with the latched level on
	// A3..A1, so seta_irq clears the level actually taken.
	output logic        iack,
	output logic  [2:0] iack_level,

	output logic        dbg_stb,
	output logic [23:1] dbg_addr,
	output logic        dbg_we,
	output logic [15:0] dbg_data
);

	localparam int IO_PALETTE  = 0;
	localparam int IO_SPRYLOW  = 1;   // sprite Y low + per-column scroll
	localparam int IO_SPRCTRL  = 2;   // 4 control bytes
	localparam int IO_SPRCODE  = 3;   // sprite code / X / attributes
	localparam int IO_L0VRAM   = 4;
	localparam int IO_L1VRAM   = 5;
	localparam int IO_L0CTRL   = 6;
	localparam int IO_L1CTRL   = 7;
	localparam int IO_X1SND    = 8;
	localparam int IO_VREGS    = 9;   // the X1-011 order / sample-bank register
	localparam int IO_INPUTS   = 10;  // P1 / P2 / COINS
	localparam int IO_DSW      = 11;
	localparam int IO_WRAM2    = 12;  // the second work RAM block, where present
	localparam int IO_XRAM     = 13;  // RAM above the palette, where MAME maps one
	// pairlove's write-history block
	localparam int IO_PROT     = 14;
	// uPD71054C
	localparam int IO_PIT      = 15;

	// declared before the instance: a port connection to an undeclared name is
	// inferred as a net by ModelSim even under `default_nettype none`, and the
	// later explicit declaration then collides with it.
	wire [23:1] eab;
	wire [15:0] cpu_dout;
	wire [15:0] cpu_din;
	wire        as_n, n_uds, n_lds, rw_n;
	wire        fc0, fc1, fc2;
	wire  [2:0] fc = {fc2, fc1, fc0};
	logic       en_phi1, en_phi2;
	logic       acc_ready;

	wire        in_iack   = !as_n && (fc == 3'b111);
	wire        dtack_n   = !(acc_ready && !as_n && !in_iack);

	fx68k u_cpu (
		.clk(clk), .HALTn(1'b1), .extReset(reset), .pwrUp(reset),
		.enPhi1(en_phi1), .enPhi2(en_phi2),
		.eRWn(rw_n), .ASn(as_n), .LDSn(n_lds), .UDSn(n_uds), .E(), .VMAn(),
		.FC0(fc0), .FC1(fc1), .FC2(fc2), .BGn(), .oRESETn(), .oHALTEDn(),
		.DTACKn(dtack_n), .VPAn(!in_iack), .BERRn(1'b1),
		.BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(~ipl_level[0]), .IPL1n(~ipl_level[1]), .IPL2n(~ipl_level[2]),
		.iEdb(cpu_din), .oEdb(cpu_dout), .eab(eab)
	);

	// an access: AS and a strobe (a write's strobes follow AS by a state, with
	// the data bus driven by then)
	wire        acc_active = !as_n && !in_iack && !(n_uds && n_lds);
	wire        acc_write  = !rw_n;
	wire [23:0] addr24     = {eab, 1'b0};

	// interrupt acknowledge: one pulse as the cycle starts
	logic       as_q = 1'b1;
	always_ff @(posedge clk) as_q <= as_n;
	assign iack       = in_iack && as_q;
	assign iack_level = eab[3:1];

	// phase enables; the DTACK-sampling phi2 (the second after AS) waits for
	// acc_ready
	logic [3:0] ph_cnt = 4'd0;
	logic       next_phi2 = 1'b0;
	logic [1:0] phi2_in_as = 2'd0;
	wire        ph_due  = cpu_run && (ph_cnt + 4'd1 >= cpu_half);
	wire        ph_hold = next_phi2 && !as_n && !in_iack && !acc_ready
	                   && phi2_in_as != 2'd0;
	assign en_phi1 = ph_due && !next_phi2;
	assign en_phi2 = ph_due && next_phi2 && !ph_hold;
	always_ff @(posedge clk) begin
		if (cpu_run) begin
			if (!ph_due)      ph_cnt <= ph_cnt + 4'd1;
			else if (!ph_hold) begin
				ph_cnt    <= 4'd0;
				next_phi2 <= ~next_phi2;
			end
		end
		if (as_n)                            phi2_in_as <= 2'd0;
		else if (en_phi2 && phi2_in_as != 2'd3) phi2_in_as <= phi2_in_as + 2'd1;
	end

	// Address decode. Regions decode on ranges, so byte, word and long accesses all land.
	logic [23:0] rom_end;
	logic [23:0] wram_base, wram_end;
	logic [23:0] wram2_base, wram2_end;
	logic [23:0] pal_base, pal_end;
	logic [23:0] spry_base, sprc_base, sprcode_base;
	logic [23:0] l0v_base, l1v_base, l0c_base, l1c_base;
	logic [23:0] x1_base;
	logic [23:0] pit_base;
	logic [23:0] vregs_base;
	logic [23:0] in_base, dsw_base;
	// extdwnhl watchdog read, must return 0xFFFF
	logic [23:0] wdog_base;
	// thunderl protection PAL
	logic        has_tprot;
	// zombraid ADC0834: gun_w 0xf00000, gun_r 0xf00002
	logic        has_gun;
	// palette SRAM size: 16 KB (kamenrid, magspeed) or 64 KB (rezon, zingzip,
	// daioh maps); power-on tests walk it
	logic [23:0] xram_span;
	// blandia's second palette RAM, at entry 0x600
	logic [23:0] pal2_base;
	// input window size, per map (wits P3/P4, kamenrid COINS at +8)
	logic  [4:0] in_span;
	logic        coins_hi;
	// daioh EXTRA, carved out of the vregs window
	logic        has_extra;
	logic [23:0] extra_base;
	logic [23:0] prot_base;
	logic        has_l0, has_l1, has_wram2;
	// has_xram: 16 KB palette SRAM at pal_base - 0x400 (Group C self-tests)
	logic        has_xram;
	// has_tails: VRAM and sprite code windows widened to their 32 KB SRAMs (kamenrid, magspeed)
	logic        has_tails;
	// RAM declared behind VRAM/sprite code beyond the tails (extdwnhl: 48 KB, 64 KB),
	// walked by its POST. Mirrored onto the existing arrays; 0 = none.
	logic [23:0] vram_span, sprcode_span;
	logic [23:0] wram_mask;
	logic        board_unmapped;

	// base NONE: region absent
	localparam logic [23:0] NONE = 24'hFFFFFF;

	always_comb begin
		// defaults: rezon_map / zingzip_map / wrofaero_map
		rom_end      = 24'h1FFFFF;
		wram_base    = 24'h200000;  wram_end   = 24'h21FFFF;
		wram_mask    = 24'h03FFFF;
		wram2_base   = 24'h300000;  wram2_end  = 24'h30FFFF;
		pal_base     = 24'h700400;  pal_end    = 24'h700FFF;
		l0v_base     = 24'h800000;  l1v_base   = 24'h880000;
		l0c_base     = 24'h900000;  l1c_base   = 24'h980000;
		spry_base    = 24'hA00000;  sprc_base  = 24'hA00600;
		sprcode_base = 24'hB00000;
		x1_base      = 24'hC00000;
		pit_base     = NONE;
		vregs_base   = 24'h500000;
		in_base      = 24'h400000;  dsw_base   = 24'h600000;
		wdog_base    = NONE;
		has_tprot    = 1'b0;
		has_gun      = 1'b0;
		xram_span    = 24'h4000;
		pal2_base    = NONE;
		in_span      = 5'd6;        coins_hi   = 1'b0;
		has_extra    = 1'b0;        extra_base = NONE;
		prot_base    = NONE;
		has_l0 = 1'b1; has_l1 = 1'b1; has_wram2 = 1'b1;
		has_xram = 1'b0; has_tails = 1'b0;
		vram_span = 24'h0; sprcode_span = 24'h0;
		board_unmapped = 1'b0;

		case (board)
			BOARD_TWO_LAYER: begin                   // rezon_map / wrofaero_map
				has_xram = 1'b1;
				xram_span = 24'h10000;               // the 64 KB chip
				has_tails = 1'b1;
				// wrofaero_map: PIT at 0xd00000 (rezon has none)
				pit_base = 24'hD00000;
			end

			// zombraid_map: zingzip_map plus the gun ADC, no PIT
			BOARD_ZOMBRAID: begin                    // zombraid_map
				has_xram = 1'b1;
				xram_span = 24'h10000;
				has_tails = 1'b1;
				has_gun = 1'b1;
			end

			BOARD_DAIOH: begin                       // daioh_map
				has_xram = 1'b1;
				xram_span = 24'h10000;               // the 64 KB chip
				has_tails = 1'b1;
				// daioh_map: 1 MB ROM, work RAM at 0x100000
				rom_end   = 24'h0FFFFF;
				wram_base = 24'h100000; wram_end = 24'h10FFFF;
				has_extra = 1'b1;       extra_base = 24'h500006;
				wram2_base = NONE;      has_wram2 = 1'b0;
			end

			BOARD_EXTDWNHL: begin                    // extdwnhl_map
				has_xram = 1'b1;
				has_tails = 1'b1;
				vram_span    = 24'h10000;            // to 0x80ffff / 0x88ffff
				sprcode_span = 24'h14000;            // to 0xb13fff
				pal_base = 24'h600400; pal_end = 24'h600FFF;
				dsw_base = 24'h400008;
				// X1-010 at 0xe00000
				x1_base  = 24'hE00000;
				// extdwnhl_watchdog_r: its POST uses the value as a fill count
				wdog_base = 24'h40000C;
			end

			BOARD_KAMENRID: begin                    // kamenrid_map
				has_xram = 1'b1;
				has_tails = 1'b1;
				rom_end    = 24'h07FFFF;
				vregs_base = 24'h600000;
				in_base    = 24'h500000;
				dsw_base   = 24'h500004;
				in_span    = 5'd10;  coins_hi = 1'b1;
				wram_end   = 24'h20FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				// kamenrid_map: PIT 0xc00000, X1-010 0xd00000
				x1_base    = 24'hD00000;
				pit_base   = 24'hC00000;
			end

			BOARD_MSGUNDAM: begin                    // msgundam_map
				// 64 KB mirrored over 0x70000
				wram_end     = 24'h27FFFF;
				wram_mask    = 24'h00FFFF;
				wram2_base   = NONE; has_wram2 = 1'b0;
				spry_base    = 24'h800000; sprc_base = 24'h800600;
				sprcode_base = 24'h900000;
				l0v_base     = 24'hA00000; l1v_base  = 24'hA80000;
				l0c_base     = 24'hB00000; l1c_base  = 24'hB80000;
				vregs_base   = 24'h500004;
				// PIT at 0xd00000, IPL 4
				pit_base     = 24'hD00000;
			end

			// oisipuzl_map: palette 0xc00400, X1-010 0x700000, DSW 0x300000
			BOARD_OISIPUZL: begin                    // oisipuzl_map
				rom_end    = 24'h17FFFF;             // two ROM ranges, 0 and 0x100000
				wram_end   = 24'h20FFFF;
				wram2_base = NONE; has_wram2 = 1'b0; // 0x300000 is the DSW here
				dsw_base   = 24'h300000;
				x1_base    = 24'h700000;
				pal_base   = 24'hC00400; pal_end = 24'hC00FFF;
			end

			// magspeed_map: inputs 0x500000, DSW 0x500008, vregs 0x500015, acks in the same block; PIT/X1-010 as kamenrid
			BOARD_MADSHARK: begin                    // madshark_map
				rom_end    = 24'h0FFFFF;
				wram_end   = 24'h20FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				// COINS +4, DSW +8
				in_base    = 24'h500000;
				dsw_base   = 24'h500008;
				vregs_base = 24'h600000;
				// no palette SRAM, no tails
				x1_base    = 24'hD00000;
				pit_base   = 24'hC00000;
			end

			BOARD_MAGSPEED: begin                    // magspeed_map
				has_xram = 1'b1; has_tails = 1'b1;
				rom_end    = 24'h07FFFF;
				wram_end   = 24'h20FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				in_base    = 24'h500000;
				dsw_base   = 24'h500008;
				// vregs_base + vregs_ofs = 0x500015; clear of the acks at 0x500018/c
				vregs_base = 24'h500010;
				x1_base    = 24'hD00000;
				pit_base   = 24'hC00000;
			end

			BOARD_BLANDIA: begin                     // blandia_map
				has_xram = 1'b1;
				has_tails = 1'b1;
				spry_base    = 24'h800000; sprc_base = 24'h800600;
				sprcode_base = 24'h900000;
				l0c_base     = 24'hA00000; l1c_base  = 24'hA80000;
				l0v_base     = 24'hB00000; l1v_base  = 24'hB80000;
				// second palette RAM 0x703c00-0x7047ff, entry 0x600
				pal2_base = 24'h703C00;
			end

			BOARD_BLANDIAP: begin                    // blandiap_map
				// blandiap: default layer layout
				has_xram = 1'b1;
				has_tails = 1'b1;
				wram_end = 24'h21FFFF;               // two blocks, contiguous
				pal2_base = 24'h703C00;
			end

			BOARD_DRGNUNIT: begin                    // drgnunit_map
				rom_end    = 24'h0FFFFF;
				wram_base  = 24'hF00000; wram_end  = 24'hF0FFFF;
				wram2_base = 24'hFFC000; wram2_end = 24'hFFFFFF;
				pal_base   = 24'h700000; pal_end   = 24'h7003FF;
				l0c_base   = 24'h800000; l0v_base  = 24'h900000;
				l1c_base   = NONE;       l1v_base  = NONE;  has_l1 = 1'b0;
				spry_base  = 24'hD00000; sprc_base = 24'hD00600;
				sprcode_base = 24'hE00000;
				x1_base    = 24'h100000;
				in_base    = 24'hB00000;
			end

			BOARD_THUNDERL, BOARD_WITS: begin        // thunderl_map / wits_map
				// thunderl_map only
				has_tprot  = (board == BOARD_THUNDERL);
				rom_end    = 24'h0FFFFF;
				wram_base  = 24'hFFC000; wram_end  = 24'hFFFFFF;
				// wits: P3 +8, P4 +0xa
				in_span    = (board == BOARD_WITS) ? 5'd12 : 5'd6;
				wram2_base = (board == BOARD_WITS) ? 24'hE04000 : NONE;
				wram2_end  = 24'hE07FFF;
				has_wram2  = (board == BOARD_WITS);
				pal_base   = 24'h700000; pal_end   = 24'h7003FF;
				l0v_base = NONE; l1v_base = NONE; l0c_base = NONE; l1c_base = NONE;
				has_l0 = 1'b0; has_l1 = 1'b0;
				spry_base  = 24'hD00000; sprc_base = 24'hD00600;
				sprcode_base = 24'hE00000;
				x1_base    = 24'h100000;
				in_base    = 24'hB00000;
				vregs_base = NONE;
			end

			BOARD_UMANCLUB: begin                    // umanclub_map
				rom_end    = 24'h0FFFFF;
				wram_end   = 24'h20FFFF;
				// umanclub_map: RAM at 0x300400-0x300fff above the palette
				wram2_base = 24'h300400; wram2_end = 24'h300FFF;
				has_wram2  = 1'b1;
				pal_base   = 24'h300000; pal_end = 24'h3003FF;
				l0v_base = NONE; l1v_base = NONE; l0c_base = NONE; l1c_base = NONE;
				has_l0 = 1'b0; has_l1 = 1'b0;
				vregs_base = NONE;
			end

			BOARD_BLOCKCAR: begin                    // blockcar_map
				// inputs 0x500000, DSW 0x300000
				in_base    = 24'h500000; dsw_base = 24'h300000;
				rom_end    = 24'h0FFFFF;
				wram_base  = 24'hF00000; wram_end = 24'hF03FFF;
				// backup RAM blocks 0xf04000 and 0xf05000, one window
				wram2_base = 24'hF04000; wram2_end = 24'hF05FFF;
				has_wram2  = 1'b1;
				pal_base   = 24'hB00000; pal_end  = 24'hB003FF;
				l0v_base = NONE; l1v_base = NONE; l0c_base = NONE; l1c_base = NONE;
				has_l0 = 1'b0; has_l1 = 1'b0;
				sprcode_base = 24'hC00000;
				spry_base    = 24'hE00000; sprc_base = 24'hE00600;
				x1_base      = 24'hA00000;
				vregs_base   = NONE;
			end

			BOARD_ATEHATE: begin                     // atehate_map
				rom_end    = 24'h0FFFFF;
				// atehate_map declares 1 MB; the game uses 0x900061-0x909a19 and
				// 0x9fff7b-0x9ffffb, which a 64 KB mirror keeps apart
				wram_base  = 24'h900000; wram_end = 24'h9FFFFF;
				wram_mask  = 24'h00FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				pal_base   = 24'h700000; pal_end  = 24'h7003FF;
				l0v_base = NONE; l1v_base = NONE; l0c_base = NONE; l1c_base = NONE;
				has_l0 = 1'b0; has_l1 = 1'b0;
				spry_base  = 24'hA00000; sprc_base = 24'hA00600;
				sprcode_base = 24'hE00000;
				x1_base    = 24'h100000;
				in_base    = 24'hB00000;
				vregs_base = NONE;
			end

			BOARD_PAIRLOVE: begin                    // pairlove_map
				// pairlove: 2048-entry palette
				rom_end    = 24'h03FFFF;
				wram_base  = 24'hF00000; wram_end = 24'hF0FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				pal_base   = 24'hB00000; pal_end  = 24'hB00FFF;
				l0v_base = NONE; l1v_base = NONE; l0c_base = NONE; l1c_base = NONE;
				has_l0 = 1'b0; has_l1 = 1'b0;
				sprcode_base = 24'hC00000;
				spry_base  = 24'hE00000; sprc_base = 24'hE00600;
				x1_base    = 24'hA00000;
				in_base    = 24'h500000;  dsw_base = 24'h300000;
				prot_base  = 24'h900000;
				vregs_base = NONE;
			end

			BOARD_DOWNTOWN: begin                    // downtown.cpp downtown_map
				rom_end    = 24'h09FFFF;
				// declared 0xf00000-0xffffff; the games write 0xf00000-0xf03fff
				// (metafox, arbalest, twineagl) and 0xffc000-0xffffff (downtown,
				// twineagl), which a 128 KB mirror keeps apart
				wram_base  = 24'hF00000; wram_end = 24'hFFFFFF;
				wram_mask  = 24'h01FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				pal_base   = 24'h700000; pal_end  = 24'h7003FF;
				l0c_base   = 24'h800000; l0v_base = 24'h900000;
				l1c_base   = NONE;       l1v_base = NONE;  has_l1 = 1'b0;
				spry_base  = 24'hD00000; sprc_base = 24'hD00600;
				sprcode_base = 24'hE00000;
				x1_base    = 24'h100000;
				in_base    = NONE;
				vregs_base = NONE;
			end

			BOARD_CALIBR50: begin                    // downtown.cpp calibr50_map
				rom_end    = 24'h09FFFF;
				wram_base  = 24'hFF0000; wram_end = 24'hFFFFFF;
				wram_mask  = 24'h00FFFF;
				// the battery RAM, 0x200000-0x200fff (seta_core)
				wram2_base = 24'h200000; wram2_end = 24'h200FFF;
				has_wram2  = 1'b1;
				pal_base   = 24'h700000; pal_end  = 24'h7003FF;
				l0c_base   = 24'h800000; l0v_base = 24'h900000;
				l1c_base   = NONE;       l1v_base = NONE;  has_l1 = 1'b0;
				spry_base  = 24'hD00000; sprc_base = 24'hD00600;
				sprcode_base = 24'hE00000;
				x1_base    = NONE;
				// X1-004: P1 +0, P2 +2, COINS +8
				in_base    = 24'hA00000;
				in_span    = 5'd10;  coins_hi = 1'b1;
				vregs_base = NONE;
			end

			BOARD_TNDRCADE: begin                    // downtown.cpp tndrcade_map
				rom_end    = 24'h07FFFF;
				// 16 KB at 0xe00000, mirrored at 0xffc000
				wram_base  = 24'hE00000; wram_end = 24'hFFFFFF;
				wram_mask  = 24'h003FFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				pal_base   = 24'h380000; pal_end  = 24'h3803FF;
				l0v_base = NONE; l1v_base = NONE; l0c_base = NONE; l1c_base = NONE;
				has_l0 = 1'b0; has_l1 = 1'b0;
				spry_base  = 24'h600000; sprc_base = 24'h600600;
				sprcode_base = 24'hC00000;
				x1_base    = NONE;
				// inputs and DSW are the 65C02's
				in_base    = NONE;  dsw_base = NONE;
				vregs_base = NONE;
			end

			default: board_unmapped = 1'b1;
		endcase
	end

	// is_rom from the live address (needed in S_IDLE); the rest from q_a
	wire is_rom     = (addr24 <= rom_end);

	// q_a: address latched in S_IDLE, stable through the access (timing)
	logic [23:0] q_a;
	wire is_wram    = (q_a >= wram_base)  && (q_a <= wram_end);
	wire is_wram2   = has_wram2 && (q_a >= wram2_base) && (q_a <= wram2_end);
	wire is_pal2    = (pal2_base != NONE) && (q_a >= pal2_base)
	               && (q_a <  pal2_base + 24'hC00);
	wire [10:0] pal_off_main = q_a[11:1] - pal_base[11:1];
	wire [11:0] pal_off_2    = 12'h600 + (q_a[15:1] - pal2_base[15:1]);
	wire is_pal     = ((q_a >= pal_base) && (q_a <= pal_end)) || is_pal2;
	wire is_prot    = (q_a >= prot_base)  && (q_a <  prot_base + 24'h400);
	wire is_spry    = (q_a >= spry_base)  && (q_a <  spry_base + 24'h600);
	wire is_sprc    = (q_a >= sprc_base)  && (q_a <  sprc_base + 24'h8);
	wire [23:0] vwin = (vram_span != 24'h0) ? vram_span
	                 : has_tails ? 24'h8000 : 24'h4000;
	wire [23:0] swin = (sprcode_span != 24'h0) ? sprcode_span
	                 : has_tails ? 24'h8000 : 24'h4000;
	wire is_sprcode = (q_a >= sprcode_base) && (q_a < sprcode_base + swin);
	wire is_l0v     = has_l0 && (q_a >= l0v_base) && (q_a < l0v_base + vwin);
	wire is_l1v     = has_l1 && (q_a >= l1v_base) && (q_a < l1v_base + vwin);
	wire is_l0c     = has_l0 && (q_a >= l0c_base) && (q_a < l0c_base + 24'h6);
	wire is_l1c     = has_l1 && (q_a >= l1c_base) && (q_a < l1c_base + 24'h6);
	wire is_x1      = (q_a >= x1_base)    && (q_a <  x1_base + 24'h4000);
	wire is_pit     = (pit_base != NONE) && (q_a >= pit_base)
	               && (q_a <  pit_base + 24'h8);
	wire is_extra   = has_extra && (q_a >= extra_base)
	               && (q_a <  extra_base + 24'h2);
	wire is_vregs   = (vregs_base != NONE) && (q_a >= vregs_base) &&
	                  (q_a < vregs_base + 24'h8) && !is_extra;
	// kamenrid's DSW sits inside the input span
	wire is_inputs  = is_extra ||
	                  (q_a >= in_base) && (q_a < in_base + {19'd0, in_span})
	               && !(coins_hi && (q_a >= in_base + 24'h4)
	                             && (q_a <  in_base + 24'h8));
	wire is_dsw     = (q_a >= dsw_base)   && (q_a <  dsw_base + 24'h4);
	wire is_wdog    = (wdog_base != NONE) && (q_a >= wdog_base)
	               && (q_a <  wdog_base + 24'h2);

	// thunderl protection: writes to 0x400000-0x41ffff (address matters, data
	// ignored), read at 0xb0000c
	wire is_tprot_w = has_tprot && (q_a >= 24'h400000) && (q_a < 24'h420000);
	wire is_tprot_r = has_tprot && (q_a >= 24'hB0000C) && (q_a < 24'hB0000E);

	wire [16:0] tp  = q_a[16:0];        // 0x400000 is 17-bit aligned
	wire tp_or6     = tp[2] | ~tp[6];
	wire tp_or8     = tp[2] | ~tp[6] | ~tp[8];
	wire tp_and13   = tp[6] & tp[13];
	wire tp_or16    = tp_and13 | ~tp[16];
	wire [7:0] tprot_next = {tp_or16 & tp_or8,              // 7
	                         tp_or16,                        // 6
	                         tp_and13,                       // 5
	                         tp[3] & ~tp[11] & tp[15],       // 4
	                         tp_or8,                         // 3
	                         tp_or6,                         // 2
	                         tp[2] & ~tp[3],                 // 1
	                         tp[2]};                         // 0
	logic [7:0] tprot_reg;

	// zombraid ADC0834: gun_w 0xf00000 (bit 0 CLK, 1 DI, 2 /CS), gun_r 0xf00002 (DO)
	wire is_gun_w = has_gun && (q_a[23:1] == 23'h780000);   // 0xf00000
	wire is_gun_r = has_gun && (q_a[23:1] == 23'h780001);   // 0xf00002
	logic [2:0] gun_reg;
	wire        gun_do;

	adc0834 u_adc (
		.clk(clk), .reset(reset),
		.cs_n(gun_reg[2]), .sclk(gun_reg[0]), .di(gun_reg[1]), .dout(gun_do),
		.ch0(gun_ch[7:0]), .ch1(gun_ch[15:8]), .ch2(gun_ch[23:16]), .ch3(gun_ch[31:24])
	);

	wire [23:0] xram_base = pal_base - 24'h400;
	wire is_xram    = has_xram && (q_a >= xram_base) && (q_a < xram_base + xram_span);

	// Bus sequencing. acc_ready is a held level, DTACK, until AS rises. RAM and
	// I/O accesses take four cycles (S_MEM..S_MEM4): the request (address, data,
	// decode) is registered in S_MEM, io_req asserted in S_MEM2, the read
	// captured in S_MEM4. Registers everything leaving the module (timing).
	typedef enum logic [3:0] { S_IDLE, S_ROM, S_MEM, S_MEM2, S_MEM3, S_MEM4, S_DONE } state_t;
	state_t state;

	wire [23:0] wram_off = (q_a - wram_base) & wram_mask;

	wire [15:0] io_sel_comb = {is_pit,  // 15 IO_PIT
	                   is_prot,       // 14 IO_PROT
	                   is_xram,       // 13
	                   is_wram2,      // 12
	                   is_dsw,        // 11
	                   is_inputs,     // 10
	                   is_vregs,      //  9
	                   is_x1,         //  8
	                   is_l1c,        //  7
	                   is_l0c,        //  6
	                   is_l1v,        //  5
	                   is_l0v,        //  4
	                   is_sprcode,    //  3
	                   is_sprc,       //  2
	                   is_spry,       //  1
	                   is_pal};       //  0

	logic [15:0] rd_data;
	logic        dbg_sent;

	logic [23:1] q_addr;
	logic [15:0] q_wdata;
	logic        q_we, q_uds, q_lds;
	logic        q_wram, q_wram_wel, q_wram_weh;
	logic        q_wdog, q_tprot, q_gun;
	logic [19:1] q_wram_addr;
	logic [15:0] q_sel;

	// rom_addr registered (timing); addr24 is stable through the access
	logic [23:1] q_rom_addr;

	// ROM word latched on rom_valid. The bridge packs the even byte low; the
	// 68000 is big-endian, so the word is swapped here.
	parameter bit ROM_BYTESWAP = 1'b1;
	wire [15:0] rom_word = ROM_BYTESWAP ? {rom_data[7:0], rom_data[15:8]} : rom_data;

	always_ff @(posedge clk) begin
		rom_req <= 1'b0;                 // a PULSE, per the bridge's contract
		dbg_stb <= 1'b0;

		if (reset) begin
			state     <= S_IDLE;
			acc_ready <= 1'b0;
			dbg_sent  <= 1'b0;
			rd_data   <= 16'h0000;
			tprot_reg <= 8'h00;
			gun_reg   <= 3'b100;             // /CS high: the ADC idle
		end else begin
			case (state)
				S_IDLE: begin
					q_a <= addr24;
					if (acc_active && !acc_ready) begin
						if (is_rom && !acc_write) begin
							rom_req    <= 1'b1;
							q_rom_addr <= addr24[23:1];
							state      <= S_ROM;
						end else begin
							state <= S_MEM;
						end
					end
				end

				S_ROM: begin
					if (rom_valid) begin
						rd_data   <= rom_word;
						acc_ready <= 1'b1;
						state     <= S_DONE;
					end
				end

				S_MEM: begin
					q_addr      <= q_a[23:1];
					q_wdata     <= cpu_dout;
					q_we        <= acc_write;
					q_uds       <= ~n_uds;
					q_lds       <= ~n_lds;
					q_sel       <= io_sel_comb;
					io_extra    <= is_extra;
					q_wram      <= is_wram;
					q_wdog      <= is_wdog;
					q_tprot     <= is_tprot_r;
					q_gun       <= is_gun_r;
					// Each arm sized explicitly: the main offset must wrap in 11 bits
					// (the xram window below the palette), pal2 needs 15.
					pal_index_w <= is_pal2 ? pal_off_2 : {1'b0, pal_off_main};
					if (is_tprot_w && acc_write) tprot_reg <= tprot_next;
					if (is_gun_w && acc_write && !n_lds) gun_reg <= cpu_dout[2:0];
					q_wram_addr <= wram_off[19:1];
					q_wram_wel  <= is_wram && acc_write && !n_lds;
					q_wram_weh  <= is_wram && acc_write && !n_uds;
					state       <= S_MEM2;
				end
				S_MEM2: begin
					q_wram_wel <= 1'b0;
					q_wram_weh <= 1'b0;
					state      <= S_MEM3;
				end
				S_MEM3: if (!io_hold) state <= S_MEM4;
				S_MEM4: begin
					rd_data   <= q_wdog  ? 16'hFFFF
					           : q_tprot ? {8'd0, tprot_reg}
					           : q_gun   ? {15'd0, gun_do}
					           : q_wram  ? wram_rdata : io_rdata;
					acc_ready <= 1'b1;
					state     <= S_DONE;
				end

				S_DONE: begin
					// the trace strobe on the first cycle, while the bus still
					// holds the access; ready held until the cycle ends
					if (!dbg_sent) begin
						dbg_sent  <= 1'b1;
						dbg_stb   <= 1'b1;
						dbg_addr  <= addr24[23:1];
						dbg_we    <= acc_write;
						dbg_data  <= acc_write ? cpu_dout : rd_data;
					end
					if (as_n) begin
						acc_ready <= 1'b0;
						dbg_sent  <= 1'b0;
						state     <= S_IDLE;
					end
				end
			endcase
		end
	end

	assign cpu_din    = rd_data;


	assign coins_at8  = coins_hi;

	assign rom_addr   = q_rom_addr;

	assign wram_addr  = q_wram_addr;
	assign wram_wdata = q_wdata;
	assign wram_wel   = q_wram_wel;
	assign wram_weh   = q_wram_weh;

	assign io_req   = (state == S_MEM2);
	assign io_we    = q_we;
	assign io_addr  = q_addr;
	assign io_wdata = q_wdata;
	assign io_uds   = q_uds;
	assign io_lds   = q_lds;
	assign io_sel   = q_sel;
	// all sixteen positions written out

// synthesis translate_off
	// simulation: a board value with no map
	always_ff @(posedge clk) begin
		if (!reset && board_unmapped)
			$fatal(1, "maincpu: board=%0d has no memory map", board);
	end

	// simulation: no region may start inside the ROM range (is_rom wins reads)
	always_ff @(posedge clk) begin
		if (!reset) begin
			if (wram_base <= rom_end)
				$fatal(1, "maincpu: board=%0d work RAM at %06x is inside ROM (rom_end %06x)",
				       board, wram_base, rom_end);
			if (has_wram2 && wram2_base != NONE && wram2_base <= rom_end)
				$fatal(1, "maincpu: board=%0d work RAM 2 at %06x is inside ROM (rom_end %06x)",
				       board, wram2_base, rom_end);
			if (pal_base != NONE && pal_base <= rom_end)
				$fatal(1, "maincpu: board=%0d palette at %06x is inside ROM (rom_end %06x)",
				       board, pal_base, rom_end);
			if (has_xram && xram_base <= rom_end)
				$fatal(1, "maincpu: board=%0d palette SRAM at %06x is inside ROM (rom_end %06x)",
				       board, xram_base, rom_end);
			if (x1_base != NONE && x1_base <= rom_end)
				$fatal(1, "maincpu: board=%0d X1-010 at %06x is inside ROM (rom_end %06x)",
				       board, x1_base, rom_end);
			if (in_base != NONE && in_base <= rom_end)
				$fatal(1, "maincpu: board=%0d inputs at %06x are inside ROM (rom_end %06x)",
				       board, in_base, rom_end);
			if (dsw_base != NONE && dsw_base <= rom_end)
				$fatal(1, "maincpu: board=%0d DSW at %06x is inside ROM (rom_end %06x)",
				       board, dsw_base, rom_end);
		end
	end
// synthesis translate_on

endmodule

`default_nettype wire
