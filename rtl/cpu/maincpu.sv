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
		BOARD_MADSHARK  = 5'd16   // madshark_map   -- kamenrid's registers,
		                          //                   magspeed's inputs
	} board_t;
endpackage

import seta_board_pkg::*;

module maincpu (
	input  wire         clk,
	input  wire         reset,

	// Memory-map family. See seta_board_pkg above.
	// FIVE bits. Four held sixteen maps and fifteen were used once oisipuzl
	// and magspeed got arms of their own -- and the guard against an
	// unmapped board was a `board > BOARD_PAIRLOVE` comparison that a full
	// 4-bit field can never satisfy, so it had stopped guarding anything.
	// The guard now comes from the decode's own default arm; this widening
	// is just headroom.
	input  wire  [4:0]  board,

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
	// The palette window's base as a WORD index, low 11 bits. The palette
	// is the one region whose base is not aligned to its own size --
	// 0x?00400 on every Group C board, 0x?00000 on every other -- so its
	// consumer must subtract rather than mask. Exported from here because
	// this is where pal_base is decided.
	// THE FINISHED PALETTE INDEX, not a base for seta_core to subtract from.
	// It used to be `io_addr[11:1] - pal_base_w`, which works only while the
	// whole palette lives inside one 4 KB page. blandia's second window at
	// 0x703c00-0x7047ff straddles two, so the subtraction has to happen here
	// where the full address still exists.
	output logic [11:0] pal_index_w,
	// COINS is at in_base+8 on this board, not +4 -- seta_core's input mux
	// needs it to answer index 4 with COINS instead of P3.
	output wire         coins_at8,
	// This access is daioh's EXTRA port rather than P1/P2/COINS.
	output logic        io_extra,
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
	localparam int IO_XRAM     = 13;  // RAM above the palette, where MAME maps one
	// pairlove only. seta.cpp calls it protection; prot_r returns the current
	// value and then reverts that cell to the PREVIOUS value written to it, so
	// it is a one-deep write history and not an algorithm. Two small RAMs.
	localparam int IO_PROT     = 14;
	// The uPD71054C. 0xc00000 on most of the boards that have one,
	// 0xd00000 on wrofaero and magspeed.
	localparam int IO_PIT      = 15;

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
	logic [23:0] pit_base;
	logic [23:0] vregs_base;
	logic [23:0] in_base, dsw_base;
	// extdwnhl_map's watchdog, which is a READ that must return 0xFFFF.
	logic [23:0] wdog_base;
	// Thunder & Lightning's protection PAL. NONE on every other board.
	logic        has_tprot;
	// THE PALETTE SRAM IS A CHIP, AND ITS SIZE VARIES. kamenrid_map and
	// magspeed_map declare 16 KB behind the palette (0x?01000-0x?03fff);
	// rezon_map, zingzip_map and daioh_map declare 64 KB (0x701000-0x70ffff).
	// The power-on test walks the whole chip. jjsquawk's reports PALETTE RAM
	// NG at 0x704000 -- the first address past a 16 KB window -- and no game
	// on either map writes above 0x704000 after its test (measured with a
	// MAME write tap on all six sets), so the extra 48 KB exists to let the
	// test pass, which is still the honest thing to give it.
	logic [23:0] xram_span;
	// blandia's second palette RAM, the one the palette-offset effect reads.
	// Its 1536 words sit ABOVE the first window's in one array, at 0x600.
	logic [23:0] pal2_base;
	// HOW BIG THE INPUT WINDOW IS, and whether COINS sits at +8 rather
	// than +4. Both are per map: wits reads P3 at +8 and P4 at +0xa, and
	// kamenrid_map puts COINS at +8 above its own four-byte DSW. A flat
	// six bytes left kamenrid's Country jumper and wits' two extra players
	// decoding nowhere.
	logic  [4:0] in_span;
	logic        coins_hi;
	// daioh_map's EXTRA port, buttons 4-6 for both players. It is inside
	// the vregs window and has to be taken out of it: io_sel is one-hot.
	logic        has_extra;
	logic [23:0] extra_base;
	logic [23:0] prot_base;
	logic        has_l0, has_l1, has_wram2;
	// THE PALETTE SRAM. On the Group C boards the palette is 0xC00 bytes
	// of a 16 KB SRAM at 0x?00000, and the self-tests walk the SRAM:
	// kamenrid_map marks 0x700000-0x7003ff "Palette RAM (tested)" and
	// 0x701000-0x703fff after it, daioh_map maps 0x700000-0x7003ff and
	// 0x701000-0x70ffff. Without the rest of the chip Daioh reports COLOR
	// NG at 701000 and Magical Speed PALETTE RAM NG, and both stop there.
	// has_xram: a 16 KB block at pal_base - 0x400. msgundam and oisipuzl
	// map only the palette.
	logic        has_xram;
	// TAILS. kamenrid_map and magspeed_map mark 0x804000-0x807fff,
	// 0x884000-0x887fff and 0xb04000-0xb07fff "tested": each VRAM and the
	// sprite code RAM is a 32 KB SRAM of which the chip uses the lower
	// half, and the test walks all of it. has_tails widens those three
	// windows to 32 KB; the core puts plain RAM behind the upper halves.
	logic        has_tails;
	logic [23:0] wram_mask;
	// Set by the decode's default arm: this board value has no map.
	logic        board_unmapped;

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
		pit_base     = NONE;
		vregs_base   = 24'h500000;
		in_base      = 24'h400000;  dsw_base   = 24'h600000;
		wdog_base    = NONE;
		has_tprot    = 1'b0;
		xram_span    = 24'h4000;
		pal2_base    = NONE;
		in_span      = 5'd6;        coins_hi   = 1'b0;
		has_extra    = 1'b0;        extra_base = NONE;
		prot_base    = NONE;
		has_l0 = 1'b1; has_l1 = 1'b1; has_wram2 = 1'b1;
		has_xram = 1'b0; has_tails = 1'b0;
		board_unmapped = 1'b0;

		case (board)
			BOARD_TWO_LAYER: begin                   // rezon_map / wrofaero_map
				has_xram = 1'b1;
				xram_span = 24'h10000;               // the 64 KB chip
				has_tails = 1'b1;
				// wrofaero_map maps the uPD71054C at 0xd00000 and acks IPL 4
				// at 0xf00000. rezon has neither, and a NONE base leaves
				// is_pit low so nothing decodes there.
				pit_base = 24'hD00000;
			end

			BOARD_DAIOH: begin                       // daioh_map
				has_xram = 1'b1;
				xram_span = 24'h10000;               // the 64 KB chip
				has_tails = 1'b1;
				// ROM IS 1 MB HERE, NOT 2. daioh_map is
				//   map(0x000000, 0x0fffff).rom()
				//   map(0x100000, 0x10ffff).ram()
				// and the work RAM starts where the Group C default rom_end
				// (0x1FFFFF) still claims ROM. is_rom is `addr24 <= rom_end`
				// and the read path takes is_rom first, so every read back from
				// work RAM fetched SDRAM past the end of the program image
				// while the writes landed in RAM correctly. The game wrote its
				// variables and read back rubbish: on hardware it managed 129
				// sound-chip writes and never touched the video hardware at all.
				rom_end   = 24'h0FFFFF;
				wram_base = 24'h100000; wram_end = 24'h10FFFF;
				has_extra = 1'b1;       extra_base = 24'h500006;
				wram2_base = NONE;      has_wram2 = 1'b0;
			end

			BOARD_EXTDWNHL: begin                    // extdwnhl_map
				has_xram = 1'b1;
				has_tails = 1'b1;
				pal_base = 24'h600400; pal_end = 24'h600FFF;
				dsw_base = 24'h400008;
				// THE SOUND CHIP IS AT 0xE00000 ON THIS MAP, not the 0xC00000
				// the defaults carry:
				//   map(0xe00000, 0xe03fff).rw(m_x1snd, word_r, word_w)
				// Left at the default, every X1-010 write from Extreme
				// Downhill and Sokonuke Taisen decoded to nothing -- both
				// games ran, rendered, and were silent, with w_x1snd at 0.
				x1_base  = 24'hE00000;
				// THE WATCHDOG READ IS LOAD-BEARING. extdwnhl_map is
				//   map(0x40000c, 0x40000d).r(extdwnhl_watchdog_r)
				//                          .w(watchdog reset16_w)
				// and seta.cpp's comment on it is "MUST RETURN $FFFF".
				// The POST at 0x3736 uses the value as a BYTE COUNT:
				//     move.w  $40000c.l, D0
				//     move.l  D0, D1
				//     move.b  #$aa, (A1)+   <- 0x3740
				//     subq.l  #1, D1
				//     bne     $3740
				// Undecoded, it read zero, the subtract wrapped, and the fill
				// walked the whole address space writing 0xAA -- palette
				// included, which put 0xAAAA in every entry and painted the
				// screen one flat colour (82,173,82). The branch ring was
				// twenty copies of 0x3740.
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
				// THE SOUND CHIP AND THE TIMER ARE NOT WHERE THE OTHER TWO-LAYER
				// BOARDS PUT THEM. kamenrid_map:
				//   map(0xc00000, 0xc00007) pit8254
				//   map(0xd00000, 0xd03fff) x1_010
				// With the Group C defaults (x1 at 0xc00000, no PIT) the game's
				// timer writes landed in the sound chip's registers and its
				// sound writes decoded nowhere.
				x1_base    = 24'hD00000;
				pit_base   = 24'hC00000;
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

			// oisipuzl_map SWAPS THE PALETTE AND THE SOUND CHIP relative to
			// every other two-layer board -- palette at 0xc00400, X1-010 at
			// 0x700000 -- and puts the DSW at 0x300000, where the default
			// two-layer arrangement has its second work RAM. Decoded as
			// BOARD_TWO_LAYER the game's palette writes went into the sound
			// chip and its DSW reads hit RAM.
			BOARD_OISIPUZL: begin                    // oisipuzl_map
				rom_end    = 24'h17FFFF;             // two ROM ranges, 0 and 0x100000
				wram_end   = 24'h20FFFF;
				wram2_base = NONE; has_wram2 = 1'b0; // 0x300000 is the DSW here
				dsw_base   = 24'h300000;
				x1_base    = 24'h700000;
				pal_base   = 24'hC00400; pal_end = 24'hC00FFF;
			end

			// magspeed_map moves nearly everything: the inputs to 0x500000,
			// the DSW to 0x500008, the video registers to 0x500015 and both
			// interrupt acknowledges into the same block, with the sound chip
			// and timer swapped as on kamenrid.
			BOARD_MADSHARK: begin                    // madshark_map
				rom_end    = 24'h0FFFFF;
				wram_end   = 24'h20FFFF;
				wram2_base = NONE; has_wram2 = 1'b0;
				// COINS at +4 and the DSW at +8 -- the opposite way round from
				// kamenrid, whose COINS sits above its own DSW.
				// COINS at +4 puts the window at the default six bytes;
				// the DSW sits above it, out of the way.
				in_base    = 24'h500000;
				dsw_base   = 24'h500008;
				vregs_base = 24'h600000;
				// No RAM below the palette and no tail above either VRAM: this
				// board's map declares neither, so has_xram and has_tails stay
				// low and the windows are the 16 KB the chips use.
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
				// 0x500015, reached as vregs_base + vregs_ofs; the range must
				// clear the acknowledges at 0x500018 and 0x50001c.
				vregs_base = 24'h500010;
				x1_base    = 24'hD00000;
				pit_base   = 24'hC00000;
			end

			BOARD_BLANDIA: begin                     // blandia_map
				has_xram = 1'b1;
				has_tails = 1'b1;
				// 0x200000-0x21FFFF in two blocks, plus 0x300000 -- the
				// defaults above are already right. Do NOT truncate.
				spry_base    = 24'h800000; sprc_base = 24'h800600;
				sprcode_base = 24'h900000;
				l0c_base     = 24'hA00000; l1c_base  = 24'hA80000;
				l0v_base     = 24'hB00000; l1v_base  = 24'hB80000;
				// THE SECOND PALETTE RAM, which is what the palette-offset
				// effect reads. 0x703c00-0x7047ff: 1536 words, landing at
				// entry 0x600 of one array. It straddles two 4 KB pages,
				// which is why the index is formed here and not in
				// seta_core.sv. Its first 0x400 bytes also fall inside the
				// xram window -- harmless, the palette wins the read.
				pal2_base = 24'h703C00;
			end

			BOARD_BLANDIAP: begin                    // blandiap_map
				// The prototype is on the DEFAULT layer layout, not
				// blandia_map's shifted one: VRAM at 0x800000/0x880000 and
				// sprite code at 0xb00000, like zingzip. Only the two work
				// RAM blocks, the tails and the second palette are shared.
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
				// The protection PAL is thunderl_map's alone -- wits_map has
				// neither the write window nor the read, and puts P3/P4 in
				// the input span where the read would be.
				has_tprot  = (board == BOARD_THUNDERL);
				rom_end    = 24'h0FFFFF;
				wram_base  = 24'hFFC000; wram_end  = 24'hFFFFFF;
				// wits is the four-player one: P3 at +8, P4 at +0xa.
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

			// NOT the two-layer defaults. A board with no arm would decode most
			// addresses to the wrong region and read as a CPU fault, so say so.
			default: board_unmapped = 1'b1;
		endcase
	end

	// is_rom is the ONE decode taken from the live address: S_IDLE needs it
	// in the cycle the access appears, and it is a single compare.
	wire is_rom     = (addr24 <= rom_end);

	// Every other region is decoded from q_a, a copy of the address latched
	// in S_IDLE. The decode is consumed in S_MEM, one cycle later, and the
	// address has not moved in between -- the CPU is stalled by cpu_clkena
	// from the moment acc_active goes high -- so the copy is the same value.
	//
	// What it buys: addr24 is a32, TG68K's combinational address output, the
	// sum off its effective-address adder fed from the register file M10K.
	// With the compares hung off it, the worst path in the design ran
	// regfile -> adder -> compares -> q_sel at -0.131 ns, and the M10K's own
	// clock-to-out put 2.4 ns of skew on top. From q_a the same compares
	// start at a plain register with a whole cycle to themselves.
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
	// 16 KB the chip uses, or the whole 32 KB SRAM where the test walks it.
	wire [23:0] vwin = has_tails ? 24'h8000 : 24'h4000;
	wire is_sprcode = (q_a >= sprcode_base) && (q_a < sprcode_base + vwin);
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
	// The hole is kamenrid's: its DSW lives inside the span, at +4..+7,
	// and has its own select. Subtracting it here keeps the two windows
	// disjoint rather than relying on the read mux's if/else order.
	wire is_inputs  = is_extra ||
	                  (q_a >= in_base) && (q_a < in_base + {19'd0, in_span})
	               && !(coins_hi && (q_a >= in_base + 24'h4)
	                             && (q_a <  in_base + 24'h8));
	wire is_dsw     = (q_a >= dsw_base)   && (q_a <  dsw_base + 24'h4);
	wire is_wdog    = (wdog_base != NONE) && (q_a >= wdog_base)
	               && (q_a <  wdog_base + 24'h2);

	// -----------------------------------------------------------------
	// Thunder & Lightning's protection PAL (thunderl_protection_w/_r).
	//
	//     map(0x400000, 0x41ffff).w(thunderl_protection_w)
	//     map(0xb0000c, 0xb0000d).r(thunderl_protection_r)
	//
	// THE DATA WRITTEN IS DISCARDED. The register is a function of the
	// write ADDRESS alone -- seta.cpp spells out the PAL's inputs, and the
	// 17-bit offset into the window is what feeds them. So a 128 KB write
	// window is not a 128 KB region: it is one 8-bit register with the
	// address bus wired into its combinational input.
	// -----------------------------------------------------------------
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
	wire [23:0] xram_base = pal_base - 24'h400;
	wire is_xram    = has_xram && (q_a >= xram_base) && (q_a < xram_base + xram_span);

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
	logic        acc_ready;

	// THE REGISTERED REQUEST STAGE. Everything that crosses out of this module
	// during an access is taken from these, not from the CPU's outputs.
	logic [23:1] q_addr;
	logic [15:0] q_wdata;
	logic        q_we, q_uds, q_lds;
	logic        q_wram, q_wram_wel, q_wram_weh;
	logic        q_wdog, q_tprot;
	logic [19:1] q_wram_addr;
	logic [15:0] q_sel;

	// rom_addr is REGISTERED, not wired straight out of addr24.
	//
	// addr24 is a32, which is TG68K's combinational address output -- the sum
	// coming off its address adder. Driving the bridge from it put that adder,
	// the bridge's 23-bit tag comparator and the tag_inflight enable in one
	// 96 MHz cycle: measured as the worst path in the design at +0.133 ns
	// slack (adder -> always0~0..2 -> tag_inflight[20]~0 -> tag_inflight[1]).
	//
	// The value does not change: the CPU is stalled by cpu_clkena from the
	// moment acc_active goes high until acc_ready, so addr24 is already held
	// for the whole access. Latching it in the same cycle that sets rom_req --
	// which is itself registered, so it and the address arrive together --
	// hands the bridge a register instead of an adder, and gives the fitter
	// something it can place next to it.
	logic [23:1] q_rom_addr;

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
			tprot_reg <= 8'h00;
		end else begin
			case (state)
				S_IDLE: begin
					// Every idle cycle, not just the one that starts an
					// access: the value at the S_IDLE -> S_MEM edge is the
					// one S_MEM decodes.
					q_a <= addr24;
					if (acc_active && !acc_ready) begin
						if (is_rom && !acc_write) begin
							rom_req    <= 1'b1;
							q_rom_addr <= addr24[23:1];
							state      <= S_ROM;
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
					// BOTH ARMS ARE SIZED EXPLICITLY. Written as one ternary
					// the 12-bit pal2 arm widens the main one, and the main
					// one MUST wrap in eleven bits: the xram window below the
					// palette produces a negative offset, which in eleven bits
					// lands at 0x600-0x7ff and is what the read path serves
					// back. Widened, it became 0xe00-0xfff, the write was
					// dropped as out of range and the read still came from
					// 0x600-0x7ff -- so a game's power-on RAM test read back
					// what it had never written and failed.
					//
					// pal2 needs FIFTEEN address bits, not thirteen:
					// 0x703c00-0x7047ff crosses 0x704000, so anything
					// narrower wraps in the middle of the window.
					pal_index_w <= is_pal2 ? pal_off_2 : {1'b0, pal_off_main};
					if (is_tprot_w && acc_write) tprot_reg <= tprot_next;
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
					rd_data   <= q_wdog  ? 16'hFFFF
					           : q_tprot ? {8'd0, tprot_reg}
					           : q_wram  ? wram_rdata : io_rdata;
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
		if (!reset && board_unmapped)
			$fatal(1, "maincpu: board=%0d has no memory map", board);
	end

	// NOTHING MAY LIE INSIDE THE ROM RANGE. is_rom is `addr24 <= rom_end` and
	// the read path takes it first, so a region that starts at or below
	// rom_end is readable only as ROM: writes go to the region and reads come
	// back from SDRAM. BOARD_DAIOH shipped like that -- its map has 1 MB of
	// ROM and work RAM at 0x100000, but the arm left the Group C default
	// rom_end of 0x1FFFFF -- and the boot trace could not see it, because the
	// first few hundred accesses never read a variable back.
	//
	// Checked here rather than in a script because every bench instantiates
	// this module, so every bench checks it.
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
