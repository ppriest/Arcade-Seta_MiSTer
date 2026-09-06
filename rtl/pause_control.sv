// CPU pause: a toggle driven from the dedicated Pause button, plus the
// internal reasons the core must hold the CPU still.
//
// ---------------------------------------------------------------------------
// WHICH JOYSTICK BIT IS PAUSE
//
// MiSTer numbers joystick bits 0-3 as up/down/left/right and assigns bits 4
// upward to the buttons IN THE ORDER THE `.mra`'s `<buttons names="...">`
// LIST GIVES THEM. So the Pause bit is not a constant of the framework -- it
// is a function of that list, and it moves if the list changes.
//
// This core uses one list for both boards, sized to the larger:
//
//     names = "Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause"
//              bit 4     bit 5     bit 6     bit 7   bit 8 bit 9 bit 10
//
// Four buttons because FG-3 (Asura Blade/Buster) uses BUTTON1-4 while FG-2
// (Mile Smile, Puzzle Bancho) uses only BUTTON1 -- read from each driver's
// INPUT_PORTS. A single list keeps PAUSE_BIT the same for every game, which
// is worth more than trimming two unused bits on FG-2.
//
// PAUSE_BIT is a parameter rather than a literal precisely because it is a
// consequence of the `.mra` rather than of this module, and because it has
// NOT yet been confirmed on hardware. The way to confirm it, which is how the
// Psikyo core settled the same question: build, press Pause, and read back
// which joystick bit set. If the `<buttons>` list is ever edited, this must
// move with it.
// ---------------------------------------------------------------------------
//
// The button TOGGLES rather than gating directly: a level-driven pause would
// only hold while the button was held down, which is useless for looking at a
// frame. Edge-detected, so the toggle happens once per press.
//
// Internal pause reasons are ORed in separately and are NOT toggles -- they
// assert for as long as they need the CPU still (hiscore borrowing a work-RAM
// port, a debug auto-pause). Keeping them separate from the button's toggle
// state means releasing an internal hold cannot leave the user's own pause
// silently cleared.

module pause_control #(
	parameter int PAUSE_BIT = 10
) (
	input  logic        clk,
	input  logic        reset,

	// Raw joystick words, as the framework presents them. Either player's
	// Pause works, matching the Psikyo core.
	input  logic [31:0] joystick_0,
	input  logic [31:0] joystick_1,

	// Reasons the core itself needs the CPU held, ORed together by the
	// caller: hiscore RAM access, debug auto-pause, and so on. A level, not
	// a pulse.
	input  logic        ext_pause,

	// Pause the CPU. Note this does NOT pause video: the picture must keep
	// being scanned out or the display drops sync, and a paused frame is the
	// entire point of the feature.
	output logic        pause_cpu,

	// The user's own toggle state, for an OSD indicator or a debug overlay.
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
			// Rising edge only: one toggle per press, however long it is held.
			if (pause_btn && !pause_btn_d)
				pause_latched <= ~pause_latched;
		end
	end

	assign pause_cpu = pause_latched | ext_pause;

endmodule
