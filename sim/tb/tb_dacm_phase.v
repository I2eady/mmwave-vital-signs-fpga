//=============================================================================
// tb_dacm_phase.v -- DACM 相位增量模块仿真
//-----------------------------------------------------------------------------
// 激励：对通道 0 连续送入固定相位步进的复样本  I+jQ = A*exp(j*theta[n])
//       theta[n] = n * dtheta
// 期望：输出 dphi 恒等于 dtheta（Q4.20，即 round(dtheta*2^20)）
//       第一个样本的 dphi = theta[0]（因为 prev 初值为 0）
//=============================================================================
`timescale 1ns / 1ps

module tb_dacm_phase;

    localparam integer W = 24;
    localparam real    DTHETA = 0.25;             // 每帧相位步进 (rad)
    localparam integer EXPECT = 262144;           // round(0.25 * 2^20)

    reg         aclk = 0;
    reg         aresetn = 0;
    reg  [31:0] s_tdata = 0;
    reg         s_tvalid = 0;
    wire        s_tready;
    reg  [6:0]  s_tuser = 0;
    reg         s_tlast = 0;

    wire [31:0] m_tdata;
    wire        m_tvalid;
    reg         m_tready = 1;
    wire [6:0]  m_tuser;
    wire        m_tlast;

    integer n, got;
    integer errors = 0;
    real    th;

    dacm_phase #(.N_CH(80), .CH_W(7)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast)
    );

    always #5 aclk = ~aclk;      // 100 MHz

    initial begin
        // 复位
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (2) @(posedge aclk);

        // 送 40 个样本（通道 0）
        for (n = 0; n < 40; n = n + 1) begin
            th = n * DTHETA;
            s_tdata  = { $rtoi($cos(th) * 20000.0) & 16'hFFFF,
                         $rtoi($sin(th) * 20000.0) & 16'hFFFF };
            s_tuser  = 7'd0;
            s_tlast  = (n == 39);
            s_tvalid = 1;
            @(posedge aclk);
            while (!s_tready) @(posedge aclk);
            s_tvalid = 0;
            // 等本样本处理完
            while (!m_tvalid) @(posedge aclk);
            got = $signed(m_tdata[23:0]);
            if (n == 0) begin
                if (got !== 0) begin
                    $display("  [n=%0d] 首样本 dphi=%0d (期望 0)", n, got);
                end
            end else begin
                if (got > EXPECT + 2000 || got < EXPECT - 2000) begin
                    $display("  [n=%0d] dphi=%0d  期望约 %0d  <-- 超出容差", n, got, EXPECT);
                    errors = errors + 1;
                end
            end
            @(posedge aclk);
        end

        $display("========================================");
        if (errors == 0)
            $display("  tb_dacm_phase : PASS  (40 样本，步进 %.3f rad)", DTHETA);
        else
            $display("  tb_dacm_phase : FAIL  (%0d 个样本超差)", errors);
        $display("========================================");
        $finish;
    end

    initial begin
        #200000;
        $display("  tb_dacm_phase : TIMEOUT");
        $finish;
    end

endmodule
