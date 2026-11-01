//=============================================================================
// ratio_q15.v -- peak / sum  ->  Q1.15 竞争比
//-----------------------------------------------------------------------------
// 对应 Python (estimator.py):
//   competitive_vr = vr_curve[k_best] / vr_curve.sum()      # 与 vr_min=0.05 比
//
// peak_argmax 输出的 peak_val / sum_val 都是 32 位累加幅度，量纲一致，所以
// 直接相除就是无量纲的竞争比。这里把结果归一到 Q1.15（乘 2^15 后饱和到
// 16 位），与 certificate_fsm 里的门限 `compet_vr_q15 < 1638 (=0.05)` 对齐。
//
// 除法是纯组合的 48 位除法器，由 pk_done 脉冲触发锁存；不需要流水时序，
// 因为一个测量周期里它只被触发两次（呼吸峰 + VR 峰），且 VR 峰在最后，
// 所以锁存下来的永远是 VR 那次的结果。
//=============================================================================
`timescale 1ns / 1ps

module ratio_q15 (
    input  wire            aclk,
    input  wire            aresetn,

    input  wire            load,          // vs_engine.pk_done
    input  wire [31:0]     num,           // peak_argmax.peak_val
    input  wire [31:0]     den,           // peak_argmax.sum_val

    output reg  [15:0]     ratio_q15
);

    wire [63:0] raw = (den == 32'd0) ? 64'd0
                    : (({32'd0, num} << 15) / {32'd0, den});

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)  ratio_q15 <= 16'd0;
        else if (load) ratio_q15 <= (raw > 64'd65535) ? 16'hFFFF : raw[15:0];
    end

endmodule
