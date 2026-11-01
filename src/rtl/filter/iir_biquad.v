//=============================================================================
// iir_biquad.v -- 二阶 IIR 节（Direct-Form II Transposed）
//-----------------------------------------------------------------------------
// 对应 Python:  dsp.bandpass_axis() 中 butter(order=4, btype='band') 的每个二阶节
//
//   y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] + a1n*y[n-1] + a2n*y[n-2]
//   其中 a1n = -a1, a2n = -a2（系数表已取负，便于加法实现）
//
// 定点
//   x, y : s24 Q8.16
//   系数 : s18 Q4.14   (与 DSP48E1 的 25x18 乘法器原生匹配)
//   累加 : s48         (Q12.30)
//   内部瞬时 y_int = 累加器取全精度 -> 反馈项用 24bit 量化，相对误差 2^-16，
//   远小于系数量化误差 2^-14，可忽略。
//
// 吞吐：1 样本/拍（20 Hz 数据率下无压力，不做流水）
//=============================================================================
`timescale 1ns / 1ps

module iir_biquad #(
    parameter integer DW = 24,      // 数据位宽 (Q8.16)
    parameter integer CW = 18       // 系数位宽 (Q4.14)
)(
    input  wire                    aclk,
    input  wire                    aresetn,
    input  wire                    clr,       // 清状态（每次滤波开始）
    input  wire                    ce,        // clock enable

    input  wire signed [DW-1:0]    x,
    input  wire signed [CW-1:0]    b0,
    input  wire signed [CW-1:0]    b1,
    input  wire signed [CW-1:0]    b2,
    input  wire signed [CW-1:0]    a1n,
    input  wire signed [CW-1:0]    a2n,

    output reg  signed [DW-1:0]    y
);

    localparam integer FW  = 14;             // 系数小数位
    localparam integer ACC = DW + CW + 6;    // 48

    reg signed [ACC-1:0] s1, s2;

    wire signed [ACC-1:0] p0 = b0 * x;
    wire signed [ACC-1:0] p1 = b1 * x;
    wire signed [ACC-1:0] p2 = b2 * x;

    wire signed [ACC-1:0] y_acc = p0 + s1;
    wire signed [ACC-1:0] y_shr = y_acc >>> FW;          // Q8.16

    // 量化/饱和到 DW
    wire signed [DW-1:0] y_q =
        (y_shr > $signed({1'b0, {DW-1{1'b1}}}))  ? $signed({1'b0, {DW-1{1'b1}}})  :
        (y_shr < $signed({1'b1, {DW-1{1'b0}}}))  ? $signed({1'b1, {DW-1{1'b0}}})  :
        y_shr[DW-1:0];

    // 反馈项（用 24bit 量化后的 y，误差可忽略）
    wire signed [ACC-1:0] a1y = a1n * y_q;
    wire signed [ACC-1:0] a2y = a2n * y_q;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s1 <= 'sd0;
            s2 <= 'sd0;
            y  <= 'sd0;
        end else if (clr) begin
            s1 <= 'sd0;
            s2 <= 'sd0;
            y  <= 'sd0;
        end else if (ce) begin
            s1 <= p1 + s2 + a1y;
            s2 <= p2 + a2y;
            y  <= y_q;
        end
    end

endmodule
