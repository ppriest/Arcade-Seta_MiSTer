// Rotary joysticks for the downtown.cpp games, with the controls the Ikari
// Warriors core (MiSTer-devel/Arcade-IkariWarriors_MiSTer) gives: Rotate Left
// and Rotate Right buttons step the stick while held, at the OSD's Rotary
// Speed, and a GRS Super Joystick in keystroke mode sends its spinner as keys
// (P1 Left/Right arrows, P2 C/V), stepped at the fastest rate.
//
// Each game turns a step into what its board reads: DownTown's 12-position
// switch (downtown_sub.sv), Caliber 50's uPD4701 count (4 counts a position,
// 16 positions a turn: its 68000 takes (count + 2) >> 2 and masks it to 4 bits).
//
// Rates at 96 MHz: Normal 156 ms a step (Ikari's Normal, 2^23 cycles at
// 53.6 MHz), Slow twice that, Fast half, Very Fast a quarter.

`default_nettype none

module rotary_input (
	input  wire        clk,
	input  wire        reset,
	input  wire  [1:0] speed,          // 0 Normal, 1 Slow, 2 Fast, 3 Very Fast
	input  wire        grs,            // GRS Super Joystick, keystroke mode
	input  wire [10:0] ps2_key,        // hps_io: [10] toggles per event, [9] pressed, [8] extended
	input  wire  [1:0] btn_left,       // per player
	input  wire  [1:0] btn_right,
	output logic [1:0] step_left = 2'b00,   // one clk pulse per step
	output logic [1:0] step_right = 2'b00
);

	// GRS keys
	logic [1:0] key_l = 2'b00, key_r = 2'b00;
	logic       key_tog = 1'b0;
	always_ff @(posedge clk) begin
		key_tog <= ps2_key[10];
		if (reset || !grs) begin
			key_l <= 2'b00;
			key_r <= 2'b00;
		end else if (key_tog != ps2_key[10]) begin
			case ({ps2_key[8], ps2_key[7:0]})
				9'h16B: key_l[0] <= ps2_key[9];   // Left arrow
				9'h174: key_r[0] <= ps2_key[9];   // Right arrow
				9'h021: key_l[1] <= ps2_key[9];   // C
				9'h02A: key_r[1] <= ps2_key[9];   // V
				default: ;
			endcase
		end
	end

	logic [24:0] div = '0;
	wire  [24:0] period = grs            ? 25'd3_750_000
	                    : (speed == 2'd1) ? 25'd30_000_000
	                    : (speed == 2'd2) ? 25'd7_500_000
	                    : (speed == 2'd3) ? 25'd3_750_000
	                    :                   25'd15_000_000;
	wire tick = (div >= period - 25'd1);
	always_ff @(posedge clk) div <= (reset || tick) ? 25'd0 : div + 25'd1;

	wire [1:0] l = btn_left  | key_l;
	wire [1:0] r = btn_right | key_r;
	always_ff @(posedge clk) begin
		step_left  <= tick ? (l & ~r) : 2'b00;
		step_right <= tick ? (r & ~l) : 2'b00;
	end

endmodule

`default_nettype wire
