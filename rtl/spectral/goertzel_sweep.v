//=============================================================================
// goertzel_sweep.v -- 可编程频率网格 DFT 扫描引擎
//-----------------------------------------------------------------------------
// 对应 Python:  dsp.spectrum() / dsp.band_mask() / estimator._vr_sweep() 的
//               频率轴部分，以及 _respiration_rate() 的呼吸带谱峰搜索。
//
// 实现：复数 DFT 累加（等价于零填充 FFT 在任意频率点的精确求值）
//
//     X(f_k) = sum_n x[n] * exp(-j*2*pi*f_k*n/fs)
//     |X|^2  = Re^2 + Im^2
//
//   每个网格点 k 的频率增量 delta_k 存放在系数 ROM 中：
//     delta_k = 2*pi*f_k/fs   以 2^32 为一圈（相位累加器自然溢出取模）
//   sin/cos 由共享的 4096 点 LUT 给出。
//
// 为什么不用 FFT：本设计只需 ~200 个特定频点，且数据率极低
//  （600 样本 x 201 点 = 12 万拍/次，100 MHz 下 1.2 ms）。
//  DFT 扫描的资源远小于 1024/4096 点 FFT IP，且网格可任意非均匀。
//
// 内部自缓冲整窗（600 x 24b BRAM），对每个网格点重放一遍。
//=============================================================================
`timescale 1ns / 1ps

module goertzel_sweep #(
    parameter integer DW     = 24,
    parameter integer NSAMP  = 600,
    parameter integer MAXPTS = 256,
    parameter integer AW     = 8,
    parameter         GMEM   = "dft_delta.mem",     // 3 网格 x 256 点 x 32bit
    parameter         SMEM   = "sin_lut.mem"
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  start,
    input  wire [1:0]            grid_sel,     // 0=呼吸 1=VR 2=心脏带
    input  wire [AW-1:0]         npts,

    // ---- 输入样本流（本通道的 N 个样本） --------------------------------
    input  wire signed [DW-1:0]  s_data,
    input  wire                  s_valid,
    output wire                  s_ready,

    // ---- 输出幅度谱（写入结果 RAM） -------------------------------------
    output reg                   res_we,
    output reg  [AW-1:0]         res_addr,
    output reg  [31:0]           res_mag,

    output reg                   busy,
    output reg                   done
);

    localparam integer CAPW = 10;                       // 0..599
    localparam integer GW   = (MAXPTS <= 2) ? 1 : $clog2(MAXPTS);

    //-----------------------------------------------------------------------
    // 输入缓存
    //-----------------------------------------------------------------------
    reg signed [DW-1:0] cap [0:NSAMP-1];
    reg [CAPW-1:0]      cap_wr;
    reg [CAPW-1:0]      cap_rd;

    //-----------------------------------------------------------------------
    // 网格频率增量 ROM
    //-----------------------------------------------------------------------
    reg [31:0] drom [0:4*MAXPTS-1];   // 4 个网格 x MAXPTS（与 dft_delta.mem 的 1024 行对应）

    initial begin
        $readmemh(GMEM, drom);
    end

    // 索引： base = grid_sel*MAXPTS + k
    reg [GW-1:0] k;
    wire [31:0] delta_k = drom[(grid_sel * MAXPTS) + k];

    //-----------------------------------------------------------------------
    // sin/cos LUT
    //-----------------------------------------------------------------------
    reg signed [15:0] srom [0:4095];
    initial begin
        $readmemh(SMEM, srom);
    end

    reg [31:0]            phase;
    wire [11:0]           a_sin = phase[31:20];
    wire [11:0]           a_cos = phase[31:20] + 12'h400;
    reg signed [15:0]     sin_v, cos_v;

    always @(posedge aclk) begin
        sin_v <= srom[a_sin];
        cos_v <= srom[a_cos];
    end

    //-----------------------------------------------------------------------
    // FSM
    //-----------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_CAP = 2'd1, S_SWEEP = 2'd2, S_DONE = 2'd3;
    reg [1:0] state;

    reg [CAPW:0]  n;
    reg signed [39:0] acc_re, acc_im;

    wire signed [DW-1:0] x_s = cap[cap_rd];

    // 乘积累加： x(Q8.16) * cos(Q1.15) -> Q9.31 -> 对齐到 40bit
    wire signed [39:0] p_re = x_s * cos_v;
    wire signed [39:0] p_im = x_s * sin_v;

    assign s_ready = (state == S_CAP);

    // 幅度： ((Re>>>8)^2 + (Im>>>8)^2) >>> 8  ，饱和到 32bit
    wire signed [39:0] re_s = acc_re >>> 8;
    wire signed [39:0] im_s = acc_im >>> 8;
    wire signed [79:0] mag_big = (re_s * re_s) + (im_s * im_s);
    wire [34:0]        mag_35  = mag_big[72:38];
    wire [31:0]        mag_32  = (|mag_35[34:32]) ? 32'hFFFF_FFFF : mag_35[31:0];

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state    <= S_IDLE;
            cap_wr   <= {CAPW{1'b0}};
            cap_rd   <= {CAPW{1'b0}};
            k        <= {GW{1'b0}};
            n        <= {CAPW{1'b0}};
            acc_re   <= 40'sd0;
            acc_im   <= 40'sd0;
            phase    <= 32'd0;
            res_we   <= 1'b0;
            res_addr <= {AW{1'b0}};
            res_mag  <= 32'd0;
            busy     <= 1'b0;
            done     <= 1'b0;
        end else begin
            done   <= 1'b0;
            res_we <= 1'b0;

            case (state)
            //=================================================================
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    state  <= S_CAP;
                    cap_wr <= {CAPW{1'b0}};
                    n      <= {CAPW{1'b0}};
                    busy   <= 1'b1;
                end
            end
            //=================================================================
            S_CAP: begin
                if (s_valid && s_ready) begin
                    cap[cap_wr] <= s_data;
                    cap_wr      <= cap_wr + 1'b1;
                    if (cap_wr == NSAMP-1) begin
                        state  <= S_SWEEP;
                        cap_rd <= {CAPW{1'b0}};
                        k      <= {GW{1'b0}};
                        n      <= {CAPW{1'b0}};
                        acc_re <= 40'sd0;
                        acc_im <= 40'sd0;
                        phase  <= 32'd0;
                    end
                end
            end
            //=================================================================
            S_SWEEP: begin
                // 相位累加 + 复乘累加
                phase  <= phase + delta_k;
                cap_rd <= cap_rd + 1'b1;

                if (n == 0) begin
                    acc_re <= p_re;
                    acc_im <= p_im;
                end else begin
                    acc_re <= acc_re + p_re;
                    acc_im <= acc_im + p_im;
                end

                if (n == NSAMP-1) begin
                    // 输出该频点的 |X|^2
                    res_addr <= k[AW-1:0];
                    res_mag  <= mag_32;
                    res_we   <= 1'b1;
                    n        <= {CAPW{1'b0}};
                    cap_rd   <= {CAPW{1'b0}};
                    phase    <= 32'd0;
                    acc_re   <= 40'sd0;
                    acc_im   <= 40'sd0;
                    if (k == npts - 1) begin
                        state <= S_DONE;
                        busy  <= 1'b0;
                    end else begin
                        k <= k + 1'b1;
                    end
                end else begin
                    n <= n + 1'b1;
                end
            end
            //=================================================================
            S_DONE: begin
                done  <= 1'b1;
                state <= S_IDLE;
            end
            endcase
        end
    end

endmodule
