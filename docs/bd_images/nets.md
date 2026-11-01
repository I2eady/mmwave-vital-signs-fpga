### 1. AXI-Stream 数据流（PS / DMA -> 相位链）

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `axi_dma_0` | `M_AXIS_MM2S` | `radar_frame_if_0` | `s_axis` |
| `axi_dma_0` | `M_AXI_MM2S` | `axi_pc` | `S_AXI` |

### 2. 普通数据流 data / valid / ready（滤波 -> 谱）

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `fir_card_0` | `m_data` | `null_model_cancel_0` | `s_data` |
| `fir_card_0` | `m_ready` | `null_model_cancel_0` | `s_ready` |
| `fir_card_0` | `m_valid` | `null_model_cancel_0` | `s_valid` |
| `fir_resp_0` | `m_data` | `goertzel_resp_0` | `s_data` |
| `fir_resp_0` | `m_ready` | `goertzel_resp_0` | `s_ready` |
| `fir_resp_0` | `m_valid` | `goertzel_resp_0` | `s_valid` |
| `null_model_cancel_0` | `m_data` | `goertzel_vr_0` | `s_data` |
| `null_model_cancel_0` | `m_ready` | `goertzel_vr_0` | `s_ready` |
| `null_model_cancel_0` | `m_valid` | `goertzel_vr_0` | `s_valid` |

### 3. 窗口存储器读端口（600x80 滤波器输入）

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `fir_card_0` | `busy` | `integrate_detrend_0` | `rd_sel` |
| `fir_card_0` | `mem_addr` | `integrate_detrend_0` | `rd_addr_b` |
| `fir_resp_0` | `mem_addr` | `integrate_detrend_0` | `rd_addr` |
| `integrate_detrend_0` | `rd_data` | `fir_card_0` | `mem_data` |
| `integrate_detrend_0` | `rd_data` | `fir_resp_0` | `mem_data` |

### 4. 引擎控制握手（start / done / 选择信号）

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `bin_selector_0` | `bin_mask` | `vs_engine_0` | `bin_mask` |
| `certificate_0` | `done` | `vs_engine_0` | `cert_done` |
| `dacm_phase_0` | `m_axis` | `hampel7_0` | `s_axis` |
| `fir_card_0` | `done` | `vs_engine_0` | `bf_done_card` |
| `fir_resp_0` | `done` | `vs_engine_0` | `bf_done_resp` |
| `goertzel_resp_0` | `done` | `vs_engine_0` | `gz_done_resp` |
| `goertzel_vr_0` | `done` | `vs_engine_0` | `gz_done_vr` |
| `hampel7_0` | `m_axis` | `integrate_detrend_0` | `s_axis` |
| `integrate_detrend_0` | `win_ready` | `vs_engine_0` | `win_ready` |
| `radar_frame_if_0` | `m_axis` | `dacm_phase_0` | `s_axis` |
| `ratio_q15_0` | `ratio_q15` | `certificate_0` | `compet_vr_q15` |
| `vs_defaults_0` | `contrast_db_q8` | `certificate_0` | `contrast_db_q8` |
| `vs_defaults_0` | `dispersion_q8` | `certificate_0` | `dispersion_q8` |
| `vs_defaults_0` | `fr_inc_nominal` | `vs_engine_0` | `fr_inc_in` |
| `vs_defaults_0` | `harmonic_collision` | `certificate_0` | `harmonic_collision` |
| `vs_defaults_0` | `nc_s_last` | `null_model_cancel_0` | `s_last` |
| `vs_defaults_0` | `nc_start` | `null_model_cancel_0` | `start` |
| `vs_defaults_0` | `no_candidate` | `certificate_0` | `no_candidate` |
| `vs_defaults_0` | `outlier_q15` | `certificate_0` | `outlier_q15` |
| `vs_defaults_0` | `ref_i` | `null_model_cancel_0` | `ref_i` |
| `vs_defaults_0` | `ref_q` | `null_model_cancel_0` | `ref_q` |
| `vs_defaults_0` | `subwin_delta_q8` | `certificate_0` | `subwin_delta_q8` |
| `vs_defaults_0` | `support_q15` | `certificate_0` | `support_q15` |
| `vs_engine_0` | `bf_base_addr` | `fir_card_0` | `base_addr` |
| `vs_engine_0` | `bf_base_addr` | `fir_resp_0` | `base_addr` |
| `vs_engine_0` | `bf_start_card` | `fir_card_0` | `start` |
| `vs_engine_0` | `bf_start_resp` | `fir_resp_0` | `start` |
| `vs_engine_0` | `busy` | `result_out_0` | `busy` |
| `vs_engine_0` | `cert_start` | `certificate_0` | `start` |
| `vs_engine_0` | `fr_inc_out` | `null_model_cancel_0` | `fr_inc` |
| `vs_engine_0` | `fr_inc_out` | `result_out_0` | `fr_inc` |
| `vs_engine_0` | `gz_npts` | `goertzel_resp_0` | `npts` |
| `vs_engine_0` | `gz_npts` | `goertzel_vr_0` | `npts` |
| `vs_engine_0` | `gz_start_resp` | `goertzel_resp_0` | `start` |
| `vs_engine_0` | `gz_start_vr` | `goertzel_vr_0` | `start` |
| `vs_engine_0` | `meas_done` | `result_out_0` | `meas_done` |
| `vs_engine_0` | `nc_clr` | `null_model_cancel_0` | `clr` |
| `vs_engine_0` | `pk_done` | `bpm_map_0` | `load` |
| `vs_engine_0` | `pk_done` | `ratio_q15_0` | `load` |
| `vs_engine_0` | `pk_sel` | `bpm_map_0` | `sel` |
| `vs_engine_0` | `win_start` | `integrate_detrend_0` | `win_start` |

### 5. 谱累加与峰值搜索

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `goertzel_resp_0` | `res_addr` | `spectrum_accum_0` | `acc_addr` |
| `goertzel_resp_0` | `res_mag` | `spectrum_accum_0` | `acc_mag` |
| `goertzel_resp_0` | `res_we` | `spectrum_accum_0` | `acc_we` |
| `goertzel_vr_0` | `res_addr` | `spectrum_accum_0` | `acc_addr_b` |
| `goertzel_vr_0` | `res_mag` | `spectrum_accum_0` | `acc_mag_b` |
| `goertzel_vr_0` | `res_we` | `spectrum_accum_0` | `acc_we_b` |
| `peak_argmax_0` | `contrast_q12` | `certificate_0` | `vr_contrast_q12` |
| `peak_argmax_0` | `contrast_q12` | `result_out_0` | `vr_contrast_q12` |
| `peak_argmax_0` | `done` | `vs_engine_0` | `pk_done` |
| `peak_argmax_0` | `k_best` | `bpm_map_0` | `k_best` |
| `peak_argmax_0` | `peak_val` | `ratio_q15_0` | `num` |
| `peak_argmax_0` | `rd_addr` | `spectrum_accum_0` | `rd_addr` |
| `peak_argmax_0` | `sum_val` | `ratio_q15_0` | `den` |
| `spectrum_accum_0` | `rd_mag` | `peak_argmax_0` | `rd_mag` |
| `vs_engine_0` | `accum_clr` | `spectrum_accum_0` | `clr` |
| `vs_engine_0` | `pk_npts` | `peak_argmax_0` | `npts` |
| `vs_engine_0` | `pk_start` | `peak_argmax_0` | `start` |

### 6. 空间选择与机器人协同

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `bin_selector_0` | `bin_mask` | `result_out_0` | `bin_mask` |
| `bin_selector_0` | `eff_range_q16` | `result_out_0` | `eff_range_q16` |
| `bin_selector_0` | `free_mask` | `vs_defaults_0` | `free_mask` |
| `bin_selector_0` | `n_bins_sel` | `result_out_0` | `n_bins_sel` |
| `bin_selector_0` | `n_bins_sel` | `vs_defaults_0` | `n_bins_sel` |
| `bin_selector_0` | `out_of_range` | `certificate_0` | `out_of_range` |
| `bin_selector_0` | `out_of_range` | `result_out_0` | `out_of_range` |
| `radar_frame_if_0` | `win_active` | `robot_motion_if_0` | `win_active` |
| `radar_frame_if_0` | `win_done` | `robot_motion_if_0` | `win_done` |
| `robot_motion_if_0` | `motion_reject` | `certificate_0` | `motion_reject` |
| `robot_motion_if_0` | `motion_reject` | `result_out_0` | `motion_reject` |
| `robot_motion_if_0` | `robot_cmd_out` | `result_out_0` | `robot_cmd` |
| `robot_motion_if_0` | `vision_range_q16` | `bin_selector_0` | `vision_range_q16` |
| `vs_defaults_0` | `motion_thresh_q16` | `robot_motion_if_0` | `reg_motion_thresh` |
| `vs_defaults_0` | `radar_loc_bin` | `bin_selector_0` | `radar_loc_bin` |
| `vs_defaults_0` | `radar_loc_valid` | `bin_selector_0` | `radar_loc_valid` |
| `vs_defaults_0` | `radar_localize_en` | `bin_selector_0` | `radar_localize_en` |
| `vs_defaults_0` | `robot_ctrl` | `robot_motion_if_0` | `reg_ctrl` |

### 7. 结果寄存器输出（-> PS）

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `bpm_map_0` | `heart_bpm_q8` | `result_out_0` | `heart_bpm_q8` |
| `bpm_map_0` | `resp_bpm_q8` | `result_out_0` | `resp_bpm_q8` |
| `certificate_0` | `confidence_q15` | `result_out_0` | `confidence_q15` |
| `certificate_0` | `decision` | `result_out_0` | `decision` |
| `certificate_0` | `quality_q8` | `result_out_0` | `quality_q8` |
| `integrate_detrend_0` | `win_ready` | `result_out_0` | `win_ready` |
| `radar_frame_if_0` | `frame_cnt` | `result_out_0` | `frame_cnt` |
| `ratio_q15_0` | `ratio_q15` | `result_out_0` | `compet_vr_q15` |
| `vs_defaults_0` | `harmonic_collision` | `result_out_0` | `harmonic_collision` |
| `vs_defaults_0` | `n_free_bins` | `result_out_0` | `n_free_bins` |
| `vs_defaults_0` | `outlier_q15` | `result_out_0` | `outlier_q15` |
| `vs_defaults_0` | `support_q15` | `result_out_0` | `support_q15` |

### 8. 常量（频带 / 频率网格 / 默认值）

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `const_card` | `dout` | `fir_card_0` | `band_sel` |
| `const_resp` | `dout` | `fir_resp_0` | `band_sel` |
| `const_resp` | `dout` | `goertzel_resp_0` | `grid_sel` |
| `const_vrgrid` | `dout` | `goertzel_vr_0` | `grid_sel` |

### 9. 时钟与复位

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `processing_system7_0` | `FCLK_CLK0` | `axi_gpio_ctrl` | `s_axi_aclk` |
| `processing_system7_0` | `FCLK_CLK0` | `axi_pc` | `aclk` |
| `processing_system7_0` | `FCLK_CLK0` | `axi_smc` | `aclk` |
| `processing_system7_0` | `FCLK_CLK0` | `processing_system7_0` | `M_AXI_GP0_ACLK` |
| `processing_system7_0` | `FCLK_CLK0` | `processing_system7_0` | `S_AXI_HP0_ACLK` |
| `processing_system7_0` | `FCLK_CLK0` | `rst_ps7_100M` | `slowest_sync_clk` |
| `processing_system7_0` | `FCLK_RESET0_N` | `rst_ps7_100M` | `ext_reset_in` |
| `rst_ps7_100M` | `peripheral_aresetn` | `axi_gpio_ctrl` | `s_axi_aresetn` |
| `rst_ps7_100M` | `peripheral_aresetn` | `axi_pc` | `aresetn` |
| `rst_ps7_100M` | `peripheral_aresetn` | `axi_smc` | `aresetn` |

### 10. AXI 总线（PS 侧寄存器通路）

| 源 | 源端口 | 目标 | 目标端口 |
|---|---|---|---|
| `axi_gpio_ctrl` | `gpio2_io_o` | `robot_motion_if_0` | `reg_robot_vel` |
| `axi_gpio_ctrl` | `gpio_io_o` | `robot_motion_if_0` | `reg_vision_range` |
| `axi_pc` | `M_AXI` | `processing_system7_0` | `S_AXI_HP0` |
| `axi_smc` | `M00_AXI` | `axi_dma_0` | `S_AXI_LITE` |
| `axi_smc` | `M01_AXI` | `axi_gpio_ctrl` | `S_AXI` |
| `axi_smc` | `M02_AXI` | `result_out_0` | `s_axi` |
| `processing_system7_0` | `FCLK_CLK0` | `axi_dma_0` | `m_axi_mm2s_aclk` |
| `processing_system7_0` | `FCLK_CLK0` | `axi_dma_0` | `s_axi_lite_aclk` |
| `processing_system7_0` | `M_AXI_GP0` | `axi_smc` | `S00_AXI` |
| `result_out_0` | `irq` | `processing_system7_0` | `IRQ_F2P` |
| `rst_ps7_100M` | `peripheral_aresetn` | `axi_dma_0` | `axi_resetn` |
