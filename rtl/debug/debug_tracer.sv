// Trace buffer for bring-up, read out on the video output (one entry per
// line) and controlled from the OSD. Not instantiated at present.
//
// cap_stb pulses once per event with cap_data valid. No reset: registers
// power up to zero. ctl_window skips ctl_window * 8191 events before
// recording; a change on ctl_rearm restarts capture. In ring mode the buffer
// keeps the latest DEPTH events and freezes when the stream goes quiet or
// cap_trig fires.

module debug_tracer #(
	parameter int DEPTH = 256,   // entries; also the events-per-window step
	parameter int WIDTH = 24,    // bits per entry (24 = one RGB pixel)

	// default for ctl_ring: 0 = first DEPTH events then hold, 1 = ring
	parameter bit MODE_RING = 1'b0,
	parameter int IDLE_BITS = 22   // ring mode: freeze after 2**IDLE_BITS idle clks
) (
	input  logic              clk,

	input  logic              cap_stb,    // ONE cycle per event
	input  logic [WIDTH-1:0]  cap_data,

	input  logic              ctl_rearm,  // any change restarts capture
	input  logic [3:0]        ctl_window, // skip ctl_window*8191 events first
	input  logic              ctl_ring,   // 1 = ring (latest N), 0 = first N
	input  logic              ctl_trig_en,// 1 = freeze on first cap_trig

	// freeze on the first occurrence (ring mode)
	input  logic              cap_trig,

	input  logic [8:0]        rd_index,
	output logic [WIDTH-1:0]  rd_data,

	// ring mode: buffer has stopped
	output logic              frozen
);

	localparam int AW = $clog2(DEPTH);

	(* ramstyle = "no_rw_check" *) logic [WIDTH-1:0] mem [0:DEPTH-1];

	// no reset: power-up zero
	logic [AW:0]  wptr      = '0;   // extra MSB is the "full" flag
	logic [19:0]  skip_cnt  = '0;
	logic         rearm_d   = 1'b0;

	wire full        = wptr[AW];

	// odd skip step, so a window cannot alias a power-of-two event period
	wire [19:0] skip_target = ({16'd0, ctl_window} << 13) - {16'd0, ctl_window};

	// clk cycles since the last event, saturating
	logic [IDLE_BITS-1:0] idle_cnt = '0;
	wire idle_hit = &idle_cnt;

	logic trig_seen = 1'b0;

	// frozen reads the registered trig_seen, so the trigger event is captured
	assign frozen = ctl_ring ? (idle_hit | trig_seen) : full;

	always_ff @(posedge clk) begin
		rearm_d <= ctl_rearm;

		if (ctl_rearm != rearm_d) begin
			wptr      <= '0;
			skip_cnt  <= '0;
			idle_cnt  <= '0;
			trig_seen <= 1'b0;
		end else if (cap_stb) begin
			idle_cnt <= '0;
			if (ctl_trig_en && cap_trig) trig_seen <= 1'b1;
			if (!frozen) begin
				if (skip_cnt < skip_target) begin
					skip_cnt <= skip_cnt + 20'd1;
				end else begin
					mem[wptr[AW-1:0]] <= cap_data;
					wptr              <= wptr + 1'b1;
				end
			end
		end else if (ctl_ring && !idle_hit) begin
			idle_cnt <= idle_cnt + 1'b1;
		end
	end

	// verilator lint_off UNUSED
	wire _unused_mode_ring = MODE_RING;
	// verilator lint_on UNUSED

	always_ff @(posedge clk) begin
		rd_data <= mem[rd_index[AW-1:0]];
	end

endmodule
