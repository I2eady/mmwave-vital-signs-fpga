#=============================================================================
# export_bd_diagram.tcl -- export the Block Design diagram to PDF / SVG
#   output : docs/bd_dataflow.pdf  and  docs/bd_dataflow.svg
#   usage  : source <this file>   (GUI or batch)
# ASCII-only on purpose.
#=============================================================================

set root [file normalize [file join [file dirname [file dirname [file dirname [info script]]]]]]

if {[llength [current_project -quiet]] == 0} {
    open_project "$root/build/vivado/vs_fpga.xpr"
}

set bds [get_files -quiet *.bd]
if {[llength $bds] == 0} {
    puts "no Block Design in this project"
    return
}
open_bd_design [lindex $bds 0]

# optional: arrange the blocks roughly along the data flow direction
proc place {cell col row} {
    if {[llength [get_bd_cells -quiet $cell]] == 0} { return }
    set x [expr {120 + $col * 320}]
    set y [expr { 60 + $row * 220}]
    catch { move_bd_cells -to [list $x $y] [get_bd_cells $cell] }
}

place processing_system7_0  0 2
place axi_dma_0             1 1
place radar_frame_if_0      2 1
place dacm_phase_0          3 1
place hampel7_0             4 1
place integrate_detrend_0   5 1
place fir_resp_0            6 0
place fir_card_0            6 2
place goertzel_resp_0       7 0
place null_model_cancel_0   7 2
place goertzel_vr_0         8 2
place spectrum_accum_0      9 1
place peak_argmax_0        10 1
place certificate_0        11 1
place vs_engine_0          10 3
place bin_selector_0        8 3
place robot_motion_if_0     7 3
place result_out_0         12 1

catch { save_bd_design }

set out_pdf "$root/report/figures/bd_dataflow.pdf"
set out_svg "$root/report/figures/bd_dataflow.svg"

if {[catch { write_bd_layout -format pdf -force -file $out_pdf } e]} {
    puts "PDF export failed: $e"
    if {[catch { write_bd_layout -format svg -force -file $out_svg } e2]} {
        puts "SVG export also failed: $e2"
        puts "hint: in the GUI use File -> Export -> Export Block Design"
    } else {
        puts "exported $out_svg"
    }
} else {
    puts "exported $out_pdf"
    catch { write_bd_layout -format svg -force -file $out_svg }
}

puts "===== diagram export finished ====="
