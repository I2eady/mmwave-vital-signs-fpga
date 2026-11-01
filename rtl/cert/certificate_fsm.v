//=============================================================================
// certificate_fsm.v -- 质量证书 / 决策分级
//-----------------------------------------------------------------------------
// 对应 Python:  estimator.py :: VitalSignsEstimator._certificate()
//
// 判定优先级（与 Python 完全一致）：
//   1) out_of_range                    -> REJECT_RANGE
//   2) 无有限候选                       -> NO_CANDIDATE
//   3) outlier_fraction > 0.12         -> REJECT_MOTION
//   4) competitive_vr < 0.05           -> REJECT_HARMONIC_UNRESOLVABLE
//   5) vr_contrast < 1.15              -> REJECT_HARMONIC_UNRESOLVABLE
//   6) 其余：输出 heart_bpm
//        support >= 0.50  -> MEASURE
//        否则             -> LOW_CONFIDENCE（仍然输出）
//
// 质量分（与 Python 同式）：
//   q = 20 + 20*p_clip + 15*support + 10*g_clip + 10*dt_clip - 20*o_pen - 5*harm
//   p_clip = clip(contrast_db/12)   g_clip = clip(1 - disp/10)
//   dt_clip= clip(1 - subwin_delta/12)   o_pen = clip(outlier_frac/0.20)
//
// 定点： 所有 0..1 量用 Q1.15，bpm 用 Q8.8，质量分用 Q8.8。
//=============================================================================
`timescale 1ns / 1ps
module certificate_fsm (
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  start,             // 启动一次判定
    input  wire                  no_candidate,      // 无有限候选

    // ---- 证据量 ---------------------------------------------------------
    input  wire                  out_of_range,
    input  wire                  motion_reject,     // 来自 robot_motion_if
    input  wire [15:0]           outlier_q15,       // 野点比例 Q1.15
    input  wire [15:0]           compet_vr_q15,     // argmax VR 值 Q1.15
    input  wire [31:0]           vr_contrast_q12,   // peak/median Q4.12
    input  wire [15:0]           support_q15,       // 分量一致度 Q1.15
    input  wire signed [15:0]    dispersion_q8,     // 分量离散度 bpm Q8.8
    input  wire signed [15:0]    subwin_delta_q8,   // 子窗偏差 bpm Q8.8
    input  wire signed [15:0]    contrast_db_q8,    // 谱峰突出度 dB Q8.8
    input  wire                  harmonic_collision,

    // ---- 结果 -----------------------------------------------------------
    output reg  [2:0]            decision,
    output reg  [15:0]           quality_q8,        // 质量分 (0..100)
    output reg  [15:0]           confidence_q15,    // = support
    output reg                   busy,
    output reg                   done
);

    // ---- 中间裁剪量 -----------------------------------------------------
    // 注意：所有 "x * 32767 / TH" 都必须先在 48 位里算再收窄。
    // 若直接写成 16 位上下文里的乘法，Verilog 会按操作数最大位宽（16）计算乘积，
    // 3072*32767 直接溢出，结果完全错误。
    wire signed [47:0] p_num  = $signed({32'd0, contrast_db_q8}) * 48'sd32767;
    wire        [15:0] p_clip = (contrast_db_q8 <= 0) ? 16'd0 :
                                ((contrast_db_q8 >= 16'sd3072) ? 16'd32767 :   // 12 dB
                                 p_num[47:0] / 48'sd3072);

    wire signed [15:0] disp_abs = (dispersion_q8 < 0) ? -dispersion_q8 : dispersion_q8;
    wire signed [47:0] g_num  = $signed({32'd0, disp_abs}) * 48'sd32767;
    wire        [15:0] g_clip = (disp_abs >= 16'sd2560) ? 16'd0 :              // 10 bpm
                                (16'd32767 - (g_num[47:0] / 48'sd2560));

    wire signed [15:0] dt_abs = (subwin_delta_q8 < 0) ? -subwin_delta_q8 : subwin_delta_q8;
    wire signed [47:0] dt_num = $signed({32'd0, dt_abs}) * 48'sd32767;
    wire        [15:0] dt_clip= (dt_abs >= 16'sd3072) ? 16'd0 :                // 12 bpm
                                (16'd32767 - (dt_num[47:0] / 48'sd3072));

    wire signed [47:0] o_num  = $signed({32'd0, outlier_q15}) * 48'sd32767;
    wire        [15:0] o_pen  = (outlier_q15 >= 16'd6553) ? 16'd32767 :        // 0.20
                                o_num[47:0] / 48'sd6553;

    // ---- 质量分 ---------------------------------------------------------
    // q*32767 = 20 + 20*p + 15*s + 10*g + 10*dt - 20*o - (5 if harm)
    wire signed [47:0] q_terms =
        (48'sd20 * 48'sd32767)
      + (48'sd20 * $signed({1'b0, p_clip}))
      + (48'sd15 * $signed({1'b0, support_q15}))
      + (48'sd10 * $signed({1'b0, g_clip}))
      + (48'sd10 * $signed({1'b0, dt_clip}))
      - (48'sd20 * $signed({1'b0, o_pen}))
      - (harmonic_collision ? (48'sd5 * 48'sd32767) : 48'sd0);

    wire signed [47:0] q_div = (q_terms > 0) ? (q_terms / 48'sd32767) : 48'sd0;
    wire [15:0]        q_sat = (q_div > 48'sd300) ? 16'd300 : q_div[15:0];

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            decision       <= 3'd3;
            quality_q8     <= 16'd0;
            confidence_q15 <= 16'd0;
            busy           <= 1'b0;
            done           <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start) begin
                busy           <= 1'b1;
                confidence_q15 <= support_q15;
                quality_q8     <= {q_sat[7:0], 8'h00};   // Q8.8

                // ---- 硬性数据质量闸门 ------------------------------------
                if (out_of_range)
                    decision <= 3'd2;
                else if (motion_reject)
                    decision <= 3'd4;
                else if (no_candidate)
                    decision <= 3'd3;
                else if (outlier_q15 > 16'd3932)
                    decision <= 3'd4;
                else if (compet_vr_q15 < 16'd1638)
                    decision <= 3'd5;
                else if (vr_contrast_q12 < 32'd4710)
                    decision <= 3'd5;
                else if (support_q15 >= 16'd16384)
                    decision <= 3'd0;
                else
                    decision <= 3'd1;

                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule
