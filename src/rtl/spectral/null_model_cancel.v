//=============================================================================
// null_model_cancel.v -- 零模型自适应抵消（呼吸谐波 + 共模参考）
//-----------------------------------------------------------------------------
// 对应 Python:
//   estimator._harmonic_residual()   呼吸谐波最小二乘回归
//   estimator._vr_sweep() 中的 QR 正交化（零模型 A 的投影）
//   estimator._common_mode_reference()  共模参考列
//
// Python 用 np.linalg.lstsq / np.linalg.qr 做一次性批处理最小二乘；
// 硬件用 LMS 自适应抵消实现同一目标函数（把已知频率的干扰从心脏带残差里
// 减去），两者在干扰频率处的稳态解一致：
//
//   零模型 A = span{ 1, sin/cos(k*w_r) k=2..12, ref_I, ref_Q }
//   残差     e = x - sum_k (a_k*sin_k + b_k*cos_k) - (c_I*ref_I + c_Q*ref_Q)
//   LMS 更新  w <- w + mu * e * u
//   定点换算：e 为 Q8.16 且 u 为 Q1.15 时乘积在 2^31 尺度，
//   MU_SHIFT=22 -> 增量落在 2^9 尺度，而 w 是 Q8.16(2^16 尺度)，
//   故等效步长 mu = 2^(9-16) = 2^-7 ≈ 0.0078。
//
// 硬件差异（已在文档记录）
//   * 常数项（DC）由上游心脏带通已去除，不再显式建模。
//   * 谐波阶数 2..12（config.harmonic_max_order = 12）。
//   * 共模参考用"空仓带通信号的加权均值 + 其 90 度相移"，替代 SVD 的主成分，
//     省掉 80x80 矩阵奇异值分解 —— 这是本移植最主要的近似。
//
// 定点
//   x, e : s24 Q8.16 ； sin/cos : s16 Q1.15 ； 权重 w : s24 Q8.16
//=============================================================================
`timescale 1ns / 1ps

module null_model_cancel #(
    parameter integer DW       = 24,
    parameter integer NHARM    = 11,        // k = 2..12
    parameter integer MU_SHIFT = 22,
    parameter         SMEM     = "sin_lut.mem"
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  start,
    input  wire [31:0]           fr_inc,     // 呼吸基频的相位增量 (rad/2pi * 2^32)
    input  wire                  clr,

    // ---- 主输入：心脏带残差 --------------------------------------------
    input  wire signed [DW-1:0]  s_data,
    input  wire                  s_valid,
    output wire                  s_ready,
    input  wire                  s_last,

    // ---- 共模参考通道（空仓） ------------------------------------------
    input  wire signed [DW-1:0]  ref_i,
    input  wire signed [DW-1:0]  ref_q,

    // ---- 输出：抵消后残差 ----------------------------------------------
    output reg  signed [DW-1:0]  m_data,
    output reg                   m_valid,
    input  wire                  m_ready
);

    //-----------------------------------------------------------------------
    // 12 个谐波相位累加器 + sin/cos LUT
    //-----------------------------------------------------------------------
    reg [31:0] ph [0:11];
    wire signed [15:0] sin_v [0:11];
    wire signed [15:0] cos_v [0:11];

    genvar g;
    generate
        for (g = 0; g < 12; g = g + 1) begin : G_HARM
            sin_lut #(.AW(12), .MEM(SMEM)) u_lut (
                .clk   (aclk),
                .phase (ph[g]),
                .sin_o (sin_v[g]),
                .cos_o (cos_v[g])
            );
        end
    endgenerate

    //-----------------------------------------------------------------------
    // LMS 权重： 22 个谐波抽头 + 2 个共模抽头
    //-----------------------------------------------------------------------
    reg signed [DW-1:0] w_s [0:NHARM-1];
    reg signed [DW-1:0] w_c [0:NHARM-1];
    reg signed [DW-1:0] w_ri, w_rq;

    // 更新量中间寄存器（48 位，保证乘积不被截断）
    reg signed [47:0] upd0, upd1;

    //-----------------------------------------------------------------------
    // 组合：y_hat 累加
    //-----------------------------------------------------------------------
    wire signed [DW-1:0] x_in = s_data;

    integer t;
    reg signed [48:0] acc_y;          // 49 位累加器

    // 24 位饱和：acc_y 溢出时不回绕（必须在调用点之前声明）
    function signed [23:0] sat24;
        input signed [48:0] v;
        begin
            if      (v >  48'sd8388607) sat24 =  24'sd8388607;
            else if (v < -48'sd8388608) sat24 = -24'sd8388608;
            else                        sat24 = v[23:0];
        end
    endfunction

    always @(*) begin
        acc_y = 49'sd0;
        for (t = 0; t < NHARM; t = t + 1) begin
            acc_y = acc_y + (w_s[t] * sin_v[t+1]) + (w_c[t] * cos_v[t+1]);
        end
        acc_y = acc_y + (w_ri * ref_i) + (w_rq * ref_q);
    end

    wire signed [DW-1:0] y_hat = sat24(acc_y >>> 15);   // Q8.16（带饱和）
    wire signed [DW-1:0] err   = x_in - y_hat;

    //-----------------------------------------------------------------------
    // 权重更新（组合计算，时序写入）
    //-----------------------------------------------------------------------
    wire signed [DW-1:0] e_s = err;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            for (t = 0; t < 12; t = t + 1) ph[t] <= 32'd0;
            for (t = 0; t < NHARM; t = t + 1) begin
                w_s[t] <= {DW{1'b0}};
                w_c[t] <= {DW{1'b0}};
            end
            w_ri <= {DW{1'b0}};
            w_rq <= {DW{1'b0}};
            m_data  <= {DW{1'b0}};
            m_valid <= 1'b0;
        end else begin
            if (m_valid && m_ready) m_valid <= 1'b0;

            if (clr) begin
                for (t = 0; t < NHARM; t = t + 1) begin
                    w_s[t] <= {DW{1'b0}};
                    w_c[t] <= {DW{1'b0}};
                end
                w_ri <= {DW{1'b0}};
                w_rq <= {DW{1'b0}};
            end

            if (s_valid && s_ready) begin
                // 相位推进：第 g 个累加器对应谐波 k = g+1
                for (t = 0; t < 12; t = t + 1)
                    ph[t] <= ph[t] + (fr_inc * (t + 1));

                // 权重更新。
                // 注意：必须先把乘积算进 48 位中间量再右移。若直接写
                //   w_s[t] <= w_s[t] + ((e_s * sin_v[t+1]) >>> MU_SHIFT);
                // 由于赋值上下文只有 24 位，乘法会被截断到 24 位，
                // 右移 22 位后几乎恒为 0，自适应完全不动。
                for (t = 0; t < NHARM; t = t + 1) begin
                    upd0 = ($signed(e_s) * $signed(sin_v[t+1])) >>> MU_SHIFT;
                    upd1 = ($signed(e_s) * $signed(cos_v[t+1])) >>> MU_SHIFT;
                    w_s[t] <= w_s[t] + upd0[23:0];
                    w_c[t] <= w_c[t] + upd1[23:0];
                end
                upd0 = ($signed(e_s) * $signed(ref_i)) >>> MU_SHIFT;
                upd1 = ($signed(e_s) * $signed(ref_q)) >>> MU_SHIFT;
                w_ri <= w_ri + upd0[23:0];
                w_rq <= w_rq + upd1[23:0];

                m_data  <= err;
                m_valid <= 1'b1;
            end
        end
    end

    assign s_ready = m_ready | ~m_valid;

endmodule
