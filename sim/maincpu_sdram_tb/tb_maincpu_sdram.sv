// maincpu.sv booting a real ROM through the PRODUCTION SDRAM stack.
//
//     python scripts/prep_maincpu_tb.py thunderl debug/bt/thunderl/thunderl_boot.trace
//     scripts/run_sim.sh maincpu_sdram_tb           (from the repository root)
//
// sim/maincpu_tb proves the CPU and the address decode against a behavioural
// ROM model. This proves the same boot through the real transport:
//
//     ioctl stream -> sdram_download -> sdram_arbiter -> sdram_phy
//                  -> sdram.sv -> sdram_chip_model_wide
//     maincpu -> sdram_narrow_bridge -> sdram_arbiter (client 0) -> ...
//
// LESSONS_LEARNED is explicit that the first is not a substitute for the
// second: "Re-run the failing case with the production transport in place of
// behavioural models". Psikyo had a gfxrom handshake bug that EVERY
// module-level simulation passed, because a short-latency behavioural model
// returned its response while the FSM was between states; the real controller's
// ~12-cycle latency landed the duplicate in the next wait state, where it
// corrupted the result. A latency sweep against a behavioural model is a proxy,
// not a proof.
//
// THREE BYTE-ORDER CONVENTIONS MEET HERE, and this is the test that they
// compose:
//   1. the ioctl stream delivers image bytes in ascending address order;
//   2. sdram_download pairs them {odd, even} -- the EVEN byte in the LOW half;
//   3. sdram_narrow_bridge hands that word back unchanged;
//   4. maincpu.sv's ROM_BYTESWAP turns it into the big-endian word a 68000
//      expects.
// Get any one backwards and the CPU reads swapped opcodes. On Psikyo that
// looked like a corrupt stack pointer and cost a loader rewrite that turned out
// to be inert.
//
// TWO RESET DOMAINS, deliberately. MiSTer holds core RESET for the ENTIRE ROM
// download, so anything in the memory path that resets on it is dead for the
// whole transfer -- Psikyo pinned sdram_download's FSM in idle that way and not
// one CMD_WRITE ever reached the chip, while every delivery counter looked
// perfect. Here `core_reset` gates the CPU and `mem_reset` the transport, and
// they are not the same signal.

`timescale 1ns / 1ps

module tb_maincpu_sdram;

	localparam realtime CLK_PERIOD = 10.4167;    // 96 MHz
	localparam int      CE_DIV     = 6;          // -> 16 MHz CPU
	localparam int      MAX_BYTES  = 1 << 21;    // 2 MB

	logic clk = 0;
	always #(CLK_PERIOD / 2.0) clk = ~clk;

	logic mem_reset  = 1;    // transport: released once, early
	logic core_reset = 1;    // CPU: held across the whole download
	logic pll_locked = 0;

	logic [2:0] ce_cnt = 0;
	wire  cpu_ce = (ce_cnt == 0);
	always @(posedge clk) ce_cnt <= (ce_cnt == CE_DIV - 1) ? 3'd0 : ce_cnt + 3'd1;

	// ---- SDRAM chip + controller --------------------------------------------
	wire [15:0] SDRAM_DQ;
	wire [12:0] SDRAM_A;
	wire  [1:0] SDRAM_BA;
	wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS,
	            SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

	logic [25:1] p0_addr;
	logic        p0_wrl, p0_wrh, p0_req;
	logic [15:0] p0_din;
	wire  [63:0] p0_dout;
	wire         p0_ack;

	sdram u_sdram (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
		.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
		.init(~pll_locked), .clk(clk),
		.addr0(p0_addr), .wrl0(p0_wrl), .wrh0(p0_wrh), .din0(p0_din),
		.dout0(p0_dout), .req0(p0_req), .ack0(p0_ack),
		.addr1(25'd0), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0),
		.dout1(), .req1(1'b0), .ack1(),
		.addr2(25'd0), .wrl2(1'b0), .wrh2(1'b0), .din2(16'd0),
		.dout2(), .req2(1'b0), .ack2()
	);

	sdram_chip_model_wide u_chip (
		.clk(SDRAM_CLK), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// ---- phy + arbiter ------------------------------------------------------
	logic        phy_req, phy_we, phy_we16;
	logic [25:0] phy_addr;
	logic [15:0] phy_wdata;
	wire         phy_busy, phy_valid;
	wire  [63:0] phy_rdata;

	sdram_phy u_phy (
		.clk(clk), .reset(mem_reset),
		.port_addr(p0_addr), .port_wrl(p0_wrl), .port_wrh(p0_wrh),
		.port_din(p0_din), .port_dout(p0_dout), .port_req(p0_req),
		.port_ack(p0_ack),
		.req(phy_req), .we(phy_we), .we16(phy_we16), .addr(phy_addr),
		.wdata(phy_wdata), .busy(phy_busy), .valid(phy_valid), .rdata(phy_rdata)
	);

	// One read client: the maincpu program fetch, through the narrow bridge.
	localparam int NCLI = 1;
	logic [NCLI-1:0]      c_req;
	logic [26*NCLI-1:0]   c_addr;
	wire  [NCLI-1:0]      c_valid;
	wire  [63:0]          c_rdata;

	wire         dl_req, dl_we16, dl_busy;
	wire [25:0]  dl_addr;
	wire [15:0]  dl_data;

	sdram_arbiter #(.N(NCLI)) u_arb (
		.clk(clk), .reset(mem_reset),
		.phy_req(phy_req), .phy_we(phy_we), .phy_we16(phy_we16),
		.phy_addr(phy_addr), .phy_wdata(phy_wdata), .phy_busy(phy_busy),
		.phy_valid(phy_valid), .phy_rdata(phy_rdata),
		.c_req(c_req), .c_addr(c_addr), .c_valid(c_valid), .c_rdata(c_rdata),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

	// ---- the ROM download, through the real path ----------------------------
	logic         ioctl_download = 0;
	logic [15:0]  ioctl_index = 0;
	logic         ioctl_wr = 0;
	logic [26:0]  ioctl_addr = 0;
	logic [7:0]   ioctl_dout = 0;
	wire          ioctl_wait;

	sdram_download u_dl (
		.clk(clk), .reset(mem_reset),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

	// ---- maincpu ------------------------------------------------------------
	wire         rom_req;
	wire  [23:1] rom_addr;
	wire         rom_valid;
	wire  [15:0] rom_data;

	sdram_narrow_bridge #(.WORD_BYTES(2)) u_bridge (
		.clk(clk), .reset(mem_reset),
		.inval(ioctl_download),          // flush the granule cache while loading
		// 26 bits: 2 + 23 + 1. Writing 3'b000 here made 27 and ModelSim
		// truncated the top -- harmless for a 64 KB image and not for a
		// 2 MB one, which is exactly how a width bug hides.
		.req(rom_req), .addr({2'b00, rom_addr, 1'b0}),
		.valid(rom_valid), .data(rom_data),
		.g_req(c_req[0]), .g_addr(c_addr[25:0]),
		.g_valid(c_valid[0]), .g_data(c_rdata)
	);

	wire [19:1] wram_addr;
	wire        wram_wel, wram_weh;
	wire [15:0] wram_wdata;
	logic [15:0] wram_rdata;

	wire        io_req, io_we, io_uds, io_lds;
	wire [23:1] io_addr;
	wire [15:0] io_wdata;
	wire [15:0] io_sel;
	logic [15:0] io_rdata;

	wire        dbg_stb, dbg_we;
	wire [23:1] dbg_addr;
	wire [15:0] dbg_data;

	int board_sel = 8;    // BOARD_THUNDERL

	maincpu dut (
		.clk(clk), .reset(core_reset), .board(board_sel[4:0]), .cpu_ce(cpu_ce),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.wram_addr(wram_addr), .wram_wel(wram_wel), .wram_weh(wram_weh),
		.wram_wdata(wram_wdata), .wram_rdata(wram_rdata),
		.io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_wdata(io_wdata),
		.io_uds(io_uds), .io_lds(io_lds), .io_sel(io_sel), .io_rdata(io_rdata),
		.ipl_level(3'd0),
		.iack(), .iack_level(),
		.dbg_stb(dbg_stb), .dbg_addr(dbg_addr), .dbg_we(dbg_we), .dbg_data(dbg_data)
	);

	// Work RAM and the io regions stay behavioural: they are block RAM on the
	// real board too, so nothing about the SDRAM transport is being avoided.
	logic [15:0] wram [0:(1<<19)-1];
	always @(posedge clk) begin
		if (wram_wel) wram[wram_addr][7:0]  <= wram_wdata[7:0];
		if (wram_weh) wram[wram_addr][15:8] <= wram_wdata[15:8];
		wram_rdata <= wram[wram_addr];
	end

	logic [15:0] ioram [0:(1<<18)-1];
	logic  [3:0] io_region;
	always_comb begin
		io_region = 4'd15;
		for (int k = 0; k < 14; k++) if (io_sel[k]) io_region = k[3:0];
	end
	wire [17:0] ioram_a = {io_region, io_addr[14:1]};
	logic [15:0] ioram_q;
	always @(posedge clk) begin
		if (io_req && io_we && io_region != 4'd15) begin
			if (io_lds) ioram[ioram_a][7:0]  <= io_wdata[7:0];
			if (io_uds) ioram[ioram_a][15:8] <= io_wdata[15:8];
		end
		ioram_q <= ioram[ioram_a];
	end
	assign io_rdata = (io_region == 4'd15) ? 16'h0000 : ioram_q;

	// ---- expected fetch list ------------------------------------------------
	localparam int MAX_EXP = 4096;
	localparam int WINDOW  = 16;
	logic [38:0] expect_mem [0:MAX_EXP-1];
	logic        consumed   [0:MAX_EXP-1];
	int n_exp = 0, exp_i = 0, matched = 0, mismatched = 0;
	int skipped = 0, reordered = 0;
	logic [23:1] first_bad_addr;
	logic [15:0] first_bad_got, first_bad_want;
	logic have_bad = 0;

	logic [23:1] prev_addr = '1;
	logic [15:0] prev_data = '1;
	logic        have_prev = 0;
	wire         is_dup = have_prev && (dbg_addr == prev_addr) && (dbg_data == prev_data);

	int hit;
	always @(posedge clk) begin
		if (!core_reset && dbg_stb && !dbg_we) begin
			prev_addr <= dbg_addr; prev_data <= dbg_data; have_prev <= 1'b1;
		end
		if (!core_reset && dbg_stb && !dbg_we && !is_dup && exp_i < n_exp && !have_bad) begin
			hit = -1;
			for (int k = 0; k < WINDOW; k++)
				if (hit < 0 && (exp_i + k) < n_exp && !consumed[exp_i + k] &&
				    dbg_addr == expect_mem[exp_i + k][38:16])
					hit = exp_i + k;
			if (hit >= 0) begin
				if (dbg_data == expect_mem[hit][15:0]) matched <= matched + 1;
				else begin
					mismatched <= mismatched + 1; have_bad <= 1'b1;
					first_bad_addr <= dbg_addr; first_bad_got <= dbg_data;
					first_bad_want <= expect_mem[hit][15:0];
				end
				consumed[hit] = 1'b1;
				if (hit != exp_i) reordered <= reordered + 1;
				while (exp_i < n_exp && consumed[exp_i]) exp_i = exp_i + 1;
			end else skipped <= skipped + 1;
		end
	end

	// ---- run ----------------------------------------------------------------
	logic [7:0] img [0:MAX_BYTES-1];
	int n_bytes = 0;
	int i;

	initial begin
		for (i = 0; i < MAX_BYTES; i++)     img[i] = 8'hxx;
		for (i = 0; i < (1<<19); i++)       wram[i] = 16'h0000;
		for (i = 0; i < (1<<18); i++)       ioram[i] = 16'h0000;
		for (i = 0; i < MAX_EXP; i++) begin expect_mem[i] = '0; consumed[i] = 1'b0; end

		$readmemh("sim/maincpu_tb/rom_bytes.hex", img);
		$readmemh("sim/maincpu_tb/expect.hex", expect_mem);

		if ($isunknown(img[0]) && $isunknown(img[1])) begin
			$display("FAIL: sim/maincpu_tb/rom_bytes.hex missing. Run scripts/prep_maincpu_tb.py");
			$finish;
		end
		n_bytes = 0;
		for (i = 0; i < MAX_BYTES; i++) if (!$isunknown(img[i])) n_bytes = i + 1;

		n_exp = 0;
		for (i = 0; i < MAX_EXP; i++) if (expect_mem[i] !== '0) n_exp = i + 1;
		void'($value$plusargs("BOARD=%d", board_sel));

		$display("=== maincpu through the PRODUCTION SDRAM stack ===");
		$display("  image            %0d bytes", n_bytes);
		$display("  expected reads   %0d", n_exp);

		// PLL locks, then the transport comes out of reset. The CPU does NOT:
		// core_reset stays asserted across the whole download, as MiSTer does.
		repeat (10) @(posedge clk);
		pll_locked <= 1;
		repeat (200) @(posedge clk);       // sdram.sv's own init sequence
		mem_reset <= 0;
		repeat (10) @(posedge clk);

		download();

		$display("  [%0t] download done, releasing the CPU", $time);
		repeat (20) @(posedge clk);
		core_reset <= 0;

		do @(posedge clk); while (exp_i < n_exp && !have_bad && $time < 200ms);

		$display("");
		$display("  reads compared   %0d of %0d", exp_i, n_exp);
		$display("  matched          %0d", matched);
		$display("  mismatched       %0d", mismatched);
		$display("  RTL-only reads   %0d", skipped);
		$display("  reordered        %0d", reordered);
		if (have_bad)
			$display("  FIRST DIVERGENCE at %06x: RTL %04x, MAME %04x",
			         {first_bad_addr, 1'b0}, first_bad_got, first_bad_want);
		$display("");

		if (have_bad)
			$display("FAIL: the CPU diverged from MAME through the real transport");
		else if (exp_i < n_exp)
			$display("FAIL: only %0d of %0d expected reads happened", exp_i, n_exp);
		else
			$display("PASS: %0d reads through the real SDRAM stack, all matching MAME",
			         matched);
		$finish;
	end

	// hps_io's real shape: ioctl_wr is a ONE-SHOT pulse and ioctl_wait is
	// backpressure that must be honoured. Streaming without it is the classic
	// way to write a download test that passes and a core that drops bytes.
	task download();
		ioctl_index <= 16'd0;
		ioctl_download <= 1'b1;
		@(posedge clk);
		for (int b = 0; b < n_bytes; b++) begin
			// `do @(posedge clk); while (...)`, never the other way round: the
			// latter races an always_ff updating the same signal on the same
			// edge (LESSONS_LEARNED, "Testbench discipline", first entry).
			while (ioctl_wait) @(posedge clk);
			ioctl_addr <= b[26:0];
			ioctl_dout <= img[b];
			ioctl_wr   <= 1'b1;
			@(posedge clk);
			ioctl_wr   <= 1'b0;
			@(posedge clk);
		end
		// Let the last buffered byte flush before the download flag drops.
		repeat (40) @(posedge clk);
		ioctl_download <= 1'b0;
		repeat (40) @(posedge clk);
	endtask

endmodule
