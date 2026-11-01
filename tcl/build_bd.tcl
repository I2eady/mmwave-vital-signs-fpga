#=============================================================================
# build_bd.tcl -- Build the ZYNQ7020 mmWave heart-rate Block Design
#-----------------------------------------------------------------------------
# NOTE: This file is intentionally ASCII-only.
#       Vivado's Tcl on Windows reads .tcl files using the system code page
#       (GBK on Chinese Windows), so non-ASCII text would be mangled.
#
# Data flow implemented here:
#
#   PS(DMA) -> radar_frame_if -> dacm_phase -> hampel7 -> integrate_detrend
#                                                              |  window RAM
#                        +-------------------------------------+
#                        v                                     v
#                 fir_resp (0.15-0.60Hz)               fir_card (0.80-2.00Hz)
#                        |                                     |
#                        v                                     v
#                 goertzel_resp (91 pts)             null_model_cancel (LMS)
#                        |                                     |
#                        |                                     v
#                        |                            goertzel_vr (201 pts)
#                        +------------+------------------------+
#                                     v
#                              spectrum_accum
#                                     v
#                               peak_argmax  <-- vs_engine (sequencer)
#                                     v
#                              certificate_fsm
#                                     v
#                               result_out --> PS (AXI4-Lite + IRQ)
#=============================================================================

set root [file normalize [file dirname [file dirname [info script]]]]

#-----------------------------------------------------------------------------
# Connection helpers (auto-detect inferred interface vs discrete pins)
#-----------------------------------------------------------------------------
proc vs_link {sc sb dc db} {
    set si [get_bd_intf_pins -quiet ${sc}/${sb}]
    set di [get_bd_intf_pins -quiet ${dc}/${db}]
    if {[llength $si] > 0 && [llength $di] > 0} {
        if {[catch { connect_bd_intf_net $si $di } e]} {
            puts "  !! INTF link failed ${sc}/${sb} -> ${dc}/${db} : $e"
        } else {
            puts "  INTF ${sc}/${sb}  ==>  ${dc}/${db}"
        }
        return
    }
    set n 0
    foreach suf {tdata tvalid tready tlast tuser tkeep tstrb tid tdest} {
        set sp [get_bd_pins -quiet ${sc}/${sb}_${suf}]
        set dp [get_bd_pins -quiet ${dc}/${db}_${suf}]
        if {[llength $sp] > 0 && [llength $dp] > 0} {
            catch { connect_bd_net $sp $dp }
            incr n
        }
    }
    if {$n == 0} {
        puts "  !! NO PORT MATCH ${sc}/${sb} -> ${dc}/${db}"
    } else {
        puts "  PIN  ${sc}/${sb}  ==>  ${dc}/${db}   ($n wires)"
    }
}

proc vs_net {a b} {
    set ap [get_bd_pins -quiet $a]
    set bp [get_bd_pins -quiet $b]
    if {[llength $ap] > 0 && [llength $bp] > 0} {
        if {[catch { connect_bd_net $ap $bp } e]} {
            puts "  !! net failed $a -> $b : $e"
        }
        return
    }
    set ai [get_bd_intf_pins -quiet $a]
    set bi [get_bd_intf_pins -quiet $b]
    if {[llength $ai] > 0 && [llength $bi] > 0} {
        if {[catch { connect_bd_intf_net $ai $bi } e]} {
            puts "  !! intf net failed $a -> $b : $e"
        }
        return
    }
    puts "  ~ skip (port not found): $a -> $b"
}

# Create an IP cell; abort with a readable message on failure
proc mkip {vlnv name} {
    if {[catch { create_bd_cell -type ip -vlnv $vlnv $name } e]} {
        puts "\n  !! FAILED  create_bd_cell -type ip -vlnv $vlnv $name"
        puts "     reason : $e\n"
        error "create_bd_cell ip $vlnv failed"
    }
    puts "  OK  $name   <- $vlnv"
}

# Create an RTL module-reference cell; abort with a readable message on failure
proc mkmod {mod name} {
    if {[catch { create_bd_cell -type module -reference $mod $name } e]} {
        puts "\n  !! FAILED  create_bd_cell -type module -reference $mod $name"
        puts "     reason : $e"
        puts "     hint   : the RTL module must parse cleanly on its own."
        puts "              Vivado's BD HDL parser does NOT honour include_dirs,"
        puts "              so no module may depend on a \`include file."
        puts "              See the Messages tab for [IP_Flow] errors on this file.\n"
        error "create_bd_cell module $mod failed"
    }
    puts "  OK  $name   <- $mod"
}

#-----------------------------------------------------------------------------
# CONFIG property helpers
#-----------------------------------------------------------------------------
# Different Vivado / IP versions expose the same IP setting under different
# CONFIG names (SI_PROTOCOL vs S_AXI_PROTOCOL vs C_S_AXI_PROTOCOL, ...).
# A wrong name does NOT raise a Tcl error - it only produces
#   CRITICAL WARNING: [BD 41-1276] Cannot set the parameter X. Parameter does not exist
# and silently leaves the default in place. That is exactly how the
# "DATA_WIDTH does not match HP0(64) / M_AXI(32)" error slipped through.
# set_any therefore enumerates the real property names and only sets one
# that actually exists, printing which one it used.
proc cfg_names {cell} {
    set cfg [list]
    catch {
        foreach p [list_property [get_bd_cells $cell]] {
            if {[string match "CONFIG.*" $p]} { lappend cfg $p }
        }
    }
    return $cfg
}

proc set_any {cell names value} {
    set obj [get_bd_cells $cell]
    set cfg [cfg_names $cell]
    if {[llength $cfg] > 0} {
        foreach n $names {
            set i [lsearch -glob -nocase $cfg $n]
            if {$i >= 0} {
                set real [lindex $cfg $i]
                if {[catch { set_property $real $value $obj } e]} {
                    puts "  !! $cell : $real = $value failed : $e"
                    return 0
                }
                puts "  OK $cell : $real = $value"
                return 1
            }
        }
        puts "  ~ $cell : none of [join $names { }] exists - $value NOT applied"
        return 0
    }
    # property list not enumerable - try each candidate and verify by read-back
    foreach n $names {
        if {[catch { set_property $n $value $obj } e]} { continue }
        set got ""
        catch { set got [get_property $n $obj] }
        if {[string trim $got] ne ""} {
            puts "  OK $cell : $n = $got"
            return 1
        }
    }
    puts "  !! $cell : could not apply $value (tried [join $names { }])"
    return 0
}

#-----------------------------------------------------------------------------
# Remove a previously generated BD so this script is re-runnable
#-----------------------------------------------------------------------------
set old [get_files -quiet *.bd]
if {[llength $old] > 0} {
    puts "===== removing existing Block Design ====="
    foreach bdf $old {
        catch { close_bd_design -force [get_bd_designs -quiet] }
        catch { remove_files $bdf }
    }
}

create_bd_design "vs_bd"
current_bd_design "vs_bd"
puts "===== Block Design vs_bd created ====="

#=============================================================================
# 1) PS7 and AXI infrastructure
#=============================================================================
puts "\n--- 1) PS7 / reset / AXI infrastructure ---"

mkip xilinx.com:ip:processing_system7:5.5 processing_system7_0
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
] [get_bd_cells processing_system7_0]

# The AXI-DMA MM2S port is 32 bit wide, so the HP0 slave port must be 32 bit
# too.  Left at its 64 bit default this gives
#   ERROR: [BD 41-237] Bus Interface property DATA_WIDTH does not match
#                      between /processing_system7_0/S_AXI_HP0(64) and /axi_pc/M_AXI(32)
set_any processing_system7_0 {CONFIG.PCW_S_AXI_HP0_DATA_WIDTH} 32

mkip xilinx.com:ip:proc_sys_reset:5.0  rst_ps7_100M

mkip xilinx.com:ip:axi_dma:7.1         axi_dma_0
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
] [get_bd_cells axi_dma_0]

mkip xilinx.com:ip:smartconnect:1.0    axi_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] [get_bd_cells axi_smc]

mkip xilinx.com:ip:axi_gpio:2.0        axi_gpio_ctrl
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {32} CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {1} CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_OUTPUTS_2 {1} \
] [get_bd_cells axi_gpio_ctrl]

mkip xilinx.com:ip:axi_protocol_converter:2.1 axi_pc
# The PS7 S_AXI_HP0 slave is AXI3 while the DMA M_AXI_MM2S master is AXI4, so a
# protocol converter is mandatory (a direct connection fails with BD 41-1285).
# Its two protocol + width settings are set through set_any because the CONFIG
# name varies with the IP version.
puts "  axi_pc CONFIG properties: [join [lsort [cfg_names axi_pc]] { }]"
set_any axi_pc {CONFIG.SI_PROTOCOL CONFIG.S_AXI_PROTOCOL CONFIG.C_S_AXI_PROTOCOL} AXI4
set_any axi_pc {CONFIG.MI_PROTOCOL CONFIG.M_AXI_PROTOCOL CONFIG.C_M_AXI_PROTOCOL} AXI3
# The converter has ONE data width shared by both sides; keep it 32 to match
# the 32 bit DMA MM2S path and the 32 bit HP0 set above.
set_any axi_pc {CONFIG.DATA_WIDTH CONFIG.C_DATA_WIDTH} 32

#=============================================================================
# 2) Algorithm RTL modules as module references
#=============================================================================
puts "\n--- 2) RTL algorithm modules ---"

mkmod radar_frame_if     radar_frame_if_0
mkmod dacm_phase         dacm_phase_0
mkmod hampel7            hampel7_0
mkmod integrate_detrend  integrate_detrend_0
mkmod bin_selector       bin_selector_0
mkmod robot_motion_if    robot_motion_if_0
mkmod fir_bandpass       fir_resp_0
mkmod fir_bandpass       fir_card_0
mkmod null_model_cancel  null_model_cancel_0
mkmod goertzel_sweep     goertzel_resp_0
mkmod goertzel_sweep     goertzel_vr_0
mkmod spectrum_accum     spectrum_accum_0
mkmod peak_argmax        peak_argmax_0
mkmod certificate_fsm    certificate_0
mkmod vs_engine_fsm      vs_engine_0
mkmod result_out         result_out_0
mkmod bpm_map        bpm_map_0
mkmod ratio_q15      ratio_q15_0
mkmod vs_defaults    vs_defaults_0


puts "\n===== cells in design ====="
foreach c [get_bd_cells] { puts "  $c" }

#=============================================================================
# 3) Constant cells (band / grid select)
#=============================================================================
puts "\n--- 3) constant cells ---"
mkip xilinx.com:ip:xlconstant:1.1 const_resp
mkip xilinx.com:ip:xlconstant:1.1 const_card
mkip xilinx.com:ip:xlconstant:1.1 const_vrgrid
set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {0}] [get_bd_cells const_resp]
set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {1}] [get_bd_cells const_card]
set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {1}] [get_bd_cells const_vrgrid]

#=============================================================================
# 4) Clock and reset
#=============================================================================
puts "\n--- 4) clock / reset ---"
# RTL module-reference cells expose aclk / aresetn
set rtl_clk {radar_frame_if_0 dacm_phase_0 hampel7_0 integrate_detrend_0
             bin_selector_0 robot_motion_if_0 fir_resp_0 fir_card_0
             null_model_cancel_0 goertzel_resp_0 goertzel_vr_0
             spectrum_accum_0 peak_argmax_0 certificate_0 vs_engine_0
             result_out_0 bpm_map_0 ratio_q15_0 vs_defaults_0}
foreach c $rtl_clk { vs_net processing_system7_0/FCLK_CLK0 $c/aclk }
# Tag each module-reference clock pin with the real frequency.  Without it
# validate_bd_design emits one BD 41-927 warning per pin
# ("CLK_DOMAIN ... may not be synchronized with cell properties").
# The property is only written when it actually exists on the pin, so a wrong
# name can never produce a CRITICAL WARNING.
proc pin_freq {pin hz} {
    set obj [get_bd_intf_pins -quiet $pin]
    if {[llength $obj] == 0} { return 0 }
    set props [list]
    catch { set props [list_property $obj] }
    set up [list]
    foreach p $props { lappend up [string toupper $p] }
    if {[lsearch -exact $up "CONFIG.FREQ_HZ"] < 0} { return 0 }
    if {[catch { set_property CONFIG.FREQ_HZ $hz $obj } e]} { return 0 }
    return 1
}

set n_freq 0
foreach c $rtl_clk { if {[pin_freq $c/aclk 100000000]} { incr n_freq } }
puts "  clock pins tagged with FREQ_HZ : $n_freq / [llength $rtl_clk]"

# Xilinx IP cells use their own pin names - connect each explicitly.
# (Before the fix these were silently skipped with "port not found", which is
#  what left all the AXI clock pins unconnected and failed validation.)
vs_net processing_system7_0/FCLK_CLK0 processing_system7_0/M_AXI_GP0_ACLK
vs_net processing_system7_0/FCLK_CLK0 processing_system7_0/S_AXI_HP0_ACLK
vs_net processing_system7_0/FCLK_CLK0 axi_dma_0/s_axi_lite_aclk
vs_net processing_system7_0/FCLK_CLK0 axi_dma_0/m_axi_mm2s_aclk
vs_net processing_system7_0/FCLK_CLK0 axi_gpio_ctrl/s_axi_aclk
vs_net processing_system7_0/FCLK_CLK0 axi_smc/aclk
vs_net processing_system7_0/FCLK_CLK0 axi_pc/aclk

vs_net processing_system7_0/FCLK_CLK0     rst_ps7_100M/slowest_sync_clk
vs_net processing_system7_0/FCLK_RESET0_N rst_ps7_100M/ext_reset_in

set rtl_rst {radar_frame_if_0 dacm_phase_0 hampel7_0 integrate_detrend_0
             bin_selector_0 robot_motion_if_0 fir_resp_0 fir_card_0
             null_model_cancel_0 goertzel_resp_0 goertzel_vr_0
             spectrum_accum_0 peak_argmax_0 certificate_0 vs_engine_0
             result_out_0 bpm_map_0 ratio_q15_0 vs_defaults_0}
foreach c $rtl_rst { vs_net rst_ps7_100M/peripheral_aresetn $c/aresetn }
vs_net rst_ps7_100M/peripheral_aresetn axi_smc/aresetn
vs_net rst_ps7_100M/peripheral_aresetn axi_dma_0/axi_resetn
vs_net rst_ps7_100M/peripheral_aresetn axi_gpio_ctrl/s_axi_aresetn
vs_net rst_ps7_100M/peripheral_aresetn axi_pc/aresetn

puts "\n--- 5) AXI ---"
vs_net processing_system7_0/M_AXI_GP0  axi_smc/S00_AXI
vs_net axi_smc/M00_AXI                 axi_dma_0/S_AXI_LITE
vs_net axi_smc/M01_AXI                 axi_gpio_ctrl/S_AXI
vs_net axi_smc/M02_AXI                 result_out_0/s_axi
# The PS7 HP slave port is AXI3 while the DMA MM2S master is AXI4, so a
# protocol converter is mandatory here. Connecting them directly fails with
# BD 41-1285 "protocols ... are incompatible".
vs_net axi_dma_0/M_AXI_MM2S            axi_pc/S_AXI
vs_net axi_pc/M_AXI                    processing_system7_0/S_AXI_HP0

puts "\n--- 6) radar datapath ---"
vs_link axi_dma_0            M_AXIS_MM2S radar_frame_if_0    s_axis
vs_link radar_frame_if_0     m_axis      dacm_phase_0        s_axis
vs_link dacm_phase_0         m_axis      hampel7_0           s_axis
vs_link hampel7_0            m_axis      integrate_detrend_0 s_axis

# These three are plain valid/data/ready streams (not AXIS interfaces), so
# each of the three wires has to be connected individually.
#   m_data/m_valid are FIR outputs, m_ready is the FIR input
#   s_data/s_valid are the consumer inputs, s_ready is the consumer output
vs_net fir_resp_0/m_data        goertzel_resp_0/s_data
vs_net fir_resp_0/m_valid       goertzel_resp_0/s_valid
vs_net fir_resp_0/m_ready       goertzel_resp_0/s_ready

vs_net fir_card_0/m_data        null_model_cancel_0/s_data
vs_net fir_card_0/m_valid       null_model_cancel_0/s_valid
vs_net fir_card_0/m_ready       null_model_cancel_0/s_ready

vs_net null_model_cancel_0/m_data   goertzel_vr_0/s_data
vs_net null_model_cancel_0/m_valid  goertzel_vr_0/s_valid
vs_net null_model_cancel_0/m_ready  goertzel_vr_0/s_ready

puts "\n--- 7) window memory ---"
vs_net fir_resp_0/mem_addr         integrate_detrend_0/rd_addr
vs_net fir_card_0/mem_addr         integrate_detrend_0/rd_addr_b
vs_net fir_card_0/busy             integrate_detrend_0/rd_sel
vs_net integrate_detrend_0/rd_data fir_resp_0/mem_data
vs_net integrate_detrend_0/rd_data fir_card_0/mem_data

#=============================================================================
# 8) Constants, engine handshakes, spectrum path
#=============================================================================
puts "\n--- 8) constants / control / spectrum ---"
vs_net const_resp/dout   fir_resp_0/band_sel
vs_net const_card/dout   fir_card_0/band_sel
vs_net const_resp/dout   goertzel_resp_0/grid_sel
vs_net const_vrgrid/dout goertzel_vr_0/grid_sel

vs_net vs_engine_0/bf_start_resp fir_resp_0/start
vs_net vs_engine_0/bf_start_card fir_card_0/start
vs_net vs_engine_0/bf_base_addr  fir_resp_0/base_addr
vs_net vs_engine_0/bf_base_addr  fir_card_0/base_addr
vs_net fir_resp_0/done           vs_engine_0/bf_done_resp
vs_net fir_card_0/done           vs_engine_0/bf_done_card

vs_net vs_engine_0/gz_start_resp goertzel_resp_0/start
vs_net vs_engine_0/gz_start_vr   goertzel_vr_0/start
vs_net vs_engine_0/gz_npts       goertzel_resp_0/npts
vs_net vs_engine_0/gz_npts       goertzel_vr_0/npts
vs_net goertzel_resp_0/done      vs_engine_0/gz_done_resp
vs_net goertzel_vr_0/done        vs_engine_0/gz_done_vr

vs_net goertzel_resp_0/res_we    spectrum_accum_0/acc_we
vs_net goertzel_resp_0/res_addr  spectrum_accum_0/acc_addr
vs_net goertzel_resp_0/res_mag   spectrum_accum_0/acc_mag
vs_net goertzel_vr_0/res_we      spectrum_accum_0/acc_we_b
vs_net goertzel_vr_0/res_addr    spectrum_accum_0/acc_addr_b
vs_net goertzel_vr_0/res_mag     spectrum_accum_0/acc_mag_b
vs_net vs_engine_0/accum_clr     spectrum_accum_0/clr

vs_net vs_engine_0/pk_start      peak_argmax_0/start
vs_net vs_engine_0/pk_npts       peak_argmax_0/npts
vs_net peak_argmax_0/rd_addr     spectrum_accum_0/rd_addr
vs_net spectrum_accum_0/rd_mag   peak_argmax_0/rd_mag
vs_net peak_argmax_0/done        vs_engine_0/pk_done

vs_net vs_engine_0/cert_start     certificate_0/start
vs_net certificate_0/done         vs_engine_0/cert_done
vs_net peak_argmax_0/contrast_q12 certificate_0/vr_contrast_q12
vs_net integrate_detrend_0/win_ready vs_engine_0/win_ready

#-----------------------------------------------------------------------------
# 8b) peak -> bpm / competitive ratio, and control lines that were missing
#-----------------------------------------------------------------------------
vs_net vs_engine_0/pk_sel      bpm_map_0/sel
vs_net vs_engine_0/pk_done     bpm_map_0/load
vs_net peak_argmax_0/k_best    bpm_map_0/k_best
vs_net peak_argmax_0/peak_val  ratio_q15_0/num
vs_net peak_argmax_0/sum_val   ratio_q15_0/den
vs_net vs_engine_0/pk_done     ratio_q15_0/load
vs_net ratio_q15_0/ratio_q15   certificate_0/compet_vr_q15
# vs_engine_fsm already had an nc_clr output - it was simply not wired
vs_net vs_engine_0/nc_clr      null_model_cancel_0/clr
# after each measurement, reopen the window memory for the next one
vs_net vs_engine_0/win_start   integrate_detrend_0/win_start

#=============================================================================
# 9) Spatial select / robot interface
#=============================================================================
puts "\n--- 9) spatial / robot ---"
vs_net axi_gpio_ctrl/gpio_io_o  robot_motion_if_0/reg_vision_range
vs_net axi_gpio_ctrl/gpio2_io_o robot_motion_if_0/reg_robot_vel
vs_net robot_motion_if_0/vision_range_q16 bin_selector_0/vision_range_q16
vs_net bin_selector_0/bin_mask         vs_engine_0/bin_mask
vs_net bin_selector_0/out_of_range     certificate_0/out_of_range
vs_net robot_motion_if_0/motion_reject certificate_0/motion_reject
vs_net vs_engine_0/fr_inc_out          null_model_cancel_0/fr_inc

#=============================================================================
# 9b) Defaults / placeholders + previously missing connections
#     vs_defaults_0 collects every input that has no data source yet, so no BD
#     input is left dangling (BD 41-759) and the "still a placeholder" part of
#     the design shows up as ONE block in the diagram instead of 30 tie-offs.
#=============================================================================
puts "\n--- 9b) defaults / placeholders ---"

# robot_motion_if: window activity comes from the radar frame interface
vs_net radar_frame_if_0/win_active     robot_motion_if_0/win_active
vs_net radar_frame_if_0/win_done       robot_motion_if_0/win_done
vs_net vs_defaults_0/motion_thresh_q16 robot_motion_if_0/reg_motion_thresh
vs_net vs_defaults_0/robot_ctrl        robot_motion_if_0/reg_ctrl

# bin_selector: Ablation A radar self-localisation (disabled -> vision range)
vs_net vs_defaults_0/radar_loc_bin     bin_selector_0/radar_loc_bin
vs_net vs_defaults_0/radar_loc_valid   bin_selector_0/radar_loc_valid
vs_net vs_defaults_0/radar_localize_en bin_selector_0/radar_localize_en

# bin statistics: real logic inside vs_defaults_0 (no_candidate / n_free_bins)
vs_net bin_selector_0/n_bins_sel       vs_defaults_0/n_bins_sel
vs_net bin_selector_0/free_mask        vs_defaults_0/free_mask

# certificate_fsm statistics
vs_net vs_defaults_0/no_candidate        certificate_0/no_candidate
vs_net vs_defaults_0/outlier_q15         certificate_0/outlier_q15
vs_net vs_defaults_0/support_q15         certificate_0/support_q15
vs_net vs_defaults_0/dispersion_q8       certificate_0/dispersion_q8
vs_net vs_defaults_0/subwin_delta_q8     certificate_0/subwin_delta_q8
vs_net vs_defaults_0/contrast_db_q8      certificate_0/contrast_db_q8
vs_net vs_defaults_0/harmonic_collision  certificate_0/harmonic_collision

# null_model_cancel: common-mode reference + reserved inputs
vs_net vs_defaults_0/ref_i             null_model_cancel_0/ref_i
vs_net vs_defaults_0/ref_q             null_model_cancel_0/ref_q
vs_net vs_defaults_0/nc_start          null_model_cancel_0/start
vs_net vs_defaults_0/nc_s_last         null_model_cancel_0/s_last

# engine: nominal breathing fundamental (0.30 Hz)
vs_net vs_defaults_0/fr_inc_nominal    vs_engine_0/fr_inc_in

#=============================================================================
# 10) Result registers
#=============================================================================
puts "\n--- 10) result output ---"
vs_net certificate_0/decision       result_out_0/decision
vs_net certificate_0/quality_q8     result_out_0/quality_q8
vs_net certificate_0/confidence_q15 result_out_0/confidence_q15
vs_net peak_argmax_0/contrast_q12   result_out_0/vr_contrast_q12
vs_net bin_selector_0/bin_mask      result_out_0/bin_mask
vs_net bin_selector_0/eff_range_q16 result_out_0/eff_range_q16
vs_net robot_motion_if_0/robot_cmd_out result_out_0/robot_cmd
vs_net vs_engine_0/meas_done        result_out_0/meas_done
vs_net integrate_detrend_0/win_ready result_out_0/win_ready
vs_net vs_engine_0/fr_inc_out       result_out_0/fr_inc
vs_net result_out_0/irq             processing_system7_0/IRQ_F2P
#--- defaults / placeholders that also feed the result register block --------
vs_net bpm_map_0/heart_bpm_q8            result_out_0/heart_bpm_q8
vs_net bpm_map_0/resp_bpm_q8             result_out_0/resp_bpm_q8
vs_net vs_defaults_0/support_q15         result_out_0/support_q15
vs_net ratio_q15_0/ratio_q15             result_out_0/compet_vr_q15
vs_net vs_defaults_0/outlier_q15         result_out_0/outlier_q15
vs_net vs_defaults_0/harmonic_collision  result_out_0/harmonic_collision
vs_net robot_motion_if_0/motion_reject   result_out_0/motion_reject
vs_net bin_selector_0/out_of_range       result_out_0/out_of_range
vs_net bin_selector_0/n_bins_sel         result_out_0/n_bins_sel
vs_net vs_defaults_0/n_free_bins         result_out_0/n_free_bins
vs_net radar_frame_if_0/frame_cnt        result_out_0/frame_cnt
vs_net vs_engine_0/busy                  result_out_0/busy

#=============================================================================
# 11) Address assignment, layout, validate, save
#=============================================================================
puts "\n--- 11) address / validate / save ---"
# Print every DATA_WIDTH that has to agree, so a future mismatch is obvious
# in the log instead of only appearing as "BD 41-237".
foreach cell {processing_system7_0 axi_pc axi_dma_0 result_out_0} {
    foreach p [lsort [cfg_names $cell]] {
        if {[string match -nocase "*DATA_WIDTH*" $p]} {
            catch { puts "  width  $cell : $p = [get_property $p [get_bd_cells $cell]]" }
        }
    }
}
catch { assign_bd_address }
catch { regenerate_bd_layout }
save_bd_design

if {[catch { validate_bd_design } e]} {
    puts "  validate_bd_design returned: $e"
} else {
    puts "  validate_bd_design OK"
}

set bds [get_files -quiet *.bd]
if {[llength $bds] > 0 } {
    puts "  generating output products ..."
    catch { generate_target all $bds }
}
save_bd_design
puts "\n===== Block Design build finished ====="
