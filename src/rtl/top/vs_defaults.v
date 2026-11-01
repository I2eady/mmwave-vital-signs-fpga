//=============================================================================
// vs_defaults.v -- 占位 / 默认值源
//-----------------------------------------------------------------------------
// 为什么要有这个模块：
//   Vivado 的 Block Design 对未连接的输入脚只给一条 CRITICAL WARNING
//   (BD 41-759) 然后**静默 tie 成 0**。这会掩盖真实问题——分辨不出
//   "本来设计成 0" 和 "忘了接线"。
//   把还没有数据源的输入集中到这一个小模块上，BD 里就不存在悬空输入，
//   而"哪些量还是占位"在数据流图上一眼可见（一个块，下面挂着那些信号）。
//
// 已经算出真值的量（不是常量）：
//   no_candidate = (n_bins_sel == 0)        没有任何有限候选 -> 拒绝
//   n_free_bins  = popcount(free_mask)      空仓个数
//
// 其余是占位常量，逐个对应 docs/架构与移植说明.md 的近似清单 A1..A10：
//   support_q15        = 0.80 << 15   分量一致度（近似清单 A9）。Python 由逐
//                                     (bin,RX) 的 argmax 一致性统计得到，需要
//                                     分量级暂存，当前取占位 0.8。
//   contrast_db_q8     = 12 dB << 8   谱峰突出度。应由 vr_contrast_q12 取
//                                     20*log10 得到；取 12 dB 表示"不惩罚"。
//   outlier_q15        = 0            野点比例，待加逐分量野点统计 (A9)
//   dispersion_q8      = 0            分量离散度 bpm，待加跨分量 MAD (A9)
//   subwin_delta_q8    = 0            子窗偏差 bpm，待加双子窗差分 (A9)
//   harmonic_collision = 0            谐波碰撞，待加谐波/心率峰重合检测 (A10)
//   motion_thresh_q16  = 100 mm/s     默认运动门限；正式版本应由 PS 通过
//                                     第二路 AXI GPIO 写入
//   robot_ctrl         = bit0=1       使能测量（robot_motion_if.reg_ctrl[0]）
//   radar_loc_*        = 0            Ablation A 的雷达自定位回退；置 0 即
//                                     关闭，只用视觉距离选仓（论文消融项）
//   ref_i / ref_q      = 0            共模参考（近似清单 A4）。cm_ref_extract
//                                     已写好但还没调度进引擎，置 0 时
//                                     null_model_cancel 只做呼吸谐波抵消
//   fr_inc_nominal     = 0.30 Hz 相位增量 (0.30/20 * 2^32 = 64424509)
//                                     呼吸基频；正式版本应由呼吸峰实测换算，
//                                     引擎目前还没调度这一步
//   nc_start/nc_s_last = 0            null_model_cancel 的保留输入（当前
//                                     RTL 中未使用，仅为接口完整性保留）
//=============================================================================
`timescale 1ns / 1ps

module vs_defaults #(
    parameter integer DW     = 24,
    parameter integer BIN_W  = 5,
    parameter integer N_BINS = 20
)(
    input  wire                    aclk,
    input  wire                    aresetn,

    // ---- 真实统计量的输入（有输入就一定算） -----------------------------
    input  wire [BIN_W-1:0]        n_bins_sel,
    input  wire [N_BINS-1:0]       free_mask,

    // ---- -> certificate_fsm ---------------------------------------------
    output wire                    no_candidate,
    output wire [15:0]             outlier_q15,
    output wire [15:0]             support_q15,
    output wire signed [15:0]      dispersion_q8,
    output wire signed [15:0]      subwin_delta_q8,
    output wire signed [15:0]      contrast_db_q8,
    output wire                    harmonic_collision,

    // ---- -> robot_motion_if ---------------------------------------------
    output wire [31:0]             motion_thresh_q16,
    output wire [31:0]             robot_ctrl,

    // ---- -> bin_selector ------------------------------------------------
    output wire [BIN_W-1:0]        radar_loc_bin,
    output wire                    radar_loc_valid,
    output wire                    radar_localize_en,

    // ---- -> null_model_cancel -------------------------------------------
    output wire [DW-1:0]           ref_i,
    output wire [DW-1:0]           ref_q,
    output wire                    nc_start,
    output wire                    nc_s_last,

    // ---- -> vs_engine_fsm -----------------------------------------------
    output wire [31:0]             fr_inc_nominal,

    // ---- -> result_out ---------------------------------------------------
    output wire [7:0]              n_free_bins
);

    //-----------------------------------------------------------------------
    // 真实统计：空仓个数（popcount）
    //-----------------------------------------------------------------------
    integer  i;
    reg [7:0] pc;

    always @(*) begin
        pc = 8'd0;
        for (i = 0; i < N_BINS; i = i + 1) begin
            if (free_mask[i]) pc = pc + 8'd1;
        end
    end

    assign n_free_bins = pc;

    //-----------------------------------------------------------------------
    // 真实统计：没有候选仓
    //-----------------------------------------------------------------------
    assign no_candidate = (n_bins_sel == {BIN_W{1'b0}});

    //-----------------------------------------------------------------------
    // 占位常量
    //-----------------------------------------------------------------------
    assign outlier_q15        = 16'd0;
    assign support_q15        = 16'd26214;      // 0.80
    assign dispersion_q8      = 16'sd0;
    assign subwin_delta_q8    = 16'sd0;
    assign contrast_db_q8     = 16'sd3072;      // 12 dB
    assign harmonic_collision = 1'b0;

    assign motion_thresh_q16  = 32'd6553600;    // 100 mm/s in Q16.16
    assign robot_ctrl         = 32'd1;          // bit0 = enable measurement

    assign radar_loc_bin      = {BIN_W{1'b0}};
    assign radar_loc_valid    = 1'b0;
    assign radar_localize_en  = 1'b0;

    assign ref_i              = {DW{1'b0}};
    assign ref_q              = {DW{1'b0}};
    assign nc_start           = 1'b0;
    assign nc_s_last          = 1'b0;

    assign fr_inc_nominal     = 32'd64424509;   // 0.30 Hz @ fs = 20 Hz

endmodule
