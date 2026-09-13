# Read X1-001 sprite RAM out of a Seta_stp build through ISSP instance H.
#
#   quartus_stp -t scripts/dump_sprram.tcl <out.txt> <first> <count> [<first> <count> ...]
#
# Run through scripts/dump_sprram.py, which holds the hwlock and writes the
# capture files. Source {1, 2'b0, idx} pauses the CPU and addresses the chip's
# read ports; the probe is {ctrl byte, ylow byte, code word}. The source is
# left at 0 afterwards, which releases the pause.

set out [lindex $argv 0]
set ranges [lrange $argv 1 end]

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSE*" $d] || $dev eq ""} { set dev $d }
}
if {$dev eq ""} { puts "NO DEVICE FOUND"; exit 1 }

set idx -1
foreach i [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {
    if {[lindex $i 3] eq "H"} { set idx [lindex $i 0] }
}
if {$idx < 0} { puts "NO INSTANCE H -- not a build with the sprite RAM readback"; exit 1 }

start_insystem_source_probe -device_name $dev -hardware_name $hw
set f [open $out w]
foreach {first count} $ranges {
    for {set a $first} {$a < $first + $count} {incr a} {
        write_source_data -instance_index $idx -value [format %X [expr {0x8000 | $a}]] -value_in_hex
        write_source_data -instance_index $idx -value [format %X [expr {0x8000 | $a}]] -value_in_hex
        puts $f "$a [read_probe_data -instance_index $idx -value_in_hex]"
    }
}
close $f
write_source_data -instance_index $idx -value 0 -value_in_hex
end_insystem_source_probe
puts "wrote $out"
