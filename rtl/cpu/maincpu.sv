// Seta main CPU: TG68KdotC_Kernel plus address decode and bus sequencing.
//
// One instance serves every in-scope board. All of them are plain M68000, so
// the kernel's CPU port is tied to 2'b00; what varies between boards is the
// MEMORY MAP, and seta.cpp has thirteen distinct ones across the sets in
// docs/ROADMAP.md's scope. The `board` input selects which.
//
// See rtl/cpu/tg68k/PROVENANCE.md for why the kernel is instantiated DIRECTLY
// rather than through TG68K.vhd. Short version: TG68K.vhd is an async-68000-bus
// adapter full of falling-edge registers that assumes CLK is the CPU clock, and
// rate-limiting it means fighting its design and then writing multicycle
// constraints dangerous enough to fail only on silicon. The kernel is all
// rising-edge and has clkena_in for exactly this.
//
// Consequences of driving the kernel directly, all of which DELETE code:
//   * busstate says what the CPU wants -- 00 fetch code, 10 read data,
//     11 write data, 01 no memory access (the CPU free-runs).
//   * data_in and data_write are SEPARATE ports. No bidirectional DATA net, so
//     no tri-state, and none of the Quartus tri-state-resolution trouble the
//     vendored core's provenance documents.
//   * There is no DTACK. The CPU is stalled purely by holding clkena low.
//   * IPL_autovector is tied high; no VPA/E-clock games.
//
// ---------------------------------------------------------------------------
// IPL IS INVERTED INSIDE THE KERNEL (`IPL_nr <= NOT IPL`), read from the source
// rather than inferred from real-68000 pin naming. Requesting level 2 means
// driving IPL = 3'b101. This module therefore drives `~ipl_level`, so level 0
// (no interrupt) becomes 3'b111.
// ---------------------------------------------------------------------------

`default_nettype none

package seta_board_pkg;
	// Memory-map families. These MUST agree with scripts/mame_capture.py's
	// FAMILIES/GAMES table, which is where each one was transcribed from its
	// `*_map` function in seta.cpp and where it was checked -- every family's
	// work RAM was cross-checked against the real reset stack pointer of every
	// game assigned to it, which caught seven wrong entries. Treat that table
	// as the authority and this as its RTL mirror.
	typedef enum logic [3:0] {
		BOARD_TWO_LAYER = 4'd0,   // rezon_map / zingzip_map / wrofaero_map
		BOARD_DAIOH     = 4'd1,   // daioh_map      -- work RAM at 0x100000
		BOARD_EXTDWNHL  = 4'd2,   // extdwnhl_map   -- palette at 0x600400
		BOARD_KAMENRID  = 4'd3,   // kamenrid_map   -- vregs at 0x600003
		BOARD_MSGUNDAM  = 4'd4,   // msgundam_map   -- sprites and tilemaps swap
		BOARD_BLANDIA   = 4'd5,   // blandia_map
		BOARD_BLANDIAP  = 4'd6,   // blandiap_map   -- NOT blandia_map
		BOARD_DRGNUNIT  = 4'd7,   // drgnunit_map   -- one layer, two work RAMs
		BOARD_THUNDERL  = 4'd8,   // thunderl_map   -- no layers
		BOARD_WITS      = 4'd9,   // wits_map       -- thunderl plus spare RAM
		BOARD_UMANCLUB  = 4'd10,  // umanclub_map   -- NOT thunderl_map
		BOARD_BLOCKCAR  = 4'd11,  // blockcar_map
		BOARD_ATEHATE   = 4'd12,  // atehate_map    -- 1 MB of work RAM
		BOARD_PAIRLOVE  = 4'd13   // pairlove_map   -- 2048 palette entries,
		                          //                   plus a protection RAM
	} board_t;
endpackage

import seta_board_pkg::*;

module maincpu (
	input  wire         clk,
	input  wire         reset,

	// Memory-map family. See seta_board_pkg above.
	input  wire  [3:0]  board,

	// CPU clock enable TICK -- one pulse per emulated CPU cycle, generated
	// outside this module so the 16 MHz and 8 MHz boards, and the three
	// 14.318181 MHz ones, can all be served from one clk_sys. This module
	// gates it further: the CPU only advances on a tick when the current bus
	// access has completed.
	input  wire         cpu_ce,

	// ---- Program ROM, through the SDRAM transport ---------------------------
	// rom_req is a ONE-CYCLE PULSE with rom_addr held until rom_valid. That is
	// sdram_narrow_bridge.sv's stated contract ("clients PULSE req -- a held req
	// would re-trigger this bridge"), and it is the OPPOSITE of what
	// sdram_arbiter.sv wants from its own clients ("c_req is a LEVEL held until
	// the matching c_valid"). Two transports, two conventions, and
	// LESSONS_LEARNED has an entry for each. Check the transport this is
	// actually wired to rather than assuming this comment is still right.
	output logic        rom_req,
	output logic [23:1] rom_addr,      // WORD address
	input  wire         rom_valid,
	input  wire  [15:0] rom_data,

	// ---- Work RAM (block RAM) ----------------------------------------------
	// Widest case is atehate's 1 MB at 0x900000-0x9FFFFF, hence [19:1]. Boards
	// with less simply never address the top of it.
	//
	// A megabyte is far more block RAM than the device has to spare, and
	// docs/ROADMAP.md already flags work RAM as the dominant BRAM term. Note
	// though that `map(0x900000, 0x9fffff).ram()` is MAME allocating the whole
	// decoded window, not evidence the board is populated with 1 MB -- real
	// hardware of this era almost certainly fits less and mirrors it. Sizing
	// this per board, from what each game actually touches, is an open item;
	// the address is full-width here so the simulation is honest in the
	// meantime rather than silently aliasing.
	output logic [19:1] wram_addr,
	output logic        wram_wel, wram_weh,
	output logic [15:0] wram_wdata,
	input  wire  [15:0] wram_rdata,

	// ---- Everything else ----------------------------------------------------
	// One generic secondary bus rather than a port per region. The decode below
	// already knows which region an address belongs to; routing it is the
	// core's job, not the CPU's. Adding palette or sprite RAM later is
	// connecting a consumer, not redoing this module.
	//
	// io_sel is one-hot over io_region_t. io_rdata must be presented within
	// IO_LATENCY cycles of io_req; anything not driven reads as zero, which is
	// what MAME returns for an unmapped read on this hardware (checked against
	// real boot traces: thunderl reads 0x200000, which thunderl_map does not
	// map, and gets 0x0000).
	output logic        io_req,
	output logic        io_we,
	output logic [23:1] io_addr,
	output logic [15:0] io_wdata,
	output logic        io_uds, io_lds,
	output logic [15:0] io_sel,
	input  wire  [15:0] io_rdata,

	// ---- Interrupts ---------------------------------------------------------
	// Level, not a pulse. 0 = none. seta.cpp drives level 1/2 (scanline 240 and
	// 112) or 2/4, depending on the game.
	input  wire  [2:0]  ipl_level,

	// ---- Debug trace --------------------------------------------------------
	// One strobe per completed bus access, in order, so a simulation trace can
	// be diffed against scripts/mame_capture.py --boot-trace output. The whole
	// point of Phase 0 is that this diff either matches or names the first
	// place it does not.
	// ---- interrupt acknowledge ---------------------------------------------
	// A 68000 signals an acknowledge with FC = 111 (CPU space) and puts the
	// level it latched on A3..A1. TG68KdotC_Kernel.vhd does both -- FC(1 downto
	// 0) <= "11" while `interrupt`, and memaddr_a(4 downto 0) <= '1' & rIPL_nr
	// & '0' -- so rtl/cpu/seta_irq.sv can clear exactly the level being taken
	// rather than the highest one pending, which is a different thing whenever
	// a higher interrupt arrives between the CPU's decision and its
	// acknowledge cycle.
	output logic        iack,
	output logic  [2:0] iack_level,

	output logic        dbg_stb,
	output logic [23:1] dbg_addr,
	output logic        dbg_we,
	output logic [15:0] dbg_data
);

	// Region indices for io_sel. Kept narrow deliberately -- these are the
	// regions seta.cpp actually maps.
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
	localparam int IO_MISC     = 13;  // watchdog, coin counter, IRQ acks
	// pairlove only. seta.cpp calls it protection; prot_r returns the current
	// value and then reverts that cell to the PREVIOUS value written to it, so
	// it is a one-deep write history and not an algorithm. Two small RAMs.
	localparam int IO_PROT     = 14;

	// =====================================================================
	// The CPU
	// =====================================================================
	wire [31:0] a32;
	wire [15:0] cpu_dout;
	wire [15:0] cpu_din;
	wire        n_wr, n_uds, n_lds;
	wire  [2:0] fc;      // declared before the instance: a port connection to an
	                     // undeclared name is inferred as a net by ModelSim even
	                     // under `default_nettype none`, and the later explicit
	                     // declaration then collides with it.
	wire  [1:0] busstate;
	logic       cpu_clkena;

	TG68KdotC_Kernel u_cpu (
		.clk            (clk),
		.nReset         (~reset),
		.clkena_in      (cpu_clkena),
		.data_in        (cpu_din),
		.IPL            (~ipl_level),      // INVERTED inside the kernel
		.IPL_autovector (1'b1),
		.berr           (1'b0),
		.CPU            (2'b00),           // 68000
		.addr_out       (a32),
		.data_write     (cpu_dout),
		.nWr            (n_wr),
		.nUDS           (n_uds),
		.nLDS           (n_lds),
		.busstate       (busstate),
		.longword       (),
		.nResetOut      (),
		.FC             (fc),
		.clr_berr       (),
		.skipFetch      (),
		.regin_out      (), .CACR_out (), .VBR_out ()
	);

	wire        acc_active = (busstate != 2'b01);   // 01 = no memory access

	wire        acc_write  = (busstate == 2'b11);
	wire [23:0] addr24     = a32[23:0];

	// CPU space: an interrupt-acknowledge bus cycle. Qualified with an actual
	// access so a stale FC between cycles cannot clear a pending flag.
	// Placed AFTER addr24 rather than beside the other iack wiring: ModelSim
	// rejects a use before the declaration where Quartus tolerates it
	// (LESSONS_LEARNED).
	assign iack       = acc_active && (fc == 3'b111);
	assign iack_level = addr24[3:1];

	// =====================================================================
	// Address decode
	//
	// Every region is decoded on a RANGE, so word and long accesses land as
	// well as byte ones. Psikyo lost real time to a sound latch that decoded
	// only an exact byte address: word and long writes vanished silently and
	// the measured latch-write count was zero through real gameplay.
	// =====================================================================
	logic [23:0] rom_end;
	logic [23:0] wram_base, wram_end;
	logic [23:0] wram2_base, wram2_end;
	logic [23:0] pal_base, pal_end;
	logic [23:0] spry_base, sprc_base, sprcode_base;
	logic [23:0] l0v_base, l1v_base, l0c_base, l1c_base;
	logic [23:0] x1_base;
	logic [23:0] vregs_base;
	logic [23:0] in_base, dsw_base;
	logic [23:0] prot_base;
	logic        has_l0, has_l1, has_wram2;
	logic [23:0] wram_mask;

	// A base of ALL-ONES means "this board does not have that region". No real
	// map places anything at 0xFFFFFF, and it keeps the comparison uniform.
	localparam logic [23:0] NONE = 24'hFFFFFF;

	always_comb begin
		// Defaults: the two-layer arrangement, which 14 of the 35 mapped sets
		// use (rezon_map / zingzip_map / wrofaero_map).
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
		vregs_base   = 24'h500000;
		in_base      = 24'h400000;  dsw_base   = 24'h600000;
		prot_base    = NONE;
		has_l0 = 1'b1; has_l1 = 1'b1; has_wram2 = 1'b1;

		case (board)
			BOARD_TWO_LAYER: ;                       // the defaults above

			BOARD_DAIOH: begin                       // daioh_map
				wram_base = 24'h100000; wram_end = 24'h10FFFF;
				wram2_base = NONE;      has_wram2 = 1'b0;
			end

			BOARD_EXTDWNHL: begin                    // extdwnhl_map
				pal_base = 24'h600400; pal_end = 24'h600FFF;
				dsw_base = 24'h400008;
			end

			BOARD_KAMENRID: begin                    // kamenrid_map
				vregs_base = 24'h600000;
				in_base    = 24'h500000;
				dsw_base   = 24'h500004;
				wram_end   = 24'h20FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
			end

			BOARD_MSGUNDAM: begin                    // msgundam_map
				// ONE 64 KB block, but MIRRORED over 0x70000:
				//   map(0x200000, 0x20ffff).ram().mirror(0x70000)
				// so 0x200000-0x27FFFF is all the same storage.
				wram_end     = 24'h27FFFF;
				wram_mask    = 24'h00FFFF;
				wram2_base   = NONE; has_wram2 = 1'b0;
				spry_base    = 24'h800000; sprc_base = 24'h800600;
				sprcode_base = 24'h900000;
				l0v_base     = 24'hA00000; l1v_base  = 24'hA80000;
				l0c_base     = 24'hB00000; l1c_base  = 24'hB80000;
				vregs_base   = 24'h500004;
			end

			BOARD_BLANDIA: begin                     // blandia_map
				// 0x200000-0x21FFFF in two blocks, plus 0x300000 -- the
				// defaults above are already right. Do NOT truncate.
				spry_base    = 24'h800000; sprc_base = 24'h800600;
				sprcode_base = 24'h900000;
				l0c_base     = 24'hA00000; l1c_base  = 24'hA80000;
				l0v_base     = 24'hB00000; l1v_base  = 24'hB80000;
			end

			BOARD_BLANDIAP: begin                    // blandiap_map
				wram_end = 24'h21FFFF;               // two blocks, contiguous
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
				rom_end    = 24'h0FFFFF;
				wram_base  = 24'hFFC000; wram_end  = 24'hFFFFFF;
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
				// THE 3 KB OF PLAIN RAM DIRECTLY ABOVE THE PALETTE.
				// umanclub_map is:
				//     map(0x300000, 0x3003ff) palette
				//     map(0x300400, 0x300fff) ram()
				// and leaving the second undecoded is what neobattl reports as
				// a COLOR ERROR at boot: its self-test writes across the whole
				// window and reads back, and everything above 0x3003ff came
				// back as whatever the io mux happened to present.
				wram2_base = 24'h300400; wram2_end = 24'h300FFF;
				has_wram2  = 1'b1;
				pal_base   = 24'h300000; pal_end = 24'h3003FF;
				l0v_base = NONE; l1v_base = NONE; l0c_base = NONE; l1c_base = NONE;
				has_l0 = 1'b0; has_l1 = 1'b0;
				vregs_base = NONE;
			end

			BOARD_BLOCKCAR: begin                    // blockcar_map
				// INPUTS AND DSW ARE BOTH MOVED on this board, and inheriting
				// the defaults for them was silent in simulation and obvious on
				// hardware: seta.cpp's GAME line says "Title: DSW", so reading
				// the switches from 0x600000 instead of 0x300000 selected the
				// wrong title outright. The inputs were reading 0x400000
				// instead of 0x500000 at the same time.
				//
				// Checked against the driver for every board in scope, not just
				// this one: thunderl, wits and atehate are 0xb00000/0x600000,
				// umanclub is 0x400000/0x600000 (the defaults), pairlove and
				// blockcar are 0x500000/0x300000. blockcar was the only one
				// missing its override.
				in_base    = 24'h500000; dsw_base = 24'h300000;
				rom_end    = 24'h0FFFFF;
				wram_base  = 24'hF00000; wram_end = 24'hF03FFF;
				// The two "Backup RAM?" blocks, 0xf04000-0xf041ff and
				// 0xf05000-0xf050ff. Covered as one window: the gap between
				// them is undecoded on the real board, and answering there
				// instead of floating costs nothing a game can see.
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
				// atehate_map DECLARES a megabyte at 0x900000-0x9fffff, which
				// is MAME allocating the whole decoded window rather than
				// evidence the board carries 1 MB of RAM. MEASURED, from a
				// capture of the full window during play: the game touches
				// 0x900061-0x9099a19 (variables) and 0x9ffF7b-0x9ffffb (the
				// stack) and NOTHING else -- and under a 64 KB mirror those two
				// land at 0x0061-0x9a19 and 0xff7b-0xfffb, with ZERO
				// collisions. Under a 32 KB mirror there are none either.
				//
				// So the board decodes A23..A20 and ignores A19..A16, which is
				// what a 64 KB part on this address range looks like. Masking
				// to 64 KB here is what makes the core's work RAM 64 KB instead
				// of a megabyte the device does not have the block RAM for.
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
				// Nothing here shares an address with any other board, and the
				// palette is 0x1000 bytes -- 2048 entries, four times every
				// other Group A set, via gfx_pairlove's 0x200 colour base.
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

			default: ;    // the two-layer defaults; see the assertion below
		endcase
	end

	wire is_rom     = (addr24 <= rom_end);
	wire is_wram    = (addr24 >= wram_base)  && (addr24 <= wram_end);
	wire is_wram2   = has_wram2 && (addr24 >= wram2_base) && (addr24 <= wram2_end);
	wire is_pal     = (addr24 >= pal_base)   && (addr24 <= pal_end);
	wire is_prot    = (addr24 >= prot_base)  && (addr24 <  prot_base + 24'h400);
	wire is_spry    = (addr24 >= spry_base)  && (addr24 <  spry_base + 24'h600);
	wire is_sprc    = (addr24 >= sprc_base)  && (addr24 <  sprc_base + 24'h8);
	wire is_sprcode = (addr24 >= sprcode_base) && (addr24 < sprcode_base + 24'h4000);
	wire is_l0v     = has_l0 && (addr24 >= l0v_base) && (addr24 < l0v_base + 24'h4000);
	wire is_l1v     = has_l1 && (addr24 >= l1v_base) && (addr24 < l1v_base + 24'h4000);
	wire is_l0c     = has_l0 && (addr24 >= l0c_base) && (addr24 < l0c_base + 24'h6);
	wire is_l1c     = has_l1 && (addr24 >= l1c_base) && (addr24 < l1c_base + 24'h6);
	wire is_x1      = (addr24 >= x1_base)    && (addr24 <  x1_base + 24'h4000);
	wire is_vregs   = (vregs_base != NONE) && (addr24 >= vregs_base) &&
	                  (addr24 < vregs_base + 24'h8);
	wire is_inputs  = (addr24 >= in_base)    && (addr24 <  in_base + 24'h6);
	wire is_dsw     = (addr24 >= dsw_base)   && (addr24 <  dsw_base + 24'h4);

	// =====================================================================
	// Bus sequencing
	//
	// The CPU is stalled purely by holding cpu_clkena low. acc_ready is a
	// LEVEL, never a pulse: a CPU stepping on a clock enable looks at it only
	// on its own tick, and a one-cycle assertion is missed on nearly every
	// access (LESSONS_LEARNED, "DTACK/ready must be a held level").
	// =====================================================================
	// S_MEM..S_MEM4: FOUR cycles for a block-RAM or peripheral access.
	//
	// One would do for a plain registered RAM. Three was what it took for a
	// peripheral that registers the CPU interface on the way in -- which the
	// X1-010 does, because with its RAM hanging combinationally off this bus
	// the worst paths in the whole subsystem ran from TG68K's register file
	// into that RAM's inputs. Registering there and spending a cycle here
	// removes the path structurally instead of relaxing a constraint over it.
	//
	// THE FOURTH CYCLE BUYS THE SAME THING ONE LEVEL FURTHER OUT. With the
	// peripherals and both work RAMs registered, the whole-core build measured
	// -0.935 ns and every one of the fifteen worst paths launched from the same
	// place -- TG68K's register file -- ending either in a peripheral's own
	// input register (x1_001|k_wdata) or in rd_data. Both are this module
	// handing the CPU's raw outputs straight across:
	//
	//   * the WRITE path: cpu_dout fans out combinationally to every
	//     peripheral's input register at once.
	//   * the READ path: addr24 decodes to is_wram/io_sel, and that decode is
	//     the SELECT of the return mux, so the CPU's own address is in series
	//     with the mux feeding rd_data.
	//
	// So the address, the write data and the DECODE are all registered here in
	// S_MEM, io_req moves to S_MEM2, and the capture moves to S_MEM4. What
	// leaves this module is then register-driven and low fanout, and the
	// select on the return mux comes from a register rather than from the CPU.
	//
	// It costs nothing: the CPU is stalled for the whole bus cycle and steps
	// only once every six clk_sys cycles, so four cycles fit inside one
	// enable gap on the fastest board in scope.
	typedef enum logic [3:0] { S_IDLE, S_ROM, S_MEM, S_MEM2, S_MEM3, S_MEM4, S_DONE } state_t;
	state_t state;

	// Declared here, ABOVE the FSM that reads them.
	wire [23:0] wram_off = (addr24 - wram_base) & wram_mask;

	wire [15:0] io_sel_comb = {1'b0,  // 15 unused
	                   is_prot,       // 14 IO_PROT
	                   1'b0,          // 13 IO_MISC -- decoded in the core, not here
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
	logic        acc_ready;

	// THE REGISTERED REQUEST STAGE. Everything that crosses out of this module
	// during an access is taken from these, not from the CPU's outputs.
	logic [23:1] q_addr;
	logic [15:0] q_wdata;
	logic        q_we, q_uds, q_lds;
	logic        q_wram, q_wram_wel, q_wram_weh;
	logic [19:1] q_wram_addr;
	logic [15:0] q_sel;

	// Latch the ROM word on its valid pulse. NOTHING in the path from sdram.sv
	// to here holds it: the arbiter assigns c_data combinationally from a
	// register shared with the other ports, so sampling one cycle late reads
	// another client's in-flight data (LESSONS_LEARNED, "Capture read data on
	// the valid pulse").
	//
	// BYTE ORDER. sdram_narrow_bridge packs the EVEN byte address in the LOW
	// half of each 16-bit lane -- little-endian, correct for genuinely
	// little-endian regions. The 68000 is big-endian: the word at address A
	// has its high byte AT A. The swap therefore belongs here, at the seam,
	// not inside the shared bridge where it would break its other consumers
	// (LESSONS_LEARNED, "Fix byte order at the seam, with a dedicated
	// adapter"). Whether this instance needs the swap depends on how the
	// download wrote the region; it is a parameter rather than a constant so
	// the testbench can prove which way round it goes instead of arguing.
	parameter bit ROM_BYTESWAP = 1'b1;
	wire [15:0] rom_word = ROM_BYTESWAP ? {rom_data[7:0], rom_data[15:8]} : rom_data;

	always_ff @(posedge clk) begin
		rom_req <= 1'b0;                 // a PULSE, per the bridge's contract
		dbg_stb <= 1'b0;

		if (reset) begin
			state     <= S_IDLE;
			acc_ready <= 1'b0;
			rd_data   <= 16'h0000;
		end else begin
			case (state)
				S_IDLE: begin
					if (acc_active && !acc_ready) begin
						if (is_rom && !acc_write) begin
							rom_req <= 1'b1;
							state   <= S_ROM;
						end else begin
							// Block RAM and I/O: registered read latency,
							// spent rather than assumed.
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

				// S_MEM captures the request; io_req is asserted in S_MEM2
				// only, and the peripheral latches address and data on that
				// edge into its own input register.
				S_MEM: begin
					q_addr      <= addr24[23:1];
					q_wdata     <= cpu_dout;
					q_we        <= acc_write;
					q_uds       <= ~n_uds;
					q_lds       <= ~n_lds;
					q_sel       <= io_sel_comb;
					q_wram      <= is_wram;
					q_wram_addr <= wram_off[19:1];
					q_wram_wel  <= is_wram && acc_write && !n_lds;
					q_wram_weh  <= is_wram && acc_write && !n_uds;
					state       <= S_MEM2;
				end
				S_MEM2: begin
					// One cycle of write enable, from a register.
					q_wram_wel <= 1'b0;
					q_wram_weh <= 1'b0;
					state      <= S_MEM3;
				end
				S_MEM3: state <= S_MEM4;
				S_MEM4: begin
					// The select is q_wram, a register -- not the CPU's
					// address decoded on the way past.
					rd_data   <= q_wram ? wram_rdata : io_rdata;
					acc_ready <= 1'b1;
					state     <= S_DONE;
				end

				S_DONE: begin
					// Hold ready until the CPU actually takes the cycle. The
					// trace strobe fires on the same event, so dbg_* describes
					// accesses the CPU completed, in order -- not accesses this
					// FSM merely started.
					if (cpu_clkena) begin
						acc_ready <= 1'b0;
						state     <= S_IDLE;
						dbg_stb   <= 1'b1;
						dbg_addr  <= addr24[23:1];
						dbg_we    <= acc_write;
						dbg_data  <= acc_write ? cpu_dout : rd_data;
					end
				end
			endcase
		end
	end

	assign cpu_clkena = cpu_ce && (!acc_active || acc_ready);
	assign cpu_din    = rd_data;

	assign rom_addr   = addr24[23:1];

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
	// SIXTEEN ELEMENTS FOR A SIXTEEN-BIT PORT, one per IO_* index, including the
	// undriven ones. A short concatenation zero-extends on the LEFT, so adding
	// a signal at the top silently shifts every index below it -- which is how
	// is_prot first landed on IO_MISC's bit. Written out in full so the
	// positions are visible rather than inferred from the element count.

// synthesis translate_off
	// A board value with no case arm silently gets the two-layer map, which
	// would decode most addresses to the wrong region and look like a CPU
	// fault. Say so in simulation rather than letting it pass.
	always_ff @(posedge clk) begin
		if (!reset && board > BOARD_PAIRLOVE)
			$fatal(1, "maincpu: board=%0d has no memory map", board);
	end
// synthesis translate_on

endmodule

`default_nettype wire
