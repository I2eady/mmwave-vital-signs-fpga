//=============================================================================
// sin_lut.v -- 正余弦查找表 (Q1.15)
//-----------------------------------------------------------------------------
// 输入 32 bit 相位累加器（高 12 位作为地址，1/4096 圈分辨率）
// 输出 sin/cos 各 s16 (Q1.15)。
// 用于 null_model_cancel.v 生成呼吸谐波参考与共模虚拟载波。
//
// ROM 初值由 scripts/gen_rom.py 生成到 rtl/common/sin_lut.mem。
//=============================================================================
`timescale 1ns / 1ps

module sin_lut #(
    parameter integer AW = 12,          // 地址位宽 -> 4096 点
    parameter         MEM = "sin_lut.mem"
)(
    input  wire                 clk,
    input  wire [31:0]          phase,      // 相位累加器
    output reg  signed [15:0]   sin_o,
    output reg  signed [15:0]   cos_o
);

    reg signed [15:0] rom [0:(1<<AW)-1];

    initial begin
        $readmemh(MEM, rom);
    end

    wire [AW-1:0] a_sin = phase[31 -: AW];
    wire [AW-1:0] a_cos = phase[31 -: AW] + (1 << (AW-1));   // +90 度 = 1/4 圈

    always @(posedge clk) begin
        sin_o <= rom[a_sin];
        cos_o <= rom[a_cos];
    end

endmodule
