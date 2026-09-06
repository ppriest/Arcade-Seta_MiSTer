# Read the core's debug probes over JTAG (In-System Sources and Probes).
#
#   quartus_stp -t scripts/read_issp.tcl              # read
#   quartus_stp -t scripts/read_issp.tcl clear        # read, then zero counters
#
# SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0 -- there are no
# *signaltap* Tcl commands -- so ISSP is what a headless workflow can drive.
# See rtl/debug/issp_probe.sv for why counters answer a bring-up question
# better than a waveform does.
#
# The probe bus layout is defined where the bus is BUILT, not here. Keep the
# `fields` table below in step with it: a silently shifted field decodes as
# plausible nonsense rather than as an error, which is worse than a crash.

# --- field table: {name lo hi format} -------------------------------------
#
# *** PROVISIONAL -- no Seta probe bus exists yet. ***
# This is the layout docs/ROADMAP.md's "Instrumentation this core needs" calls
# for, written down so the RTL has a target. REPLACE IT with the real layout
# the first time a probe bus is built, and keep the two in step from then on.
#
# The rule this file exists to enforce: the probe bus layout is defined where
# the bus is BUILT, not here. A silently shifted field decodes as plausible
# nonsense rather than as an error, which is worse than a crash. On Fuuki a
# field kept the label `board_fg3` after the layout moved and decoded an FG-2
# game as an FG-3 board -- exactly that failure.
set fields {
    {frames           0  15 dec}
    {core_resets     16  23 dec}
    {cpu_cycles      24  39 dec}
    {spr_seen        40  55 dec}
    {spr_drawn       56  71 dec}
    {lb_overrun      72  79 dec}
    {sdram_stall     80  95 dec}
    {sdram_worst     96 103 dec}
    {x1snd_fetch    104 111 dec}
    {max_dl_addr4k  112 123 dec}
    {download_seen  124 124 bit}
    {pause_latched  125 125 bit}
    {ring_frozen    126 126 bit}
    {pll_unlock     127 127 bit}
}

# WHAT EACH ONE ANSWERS
#
# lb_overrun is THE number for this core's architecture. docs/ROADMAP.md
# chooses a line-based sprite renderer with double line buffers over a frame
# buffer, on a per-scanline budget of roughly 4,300 clk against 6,144
# available at 96 MHz. This counts scanlines where the sprite engine did not
# finish in time. If it is ever non-zero in real gameplay, that decision is
# wrong and the frame buffer is back on the table -- which is why it exists
# from the first sprite build rather than later.
#
# spr_seen paired with spr_drawn is the "bad event / total events" pair: a
# spr_drawn of zero means "nothing was drawn" only if spr_seen shows records
# were examined at all.
#
# sdram_stall / sdram_worst say whether a fetch deadline is being missed
# because of contention. Psikyo chased ADPCM noise as SDRAM starvation for a
# long time and measured a worst wait of 149 clk against a 54 us sample
# period -- orders of magnitude away from the fault. Measure before theorising.
#
# max_dl_addr4k is the HIGHEST download address written, in 4096-byte units:
# multiply by 0x1000 for the byte address. Unlike a trace buffer it has no
# idle timeout, so a pause mid-download cannot make it look like the end.
# A complete gundhara load (15.5 MB) must reach 0xF80000 -> 0xF80 here.
#
# x1snd_fetch counts X1-010 sample-ROM reads. Zero while a game plays is a
# silent chip; a rate is what matters, not a total.
#
# NOTE the counters SATURATE and several count per-cycle events, so they pin
# almost immediately. Always `clear` first and read again to get a rate; a
# pinned maximum means "lots", nothing more.

proc bits_to_int {s lo hi} {
    # read_probe_data returns the bus MSB-first, so index from the right.
    set n [string length $s]
    set v 0
    for {set i $hi} {$i >= $lo} {incr i -1} {
        set c [string index $s [expr {$n - 1 - $i}]]
        set v [expr {$v * 2 + ($c eq "1" ? 1 : 0)}]
    }
    return $v
}

set do_clear [expr {[lsearch -exact $argv "clear"] >= 0}]
# `set N`   : write source byte N (decimal) and leave it
# `pulse N` : write N, then 0 -- for the edge-triggered controls
set set_val -1; set pulse_val -1
set i [lsearch -exact $argv "set"];   if {$i >= 0} { set set_val   [lindex $argv [expr {$i+1}]] }
set i [lsearch -exact $argv "pulse"]; if {$i >= 0} { set pulse_val [lindex $argv [expr {$i+1}]] }

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
puts "hardware: $hw"

set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSEBA6*" $d] || [string match "*5CSE*" $d] || $dev eq ""} {
        set dev $d
    }
}
if {$dev eq ""} { puts "NO DEVICE FOUND"; exit 1 }
puts "device:   $dev"

# Query instance info BEFORE opening a session: with a session already active
# this fails with "There is already an active In-System Sources and Probes
# session started."
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
if {[llength $insts] == 0} {
    puts "NO ISSP INSTANCES -- is this an instrumented build?"
    exit 1
}
foreach i $insts { puts "instance: $i" }

# Take the first instance unless one is named on the command line.
set want ""
foreach a $argv { if {$a ne "clear"} { set want $a } }
set idx [lindex [lindex $insts 0] 0]
if {$want ne ""} {
    foreach i $insts {
        if {[lindex $i 3] eq $want} { set idx [lindex $i 0] }
    }
}

start_insystem_source_probe -device_name $dev -hardware_name $hw
set raw [read_probe_data -instance_index $idx]
puts "raw ([string length $raw] bits): $raw"
puts ""

foreach f $fields {
    lassign $f name lo hi fmt
    set v [bits_to_int $raw $lo $hi]
    switch $fmt {
        sdec { if {$v >= 32768} { set v [expr {$v - 65536}] }; puts [format "  %-16s %d" $name $v] }
        hex  { puts [format "  %-16s 0x%08X" $name $v] }
        bit  { puts [format "  %-16s %s"     $name [expr {$v ? "yes" : "no"}]] }
        default { puts [format "  %-16s %d"  $name $v] }
    }
}

# write_source_data takes a BINARY STRING unless -value_in_hex is given; a
# decimal "8" is silently rejected (the source read back 00 while the script
# printed "source set to 8"). Every write goes through this, in hex.
proc write_src {idx v} { write_source_data -instance_index $idx -value [format %X $v] -value_in_hex }
if {$set_val >= 0}   { write_src $idx $set_val;   puts "source set to $set_val (reads back 0x[read_source_data -instance_index $idx -value_in_hex])" }
if {$pulse_val >= 0} { write_src $idx $pulse_val; write_src $idx 0; puts "source pulsed $pulse_val" }

if {$do_clear} {
    # Source bit 0 is the counter clear, by convention. Pulse it: the counters
    # are deliberately NOT reset by the core's own reset (see
    # rtl/debug/debug_counter.sv), so this is the only thing that zeroes them.
    write_src $idx 1
    write_src $idx 0
    puts "\ncounters cleared"
}

end_insystem_source_probe
