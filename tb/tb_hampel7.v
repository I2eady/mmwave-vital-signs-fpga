//=============================================================================
// tb_hampel7.v -- Hampel 野值剔除模块仿真
//-----------------------------------------------------------------------------
// 激励：在通道 0 上送一段恒定值序列，中间插入 3 个大幅度尖峰
// 期望：尖峰被中值替换（输出恢复为常数），outlier_cnt 计入 3（含延迟影响）
//=============================================================================
`timescale 1ns / 1ps

module tb_hampel7;

    localparam integer NS = 60;
    localparam integer BASE = 1000;
    localparam integer SPIKE = 900000;

    reg         aclk = 0;
    reg         aresetn = 0;
    reg  [31:0] s_tdata = 0;
    reg         s_tvalid = 0;
    wire        s_tready;
    reg  [6:0]  s_tuser = 0;
    reg         s_tlast = 0;

    wire [31:0] m_tdata;
    wire        m_tvalid;
    wire [6:0]  m_tuser;
    wire        m_tlast;
    wire [15:0] outlier_cnt, sample_cnt;

    integer n;
    integer errors = 0;
    integer n_out = 0;
    integer spikes = 0;

    hampel7 #(.W(24), .N_CH(80), .CH_W(7)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(1'b1),
        .m_axis_tuser(m_tuser), .m_axis_tlast(m_tlast),
        .outlier_cnt(outlier_cnt), .sample_cnt(sample_cnt)
    );

    always #5 aclk = ~aclk;

    // 采样输出
    always @(posedge aclk) begin
        if (m_tvalid) begin
            n_out = n_out + 1;
            // 从第 8 个输出起（窗已填满）检查是否等于 BASE
            if (n_out > 8 && $signed(m_tdata[23:0]) !== BASE) begin
                errors = errors + 1;
                if (errors < 6)
                    $display("  输出 #%0d = %0d （期望 %0d）",
                             n_out, $signed(m_tdata[23:0]), BASE);
            end
        end
    end

    initial begin
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (2) @(posedge aclk);

        for (n = 0; n < NS; n = n + 1) begin
            if (n == 20 || n == 21 || n == 22) begin
                s_tdata = SPIKE[23:0];
                spikes  = spikes + 1;
            end else begin
                s_tdata = BASE[23:0];
            end
            s_tuser  = 7'd0;
            s_tlast  = (n == NS-1);
            s_tvalid = 1;
            @(posedge aclk);
            while (!s_tready) @(posedge aclk);
            s_tvalid = 0;
        end

        repeat (20) @(posedge aclk);
        $display("========================================");
        $display("  输入样本 %0d ，输出样本 %0d ，注入尖峰 %0d ，野点计数 %0d",
                 NS, n_out, spikes, outlier_cnt);
        if (errors == 0 && n_out > 40)
            $display("  tb_hampel7    : PASS  (尖峰全部被中值替换)");
        else
            $display("  tb_hampel7    : FAIL  (%0d 个输出未被清洗)", errors);
        $display("========================================");
        $finish;
    end

    initial begin
        #200000;
        $display("  tb_hampel7 : TIMEOUT");
        $finish;
    end

endmodule
