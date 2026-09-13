// X1-010: 16-voice PCM / wavetable sound, transcribed from MAME's
// sound/x1_010.cpp (checked against scripts/x1_010_model.py by sim/x1_010_tb).
//
// 16 MHz clock, one stereo sample per 512 clocks. 8 KB of word-wide RAM whose
// low bytes the chip uses:
//     0x0000-0x007f   16 channels x 8 registers
//     0x0080-0x0fff   envelopes
//     0x1000-0x1fff   waveforms, 128 signed bytes each
// Register 0: bit 7 divider, bit 2 one-shot envelope, bit 1 waveform mode,
// bit 0 key on.
//   PCM:      r1 volume L:R, r2 frequency, r4 start>>12, r5 (0x100-end>>12)
//   Waveform: r1 waveform, r2/r3 pitch, r4 envelope step, r5 envelope; the
//             volume is the envelope byte.
//
// Key-on resets the channel's accumulators at the CPU write. PCM frequency 0
// is replaced by 4, as MAME does (a hack there).
//
// Channels are processed back to back once per sample; dbg_overrun counts
// passes still running at the next sample.

`default_nettype none

module x1_010 (
	input  wire         clk,
	input  wire         reset,

	input  wire         ce,             // 16 MHz

	// CPU: 0x2000 words
	input  wire         cpu_req,
	input  wire         cpu_we,
	input  wire  [12:0] cpu_addr,
	input  wire  [15:0] cpu_wdata,
	input  wire         cpu_uds, cpu_lds,
	output logic [15:0] cpu_rdata,

	// PCM sample ROM: rom_req pulses, rom_addr held until rom_valid
	output logic        rom_req,
	output logic [19:0] rom_addr,
	input  wire         rom_valid,
	input  wire  [7:0]  rom_data,

	output logic signed [15:0] audio_l,
	output logic signed [15:0] audio_r,
	output logic        audio_stb,

	output logic [15:0] dbg_samples   = '0,
	output logic [15:0] dbg_overrun   = '0,
	output logic [15:0] dbg_rom_reads = '0
);

	localparam int VOL_BASE = 546;      // MAME's 2*32*256/30, evaluated as an int

	function automatic logic signed [15:0] sat16(input logic signed [31:0] v);
		if (v > 32'sd32767)       sat16 = 16'sd32767;
		else if (v < -32'sd32768) sat16 = 16'sh8000;
		else                      sat16 = v[15:0];
	endfunction

	// Register/envelope/waveform RAM: low bytes in regmem (CPU read/write port,
	// engine read port), high bytes in a CPU-only shadow. Register 0's key-on
	// bit lives in keyon_state, which the engine clears when a voice ends, so
	// the RAM has a single writer; CPU reads of register 0 substitute it.
	logic [7:0] regmem [0:8191];
	logic [7:0] shadow [0:8191];

	logic [7:0]  cpu_q, shadow_q, eng_q;
	logic [12:0] eng_addr;

	// The CPU interface is registered (timing); maincpu allows for it. The
	// channel is addr[6:3], the register addr[2:0].
	logic        kw_req, kw_we, kw_lds;
	logic [12:0] kw_addr;
	logic [15:0] kw_wdata;
	always_ff @(posedge clk) begin
		kw_req   <= cpu_req;
		kw_we    <= cpu_we;
		kw_lds   <= cpu_lds;
		kw_addr  <= cpu_addr;
		kw_wdata <= cpu_wdata;
	end

	wire        is_ch_reg0  = (kw_addr[12:7] == 6'd0) && (kw_addr[2:0] == 3'd0);
	wire  [3:0] wr_channel  = kw_addr[6:3];
	wire        cpu_wr_reg0 = kw_req && kw_we && kw_lds && is_ch_reg0;

	logic [15:0] keyon_state = '0;
	wire        keyon_edge = cpu_wr_reg0 && !keyon_state[wr_channel] && kw_wdata[0];

	logic        eng_keyoff;
	logic  [3:0] eng_keyoff_ch;

	wire kw_we_lo = kw_req && kw_we && kw_lds;
	always_ff @(posedge clk) begin
		if (kw_we_lo) regmem[kw_addr] <= kw_wdata[7:0];
		cpu_q <= regmem[kw_addr];
	end
	always_ff @(posedge clk) begin
		eng_q <= regmem[eng_addr];
	end

	logic kw_uds;
	always_ff @(posedge clk) kw_uds <= cpu_uds;
	always_ff @(posedge clk) begin
		if (kw_req && kw_we && kw_uds) shadow[kw_addr] <= kw_wdata[15:8];
		shadow_q <= shadow[kw_addr];
	end

	logic       rd_was_reg0;
	logic [3:0] rd_channel;
	always_ff @(posedge clk) begin
		rd_was_reg0 <= is_ch_reg0;
		rd_channel  <= wr_channel;
	end
	assign cpu_rdata = {shadow_q,
	                    rd_was_reg0 ? {cpu_q[7:1], keyon_state[rd_channel]} : cpu_q};

	always_ff @(posedge clk) begin
		if (cpu_wr_reg0)   keyon_state[wr_channel]   <= cpu_wdata[0];
		else if (eng_keyoff) keyon_state[eng_keyoff_ch] <= 1'b0;
	end

	// ROM responses arrive on clk; the engine steps on ce. Latch them.
	logic       rom_got;
	logic [7:0] rom_hold;
	always_ff @(posedge clk) begin
		if (reset) begin
			rom_got <= 1'b0;
		end else begin
			if (rom_valid) begin
				rom_hold <= rom_data;
				rom_got  <= 1'b1;
			end
			if (rom_req) rom_got <= 1'b0;      // a new request clears the old answer
		end
	end

	typedef enum logic [3:0] {
		E_IDLE, E_R0, E_R1, E_R2, E_R3, E_R4, E_R5, E_CALC,
		E_ENVRD, E_WAVRD, E_ROMREQ, E_ROMWAIT, E_ACC, E_NEXT
	} estate_t;
	estate_t st;

	logic  [3:0] ch;
	logic  [9:0] tick;
	logic  [7:0] r0, r1, r2, r3, r4, r5;
	logic signed [17:0] acc_l, acc_r;
	logic  [3:0] vol_l, vol_r;
	logic signed [7:0] sample;
	logic [31:0] step, env_step;
	logic [23:0] pcm_start, pcm_end;
	logic        pass_busy;
	logic        primed;     // a sample period has completed since reset

	logic [31:0] smp_offset [0:15];
	logic [31:0] env_offset [0:15];

	wire [12:0] reg0_addr  = {6'd0, ch, 3'd0};
	wire [31:0] pcm_delta  = smp_offset[ch] >> 4;
	wire [31:0] env_delta  = env_offset[ch] >> 10;
	wire  [6:0] wav_index  = smp_offset[ch][16:10];   // (smp_offs >> 10) & 0x7f
	wire        is_wave    = r0[1];
	wire        one_shot   = r0[2];
	wire        div        = r0[7];

	// dbg_* counters saturate and are not reset.

	always_ff @(posedge clk) begin
		audio_stb  <= 1'b0;
		eng_keyoff <= 1'b0;
		rom_req    <= 1'b0;

		if (reset) begin
			st        <= E_IDLE;
			ch        <= 4'd0;
			tick      <= 10'd0;
			acc_l     <= '0;
			acc_r     <= '0;
			pass_busy <= 1'b0;
			primed    <= 1'b0;
			audio_l   <= '0;
			audio_r   <= '0;
			for (int i = 0; i < 16; i++) begin
				smp_offset[i] <= '0;
				env_offset[i] <= '0;
			end
		end else begin
			if (keyon_edge) begin
				smp_offset[wr_channel] <= '0;
				env_offset[wr_channel] <= '0;
			end

			if (ce) begin
				if (tick == 10'd511) begin
					tick <= 10'd0;
					// acc * VOL_BASE / 256, saturated
					audio_l   <= sat16((acc_l * VOL_BASE) >>> 8);
					audio_r   <= sat16((acc_r * VOL_BASE) >>> 8);
					audio_stb <= primed;
					primed    <= 1'b1;
					if (primed && ~&dbg_samples) dbg_samples <= dbg_samples + 16'd1;
					if (pass_busy && ~&dbg_overrun)
						dbg_overrun <= dbg_overrun + 16'd1;
					acc_l     <= '0;
					acc_r     <= '0;
					ch        <= 4'd0;
					eng_addr  <= 13'd0;          // channel 0, register 0
					st        <= E_R0;
					pass_busy <= 1'b1;
				end else begin
					tick <= tick + 10'd1;
				end

				// eng_q holds the byte for the address set by the previous
				// engine step (ce is one clk in several), so each state
				// captures its byte and sets the next address.
				case (st)
					E_IDLE: ;

					E_R0: begin r0 <= eng_q; eng_addr <= reg0_addr | 13'd1; st <= E_R1; end
					E_R1: begin r1 <= eng_q; eng_addr <= reg0_addr | 13'd2; st <= E_R2; end
					E_R2: begin r2 <= eng_q; eng_addr <= reg0_addr | 13'd3; st <= E_R3; end
					E_R3: begin r3 <= eng_q; eng_addr <= reg0_addr | 13'd4; st <= E_R4; end
					E_R4: begin r4 <= eng_q; eng_addr <= reg0_addr | 13'd5; st <= E_R5; end
					E_R5: begin r5 <= eng_q;                                st <= E_CALC; end

					E_CALC: begin
						st <= E_NEXT;                        // default: channel idle
						if (keyon_state[ch]) begin           // key on
							if (!r0[1]) begin
								// ---- PCM ----
								pcm_start <= {r4, 12'd0};
								pcm_end   <= (24'h100 - {16'd0, r5}) << 12;
								vol_l     <= r1[7:4];
								vol_r     <= r1[3:0];
								step      <= ((r2 >> (r0[7] ? 1 : 0)) == 8'd0)
								             ? 32'd4                    // MAME's hack
								             : {24'd0, (r2 >> (r0[7] ? 1 : 0))};
								st        <= E_ROMREQ;
							end else begin
								// ---- waveform ----
								// env = (r5 << 7) + ((env_offs >> 10) & 0x7f)
								step     <= {16'd0, {r3, r2}} >> (r0[7] ? 1 : 0);
								env_step <= {24'd0, r4};
								eng_addr <= ({r5, 7'd0} + {6'd0, env_delta[6:0]})
								            & 13'h1FFF;
								st       <= E_ENVRD;
							end
						end
					end

					// ---- waveform ----
					E_ENVRD: begin
						if (one_shot && (env_delta >= 32'd128)) begin
							eng_keyoff    <= 1'b1;
							eng_keyoff_ch <= ch;
							st            <= E_NEXT;
						end else begin
							// volume from the envelope byte
							vol_l <= eng_q[7:4];
							vol_r <= eng_q[3:0];
							// wave = 0x1000 + (r1 << 7) + ((smp_offs >> 10) & 0x7f)
							eng_addr <= (13'h1000 + {r1, 7'd0} + {6'd0, wav_index})
							            & 13'h1FFF;
							st       <= E_WAVRD;
						end
					end

					E_WAVRD: begin
						sample <= eng_q;          // the waveform byte, signed
						st     <= E_ACC;
					end

					// ---- PCM ----
					E_ROMREQ: begin
						if ((pcm_start + pcm_delta[23:0]) >= pcm_end) begin
							eng_keyoff    <= 1'b1;            // key off
							eng_keyoff_ch <= ch;
							st            <= E_NEXT;
						end else begin
							rom_addr      <= (pcm_start + pcm_delta[23:0]) & 24'hFFFFF;
							rom_req       <= 1'b1;
							if (~&dbg_rom_reads) dbg_rom_reads <= dbg_rom_reads + 16'd1;
							st            <= E_ROMWAIT;
						end
					end

					E_ROMWAIT: if (rom_got) begin
						sample <= rom_hold;
						st     <= E_ACC;
					end

					E_ACC: begin
						acc_l <= acc_l + $signed({{10{sample[7]}}, sample}) *
						                 $signed({14'd0, vol_l});
						acc_r <= acc_r + $signed({{10{sample[7]}}, sample}) *
						                 $signed({14'd0, vol_r});
						smp_offset[ch] <= smp_offset[ch] + step;
						if (is_wave) env_offset[ch] <= env_offset[ch] + env_step;
						st <= E_NEXT;
					end

					E_NEXT: begin
						if (ch == 4'd15) begin
							pass_busy <= 1'b0;
							st        <= E_IDLE;
						end else begin
							ch       <= ch + 4'd1;
							eng_addr <= {6'd0, ch + 4'd1, 3'd0};   // next ch, reg 0
							st       <= E_R0;
						end
					end

					default: st <= E_IDLE;
				endcase
			end
		end
	end

endmodule

`default_nettype wire
