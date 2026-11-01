//=============================================================================
// robot_motion_if.v -- 机器人运动/位姿接口 + 运动门控
//-----------------------------------------------------------------------------
// 本模块承担"机器人控制"一侧的 FPGA 角色：
//
//  1) 把 PS(ARM) 通过 AXI-Lite / AXI-GPIO 写入的视觉几何与机器人状态
//     同步到 PL 时钟域：
//        reg_vision_range  : 视觉测得的被试距离 (Q16.16, m)
//        reg_robot_vel     : 机器人当前速度 (mm/s)
//        reg_motion_thresh : 运动门限 (mm/s)
//        reg_cmd_in        : 上位机控制字
//
//  2) 产生"运动安全/运动拒绝"信号给证书模块：
//        运动过快 -> motion_reject=1 -> certificate 判 REJECT_MOTION
//
//  3) 反向输出机器人控制字 robot_cmd_out：
//        测量窗内检测到运动 -> 请求机器人减速/悬停（闭环：先停稳再测心率）
//        bit[0] : hold   (保持静止)
//        bit[1] : slow   (减速)
//        bit[2] : meas   (正在测量)
//        bit[3] : unsafe (运动过大，本次测量作废)
//
// 该模块使"机器人控制 + 雷达心率监测"在同一 PL 数据流中闭环。
//=============================================================================
`timescale 1ns / 1ps

module robot_motion_if (
    input  wire                 aclk,
    input  wire                 aresetn,

    // ---- 来自 AXI-Lite 的寄存器（PS 写） --------------------------------
    input  wire [31:0]          reg_vision_range,   // Q16.16 m, 0x7FFFFFFF = 无效
    input  wire [31:0]          reg_robot_vel,      // mm/s
    input  wire [31:0]          reg_motion_thresh,  // mm/s
    input  wire [31:0]          reg_ctrl,           // bit0 = 使能测量

    // ---- 数据流状态 -----------------------------------------------------
    input  wire                 win_active,         // 来自 radar_frame_if
    input  wire                 win_done,           // 窗口结束脉冲

    // ---- 输出到 PL 数据通路 ---------------------------------------------
    output reg  signed [31:0]   vision_range_q16,   // -> bin_selector
    output reg                  motion_safe,
    output reg                  motion_reject,      // -> certificate_fsm
    output reg  [15:0]          vel_peak_mmps,      // 窗内速度峰值（诊断）

    // ---- 输出给机器人 ---------------------------------------------------
    output reg  [31:0]          robot_cmd_out,
    output reg                  meas_enable
);

    reg [31:0] ctrl_r;
    reg [31:0] vel_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            vision_range_q16 <= 32'sd0;
            motion_safe      <= 1'b1;
            motion_reject    <= 1'b0;
            vel_peak_mmps    <= 16'd0;
            robot_cmd_out    <= 32'd0;
            meas_enable      <= 1'b0;
            ctrl_r           <= 32'd0;
            vel_r            <= 32'd0;
        end else begin
            // ---- 1) 同步 PS 寄存器 -------------------------------------
            vision_range_q16 <= $signed(reg_vision_range);
            ctrl_r           <= reg_ctrl;
            meas_enable      <= reg_ctrl[0];

            // ---- 2) 运动门控 -------------------------------------------
            vel_r <= reg_robot_vel;
            if (reg_robot_vel > reg_motion_thresh) begin
                motion_safe   <= 1'b0;
                motion_reject <= win_active;      // 只在测量窗内才作废
            end else begin
                motion_safe   <= 1'b1;
            end

            // 速度峰值统计（窗起点清零）
            if (win_done)
                vel_peak_mmps <= 16'd0;
            else if (win_active && !motion_safe)
                vel_peak_mmps <= (vel_r > reg_motion_thresh) ?
                                 ((vel_r > 32'd65535) ? 16'hFFFF : vel_r[15:0]) :
                                 vel_peak_mmps;

            // ---- 3) 反向控制字 -----------------------------------------
            robot_cmd_out[0] <= win_active & ~motion_safe;        // hold
            robot_cmd_out[1] <= win_active &  motion_safe;        // slow (正常巡航)
            robot_cmd_out[2] <= win_active;                       // meas
            robot_cmd_out[3] <= ~motion_safe;                     // unsafe
        end
    end

endmodule
