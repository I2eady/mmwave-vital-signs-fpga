#=============================================================================
# run_sim.tcl -- run the RTL unit simulations
#   tests: tb_dacm_phase / tb_hampel7 / tb_fir_bandpass / tb_goertzel_sweep
#   usage: source <this file>
# ASCII-only on purpose.
#=============================================================================

set root [file normalize [file join [file dirname [file dirname [file dirname [info script]]]]]]

if {[llength [current_project -quiet]] == 0} {
    open_project "$root/build/vivado/vs_fpga.xpr"
}

set tests [list tb_dacm_phase tb_hampel7 tb_fir_bandpass tb_goertzel_sweep]

foreach t $tests {
    set f [glob -nocomplain "$root/sim/tb/$t.v"]
    if {$f eq ""} {
        puts "skip $t (file not found)"
        continue
    }

    puts "=========== running $t ==========="
    if {[llength [get_files -quiet $t.v]] == 0} {
        add_files -fileset sim_1 -norecurse $f
    }
    set_property top $t [get_filesets sim_1]
    update_compile_order -fileset sim_1

    if {[catch {
        launch_simulation -mode behavioral
        run all
        close_sim
    } e]} {
        puts "  $t simulation error: $e"
    }
}

puts "===== simulation finished ====="
