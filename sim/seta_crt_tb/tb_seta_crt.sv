// seta_crt: where the picture lands, in clk cycles from the HSync rise.
//   ref  : 384 wide, CRT adjust On, H-Size 0 (the module's native-rate path)
//   wide : 320 wide, Match 384
//   h10  : 320 wide, CRT adjust On, H-Size +10, H-Position -19
//   pos-8: 384 wide, CRT adjust On, H-Position -8: ref moved 96 cycles left
// Every source pixel must come out once, in order. wide must match ref's width
// and start within half a read tick (7 cycles): output HSync is registered on
// read ticks too. Line period is 6144 in all; H-Size moves the HSync fall by
// up to a tick, so pulse width is checked for wide only.

`timescale 1ns/1ps
`default_nettype none

module crt_probe #(parameter string NAME = "", parameter bit NARROW = 0,
                   parameter bit ADJUST = 0, parameter bit WIDE = 0,
                   parameter logic [4:0] HSIZE = 5'd0,
                   parameter logic [6:0] HPOS = 7'd0) (
	input  wire         clk,
	input  wire         ce,
	output int          first_c, last_c, npix, hs_period, hs_width,
	output bit          ordered, done
);
	wire [9:0] hcount, vcount;
	wire       hs, vs, hb, vb, de, ls, v240, v112, vr, snap;
	wire [8:0] line;

	seta_video_timing u_t (
		.clk(clk), .reset(1'b0), .ce_pix(ce),
		.htotal(10'd512), .hs_start(10'd400), .hs_end(10'd448),
		.hact_start(10'd0), .hact_end(NARROW ? 10'd319 : 10'd383),
		.vtotal(10'd272), .vs_start(10'd250), .vs_end(10'd253),
		.vact_start(10'd8), .vact_end(10'd247),
		.hcount(hcount), .vcount(vcount), .hsync(hs), .vsync(vs),
		.hblank(hb), .vblank(vb), .de(de),
		.line_start(ls), .line(line),
		.irq_vblank_line(v240), .irq_mid_line(v112), .vblank_rise(vr), .snap_start(snap)
	);

	wire [7:0] r, g, b;
	wire       hs_o, vs_o, hb_o, vb_o, act, ce_o;

	seta_crt u_crt (
		.clk(clk), .ce(ce), .adjust(ADJUST), .wide(WIDE),
		.hsize_idx(HSIZE), .hpos_idx(HPOS), .vshift_idx(6'd0),
		.r_in(hcount[7:0]), .g_in({6'd0, hcount[9:8]}), .b_in(vcount[7:0]),
		.hs_in(hs), .vs_in(vs), .hb_in(hb), .vb_in(vb),
		.active(act), .ce_out(ce_o),
		.r_out(r), .g_out(g), .b_out(b),
		.hs_out(hs_o), .vs_out(vs_o), .hb_out(hb_o), .vb_out(vb_o)
	);

	int  cyc = 0, hs_rise = 0, prev_rise = 0, lines = 0, expect_px = 0;
	bit  hs_d = 0, hb_d = 1, meas = 0;
	always @(posedge clk) begin
		cyc <= cyc + 1;
		hs_d <= hs_o;
		hb_d <= hb_o;
		if (hs_o & ~hs_d) begin
			prev_rise = hs_rise;
			hs_rise   = cyc;
			lines     = lines + 1;
			if (meas) done <= 1'b1;
			meas = (lines == 2000);     // a picture line in the eighth frame
			if (meas) begin
				hs_period = hs_rise - prev_rise;
				npix = 0; expect_px = 0; ordered = 1;
			end
		end
		if (meas && ~hs_o && hs_d) hs_width = cyc - hs_rise;
		if (meas && ~hb_o && hb_d) first_c = cyc - hs_rise;
		if (meas && hb_o && ~hb_d) last_c = cyc - hs_rise;
		// source pixels are hcount, so each new output pixel changes the value
		if (meas && ~hb_o && (npix == 0 || {g[1:0], r} != 10'(expect_px - 1))) begin
			if ({g[1:0], r} != 10'(expect_px)) ordered = 0;
			expect_px = {g[1:0], r} + 1;
			npix = npix + 1;
		end
	end
endmodule

module tb_seta_crt;
	bit clk = 0;
	always #5 clk = ~clk;

	bit [3:0] div = 0;
	always @(posedge clk) div <= (div == 4'd11) ? 4'd0 : div + 4'd1;
	wire ce = (div == 4'd0);

	int f[4], l[4], n[4], hp[4], hw[4];
	bit o[4], d[4];

	crt_probe #(.NAME("ref"), .NARROW(0), .ADJUST(1)) p_ref (
		.clk(clk), .ce(ce), .first_c(f[0]), .last_c(l[0]), .npix(n[0]),
		.hs_period(hp[0]), .hs_width(hw[0]), .ordered(o[0]), .done(d[0]));
	crt_probe #(.NAME("wide"), .NARROW(1), .WIDE(1)) p_wide (
		.clk(clk), .ce(ce), .first_c(f[1]), .last_c(l[1]), .npix(n[1]),
		.hs_period(hp[1]), .hs_width(hw[1]), .ordered(o[1]), .done(d[1]));
	crt_probe #(.NAME("h10"), .NARROW(1), .ADJUST(1), .HSIZE(5'd10), .HPOS(7'd78)) p_h10 (
		.clk(clk), .ce(ce), .first_c(f[2]), .last_c(l[2]), .npix(n[2]),
		.hs_period(hp[2]), .hs_width(hw[2]), .ordered(o[2]), .done(d[2]));
	crt_probe #(.NAME("pos-8"), .NARROW(0), .ADJUST(1), .HPOS(7'd89)) p_pos (
		.clk(clk), .ce(ce), .first_c(f[3]), .last_c(l[3]), .npix(n[3]),
		.hs_period(hp[3]), .hs_width(hw[3]), .ordered(o[3]), .done(d[3]));

	string names[4] = '{"ref ", "wide", "h10 ", "pos-8"};
	int fails = 0;
	initial begin
		wait (d[0] && d[1] && d[2] && d[3]);
		for (int i = 0; i < 4; i++)
			$display("%s  active %4d..%4d cycles (%4d)  pixels %3d  ordered %0d  hsync period %4d width %3d",
			         names[i], f[i], l[i], l[i] - f[i], n[i], o[i], hp[i], hw[i]);
		if (n[0] != 384 || !o[0]) begin $display("FAIL ref pixels"); fails++; end
		if (n[1] != 320 || !o[1]) begin $display("FAIL wide pixels"); fails++; end
		if (n[2] != 320 || !o[2]) begin $display("FAIL h10 pixels"); fails++; end
		if (n[3] != 384 || !o[3] || f[3] != f[0] - 96 || l[3] != l[0] - 96) begin
			$display("FAIL pos-8 not ref shifted 96 cycles left"); fails++;
		end
		for (int i = 1; i < 4; i++)
			if (hp[i] != hp[0]) begin $display("FAIL %s line period", names[i]); fails++; end
		if (hw[1] != hw[0]) begin $display("FAIL wide hsync width"); fails++; end
		if (hp[0] != 6144) begin $display("FAIL line not 512 x 12"); fails++; end
		if ((f[1] - f[0]) > 7 || (f[0] - f[1]) > 7 || (l[1] - f[1]) != (l[0] - f[0])) begin
			$display("FAIL wide window not ref's to 7 cycles"); fails++;
		end
		if (fails) $display("FAIL"); else $display("PASS");
		$finish;
	end
endmodule

`default_nettype wire
