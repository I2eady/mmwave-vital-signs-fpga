//=============================================================================
// vs_engine_fsm.v -- 估计引擎时序编排器
//-----------------------------------------------------------------------------
// 对应 Python:  estimator.py :: VitalSignsEstimator.estimate() 的控制流，
//   即"对整个 30 s 窗口、对每个候选 (bin,RX) 分量依次执行
//     呼吸带通 -> 呼吸谱峰 -> 心脏带通 -> 谐波/共模抵消 -> VR 频率扫描
//     -> 跨分量谱融合 -> 峰值搜索 -> 证书"
//   的调度部分。
//
// 之所以把 band/grid 的译码也放在这里（而不是用 BD 里的 AND 门），
// 是为了让 Block Design 里各引擎与编排器之间是直接的 1:1 控制线，
// 数据流图更干净可读。
//
// 时间预算（每条通道）:
//   呼吸: FIR 307k + DFT 91x600=54.6k  ≈ 0.36 M 拍
//   心脏: FIR 307k + DFT 201x600=120.6k ≈ 0.43 M 拍
//   约 40 个候选通道 -> 32 M 拍 = 320 ms @100 MHz，远小于 30 s 窗长
//=============================================================================
`timescale 1ns / 1ps
module vs_engine_fsm #(
    parameter integer NPTS_RESP = 91,
    parameter integer NPTS_VR   = 201
)(
    input  wire        aclk,
    input  wire        aresetn,

    input  wire        win_ready,          // 窗口数据就绪
    input  wire [19:0] bin_mask,           // 候选仓掩码
    input  wire [31:0] fr_inc_in,          // 呼吸率相位增量

    // ---- 谱累加器 -------------------------------------------------------
    output reg         accum_clr,

    // ---- 呼吸带 FIR -----------------------------------------------------
    output reg         bf_start_resp,
    input  wire        bf_done_resp,

    // ---- 心脏带 FIR -----------------------------------------------------
    output reg         bf_start_card,
    input  wire        bf_done_card,

    // ---- 零模型抵消 -----------------------------------------------------
    output reg         nc_clr,

    // ---- DFT 扫描 -------------------------------------------------------
    output reg         gz_start_resp,
    input  wire        gz_done_resp,
    output reg         gz_start_vr,
    input  wire        gz_done_vr,
    output reg  [7:0]  gz_npts,

    // ---- 峰值搜索 -------------------------------------------------------
    output reg         pk_start,
    output reg         pk_sel,             // 0=呼吸 1=心率/VR
    output reg  [7:0]  pk_npts,             // 送给 peak_argmax 的网格点数
    input  wire        pk_done,

    // ---- 证书 -----------------------------------------------------------
    output reg         cert_start,
    input  wire        cert_done,

    output reg  [15:0] bf_base_addr,
    output reg  [31:0] fr_inc_out,
    output reg         meas_done,
    output reg         win_start,          // 一次测量结束 -> 让窗口存储器重开一窗
    output wire        busy,               // 引擎不在 IDLE
    output reg  [3:0]  state_dbg
);


    localparam [3:0] S_IDLE   = 4'd0,
                     S_CLR    = 4'd1,
                     S_R_REQ  = 4'd2,   // 发起一次呼吸带 FIR
                     S_R_BFW  = 4'd3,   // 等 FIR 完成
                     S_R_GZW  = 4'd4,   // 呼吸 DFT 完成
                     S_R_PK   = 4'd5,
                     S_C_REQ  = 4'd6,
                     S_C_BFW  = 4'd7,
                     S_C_GZW  = 4'd8,   // 心脏 DFT 完成
                     S_C_PK   = 4'd9,
                     S_CERT   = 4'd10,
                     S_DONE   = 4'd11;

    reg [3:0] state;
    reg [6:0] ch;
    reg [4:0] clr_cnt;

    wire bin_hit = bin_mask[ch % 20];
    wire last_ch = (ch == 7'd79);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state          <= S_IDLE;
            ch             <= 7'd0;
            clr_cnt        <= 5'd0;
            accum_clr      <= 1'b0;
            bf_start_resp  <= 1'b0;
            bf_start_card  <= 1'b0;
            nc_clr         <= 1'b0;
            gz_start_resp  <= 1'b0;
            gz_start_vr    <= 1'b0;
            gz_npts        <= 8'd0;
            pk_start       <= 1'b0;
            pk_sel         <= 1'b0;
            pk_npts        <= 8'd0;
            cert_start     <= 1'b0;
            bf_base_addr   <= 16'd0;
            fr_inc_out     <= 32'd0;
            meas_done      <= 1'b0;
            win_start      <= 1'b0;
            state_dbg      <= 4'd0;
        end else begin
            bf_start_resp <= 1'b0;
            bf_start_card <= 1'b0;
            gz_start_resp <= 1'b0;
            gz_start_vr   <= 1'b0;
            pk_start      <= 1'b0;
            cert_start    <= 1'b0;
            meas_done     <= 1'b0;
            win_start     <= 1'b0;
            accum_clr     <= 1'b0;
            nc_clr        <= 1'b0;
            state_dbg     <= state;

            case (state)
            //-------------------------------------------------------------
            S_IDLE: begin
                ch <= 7'd0;
                if (win_ready) state <= S_CLR;
            end
            //-------------------------------------------------------------
            S_CLR: begin
                accum_clr <= 1'b1;
                clr_cnt   <= clr_cnt + 5'd1;
                if (clr_cnt == 5'd15) begin
                    clr_cnt <= 5'd0;
                    ch      <= 7'd0;
                    state   <= S_R_REQ;
                end
            end
            //-------------------------------------------------------------
            S_R_REQ: begin
                if (bin_hit) begin
                    bf_base_addr  <= {9'd0, ch};
                    bf_start_resp <= 1'b1;
                    state         <= S_R_BFW;
                end else if (last_ch) begin
                    state <= S_R_PK;
                end else begin
                    ch <= ch + 7'd1;
                end
            end
            //-------------------------------------------------------------
            S_R_BFW: begin
                if (bf_done_resp) begin
                    gz_npts      <= NPTS_RESP;
                    gz_start_resp<= 1'b1;
                    state        <= S_R_GZW;
                end
            end
            //-------------------------------------------------------------
            S_R_GZW: begin
                if (gz_done_resp) begin
                    if (last_ch) begin
                        state <= S_R_PK;
                    end else begin
                        ch    <= ch + 7'd1;
                        state <= S_R_REQ;
                    end
                end
            end
            //-------------------------------------------------------------
            S_R_PK: begin
                pk_sel   <= 1'b0;
                pk_npts  <= NPTS_RESP;
                pk_start <= 1'b1;
                if (pk_done) begin           // 呼吸峰已就绪
                    fr_inc_out <= fr_inc_in;
                    ch         <= 7'd0;
                    state      <= S_C_REQ;
                end
            end
            //-------------------------------------------------------------
            S_C_REQ: begin
                if (bin_hit) begin
                    bf_base_addr  <= {9'd0, ch};
                    bf_start_card <= 1'b1;
                    state         <= S_C_BFW;
                end else if (last_ch) begin
                    state <= S_C_PK;
                end else begin
                    ch <= ch + 7'd1;
                end
            end
            //-------------------------------------------------------------
            S_C_BFW: begin
                if (bf_done_card) begin
                    nc_clr      <= 1'b1;
                    gz_npts     <= NPTS_VR;
                    gz_start_vr <= 1'b1;
                    state       <= S_C_GZW;
                end
            end
            //-------------------------------------------------------------
            S_C_GZW: begin
                if (gz_done_vr) begin
                    if (last_ch) begin
                        state <= S_C_PK;
                    end else begin
                        ch    <= ch + 7'd1;
                        state <= S_C_REQ;
                    end
                end
            end
            //-------------------------------------------------------------
            S_C_PK: begin
                pk_sel   <= 1'b1;
                pk_npts  <= NPTS_VR;
                pk_start <= 1'b1;
                state    <= S_CERT;
            end
            //-------------------------------------------------------------
            S_CERT: begin
                if (pk_done) begin
                    cert_start <= 1'b1;
                    state      <= S_DONE;
                end
            end
            //-------------------------------------------------------------
            S_DONE: begin
                if (cert_done) begin
                    meas_done <= 1'b1;
                    win_start <= 1'b1;   // 窗口存储器重开一窗，开始下一次测量
                    state     <= S_IDLE;
                end
            end
            default: state <= S_IDLE;
            endcase
        end
    end

    // 给 result_out 的忙碌指示
    assign busy = (state != S_IDLE);

endmodule
