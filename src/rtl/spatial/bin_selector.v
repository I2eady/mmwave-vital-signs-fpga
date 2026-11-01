//=============================================================================
// bin_selector.v -- 视觉距离 -> 候选距离仓 / 空仓掩码
//-----------------------------------------------------------------------------
// 对应 Python:  estimator.py :: candidate_bins() / _subject_free_bins()
//                                / out_of_band_margin_m() / _effective_range()
//
//   bin_spacing = (0.85-0.35)/(20-1) = 0.0263158 m   -> 1/spacing = 38.0
//   center      = round( (range_m - 0.35) * 38 )
//   half        = ceil( 0.12 * 38 ) = 5
//   候选仓      = [clamp(center-5, 0, 19),  clamp(center+6, 0, 20) ) 内的仓
//   空仓        = 候选仓之外的仓 -> 用于共模参考
//   越界判据    = 距 0.35~0.85 m 带的余量 > 0.12 m  -> REJECT_RANGE
//
// Ablation A（雷达自定位）：视觉距离缺失或越界时，改用输入 radar_loc_bin
//   （由呼吸带距离能量剖面的 argmax 提供）作为等效距离，而不是硬夹到带边缘。
//=============================================================================
`timescale 1ns / 1ps
module bin_selector #(
    parameter integer N_BINS = 20,
    parameter integer BIN_W  = 5
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    // ---- 来自机器人视觉几何 / AXI-Lite 寄存器 ---------------------------
    input  wire signed [31:0]    vision_range_q16,   // Q16.16，NaN 用 0x7FFFFFFF 表示
    input  wire [BIN_W-1:0]      radar_loc_bin,      // 雷达自定位结果（回退用）
    input  wire                  radar_loc_valid,
    input  wire                  radar_localize_en,  // config.radar_localize

    // ---- 输出 -----------------------------------------------------------
    output reg  [N_BINS-1:0]     bin_mask,           // 候选仓
    output reg  [N_BINS-1:0]     free_mask,          // 空仓（共模参考）
    output reg  [BIN_W-1:0]      subject_bin,
    output reg signed [31:0]     eff_range_q16,      // 实际使用距离
    output reg                   out_of_range,       // -> REJECT_RANGE
    output reg  [4:0]            n_bins_sel          // 候选仓个数
);

    localparam signed [31:0] R_MIN_Q16 = 32'sd22938;   // 0.35 m
    localparam signed [31:0] R_MAX_Q16 = 32'sd55706;   // 0.85 m
    localparam signed [31:0] TOL_Q16   = 32'sd7864;    // 0.12 m
    localparam signed [31:0] HALF      = 32'sd5;       // ceil(0.12*38)

    wire in_band = (vision_range_q16 >= (R_MIN_Q16 - TOL_Q16)) &&
                   (vision_range_q16 <= (R_MAX_Q16 + TOL_Q16));

    // ---- 越界余量 -------------------------------------------------------
    wire signed [31:0] margin_lo = R_MIN_Q16 - vision_range_q16;
    wire signed [31:0] margin_hi = vision_range_q16 - R_MAX_Q16;
    wire signed [31:0] margin    = (margin_lo > margin_hi) ? margin_lo : margin_hi;
    wire               oor       = (margin > TOL_Q16);

    // ---- 有效距离（视觉优先，雷达回退） ---------------------------------
    wire signed [31:0] range_clamped =
        (vision_range_q16 < R_MIN_Q16) ? R_MIN_Q16 :
        (vision_range_q16 > R_MAX_Q16) ? R_MAX_Q16 : vision_range_q16;

    // 雷达回退距离 = 0.35 + bin*spacing   (Q16.16)
    wire signed [31:0] radar_range_q16 =
        R_MIN_Q16 + ($signed({27'd0, radar_loc_bin}) * 32'sd1725);

    wire use_radar = radar_localize_en && (!in_band) && radar_loc_valid;
    wire signed [31:0] eff_range = use_radar ? radar_range_q16 : range_clamped;

    // ---- center = round((eff_range - 0.35) * 38) ------------------------
    wire signed [33:0] delta        = {2{eff_range[31]}} + (eff_range - R_MIN_Q16);
    wire signed [39:0] center_prod  = delta * 34'sd38;
    wire signed [23:0] center_round = (center_prod + 40'sd32768) >>> 16;

    // ---- 候选仓区间 -----------------------------------------------------
    wire signed [23:0] lo_raw = center_round - 24'sd5;
    wire signed [23:0] hi_raw = center_round + 24'sd6;

    wire signed [23:0] lo_i = (lo_raw < 24'sd0)  ? 24'sd0  : lo_raw;
    wire signed [23:0] hi_i = (hi_raw > 24'sd20) ? 24'sd20 : hi_raw;
    wire signed [23:0] sb_i = (center_round < 24'sd0)  ? 24'sd0 :
                              (center_round > 24'sd19) ? 24'sd19 : center_round;

    integer b;
    always @(*) begin
        bin_mask  = {N_BINS{1'b0}};
        free_mask = {N_BINS{1'b0}};
        n_bins_sel = 5'd0;
        for (b = 0; b < N_BINS; b = b + 1) begin
            if ((b >= lo_i) && (b < hi_i)) begin
                bin_mask[b]  = 1'b1;
                n_bins_sel   = n_bins_sel + 5'd1;
            end else begin
                free_mask[b] = 1'b1;
            end
        end
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            subject_bin  <= {BIN_W{1'b0}};
            eff_range_q16<= 32'sd0;
            out_of_range <= 1'b0;
        end else begin
            subject_bin   <= sb_i[BIN_W-1:0];
            eff_range_q16 <= eff_range;
            // 只有完全无法定位（视觉不在带内且雷达回退也无效）才判 REJECT_RANGE
            out_of_range  <= oor && (!use_radar);
        end
    end

endmodule
