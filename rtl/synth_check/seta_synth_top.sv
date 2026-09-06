// Standalone synthesis / timing harness for the Phase 0 subsystem.
//
// Not part of the core build. It exists to answer two questions before a whole
// core top level exists:
//
//   1. Does it elaborate for QUARTUS? ModelSim accepts SystemVerilog Quartus
//      rejects outright -- non-blocking assignment to an automatic variable,
//      RAMSTYLE in a .qsf, hierarchical references into VHDL -- so "it
//      simulates" is not evidence that it synthesizes.
//   2. What is Fmax on the real device and speed grade? docs/ROADMAP.md picks
//      clk_sys = 96 MHz, and the line-based sprite renderer depends on it.
//      Measuring that AFTER a video engine exists is expensive.
//
// It instantiates the whole Phase 0 subsystem, not just the CPU: maincpu with
// TG68K under it, the X1-010, and the SDRAM transport they both fetch through.
// `sdram.sv` itself is deliberately left out -- it has bidirectional device
// pins and is vendored, unmodified, into many shipping cores, so its timing is
// not what this is asking about.
//
// KEEPING THE DESIGN ALIVE
//   The blocks have far more port bits than this device has pins. Inputs come
//   from a free-running pattern register and every output is XOR-reduced onto
//   one pin. If the outputs were left unconnected Quartus would optimise the
//   logic away and report a beautifully fast empty design; if the inputs were
//   tied to constants the fitter would fold the decode flat and flatter the
//   report the same way. Both traps are why this file exists rather than a
//   simpler wrapper.
//
// This is a synthesis harness, NOT a simulation model. It does not execute
// anything sensible.

`default_nettype none

module seta_synth_top (
	input  wire  clk,
	input  wire  rst_n,
	input  wire  stim,
	output logic result
);

	wire reset = ~rst_n;

	// Free-running pattern: a real, changing driver for every input without
	// spending a pin each.
	logic [31:0] pat;
	always_ff @(posedge clk or posedge reset)
		if (reset) pat <= 32'h1234_5678;
		else       pat <= {pat[30:0], pat[31] ^ pat[21] ^ pat[1] ^ stim};

	// Clock enables, as the real design generates them: 96 MHz / 6 = 16 MHz
	// for both the 68000 and the X1-010.
	logic [2:0] ce_cnt;
	always_ff @(posedge clk or posedge reset)
		if (reset) ce_cnt <= 3'd0;
		else       ce_cnt <= (ce_cnt == 3'd5) ? 3'd0 : ce_cnt + 3'd1;
	wire ce_16m = (ce_cnt == 3'd0);

	// =====================================================================
	// maincpu
	// =====================================================================
	wire         rom_req;
	wire  [23:1] rom_addr;
	wire         rom_valid;
	wire  [15:0] rom_data;

	wire  [19:1] wram_addr;
	wire         wram_wel, wram_weh;
	wire  [15:0] wram_wdata;
	logic [15:0] wram_rdata;

	wire         io_req, io_we, io_uds, io_lds;
	wire  [23:1] io_addr;
	wire  [15:0] io_wdata;
	wire  [15:0] io_sel;
	logic [15:0] io_rdata;

	wire         dbg_stb, dbg_we;
	wire  [23:1] dbg_addr;
	wire  [15:0] dbg_data;

	// Read-data paths come from REGISTERS, not constants: a constant lets the
	// fitter fold the read mux flat and flatters the timing report.
	always_ff @(posedge clk) begin
		wram_rdata <= pat[15:0] ^ {8'd0, pat[23:16]};
		io_rdata   <= pat[31:16] ^ {pat[7:0], 8'd0};
	end

	maincpu u_cpu (
		.clk(clk), .reset(reset),
		.board(pat[19:16]),          // static in the core; see the .sdc
		.cpu_ce(ce_16m),
		.rom_req(rom_req), .rom_addr(rom_addr),
		.rom_valid(rom_valid), .rom_data(rom_data),
		.wram_addr(wram_addr), .wram_wel(wram_wel), .wram_weh(wram_weh),
		.wram_wdata(wram_wdata), .wram_rdata(wram_rdata),
		.io_req(io_req), .io_we(io_we), .io_addr(io_addr), .io_wdata(io_wdata),
		.io_uds(io_uds), .io_lds(io_lds), .io_sel(io_sel), .io_rdata(io_rdata),
		.ipl_level(pat[2:0]),
		.dbg_stb(dbg_stb), .dbg_addr(dbg_addr), .dbg_we(dbg_we), .dbg_data(dbg_data)
	);

	// =====================================================================
	// X1-010
	// =====================================================================
	wire         snd_rom_req;
	wire  [19:0] snd_rom_addr;
	wire         snd_rom_valid;
	wire   [7:0] snd_rom_data;
	wire signed [15:0] audio_l, audio_r;
	wire         audio_stb;
	wire  [15:0] snd_dbg_samples, snd_dbg_overrun, snd_dbg_rom_reads;
	wire  [15:0] snd_cpu_rdata;

	x1_010 u_snd (
		.clk(clk), .reset(reset), .ce(ce_16m),
		.cpu_req(io_req & io_sel[8]), .cpu_we(io_we),
		.cpu_addr(io_addr[13:1]), .cpu_wdata(io_wdata),
		.cpu_uds(io_uds), .cpu_lds(io_lds), .cpu_rdata(snd_cpu_rdata),
		.rom_req(snd_rom_req), .rom_addr(snd_rom_addr),
		.rom_valid(snd_rom_valid), .rom_data(snd_rom_data),
		.audio_l(audio_l), .audio_r(audio_r), .audio_stb(audio_stb),
		.dbg_samples(snd_dbg_samples), .dbg_overrun(snd_dbg_overrun),
		.dbg_rom_reads(snd_dbg_rom_reads)
	);

	// =====================================================================
	// SDRAM transport, wired as the core will wire it: two narrow read
	// clients on one arbiter, plus the download write path.
	// =====================================================================
	localparam int NCLI = 2;
	wire [NCLI-1:0]    c_req;
	wire [26*NCLI-1:0] c_addr;
	wire [NCLI-1:0]    c_valid;
	wire [63:0]        c_rdata;

	wire        phy_req, phy_we, phy_we16, phy_busy, phy_valid;
	wire [25:0] phy_addr;
	wire [15:0] phy_wdata;
	logic [63:0] phy_rdata;

	// Registered, not constant -- same reasoning as the read-data paths above.
	always_ff @(posedge clk) phy_rdata <= {pat, ~pat};

	wire        dl_req, dl_we16, dl_busy;
	wire [25:0] dl_addr;
	wire [15:0] dl_data;
	wire        ioctl_wait;

	sdram_narrow_bridge #(.WORD_BYTES(2)) u_bridge_cpu (
		.clk(clk), .reset(reset), .inval(pat[3]),
		.req(rom_req), .addr({2'b00, rom_addr, 1'b0}),
		.valid(rom_valid), .data(rom_data),
		.g_req(c_req[0]), .g_addr(c_addr[25:0]),
		.g_valid(c_valid[0]), .g_data(c_rdata)
	);

	sdram_narrow_bridge #(.WORD_BYTES(1)) u_bridge_snd (
		.clk(clk), .reset(reset), .inval(pat[3]),
		.req(snd_rom_req), .addr({6'b000000, snd_rom_addr}),
		.valid(snd_rom_valid), .data(snd_rom_data),
		.g_req(c_req[1]), .g_addr(c_addr[51:26]),
		.g_valid(c_valid[1]), .g_data(c_rdata)
	);

	sdram_arbiter #(.N(NCLI)) u_arb (
		.clk(clk), .reset(reset),
		.phy_req(phy_req), .phy_we(phy_we), .phy_we16(phy_we16),
		.phy_addr(phy_addr), .phy_wdata(phy_wdata),
		.phy_busy(pat[4]), .phy_valid(pat[5]), .phy_rdata(phy_rdata),
		.c_req(c_req), .c_addr(c_addr), .c_valid(c_valid), .c_rdata(c_rdata),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

	sdram_download u_dl (
		.clk(clk), .reset(reset),
		.ioctl_download(pat[6]), .ioctl_index(16'd0), .ioctl_wr(pat[7]),
		.ioctl_addr({5'd0, pat[21:0]}), .ioctl_dout(pat[15:8]),
		.ioctl_wait(ioctl_wait),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data),
		.dl_we16(dl_we16), .dl_busy(dl_busy)
	);

	sdram_phy u_phy (
		.clk(clk), .reset(reset),
		.port_addr(), .port_wrl(), .port_wrh(), .port_din(),
		.port_dout(phy_rdata), .port_req(), .port_ack(pat[8]),
		.req(phy_req), .we(phy_we), .we16(phy_we16), .addr(phy_addr),
		.wdata(phy_wdata), .busy(phy_busy), .valid(phy_valid), .rdata()
	);

	// =====================================================================
	// Keep everything alive: one pin, everything XOR-reduced onto it.
	// =====================================================================
	always_ff @(posedge clk) begin
		result <= ^{
			wram_addr, wram_wel, wram_weh, wram_wdata,
			io_req, io_we, io_addr, io_wdata, io_uds, io_lds, io_sel,
			dbg_stb, dbg_addr, dbg_we, dbg_data,
			audio_l, audio_r, audio_stb,
			snd_dbg_samples, snd_dbg_overrun, snd_dbg_rom_reads, snd_cpu_rdata,
			phy_req, phy_we, phy_we16, phy_addr, phy_wdata, phy_valid,
			ioctl_wait, dl_busy
		};
	end

endmodule

`default_nettype wire
