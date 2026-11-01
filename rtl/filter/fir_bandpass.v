//=============================================================================
// fir_bandpass.v -- 线性相位 FIR 带通（零相位，等价 filtfilt 带通）
//-----------------------------------------------------------------------------
// 对应 Python:  dsp.bandpass_axis() = butter(order=4) + scipy.signal.filtfilt
//
// 为什么硬件用 FIR 而不是 biquad 级联：
//   scipy 的 butter SOS 分解把全部增益压到第一节，b 系数小到 2e-5，
//   Q4.14 定点直接量化成 0；且各级增益跨越 0.011 ~ 472（4 个数量级），
//   级间中间量必然下溢，需要复杂的逐级定标。
//   512/1024 抽头对称 FIR 的系数天然 O(1)（最大 0.123），Q1.15 精度充足，
//   且**对称 FIR 本身就是零相位**，不需要 filtfilt 的正/反向两遍。
//
// 边界处理：与 scipy 一样做镜像延拓（reflect），使 600 个输出样本全部有效。
//
// 结构
//   1) 从窗口存储器把本通道 600 个样本载入本地缓冲 samp_buf[0:599]
//   2) 对每个输出 n，跑 NHALF 次乘加：
//        y[n] = sum_k h[k] * ( x[n-k] + x[n-(NTAP-1)+k] )
//      下标经镜像映射到 [0, NSAMP)
//   3) 结果流式输出；带通中心增益为 1
//
// 吞吐：NHALF x NSAMP = 512 x 600 = 307,200 拍/通道，100 MHz 下 3 ms
//=============================================================================
`timescale 1ns / 1ps

module fir_bandpass #(
    parameter integer DW     = 24,      // 数据 Q8.16
    parameter integer CW     = 18,      // 系数 Q1.15
    parameter integer NTAP   = 1024,    // 总抽头数（偶数）
    parameter integer NHALF  = 512,     // 唯一系数个数 = NTAP/2
    parameter integer NSAMP  = 600,
    parameter integer N_CH   = 80,
    parameter integer ADDR_W = 16,
    parameter         CMEM   = "fir_coeff.mem",
    parameter integer NWB    = 3         // 频带数
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  start,
    input  wire [ADDR_W-1:0]     base_addr,   // 通道在窗口存储器中的基址 = ch
    input  wire [1:0]            band_sel,    // 0=呼吸 1=心脏 2=共模

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

    localparam integer AW_S = 10;                          // 0..599
    localparam integer CW_B = (NWB <= 1) ? 1 : $clog2(NWB);

    //-----------------------------------------------------------------------
    // 系数 ROM (组合读，LUTRAM)
    //-----------------------------------------------------------------------
    (* rom_style = "distributed" *)
    reg signed [CW-1:0] crom [0:NWB*NHALF-1];

    initial begin
        $readmemh(CMEM, crom);
    end

    wire [CW_B+9:0] cidx = (band_sel[CW_B-1:0] * NHALF) + k;

    //-----------------------------------------------------------------------
    // sample buffer (renamed from 'buf': 'buf' is a Verilog keyword)
    //-----------------------------------------------------------------------
    // samp_buf 在 MAC 循环里是**异步读**（当拍出数），BRAM 做不到异步读，
    // 所以只能用分布式 RAM。原来写 ram_style="block" 会迫使综合器把它
    // 退化成触发器 —— 实测 600x24 = 14400 个 FF，占掉器件 FF 的 1/7。
    // 改回 distributed 后：约 450 个 LUT 当 RAM，省 14400 个 FF。
    (* ram_style = "distributed" *)
    reg signed [DW-1:0] samp_buf [0:NSAMP-1];

    //-----------------------------------------------------------------------
    // 镜像下标映射： m -> [0, NSAMP)
    //-----------------------------------------------------------------------
    function [AW_S-1:0] refl;
        input signed [31:0] m;
        integer t;
        begin
            t = m;
            if (t < 0)         t = -t;
            if (t >= NSAMP)    t = 2*NSAMP - 2 - t;
            if (t < 0)         t = -t;
            if (t >= NSAMP)    t = NSAMP - 1;
            refl = t[AW_S-1:0];
        end
    endfunction

    //-----------------------------------------------------------------------
    // FSM
    //-----------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_LOAD = 2'd1, S_MAC = 2'd2, S_DONE = 2'd3;
    reg [1:0]  state;

    reg [11:0] a_cnt;          // 载入计数
    reg [AW_S-1:0] n_cur;      // 输出样本序号
    reg [9:0]  k;              // 抽头序号 0..NHALF-1

    // 显式 32 位有符号下标，避免无符号下溢导致的行为不确定。
    // 注意：NTAP-1 必须先算成 localparam —— Verilog 的 sized literal
    // 后面不能直接跟括号表达式（32'sd(NTAP-1) 是非法写法）。
    localparam integer NTAP_M1 = NTAP - 1;
    wire signed [31:0] idx_l = $signed({22'd0, n_cur}) - $signed({22'd0, k});
    wire signed [31:0] idx_r = $signed({22'd0, n_cur}) - NTAP_M1
                             + $signed({22'd0, k});

    wire [AW_S-1:0] i_l = refl(idx_l);
    wire [AW_S-1:0] i_r = refl(idx_r);

    wire signed [DW-1:0] xl = samp_buf[i_l];
    wire signed [DW-1:0] xr = samp_buf[i_r];

    wire signed [CW-1:0] hco = crom[cidx];

    wire signed [DW:0]   xsum = xl + xr;                  // DW+1
    wire signed [DW+CW:0] prod = hco * xsum;              // Q9.31, 43 bit

    reg signed [DW+CW+9:0] acc;                           // 52 bit

    wire signed [DW+CW+9:0] acc_next = acc + prod;
    wire signed [DW+CW+9:0] y_shr    = acc_next >>> 15;   // Q8.16

    wire signed [DW-1:0] y_sat =
        (y_shr > $signed({1'b0, {DW-1{1'b1}}})) ? $signed({1'b0, {DW-1{1'b1}}}) :
        (y_shr < $signed({1'b1, {DW-1{1'b0}}})) ? $signed({1'b1, {DW-1{1'b0}}}) :
        y_shr[DW-1:0];

    wire stall = m_valid && !m_ready;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state    <= S_IDLE;
            a_cnt    <= 12'd0;
            n_cur    <= {AW_S{1'b0}};
            k        <= 10'd0;
            acc      <= {DW+CW+10{1'b0}};
            m_data   <= {DW{1'b0}};
            m_valid  <= 1'b0;
            mem_addr <= {ADDR_W{1'b0}};
            busy     <= 1'b0;
            done     <= 1'b0;
        end else begin
            done <= 1'b0;
            if (m_valid && m_ready) m_valid <= 1'b0;

            case (state)
            //=================================================================
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    state <= S_LOAD;
                    a_cnt <= 12'd0;
                    busy  <= 1'b1;
                end
            end
            //=================================================================
            // 载入本通道 600 个样本（BRAM 1 拍读延迟）
            //=================================================================
            S_LOAD: begin
                mem_addr <= base_addr + (a_cnt[AW_S+1:0] * N_CH);
                if (a_cnt >= 12'd1)
                    samp_buf[a_cnt[AW_S-1:0] - 1'b1] <= mem_data;

                if (a_cnt == NSAMP + 12'd1) begin
                    state <= S_MAC;
                    n_cur <= {AW_S{1'b0}};
                    k     <= 10'd0;
                    acc   <= {DW+CW+10{1'b0}};
                end else begin
                    a_cnt <= a_cnt + 12'd1;
                end
            end
            //=================================================================
            // 乘加：每拍一个抽头
            //=================================================================
            S_MAC: begin
                if (!stall) begin
                    acc <= acc_next;

                    if (k == NHALF-1) begin
                        m_data  <= y_sat;
                        m_valid <= 1'b1;
                        acc     <= {DW+CW+10{1'b0}};
                        k       <= 10'd0;
                        if (n_cur == NSAMP-1) begin
                            state <= S_DONE;
                            busy  <= 1'b0;
                        end else begin
                            n_cur <= n_cur + 1'b1;
                        end
                    end else begin
                        k <= k + 10'd1;
                    end
                end
            end
            //=================================================================
            S_DONE: begin
                done  <= 1'b1;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
