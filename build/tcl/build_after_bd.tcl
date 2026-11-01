#=============================================================================
# build_after_bd.tcl -- everything after the Block Design exists
#-----------------------------------------------------------------------------
#   1) generate the HDL wrapper and set it as top
#   2) run synthesis       (synth_1)
#   3) run implementation  (impl_1)
#   4) write bitstream
#   5) export the hardware platform .xsa for Vitis / SDK
#
# Usage:  source <this file>
# Stop point can be truncated with the environment variable VS_STOP_AFTER
#   bd | synth | impl | bit   (bit = default, run everything)
#
# ASCII-only on purpose (Vivado's Tcl uses the system code page on Windows).
#=============================================================================

set root [file normalize [file join [file dirname [file dirname [file dirname [info script]]]]]]
set xpr  "$root/build/vivado/vs_fpga.xpr"

set RUN_IMPL 1
set RUN_BIT  1
set RUN_XSA  1

# allow build_everything.tcl / build_vivado.bat to truncate the flow
if {[info exists ::env(VS_STOP_AFTER)]} {
    switch -- $::env(VS_STOP_AFTER) {
        bd    { set RUN_IMPL 0; set RUN_BIT 0; set RUN_XSA 0 }
        synth { set RUN_IMPL 0; set RUN_BIT 0; set RUN_XSA 0 }
        impl  { set RUN_BIT 0 }
        default { }
    }
}

if {[llength [current_project -quiet]] == 0} {
    open_project $xpr
}

#-----------------------------------------------------------------------------
# 1) HDL wrapper
#-----------------------------------------------------------------------------
set bds [get_files -quiet *.bd]
if {[llength $bds] == 0} {
    puts "ERROR: no Block Design in this project. Run tcl/build_bd.tcl first."
    return
}
set bd      [lindex $bds 0]
set bdname  [file rootname [file tail $bd]]
set wname   ${bdname}_wrapper
set wpath   "$root/build/vivado/vs_fpga.srcs/sources_1/bd/$bdname/hdl/${wname}.v"

puts "===== HDL wrapper ($wname) ====="
if {[llength [get_files -quiet ${wname}.v]] > 0} {
    puts "  wrapper is already a project source"
} elseif {[file exists $wpath]} {
    # generate_target already wrote it - just import that file, do not
    # regenerate (make_wrapper would complain the file already exists)
    add_files -norecurse $wpath
    puts "  imported existing wrapper: $wpath"
} else {
    if {[catch { make_wrapper -files $bd -top -import } e]} {
        puts "ERROR: make_wrapper failed: $e"
        return
    }
    puts "  wrapper generated"
}

set_property top $wname [current_fileset]
update_compile_order -fileset sources_1
puts "  top set to $wname"

#-----------------------------------------------------------------------------
# 2) synthesis
#-----------------------------------------------------------------------------
puts "\n===== synthesis ====="
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set st [get_property STATUS [get_runs synth_1]]
puts "  synth status: $st"
if {[string match "*ERROR*" $st]} {
    puts "  SYNTHESIS FAILED - see $root/build/vivado/vs_fpga.runs/synth_1/runme.log"
    return
}

set rpt "$root/build/vivado/vs_fpga.runs/synth_1/vs_bd_wrapper_utilization_synth.rpt"
if {[file exists $rpt]} { puts "  utilization report: $rpt" }

if {!$RUN_IMPL} {
    puts "\n===== stopped after synthesis ====="
    return
}

#-----------------------------------------------------------------------------
# 3) implementation + bitstream
#-----------------------------------------------------------------------------
puts "\n===== implementation ====="
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set st [get_property STATUS [get_runs impl_1]]
puts "  impl status: $st"

if {$RUN_BIT} {
    set bit "$root/build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper.bit"
    if {[file exists $bit]} {
        puts "  bitstream: $bit"
    } else {
        puts "  bitstream NOT found - check impl_1/runme.log"
    }
    set tsum "$root/build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper_timing_summary_routed.rpt"
    if {[file exists $tsum]} {
        puts "  timing   : $tsum   (check WNS >= 0)"
    }
}

#-----------------------------------------------------------------------------
# 4) export hardware platform
#-----------------------------------------------------------------------------
if {$RUN_XSA && $RUN_IMPL} {
    catch { open_run impl_1 }
    set xsa "$root/build/vivado/vs_design.xsa"
    puts "\n===== exporting hardware platform ====="
    if {[catch {
        write_hw_platform -fixed -include_bit -force -file $xsa
    } e]} {
        puts "  with-bitstream export failed ($e), retrying without it"
        catch { write_hw_platform -fixed -force -file $xsa }
    }
    if {[file exists $xsa]} { puts "  exported: $xsa" }
}

#-----------------------------------------------------------------------------
# 5) collect the reports / artifacts into build/reports and board/artifacts
#    (the raw run directories are throw-away; these copies are the deliverable)
#-----------------------------------------------------------------------------
puts "\n===== collecting reports ====="
set repdir "$root/build/reports"
file mkdir $repdir
set pairs [list \
    "$root/build/vivado/vs_fpga.runs/synth_1/vs_bd_wrapper_utilization_synth.rpt"   "synthesis_utilization.rpt" \
    "$root/build/vivado/vs_fpga.runs/synth_1/vs_bd_wrapper_utilization_synth_hier.rpt" "synthesis_utilization_hier.rpt" \
    "$root/build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper_utilization_placed.rpt"   "implementation_utilization.rpt" \
    "$root/build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper_timing_summary_routed.rpt" "implementation_timing.rpt" \
    "$root/build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper_clock_utilization_routed.rpt" "implementation_clock.rpt" 
]
foreach {src dst} $pairs {
    if {[file exists $src]} {
        file copy -force $src [file join $repdir $dst]
        puts "  report : $repdir/$dst"
    }
}

set boarddir "$root/board/artifacts"
file mkdir $boarddir
foreach a [list "$root/build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper.bit" \
                "$root/build/vivado/vs_design.xsa"] {
    if {[file exists $a]} {
        file copy -force $a [file join $boarddir [file tail $a]]
        puts "  artifact : $boarddir/[file tail $a]"
    }
}

puts "\n=========================================================="
puts "  flow finished"
puts "  next: import $root/board/artifacts/vs_design.xsa into Vitis / SDK"
puts "=========================================================="
