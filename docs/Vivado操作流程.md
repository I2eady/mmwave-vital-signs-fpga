# Vivado 手动执行完整流程

> 工程目录：`D:\A_university_project\FPGAmmwave\fpga\`
> Vivado：`D:\vivado2019\Vivado\2019.1\`（v2019.1）
> 器件：`xc7z020clg400-2`（ZYNQ7020）

本工程要在 PL 里搭的东西是 **Block Design `vs_bd`**：28 个单元 ——
PS7 + AXI-DMA + SmartConnect + AXI-GPIO + AXI-Protocol-Converter + 复位 + 3 个常量
+ 19 个算法模块（module reference）。该 BD 已在 Vivado 2019.1 实测跑通：
`validate_bd_design OK`、`generate_target` 生成完毕、悬空输入 0 个。
其中 60 多根连线如果纯手工点会非常费时间，所以流程分成两种走法：

| 走法 | 谁干 | 用时 | 说明 |
|---|---|---|---|
| **A. Tcl Console 一键**（推荐） | 脚本 | 2 分钟 | 在 GUI 里跑脚本建工程 + BD，之后在界面上看/改 |
| **B. 全手动点击** | 你 | 40 分钟+ | 适合想搞清楚每个单元从哪来的情况 |

两种走法**后半段完全相同**（校验 → wrapper → 综合 → 实现 → 比特流 → 导出）。

---

## 0. 开工前检查

打开 cmd 或资源管理器确认这三样在：

```
D:\A_university_project\FPGAmmwave\fpga\rtl\                22 个 .v/.vh
D:\A_university_project\FPGAmmwave\fpga\rtl\**\*.mem        5 个 ROM 初值
D:\A_university_project\FPGAmmwave\fpga\tcl\build_all.tcl
```

ROM 初值必须先存在，否则综合时报 `$readmemh` 找不到文件。
如果缺了，先重新生成（需要 numpy + scipy）：

```bat
cd /d D:\A_university_project\FPGAmmwave\fpga\scripts
python gen_rom.py
```

---

## 1. 打开 Vivado

双击 `D:\vivado2019\Vivado\2019.1\bin\vivado.bat`，
或在开始菜单选 **Xilinx Design Tools → Vivado 2019.1**。

启动后的 **Welcome 界面先别点任何东西**，直接做第 2 步。
（如果它自动打开了上次的工程，先 `File → Close Project`。）

---

## 2. 走法 A：Tcl Console 一键建工程 + Block Design

### 2.1 打开 Tcl Console

GUI 底部有一排标签：`Tcl Console` / `Messages` / `Log` / `Reports` / `Design Runs`。
点 **Tcl Console**。

### 2.2 敲一行

```tcl
source D:/A_university_project/FPGAmmwave/fpga/tcl/build_all.tcl
```

**注意用正斜杠 `/`**，反斜杠会被 Tcl 当转义字符。

### 2.3 看它跑

Console 里会依次打印：

```
==========================================================
  工程根目录 : D:/A_university_project/FPGAmmwave/fpga
  器件       : xc7z020clg400-2
  运行模式   : GUI
==========================================================
===== 创建工程 =====
已添加 RTL：22 个（共 22 个）
已添加 ROM 初值：5 个
===== 已创建单元 =====
  processing_system7_0
  rst_ps7_100M
  axi_dma_0
  axi_smc
  axi_gpio_ctrl
  radar_frame_if_0
  dacm_phase_0
  ...
===== 分配 AXI 地址 =====
===== 保存 Block Design =====
===== 校验 Block Design =====
===== 生成 Output Products =====
===== Block Design 构建完成 =====
```

### 2.4 看数据流图

左侧 **Sources** 面板里会出现 `vs_bd.bd`，**双击它**。
中间画布上就是完整的数据流（和 `docs/数据流图.html` 一致）。
左上角两个图标可以全屏 / 适应窗口。

### 2.5 看校验结果

底部 **Messages** 标签页，切到 **Critical Warnings** 看一下。
正常情况下会有若干条 "unconnected pin" 的 warning（因为 I/Q 之外的一些
调试端口没接），**只要没有 Critical 级别的 ERROR 就能继续**。

> 跑法 A 的人直接跳到 **第 4 节**。

---

## 3. 走法 B：GUI 全手动点击

### 3.1 新建工程

1. Welcome 界面点 **Create Project** → Next
2. Project name：`vs_fpga`；Project location：`D:/A_university_project/FPGAmmwave/fpga/prj`
   （**Deselect** "Create project subdirectory"，否则会多一层 `vs_fpga/vs_fpga`）
3. Project Type：**RTL Project**，勾选 "Do not specify sources at this time"
4. Default Part → 选 **Boards**，搜索 `ZYNQ`；如果板卡列表里没有，
   切到 **Parts** 标签，搜 `xc7z020clg400-2` 直接选中
5. Finish

### 3.2 添加源文件

**Flow Navigator → PROJECT MANAGER → Add Sources**（或快捷键 `Alt+A`）

1. 选 **Add or create design sources** → Next
2. **Add Files** → 全选 `fpga\rtl` 下 8 个子目录里的 `.v`（共 17 个）
   - 一次选不完就分几批 Add，Vivado 会去重
3. **Add Directories** 也可以：把 `rtl\common`、`rtl\frontend` … 8 个目录逐个加进去
4. 勾选 **Copy sources into project** 的**取消**（保持原地引用，便于我后续改代码）
5. Finish

### 3.3 添加 ROM 初值文件（**这步最容易漏**）

再次 **Add Sources → Add or create design sources → Add Files**，
选这 5 个 `.mem`：

```
rtl\common\sin_lut.mem
rtl\spectral\sin_lut.mem
rtl\filter\fir_coeff.mem
rtl\filter\coeff_rom.mem
rtl\spectral\dft_delta.mem
```

然后**必须改文件类型**：在 Sources 面板里选中这些 `.mem` →
右键 → **Set File Type...** → 选 **Memory Initialization Files**。

（或在 Tcl Console 敲：）
```tcl
set_property file_type {Memory Initialization Files} [get_files *.mem]
```

### 3.4 刷新编译顺序

Tcl Console 里敲：

```tcl
update_compile_order -fileset sources_1
```

> 早期版本这里要设 `include_dirs`（全局参数在 `vs_params.vh` 里）。
> 但实测 **Vivado 的 Block Design HDL 解析器不走 include_dirs**，
> `create_bd_cell -type module -reference` 会因为 `` `include `` 解不开而失败。
> 现在所有参数已内联成字面量，全工程没有 `` `include ``，这一步不需要了。

### 3.5 建 Block Design

**Flow Navigator → IP INTEGRATOR → Create Block Design**
名字填 `vs_bd`，Directory 留空，OK。画布会打开一个空白 BD。

### 3.6 加 PS7

画布中间点 **"+"（Add IP）** → 搜 `Zynq` → 双击 **ZYNQ7 Processing System**。

然后画布上方会出现绿色横条 **"Designer Assistance available. Run Block Automation"**
→ 点它 → OK（它会自动配好 DDR / FIXED_IO / FCLK）。

再双击 `processing_system7_0` 块，在 **Re-customize IP** 窗口里对 4 处：

| 位置 | 设置 |
|---|---|
| PS-PL Configuration → HP Slave AXI Interface | ☑ **S AXI HP0 interface**，**HP0 Data Width = 32** |
| PS-PL Configuration → GP Master AXI Interface | ☑ **M AXI GP0 interface** |
| PS-PL Configuration → General → Enable Clock Resets | 确认 **FCLK_RESET0_N** 已开 |
| Clock Configuration → PL Fabric Clocks | ☑ FCLK_CLK0，**Frequency = 100 MHz** |
| Interrupts → Fabric Interrupts → PL-PS Interrupt Ports | ☑ **IRQ_F2P** |
| Peripheral I/O Pins | ☑ UART 1（调试串口，可选） |

OK 保存。

### 3.7 加外围 IP

画布点 **"+"**，逐个搜并双击添加：

| 搜索关键词 | 选中的 IP |
|---|---|
| `AXI Direct Memory Access` | axi_dma |
| `AXI SmartConnect` | axi_smc |
| `AXI GPIO` | axi_gpio_ctrl |
| `Processor System Reset` | rst_ps7_100M |

配置：

- **axi_dma**：双击 → 取消勾选 **Enable Scatter Gather Engine**，
  取消 **Enable Read Channel** 之外的都不要；勾 **Enable Write Channel** 取消。
  简单说：只留 **Read Channel (MM2S)**。
  Width of Buffer Length Register 保持 26；Stream Data Width = **32**。
- **axi_smc**：双击 → Number of Slave Interfaces = **1**，
  Number of Master Interfaces = **3**。
- **axi_gpio_ctrl**：双击 → 勾 **Enable Dual Channel**；
  Channel 1 GPIO Width = **32**，Channel 2 GPIO Width = **32**；
  两个都选 **All Outputs**。

### 3.8 把 RTL 模块加进 Block Design（**关键步骤**）

这一步是把 Verilog 模块当"积木"放进 BD。有两种方式：

**方式一（拖拽，最快）**：
在左侧 **Sources** 面板里找到模块名（例如 `radar_frame_if`），
**直接拖到 BD 画布上**。Vivado 会在画布上生成一个名为 `radar_frame_if_0` 的块。

**方式二（右键菜单）**：
在 BD 画布空白处 **右键 → Add Module...** → 在弹出的列表里点选模块 → OK。

需要加进去的 **15 个模块**（同一模块可以加多次，加完后改名字）：

| # | Sources 里的模块 | BD 里的实例名 | 参数（双击改） |
|---|---|---|---|
| 1 | `radar_frame_if` | `radar_frame_if_0` | 默认 |
| 2 | `dacm_phase` | `dacm_phase_0` | 默认 |
| 3 | `hampel7` | `hampel7_0` | 默认 |
| 4 | `integrate_detrend` | `integrate_detrend_0` | 默认 |
| 5 | `bin_selector` | `bin_selector_0` | 默认 |
| 6 | `robot_motion_if` | `robot_motion_if_0` | 默认 |
| 7 | `fir_bandpass` | `fir_resp_0` | `band_sel = 0` |
| 8 | `fir_bandpass` | `fir_card_0` | `band_sel = 1` |
| 9 | `null_model_cancel` | `null_model_cancel_0` | 默认 |
| 10 | `goertzel_sweep` | `goertzel_resp_0` | `grid_sel = 0` |
| 11 | `goertzel_sweep` | `goertzel_vr_0` | `grid_sel = 1` |
| 12 | `spectrum_accum` | `spectrum_accum_0` | 默认 |
| 13 | `peak_argmax` | `peak_argmax_0` | 默认 |
| 14 | `certificate_fsm` | `certificate_0` | 默认 |
| 15 | `vs_engine_fsm` | `vs_engine_0` | 默认 |
| 16 | `result_out` | `result_out_0` | 默认 |

改实例名：右键块 → **Rename**（或选中后按 `F2`）。
参数如果是直接在模块里用 `parameter` 声明且没进 BD 的 CONFIG，
可以在 Tcl Console 里设：

```tcl
set_property -dict [list CONFIG.band_sel {0}] [get_bd_cells fir_resp_0]
set_property -dict [list CONFIG.band_sel {1}] [get_bd_cells fir_card_0]
```

再补 4 个 **Constant**（画布 "+" → 搜 `Constant`）驱动固定的频带/网格选择：

| 实例名 | CONST_WIDTH | CONST_VAL | 接到哪 |
|---|---|---|---|
| `const_resp` | 2 | 0 | `fir_resp_0/band_sel`、`goertzel_resp_0/grid_sel` |
| `const_card` | 2 | 1 | `fir_card_0/band_sel` |
| `const_vrgrid` | 2 | 1 | `goertzel_vr_0/grid_sel` |

### 3.9 连线

**先点 "Run Connection Automation"（绿色横条）**，它会自动把
`FCLK_CLK0` / `peripheral_aresetn` / AXI 互联接到大部分块上。
勾 "All Automation" → OK。

剩下的数据流和控制线按下面这张表手动连（**从 A 拖到 B 的端口上**）：

**时钟 / 复位**（Connection Automation 一般会做好，核对一下）

| 源 | 目标 |
|---|---|
| `processing_system7_0/FCLK_CLK0` | 所有模块的 `aclk`、`rst_ps7_100M/slowest_sync_clk` |
| `processing_system7_0/FCLK_RESET0_N` | `rst_ps7_100M/ext_reset_in` |
| `rst_ps7_100M/peripheral_aresetn` | 所有模块的 `aresetn` |

**AXI**

| 源 | 目标 |
|---|---|
| `processing_system7_0/M_AXI_GP0` | `axi_smc/S00_AXI` |
| `axi_smc/M00_AXI` | `axi_dma_0/S_AXI_LITE` |
| `axi_smc/M01_AXI` | `axi_gpio_ctrl/S_AXI` |
| `axi_smc/M02_AXI` | `result_out_0/s_axi` |
| `axi_dma_0/M_AXI_MM2S` | `axi_pc/S_AXI`（协议转换器，S=AXI4） |
| `axi_pc/M_AXI` | `processing_system7_0/S_AXI_HP0`（M=AXI3） |
| `result_out_0/irq` | `processing_system7_0/IRQ_F2P` |

**雷达数据流（AXI-Stream 链）**
把 `m_axis_*` 拖到下一个的 `s_axis_*`，Vivado 会自动连成一整组接口：

```
axi_dma_0/M_AXIS_MM2S  →  radar_frame_if_0/s_axis
radar_frame_if_0/m_axis →  dacm_phase_0/s_axis
dacm_phase_0/m_axis     →  hampel7_0/s_axis
hampel7_0/m_axis        →  integrate_detrend_0/s_axis
fir_resp_0/m_data       →  goertzel_resp_0/s_data      （含 m_valid→s_valid）
fir_card_0/m_data       →  null_model_cancel_0/s_data
null_model_cancel_0/m_data → goertzel_vr_0/s_data
```

**窗口存储器共享读端口**

| 源 | 目标 |
|---|---|
| `fir_resp_0/mem_addr` | `integrate_detrend_0/rd_addr` |
| `fir_card_0/mem_addr` | `integrate_detrend_0/rd_addr_b` |
| `fir_card_0/busy` | `integrate_detrend_0/rd_sel` |
| `integrate_detrend_0/rd_data` | `fir_resp_0/mem_data` **和** `fir_card_0/mem_data` |

**引擎控制**

| 源 | 目标 |
|---|---|
| `vs_engine_0/bf_start_resp` | `fir_resp_0/start` |
| `vs_engine_0/bf_start_card` | `fir_card_0/start` |
| `vs_engine_0/bf_base_addr` | `fir_resp_0/base_addr` **和** `fir_card_0/base_addr` |
| `fir_resp_0/done` | `vs_engine_0/bf_done_resp` |
| `fir_card_0/done` | `vs_engine_0/bf_done_card` |
| `vs_engine_0/gz_start_resp` | `goertzel_resp_0/start` |
| `vs_engine_0/gz_start_vr` | `goertzel_vr_0/start` |
| `vs_engine_0/gz_npts` | `goertzel_resp_0/npts` **和** `goertzel_vr_0/npts` |
| `goertzel_resp_0/done` | `vs_engine_0/gz_done_resp` |
| `goertzel_vr_0/done` | `vs_engine_0/gz_done_vr` |
| `vs_engine_0/pk_start` | `peak_argmax_0/start` |
| `vs_engine_0/pk_npts` | `peak_argmax_0/npts` |
| `peak_argmax_0/done` | `vs_engine_0/pk_done` |
| `vs_engine_0/cert_start` | `certificate_0/start` |
| `certificate_0/done` | `vs_engine_0/cert_done` |
| `integrate_detrend_0/win_ready` | `vs_engine_0/win_ready` |

**谱累加与峰值**

| 源 | 目标 |
|---|---|
| `goertzel_resp_0/res_we` | `spectrum_accum_0/acc_we` |
| `goertzel_resp_0/res_addr` | `spectrum_accum_0/acc_addr` |
| `goertzel_resp_0/res_mag` | `spectrum_accum_0/acc_mag` |
| `goertzel_vr_0/res_we` | `spectrum_accum_0/acc_we_b` |
| `goertzel_vr_0/res_addr` | `spectrum_accum_0/acc_addr_b` |
| `goertzel_vr_0/res_mag` | `spectrum_accum_0/acc_mag_b` |
| `peak_argmax_0/rd_addr` | `spectrum_accum_0/rd_addr` |
| `spectrum_accum_0/rd_mag` | `peak_argmax_0/rd_mag` |
| `vs_engine_0/accum_clr` | `spectrum_accum_0/clr` |

**空间 / 机器人 / 证书**

| 源 | 目标 |
|---|---|
| `axi_gpio_ctrl/gpio_io_o` | `robot_motion_if_0/reg_vision_range` |
| `axi_gpio_ctrl/gpio2_io_o` | `robot_motion_if_0/reg_robot_vel` |
| `robot_motion_if_0/vision_range_q16` | `bin_selector_0/vision_range_q16` |
| `bin_selector_0/bin_mask` | `vs_engine_0/bin_mask` **和** `result_out_0/bin_mask` |
| `bin_selector_0/out_of_range` | `certificate_0/out_of_range` |
| `robot_motion_if_0/motion_reject` | `certificate_0/motion_reject` |
| `peak_argmax_0/peak_val` | `certificate_0/compet_vr_q15` |
| `peak_argmax_0/contrast_q12` | `certificate_0/vr_contrast_q12` |
| `vs_engine_0/fr_inc_out` | `null_model_cancel_0/fr_inc` |

**结果寄存器**

| 源 | 目标 |
|---|---|
| `certificate_0/decision` | `result_out_0/decision` |
| `certificate_0/quality_q8` | `result_out_0/quality_q8` |
| `certificate_0/confidence_q15` | `result_out_0/confidence_q15` |
| `peak_argmax_0/contrast_q12` | `result_out_0/vr_contrast_q12` |
| `bin_selector_0/eff_range_q16` | `result_out_0/eff_range_q16` |
| `robot_motion_if_0/robot_cmd_out` | `result_out_0/robot_cmd` |
| `vs_engine_0/meas_done` | `result_out_0/meas_done` |
| `integrate_detrend_0/win_ready` | `result_out_0/win_ready` |
| `vs_engine_0/fr_inc_out` | `result_out_0/fr_inc` |

> 上面这些 `vs_net ...` 全部写在 `tcl/build_bd.tcl` 里。
> 如果你想省事又不想全跑脚本，可以**只把连线那段单独跑**：先在 GUI 里手动
> 建好 BD 和所有单元、连上时钟复位，然后在 Tcl Console 里 `source` 那个文件的
> 第 5~8 节（复制粘贴对应行）。

### 3.10 校验

按 **F6**，或工具栏的 ✓ 图标，或画布右键 → **Validate Design**。
弹窗 "Validation successful" 就通过了。

有 ERROR 的话点 **Messages** 看红色条目，多半是：
- 某个必接输入悬空 → 补一根线，或接 Constant
- AXI 地址没分配 → Tcl Console 敲 `assign_bd_address`

---

## 4. 生成 HDL Wrapper（两种走法都一样）

1. 左侧 **Sources** 面板，切到 **Hierarchy** 标签
2. 找到 `vs_bd` → **右键 → Create HDL Wrapper...**
3. 选 **Let Vivado manage wrapper and auto-update** → OK
4. 生成完 `vs_bd_wrapper` 会自动成为顶层（Sources 里名字变成**粗体**）

如果不是粗体：右键 `vs_bd_wrapper` → **Set as Top**。

---

## 5. 综合

**Flow Navigator → SYNTHESIS → Run Synthesis**
- Number of jobs 填 **8**
- Strategy 保持 `Vivado Synthesis Defaults`
- OK，等 3–6 分钟

跑完弹窗选 **Open Synthesized Design**（不是必须）。

> **这一步最可能出问题的地方是 ROM 初值。**
> 如果报 `ERROR: [Synth 8-4445] $readmemh: cannot open file xxx.mem`
> → 回到 3.3 节确认 `.mem` 的文件类型是 **Memory Initialization Files**。
> 实在不行，把 5 个 `.mem` 直接复制到 `prj\vs_fpga.runs\synth_1\` 再重跑。

看资源占用：左侧 **Open Synthesized Design → Report Utilization**
（或 `Reports → Report Utilization`）。对照预算：

| 资源 | 预计 | 器件总量 |
|---|---:|---:|
| BRAM36 | ~54 | 140 |
| DSP48E1 | ~14 | 220 |
| FF | ~15 k | 106 400 |
| LUT | ~12 k | 53 200 |

---

## 6. 实现 + 比特流

**Flow Navigator → IMPLEMENTATION → Run Implementation**（约 5–15 分钟）
跑完 → **Flow Navigator → PROGRAM AND DEBUG → Generate Bitstream**（约 2–5 分钟）

产物：
```
prj\vs_fpga.runs\impl_1\vs_bd_wrapper.bit
prj\vs_fpga.runs\impl_1\vs_bd_wrapper_utilization_placed.rpt
prj\vs_fpga.runs\impl_1\vs_bd_wrapper_timing_summary_routed.rpt
```

**时序报告要看的关键项**：`WNS`（Worst Negative Slack）必须 **≥ 0**。
`vs_engine_fsm`、`integrate_detrend`、`null_model_cancel` 是三条最深路径。
如果 WNS 是负的，先把 `processing_system7_0` 的 FCLK_CLK0 从 100 MHz 降到 50 MHz
（重新跑 BD → wrapper → 综合），这个设计在 50 MHz 下时间余量约 190 倍，够用。

---

## 7. 导出硬件平台，进 Vitis / SDK 写 PS 程序

### 7.1 导出

**File → Export → Export Hardware...**
- ☑ **Include bitstream**
- 输出到：`D:\A_university_project\FPGAmmwave\fpga\prj\vs_design.xsa`

### 7.2 PS 端程序要干的事

导出后进 **Vitis 2019.1**（或 SDK），新建 Platform Project → 导入 `vs_design.xsa`，
再建 Application Project，PS 程序需要：

1. **初始化**
   - 配置 UART（115200）做调试打印
   - 配置 AXI-GPIO：写视觉距离、机器人速度、运动门限 → `XGpio_DiscreteWrite`
   - 开 `result_out` 的中断（IRQ_F2P → GIC）

2. **送雷达帧（持续循环）**
   - 从雷达（UART/SPI）读一帧 80 个复数样本，按 `{Q[15:0], I[15:0]}` 打包成 80 个 32 bit 字
   - 首字带 TUSER=1（帧起点），末字 TLAST=1
   - 用 `XAxiDma_SimpleTransfer()` 从 DDR 送到 `axi_dma_0` 的 MM2S 通道

3. **收结果（中断里读）**
   中断来了以后读 `result_out` 的寄存器：

   | 偏移 | 内容 |
   |---|---|
   | `0x00` | `heart_bpm` Q8.8（`0xFFFF`= 无输出）→ **除以 256 得到 bpm** |
   | `0x04` | `respiration_bpm` Q8.8 |
   | `0x08` | `{decision[2:0], quality[15:0]}` |
   | `0x0C` | `{support, confidence}` Q1.15 |
   | `0x10` | `vr_contrast` Q4.12 |
   | `0x14` | 标志位 + `outlier_frac` |
   | `0x24` | 状态 |
   | `0x28` | `robot_cmd_out` → **回给机器人做闭环（hold/slow/meas/unsafe）** |
   | `0x34` | 写任意值清中断标志 |

   换算：Q8.8 值 `v` → 真实值 = `v / 256.0`；Q1.15 值 `v` → `v / 32768.0`。

4. **（可选）闭环控制**
   把 `robot_cmd_out` 通过 CAN / 串口发给机器人底盘：测量窗内运动过大就让它先停稳。

### 7.3 上板

把 `.bit` 通过 **Hardware Manager** 下载（或固化进 QSPI/SD），
打开串口终端看 PS 打印的心率估计结果。

---

## 8. 常见问题排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `$readmemh: cannot open file *.mem` | `.mem` 没设成 Memory Initialization Files | 回 3.3 节；或手动把 `.mem` 拷到 `runs\synth_1\` |
| BD 里找不到某个模块 | 模块不在 sources 里，或有语法错误解析失败 | 先 `update_compile_order`，再在 Messages 里搜该模块名的 ERROR |
| `validate_bd_design` 报未连接端口 | 漏连 | 按 3.9 节的表逐条核对；不用的输入接 Constant |
| AXI 地址冲突 / 未分配 | 没跑 assign_bd_address | Tcl Console：`assign_bd_address` |
| 综合报 unused/undeclared 但能过 | 是 warning | 可以忽略 |
| 时序 WNS < 0 | 100 MHz 太紧 | FCLK_CLK0 降到 50 MHz |
| 跑完 BD 但 Sources 里看不到 `vs_bd.bd` | 面板没展开 | 切到 **Sources → Hierarchy** 标签 |

---

## 9. 只想验证 RTL 语法（不开综合，30 秒）

```tcl
# Tcl Console 里
open_project D:/A_university_project/FPGAmmwave/fpga/prj/vs_fpga.xpr
synth_design -rtl -top vital_signs_top -mode out_of_context
```

这一步只做 elaboration，能快速暴露端口名写错、变量未声明一类的问题。
不用管时序和资源。

---

## 10. 参考文件一览

| 文件 | 用途 |
|---|---|
| `tcl/build_all.tcl` | 建工程 + 加源码 + 建 BD（**GUI 里 source 这一个就够**） |
| `tcl/build_bd.tcl` | 只建 Block Design |
| `tcl/build_after_bd.tcl` | wrapper → 综合 → 实现 → 比特流 → 导出 xsa |
| `tcl/export_bd_diagram.tcl` | 把 BD 导出成 PDF/SVG |
| `tcl/run_sim.tcl` | 跑 4 个单元仿真 |
| `build_vivado.bat` | 纯命令行一键（`synth` / `gui` 参数） |
| `docs/数据流图.html` | 不开 Vivado 就能看的数据流图 |
| `docs/架构与移植说明.md` | Python→Verilog 逐阶段映射、定点规格、近似点清单 |

---

## 附：不想点那么多？三条捷径

```tcl
# 捷径 1：全程一次搞定（含综合）
source D:/A_university_project/FPGAmmwave/fpga/tcl/build_all.tcl
source D:/A_university_project/FPGAmmwave/fpga/tcl/build_after_bd.tcl
```

```bat
:: 捷径 2：cmd 里双击级别的一键
cd /d D:\A_university_project\FPGAmmwave\fpga
build_vivado.bat synth
```

捷径 3：先 `build_all.tcl` 建好 BD，然后**在 GUI 里慢慢看图和调**，
满意了再跑 `build_after_bd.tcl`。**推荐这条**——BD 是可以反复重建的，
改了 RTL 只要重跑 `build_all.tcl` 就行。
