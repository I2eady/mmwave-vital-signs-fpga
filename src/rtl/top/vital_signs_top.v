//=============================================================================
// vital_signs_top.v -- 顶层集成（纯 RTL 数据通路，例化全部算法模块）
//-----------------------------------------------------------------------------
// 与 Python scr/ 的模块一一对应：
//
//  radar_frame_if  -> dataio.load_radar + 分析窗切片
//  dacm_phase      -> dsp.dacm_phase
//  hampel7         -> dsp.hampel_axis
//  integrate_     -> dsp.integrate_axis + dsp.detrend_axis
//  detrend
//  bin_selector    -> estimator.candidate_bins / _subject_free_bins
//  robot_motion_if -> 机器人运动门控（对应 vision_geometry.motion_safe）
//  biquad_cascade  -> dsp.bandpass_axis (filtfilt)
//  null_model_     -> estimator._harmonic_residual + _common_mode_reference
//  cancel
//  goertzel_sweep  -> dsp.spectrum + estimator._vr_sweep 频率轴
//  spectrum_accum  -> estimator._fused_spectrum
//  peak_argmax     -> np.argmax + dsp.parabolic_peak + vr_contrast
//  certificate_fsm -> estimator._certificate
//  result_out      -> run.py 的输出字段（AXI4-Lite 从端）
//=============================================================================
`timescale 1ns / 1ps
module vital_signs_top #(
    parameter integer DW     = 24,
    parameter integer CW     = 18,
    parameter integer N_RX   = 4,
    parameter integer N_BINS = 20,
    parameter integer N_CH   = 80,
    parameter integer NSAMP  = 600,
    parameter integer NPTS_R = 91,
    parameter integer NPTS_V = 201,
    parameter         CMEM   = "coeff_rom.mem",
    parameter         GMEM   = "dft_delta.mem",
    parameter         SMEM   = "sin_lut.mem"
)(
    input  wire              aclk,
    input  wire              aresetn,

    // ---- 雷达原始帧流（来自 AXI-DMA MM2S） -------------------------------
    input  wire [31:0]       s_axis_raw_tdata,
    input  wire              s_axis_raw_tvalid,
    output wire              s_axis_raw_tready,
    input  wire              s_axis_raw_tuser,
    input  wire              s_axis_raw_tlast,

    // ---- 控制寄存器（来自 AXI-GPIO / PS） -------------------------------
    input  wire [31:0]       reg_vision_range,
    input  wire [31:0]       reg_robot_vel,
    input  wire [31:0]       reg_motion_thresh,
    input  wire [31:0]       reg_ctrl,

    // ---- 结果（送往 result_out） ----------------------------------------
    output wire [15:0]       o_heart_bpm_q8,
    output wire [15:0]       o_resp_bpm_q8,
    output wire [2:0]        o_decision,
    output wire [15:0]       o_quality_q8,
    output wire [15:0]       o_support_q15,
    output wire [15:0]       o_confidence_q15,
    output wire [15:0]       o_compet_vr_q15,
    output wire [31:0]       o_vr_contrast_q12,
    output wire [15:0]       o_outlier_q15,
    output wire              o_harmonic_collision,
    output wire [19:0]       o_bin_mask,
    output wire [7:0]        o_n_bins_sel,
    output wire [7:0]        o_n_free_bins,
    output wire [31:0]       o_eff_range_q16,
    output wire [31:0]       o_robot_cmd,
    output wire [31:0]       o_fr_inc,
    output wire [15:0]       o_frame_cnt,
    output wire              o_win_ready,
    output wire              o_meas_done,
    output wire              o_busy
);

    //=========================================================================
    // 1) 帧接口 + 相位提取链
    //=========================================================================
    wire [31:0] frame_tdata;   wire frame_tvalid, frame_tready;
    wire [6:0]  frame_tuser;   wire frame_tlast;
    wire        frame_sync, win_active, win_done;

    radar_frame_if #(.N_RX(N_RX), .N_BINS(N_BINS)) u_frame (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (s_axis_raw_tdata),
        .s_axis_tvalid(s_axis_raw_tvalid),
        .s_axis_tready(s_axis_raw_tready),
        .s_axis_tuser (s_axis_raw_tuser),
        .s_axis_tlast (s_axis_raw_tlast),
        .m_axis_tdata (frame_tdata),
        .m_axis_tvalid(frame_tvalid),
        .m_axis_tready(frame_tready),
        .m_axis_tuser (frame_tuser),
        .m_axis_tlast (frame_tlast),
        .frame_sync   (frame_sync),
        .win_active   (win_active),
        .win_done     (win_done),
        .frame_cnt    (o_frame_cnt)
    );

    wire [31:0] dphi_tdata;  wire dphi_tvalid, dphi_tready;
    wire [6:0]  dphi_tuser;  wire dphi_tlast;

    dacm_phase #(.N_CH(N_CH), .CH_W(7)) u_dacm (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (frame_tdata),  .s_axis_tvalid(frame_tvalid),
        .s_axis_tready(frame_tready), .s_axis_tuser (frame_tuser),
        .s_axis_tlast (frame_tlast),
        .m_axis_tdata (dphi_tdata),   .m_axis_tvalid(dphi_tvalid),
        .m_axis_tready(dphi_tready),  .m_axis_tuser (dphi_tuser),
        .m_axis_tlast (dphi_tlast)
    );

    wire [31:0] ham_tdata;   wire ham_tvalid, ham_tready;
    wire [6:0]  ham_tuser;   wire ham_tlast;
    wire [15:0] outlier_cnt, sample_cnt;

    hampel7 #(.W(DW), .N_CH(N_CH), .CH_W(7)) u_hampel (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata (dphi_tdata),  .s_axis_tvalid(dphi_tvalid),
        .s_axis_tready(dphi_tready), .s_axis_tuser (dphi_tuser),
        .s_axis_tlast (dphi_tlast),
        .m_axis_tdata (ham_tdata),   .m_axis_tvalid(ham_tvalid),
        .m_axis_tready(ham_tready),  .m_axis_tuser (ham_tuser),
        .m_axis_tlast (ham_tlast),
        .outlier_cnt  (outlier_cnt), .sample_cnt   (sample_cnt)
    );

    wire        int_win_ready;
    wire signed [DW-1:0] mem_rdata;

    integrate_detrend #(.W(DW), .N_CH(N_CH), .NSAMP(NSAMP)) u_intdet (
        .aclk(aclk), .aresetn(aresetn),
        .win_start    (frame_sync),
        .s_axis_tdata (ham_tdata),
        .s_axis_tvalid(ham_tvalid),
        .s_axis_tready(ham_tready),
        .s_axis_tlast (ham_tlast),
        .win_ready    (int_win_ready),
        .mean_ch      (),
        .slope_ch     (),
        .rd_addr      (resp_bf_addr),
        .rd_addr_b    (card_bf_addr),
        .rd_sel       (fir_card_busy),
        .rd_data      (mem_rdata)
    );

    //=========================================================================
    // 2) 空间选择 + 机器人接口
    //=========================================================================
    wire signed [31:0] vision_range_q16;
    wire               motion_reject, motion_safe;
    wire [15:0]        vel_peak;
    wire [4:0]         subject_bin;
    wire [19:0]        bin_mask_w;
    wire [4:0]         n_bins_sel_w;
    wire               out_of_range_w;

    robot_motion_if u_robot (
        .aclk(aclk), .aresetn(aresetn),
        .reg_vision_range (reg_vision_range),
        .reg_robot_vel    (reg_robot_vel),
        .reg_motion_thresh(reg_motion_thresh),
        .reg_ctrl         (reg_ctrl),
        .win_active       (win_active),
        .win_done         (win_done),
        .vision_range_q16 (vision_range_q16),
        .motion_safe      (motion_safe),
        .motion_reject    (motion_reject),
        .vel_peak_mmps    (vel_peak),
        .robot_cmd_out    (o_robot_cmd),
        .meas_enable      ()
    );

    bin_selector #(.N_BINS(N_BINS)) u_binsel (
        .aclk(aclk), .aresetn(aresetn),
        .vision_range_q16 (vision_range_q16),
        .radar_loc_bin    (5'd0),
        .radar_loc_valid  (1'b0),
        .radar_localize_en(1'b1),
        .bin_mask         (bin_mask_w),
        .free_mask        (),
        .subject_bin      (subject_bin),
        .eff_range_q16    (o_eff_range_q16),
        .out_of_range     (out_of_range_w),
        .n_bins_sel       (n_bins_sel_w)
    );

    //=========================================================================
    // 3) 引擎控制线
    //=========================================================================
    wire        bf_start_resp, bf_start_card;
    wire        fir_card_busy;          // 心脏带 FIR 忙 -> 窗口存储器读端口选择
    wire [15:0] bf_base_addr;
    wire        gz_start_resp, gz_start_vr;
    wire [7:0]  gz_npts;
    wire        pk_start, pk_sel, pk_done;
    wire [7:0]  pk_npts_w;
    wire        cert_start, cert_done;
    wire [31:0] fr_inc_w;

    // 呼吸通道
    wire signed [DW-1:0] resp_bf_data;
    wire                 resp_bf_valid, resp_bf_done;
    wire [15:0]          resp_bf_addr;
    wire                 resp_res_we,   resp_gz_done;
    wire [7:0]           resp_res_addr;
    wire [31:0]          resp_res_mag;

    // 心脏通道
    wire signed [DW-1:0] card_bf_data;
    wire                 card_bf_valid, card_bf_done;
    wire [15:0]          card_bf_addr;
    wire signed [DW-1:0] nc_data;
    wire                 nc_valid;
    wire                 card_res_we,   card_gz_done;
    wire [7:0]           card_res_addr;
    wire [31:0]          card_res_mag;

    // 峰值搜索
    wire [7:0]  pk_k_best;
    wire [31:0] pk_peak, pk_med, pk_contrast, pk_sum;
    wire signed [15:0] pk_delta;

    // 窗口存储器读端口由 integrate_detrend 内部的 rd_sel 选择：
    //   心脏带 FIR 忙 -> 用 rd_addr_b，否则用 rd_addr

    //=========================================================================
    // 4) 呼吸带双向滤波 + DFT 扫描
    //=========================================================================
    fir_bandpass #(.DW(DW), .NSAMP(NSAMP), .N_CH(N_CH), .CMEM(CMEM)) u_resp_bf (
        .aclk(aclk), .aresetn(aresetn),
        .start     (bf_start_resp),
        .base_addr (bf_base_addr),
        .band_sel  (2'd0),
        .busy      (), .done(resp_bf_done),
        .mem_addr  (resp_bf_addr),
        .mem_data  (mem_rdata),
        .m_data    (resp_bf_data), .m_valid(resp_bf_valid), .m_ready(1'b1)
    );

    goertzel_sweep #(.DW(DW), .NSAMP(NSAMP), .MAXPTS(256), .AW(8),
                     .GMEM(GMEM), .SMEM(SMEM)) u_resp_dft (
        .aclk(aclk), .aresetn(aresetn),
        .start    (gz_start_resp),
        .grid_sel (2'd0), .npts(gz_npts),
        .s_data   (resp_bf_data), .s_valid(resp_bf_valid), .s_ready(),
        .res_we   (resp_res_we), .res_addr(resp_res_addr), .res_mag(resp_res_mag),
        .busy(), .done(resp_gz_done)
    );

    //=========================================================================
    // 5) 心脏带双向滤波 + 零模型抵消 + VR 扫描
    //=========================================================================
    fir_bandpass #(.DW(DW), .NSAMP(NSAMP), .N_CH(N_CH), .CMEM(CMEM)) u_card_bf (
        .aclk(aclk), .aresetn(aresetn),
        .start     (bf_start_card),
        .base_addr (bf_base_addr),
        .band_sel  (2'd1),
        .busy      (fir_card_busy), .done(card_bf_done),
        .mem_addr  (card_bf_addr),
        .mem_data  (mem_rdata),
        .m_data    (card_bf_data), .m_valid(card_bf_valid), .m_ready(1'b1)
    );

    null_model_cancel #(.DW(DW), .NHARM(11), .SMEM(SMEM)) u_nmc (
        .aclk(aclk), .aresetn(aresetn),
        .start   (bf_start_card),
        .fr_inc  (fr_inc_w),
        .clr     (card_bf_done),
        .s_data  (card_bf_data), .s_valid(card_bf_valid), .s_ready(),
        .s_last  (1'b0),
        .ref_i   ({DW{1'b0}}), .ref_q({DW{1'b0}}),
        .m_data  (nc_data), .m_valid(nc_valid), .m_ready(1'b1)
    );

    goertzel_sweep #(.DW(DW), .NSAMP(NSAMP), .MAXPTS(256), .AW(8),
                     .GMEM(GMEM), .SMEM(SMEM)) u_card_dft (
        .aclk(aclk), .aresetn(aresetn),
        .start    (gz_start_vr),
        .grid_sel (2'd1), .npts(gz_npts),
        .s_data   (nc_data), .s_valid(nc_valid), .s_ready(),
        .res_we   (card_res_we), .res_addr(card_res_addr), .res_mag(card_res_mag),
        .busy(), .done(card_gz_done)
    );

    //=========================================================================
    // 6) 谱融合累加 + 峰值搜索
    //=========================================================================
    wire [7:0]  pk_rd_addr;
    wire [31:0] pk_rd_mag;

    spectrum_accum #(.AW(8), .MAXPTS(256)) u_sacc (
        .aclk(aclk), .aresetn(aresetn),
        .clr(cert_done),
        .acc_we   (resp_res_we),  .acc_addr(resp_res_addr), .acc_mag(resp_res_mag),
        .acc_we_b (card_res_we),  .acc_addr_b(card_res_addr), .acc_mag_b(card_res_mag),
        .rd_addr (pk_rd_addr), .rd_mag(pk_rd_mag), .ready()
    );

    peak_argmax #(.AW(8), .MAXPTS(256), .MW(32)) u_peak (
        .aclk(aclk), .aresetn(aresetn),
        .start   (pk_start),
        .npts    (pk_npts_w),
        .rd_addr (pk_rd_addr), .rd_mag(pk_rd_mag),
        .busy(), .done(pk_done),
        .k_best  (pk_k_best), .peak_val(pk_peak), .median_val(pk_med),
        .contrast_q12(pk_contrast), .sum_val(pk_sum), .delta_q10(pk_delta)
    );

    // 呼吸率（Hz, Q16.16）= 0.15 + k*0.005
    wire [31:0] f_resp_q16 = 32'd9830 + ({{24{1'b0}}, pk_k_best} * 32'd328);
    // 相位增量 = f/fs * 2^32 = f_q16 * 65536 / 20
    assign fr_inc_w = ((f_resp_q16 * 32'd65536) >> 5) / 32'd2048;

    // 心率 bpm（Q8.8）= 60 + k*0.25
    wire [31:0] hr_bpm_q8 = 32'd15360 + ({{24{1'b0}}, pk_k_best} * 32'd64);

    //=========================================================================
    // 7) 证书
    //=========================================================================
    wire [15:0] outlier_q15_w = (sample_cnt == 16'd0) ? 16'd0 :
                                ((outlier_cnt * 16'd32767) / sample_cnt);
    wire [15:0] compet_vr_q15_w = (pk_peak > 32'h0000_FFFF) ? 16'hFFFF : pk_peak[15:0];
    wire [15:0] support_q15_w   = 16'd26214;     // 0.8（分量一致性统计的占位，见文档）
    wire [31:0] cdb_like        = (pk_med == 0) ? 32'd0 :
                                  ((pk_peak * 32'd1200) / pk_med);

    certificate_fsm u_cert (
        .aclk(aclk), .aresetn(aresetn),
        .start             (cert_start),
        .no_candidate      (1'b0),
        .out_of_range      (out_of_range_w),
        .motion_reject     (motion_reject),
        .outlier_q15       (outlier_q15_w),
        .compet_vr_q15     (compet_vr_q15_w),
        .vr_contrast_q12   (pk_contrast),
        .support_q15       (support_q15_w),
        .dispersion_q8     (16'd0),
        .subwin_delta_q8   (16'd0),
        .contrast_db_q8    ((cdb_like > 32'h0000_FFFF) ? 16'hFFFF : cdb_like[15:0]),
        .harmonic_collision(1'b0),
        .decision          (o_decision),
        .quality_q8        (o_quality_q8),
        .confidence_q15    (o_confidence_q15),
        .busy(), .done(cert_done)
    );

    //=========================================================================
    // 8) 引擎编排
    //=========================================================================
    vs_engine_fsm #(.NPTS_RESP(NPTS_R), .NPTS_VR(NPTS_V)) u_engine (
        .aclk(aclk), .aresetn(aresetn),
        .win_ready     (int_win_ready),
        .bin_mask      (bin_mask_w),
        .fr_inc_in     (fr_inc_w),
        .accum_clr     (),
        .bf_start_resp (bf_start_resp), .bf_done_resp(resp_bf_done),
        .bf_start_card (bf_start_card), .bf_done_card(card_bf_done),
        .nc_clr        (),
        .gz_start_resp (gz_start_resp), .gz_done_resp(resp_gz_done),
        .gz_start_vr   (gz_start_vr),   .gz_done_vr  (card_gz_done),
        .gz_npts       (gz_npts),
        .pk_start      (pk_start), .pk_sel(pk_sel),
        .pk_npts       (pk_npts_w), .pk_done(pk_done),
        .cert_start    (cert_start), .cert_done(cert_done),
        .bf_base_addr  (bf_base_addr),
        .fr_inc_out    (), .meas_done(o_meas_done), .state_dbg()
    );

    //=========================================================================
    // 9) 输出打包
    //=========================================================================
    assign o_heart_bpm_q8   = pk_sel ? hr_bpm_q8[15:0] : 16'hFFFF;
    assign o_resp_bpm_q8    = ((f_resp_q16 * 32'd60) >> 16)[15:0];
    assign o_support_q15    = support_q15_w;
    assign o_compet_vr_q15  = compet_vr_q15_w;
    assign o_vr_contrast_q12= pk_contrast;
    assign o_outlier_q15    = outlier_q15_w;
    assign o_bin_mask       = bin_mask_w;
    assign o_n_bins_sel     = {3'd0, n_bins_sel_w};
    assign o_n_free_bins    = 8'd20 - {3'd0, n_bins_sel_w};
    assign o_fr_inc         = fr_inc_w;
    assign o_win_ready      = int_win_ready;
    assign o_busy           = bf_start_resp | bf_start_card | pk_start;
    assign o_harmonic_collision = 1'b0;

endmodule
