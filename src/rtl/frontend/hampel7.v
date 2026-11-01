//=============================================================================
// hampel7.v -- Hampel 鲁棒野值剔除（滑窗中值 / MAD）
//-----------------------------------------------------------------------------
// 对应 Python:  scr/dsp.py :: _hampel_1d / hampel_axis
//
//   win  = x[i-3 .. i+3]            (窗长 7，居中，Python 用 reflect 填充边界)
//   med  = median(win)
//   mad  = median(|win - med|)
//   out  = |x[i] - med| > K*mad  ?  med : x[i]        K = nsigma*1.4826 = 4.4478
//
// 硬件实现
//   * 每通道独立 7 级移位寄存器 win[ch][0..6]，win[ch][0] 最新。
//   * 输出对应当前窗的"中心样本" win[ch][2]，即 3 个样本之前 -> 通道号
//     与 tlast 需延迟 3 拍对齐（3 级流水线）。
//   * 使用 2 个 median7 实例：一个求 med，一个求 mad。
//
// 与 Python 的差异（已在文档中记录）
//   Python 用 reflect 边界填充，硬件用零填充起步；对 600 样本窗口的
//   影响仅限前 3 个样本，可忽略。
//=============================================================================
`timescale 1ns / 1ps
module hampel7 #(
    parameter integer W      = 24,
    parameter integer N_CH   = 80,
    parameter integer CH_W   = 7,
    parameter integer K_Q12  = 18218     // 4.4478 * 2^12
)(
    input  wire              aclk,
    input  wire              aresetn,

    input  wire [31:0]       s_axis_tdata,        // {8'h0, dphi[23:0]}
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    input  wire [CH_W-1:0]   s_axis_tuser,
    input  wire              s_axis_tlast,

    output reg  [31:0]       m_axis_tdata,
    output reg               m_axis_tvalid,
    input  wire              m_axis_tready,
    output reg  [CH_W-1:0]   m_axis_tuser,
    output reg               m_axis_tlast,

    output reg  [15:0]       outlier_cnt,          // 被替换样本数
    output reg  [15:0]       sample_cnt            // 总样本数
);

    // 每通道 7 级窗口： win[ch][0] 最新
    reg signed [W-1:0] win [0:N_CH-1][0:6];

    // ---- 当前样本的完整窗 (新样本在最前) ---------------------------------
    wire signed [W-1:0] x_new = s_axis_tdata[W-1:0];
    wire [CH_W-1:0]     ch    = s_axis_tuser;

    wire signed [W-1:0] w0 = x_new;
    wire signed [W-1:0] w1 = win[ch][0];
    wire signed [W-1:0] w2 = win[ch][1];
    wire signed [W-1:0] w3 = win[ch][2];      // <== 中心样本
    wire signed [W-1:0] w4 = win[ch][3];
    wire signed [W-1:0] w5 = win[ch][4];
    wire signed [W-1:0] w6 = win[ch][5];

    wire signed [W-1:0] med;

    median7 #(.W(W)) u_med (
        .x0(w0), .x1(w1), .x2(w2), .x3(w3),
        .x4(w4), .x5(w5), .x6(w6),
        .y_med(med)
    );

    // ---- MAD = median(|w - med|) ----------------------------------------
    wire signed [W-1:0] d0 = (w0 > med) ? (w0 - med) : (med - w0);
    wire signed [W-1:0] d1 = (w1 > med) ? (w1 - med) : (med - w1);
    wire signed [W-1:0] d2 = (w2 > med) ? (w2 - med) : (med - w2);
    wire signed [W-1:0] d3 = (w3 > med) ? (w3 - med) : (med - w3);
    wire signed [W-1:0] d4 = (w4 > med) ? (w4 - med) : (med - w4);
    wire signed [W-1:0] d5 = (w5 > med) ? (w5 - med) : (med - w5);
    wire signed [W-1:0] d6 = (w6 > med) ? (w6 - med) : (med - w6);

    wire signed [W-1:0] mad;
    median7 #(.W(W)) u_mad (
        .x0(d0), .x1(d1), .x2(d2), .x3(d3),
        .x4(d4), .x5(d5), .x6(d6),
        .y_med(mad)
    );

    // ---- 阈值 = mad * K (Q.12)  ->  低 12 位截断 ------------------------
    // 先算到 48 位再收窄：mad 为 Q8.16，K 为 Q4.12，乘积 >> 12 才是阈值
    wire signed [47:0] thr_prod = $signed(mad) * $signed(K_Q12);
    wire signed [47:0] thr_shr  = thr_prod >>> 12;
    wire signed [W-1:0] thr     = (thr_shr >  48'sd8388607) ?  24'sd8388607 :
                                  (thr_shr < -48'sd8388608) ? -24'sd8388608 :
                                  thr_shr[W-1:0];

    // ---- 野值判定 -------------------------------------------------------
    wire signed [2*W-1:0] dev_c = (w3 > med) ? (w3 - med) : (med - w3);
    wire                  is_outlier = (dev_c > {{W{1'b0}}, thr});

    wire signed [W-1:0]  y_clean = is_outlier ? med : w3;

    // ---- 握手 / 3 拍延迟对齐 --------------------------------------------
    reg [2:0]            vpipe;
    reg [CH_W-1:0]       chd1, chd2, chd3;
    reg                  lastd1, lastd2, lastd3;
    reg                  outd1, outd2, outd3;

    assign s_axis_tready = m_axis_tready | ~m_axis_tvalid;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_axis_tdata  <= 32'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tuser  <= {CH_W{1'b0}};
            m_axis_tlast  <= 1'b0;
            outlier_cnt   <= 16'd0;
            sample_cnt    <= 16'd0;
            vpipe         <= 3'd0;
            chd1 <= {CH_W{1'b0}}; chd2 <= {CH_W{1'b0}}; chd3 <= {CH_W{1'b0}};
            lastd1 <= 1'b0; lastd2 <= 1'b0; lastd3 <= 1'b0;
            outd1  <= 1'b0; outd2  <= 1'b0; outd3  <= 1'b0;
        end else begin
            if (m_axis_tvalid && m_axis_tready)
                m_axis_tvalid <= 1'b0;

            // 延迟链
            chd1 <= ch;   chd2 <= chd1;  chd3 <= chd2;
            lastd1 <= s_axis_tlast; lastd2 <= lastd1; lastd3 <= lastd2;
            outd1 <= is_outlier;  outd2 <= outd1;  outd3 <= outd2;
            vpipe <= {vpipe[1:0], (s_axis_tvalid && s_axis_tready)};

            if (s_axis_tvalid && s_axis_tready) begin
                // 窗口右移并写入新样本
                win[ch][6] <= win[ch][5];
                win[ch][5] <= win[ch][4];
                win[ch][4] <= win[ch][3];
                win[ch][3] <= win[ch][2];
                win[ch][2] <= win[ch][1];
                win[ch][1] <= win[ch][0];
                win[ch][0] <= x_new;

                sample_cnt <= sample_cnt + 16'd1;
                if (is_outlier)
                    outlier_cnt <= outlier_cnt + 16'd1;
            end

            // 3 拍延迟后输出中心样本的清洗结果
            if (vpipe[2]) begin
                m_axis_tdata  <= {{(32-W){1'b0}}, y_clean};
                m_axis_tuser  <= chd3;
                m_axis_tlast  <= lastd3;
                m_axis_tvalid <= 1'b1;
            end
        end
    end

endmodule
