//=============================================================================
// biquad_coeff_rom.v -- 二阶节系数表
//-----------------------------------------------------------------------------
// 3 个频带 x 4 个二阶节 x 5 个系数 = 60 条，由 scripts/gen_coeff.py 生成的
// coeff_rom.mem 初始化（每个系数 s18 Q4.14 的十六进制）。
//
//   band 0 : 呼吸带   0.15 - 0.60 Hz   (config.resp_band)
//   band 1 : 心脏带   0.80 - 2.00 Hz   (config.cardiac_band)
//   band 2 : 共模参考 0.95 - 1.20 Hz   (config.cm_ref_band)
//   band 3 : 自适应窄带（VR 峰值所在 +-6 bpm，config.adaptive_filter_half_bpm）
//            —— 该带系数由 PS 在运行中重算并通过写端口覆盖
//=============================================================================
`timescale 1ns / 1ps

module biquad_coeff_rom #(
    parameter integer CW  = 18,
    parameter integer MEM = "coeff_rom.mem"
)(
    input  wire                 clk,
    input  wire [1:0]           band_sel,      // 0..3
    input  wire [2:0]           sec_sel,       // 0..4
    output wire signed [CW-1:0] b0,
    output wire signed [CW-1:0] b1,
    output wire signed [CW-1:0] b2,
    output wire signed [CW-1:0] a1n,
    output wire signed [CW-1:0] a2n
);

    reg signed [CW-1:0] rom [0:79];     // 4 band x 4 sec x 5 = 80

    initial begin
        $readmemh(MEM, rom);
    end

    // base = band_sel*20 + sec_sel*5
    wire [6:0] base = (band_sel * 7'd20) + (sec_sel * 7'd5);
    wire [6:0] idx  = base;

    assign b0  = rom[idx + 0];
    assign b1  = rom[idx + 1];
    assign b2  = rom[idx + 2];
    assign a1n = rom[idx + 3];
    assign a2n = rom[idx + 4];

endmodule
