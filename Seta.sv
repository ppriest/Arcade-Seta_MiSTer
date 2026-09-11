//============================================================================
//
//  Seta X1-010 hardware for MiSTer -- seta/seta.cpp, Group A.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================
//
// Framework glue only. Everything that is the GAME is in rtl/seta_core.sv;
// this file owns hps_io, the PLL, the SDRAM pins, the video chain and the
// assembly of the driver's input port words. Keeping the split sharp is what
// lets sim/seta_core_tb run the whole game with no framework at all.
//
// Video chain: seta_core -> arcade_video (scandoubler, gamma) -> video_freak
// (crop, integer scale, aspect) -> the framework, with screen_rotate_two
// TAPPING the final output into a rotated HDMI framebuffer. The analog output
// keeps the native raster either way.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Ports this core does not use /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// The framebuffer's forced-blank input, a real port only because Seta.qsf
// defines MISTER_FB=1 for the HDMI rotator. screen_rotate_two does not drive
// it, so it is tied off here as every rotating core does.
assign FB_FORCE_BLANK = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

// The X1-010 mixes to a signed stereo pair.
wire signed [15:0] core_audio_l, core_audio_r;
assign AUDIO_S   = 1;
assign AUDIO_L   = core_audio_l;
assign AUDIO_R   = core_audio_r;
assign AUDIO_MIX = 0;

//////////////////////////////////////////////////////////////////

// 384x240 with square-ish pixels. The three games on a 14.318181 MHz XTAL are
// 304x240 and are not in this phase.
wire [1:0] ar = status[122:121];

wire  [1:0] game_rot;   // from seta_core, driven by the mod byte

// ROTATION. Auto is the default and follows the driver's own ROT for the set
// -- five of the eight Group A games are vertical, and coming up sideways until
// someone finds the menu is not a sensible default. The explicit settings stay
// for a cabinet that is already turned round, or a monitor that is not.
//
// game_rot comes from rtl/seta_board_cfg.sv: 0 = ROT0, 1 = ROT90, 2 = ROT270.
// A ROT270 game needs the picture turned counter-clockwise to stand upright.
wire [1:0] rot_sel   = status[64:63];
wire       rotate_en = (rot_sel == 2'd0) ? (game_rot != 2'd0)
                     : (rot_sel != 2'd1);
wire       rotate_ccw = (rot_sel == 2'd0) ? (game_rot == 2'd2)
                      : (rot_sel == 2'd3);
wire       flip_180   = status[65];

// Aspect ratio. THE PHYSICAL SCREEN IS 4:3 -- these boards drive an ordinary
// arcade monitor -- and 384x240 of active video on it means the pixels are NOT
// square. 8:5 is the pixel-count ratio, which is what was here, and it renders
// the picture too wide.
//
// When the output is rotated to portrait the original aspect becomes 3:4, so
// the two swap with rotate_en. Arcade-Psikyo_MiSTer has the same pair, for
// boards that are vertical rather than optionally rotated, and records that
// leaving it at a hardcoded 4:3 is what made its Original/Full Screen toggle
// look like it did nothing.
wire [11:0] base_arx = rotate_en ? 12'd3 : 12'd4;
wire [11:0] base_ary = rotate_en ? 12'd4 : 12'd3;

`include "build_id.v"

// The Debug page is hidden in the release revision. Every P1 line carries an
// H1 prefix, so status_menumask bit 1 hides the whole page; the bits still
// work if a .CFG sets them, only the MENU goes away.
`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif
wire debug_menu_hide = DEBUG_MENU_HIDE;
localparam CONF_STR = {
	"Seta;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[64:63],Rotation,Auto,Off,CW,CCW;",
	"O[65],Flip 180,Off,On;",
	"O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O[70:69],Crop,Off,216 lines,224 lines;",
	"O[75:71],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	// A DEBUG PAGE, not a settings page. Every switch here answers a bring-up
	// question without a rebuild, which is the practice docs/WORKFLOW.md
	// carries over from Psikyo and Fuuki: on hardware the difference between
	// "the sprite engine is dead" and "the palette is wrong" is one toggle,
	// and finding it out by rebuilding costs half an hour each time.
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[80],Sprites,On,Off;",
	"H1P1O[83],Tilemap 0,On,Off;",
	"H1P1O[84],Tilemap 1,On,Off;",
	"H1P1O[81],PCM sound,On,Off;",
	"H1P1O[82],Pause CPU,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// THE SAME POSITIONAL RULE AS THE .mra's <buttons> LIST: entry i is
	// joystick bit 4 + i. This line named five buttons, which put Start on
	// bit 6 -- the bit the core reads as COIN1 -- and it has to be padded to
	// hold Start, Coin, Pause and Service at 10, 11, 12 and 13. The unused
	// four are named rather than left empty so the alignment is visible and
	// does not depend on how the OSD treats a blank entry.
	"J1,Button 1,Button 2,Button 3,Button 4,Button 5,Button 6,Start,Coin,Pause,Service;",
	"jn,A,B,Start,Select,R;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, debug_menu_hide, 1'b0}),  // H1: the Debug page

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 96 MHz: 6x the 16 MHz 68000, 12x the believed 8 MHz dot clock, and 6x the
// X1-010's 16 MHz. Every clock enable in the core is an integer divide of it,
// which is why this frequency and not a rounder one -- see docs/ROADMAP.md.
//
// outclk_1 is the same 96 MHz shifted 180 degrees and drives SDRAM_CLK. That
// phase is carried over from Psikyo, where it is proven on real hardware; no
// simulation can check it, because the chip model has no notion of phase. See
// rtl/pll/pll_0002.v.
wire clk_sys, clk_sdram_shifted, clk_video, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.outclk_2(clk_video),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

///////////////////////   RESET   ////////////////////////////////

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// TWO RESETS, and mixing them up is the single most expensive mistake
// available here. MiSTer holds core RESET asserted for the ENTIRE ROM
// download, so anything in the MEMORY path gated by a reset that includes it
// is dead for the whole transfer: not one write reaches the chip and every
// later read returns power-up contents. Psikyo hit it; Fuuki's first bitstream
// still shipped with it, and came up as a perfectly timed, entirely black
// screen -- video timing is independent of memory, so the only symptom was
// that nothing was ever drawn.
wire core_reset = reset | ioctl_download;
wire mem_reset  = reset & ~ioctl_download;

///////////////////   .mra: mod byte and DIPs   //////////////////

// `<rom index="1">` carries one byte naming the GAME. rtl/seta_board_cfg.sv
// turns it into everything else, including which of maincpu.sv's memory maps
// to use -- one index, one table, nothing that can disagree with itself.
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd1)) mod_byte <= ioctl_dout;

// `<switches>` arrives as index 254. THREE bytes are used, and which is which
// is a decision this file and scripts/build_mra.py have to share:
//
//   sw[0]  the byte seta_dsw_r returns at OFFSET 0, i.e. the HIGH half of the
//          driver's 16-bit DSW port -- "SW1" in its PORT_DIPLOCATION names
//   sw[1]  the byte at offset 1, the LOW half -- "SW2"
//   sw[2]  the DIP bits several games put in the COINS port's top nibble
//          (thunderl's "Force 1 Life" and "Copyright", for instance)
//
// seta_dsw_r reads offset 0 as the high byte and offset 1 as the low one.
// Backwards, the game reads the wrong DIP bank and misbehaves in ways that
// look like anything except a byte order.
reg [7:0] sw[8];
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
		sw[ioctl_addr[2:0]] <= ioctl_dout;

wire [15:0] dsw_in = {sw[0], sw[1]};

///////////////////////   INPUTS   ///////////////////////////////

// Every port in this driver is IP_ACTIVE_LOW (0 = pressed) while hps_io's
// joystick words are active HIGH, hence the inversion on each concatenation.
//
// The bit order is JOY_TYPE1_2BUTTONS from seta.cpp, which is NOT the usual
// arcade order -- LEFT is bit 0 and RIGHT is bit 1, the opposite way round
// from the MiSTer joystick word:
//
//     0 LEFT   1 RIGHT   2 UP   3 DOWN   4 B1   5 B2   6 unused   7 START
//
// MiSTer's joystick word is 0 = Right, 1 = Left, 2 = Down, 3 = Up, then
// buttons from bit 4.
//
// START AND COIN ARE AT FIXED JOYSTICK BITS, and the .mra's <buttons> name
// list is positional -- entry i is bit 4 + i -- so the two have to agree.
// They did not: the core read COIN1 from bit 6 and START1 from bit 8 while the
// .mra named bit 6 "Start" and bit 7 "Coin". On hardware, Start inserted a
// coin and Coin did nothing.
//
//     bit  4  5  6  7  8  9  10     11    12     13
//          B1 B2 -  -  -  -  Start  Coin  Pause  Service
//
// Those are Arcade-Psikyo_MiSTer's positions, which is why its six-button and
// three-button sets both work. scripts/build_mra.py pads the name list to
// match.
// THE LAYOUT IS PER GAME, from seta_board_cfg.sv's input_layout. seta.cpp has
// three joystick macros and three one-off panels among the sets in scope, and
// assembling every one of them as JOY_TYPE1_2BUTTONS meant the five
// three-button games could not press button 3 at all -- bit 6 was tied low --
// and the four-answer-button games read their buttons off the joystick
// directions.
//
//   0 JOY2    LRUD at 0-3, B1 B2 at 4-5, 6 unused
//   1 JOY1    as JOY2 with 5 and 6 unused
//   2 JOY3    as JOY2 plus BUTTON3 at 6
//   3 PANEL4  B3 B4 B1 B2 at 0-3 -- atehate's default panel, and qzkklgy2
//   4 PANEL5  PANEL4 plus BUTTON5 at 4 (qzkklogy's pause cheat)
//   5 CARDS   magspeed: Card 1-4 at 0-3, B1 B2 at 4-5
//
// Bit 7 is START in all six. The MiSTer joystick word is 0 Right, 1 Left,
// 2 Down, 3 Up, buttons 1-6 at 4-9, then Start 10, Coin 11, Pause 12,
// Service 13 -- fixed positions the .mra's <buttons> list has to match.
function automatic [7:0] seta_port(input [31:0] j, input [2:0] layout);
	case (layout)
		3'd1:    seta_port = {j[10], 1'b0,  1'b0,  j[4],
		                      j[2],  j[3],  j[0],  j[1]};
		3'd2:    seta_port = {j[10], j[6],  j[5],  j[4],
		                      j[2],  j[3],  j[0],  j[1]};
		3'd3:    seta_port = {j[10], 1'b0,  1'b0,  1'b0,
		                      j[5],  j[4],  j[7],  j[6]};
		3'd4:    seta_port = {j[10], 1'b0,  1'b0,  j[8],
		                      j[5],  j[4],  j[7],  j[6]};
		3'd5:    seta_port = {j[10], 1'b0,  j[5],  j[4],
		                      j[9],  j[8],  j[7],  j[6]};
		default: seta_port = {j[10], 1'b0,  j[5],  j[4],
		                      j[2],  j[3],  j[0],  j[1]};
	endcase
endfunction

wire [2:0] input_layout;

// daioh's EXTRA port: P1 buttons 4-6 at bits 0-2, P2's at 3-5. Buttons 4, 5
// and 6 are joystick bits 7, 8 and 9. Every other board leaves it undecoded.
wire [15:0] extra_in = ~{10'h000,
	joystick_1[9], joystick_1[8], joystick_1[7],
	joystick_0[9], joystick_0[8], joystick_0[7]};

wire [15:0] p1_in = ~{8'h00, seta_port(joystick_0, input_layout)};
wire [15:0] p2_in = ~{8'h00, seta_port(joystick_1, input_layout)};

// COINS: coin 1 and 2, service, tilt, and then whatever DIP bits the game puts
// in the top nibble. sw[2] supplies those; where a game uses none of them the
// `.mra` leaves it 0xf0 and nothing changes.
wire [15:0] coins_in = {
	8'hff,
	sw[2][7:4],
	1'b1,               // 3 TILT, never asserted
	~joystick_0[13],    // 2 SERVICE1
	~joystick_1[11],    // 1 COIN2
	~joystick_0[11]     // 0 COIN1
};

// PAUSE. Edge-triggered toggle, not a level: the button is momentary, so a
// level would only pause while held.
//
// Bit 12 is a function of the button lists above -- the .mra's <buttons> and
// the OSD's J1 -- never a constant copied from another core. Both put Pause
// there, and rtl/seta_core.sv already gates cpu_ce on pause_cpu, so this is
// the whole of it.
//
// The OSD's own "Pause CPU" switch on the Debug page stays, ORed in: it is
// the one that can be left on while poking at a frozen frame, where a toggle
// button is awkward.
wire pause_btn = joystick_0[12] | joystick_1[12];
reg  pause_btn_d, pause_toggle;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                          pause_toggle <= 1'b0;
	else if (pause_btn & ~pause_btn_d)  pause_toggle <= ~pause_toggle;
end
wire pause_core = pause_toggle | status[82];

// wits alone has four players; the other seven boards never read these.
wire [15:0] p3_in = 16'hffff;
wire [15:0] p4_in = 16'hffff;

///////////////////////   THE GAME   /////////////////////////////

wire [7:0] core_r, core_g, core_b;
wire       core_hs, core_vs, core_hb, core_vb, core_de, core_ce;

// core_ce IS ONE clk_sys CYCLE WIDE, which is half a clk_video cycle -- a
// clk_video edge can fall either side of it. Stretched to two clk_sys cycles,
// exactly one clk_video edge samples it high, whichever parity it lands on.
//
// Without this the design still works or does not work DETERMINISTICALLY --
// an 8 MHz pixel is 12 clk_sys cycles, an even number, so every enable lands
// on the same parity and the video chain would see all of them or none. "None"
// is a black screen with every register correct, which is a bad hour on
// hardware; two cycles costs one flip-flop.
reg core_ce_d;
always @(posedge clk_sys) core_ce_d <= core_ce;
wire core_ce_v = core_ce | core_ce_d;

wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun;
wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped;
wire [15:0] dbg_snd_samples, dbg_snd_overrun, dbg_snd_rom_reads;
wire  [7:1] dbg_irq_pending;
wire [23:0] dbg_last_rom;
wire [15:0] dbg_rom_fetches, dbg_wram_writes, dbg_io_reads;
wire [23:0] dbg_last_io;
wire [23:0] dbg_last_vec;
wire [479:0] dbg_pc_ring;
wire         dbg_pc_frozen;
wire [23:3] dbg_l0_last_addr;
wire [63:0] dbg_l0_last_data;
wire [15:0] dbg_l0_lines, dbg_l0_tiles, dbg_l0_overrun;
wire [15:0] dbg_l1_lines, dbg_l1_tiles, dbg_l1_overrun;

// THE DOWNLOAD'S HIGH-WATER MARK, in 4096-byte units. An .mra that stops
// short leaves the CPU fetching from SDRAM that was never written, which
// looks exactly like a CPU fault and is not one. Unlike a trace buffer
// this has no idle timeout, so a pause mid-download cannot look like the
// end. Daioh's image is 11 MB, so a complete load must reach 0xB00.
reg [13:0] dbg_dl_max4k = 14'd0;
always @(posedge clk_sys) begin
	if (ioctl_download && ioctl_wr && ioctl_addr[26:12] > {1'b0, dbg_dl_max4k})
		dbg_dl_max4k <= ioctl_addr[25:12];
end

wire [15:0] dbg_w_pal, dbg_w_l0v, dbg_w_l1v, dbg_w_l0c, dbg_w_l1c, dbg_w_vregs, dbg_w_sprc, dbg_w_x1snd;
wire        dbg_cpu_stb, dbg_cpu_we;
wire [23:1] dbg_cpu_addr;
wire [15:0] dbg_cpu_data;

seta_core seta_core
(
	.clk(clk_sys),
	.reset(core_reset),
	.mem_reset(mem_reset),
	.init(~pll_locked),

	.game(mod_byte[4:0]),
	.game_rot(game_rot), .input_layout(input_layout),

	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
	// The physical clock pin is driven from the PLL above, not from here.
	.SDRAM_CLK(),

	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.p1_in(p1_in), .p2_in(p2_in), .coins_in(coins_in), .extra_in(extra_in),
	.p3_in(p3_in), .p4_in(p4_in), .dsw_in(dsw_in),

	.pause_cpu(pause_core),
	.en_spr(~status[80]),
	.en_pcm(~status[81]),
	.en_l0(~status[83]), .en_l1(~status[84]),

	.video_r(core_r), .video_g(core_g), .video_b(core_b),
	.video_hs(core_hs), .video_vs(core_vs),
	.video_hb(core_hb), .video_vb(core_vb),
	.video_de(core_de), .video_ce(core_ce),

	.audio_l(core_audio_l), .audio_r(core_audio_r),

	.dbg_last_rom(dbg_last_rom), .dbg_rom_fetches(dbg_rom_fetches),
	.dbg_wram_writes(dbg_wram_writes), .dbg_io_reads(dbg_io_reads),
	.dbg_last_io(dbg_last_io), .dbg_last_vec(dbg_last_vec),
	.dbg_pc_ring(dbg_pc_ring), .dbg_pc_frozen(dbg_pc_frozen),
	.dbg_l0_last_addr(dbg_l0_last_addr),
	.dbg_l0_last_data(dbg_l0_last_data),
	.dbg_l0_lines(dbg_l0_lines), .dbg_l0_tiles(dbg_l0_tiles),
	.dbg_l0_overrun(dbg_l0_overrun),
	.dbg_l1_lines(dbg_l1_lines), .dbg_l1_tiles(dbg_l1_tiles),
	.dbg_l1_overrun(dbg_l1_overrun),
	.dbg_w_pal(dbg_w_pal),
	.dbg_w_l0v(dbg_w_l0v),
	.dbg_w_l1v(dbg_w_l1v),
	.dbg_w_l0c(dbg_w_l0c),
	.dbg_w_l1c(dbg_w_l1c),
	.dbg_w_vregs(dbg_w_vregs),
	.dbg_w_sprc(dbg_w_sprc),
	.dbg_w_x1snd(dbg_w_x1snd),
	.dbg_lines(dbg_lines), .dbg_sprites(dbg_sprites),
	.dbg_fetches(dbg_fetches), .dbg_overrun(dbg_overrun),
	.dbg_worst_line(dbg_worst_line), .dbg_worst_sprites(dbg_worst_sprites),
	.dbg_dropped(dbg_dropped),
	.dbg_snd_samples(dbg_snd_samples), .dbg_snd_overrun(dbg_snd_overrun),
	.dbg_snd_rom_reads(dbg_snd_rom_reads),
	.dbg_irq_pending(dbg_irq_pending),
	.dbg_cpu_stb(dbg_cpu_stb), .dbg_cpu_addr(dbg_cpu_addr),
	.dbg_cpu_we(dbg_cpu_we), .dbg_cpu_data(dbg_cpu_data)
);

// ---------------------------------------------------------------------------
// THE PROBES ARE BUILT BY THE Seta_stp REVISION ONLY. `DEBUG_ISSP is set in
// Seta_stp.qsf and nowhere else, so the release revision compiles them out
// -- and with them the ring buffer, the counters and the JTAG hub they carry.
// Same source, two revisions; see docs/WORKFLOW.md.
`ifdef DEBUG_ISSP
// ---------------------------------------------------------------------------
// JTAG READBACK. The counters above were wired out of the core from the start
// and then went nowhere -- rtl/debug/ held the probe, files.qip compiled it,
// and nothing instantiated it. On the first hardware run that meant the
// instruments existed everywhere except where they were needed.
//
// PROBE LAYOUT, 128 bits. Keep scripts/read_issp.tcl's decode in step: a
// shifted field reads as plausible nonsense rather than as an error.
//
//   [ 15:  0]  dbg_lines           scanlines the sprite engine started
//   [ 31: 16]  dbg_sprites         sprites blitted
//   [ 47: 32]  dbg_overrun         line_start while still rendering (a fault)
//   [ 63: 48]  dbg_dropped         lines cut short by the per-line budget
//   [ 79: 64]  dbg_worst_sprites   most sprites completed on one line
//   [ 95: 80]  dbg_snd_samples     X1-010 output samples
//   [111: 96]  dbg_snd_rom_reads   X1-010 PCM/wave fetches from SDRAM
//   [119:112]  dbg_snd_overrun[7:0]  sample generated before the last finished
//   [126:120]  dbg_irq_pending[7:1]
//   [    127]  pll_locked
//
// The two sound counters are the ones that matter first: samples with no ROM
// reads means the chip is running but starved, ROM reads with no samples means
// the opposite, and both at zero means the CPU never programmed it.
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_issp (
	.clk(clk_sys),
	.probe({
		pll_locked,
		dbg_irq_pending,
		dbg_snd_overrun[7:0],
		dbg_snd_rom_reads,
		dbg_snd_samples,
		dbg_worst_sprites,
		dbg_dropped,
		dbg_overrun,
		dbg_sprites,
		dbg_lines
	}),
	.source()
);

// PROBE LAYOUT, INSTANCE A -- the last twenty ROM reads before an
// exception, 488 bits. Keep scripts/read_issp.tcl's decode in step.
//
//   [ 23:  0]  pc0      the newest ROM read (byte address)
//   ...                 pc1..pc19 at 24-bit steps, oldest at [479:456]
//   [480]      frozen   a fetch hit vectors 2..11 and the ring stopped
//   [487:481]  spare
//
// Instruction fetches and ROM data reads are not distinguished; the
// disassembly around the addresses says which is which.
issp_probe #(.INSTANCE_ID("A"), .PROBE_W(488), .SOURCE_W(8)) u_issp_pc (
	.clk(clk_sys),
	.probe({7'd0, dbg_pc_frozen, dbg_pc_ring}),
	.source()
);

// PROBE LAYOUT, INSTANCE B -- one granule layer 0 actually received.
//
//   [ 63:  0]  dbg_l0_last_data  the 64 bits that came back
//   [ 84: 64]  dbg_l0_last_addr  the granule address asked for
//   [108: 85]  dbg_last_vec      the last 68000 vector fetched
//   [127:109]  spare
//
// The byte address in gfx2 is dbg_l0_last_addr * 8. Compare the data
// against the ROM image at that offset: equal means SDRAM holds the
// right bytes and the fault is in the engine, different means the
// download or the arbiter put the wrong bytes there.
issp_probe #(.INSTANCE_ID("B"), .PROBE_W(128), .SOURCE_W(8)) u_issp_gran (
	.clk(clk_sys),
	.probe({19'd0, dbg_last_vec, dbg_l0_last_addr, dbg_l0_last_data}),
	.source()
);

// PROBE LAYOUT, INSTANCE C -- the two tilemap engines, 128 bits.
// Keep scripts/read_issp.tcl's decode in step.
//
//   [ 15:  0]  dbg_l0_lines     lines layer 0 started
//   [ 31: 16]  dbg_l0_tiles     tiles layer 0 blitted
//   [ 47: 32]  dbg_l0_overrun   lines layer 0 did not finish in time
//   [ 63: 48]  dbg_l1_lines
//   [ 79: 64]  dbg_l1_tiles
//   [ 95: 80]  dbg_l1_overrun
//   [127: 96]  spare
//
// An overrun count near the line count means the layer is being starved
// on the shared SDRAM port and most of its tiles never arrive -- which
// is what a mostly-black screen with a few real tiles looks like.
issp_probe #(.INSTANCE_ID("C"), .PROBE_W(128), .SOURCE_W(8)) u_issp_tile (
	.clk(clk_sys),
	.probe({
		32'd0,
		dbg_l1_overrun, dbg_l1_tiles, dbg_l1_lines,
		dbg_l0_overrun, dbg_l0_tiles, dbg_l0_lines
	}),
	.source()
);

// PROBE LAYOUT, INSTANCE D -- where the CPU is, 128 bits.
// Keep scripts/read_issp.tcl's decode in step.
//
//   [ 23:  0]  dbg_last_rom     byte address of the last program fetch
//   [ 39: 24]  dbg_rom_fetches  program fetches issued
//   [ 55: 40]  dbg_wram_writes  work RAM writes
//   [ 71: 56]  dbg_io_reads     peripheral reads
//   [ 85: 72]  dbg_dl_max4k     highest download address, in 4 KB units
//   [109: 86]  dbg_last_io      address of the last peripheral read
//   [127:110]  spare
issp_probe #(.INSTANCE_ID("D"), .PROBE_W(128), .SOURCE_W(8)) u_issp_cpu (
	.clk(clk_sys),
	.probe({
		18'd0,
		dbg_last_io,
		dbg_dl_max4k,
		dbg_io_reads,
		dbg_wram_writes,
		dbg_rom_fetches,
		dbg_last_rom
	}),
	.source()
);

// PROBE LAYOUT, INSTANCE E -- CPU writes per video region, 128 bits.
// Keep scripts/read_issp.tcl's decode in step.
//
//   [ 15:  0]  dbg_w_pal      palette writes
//   [ 31: 16]  dbg_w_l0v      layer 0 VRAM writes
//   [ 47: 32]  dbg_w_l1v      layer 1 VRAM writes
//   [ 63: 48]  dbg_w_l0c      layer 0 control writes
//   [ 79: 64]  dbg_w_l1c      layer 1 control writes
//   [ 95: 80]  dbg_w_vregs    video register writes
//   [111: 96]  dbg_w_sprc     sprite code/attribute writes
//   [127:112]  dbg_w_x1snd    sound chip writes
//
// All zero means the CPU never reached the video hardware. Palette and
// VRAM counting up while the screen stays black means it did, and the
// fault is downstream.
issp_probe #(.INSTANCE_ID("E"), .PROBE_W(128), .SOURCE_W(8)) u_issp_io (
	.clk(clk_sys),
	.probe({
		dbg_w_x1snd,
		dbg_w_sprc,
		dbg_w_vregs,
		dbg_w_l1c,
		dbg_w_l0c,
		dbg_w_l1v,
		dbg_w_l0v,
		dbg_w_pal
	}),
	.source()
);
`endif  // DEBUG_ISSP

///////////////////////   VIDEO   ////////////////////////////////

// CLK_VIDEO and CE_PIXEL are OUTPUTS of arcade_video -- it drives CLK_VIDEO
// from its own clk_video input -- so they must not be assigned here as well.
// A second driver on CLK_VIDEO propagates back to clk_sys, and Quartus then
// reports the error against the clock rather than against the line that
// caused it.
wire vga_de_raw;

// THE VIDEO CHAIN RUNS AT 48 MHz, NOT clk_sys.
//
// arcade_video's scandoubler and HQ2x blender were the last thing in the whole
// design still failing timing: -0.229 ns with TNS -3.273, every failing path
// inside Hq2x|Blend, and not one path belonging to this core. That is vendored
// framework logic, so it cannot be retimed here -- but it can be given a
// slower clock. It needs about 10.65 ns; 48 MHz gives it 20.83.
//
// This is the fix Arcade-Psikyo_MiSTer's SDC names as the structurally correct
// one, having tried and then REMOVED the obvious alternative: a setup-2
// multicycle on the blender is not backed by the hardware, because
// scandoubler.v force-asserts Blend's clock enable on hsync, so one transition
// per scanline gets no second cycle. That trade is what "HQ2x intentionally
// broken to close timing" means in other cores' release notes.
//
// 48 MHz is EXACTLY HALF of clk_sys, from the same PLL, so every clk_video
// edge is also a clk_sys edge. There is no clock-domain crossing here, and no
// SDC exception to write or audit.
arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_video),
	.ce_pix(core_ce_v),

	.RGB_in({core_r, core_g, core_b}),
	.HBlank(core_hb),
	.VBlank(core_vb),
	.HSync(core_hs),
	.VSync(core_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// CROP_SIZE is the number of lines kept out of 240: 216 is exactly 5x on a
// 1080-line display, 224 trims 8 lines top and bottom.
wire  [1:0] vcrop_sel = status[70:69];
wire [11:0] crop_size = (vcrop_sel == 2'd1) ? 12'd216 :
                        (vcrop_sel == 2'd2) ? 12'd224 : 12'd0;

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX((!ar) ? base_arx : (ar - 1'd1)),
	.ARY((!ar) ? base_ary : 12'd0),
	.CROP_SIZE(crop_size),
	.CROP_OFF(status[75:71]),
	.SCALE(status[68:66])
);

// HDMI rotation and 180 flip: a TAP, not a filter. The analog output keeps the
// native raster while a rotated copy goes into DDR3 and the HPS framebuffer is
// pointed at it.
//
// This is NOT the driver's "Flip Screen" DIP. That is the game redrawing
// itself upside down through the sprite chip's own flip bit -- implemented in
// rtl/video/x1_001.sv and checked only against the model, since no captured
// frame has it set. This flip is the OUTPUT turned round, which is what a
// cocktail cabinet or an upside-down monitor wants.
//
// Five of the eight Group A games are vertical: thunderl, thunderla, neobattl
// and pairlove are ROT270 and blockcar is ROT90. The `.mra` sets Rotate on for
// those and the direction accordingly.
screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(flip_180),
	.two_screen(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	.DDRAM_CLK(DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	.DDRAM_RD(DDRAM_RD)
);

endmodule
