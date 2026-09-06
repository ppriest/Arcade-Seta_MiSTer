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
wire [11:0] base_arx = 12'd8;
wire [11:0] base_ary = 12'd5;

wire       rotate_en  = status[63];
wire       rotate_ccw = status[64];
wire       flip_180   = status[65];

`include "build_id.v"
localparam CONF_STR = {
	"Seta;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[63],Rotate,Off,On;",
	"O[64],Rotate direction,CW,CCW;",
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
	"P1,Debug;",
	"P1-;",
	"P1O[80],Sprites,On,Off;",
	"P1O[81],PCM sound,On,Off;",
	"P1O[82],Pause CPU,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J1,Button 1,Button 2,Start,Coin,Service;",
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
	.status_menumask(0),

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
wire clk_sys, clk_sdram_shifted, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
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
wire [15:0] p1_in = ~{
	8'h00,
	joystick_0[8],    // 7 START1
	1'b0,             // 6 unused
	joystick_0[5],    // 5 BUTTON2
	joystick_0[4],    // 4 BUTTON1
	joystick_0[2],    // 3 DOWN
	joystick_0[3],    // 2 UP
	joystick_0[0],    // 1 RIGHT
	joystick_0[1]     // 0 LEFT
};

wire [15:0] p2_in = ~{
	8'h00,
	joystick_1[8],
	1'b0,
	joystick_1[5],
	joystick_1[4],
	joystick_1[2],
	joystick_1[3],
	joystick_1[0],
	joystick_1[1]
};

// COINS: coin 1 and 2, service, tilt, and then whatever DIP bits the game puts
// in the top nibble. sw[2] supplies those; where a game uses none of them the
// `.mra` leaves it 0xf0 and nothing changes.
wire [15:0] coins_in = {
	8'hff,
	sw[2][7:4],
	1'b1,               // 3 TILT, never asserted
	~joystick_0[9],     // 2 SERVICE1
	~joystick_1[6],     // 1 COIN2
	~joystick_0[6]      // 0 COIN1
};

// wits alone has four players; the other seven boards never read these.
wire [15:0] p3_in = 16'hffff;
wire [15:0] p4_in = 16'hffff;

///////////////////////   THE GAME   /////////////////////////////

wire [7:0] core_r, core_g, core_b;
wire       core_hs, core_vs, core_hb, core_vb, core_de, core_ce;

wire [15:0] dbg_lines, dbg_sprites, dbg_fetches, dbg_overrun;
wire [15:0] dbg_worst_line, dbg_worst_sprites, dbg_dropped;
wire [15:0] dbg_snd_samples, dbg_snd_overrun, dbg_snd_rom_reads;
wire  [7:1] dbg_irq_pending;
wire        dbg_cpu_stb, dbg_cpu_we;
wire [23:1] dbg_cpu_addr;
wire [15:0] dbg_cpu_data;

seta_core seta_core
(
	.clk(clk_sys),
	.reset(core_reset),
	.mem_reset(mem_reset),
	.init(~pll_locked),

	.game(mod_byte[3:0]),

	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
	// The physical clock pin is driven from the PLL above, not from here.
	.SDRAM_CLK(),

	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.p1_in(p1_in), .p2_in(p2_in), .coins_in(coins_in),
	.p3_in(p3_in), .p4_in(p4_in), .dsw_in(dsw_in),

	.pause_cpu(status[82]),
	.en_spr(~status[80]),
	.en_pcm(~status[81]),

	.video_r(core_r), .video_g(core_g), .video_b(core_b),
	.video_hs(core_hs), .video_vs(core_vs),
	.video_hb(core_hb), .video_vb(core_vb),
	.video_de(core_de), .video_ce(core_ce),

	.audio_l(core_audio_l), .audio_r(core_audio_r),

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

///////////////////////   VIDEO   ////////////////////////////////

// CLK_VIDEO and CE_PIXEL are OUTPUTS of arcade_video -- it drives CLK_VIDEO
// from its own clk_video input -- so they must not be assigned here as well.
// A second driver on CLK_VIDEO propagates back to clk_sys, and Quartus then
// reports the error against the clock rather than against the line that
// caused it.
wire vga_de_raw;

arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(core_ce),

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
