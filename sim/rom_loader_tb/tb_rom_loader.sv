// The fast ROM load against the byte path it replaces.
//
//     scripts/run_verilator.sh rom_loader_tb +LAYOUT=0     (0..5 = A..F)
//     scripts/run_verilator.sh rom_loader_tb +LAYOUT=0 +NOINV
//     scripts/run_sim.sh rom_loader_tb +LAYOUT=0            (ModelSim, slower)
//
// Two seta_sdram_tops, each on its own command-decoding chip model, load the
// same image at the same time:
//
//   dut_b through ioctl, a byte at a time -- the path every game has loaded on
//         a DE10-nano with, sprite swizzle and inversion applied as the bytes
//         arrive;
//   dut_f through rtl/memory/rom_loader.sv, from a DDR3 responder serving the
//         same image in 8-byte granules, with the transform applied in the copy.
//
// The two memories must be identical, word for word, up to the layout's end,
// and the copy must write nothing past it. The byte path is the oracle because
// it is the one hardware has proven.
//
// The image: pseudo-random data in the first 64 KB of the program, of each
// tile region and of x1snd -- which the copy must pass through untouched --
// and across the whole sprite window, which the swizzle permutes
// (gfx_half_words = window / 4) and gfx1_invert inverts unless +NOINV. Zeros
// elsewhere. A match proves nothing if the transform never ran, so the bench
// also requires the byte path's sprite window to differ from the raw image.

`timescale 1ns / 1ps

module tb_rom_loader;

	localparam realtime CLK_PERIOD = 10.4167;   // 96 MHz
	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	// The map (rtl/memory/seta_sdram_top.sv). A gfx2/gfx3 base of 0 = absent.
	localparam int MAX_BYTES = 32'h1100000;
	localparam int CHUNK     = 32'h10000;
	int lay = 0;
	bit inv = 1;
	int MAP_BYTES, GFX1_BASE, GFX1_BYTES, GFX2_BASE, GFX3_BASE, SND_BASE;
	logic [22:0] half_words = '0;

	task automatic set_layout(input int l);
		case (l)
			0: begin MAP_BYTES='h0400000; GFX1_BASE='h100000; GFX1_BYTES='h200000; GFX2_BASE=0;         GFX3_BASE=0;         SND_BASE='h0300000; end
			1: begin MAP_BYTES='h0500000; GFX1_BASE='h100000; GFX1_BYTES='h100000; GFX2_BASE='h0200000; GFX3_BASE=0;         SND_BASE='h0400000; end
			2: begin MAP_BYTES='h0c00000; GFX1_BASE='h200000; GFX1_BYTES='h400000; GFX2_BASE='h0600000; GFX3_BASE='h0800000; SND_BASE='h0a00000; end
			3: begin MAP_BYTES='h0b00000; GFX1_BASE='h200000; GFX1_BYTES='h200000; GFX2_BASE='h0400000; GFX3_BASE='h0800000; SND_BASE='h0a00000; end
			4: begin MAP_BYTES='h1100000; GFX1_BASE='h200000; GFX1_BYTES='h800000; GFX2_BASE='h0a00000; GFX3_BASE='h0c00000; SND_BASE='h1000000; end
			5: begin MAP_BYTES='h0e00000; GFX1_BASE='h200000; GFX1_BYTES='h200000; GFX2_BASE='h0400000; GFX3_BASE='h0700000; SND_BASE='h0a00000; end
			default: begin $display("FAIL: +LAYOUT=%0d is not 0..5", l); $finish; end
		endcase
		half_words = 23'(GFX1_BYTES / 4);
	endtask

	logic [7:0] img [0:MAX_BYTES-1];

	// ---- DUTs ----------------------------------------------------------------
	logic        mem_reset = 1, pll_locked = 0;
	logic        ioctl_download = 0;
	logic [15:0] ioctl_index = 0;
	logic        ioctl_wr = 0;
	logic [26:0] ioctl_addr = 0;
	logic  [7:0] ioctl_dout = 0;
	wire         ioctl_wait;

	logic        ldr_start = 0;
	wire         ldr_active;
	wire         ldr_ddr_req;
	wire  [27:0] ldr_ddr_addr;
	logic        ldr_ddr_busy = 0, ldr_ddr_valid = 0;
	logic [63:0] ldr_ddr_rdata = '0;

	`define SDRAM_WIRES(p) \
		wire [12:0] p``_A; wire [15:0] p``_DQ; wire [1:0] p``_BA; \
		wire p``_DQML, p``_DQMH, p``_nCS, p``_nWE, p``_nRAS, p``_nCAS, p``_CLK, p``_CKE;
	`SDRAM_WIRES(sb)
	`SDRAM_WIRES(sf)

	`define SDRAM_PINS(p) \
		.SDRAM_A(p``_A), .SDRAM_DQ(p``_DQ), .SDRAM_DQML(p``_DQML), \
		.SDRAM_DQMH(p``_DQMH), .SDRAM_BA(p``_BA), .SDRAM_nCS(p``_nCS), \
		.SDRAM_nWE(p``_nWE), .SDRAM_nRAS(p``_nRAS), .SDRAM_nCAS(p``_nCAS), \
		.SDRAM_CKE(p``_CKE), .SDRAM_CLK(p``_CLK)

	`define READ_PORTS_OFF \
		.gfx_half_words(half_words), .layout(3'(lay)), .gfx1_invert(inv), \
		.cpu_req(1'b0), .cpu_addr('0), .cpu_valid(), .cpu_data(), \
		.spr_req(1'b0), .spr_addr('0), .spr_valid(), .spr_data(), \
		.tile_req(1'b0), .tile_addr('0), .tile_valid(), .tile_data(), \
		.tile1_req(1'b0), .tile1_addr('0), .tile1_valid(), .tile1_data(), \
		.snd_req(1'b0), .snd_addr('0), .snd_valid(), .snd_data()

	seta_sdram_top dut_b (
		.clk(clk), .reset(mem_reset), .init(~pll_locked), `SDRAM_PINS(sb),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait), `READ_PORTS_OFF,
		.ldr_start(1'b0), .ldr_active(), .ldr_ddr_req(), .ldr_ddr_addr(),
		.ldr_ddr_busy(1'b0), .ldr_ddr_valid(1'b0), .ldr_ddr_rdata('0)
	);

	// On hardware the fast path's ioctl_download has pulsed and gone by the time
	// the copy starts; it is simply idle here.
	seta_sdram_top dut_f (
		.clk(clk), .reset(mem_reset), .init(~pll_locked), `SDRAM_PINS(sf),
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0),
		.ioctl_addr('0), .ioctl_dout(8'd0), .ioctl_wait(), `READ_PORTS_OFF,
		.ldr_start(ldr_start), .ldr_active(ldr_active),
		.ldr_ddr_req(ldr_ddr_req), .ldr_ddr_addr(ldr_ddr_addr),
		.ldr_ddr_busy(ldr_ddr_busy), .ldr_ddr_valid(ldr_ddr_valid),
		.ldr_ddr_rdata(ldr_ddr_rdata)
	);

	sdram_chip_model_wide chip_b (
		.clk(sb_CLK), .SDRAM_DQ(sb_DQ), .SDRAM_A(sb_A), .SDRAM_BA(sb_BA),
		.SDRAM_nCS(sb_nCS), .SDRAM_nWE(sb_nWE), .SDRAM_nRAS(sb_nRAS), .SDRAM_nCAS(sb_nCAS)
	);
	sdram_chip_model_wide chip_f (
		.clk(sf_CLK), .SDRAM_DQ(sf_DQ), .SDRAM_A(sf_A), .SDRAM_BA(sf_BA),
		.SDRAM_nCS(sf_nCS), .SDRAM_nWE(sf_nWE), .SDRAM_nRAS(sf_nRAS), .SDRAM_nCAS(sf_nCAS)
	);

	// ---- the DDR3 side: ddram_phy's client contract, served from img[] -------
	// A request is taken while not busy; a few cycles later the granule comes
	// back with valid for one cycle. Little-endian: byte N at bit (N%8)*8.
	logic [27:0] ddr_a;
	int          ddr_cnt;
	always @(posedge clk) begin
		ldr_ddr_valid <= 1'b0;
		if (!ldr_ddr_busy && ldr_ddr_req) begin
			ddr_a        <= ldr_ddr_addr;
			ldr_ddr_busy <= 1'b1;
			ddr_cnt      <= 3;
		end else if (ldr_ddr_busy) begin
			if (ddr_cnt == 0) begin
				ldr_ddr_rdata <= {img[ddr_a+7], img[ddr_a+6], img[ddr_a+5], img[ddr_a+4],
				                  img[ddr_a+3], img[ddr_a+2], img[ddr_a+1], img[ddr_a]};
				ldr_ddr_valid <= 1'b1;
				ldr_ddr_busy  <= 1'b0;
			end else
				ddr_cnt <= ddr_cnt - 1;
		end
	end

	// ---- the byte path -------------------------------------------------------
	// THREE EDGES PER BYTE, NOT TWO. The write reaches sdram_download a cycle
	// after ioctl_wr falls (seta_sdram_top registers it), and the wait it
	// raises is updated on the very edge a two-edge push would sample it on --
	// so the next byte went in while the port was busy and was dropped. hps_io
	// leaves hundreds of clocks between bytes; one spare edge is enough here.
	task automatic push(input [26:0] a, input [7:0] d);
		while (ioctl_wait) @(posedge clk);
		ioctl_addr <= a;
		ioctl_dout <= d;
		ioctl_wr   <= 1'b1;
		@(posedge clk);
		ioctl_wr   <= 1'b0;
		repeat (2) @(posedge clk);
	endtask

	task automatic stream(input int base, input int nbytes);
		for (int k = 0; k < nbytes; k++) push(27'(base + k), img[base + k]);
	endtask

	function automatic bit has_data(input int i);
		return i < CHUNK
		    || (i >= GFX1_BASE && i < GFX1_BASE + GFX1_BYTES)
		    || (GFX2_BASE != 0 && i >= GFX2_BASE && i < GFX2_BASE + CHUNK)
		    || (GFX3_BASE != 0 && i >= GFX3_BASE && i < GFX3_BASE + CHUNK)
		    || (i >= SND_BASE && i < SND_BASE + CHUNK);
	endfunction

	int bad = 0, differ_from_raw = 0, nz = 0;
	logic [31:0] lfsr;

	initial begin
		$display("=== rom_loader: the DDR3 copy against the byte path ===");
		void'($value$plusargs("LAYOUT=%d", lay));
		if ($test$plusargs("NOINV")) inv = 0;
		set_layout(lay);
		$display("  layout %0d, sprite window %06x+%06x, gfx1_invert %0d, copy to %07x",
		         lay, GFX1_BASE, GFX1_BYTES, inv, MAP_BYTES);

		lfsr = 32'hC0FFEE01;
		for (int i = 0; i < MAX_BYTES; i++) begin
			if (i < MAP_BYTES && has_data(i)) begin
				lfsr   = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
				img[i] = lfsr[7:0];
			end else
				img[i] = 8'h00;
		end

		repeat (8) @(posedge clk);
		mem_reset  <= 0;
		pll_locked <= 1;
		repeat (30000) @(posedge clk);       // the controller's power-up sequence

		fork
			begin : byte_path
				ioctl_index    <= 16'd0;
				ioctl_download <= 1'b1;
				@(posedge clk);
				stream(0,         CHUNK);
				stream(GFX1_BASE, GFX1_BYTES);
				if (GFX2_BASE != 0) stream(GFX2_BASE, CHUNK);
				if (GFX3_BASE != 0) stream(GFX3_BASE, CHUNK);
				stream(SND_BASE,  CHUNK);
				while (ioctl_wait) @(posedge clk);
				repeat (64) @(posedge clk);
				ioctl_download <= 1'b0;
				$display("  byte path: done at %0t", $time);
			end
			begin : fast_path
				ldr_start <= 1'b1;
				@(posedge clk);
				ldr_start <= 1'b0;
				@(posedge clk);
				if (!ldr_active) $display("FAIL: the loader did not start");
				while (ldr_active) @(posedge clk);
				$display("  fast path: done at %0t", $time);
			end
		join
		repeat (64) @(posedge clk);

		// The chip holds byte-map word w at mem[w] -- bytes 2w and 2w+1 as
		// {odd, even}. Checked on a program word, which nothing transforms.
		if (chip_b.mem[5] !== {img[11], img[10]})
			$display("FAIL setup: chip word 5 = %04x, image bytes 10/11 = %02x%02x -- the bench's addressing is wrong",
			         chip_b.mem[5], img[11], img[10]);

		for (int w = 0; w < MAP_BYTES / 2; w++) begin
			if (w >= GFX1_BASE / 2 && w < (GFX1_BASE + GFX1_BYTES) / 2
			    && chip_b.mem[w] !== {img[2*w+1], img[2*w]})
				differ_from_raw++;
			if (chip_f.mem[w] !== chip_b.mem[w]) begin
				if (bad < 8)
					$display("  word %06x (byte %07x): fast %04x, byte path %04x",
					         w, 2 * w, chip_f.mem[w], chip_b.mem[w]);
				bad++;
			end
			if (chip_b.mem[w] !== 16'h0000) nz++;
		end
		for (int w = MAP_BYTES / 2; w < MAX_BYTES / 2; w++)
			if (chip_f.mem[w] !== 16'h0000) begin
				if (bad < 8) $display("  word %06x past the end: fast %04x", w, chip_f.mem[w]);
				bad++;
			end
		$display("  %0d of %0d sprite-window words moved or inverted by the byte path",
		         differ_from_raw, GFX1_BYTES / 2);
		$display("  %0d words differ between the paths (%0d of %0d non-zero in the byte path)",
		         bad, nz, MAP_BYTES / 2);

		if (differ_from_raw < GFX1_BYTES / 4)
			$display("FAIL: the sprite window barely differs from the raw image -- the transform did not run");
		else if (bad != 0)
			$display("FAIL: the DDR3 copy disagrees with the byte path");
		else
			$display("PASS: layout %0d, invert %0d: the DDR3 copy is word-for-word the byte path's", lay, inv);
		$finish;
	end

	initial begin
		#(CLK_PERIOD * 400_000_000);
		$display("FAIL: timed out");
		$finish;
	end

endmodule
