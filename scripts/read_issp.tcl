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
# THE REAL LAYOUT, built in Seta.sv's issp_probe instance. Keep the two in
# step: the bus is defined where it is BUILT, not here.
#
# A silently shifted field decodes as plausible nonsense rather than as an
# error, which is worse than a crash. On Fuuki a field kept the label
# `board_fg3` after the layout moved and decoded an FG-2 game as an FG-3 board
# -- exactly that failure.
set fields_F {
    {lines            0  15 dec}
    {sprites         16  31 dec}
    {line_overrun    32  47 dec}
    {lines_cut       48  63 dec}
    {worst_sprites   64  79 dec}
    {snd_samples     80  95 dec}
    {snd_rom_reads   96 111 dec}
    {snd_overrun    112 119 dec}
    {irq_pending    120 126 hex}
    {pll_locked     127 127 bit}
}

# INSTANCE E -- CPU writes per video region, built in Seta.sv's u_issp_io.
#
# What it answers: a black screen with every counter at zero means the CPU
# never reached the video hardware at all, so the fault is in the CPU, the
# address decode or the ROM -- not in the video path. Palette and VRAM
# counting up while the screen stays black means the opposite.
#
# Counters SATURATE at 65535 rather than wrapping, so a large value means
# "at least this many", never "a small number after a wrap".
# INSTANCE B -- one granule layer 0 received, built in Seta.sv's
# u_issp_gran. The byte offset into gfx2 is l0_gran_addr * 8; compare
# l0_gran_data with the ROM image there.
# INSTANCE A -- the last twenty BRANCHES before an exception, built in
# Seta.sv's u_issp_pc. Only a fetch that is not the previous one plus a word
# is recorded, so each entry is a jump, branch, return or exception target
# rather than one word of a routine -- twenty sequential fetches said nothing
# about how the CPU got there. pc0 is the newest. frozen says the ring stopped
# with the CPU executing the vector table; until then it is a live window.
set fields_A {
    {pc0               0  23 hex}
    {pc1              24  47 hex}
    {pc2              48  71 hex}
    {pc3              72  95 hex}
    {pc4              96 119 hex}
    {pc5             120 143 hex}
    {pc6             144 167 hex}
    {pc7             168 191 hex}
    {pc8             192 215 hex}
    {pc9             216 239 hex}
    {pc10            240 263 hex}
    {pc11            264 287 hex}
    {pc12            288 311 hex}
    {pc13            312 335 hex}
    {pc14            336 359 hex}
    {pc15            360 383 hex}
    {pc16            384 407 hex}
    {pc17            408 431 hex}
    {pc18            432 455 hex}
    {pc19            456 479 hex}
    {frozen           480 480 bit}
}

set fields_B {
    {l0_gran_data      0  63 hex}
    {l0_gran_addr     64  84 hex}
    {last_vector      85 108 hex}
}

# INSTANCE C -- the two tilemap engines, built in Seta.sv's u_issp_tile.
#
# overrun near lines means the layer did not finish its line: it is being
# starved on the SDRAM port it shares with the sprite engine, and most of
# its tiles never arrive.
set fields_C {
    {l0_lines          0  15 dec}
    {l0_tiles         16  31 dec}
    {l0_overrun       32  47 dec}
    {l1_lines         48  63 dec}
    {l1_tiles         64  79 dec}
    {l1_overrun       80  95 dec}
}

# INSTANCE D -- where the CPU is, built in Seta.sv's u_issp_cpu.
#
# last_rom parked in a narrow range means a spin loop; rom_fetches at zero
# means the CPU never started. dl_max4k is the download's high-water mark
# in 4096-byte units -- multiply by 0x1000 for the byte address, and
# compare against the .mra's size before reading anything into the rest.
set fields_D {
    {last_rom         0  23 hex}
    {rom_fetches     24  39 dec}
    {wram_writes     40  55 dec}
    {io_reads        56  71 dec}
    {dl_max4k        72  85 hex}
    {last_io         86 109 hex}
}

set fields_E {
    {w_palette        0  15 dec}
    {w_l0_vram       16  31 dec}
    {w_l1_vram       32  47 dec}
    {w_l0_ctrl       48  63 dec}
    {w_l1_ctrl       64  79 dec}
    {w_vregs         80  95 dec}
    {w_sprite_code   96 111 dec}
    {w_x1snd        112 127 dec}
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
set inst_id [lindex [lindex $insts 0] 3]
if {$want ne ""} {
    foreach i $insts {
        if {[lindex $i 3] eq $want} { set idx [lindex $i 0]; set inst_id $want }
    }
}

# The field table belongs to the INSTANCE, not to the script. Decoding one
# probe with the other's table is exactly the silent-nonsense failure the
# comment above warns about, so an unrecognised id stops rather than guesses.
switch -- $inst_id {
    F       { set fields $fields_F }
    D       { set fields $fields_D }
    C       { set fields $fields_C }
    B       { set fields $fields_B }
    A       { set fields $fields_A }
    E       { set fields $fields_E }
    default {
        puts "instance id '$inst_id' has no field table -- add one before reading it"
        exit 1
    }
}
puts "decoding instance $inst_id"

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
