// Interrupt requests: pending flags, and the two ways seta.cpp clears them.
//
// MAME drives this hardware's interrupts two different ways and the difference
// is not cosmetic:
//
//   HOLD_LINE    asserted, and cleared automatically when the CPU ACKNOWLEDGES.
//                seta_interrupt_1_and_2 uses it for both of its scanline IRQs,
//                and so does umanclub's vblank.
//   ASSERT_LINE  asserted, and cleared ONLY by an explicit write. thunderl and
//                wits map ipl1_ack_w at 0x200000 for exactly this;
//                seta_interrupt_2_and_4 has ipl1_ack_w and ipl2_ack_w.
//
// The 3-argument form of MAME's devcb `set_inputline(tag, line, value)` is
// `if (data) exec.set_input_line(linenum, value)` -- read from
// src/emu/devcb.h rather than assumed. It fires only on the RISING edge and
// does NOT clear on the falling one, so an ASSERT_LINE vblank source stays
// asserted after vblank ends. blockcar has exactly that and maps no ack at
// all, so its IRQ 3 is permanently pending once the first vblank has passed;
// the game masks it in SR instead. That is what the hardware does and this
// module reproduces it rather than tidying it.
//
// The seta.cpp naming is by PIN, not by level: ipl0_ack_w clears level 1,
// ipl1_ack_w clears level 2, ipl2_ack_w clears level 4. Reading those as
// levels puts every acknowledge one step out.
//
// GROUP A WIRING, from each machine_config:
//   thunderl, wits        vblank -> 2, ASSERT, ack at 0x200000 (ipl1_ack_w)
//   blockcar              vblank -> 3, ASSERT, no ack mapped
//   umanclub, neobattl    vblank -> 3, HOLD
//   atehate, pairlove     scanline 240 -> 1 and scanline 112 -> 2, both HOLD
//                         (seta_interrupt_1_and_2)
//
// THE ACKNOWLEDGE MUST WIN OVER THE SET, and it is applied first below. Every
// one of these sources is a level that is still asserted when the CPU responds
// -- vblank lasts many scanlines and the CPU acknowledges within microseconds.
// Give the set priority instead and the pending flag never clears, ipl stays
// asserted, and the ISR re-enters after every RTE. The Psikyo project shipped
// exactly that bug for its whole life because its testbench pulsed vblank for
// ONE CLOCK, so the acknowledge always landed after the source fell and every
// test passed (LESSONS_LEARNED, "Ask of every stimulus whether it is the shape
// the real system produces").
//
// Why a coincident set-and-acknowledge latches rather than clears: the sets
// here are one-cycle EDGES, so a set can never starve an acknowledge the way a
// level can. An edge arriving on the same cycle as an acknowledge is a NEW
// interrupt arriving as an older one is taken, and dropping it would lose it.
//
// THE LEVEL BEING ACKNOWLEDGED is the one the CPU LATCHED when it decided to
// take the interrupt, and it drives that level onto A3..A1 during the
// acknowledge cycle -- TG68KdotC_Kernel.vhd, `memaddr_a(4 downto 0) <= '1' &
// rIPL_nr & '0'`, exactly as a 68000 does. Clearing the highest level pending
// at the acknowledge instead is wrong: a higher interrupt arriving between the
// CPU's decision and its acknowledge cycle would be cleared without ever being
// taken, and the lower one it displaced left pending and taken twice.

`default_nettype none

module seta_irq (
	input  wire        clk,
	input  wire        reset,

	// One-cycle pulse per level to latch a request. Levels 1..7; index 0 does
	// not exist on a 68000.
	input  wire  [7:1] set,

	// Per level: 1 = HOLD_LINE (the acknowledge clears it), 0 = ASSERT_LINE
	// (only `clr` does).
	input  wire  [7:1] hold,

	// One-cycle pulse per level from the board's acknowledge decode.
	input  wire  [7:1] clr,

	// From maincpu.sv: an interrupt-acknowledge bus cycle, and the level the
	// CPU latched, off A3..A1.
	input  wire        iack,
	input  wire  [2:0] iack_level,

	output logic [2:0] ipl_level,
	output logic [7:1] pending
);

	always_ff @(posedge clk) begin
		if (reset) begin
			pending <= 7'd0;
		end else begin
			// Acknowledge first, set second -- see the header.
			if (iack && iack_level != 3'd0 && hold[iack_level])
				pending[iack_level] <= 1'b0;

			for (int n = 1; n <= 7; n++) begin
				if (!hold[n] && clr[n]) pending[n] <= 1'b0;
				if (set[n])             pending[n] <= 1'b1;
			end
		end
	end

	always_comb begin
		ipl_level = 3'd0;
		for (int n = 1; n <= 7; n++)
			if (pending[n]) ipl_level = n[2:0];
	end

endmodule

`default_nettype wire
