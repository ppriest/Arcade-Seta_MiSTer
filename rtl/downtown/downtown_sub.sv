// The downtown.cpp boards' 65C02 sub CPU: T65 (rtl/cpu/t65c02.vhd) and what
// each map puts on its bus.
//
// Maps 0-2 (downtown_sub_map, twineagl_sub_map, metafox_sub_map):
//   0000-01ff  RAM
//   0800/0801  latch 0 / latch 1 (written by the 68000 at sub_ctrl +2/+3)
//   1000-1007  inputs (map-specific); a write sets the ROM bank (bits 7-4),
//              the coin lockout and clears the IRQ
//   5000-57ff  shared RAM (the 68000's window, low byte of each word)
//   6000-7fff  ROM
//   8000-bfff  ROM window, entry = bank % bank_entries
//   c000-ffff  ROM
// Map 3 (calibr50_sub_map):
//   0000-1fff  the X1-010, at offset ^ 0x1000 (so its registers are
//              0x1000-0x1fff and 0x0000-0x0fff is wave RAM -- the 65C02's
//              zero page and stack)
//   4000       read: latch 0 (written by the 68000 at 0xb00001); write:
//              bits 7-4 ROM bank, bit 3 low acknowledges the latch (NMI),
//              bit 2 low clears the IRQ, bit 1 /PCMMUTE
//   8000-bfff  ROM window;  c000-ffff  ROM; a write to c000 is latch 1,
//              read by the 68000 at 0xb00001
//   NMI while latch 0 is pending; IRQ from irq_pulse; held in reset while
//   sub_hold (0x500001 bit 4 low)
// Map 4 (tndrcade_sub_map): as map 0, with 0800 reading 0xff, 1000-1002
//   P1 / P2 / COINS, the YM2203 at 2000-2001 and the YM3812 at 3000-3001.
//
// ROM addresses are the "sub" region's offsets: the fixed windows read the
// region at the CPU address, the window reads 0xc000 + entry * 0x4000.
// Interrupts: irq_pulse asserts the IRQ (held until cleared as above),
// nmi_pulse pulses the NMI (maps 0-2 and 4); seta_core picks the source for
// each board.

`default_nettype none

module downtown_sub (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce,            // one pulse per 65C02 clock (2 MHz)

	// 0 downtown, 1 twineagl, 2 metafox, 3 calibr50, 4 tndrcade
	input  wire  [2:0] sub_map,
	// 16 (0x4c000 region), 8 (0x2c000), 1 (0x10000: the window is 0xc000)
	input  wire  [4:0] bank_entries,

	// 68000: the shared RAM (byte address) and sub_ctrl writes
	input  wire        m_shr_req,
	input  wire        m_shr_we,
	input  wire [10:0] m_shr_addr,
	input  wire  [7:0] m_shr_wdata,
	output logic [7:0] m_shr_rdata,
	input  wire        m_ctrl_we,
	input  wire  [1:0] m_ctrl_addr,
	input  wire  [7:0] m_ctrl_wdata,
	// calibr50: the 68000's side of the two latches, and its reset control
	input  wire        m_ltc_we,
	input  wire  [7:0] m_ltc_wdata,
	output logic [7:0] m_ltc_q,
	input  wire        sub_hold,

	// active low driver ports
	input  wire  [7:0] p1_in, p2_in, coins_in,
	// DownTown's rotary joysticks, 0..11
	input  wire  [3:0] rot1, rot2,

	input  wire        irq_pulse,
	input  wire        nmi_pulse,

	// calibr50: the X1-010's CPU port, byte-wide (its register offset)
	output logic        x1_req,
	output logic        x1_we,
	output wire  [12:0] x1_addr,
	output wire   [7:0] x1_wdata,
	input  wire   [7:0] x1_rdata,
	output logic        pcm_on,

	// tndrcade: YM2203 (cs 0) and YM3812 (cs 1)
	output logic  [1:0] ym_cs,
	output logic        ym_we,
	output wire         ym_a0,
	output wire   [7:0] ym_wdata,
	input  wire   [7:0] ym_rdata,

	// "sub" region, byte address
	output logic       rom_req,
	output logic [18:0] rom_addr,
	input  wire        rom_valid,
	input  wire  [7:0] rom_data
);

	wire [15:0] a;
	wire  [7:0] dout;
	wire        rw_n, sync;
	logic       step;
	logic       irq_n = 1'b1, nmi_n = 1'b1;
	logic       sub_reset;
	logic [7:0] din;

	wire c50 = (sub_map == 3'd3);
	wire tc  = (sub_map == 3'd4);

	t65c02 u_cpu (
		.clk(clk), .ce(step), .reset_n(~sub_reset),
		.irq_n(irq_n), .nmi_n(nmi_n),
		.addr(a), .din(rw_n ? din : dout), .dout(dout), .rw_n(rw_n), .sync(sync)
	);

	// sub_ctrl_w: +0 bit 0 rising resets the 65C02; +2, +3 the latches
	logic [7:0] ctrl0 = 8'h00;
	logic [7:0] latch0 = 8'h00, latch1 = 8'h00;
	logic       reset_pulse;
	always_ff @(posedge clk) begin
		reset_pulse <= 1'b0;
		if (reset) begin
			ctrl0  <= 8'h00;
			latch0 <= 8'h00;
			latch1 <= 8'h00;
		end else if (m_ctrl_we) begin
			case (m_ctrl_addr)
				2'd0: begin
					if (!ctrl0[0] && m_ctrl_wdata[0]) reset_pulse <= 1'b1;
					ctrl0 <= m_ctrl_wdata;
				end
				2'd2: latch0 <= m_ctrl_wdata;
				2'd3: latch1 <= m_ctrl_wdata;
				default: ;
			endcase
		end else if (m_ltc_we) begin
			latch0 <= m_ltc_wdata;
		end
	end
	assign sub_reset = reset | reset_pulse | (c50 && sub_hold);

	// shared RAM, true dual port: the 68000 on port a, the 65C02 on port b
	logic [7:0] shr [0:2047];
	logic       s_we;
	logic [10:0] s_addr;
	logic [7:0] s_q;
	always_ff @(posedge clk) begin
		if (m_shr_req && m_shr_we) shr[m_shr_addr] <= m_shr_wdata;
		m_shr_rdata <= shr[m_shr_addr];
	end
	always_ff @(posedge clk) begin
		if (s_we) shr[s_addr] <= dout;
		s_q <= shr[s_addr];
	end

	logic [7:0] ram [0:511];
	logic       r_we;
	logic [8:0] r_addr;
	logic [7:0] r_q;
	always_ff @(posedge clk) begin
		if (r_we) ram[r_addr] <= dout;
		r_q <= ram[r_addr];
	end

	// downtown_ip_r's rotation: ~(0x800 >> position) & 0xfff
	wire [11:0] dir1 = ~(12'h800 >> rot1);
	wire [11:0] dir2 = ~(12'h800 >> rot2);

	logic [7:0] io_q;
	always_comb begin
		io_q = 8'h00;
		case (sub_map)
			3'd0: case (a[2:0])                          // downtown_ip_r
				3'd0: io_q = {coins_in[7:4], dir1[11:8]};
				3'd1: io_q = dir1[7:0];
				3'd2: io_q = p1_in;
				3'd4: io_q = {4'h0, dir2[11:8]};
				3'd5: io_q = dir2[7:0];
				3'd6: io_q = p2_in;
				default: io_q = 8'hff;
			endcase
			3'd1, 3'd4: case (a[2:0])                    // twineagl, tndrcade
				3'd0: io_q = p1_in;
				3'd1: io_q = p2_in;
				3'd2: io_q = coins_in;
				default: io_q = 8'h00;
			endcase
			default: case (a[2:0])                       // metafox
				3'd0: io_q = coins_in;
				3'd2: io_q = p1_in;
				3'd6: io_q = p2_in;
				default: io_q = 8'h00;
			endcase
		endcase
	end

	logic [3:0] bank = 4'd0;
	wire  [3:0] entry = (bank_entries == 5'd16) ? bank
	                  : (bank_entries == 5'd8)  ? {1'b0, bank[2:0]} : 4'd0;

	// calibr50's latches: latch 0 pending until acknowledged through 0x4000
	// bit 3 (generic_latch_8 with separate acknowledge), which is the NMI
	logic ltc0_pending = 1'b0;

	// Bus decode
	wire is_x1  = c50 && (a[15:13] == 3'd0);
	wire is_c4k = c50 && (a == 16'h4000);
	wire is_ram = !c50 && (a[15:9] == 7'd0);
	wire is_shr = !c50 && (a[15:11] == 5'b01010);
	wire is_io  = !c50 && (a[15:8] == 8'h10);
	wire is_ltc = !c50 && (a[15:1] == 15'h0400);       // 0x0800, 0x0801
	wire is_ym0 = tc && (a[15:1] == 15'h1000);         // 0x2000-0x2001
	wire is_ym1 = tc && (a[15:1] == 15'h1800);         // 0x3000-0x3001
	wire is_rom = c50 ? a[15] : ((a[15:13] == 3'b011) || a[15]);

	assign x1_addr  = a[12:0] ^ 13'h1000;
	assign x1_wdata = dout;
	assign ym_a0    = a[0];
	assign ym_wdata = dout;

	// interrupts. IRQ held from irq_pulse until the map's clear. NMI: the
	// latch on calibr50; elsewhere low from nmi_pulse until the CPU has
	// stepped past it.
	logic nmi_hold;
	wire  irq_clr = step && !rw_n && (c50 ? (is_c4k && !dout[2]) : (a[15:12] == 4'h1));
	always_ff @(posedge clk) begin
		if (sub_reset) begin
			irq_n    <= 1'b1;
			nmi_n    <= 1'b1;
			nmi_hold <= 1'b0;
		end else begin
			if (irq_pulse) irq_n <= 1'b0;
			if (irq_clr)   irq_n <= 1'b1;
			if (c50) begin
				nmi_n <= !ltc0_pending;
			end else begin
				if (nmi_pulse) begin nmi_n <= 1'b0; nmi_hold <= 1'b1; end
				if (step && nmi_hold) nmi_hold <= 1'b0;
				if (step && !nmi_hold) nmi_n <= 1'b1;
			end
		end
	end

	// latches and /PCMMUTE: MACHINE_RESET writes 0 to 0x4000 (muted, latch
	// acknowledged)
	always_ff @(posedge clk) begin
		if (reset) begin
			ltc0_pending <= 1'b0;
			m_ltc_q      <= 8'h00;
			pcm_on       <= 1'b0;
		end else begin
			if (m_ltc_we) ltc0_pending <= 1'b1;
			if (step && !rw_n && is_c4k) begin
				if (!dout[3]) ltc0_pending <= 1'b0;
				pcm_on <= dout[1];
			end
			if (step && !rw_n && c50 && a == 16'hc000) m_ltc_q <= dout;
		end
	end

	// Bus sequencing: the address T65 presents is stable between steps. Decode
	// it, fetch the data, then step on the next 2 MHz tick. The X1-010 and the
	// YMs answer two clk after their address.
	typedef enum logic [2:0] { S_ADDR, S_ROM, S_RAM, S_WAIT, S_READY } state_t;
	state_t state;
	logic   tick;
	logic [1:0] wait_n;

	always_ff @(posedge clk) begin
		step    <= 1'b0;
		rom_req <= 1'b0;
		r_we    <= 1'b0;
		s_we    <= 1'b0;
		x1_req  <= 1'b0;
		x1_we   <= 1'b0;
		ym_cs   <= 2'b00;
		ym_we   <= 1'b0;
		if (ce) tick <= 1'b1;

		if (sub_reset) begin
			state <= S_ADDR;
			bank  <= 4'd0;
		end else begin
			case (state)
				S_ADDR: if (!step) begin
					r_addr <= a[8:0];
					s_addr <= a[10:0];
					if (!rw_n) begin
						din   <= dout;
						state <= S_READY;
					end else if (is_ram || is_shr) begin
						state <= S_RAM;
					end else if (is_x1 || is_ym0) begin
						// hold the read strobe until the data is taken
						wait_n <= 2'd3;
						state  <= S_WAIT;
					end else if (is_rom) begin
						rom_req  <= 1'b1;
						rom_addr <= (a[15:14] == 2'b10)
						          ? 19'h0c000 + {1'b0, entry, 14'd0} + {5'd0, a[13:0]}
						          : {3'd0, a};
						state    <= S_ROM;
					end else begin
						din   <= is_io  ? io_q
						       : is_c4k ? latch0
						       : is_ltc ? (tc ? 8'hff : a[0] ? latch1 : latch0)
						       : 8'h00;
						state <= S_READY;
					end
				end
				S_RAM:  state <= S_READY;       // the RAMs' registered read
				S_ROM:  if (rom_valid) begin din <= rom_data; state <= S_READY; end
				S_WAIT: begin
					ym_cs <= {1'b0, is_ym0};
					if (wait_n == 2'd0) begin
						din   <= is_x1 ? x1_rdata : ym_rdata;
						state <= S_READY;
					end else wait_n <= wait_n - 2'd1;
				end
				S_READY: begin
					if (state == S_READY && (is_ram || is_shr) && rw_n) din <= is_ram ? r_q : s_q;
					if (tick) begin
						tick <= ce;
						step <= 1'b1;
						if (!rw_n) begin
							if (is_ram) r_we <= 1'b1;
							if (is_shr) s_we <= 1'b1;
							if (is_io)  bank <= dout[7:4];
							if (is_c4k) bank <= dout[7:4];
							if (is_x1)  begin x1_req <= 1'b1; x1_we <= 1'b1; end
							if (is_ym0 || is_ym1) begin ym_cs <= {is_ym1, is_ym0}; ym_we <= 1'b1; end
						end
						state <= S_ADDR;
					end
				end
				default: state <= S_ADDR;
			endcase
		end
	end

endmodule

`default_nettype wire
