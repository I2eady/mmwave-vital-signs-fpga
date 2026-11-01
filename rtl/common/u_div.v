//=============================================================================
// u_div.v -- 参数化无符号流水除法器 (逐位恢复余数法 / restoring division)
//-----------------------------------------------------------------------------
// 功能： q = (a << SHIFT) / b ，商饱和到 W_Q 位；b==0 时输出全 1（饱和）。
//        对应 Python 中所有 "除法" 语义（DACM 归一化、去趋势斜率、距离->bin 等）。
//
// 用法示例（DACM 归一化，见 dacm_phase.v）：
//   a = |I*dQ - Q*dI|  (34 bit), b = I^2+Q^2 (32 bit), SHIFT = 20
//   -> q 为 Q4.20 的 |dphi|
//
// 算法： 标准长除法，商从 MSB 到 LSB 逐位产生。
//          rem = 0
//          for i = W_N-1 downto 0:
//              rem = (rem<<1) | num[i]
//              if rem >= den: rem -= den; q[i] = 1 else q[i] = 0
//        只保留 q[W_Q-1:0]；若 q 的高位曾置 1 则饱和到全 1。
//
// 延迟： W_A + SHIFT + 1 拍；吞吐：单发单收（不流水）。
// 80 通道 x 20 Hz 场景下占用率 < 1%，无需全流水。
//=============================================================================
`timescale 1ns / 1ps

module u_div #(
    parameter integer W_A   = 34,   // 被除数位宽
    parameter integer W_B   = 32,   // 除数位宽
    parameter integer SHIFT = 20,   // 被除数左移位数（决定小数精度）
    parameter integer W_Q   = 24    // 商位宽（饱和上限）
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              i_valid,
    input  wire [W_A-1:0]    i_a,
    input  wire [W_B-1:0]    i_b,
    output reg               o_valid,
    output reg  [W_Q-1:0]    o_q,
    output reg               o_sat,
    output wire              o_busy
);

    localparam integer W_N   = W_A + SHIFT;   // 移位后分子总位宽
    localparam integer W_REM = W_B + 1;       // 余数寄存器位宽
    localparam integer W_IDX = (W_N <= 2) ? 1 : $clog2(W_N + 1);

    reg  [W_N-1:0]   num_r;
    reg  [W_B-1:0]   den_r;
    reg  [W_REM-1:0] rem_r;
    reg  [W_Q-1:0]   quo_r;
    reg  [W_IDX-1:0] idx_r;
    reg              ovf_r;
    reg              run_r;

    assign o_busy = run_r;

    //-------------------------------------------------------------------------
    // 组合逻辑：一次余数迭代
    //-------------------------------------------------------------------------
    wire [W_REM-1:0] rem_shift = {rem_r[W_REM-2:0], num_r[idx_r - 1'b1]};
    wire             ge        = (rem_shift >= {1'b0, den_r});
    wire [W_REM-1:0] rem_next  = ge ? (rem_shift - {1'b0, den_r}) : rem_shift;
    wire             qbit      = ge;
    // 本次产生的商位在 quo_r 中的位置（idx_r-1 == 位序）
    wire             in_q      = (idx_r <= W_Q[W_IDX-1:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_r   <= 1'b0;
            o_valid <= 1'b0;
            o_q     <= {W_Q{1'b0}};
            o_sat   <= 1'b0;
            num_r   <= {W_N{1'b0}};
            den_r   <= {W_B{1'b0}};
            rem_r   <= {W_REM{1'b0}};
            quo_r   <= {W_Q{1'b0}};
            idx_r   <= {W_IDX{1'b0}};
            ovf_r   <= 1'b0;
        end else begin
            o_valid <= 1'b0;

            if (!run_r) begin
                if (i_valid) begin
                    if (i_b == {W_B{1'b0}}) begin      // 除零 -> 饱和
                        o_q     <= {W_Q{1'b1}};
                        o_sat   <= 1'b1;
                        o_valid <= 1'b1;
                    end else begin
                        num_r <= {{SHIFT{1'b0}}, i_a};
                        den_r <= i_b;
                        rem_r <= {W_REM{1'b0}};
                        quo_r <= {W_Q{1'b0}};
                        idx_r <= W_N[W_IDX-1:0];
                        ovf_r <= 1'b0;
                        run_r <= 1'b1;
                    end
                end
            end else begin
                rem_r <= rem_next;
                if (in_q)
                    quo_r[idx_r - 1'b1] <= qbit;       // 直接按位写入，MSB 先出
                else if (qbit)
                    ovf_r <= 1'b1;                     // 超出 W_Q 位 -> 饱和标记

                idx_r <= idx_r - 1'b1;
                if (idx_r == {{(W_IDX-1){1'b0}}, 1'b1}) begin
                    run_r   <= 1'b0;
                    o_valid <= 1'b1;
                    o_sat   <= ovf_r;
                    o_q     <= ovf_r ? {W_Q{1'b1}} : (in_q && qbit ? {qbit, quo_r[W_Q-1:1]} : quo_r);
                end
            end
        end
    end

endmodule
