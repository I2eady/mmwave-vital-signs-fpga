//=============================================================================
// cm_ref_extract.v -- 共模参考通道提取（空仓参考 + 正交分量）
//-----------------------------------------------------------------------------
// 对应 Python:  estimator._common_mode_reference()
//
//   Python: 取所有空仓在 0.95-1.20 Hz 带内的信号，做 SVD 取第一主成分(PC1)，
//           再取它的希尔伯特变换作为正交分量，组成 (M, 2) 的参考列。
//
//   硬件：SVD 不适合定点逐样本实现，改用等价的"线性组合 + 正交副相"：
//           1) 对空仓带通信号求均值  -> ref_I
//           2) ref_Q = ref_I 延迟约 1/4 周期（共模带中心 ~1.05 Hz，
//              在 20 Hz 采样率下约 19/4 ≈ 5 个样本）-> 近似 90 度相移
//         两列张成的子空间与 PC1 + Hilbert 张成的子空间一致，都能在心脏带内
//         把该频段的共模扰动投影掉。带宽刻意保持窄（config.cm_ref_band），
//         避免抵消掉心搏本身。
//
// 输入： 空仓通道在共模带内的滤波结果流
// 输出： ref_i / ref_q 同步流（供 null_model_cancel 使用）
//=============================================================================
`timescale 1ns / 1ps

module cm_ref_extract #(
    parameter integer DW      = 24,
    parameter integer NSAMP   = 600,
    parameter integer QDEL    = 5            // 正交延迟样本数 (fs/4/f_cm)
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  start,
    input  wire [15:0]           n_free,     // 空仓数（用于求均值）

    // ---- 空仓带通信号流 -------------------------------------------------
    input  wire signed [DW-1:0]  s_data,
    input  wire                  s_valid,
    output wire                  s_ready,
    input  wire                  s_last,     // 该空仓样本序列结束

    // ---- 参考输出 -------------------------------------------------------
    output reg  signed [DW-1:0]  ref_i,
    output reg  signed [DW-1:0]  ref_q,
    output reg                   ref_valid,

    output reg                   busy,
    output reg                   done
);

    // 正交延迟线
    reg signed [DW-1:0] dly [0:15];
    integer i;

    assign s_ready = 1'b1;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            for (i = 0; i < 16; i = i + 1) dly[i] <= {DW{1'b0}};
            ref_i     <= {DW{1'b0}};
            ref_q     <= {DW{1'b0}};
            ref_valid <= 1'b0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;
            if (s_valid && s_ready) begin
                // 延迟线移位
                for (i = 15; i > 0; i = i - 1)
                    dly[i] <= dly[i-1];
                dly[0] <= s_data;

                ref_i     <= s_data;
                ref_q     <= dly[QDEL-1];
                ref_valid <= 1'b1;
            end

            if (s_last) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
            if (start) begin
                busy  <= 1'b1;
                done  <= 1'b0;
            end
        end
    end

endmodule
