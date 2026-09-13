// CPU pause: the Pause button toggles, ext_pause holds as a level. Not yet
// instantiated. PAUSE_BIT is the joystick bit the .mra's <buttons> list gives
// Pause (bit 4 + its index).

module pause_control #(
	parameter int PAUSE_BIT = 10
) (
	input  logic        clk,
	input  logic        reset,

	input  logic [31:0] joystick_0,
	input  logic [31:0] joystick_1,

	input  logic        ext_pause,

	output logic        pause_cpu,

	output logic        pause_latched
);

	wire pause_btn = joystick_0[PAUSE_BIT] | joystick_1[PAUSE_BIT];

	logic pause_btn_d;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			pause_btn_d   <= 1'b0;
			pause_latched <= 1'b0;
		end else begin
			pause_btn_d <= pause_btn;
			if (pause_btn && !pause_btn_d)
				pause_latched <= ~pause_latched;
		end
	end

	assign pause_cpu = pause_latched | ext_pause;

endmodule
