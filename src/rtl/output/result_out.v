//=============================================================================
// result_out.v -- 结果寄存器组 + AXI4-Lite 从端接口
//-----------------------------------------------------------------------------
// 把估计流水线的最终结果打包成 PS(ARM) 可读的寄存器组。
// 对应 Python:  run.py 打印的 EstimateResult 字段。
//
// 寄存器映射（基址 + 4*n）
//   0x00 heart_bpm          Q8.8  (0xFFFF = 无输出)
//   0x04 respiration_bpm    Q8.8
//   0x08 {decision[2:0], quality[15:0]}
//   0x0C {support[15:0], confidence[15:0]}
//   0x10 competitive_vr Q1.15  | vr_contrast Q4.12
//   0x14 outlier_frac Q1.15 | {harmonic_collision, motion_reject, out_of_range}
//   0x18 bin_mask[19:0]
//   0x1C {n_free_bins[7:0], n_bins_sel[7:0]}
//   0x20 effective_range Q16.16
//   0x24 status {..., busy, win_ready, meas_done_pulse}
//   0x28 robot_cmd_out
//   0x2C f_r 相位增量（调试）
//   0x30 frame_cnt
//   0x34 IRQ 清标志
//=============================================================================
`timescale 1ns / 1ps

module result_out #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 6      // 16 个 32bit 寄存器
)(
    // ---- AXI4-Lite 全局时钟/复位（BD 会识别 aclk/aresetn） ---------------
    input  wire                                  aclk,
    input  wire                                  aresetn,

    // ---- AXI4-Lite 写地址通道 -------------------------------------------
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]         s_axi_awaddr,
    input  wire                                  s_axi_awvalid,
    output wire                                  s_axi_awready,
    // ---- 写数据通道
    input  wire [C_S_AXI_DATA_WIDTH-1:0]         s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]       s_axi_wstrb,
    input  wire                                  s_axi_wvalid,
    output wire                                  s_axi_wready,
    // ---- 写响应通道
    output reg  [1:0]                            s_axi_bresp,
    output reg                                   s_axi_bvalid,
    input  wire                                  s_axi_bready,
    // ---- 读地址通道
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]         s_axi_araddr,
    input  wire                                  s_axi_arvalid,
    output wire                                  s_axi_arready,
    // ---- 读数据通道
    output reg  [C_S_AXI_DATA_WIDTH-1:0]         s_axi_rdata,
    output reg  [1:0]                            s_axi_rresp,
    output reg                                   s_axi_rvalid,
    input  wire                                  s_axi_rready,

    // ---- 来自估计流水线的结果 -------------------------------------------
    input  wire [15:0]  heart_bpm_q8,
    input  wire [15:0]  resp_bpm_q8,
    input  wire [2:0]   decision,
    input  wire [15:0]  quality_q8,
    input  wire [15:0]  support_q15,
    input  wire [15:0]  confidence_q15,
    input  wire [15:0]  compet_vr_q15,
    input  wire [31:0]  vr_contrast_q12,
    input  wire [15:0]  outlier_q15,
    input  wire         harmonic_collision,
    input  wire         motion_reject,
    input  wire         out_of_range,
    input  wire [19:0]  bin_mask,
    input  wire [4:0]   n_bins_sel,     // = bin_selector.n_bins_sel (0..20)
    input  wire [7:0]   n_free_bins,
    input  wire [31:0]  eff_range_q16,
    input  wire [31:0]  robot_cmd,
    input  wire [31:0]  fr_inc,
    input  wire [15:0]  frame_cnt,
    input  wire         win_ready,
    input  wire         meas_done,        // 一次估计完成脉冲
    input  wire         busy,

    output reg          irq                // 中断给 PS
);

    localparam integer ADDR_LSB = 2;
    localparam integer OPT_MEM_ADDR_BITS = C_S_AXI_ADDR_WIDTH - ADDR_LSB;

    // ---- 写通道握手（简化：AW/W 同时到达） ------------------------------
    wire        wr_en = s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
    assign      s_axi_awready = wr_en;
    assign      s_axi_wready  = wr_en;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else begin
            if (wr_en) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---- 读通道 ---------------------------------------------------------
    assign s_axi_arready = ~s_axi_rvalid;

    reg [C_S_AXI_ADDR_WIDTH-1:0] araddr_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= 2'b00;
            s_axi_rdata  <= 32'd0;
            araddr_r     <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (s_axi_arready && s_axi_arvalid) begin
                araddr_r     <= s_axi_araddr;
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end

            case (araddr_r[OPT_MEM_ADDR_BITS+ADDR_LSB-1:ADDR_LSB])
                4'd0:  s_axi_rdata <= {16'h0, heart_bpm_q8};
                4'd1:  s_axi_rdata <= {16'h0, resp_bpm_q8};
                4'd2:  s_axi_rdata <= {13'h0, decision, quality_q8};
                4'd3:  s_axi_rdata <= {support_q15, confidence_q15};
                4'd4:  s_axi_rdata <= {vr_contrast_q12, compet_vr_q15};
                4'd5:  s_axi_rdata <= {13'h0, harmonic_collision, motion_reject,
                                       out_of_range, outlier_q15};
                4'd6:  s_axi_rdata <= {12'h0, bin_mask};
                4'd7:  s_axi_rdata <= {16'h0, n_free_bins, 3'b0, n_bins_sel};
                4'd8:  s_axi_rdata <= eff_range_q16;
                4'd9:  s_axi_rdata <= {30'h0, busy, win_ready};
                4'd10: s_axi_rdata <= robot_cmd;
                4'd11: s_axi_rdata <= fr_inc;
                4'd12: s_axi_rdata <= {16'h0, frame_cnt};
                default: s_axi_rdata <= 32'd0;
            endcase
        end
    end

    // ---- 中断：一次估计完成 ---------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)      irq <= 1'b0;
        else if (meas_done) irq <= 1'b1;
        else if (wr_en && (s_axi_awaddr[5:2] == 4'd13)) irq <= 1'b0;
    end

endmodule
