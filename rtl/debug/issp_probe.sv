// In-System Sources and Probes: read core state over JTAG, and poke it back.
//
// WHY THIS RATHER THAN SIGNALTAP
// SignalTap acquisition is not scriptable in Quartus Prime Lite 17.0 -- there
// are no *signaltap* / *stp* Tcl commands, only the GUI. In-System Sources and
// Probes IS scriptable (`start_insystem_source_probe`, `read_probe_data`,
// `write_source_data`), which is what a headless workflow needs.
//
// It also suits the questions a bring-up actually asks. Most of them are not
// "what does this waveform look like" but "did this ever happen, and how
// often": did the download reach memory, did the CPU read anything non-zero,
// how many scanlines overran. Those are counters, and counters are cheap.
//
// This is the GENERIC wrapper -- it carries no opinion about what is being
// measured. Build the probe bus in the module that owns the signals and pass
// it in; that keeps the instrumentation next to the thing it instruments, and
// keeps this file stable.
//
// ---------------------------------------------------------------------------
// RULES THAT MAKE A PROBE TRUSTWORTHY (docs/LESSONS_LEARNED.md, "Debug
// instrumentation: how not to fool yourself"). Every one of these was paid
// for on the Psikyo core:
//
//   * NEVER reset a debug counter with the reset you are investigating. Two
//     measurements there read 0x000000 and were reported as findings before
//     anyone noticed the counters were cleared by a reset asserted for the
//     whole measured window. Use rtl/debug/debug_counter.sv, which has no
//     reset at all -- Quartus powers registers to zero, so what it shows is
//     what genuinely happened since configuration.
//   * PAIR every "bad event" counter with a "total events" counter. A zero
//     can mean "did not happen" or "was never allowed to count", and counting
//     only failures cannot tell those apart.
//   * SAMPLE REGISTERED SIGNALS, not combinational ones, and prove the probe
//     on a known-good configuration first. A probe that reports a fault on a
//     setup known to work IS the fault.
//   * CAPTURE THE FULL ADDRESS. Packing only the low bits made a genuine
//     linear sweep look exactly like a read path dropping its high address
//     bits.
// ---------------------------------------------------------------------------
//
// The instance_id is a four-character tag the host script selects on, so
// several probes can coexist. Keep a register of them in one place:
//
//   "F"   general core state
//
// Host side: scripts/read_issp.tcl.

module issp_probe #(
	parameter [7:0] INSTANCE_ID = "F",
	parameter int   PROBE_W     = 128,
	parameter int   SOURCE_W    = 8
) (
	input  logic                 clk,

	// Everything to be read back over JTAG, concatenated by the caller.
	// Document the layout where it is built, and keep the host script's
	// decode in step with it -- a silently shifted field reads as plausible
	// nonsense rather than as an error.
	input  logic [PROBE_W-1:0]   probe,

	// Written from the host. Bit 0 is conventionally "clear the counters";
	// the rest are free. Synchronous to clk and safe to use as enables.
	output logic [SOURCE_W-1:0]  source
);

	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id(INSTANCE_ID),
		.probe_width(PROBE_W),
		.source_width(SOURCE_W),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp (
		.probe(probe),
		.source(source),
		.source_clk(clk),
		.source_ena(1'b1)
	);

endmodule
