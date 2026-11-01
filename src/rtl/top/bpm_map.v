//=============================================================================
// bpm_map.v -- 谱峰网格索引 k_best  ->  心率 / 呼吸率 (Q8.8 bpm)
//-----------------------------------------------------------------------------
// 对应 Python (estimator.py):
//   fine_bpm  = vr_grid[k_best]        # 60..110 bpm, 步长 0.25
//   resp_bpm  = resp_grid[k_resp]      # 0.15..0.60 Hz  ->  9..36 bpm
//
// 两个网格都是等间隔的，所以映射只是一次仿射变换：
//       bpm = base + k * step
// 用 Q8.8 定点：  bpm_q8 = BASE_Q8 + k * STEP_Q8
//
//   VR   网格：60.00 bpm + k * 0.25       -> BASE = 15360, STEP = 64
//   呼吸 网格： 9.00 bpm + k * 0.30       -> BASE =  2304, STEP = 77
//               (0.45 Hz / 90 点 = 0.005 Hz = 0.30 bpm)
//
// vs_engine_fsm 的 pk_done 是峰值搜索完成脉冲，pk_sel 指明本次是哪个网格
// (0 = 呼吸, 1 = VR/心脏)，所以一个实例就能同时维护两路结果。
// 上电默认 0xFFFF = "无输出"，与 result_out 的寄存器约定一致。
//=============================================================================
`timescale 1ns / 1ps

module bpm_map #(
    parameter integer KB           = 8,
    parameter integer BASE_RESP_Q8 = 2304,      //   9.00 bpm
    parameter integer STEP_RESP_Q8 = 77,        //   0.30 bpm
    parameter integer BASE_VR_Q8   = 15360,     //  60.00 bpm
    parameter integer STEP_VR_Q8   = 64         //   0.25 bpm
)(
    input  wire            aclk,
    input  wire            aresetn,

    input  wire            load,                // vs_engine.pk_done
    input  wire            sel,                 // vs_engine.pk_sel: 0=呼吸 1=VR
    input  wire [KB-1:0]   k_best,              // peak_argmax.k_best

    output reg  [15:0]     resp_bpm_q8,
    output reg  [15:0]     heart_bpm_q8
);

    wire [23:0] prod_resp = {16'd0, k_best} * STEP_RESP_Q8;
    wire [23:0] prod_vr   = {16'd0, k_best} * STEP_VR_Q8;
    wire [23:0] sum_resp  = BASE_RESP_Q8 + prod_resp;
    wire [23:0] sum_vr    = BASE_VR_Q8   + prod_vr;

    function [15:0] sat16;
        input [23:0] v;
        begin
            sat16 = (v > 24'd65534) ? 16'hFFFF : v[15:0];
        end
    endfunction

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            resp_bpm_q8  <= 16'hFFFF;
            heart_bpm_q8 <= 16'hFFFF;
        end else if (load) begin
            if (sel) heart_bpm_q8 <= sat16(sum_vr);
            else     resp_bpm_q8  <= sat16(sum_resp);
        end
    end

endmodule
