// Seta X1-010 — 16-voice PCM / wavetable sound generator.
//
// Transcribed from src/devices/sound/x1_010.cpp. There is no existing FPGA
// implementation of this chip anywhere, so MAME's C++ is the whole
// specification; scripts/x1_010_model.py is a line-by-line transcription of the
// same function and is what sim/x1_010_tb checks this against.
//
// THE CHIP
//   16 voices, stereo, clocked at 16 MHz, one output sample every 512 clocks =
//   31.25 kHz. 8 KB of RAM visible to the 68000 as 16-bit words, of which the
//   chip reads only the LOW byte -- the high byte is a read-back shadow it
//   ignores entirely (MAME's m_HI_WORD_BUF).
//
//     0x0000-0x007f   16 channels x 8 register bytes
//     0x0080-0x0fff   envelope data
//     0x1000-0x1fff   waveform data, 128 bytes per waveform, 8-bit signed
//
//   Register 0:  bit 7 frequency divider, bit 2 envelope one-shot,
//                bit 1 mode (0 = PCM from ROM, 1 = waveform from RAM),
//                bit 0 key on.
//   PCM:      r1 volume L:R, r2 frequency, r4 start>>12, r5 (0x100-end>>12)
//   Waveform: r1 waveform number, r2/r3 pitch lo/hi, r4 envelope step,
//             r5 envelope number; the VOLUME comes from the envelope byte,
//             not from r1.
//
// THREE THINGS THAT ARE NOT GUESSABLE FROM THE REGISTER MAP
//
//   KEY-ON IS EDGE-TRIGGERED AT THE CPU WRITE, not sampled by the engine. MAME
//   resets both accumulators inside write() when bit 0 of register 0 goes
//   0 -> 1. An engine that instead resets when it *notices* key-on set drifts on
//   any channel retriggered without an intervening key-off -- quietly, as a
//   phase error rather than as silence.
//
//   IN WAVEFORM MODE THE VOLUME IS THE ENVELOPE BYTE. r1 selects the waveform.
//   Reading r1 as a volume, as PCM mode does, is an easy and near-silent error.
//
//   `if (freq == 0) freq = 4` in PCM mode is a MAME HACK, commented as such in
//   the source ("Meta Fox does write the frequency register, but this is a hack
//   to make it work with the current setup. This is broken for Arbalester").
//   Reproduced here so the two agree, and flagged so nobody later mistakes it
//   for hardware behaviour. If a real board is ever measured, start here.
//
// TIMING
//   The 16 channels are walked once per output sample. They run back to back
//   rather than in fixed 32-cycle slots, because a PCM voice waits on an SDRAM
//   round trip and a fixed slot would either waste the budget or silently drop
//   a fetch. `dbg_overrun` counts passes that did not finish before the next
//   sample tick, paired with `dbg_samples` so a zero can be told from "never
//   ran" (LESSONS_LEARNED, "Pair every bad-event counter with a total").

`default_nettype none

module x1_010 (
	input  wire         clk,
	input  wire         reset,

	// One pulse per chip clock. 16 MHz on every in-scope board.
	input  wire         ce,

	// ---- CPU side: 0x2000 16-bit words ---------------------------------------
	input  wire         cpu_req,
	input  wire         cpu_we,
	input  wire  [12:0] cpu_addr,
	input  wire  [15:0] cpu_wdata,
	input  wire         cpu_uds, cpu_lds,
	output logic [15:0] cpu_rdata,

	// ---- PCM sample ROM: req/valid, byte-wide, 1 MB --------------------------
	// rom_req is a one-cycle pulse with rom_addr held until rom_valid.
	output logic        rom_req,
	output logic [19:0] rom_addr,
	input  wire         rom_valid,
	input  wire  [7:0]  rom_data,

	// ---- audio ---------------------------------------------------------------
	output logic signed [15:0] audio_l,
	output logic signed [15:0] audio_r,
	output logic        audio_stb,

	// ---- instrumentation -----------------------------------------------------
	output logic [15:0] dbg_samples   = '0,
	output logic [15:0] dbg_overrun   = '0,
	output logic [15:0] dbg_rom_reads = '0
);

	localparam int VOL_BASE = 546;      // MAME's 2*32*256/30, evaluated as an int

	function automatic logic signed [15:0] sat16(input logic signed [31:0] v);
		if (v > 32'sd32767)       sat16 = 16'sd32767;
		else if (v < -32'sd32768) sat16 = -16'sd32768;
		else                      sat16 = v[15:0];
	endfunction

	// =====================================================================
	// Register / envelope / waveform RAM
	//
	// Two byte-wide arrays rather than one 16-bit array: the engine only ever
	// touches the low byte, so giving it its own port on a narrow array keeps
	// the read-back shadow out of the audio path entirely.
	//
	// `regmem` is TRUE dual-port -- the CPU writes registers while the engine
	// reads them, and the engine writes back the key-off bit. One read/write
	// port each, which an M10K provides. LESSONS_LEARNED warns that asking for
	// two independent READ addresses plus a write makes Quartus replicate the
	// whole array; this is not that shape, but check `Block Memory Bits` per
	// hierarchy in the fit report rather than assuming.
	// =====================================================================
	// ONE WRITE PORT, TWO READS -- a SIMPLE dual-port RAM, which an M10K
	// provides directly.
	//
	// Getting here took two attempts. The engine also needs to clear a
	// channel's key-on bit when a voice ends, which reads as a second write
	// port, and a true dual-port RAM is what that implies. Quartus inferred
	// neither shape: with two separate always blocks it built the 8 KB array
	// out of logic, taking the design to 122,886 combinational nodes against
	// the 83,820 the device has -- a 47% overshoot, reported only as
	// "Can't fit design in device", with nothing naming the RAM. Folding both
	// ports into one always block did not infer either.
	//
	// So the second write is removed instead. The sixteen key-on bits already
	// exist in flops -- `keyon_state`, which the edge detector needs anyway --
	// and that mirror is made the AUTHORITY for bit 0 of each channel's
	// register 0. The engine clears it directly; the array is never written by
	// anything but the CPU.
	//
	// The behaviour a game can observe is preserved exactly: a CPU read of a
	// channel's register 0 substitutes the mirror's bit, so polling for a voice
	// to finish still works, which is what MAME's write-back to m_reg provides.
	logic [7:0] regmem [0:8191];
	logic [7:0] shadow [0:8191];

	logic [7:0]  cpu_q, shadow_q, eng_q;
	logic [12:0] eng_addr;

	// Key-on edge, detected AT THE WRITE. cpu_addr is a WORD address and each
	// channel's 8 registers occupy 8 consecutive words, so the channel is
	// addr[6:3] and the register index addr[2:0].
	//
	// The comparison needs the CURRENT key-on bit. `cpu_q` is no use: it is a
	// REGISTERED read holding whatever address was presented last cycle, so
	// comparing against it misses every edge silently -- an earlier version of
	// this module did that and no channel ever had its accumulators reset.
	// THE WHOLE CPU INTERFACE IS REGISTERED ONE CYCLE, and that is a timing fix
	// with a measurement behind it.
	//
	// With it combinational, the worst paths in the whole Phase 0 subsystem ran
	//   TG68K's register file -> maincpu's data out -> this address decode ->
	//   the key-on comparison -> a 32-bit accumulator clear
	// all in one clock, at about -1.9 ns against a 10.4167 ns period. Relaxing
	// the CPU further did not help, because by then the failing paths were no
	// longer inside the CPU at all -- they ended here, on smp_offset[] and
	// env_offset[].
	//
	// Registering just the key-on path took it to -1.169 ns, and the remaining
	// failures were the SAME source landing on regmem's own BRAM inputs -- the
	// identical path one step further down. So the whole interface is
	// registered, write and read alike, and maincpu spends one more cycle on an
	// io access to match. That costs nothing: the CPU is stalled for the whole
	// bus cycle and steps only once every six clocks.
	//
	// Read and write share the registered address deliberately. A BRAM port has
	// ONE address; writing from the registered copy while reading from the live
	// one needs two, which is a second port this design does not have.
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

	// The engine clears a channel's key-on bit when its voice ends.
	logic        eng_keyoff;
	logic  [3:0] eng_keyoff_ch;

	// Port A: CPU read/write. Port B: engine read. Two always blocks, each a
	// plain single-port template, which is what infers.
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

	// Register 0's key-on bit comes from the mirror, not the array.
	// The read-back substitution tracks the REGISTERED address, so it lines up
	// with cpu_q, which is now read from kw_addr.
	logic       rd_was_reg0;
	logic [3:0] rd_channel;
	always_ff @(posedge clk) begin
		rd_was_reg0 <= is_ch_reg0;
		rd_channel  <= wr_channel;
	end
	assign cpu_rdata = {shadow_q,
	                    rd_was_reg0 ? {cpu_q[7:1], keyon_state[rd_channel]} : cpu_q};

	// The key-on mirror, and the authority for bit 0. Both writers update it:
	// the CPU, and the engine when a voice ends.
	always_ff @(posedge clk) begin
		if (cpu_wr_reg0)   keyon_state[wr_channel]   <= cpu_wdata[0];
		else if (eng_keyoff) keyon_state[eng_keyoff_ch] <= 1'b0;
	end

	// =====================================================================
	// ROM response capture
	//
	// The transport runs at `clk`, the engine steps on `ce`. A valid pulse
	// landing between ce ticks would simply be missed, so it is latched here,
	// outside the ce gate, and consumed inside. This is the same class as
	// LESSONS_LEARNED's "Capture read data on the valid pulse -- nothing in the
	// path latches it", made worse by the clock enable.
	// =====================================================================
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

	// =====================================================================
	// The engine
	// =====================================================================
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
	// The mix emitted at a sample boundary is the one the PREVIOUS period
	// computed -- a one-period pipeline, which is free in hardware and must
	// not be emitted before there is anything in it. Without this the first
	// sample after reset is an empty accumulator, and every later sample is
	// off by one against a reference that starts at its first real sample.
	logic        primed;

	logic [31:0] smp_offset [0:15];
	logic [31:0] env_offset [0:15];

	wire [12:0] reg0_addr  = {6'd0, ch, 3'd0};
	wire [31:0] pcm_delta  = smp_offset[ch] >> 4;
	wire [31:0] env_delta  = env_offset[ch] >> 10;
	wire  [6:0] wav_index  = smp_offset[ch][16:10];   // (smp_offs >> 10) & 0x7f
	wire        is_wave    = r0[1];
	wire        one_shot   = r0[2];
	wire        div        = r0[7];

	// The counters carry NO reset, deliberately: one cleared by the reset under
	// investigation reads zero and gets reported as a finding
	// (LESSONS_LEARNED, "Never reset a debug counter with the reset you are
	// investigating"). Their power-up value is the port declaration initialiser
	// above -- an `initial` block would be a second driver and is rejected.
	// They SATURATE rather than wrap: a wrapped 3 could mean "three times" or
	// "65,539 times", and those lead to opposite conclusions.

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
			// Key-on resets both accumulators, AT THE WRITE.
			if (keyon_edge) begin
				smp_offset[wr_channel] <= '0;
				env_offset[wr_channel] <= '0;
			end

			if (ce) begin
				if (tick == 10'd511) begin
					tick <= 10'd0;
					// MAME's units are data*vol*VOL_BASE against a full scale
					// of 32768*256, so a 16-bit sample is acc*VOL_BASE/256.
					// Saturate rather than wrap: sixteen channels at maximum
					// exceed full scale, and a wrapping accumulator was a real
					// defect on Psikyo.
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

				// READ TIMING, and why there is no pipeline stage here.
				//
				// `eng_q <= regmem[eng_addr]` runs every clk, but the engine
				// steps on `ce` -- one clk in CE_DIV. So an address set in one
				// engine step has been read out CE_DIV-1 clocks before the
				// next, and eng_q is already the byte for the address the
				// PREVIOUS state set. Each state therefore captures its own
				// byte and sets the next address; there is no wait state.
				//
				// The first version of this module carried an extra lead-in
				// state, on the reasoning that a registered RAM needs its
				// latency spent (LESSONS_LEARNED, "Give a registered RAM its
				// full read latency"). That rule is right and does not apply
				// here, and applying it anyway shifted every capture by one:
				// r0 got register 1, r1 got register 2, and every channel read
				// its mode and key-on bits out of its volume register. The
				// mix was silent and no PCM voice ever requested a sample.
				//
				// THIS DEPENDS ON CE_DIV > 1. At CE_DIV == 1 the read would
				// not have completed and the extra state WOULD be needed.
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
						// The mirror, not r0[0]: the array no longer carries a
						// live key-on bit, since the engine's key-off updates
						// only the mirror.
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
						// One-shot key-off is checked BEFORE the envelope byte
						// is used, exactly as MAME orders it.
						if (one_shot && (env_delta >= 32'd128)) begin
							eng_keyoff    <= 1'b1;
							eng_keyoff_ch <= ch;
							st            <= E_NEXT;
						end else begin
							// eng_q is the ENVELOPE byte, and in waveform mode
							// that is where the volume comes from -- not r1,
							// which selects the waveform.
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
						// Both modes land here with `sample` holding the byte
						// and vol_l/vol_r the volumes.
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
