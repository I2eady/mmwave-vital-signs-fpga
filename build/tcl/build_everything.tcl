#=============================================================================
# build_everything.tcl -- ONE command runs the whole flow
#-----------------------------------------------------------------------------
#  project + sources + Block Design + wiring + validate
#    -> HDL wrapper -> synthesis -> implementation -> bitstream -> .xsa
#
# Usage (any of these):
#   1) cmd / double-click:
#        build_vivado.bat
#   2) cmd directly:
#        D:\vivado2019\Vivado\2019.1\bin\vivado.bat -mode batch ^
#            -source D:\A_university_project\FPGAmmwave\fpga\build\tcl\build_everything.tcl
#   3) GUI Tcl Console:
#        source D:/A_university_project/FPGAmmwave/fpga/build/tcl/build_everything.tcl
#
# Stop earlier by changing STOP_AFTER:
#   bd    -> only build the Block Design
#   synth -> stop after synthesis
#   impl  -> stop after implementation
#   bit   -> everything (default)
# It can also be overridden by the environment variable VS_STOP_AFTER.
#
# ASCII-only on purpose (Vivado's Tcl uses the system code page on Windows).
#=============================================================================

set root [file normalize [file join [file dirname [file dirname [file dirname [info script]]]]]]
set STOP_AFTER bit

if {[info exists ::env(VS_STOP_AFTER)]} {
    set STOP_AFTER $::env(VS_STOP_AFTER)
}

set t_all [clock seconds]

proc stage {n name} {
    puts ""
    puts "##########################################################"
    puts "#  STAGE $n : $name"
    puts "##########################################################"
}
proc elapsed {t0} {
    set d [expr {[clock seconds] - $t0}]
    return "[expr {$d/60}] min [expr {$d%60}] sec"
}

#=============================================================================
# STAGE 1 : project + sources + Block Design
#=============================================================================
stage 1 "project / sources / Block Design"
set t1 [clock seconds]

if {[catch { source "$root/build/tcl/build_all.tcl" } e]} {
    puts ""
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    puts "  STAGE 1 FAILED"
    puts "  reason : $e"
    puts "  Read the lines above starting with '!!' to find the cell"
    puts "  that could not be created."
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    return
}
puts "  >> stage 1 done, [elapsed $t1]"

if {$STOP_AFTER eq "bd"} {
    puts "\nStopped after Block Design as requested."
    return
}

#=============================================================================
# STAGE 2 : wrapper / synth / impl / bitstream / xsa
#=============================================================================
stage 2 "wrapper / synthesis / implementation / bitstream / xsa"
set t2 [clock seconds]

# pass the stop point down to build_after_bd.tcl
set ::env(VS_STOP_AFTER) $STOP_AFTER

if {[catch { source "$root/build/tcl/build_after_bd.tcl" } e]} {
    puts ""
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    puts "  STAGE 2 FAILED"
    puts "  reason : $e"
    puts "  logs   : $root/build/vivado/vs_fpga.runs/synth_1/runme.log"
    puts "           $root/build/vivado/vs_fpga.runs/impl_1/runme.log"
    puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    return
}
puts "  >> stage 2 done, [elapsed $t2]"

#=============================================================================
# summary
#=============================================================================
set bit "$root/build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper.bit"
set xsa "$root/build/vivado/vs_design.xsa"

puts ""
puts "=========================================================="
puts "  ALL DONE, total [elapsed $t_all]"
puts "=========================================================="
puts "  project      : $root/build/vivado/vs_fpga.xpr"
puts "  block design : [expr {[llength [get_files -quiet *.bd]] ? {built} : {MISSING}}]"
if {[file exists $bit]} {
    puts "  bitstream    : $bit  ([file size $bit] bytes)"
} else {
    puts "  bitstream    : NOT generated (check impl_1/runme.log)"
}
if {[file exists $xsa]} {
    puts "  hw platform  : $xsa  ([format %.1f [expr {[file size $xsa]/1048576.0}]] MB)"
} else {
    puts "  hw platform  : NOT generated"
}
puts ""
puts "  next steps"
puts "    1. open $root/build/vivado/vs_fpga.xpr"
puts "    2. double-click vs_bd.bd in Sources to view the data flow"
puts "    3. import vs_design.xsa into Vitis to write the PS program"
puts "=========================================================="
