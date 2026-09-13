// In-System Sources and Probes wrapper: read `probe` over JTAG and drive
// `source` back (scripts/read_issp.tcl). Scriptable in Quartus Lite, unlike
// SignalTap. Instance IDs and probe layouts are documented where each is built
// (Seta.sv).

module issp_probe #(
	parameter [7:0] INSTANCE_ID = "F",
	parameter int   PROBE_W     = 128,
	parameter int   SOURCE_W    = 8
) (
	input  logic                 clk,

	// concatenated by the caller
	input  logic [PROBE_W-1:0]   probe,

	// from the host, synchronous to clk
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
