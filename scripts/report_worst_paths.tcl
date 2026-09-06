# Dump the worst setup-timing paths for the clk_sys domain from the
# already-compiled Seta database, without a recompile. Run with:
#   quartus_sta -t scripts/report_worst_paths.tcl Seta
# The revision is taken from the trailing argument so this works against a
# release database too; it defaults to the project revision.
set rev "Seta"
if {[llength $quartus(args)] > 0} { set rev [lindex $quartus(args) 0] }
project_open $rev
create_timing_netlist
read_sdc
update_timing_netlist

set clk "emu|pll|pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"

report_timing -setup -npaths 15 -detail full_path -from_clock $clk -to_clock $clk \
    -panel_name "Worst 15 setup paths (clk_sys)" -file "output_files/worst_paths_$rev.rpt"

delete_timing_netlist
# -dont_export_assignments: project_close otherwise RE-SAVES Seta.qsf,
# reordering it and reverting hand edits -- which is how MISTER_FB=1 was
# silently lost between a build and the next.
project_close -dont_export_assignments
