//=============================================================================
// spectrum_accum.v -- 跨 (bin,RX) 非相干幅度谱累加器
//-----------------------------------------------------------------------------
// 对应 Python:  estimator._fused_spectrum() 的非相干加权平均
//
//   P_fuse(f) = sum_c w_c * P_c(f) / sum_c w_c
//
// 硬件简化（已记录）：各路权重取相等 w_c = 1（Python 用"带内峰/中位 dB"作
// 质量权重并在 75 分位封顶）。等权非相干累加在 4RX x ~10bin 规模下与加权
// 结果高度相关，同时省掉 80 组对数/分位数运算。
//
// 双模式：
//   ACC： acc_we 有效时 res[acc_addr] += acc_mag
//   RD ： peak_argmax 通过 rd_addr 顺序读出
//   CLR： clr 上升后逐点清零（由内部小计数器完成）
//=============================================================================
`timescale 1ns / 1ps

module spectrum_accum #(
    parameter integer AW     = 8,
    parameter integer MAXPTS = 256,
    parameter integer MW     = 32
)(
    input  wire              aclk,
    input  wire              aresetn,

    input  wire              clr,

    // ---- 写端口 A：呼吸带 DFT -------------------------------------------
    input  wire              acc_we,
    input  wire [AW-1:0]     acc_addr,
    input  wire [MW-1:0]     acc_mag,
    // ---- 写端口 B：心脏带/VR DFT ----------------------------------------
    input  wire              acc_we_b,
    input  wire [AW-1:0]     acc_addr_b,
    input  wire [MW-1:0]     acc_mag_b,

    // ---- 供 peak_argmax 读出 --------------------------------------------
    input  wire [AW-1:0]     rd_addr,
    output reg  [MW-1:0]     rd_mag,

    output reg               ready          // 累加已完成（简单状态）
);

    // 双写口 + 单读口的累加器：BRAM 只有两个口，实现不了；显式声明成
    // 分布式 RAM，综合器会自动复制成两份（每份 1 写 1 读）。
    // 不声明的话会被实现成 256x32 = 8192 个触发器（实测 FF = 8491）。
    (* ram_style = "distributed" *)
    reg [MW-1:0] mem [0:MAXPTS-1];

    // ---- 累加：3 级流水实现读-改-写 -------------------------------------
    reg          w1, w2;
    reg [AW-1:0] a1, a2;
    reg [MW-1:0] m1, m2;
    reg [MW-1:0] r1;

    wire [MW:0] sum_next = {1'b0, r1} + {1'b0, m2};

    // ---- 清零 -----------------------------------------------------------
    reg [AW-1:0] zr_addr;
    reg          zr_run;

    // 两路写端口合流（同一时刻只有一路有效）
    wire          we_any  = acc_we | acc_we_b;
    wire [AW-1:0] a_any   = acc_we ? acc_addr   : acc_addr_b;
    wire [MW-1:0] m_any   = acc_we ? acc_mag    : acc_mag_b;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            w1 <= 1'b0; w2 <= 1'b0;
            a1 <= {AW{1'b0}}; a2 <= {AW{1'b0}};
            m1 <= {MW{1'b0}}; m2 <= {MW{1'b0}};
            r1 <= {MW{1'b0}};
            rd_mag <= {MW{1'b0}};
            zr_addr <= {AW{1'b0}};
            zr_run  <= 1'b0;
            ready   <= 1'b1;
        end else begin
            // 级 1：锁存输入并读旧值
            w1 <= we_any;
            a1 <= a_any;
            m1 <= m_any;
            r1 <= mem[a1];

            // 级 2：写回
            w2 <= w1;
            a2 <= a1;
            m2 <= m1;

            if (w2)
                mem[a2] <= sum_next[MW-1:0];

            // 读端口
            rd_mag <= mem[rd_addr];

            // 清零
            if (clr || zr_run) begin
                zr_run <= 1'b1;
                mem[zr_addr] <= {MW{1'b0}};
                if (zr_addr == MAXPTS-1)
                    zr_run <= 1'b0;
                else
                    zr_addr <= zr_addr + 1'b1;
            end
        end
    end

endmodule
