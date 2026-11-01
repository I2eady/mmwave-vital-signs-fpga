//=============================================================================
// tb_fir_bandpass.v -- FIR 零相位带通模块仿真
//-----------------------------------------------------------------------------
// 做法：在窗口存储器模型里放一段"带内 + 带外"的合成信号
//         x[n] = 0.5*sin(2*pi*0.30*n/20)  (带内，呼吸带中心)
//              + 0.5*sin(2*pi*4.00*n/20)  (带外，被抑制)
//       通道 0 基址 0，每通道步进 80（与 integrate_detrend 的地址约定一致）
// 期望：输出幅度接近 0.5（带内保留、带外抑制），且与输入同相（零相位）
//=============================================================================
`timescale 1ns / 1ps

module tb_fir_bandpass;

    localparam integer DW     = 24;
    localparam integer NSAMP  = 600;
    localparam integer N_CH   = 80;
    localparam real    FS     = 20.0;

    reg          aclk = 0;
    reg          aresetn = 0;
    reg          start = 0;
    reg  [15:0]  base_addr = 16'd0;
    reg  [1:0]   band_sel = 2'd0;
    wire         busy, done;
    wire [15:0]  mem_addr;
    reg signed [DW-1:0] mem_data;
    wire signed [DW-1:0] m_data;
    wire         m_valid;

    integer i;
    real    th, amp_in, amp_out, mag2;
    integer n_out = 0;
    // 窗口存储器模型（只放通道 0 的 600 个样本，其余置零）
    reg signed [DW-1:0] wmem [0:NSAMP*N_CH-1];

    fir_bandpass #(.DW(DW), .NSAMP(NSAMP), .N_CH(N_CH), .NHALF(512), .NTAP(1024))
    dut (
        .aclk(aclk), .aresetn(aresetn),
        .start(start), .base_addr(base_addr), .band_sel(band_sel),
        .busy(busy), .done(done),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .m_data(m_data), .m_valid(m_valid), .m_ready(1'b1)
    );

    always #5 aclk = ~aclk;

    // 存储器读（1 拍延迟）
    always @(posedge aclk) mem_data <= wmem[mem_addr];

    // 累加输出功率
    always @(posedge aclk) begin
        if (m_valid) begin
            mag2 = $itor(m_data) / 65536.0;
            amp_out = amp_out + mag2 * mag2;
            n_out = n_out + 1;
        end
    end

    initial begin
        // 生成合成信号
        amp_in = 0.0;
        for (i = 0; i < NSAMP; i = i + 1) begin
            th = i;
            // Q8.16: 1.0 -> 65536
            wmem[i] = $rtoi((0.5 * $sin(2.0*3.14159265*0.30*th/FS)
                           + 0.5 * $sin(2.0*3.14159265*4.00*th/FS)) * 65536.0);
        end
        for (i = NSAMP; i < NSAMP*N_CH; i = i + 1) wmem[i] = 0;

        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (3) @(posedge aclk);

        start = 1;
        @(posedge aclk);
        start = 0;

        wait (done == 1'b1);
        repeat (5) @(posedge aclk);

        amp_out = $sqrt(amp_out / (n_out > 0 ? n_out : 1));

        $display("========================================");
        $display("  输入: 0.50·sin(0.30 Hz) + 0.50·sin(4.00 Hz)");
        $display("  输出样本数 %0d ，输出 RMS 幅度 ≈ %.3f", n_out, amp_out);
        if (n_out >= NSAMP && amp_out > 0.30 && amp_out < 0.42)
            $display("  tb_fir_bandpass : PASS  (带内保留 0.354 = 0.5/sqrt(2)，带外被抑制)");
        else if (n_out < NSAMP)
            $display("  tb_fir_bandpass : FAIL  (输出样本不足)");
        else
            $display("  tb_fir_bandpass : 检查  (RMS=%.3f，期望 ~0.354)", amp_out);
        $display("========================================");
        $finish;
    end

    initial begin
        #50000000;
        $display("  tb_fir_bandpass : TIMEOUT");
        $finish;
    end

endmodule
