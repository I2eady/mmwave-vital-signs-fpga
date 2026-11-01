//=============================================================================
// tb_goertzel_sweep.v -- 频率网格 DFT 扫描模块仿真
//-----------------------------------------------------------------------------
// 激励：600 个样本，单音 0.30 Hz（呼吸带网格的第 30 个点，0.15+30*0.005）
// 期望：argmax 出现在 k = 30 附近（result RAM 在第 30 号地址处幅度最大）
//=============================================================================
`timescale 1ns / 1ps

module tb_goertzel_sweep;

    localparam integer DW    = 24;
    localparam integer NSAMP = 600;
    localparam integer NPTS  = 91;
    localparam real    FS    = 20.0;
    localparam real    FTONE = 0.30;

    reg         aclk = 0;
    reg         aresetn = 0;
    reg         start = 0;
    reg  [1:0]  grid_sel = 2'd0;
    reg  [7:0]  npts = NPTS[7:0];
    reg signed [DW-1:0] s_data = 0;
    reg         s_valid = 0;
    wire        s_ready;
    wire        res_we;
    wire [7:0]  res_addr;
    wire [31:0] res_mag;
    wire        busy, done;

    integer i;
    real    th;
    reg [31:0] spectrum [0:255];
    integer k, kbest;
    integer n_sent = 0;

    goertzel_sweep #(.DW(DW), .NSAMP(NSAMP), .MAXPTS(256), .AW(8)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .start(start), .grid_sel(grid_sel), .npts(npts),
        .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
        .res_we(res_we), .res_addr(res_addr), .res_mag(res_mag),
        .busy(busy), .done(done)
    );

    always #5 aclk = ~aclk;

    always @(posedge aclk) begin
        if (res_we) spectrum[res_addr] = res_mag;
    end

    initial begin
        for (i = 0; i < 256; i = i + 1) spectrum[i] = 0;

        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (3) @(posedge aclk);

        start = 1;
        @(posedge aclk);
        start = 0;

        // 送 600 个样本（必须在 S_CAP 阶段完成）
        i = 0;
        while (i < NSAMP) begin
            @(posedge aclk);
            if (s_ready) begin
                th = i;
                s_data  = $rtoi(0.5 * $sin(2.0*3.14159265*FTONE*th/FS) * 65536.0);
                s_valid = 1;
                i = i + 1;
            end else begin
                s_valid = 0;
            end
        end
        @(posedge aclk);
        s_valid = 0;

        wait (done == 1'b1);
        repeat (5) @(posedge aclk);

        // 找最大点
        kbest = 0;
        for (k = 1; k < NPTS; k = k + 1)
            if (spectrum[k] > spectrum[kbest]) kbest = k;

        $display("========================================");
        $display("  单音 %.3f Hz ，网格 0.15–0.60 Hz 步长 0.005 Hz", FTONE);
        $display("  argmax k = %0d  ->  %.4f Hz   (期望 k=30 -> 0.3000 Hz)",
                 kbest, 0.15 + 0.005*kbest);
        if (kbest >= 28 && kbest <= 32)
            $display("  tb_goertzel_sweep : PASS");
        else
            $display("  tb_goertzel_sweep : FAIL");
        $display("========================================");
        $finish;
    end

    initial begin
        #50000000;
        $display("  tb_goertzel_sweep : TIMEOUT");
        $finish;
    end

endmodule
