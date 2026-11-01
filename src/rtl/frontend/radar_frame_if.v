//=============================================================================
// radar_frame_if.v -- 雷达帧接口 / 通道解复用 / 分析窗门控
//-----------------------------------------------------------------------------
// 对应 Python:  dataio.load_radar()  +  estimator.estimate() 里的窗口切片
//
//   雷达张量 X : (M, R, B) complex  -> 硬件按帧串行输入：
//   每帧 80 个复数样本，顺序固定为 ch = rx*20 + bin  (ch = 0..79)。
//
// 功能
//   1) 为每个样本打上通道索引 tuser = ch
//   2) 统计帧号，产生 frame_sync / sof
//   3) 产生分析窗门控 win_active：
//        帧号 in [analysis_start_s*fs, (analysis_start_s+window_s)*fs)
//        即 [300, 900)  —— 对应 config.analysis_start_s=15 / window_s=30
//   4) 窗结束时输出 win_done 脉冲，作为下游估计引擎的启动触发
//
// 输入  s_axis : tdata = {Q[15:0], I[15:0]} (32b), tuser = sof
// 输出  m_axis : tdata 同宽, tuser = ch[6:0], tlast = 帧末
//=============================================================================
`timescale 1ns / 1ps

module radar_frame_if #(
    parameter integer N_RX   = 4,
    parameter integer N_BINS = 20,
    parameter integer CH_W   = 7,
    parameter integer ACQ_START = 300,     // 15 s * 20 Hz
    parameter integer ACQ_LEN   = 600      // 30 s * 20 Hz
)(
    input  wire              aclk,
    input  wire              aresetn,

    input  wire [31:0]       s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    input  wire              s_axis_tuser,     // frame start
    input  wire              s_axis_tlast,

    output reg  [31:0]       m_axis_tdata,
    output reg               m_axis_tvalid,
    input  wire              m_axis_tready,
    output reg  [CH_W-1:0]   m_axis_tuser,     // 通道索引 ch
    output reg               m_axis_tlast,

    output reg               frame_sync,       // 每帧起点脉冲
    output reg               win_active,       // 分析窗内
    output reg               win_done,         // 分析窗结束脉冲
    output reg  [15:0]       frame_cnt         // 帧计数器
);

    localparam integer CH_PER_FRAME = N_RX * N_BINS;

    reg [CH_W-1:0] ch_cnt;

    assign s_axis_tready = m_axis_tready | ~m_axis_tvalid;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_axis_tdata  <= 32'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tuser  <= {CH_W{1'b0}};
            m_axis_tlast  <= 1'b0;
            ch_cnt        <= {CH_W{1'b0}};
            frame_sync    <= 1'b0;
            win_active    <= 1'b0;
            win_done      <= 1'b0;
            frame_cnt     <= 16'd0;
        end else begin
            frame_sync <= 1'b0;
            win_done   <= 1'b0;

            if (m_axis_tvalid && m_axis_tready)
                m_axis_tvalid <= 1'b0;

            if (s_axis_tvalid && s_axis_tready) begin
                // 帧起点：复位通道计数
                if (s_axis_tuser) begin
                    ch_cnt     <= {{(CH_W-1){1'b0}}, 1'b1};
                    frame_sync <= 1'b1;
                    // 帧号推进 + 窗口门控
                    if (frame_cnt == ACQ_START)
                        win_active <= 1'b1;
                    if (frame_cnt == (ACQ_START + ACQ_LEN - 1))
                        win_done <= 1'b1;
                    frame_cnt <= frame_cnt + 16'd1;
                end else begin
                    ch_cnt <= ch_cnt + 1'b1;
                end

                m_axis_tdata  <= s_axis_tdata;
                m_axis_tuser  <= ch_cnt;
                m_axis_tlast  <= (ch_cnt == CH_PER_FRAME - 1);
                m_axis_tvalid <= 1'b1;

                if (ch_cnt == CH_PER_FRAME - 1)
                    win_active <= 1'b0;
            end
        end
    end

endmodule
