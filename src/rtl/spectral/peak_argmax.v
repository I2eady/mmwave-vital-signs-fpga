//=============================================================================
// peak_argmax.v -- 谱峰搜索 + 抛物线亚 bin 插值 + 峰/中位对比度
//-----------------------------------------------------------------------------
// 对应 Python:
//   k_best   = np.argmax(vr_curve)
//   fine_bpm = grid[k_best]
//   contrast = peak / median(spectrum)        (vr_contrast, vr_contrast_min=1.15)
//   dsp.parabolic_peak(freqs, P, k)           (亚 bin 插值)
//
//   delta = 0.5*(a - c) / (a - 2b + c) ,  a=P[k-1], b=P[k], c=P[k+1]
//   最终频率 = f_k + delta * f_step
//
// 实现：把 npts 个幅度读入本地寄存器阵列，再依次做
//   1) argmax 与谱和
//   2) 中位数（计数法，O(n^2)；n<=256 时 ~6.5 万拍，可接受）
//   3) 抛物线插值与对比度除法
//=============================================================================
`timescale 1ns / 1ps

module peak_argmax #(
    parameter integer AW     = 8,
    parameter integer MAXPTS = 256,
    parameter integer MW     = 32
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  start,
    input  wire [AW-1:0]         npts,

    output reg  [AW-1:0]         rd_addr,
    input  wire [MW-1:0]         rd_mag,

    output reg                   busy,
    output reg                   done,

    output reg  [AW-1:0]         k_best,
    output reg  [MW-1:0]         peak_val,
    output reg  [MW-1:0]         median_val,
    output reg  [31:0]           contrast_q12,     // peak/median, Q4.12
    output reg  [31:0]           sum_val,
    output reg  signed [15:0]    delta_q10         // 抛物线偏移, Q1.10 (+-512)
);

    localparam [2:0] S_IDLE=3'd0, S_LOAD=3'd1, S_ARG=3'd2, S_MED=3'd3, S_INTERP=3'd4, S_DONE=3'd5;
    reg [2:0] state;

    // 组合读（同一拍照 vals[i]/vals[j]/vals[k_best-1]/k_best/k_best+1 共 5 个
    // 地址），BRAM 做不到；必须显式声明为分布式 RAM，否则综合器会用
    // 256x32 = 8192 个触发器去实现（实测 FF = 8699）。
    (* ram_style = "distributed" *)
    reg [MW-1:0] vals [0:MAXPTS-1];
    reg [AW-1:0] ld, i, j;
    reg [15:0]   cnt, best_rank;
    reg [MW-1:0] cur_max, med_r;
    reg [AW-1:0] cur_arg;
    reg [31:0]   acc_sum;

    wire [MW-1:0] v_cur = vals[i];
    wire [MW-1:0] v_j   = vals[j];
    wire          gt    = (v_cur > cur_max) || (i == {AW{1'b0}});

    // ---- 抛物线插值 ------------------------------------------------------
    wire [MW-1:0] pv_a = vals[(k_best == 0) ? 0 : (k_best - 1'b1)];
    wire [MW-1:0] pv_b = vals[k_best];
    wire [MW-1:0] pv_c = vals[(k_best >= npts-1) ? (npts-1) : (k_best + 1'b1)];

    wire signed [MW+2:0] den = $signed({1'b0, pv_a}) - ($signed({1'b0, pv_b}) << 1) + $signed({1'b0, pv_c});
    wire signed [MW+2:0] num = $signed({1'b0, pv_a}) - $signed({1'b0, pv_c});

    // delta = 0.5 * num/den ，Q1.10 => (num<<10)/den /2
    wire signed [63:0] num_s = {{(64-MW-3){num[MW+2]}}, num};
    wire signed [63:0] den_s = {{(64-MW-3){den[MW+2]}}, den};
    wire signed [63:0] delta_raw = (den_s == 0) ? 64'sd0 : ((num_s << 10) / den_s) >>> 1;
    wire signed [63:0] delta_clip = (delta_raw >  64'sd512) ?  64'sd512 :
                                    (delta_raw < -64'sd512) ? -64'sd512 : delta_raw;

    // 对比度 = peak * 4096 / median
    wire [63:0] con_raw = (median_val == 0) ? 64'hFFFF_FFFF_FFFF_FFFF :
                          ({32'd0, peak_val} * 64'd4096) / {32'd0, median_val};
    wire [31:0] con_sat = (con_raw > 64'hFFFF_FFFF) ? 32'hFFFF_FFFF : con_raw[31:0];

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state        <= S_IDLE;
            ld <= {AW{1'b0}}; i <= {AW{1'b0}}; j <= {AW{1'b0}};
            cnt <= 16'd0; best_rank <= 16'd0;
            cur_max <= {MW{1'b0}}; cur_arg <= {AW{1'b0}}; med_r <= {MW{1'b0}};
            acc_sum <= 32'd0;
            k_best <= {AW{1'b0}}; peak_val <= {MW{1'b0}}; median_val <= {MW{1'b0}};
            contrast_q12 <= 32'd0; sum_val <= 32'd0; delta_q10 <= 16'sd0;
            rd_addr <= {AW{1'b0}}; busy <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
            //=================================================================
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    state   <= S_LOAD;
                    ld      <= {AW{1'b0}};
                    rd_addr <= {AW{1'b0}};
                    busy    <= 1'b1;
                end
            end
            //=================================================================
            S_LOAD: begin
                vals[ld] <= rd_mag;
                if (ld == npts - 1) begin
                    state    <= S_ARG;
                    i        <= {AW{1'b0}};
                    cur_max  <= {MW{1'b0}};
                    cur_arg  <= {AW{1'b0}};
                    acc_sum  <= 32'd0;
                end else begin
                    ld      <= ld + 1'b1;
                    rd_addr <= ld + 1'b1;
                end
            end
            //=================================================================
            S_ARG: begin
                if (gt) begin
                    cur_max <= v_cur;
                    cur_arg <= i;
                end
                if (i == npts - 1) begin
                    k_best   <= gt ? i : cur_arg;
                    peak_val <= gt ? v_cur : cur_max;
                    sum_val  <= acc_sum + v_cur[31:0];
                    state    <= S_MED;
                    i        <= {AW{1'b0}};
                    j        <= {AW{1'b0}};
                    cnt      <= 16'd0;
                    best_rank<= 16'd0;
                    med_r    <= {MW{1'b0}};
                end else begin
                    acc_sum <= acc_sum + v_cur[31:0];
                    i       <= i + 1'b1;
                end
            end
            //=================================================================
            // 中位数： 找 cnt = #{j: vals[j] < vals[i]} 最大且 <= npts/2 的那个值
            //=================================================================
            S_MED: begin
                if (v_j < v_cur)
                    cnt <= cnt + 16'd1;

                if (j == npts - 1) begin
                    j <= {AW{1'b0}};
                    if ((cnt <= (npts >> 1)) && (cnt >= best_rank)) begin
                        best_rank <= cnt;
                        med_r     <= v_cur;
                    end
                    if (i == npts - 1) begin
                        state      <= S_INTERP;
                        median_val <= ((cnt <= (npts >> 1)) && (cnt >= best_rank)) ? v_cur : med_r;
                    end else begin
                        i   <= i + 1'b1;
                        cnt <= 16'd0;
                    end
                end else begin
                    j <= j + 1'b1;
                end
            end
            //=================================================================
            S_INTERP: begin
                contrast_q12 <= con_sat;
                delta_q10    <= ((k_best != 0) && (k_best != (npts-1))) ? delta_clip[15:0] : 16'sd0;
                state        <= S_DONE;
                busy         <= 1'b0;
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
