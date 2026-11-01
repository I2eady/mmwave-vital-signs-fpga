//=============================================================================
// dacm_phase.v -- DACM 相位增量提取
//-----------------------------------------------------------------------------
// 对应 Python:  scr/dsp.py :: dacm_phase()
//
//     dphi[m] = ( I[m]*dQ[m] - Q[m]*dI[m] ) / ( I[m]^2 + Q[m]^2 )
//     dI = I[m] - I[m-1],  dQ = Q[m] - Q[m-1]
//
// 无需显式解卷绕，对低 SNR 幅度跌落与 2*pi 跳变鲁棒。
//
// 硬件要点
//   * 每个距离仓 (RX,bin) 各自独立维护上一帧 I/Q -> 80 组 prev 状态，
//     用分布式 RAM 实现（prev_i / prev_q 各 80 x 16bit）。
//   * 除以 (I^2+Q^2) 用逐位恢复除法器 u_div，约 56 拍完成；数据率仅
//     80 样本 / 50 ms，余量极大，无需全流水。
//
// 定点
//   输入  I,Q : s16  (Q1.15 归一化复样本)
//   输出  dphi: s24  Q4.20 (弧度，|dphi| <= 3.15 -> 3.3e6 LSB)
//=============================================================================
`timescale 1ns / 1ps

module dacm_phase #(
    parameter integer N_CH = 80,     // 通道数 = N_RX * N_BINS
    parameter integer CH_W = 7       // 通道索引位宽 (80 -> 7 bit)
)(
    input  wire              aclk,
    input  wire              aresetn,

    // ---- 从端：原始复数样本 {Q[15:0], I[15:0]} ---------------------------
    input  wire [31:0]       s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    input  wire [CH_W-1:0]   s_axis_tuser,     // 距离仓通道索引
    input  wire              s_axis_tlast,

    // ---- 主端：相位增量 {8'h00, dphi[23:0]} -----------------------------
    output reg  [31:0]       m_axis_tdata,
    output reg               m_axis_tvalid,
    input  wire              m_axis_tready,
    output reg  [CH_W-1:0]   m_axis_tuser,
    output reg               m_axis_tlast
);

    localparam S_IDLE = 1'b0;
    localparam S_CALC = 1'b1;

    reg               state;
    reg               sign_r;
    reg               div_start;

    // 每通道上一帧 I/Q
    reg signed [15:0] prev_i [0:N_CH-1];
    reg signed [15:0] prev_q [0:N_CH-1];

    reg signed [15:0] i_r, q_r;
    reg signed [16:0] di_r, dq_r;
    reg [CH_W-1:0]    ch_r;
    reg               last_r;

    // ---- 组合运算 --------------------------------------------------------
    // num = I*dQ - Q*dI  (s34)
    wire signed [32:0] p1  = i_r * dq_r;
    wire signed [32:0] p2  = q_r * di_r;
    wire signed [33:0] num = {p1[32], p1} - {p2[32], p2};

    // den = I^2 + Q^2  (u32)
    wire        [31:0] den = (i_r * i_r) + (q_r * q_r);

    wire signed [33:0] num_neg = -num;
    wire        [33:0] num_abs = num[33] ? num_neg[33:0] : num[33:0];
    wire               num_sgn = num[33];

    // ---- 除法器 ----------------------------------------------------------
    wire        div_go    = (state == 1'b1) && !div_busy && !div_valid && !m_axis_tvalid;  // 1'b1 = S_CALC
    wire        div_valid;
    wire [23:0] div_q;
    wire        div_sat;
    wire        div_busy;

    u_div #(
        .W_A   (34),
        .W_B   (32),
        .SHIFT (20),
        .W_Q   (24)
    ) u_dacm_div (
        .clk     (aclk),
        .rst_n   (aresetn),
        .i_valid (div_start && div_go),
        .i_a     (num_abs),
        .i_b     (den),
        .o_valid (div_valid),
        .o_q     (div_q),
        .o_sat   (div_sat),
        .o_busy  (div_busy)
    );

    assign s_axis_tready = (state == S_IDLE) && !m_axis_tvalid && aresetn;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state         <= S_IDLE;
            div_start     <= 1'b0;
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= 32'd0;
            m_axis_tuser  <= {CH_W{1'b0}};
            m_axis_tlast  <= 1'b0;
            i_r  <= 16'sd0; q_r <= 16'sd0;
            di_r <= 17'sd0; dq_r <= 17'sd0;
            ch_r <= {CH_W{1'b0}};
            last_r <= 1'b0;
            sign_r <= 1'b0;
        end else begin
            div_start <= 1'b0;

            if (m_axis_tvalid && m_axis_tready)
                m_axis_tvalid <= 1'b0;

            case (state)
            //-----------------------------------------------------------------
            S_IDLE: begin
                if (s_axis_tvalid && s_axis_tready) begin
                    i_r    <= s_axis_tdata[15:0];
                    q_r    <= s_axis_tdata[31:16];
                    di_r   <= $signed(s_axis_tdata[15:0])  - $signed(prev_i[s_axis_tuser]);
                    dq_r   <= $signed(s_axis_tdata[31:16]) - $signed(prev_q[s_axis_tuser]);
                    ch_r   <= s_axis_tuser;
                    last_r <= s_axis_tlast;
                    prev_i[s_axis_tuser] <= s_axis_tdata[15:0];
                    prev_q[s_axis_tuser] <= s_axis_tdata[31:16];
                    state  <= S_CALC;
                end
            end
            //-----------------------------------------------------------------
            S_CALC: begin
                if (div_go) begin
                    sign_r    <= num_sgn;
                    div_start <= 1'b1;
                end
                if (div_valid) begin
                    m_axis_tdata  <= {8'h00, sign_r ? (-div_q) : div_q};
                    m_axis_tuser  <= ch_r;
                    m_axis_tlast  <= last_r;
                    m_axis_tvalid <= 1'b1;
                    state         <= S_IDLE;
                end
            end
            endcase
        end
    end

endmodule
