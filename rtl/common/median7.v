//=============================================================================
// median7.v -- 7 输入组合中值网络（奇偶转置排序网络 / odd-even transposition）
//-----------------------------------------------------------------------------
// 纯组合逻辑，7 级深度、最多 21 个比较器。
// 对应 Python dsp._hampel_1d 中的 np.median(win, axis=1)。
//
// 说明：此处用位宽 W 的算术比较器实现；综合器会映射到 LUT。
//       若追求资源，可换成 9 输入 LUT6 的单级中值估计，但严格中值需网络。
//=============================================================================
`timescale 1ns / 1ps

module median7 #(
    parameter integer W = 24
)(
    input  wire signed [W-1:0] x0,
    input  wire signed [W-1:0] x1,
    input  wire signed [W-1:0] x2,
    input  wire signed [W-1:0] x3,
    input  wire signed [W-1:0] x4,
    input  wire signed [W-1:0] x5,
    input  wire signed [W-1:0] x6,
    output wire signed [W-1:0] y_med
);

    // st[s][e] : 第 s 级排序后第 e 个元素 (s = 0..7)
    wire signed [W-1:0] st [0:7][0:6];

    assign st[0][0] = x0;
    assign st[0][1] = x1;
    assign st[0][2] = x2;
    assign st[0][3] = x3;
    assign st[0][4] = x4;
    assign st[0][5] = x5;
    assign st[0][6] = x6;

    genvar s, e;
    generate
        for (s = 0; s < 7; s = s + 1) begin : G_STAGE
            for (e = 0; e < 7; e = e + 1) begin : G_ELEM
                if (((e + s) % 2) == 0) begin : G_PAIR_DOWN
                    // 与右邻居配对，取较小值
                    if (e < 6)
                        assign st[s+1][e] = (st[s][e] > st[s][e+1]) ? st[s][e+1] : st[s][e];
                    else
                        assign st[s+1][e] = st[s][e];
                end else begin : G_PAIR_UP
                    // 与左邻居配对，取较大值
                    if (e > 0)
                        assign st[s+1][e] = (st[s][e-1] > st[s][e]) ? st[s][e-1] : st[s][e];
                    else
                        assign st[s+1][e] = st[s][e];
                end
            end
        end
    endgenerate

    assign y_med = st[7][3];      // 排序后取中间元素

endmodule
