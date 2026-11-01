//=============================================================================
// integrate_detrend.v -- 相位积分 + 逐通道最小二乘线性去趋势 + 窗口存储
//-----------------------------------------------------------------------------
// 对应 Python:  dsp.integrate_axis()  +  dsp.detrend_axis()
//
//   phi[n]  = cumsum( dphi )[n]                    (逐通道)
//   t       = n - (N-1)/2
//   mean    = sum(phi)/N
//   slope   = ( 2*sum(n*phi) - (N-1)*sum(phi) ) / ( N*(N^2-1)/6 )
//   y[n]    = phi[n] - mean - slope*t
//
// 该模块同时是"窗口存储器"：600 x 80 个 24-bit 样本 (Q8.16) 存放在
// 片内 BRAM 中(48000 x 24b = 1.15 Mb)，供下游 DSP 引擎按通道随机读取。
//
// 三段式 FSM
//   S_FILL  : 流式接收 dphi，逐通道累加得 phi，写 mem，同时累加
//             sum_phi / sum_nphi（每通道各一份，80 组）
//   S_CALC  : 每通道用 u_div 算 mean 与 slope Q16.24（80 x (48+80) 拍）
//   S_APPLY : 遍历 48000 个地址 读-改-写，就地减去 mean + slope*t
//   S_READY : 置 win_ready，等待下游通过 rd_addr/rd_data 读取
//
// 定点
//   dphi : s24 Q4.20  -> phi : s24 Q8.16 (累加器 32bit，饱和)
//   mean : s24 Q8.16 ； slope : s40 Q16.24
//=============================================================================
`timescale 1ns / 1ps

module integrate_detrend #(
    parameter integer W       = 24,
    parameter integer N_CH    = 80,
    parameter integer NSAMP   = 600,
    parameter integer ADDR_W  = 16
)(
    input  wire              aclk,
    input  wire              aresetn,

    // ---- 窗口起始（清累加器） -------------------------------------------
    input  wire              win_start,

    // ---- 流式输入 dphi --------------------------------------------------
    input  wire [31:0]       s_axis_tdata,
    input  wire              s_axis_tvalid,
    output wire              s_axis_tready,
    input  wire              s_axis_tlast,

    // ---- 状态 -----------------------------------------------------------
    output reg               win_ready,       // 去趋势完成，存储器可读
    output reg  signed [W-1:0]   mean_ch,     // 调试用：最后一个通道的 mean
    output reg  signed [39:0]    slope_ch,    // 调试用：最后一个通道的 slope

    // ---- 读端口（下游 DSP 引擎；两路 FIR 共用，rd_sel 选择） -------------
    input  wire [ADDR_W-1:0] rd_addr,         // 通道 A（呼吸带 FIR）
    input  wire [ADDR_W-1:0] rd_addr_b,       // 通道 B（心脏带 FIR）
    input  wire              rd_sel,          // 0 -> A, 1 -> B
    output reg  signed [W-1:0] rd_data
);

    localparam integer MEM_DEPTH = NSAMP * N_CH;      // 48000
    localparam [15:0]  N_SAMP    = NSAMP;
    localparam [39:0]  DEN2      = 40'd35_999_900;    // N*(N^2-1)/6 , N=600

    localparam [2:0] S_FILL  = 3'd0,
                     S_CALC  = 3'd1,
                     S_APPLY = 3'd2,
                     S_READY = 3'd3;

    reg [2:0] state;

    // ---- 窗口存储 -------------------------------------------------------
    reg signed [W-1:0] mem [0:MEM_DEPTH-1];

    reg [ADDR_W-1:0]   wr_addr;
    reg signed [W-1:0] wr_data;
    reg                wr_en;

    // ---- 逐通道累加器 ---------------------------------------------------
    reg signed [31:0]  phi_acc  [0:N_CH-1];     // 积分器
    reg signed [47:0]  sum_x    [0:N_CH-1];     // sum(phi)
    reg signed [55:0]  sum_nx   [0:N_CH-1];     // sum(n*phi)

    reg [15:0]         n_idx;                   // 慢时间序号 n
    reg [6:0]          ch_idx;

    reg signed [W-1:0] mean_r  [0:N_CH-1];
    reg signed [39:0]  slope_r [0:N_CH-1];

    // ---- 除法器（时分复用：先 mean 后 slope） ---------------------------
    reg               div_start;
    reg  [55:0]       div_a;
    reg  [39:0]       div_b;
    reg  [4:0]        div_sel;                  // 0=mean, 1=slope
    wire              div_valid;
    wire [39:0]       div_q;
    wire              div_sat;
    wire              div_busy;

    // 除法器输入多路复用：一次迭代 56+24=80 位 -> 80 拍
    u_div #(
        .W_A   (56),
        .W_B   (40),
        .SHIFT (24),
        .W_Q   (40)
    ) u_detrend_div (
        .clk     (aclk),
        .rst_n   (aresetn),
        .i_valid (div_start),
        .i_a     (div_a),
        .i_b     (div_b),
        .o_valid (div_valid),
        .o_q     (div_q),
        .o_sat   (div_sat),
        .o_busy  (div_busy)
    );

    assign s_axis_tready = (state == S_FILL);

    // ---- 组合：本拍写入的地址与数据 -------------------------------------
    wire signed [31:0] phi_next = phi_acc[ch_idx] + $signed(s_axis_tdata[23:0]);

    // 饱和到 s24
    wire signed [23:0] phi_sat =
        (phi_next > 32'sd8_388_607)  ? 24'sd8_388_607  :
        (phi_next < -32'sd8_388_608) ? -24'sd8_388_608 : phi_next[23:0];

    integer k;
    integer c;
    reg [15:0] ap_idx;
    reg signed [23:0] ap_val;
    reg signed [55:0] ap_prod;
    reg signed [55:0] ap_res;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state     <= S_FILL;
            win_ready <= 1'b0;
            wr_en     <= 1'b0;
            n_idx     <= 16'd0;
            ch_idx    <= 7'd0;
            div_start <= 1'b0;
            ap_idx    <= 16'd0;
            mean_ch   <= 24'sd0;
            slope_ch  <= 40'sd0;
            for (k = 0; k < N_CH; k = k + 1) begin
                phi_acc[k] <= 32'sd0;
                sum_x[k]   <= 48'sd0;
                sum_nx[k]  <= 56'sd0;
                mean_r[k]  <= 24'sd0;
                slope_r[k] <= 40'sd0;
            end
        end else begin
            div_start <= 1'b0;
            wr_en     <= 1'b0;

            case (state)
            //=================================================================
            // S_FILL : 流式积分并写入窗口存储器
            //=================================================================
            S_FILL: begin
                win_ready <= 1'b0;
                if (win_start) begin
                    n_idx <= 16'd0;
                    for (k = 0; k < N_CH; k = k + 1) begin
                        phi_acc[k] <= 32'sd0;
                        sum_x[k]   <= 48'sd0;
                        sum_nx[k]  <= 56'sd0;
                    end
                end

                if (s_axis_tvalid && s_axis_tready) begin
                    // 积分 —— 逐通道
                    phi_acc[ch_idx] <= phi_next;
                    // sum(phi) 与 sum(n*phi)
                    sum_x[ch_idx]  <= sum_x[ch_idx]  + {{24{phi_sat[23]}}, phi_sat};
                    sum_nx[ch_idx] <= sum_nx[ch_idx] +
                        ({{40{phi_sat[23]}}, phi_sat} * {{40{1'b0}}, n_idx});

                    // 写窗口存储器
                    wr_addr <= n_idx[ADDR_W-1:0] * N_CH + ch_idx;
                    wr_data <= phi_sat;
                    wr_en   <= 1'b1;

                    ch_idx <= (ch_idx == N_CH-1) ? 7'd0 : (ch_idx + 7'd1);
                    if (s_axis_tlast) begin
                        n_idx <= n_idx + 16'd1;
                        if (n_idx == N_SAMP - 16'd1) begin
                            state  <= S_CALC;
                            ch_idx <= 7'd0;
                        end
                    end
                end
            end
            //=================================================================
            // S_CALC : 逐通道求 mean 与 slope
            //=================================================================
            S_CALC: begin
                if (!div_busy && !div_valid && !div_start) begin
                    if (div_sel == 5'd0) begin
                        // mean = sum_x / N   (Q8.16 -> 左移 24 位再除)
                        div_a     <= {{8{sum_x[ch_idx][47]}}, sum_x[ch_idx]};
                        div_b     <= {24'd0, N_SAMP};
                        div_start <= 1'b1;
                        div_sel   <= 5'd1;
                    end else begin
                        // slope 分子 = 2*sum_nx - (N-1)*sum_x
                        div_a     <= ($signed({sum_nx[ch_idx], 1'b0}))
                                     - ($signed({{8{sum_x[ch_idx][47]}}, sum_x[ch_idx]}) * 56'sd599);
                        div_b     <= DEN2;
                        div_start <= 1'b1;
                        div_sel   <= 5'd3;      // 等待 slope 结果
                    end
                end

                if (div_valid) begin
                    if (div_sel == 5'd1) begin
                        // 拿到 mean 结果（Q40 中的 Q16.24），取低 24 位作为 Q8.16
                        mean_r[ch_idx] <= div_q[23:0];
                        mean_ch        <= div_q[23:0];
                        div_sel        <= 5'd2;
                    end else begin
                        // 拿到 slope 结果 (Q16.24)
                        slope_r[ch_idx] <= div_q[39:0];
                        slope_ch        <= div_q[39:0];
                        div_sel         <= 5'd0;
                        if (ch_idx == N_CH-1) begin
                            state  <= S_APPLY;
                            ap_idx <= 16'd0;
                        end else begin
                            ch_idx <= ch_idx + 7'd1;
                        end
                    end
                end
            end
            //=================================================================
            // S_APPLY : 就地去趋势  y = x - mean - slope*(n - (N-1)/2)
            //=================================================================
            S_APPLY: begin
                // 读
                c      = ap_idx / N_CH;            // 慢时间序号 n
                ap_val = mem[ap_idx];

                // slope*(n - 299.5) = (slope*(2n-599))>>1
                ap_prod = ($signed(slope_r[c]) * $signed((2*c - 599)))
                          >>> 1;                    // Q16.24
                // >>24 得到 Q8.16
                ap_res  = (ap_prod >>> 24);

                wr_data <= ap_val - mean_r[c] - ap_res[23:0];
                wr_addr <= ap_idx;
                wr_en   <= 1'b1;

                if (ap_idx == MEM_DEPTH-1) begin
                    state     <= S_READY;
                    win_ready <= 1'b1;
                end else begin
                    ap_idx <= ap_idx + 16'd1;
                end
            end
            //=================================================================
            S_READY: begin
                win_ready <= 1'b1;
                if (win_start) begin
                    state     <= S_FILL;
                    win_ready <= 1'b0;
                    n_idx     <= 16'd0;
                    ch_idx    <= 7'd0;
                    div_sel   <= 5'd0;
                    for (k = 0; k < N_CH; k = k + 1) begin
                        phi_acc[k] <= 32'sd0;
                        sum_x[k]   <= 48'sd0;
                        sum_nx[k]  <= 56'sd0;
                    end
                end
            end
            default: state <= S_FILL;
            endcase
        end
    end

    // ---- 窗口存储器写端口 + 读端口 --------------------------------------
    // (综合时会推断为 True-Dual-Port BRAM)
    wire [ADDR_W-1:0] rd_addr_mux = rd_sel ? rd_addr_b : rd_addr;

    always @(posedge aclk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr_mux];
    end

endmodule
