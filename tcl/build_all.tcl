#=============================================================================
# build_all.tcl -- Create the Vivado project, add sources, build the BD
#-----------------------------------------------------------------------------
# ASCII-only on purpose: Vivado's Tcl on Windows uses the system code page,
# so non-ASCII characters inside a .tcl would be mangled.
#
# Usage (both work):
#   A) GUI :  Tools -> Run Tcl Script...   or in the Tcl Console:
#               source D:/A_university_project/FPGAmmwave/fpga/tcl/build_all.tcl
#   B) cmd :  vivado -mode batch -source tcl/build_all.tcl
#             set VS_RUN_SYNTH=1 first to also run synth/impl/bitstream
#
# The script locates the project root from its own location, so the current
# working directory does not matter.
#=============================================================================

set root [file normalize [file dirname [file dirname [info script]]]]
set part "xc7z020clg400-2"
set prjdir "$root/prj"
set xpr    "$prjdir/vs_fpga.xpr"

# close any project that may already be open
catch { close_project }

puts "=========================================================="
puts "  project root : $root"
puts "  part         : $part"
puts "=========================================================="

#-----------------------------------------------------------------------------
# 1) create or open the project
#-----------------------------------------------------------------------------
if {[file exists $xpr]} {
    puts "===== project exists, opening ====="
    open_project $xpr
} else {
    puts "===== creating project ====="
    file mkdir $prjdir
    create_project vs_fpga $prjdir -part $part -force
    set_property target_language Verilog  [current_project]
    set_property simulator_language Mixed [current_project]
}

#-----------------------------------------------------------------------------
# 2) RTL sources
#-----------------------------------------------------------------------------
set rtl_files [list]
foreach d {common frontend spatial filter spectral cert output top} {
    foreach f [lsort [glob -nocomplain "$root/rtl/$d/*.v"]] { lappend rtl_files $f }
}

set added 0
foreach f $rtl_files {
    if {[llength [get_files -quiet [file tail $f]]] == 0} {
        add_files -norecurse $f
        incr added
    }
}
puts "RTL files added: $added / [llength $rtl_files]"

#-----------------------------------------------------------------------------
# 3) ROM init files (must be typed as Memory Initialization Files)
#-----------------------------------------------------------------------------
set mem_files [list]
foreach pat {common/sin_lut.mem spectral/sin_lut.mem filter/fir_coeff.mem \
             filter/coeff_rom.mem spectral/dft_delta.mem} {
    if {[file exists "$root/rtl/$pat"]} { lappend mem_files "$root/rtl/$pat" }
}
foreach f $mem_files {
    if {[llength [get_files -quiet [file tail $f]]] == 0} {
        add_files -norecurse $f
    }
    set_property file_type {Memory Initialization Files} [get_files [file tail $f]]
}
puts "ROM init files added: [llength $mem_files]"

#-----------------------------------------------------------------------------
# 4) simulation sources
#-----------------------------------------------------------------------------
foreach f [lsort [glob -nocomplain "$root/tb/*.v"]] {
    if {[llength [get_files -quiet [file tail $f]]] == 0} {
        add_files -fileset sim_1 -norecurse $f
    }
}

update_compile_order -fileset sources_1

#-----------------------------------------------------------------------------
# 4b) search paths
#-----------------------------------------------------------------------------
# No module uses `include any more (the BD HDL parser cannot resolve includes),
# but the five ROM init files loaded by $readmemh live in three different RTL
# sub-directories, so all of them are added to the search path.
set_property include_dirs [list \
    "$root/rtl/common"   "$root/rtl/frontend" "$root/rtl/spatial" \
    "$root/rtl/filter"   "$root/rtl/spectral" "$root/rtl/cert" \
    "$root/rtl/output"   "$root/rtl/top"] [current_fileset]
puts "include_dirs set"

#-----------------------------------------------------------------------------
# 5) build the Block Design
#-----------------------------------------------------------------------------
source "$root/tcl/build_bd.tcl"

#-----------------------------------------------------------------------------
# 6) optional: continue with wrapper / synth / impl / bitstream / xsa
#-----------------------------------------------------------------------------
if {[info exists ::env(VS_RUN_SYNTH)] && $::env(VS_RUN_SYNTH) == "1"} {
    source "$root/tcl/build_after_bd.tcl"
}

puts "=========================================================="
puts "  done. project file : $xpr"
puts "  next : open it, double-click vs_bd.bd to see the data flow"
puts "=========================================================="

# The project is intentionally left open:
#   - in GUI mode you want to inspect the Block Design right away
#   - in batch mode Vivado exits by itself when the script ends
