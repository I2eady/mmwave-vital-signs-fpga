//=============================================================================
// biquad_cascade.v -- 零相位带通级联（前向 + 反向双向滤波）
//-----------------------------------------------------------------------------
// 对应 Python:  dsp.bandpass_axis() = scipy.signal.filtfilt(...)
//
//   filtfilt 做两次因果滤波（正向 + 反向），等效零相位、阶数翻倍。
//   硬件等价实现：
//       正向： 窗口存储器 mem[base + n*N_CH] -> 4 级 biquad 级联 -> mid_ram[n]
//       反向： mid_ram 逆序读出               -> 同样 4 级 biquad 级联 -> m_axis
//     两级串联即 8 阶零相位带通，与 Butterworth(order=4) + filtfilt 等价。
//
// 时序： BRAM(1) + 输入寄存(1) + 4 级 biquad = 6 拍流水
//
// 数据流
//   mem_*  <- integrate_detrend 的窗口存储器（地址 = base_addr + n*80）
//   m_*    -> goertzel_sweep / null_model_cancel / cm 参考提取
//=============================================================================
`timescale 1ns / 1ps

module biquad_cascade #(
    parameter integer DW      = 24,
    parameter integer CW      = 18,
    parameter integer NSEC    = 4,
    parameter integer NSAMP   = 600,
    parameter integer N_CH    = 80,
    parameter integer ADDR_W  = 16,
    parameter         CMEM    = "coeff_rom.mem"
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  start,        // 启动一次双向滤波
    input  wire [ADDR_W-1:0]     base_addr,    // 通道在窗口存储器中的基址 (=ch)
    input  wire [1:0]            band_sel,     // 0=呼吸 1=心脏 2=共模 3=自适应

    output reg                   busy,
    output reg                   done,

    // ---- 窗口存储器读端口 ----------------------------------------------
    output reg  [ADDR_W-1:0]     mem_addr,
    input  wire signed [DW-1:0]  mem_data,

    // ---- 滤波结果流 -----------------------------------------------------
    output reg  signed [DW-1:0]  m_data,
    output reg                   m_valid,
    input  wire                  m_ready
);

    localparam integer PIPE = 6;               // 流水深度
    localparam [10:0]  NONE_11 = NSAMP[10:0];

    //-----------------------------------------------------------------------
    // 4 级 biquad 级联
    //-----------------------------------------------------------------------
    reg                  chain_clr;
    reg                  chain_ce;

    wire signed [DW-1:0] q0, q1, q2, q3;

    wire signed [CW-1:0] b0_0,b1_0,b2_0,a1_0,a2_0;
    wire signed [CW-1:0] b0_1,b1_1,b2_1,a1_1,a2_1;
    wire signed [CW-1:0] b0_2,b1_2,b2_2,a1_2,a2_2;
    wire signed [CW-1:0] b0_3,b1_3,b2_3,a1_3,a2_3;

    biquad_coeff_rom #(.CW(CW), .MEM(CMEM)) u_rom0 (.clk(aclk), .band_sel(band_sel), .sec_sel(3'd0),
        .b0(b0_0), .b1(b1_0), .b2(b2_0), .a1n(a1_0), .a2n(a2_0));
    biquad_coeff_rom #(.CW(CW), .MEM(CMEM)) u_rom1 (.clk(aclk), .band_sel(band_sel), .sec_sel(3'd1),
        .b0(b0_1), .b1(b1_1), .b2(b2_1), .a1n(a1_1), .a2n(a2_1));
    biquad_coeff_rom #(.CW(CW), .MEM(CMEM)) u_rom2 (.clk(aclk), .band_sel(band_sel), .sec_sel(3'd2),
        .b0(b0_2), .b1(b1_2), .b2(b2_2), .a1n(a1_2), .a2n(a2_2));
    biquad_coeff_rom #(.CW(CW), .MEM(CMEM)) u_rom3 (.clk(aclk), .band_sel(band_sel), .sec_sel(3'd3),
        .b0(b0_3), .b1(b1_3), .b2(b2_3), .a1n(a1_3), .a2n(a2_3));

    //-----------------------------------------------------------------------
    // 中间结果缓存（正向结果，供反向读取）
    //-----------------------------------------------------------------------
    reg signed [DW-1:0] mid_ram [0:NSAMP-1];

    //-----------------------------------------------------------------------
    // FSM
    //-----------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_FWD = 2'd1, S_BWD = 2'd2, S_DONE = 2'd3;

    reg [1:0]  state;
    reg [11:0] c;                       // 周期计数

    wire going_fwd = (state == S_FWD);
    wire going_bwd = (state == S_BWD);
    wire feeding   = going_fwd || going_bwd;

    // 正向读数序号 n (0..N-1) ； 反向同样以 n 递增计数，读 mid_ram 逆序
    wire [10:0] n_idx = c[10:0];

    // 地址多路复用： 正向读窗口存储器，反向读中间缓存
    always @(*) begin
        if (going_fwd)
            mem_addr = base_addr + (n_idx[9:0] * N_CH);
        else
            mem_addr = base_addr;
    end

    reg signed [DW-1:0] din_mux;
    reg signed [DW-1:0] din_r;

    wire signed [DW-1:0] mid_rd = mid_ram[(NONE_11 - 11'd1) - n_idx];

    always @(posedge aclk) begin
        din_mux <= going_bwd ? mid_rd : mem_data;
    end
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) din_r <= {DW{1'b0}};
        else if (chain_ce) din_r <= din_mux;
    end

    //-----------------------------------------------------------------------
    // 6 拍对齐管线
    //-----------------------------------------------------------------------
    reg        v_sr [0:PIPE];
    reg [9:0]  n_sr [0:PIPE];

    iir_biquad #(.DW(DW), .CW(CW)) u_s0 (.aclk(aclk), .aresetn(aresetn), .clr(chain_clr), .ce(chain_ce),
        .x(din_r), .b0(b0_0), .b1(b1_0), .b2(b2_0), .a1n(a1_0), .a2n(a2_0), .y(q0));
    iir_biquad #(.DW(DW), .CW(CW)) u_s1 (.aclk(aclk), .aresetn(aresetn), .clr(chain_clr), .ce(chain_ce),
        .x(q0),    .b0(b0_1), .b1(b1_1), .b2(b2_1), .a1n(a1_1), .a2n(a2_1), .y(q1));
    iir_biquad #(.DW(DW), .CW(CW)) u_s2 (.aclk(aclk), .aresetn(aresetn), .clr(chain_clr), .ce(chain_ce),
        .x(q1),    .b0(b0_2), .b1(b1_2), .b2(b2_2), .a1n(a1_2), .a2n(a2_2), .y(q2));
    iir_biquad #(.DW(DW), .CW(CW)) u_s3 (.aclk(aclk), .aresetn(aresetn), .clr(chain_clr), .ce(chain_ce),
        .x(q2),    .b0(b0_3), .b1(b1_3), .b2(b2_3), .a1n(a1_3), .a2n(a2_3), .y(q3));

    //-----------------------------------------------------------------------
    // 主状态机
    //   注意 v_sr 的第 0 位在"发起读"那拍置位，q3 出现在第 PIPE 拍
    //-----------------------------------------------------------------------
    integer i;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state     <= S_IDLE;
            c         <= 12'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            m_valid   <= 1'b0;
            m_data    <= {DW{1'b0}};
            chain_clr <= 1'b0;
            chain_ce  <= 1'b0;
            for (i = 0; i <= PIPE; i = i + 1) begin
                v_sr[i] <= 1'b0;
                n_sr[i] <= 10'd0;
            end
        end else begin
            done      <= 1'b0;
            chain_clr <= 1'b0;

            // ---- 管线推进 ----
            chain_ce <= feeding && (c < NONE_11 + PIPE);

            v_sr[0] <= feeding && (c < NONE_11);
            n_sr[0] <= n_idx[9:0];
            for (i = 1; i <= PIPE; i = i + 1) begin
                v_sr[i] <= v_sr[i-1];
                n_sr[i] <= n_sr[i-1];
            end

            // ---- 输出 ----
            if (v_sr[PIPE]) begin
                if (going_fwd) begin
                    mid_ram[n_sr[PIPE]] <= q3;        // 正向结果 -> 中间缓存
                end else if (going_bwd) begin
                    m_data  <= q3;                    // 反向结果 -> 输出流
                    m_valid <= 1'b1;
                end
            end
            if (m_valid && m_ready)
                m_valid <= 1'b0;

            // ---- 状态转移 ----
            case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    state     <= S_FWD;
                    c         <= 12'd0;
                    busy      <= 1'b1;
                    chain_clr <= 1'b1;        // 清各级 biquad 状态
                end
            end
            S_FWD: begin
                c <= c + 12'd1;
                if (c == (NONE_11 + PIPE)) begin
                    state     <= S_BWD;
                    c         <= 12'd0;
                    chain_clr <= 1'b1;        // 反向重新起步
                end
            end
            S_BWD: begin
                c <= c + 12'd1;
                if (c == (NONE_11 + PIPE)) begin
                    state <= S_DONE;
                    busy  <= 1'b0;
                    done  <= 1'b1;
                end
            end
            S_DONE: state <= S_IDLE;
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
