# 面向机器人载具的毫米波雷达非接触心率估计 —— ZYNQ-7020 FPGA 实现

把一套基于 IWR6843 毫米波雷达的生命体征估计算法，从 Python 参考实现移植为**可综合的 Verilog 流水线**，
并在 Vivado 中用 Block Design 搭出完整数据流：PS（ARM）送复数距离像 → PL 完成相位提取、滤波、谱估计与
质量判定 → 结果经 AXI4-Lite 回到 PS，同时给出回给底盘的控制字。

```
radar_frame_if → dacm_phase → hampel7 → integrate_detrend
   → fir_bandpass(×2) → goertzel_sweep / null_model_cancel
   → spectrum_accum → peak_argmax → bpm_map / ratio_q15
   → certificate_fsm → result_out → PS
                     ▲
              vs_engine_fsm（全流程调度）
```

![算法模块总览](report/figures/00_overview.png)

## 1. 项目要解决的问题

雷达挂在移动底盘上做非接触测心率，难点不在"能不能测出频率"，而在**测出来的数什么时候可信**：

| 难点 | 本项目的处理 |
|---|---|
| 胸壁微动只有亚毫米级，相位噪声大 | DACM 差分相位提取 + Hampel 窗 7 中值/MAD 清洗 |
| 呼吸幅度是心跳的 10 倍以上，谐波会冒充心率 | 呼吸带与心脏带分别滤波，再对呼吸谐波做 LMS 自适应抵消 |
| 目标是移动的，距离仓会漂 | 用视觉/上位机给出的距离选候选仓，并用空仓掩码排除干扰 |
| 底盘在动的时候数据本来就不可信 | `robot_motion_if` 做运动门控，同时输出限速/停机控制字形成闭环 |
| 单次估计可能偶然对 | 跨 (bin, RX) 谱累加 + 质量分门限，输出 6 级决策码而非裸数字 |

算法共 10 个阶段，本仓库把它拆成 **17 个可综合模块**（Block Design 中例化 19 次），
全部为流式定点实现，不依赖浮点 IP。

## 2. 系统架构

| 级 | 模块 | 作用 | 数据格式 |
|---:|---|---|---|
| 0 | `radar_frame_if` | AXI-Stream 帧入口；按 `ch = rx*20 + bin` 拆包；维护 30 s 分析窗 | 32 bit `{Q[15:0], I[15:0]}` |
| 1 | `dacm_phase` | 相位差分 `Δφ = (I·dQ − Q·dI)/(I² + Q²)` | 24 bit Q8.16 |
| 2 | `hampel7` | 窗 7 中值 + MAD，剔除野值并计数 | 24 bit |
| 3 | `integrate_detrend` | 积分、逐通道最小二乘去趋势、写入 600×80 窗口存储器 | 24 bit |
| 4 | `fir_bandpass` ×2 | 呼吸带 0.15–0.60 Hz / 心脏带 0.80–2.00 Hz，1024 抽头线性相位 | 24 bit |
| 5 | `goertzel_sweep` ×2 | 任意频率网格的精确 DFT（呼吸 91 点 / 心率 201 点） | 幅值 32 bit |
| 5' | `null_model_cancel` | 呼吸谐波 + 共模参考的 LMS 自适应抵消 | 24 bit |
| 6 | `spectrum_accum` | 跨 (bin, RX) 非相干累加 | 32 bit |
| 7 | `peak_argmax` | argmax + 抛物线亚 bin 插值 + 峰/中位对比度 | 索引 + 幅值 |
| 8 | `bpm_map` / `ratio_q15` | 网格索引 → bpm（Q8.8）/ 峰和比（Q1.15） | Q8.8 / Q1.15 |
| 9 | `certificate_fsm` | 质量分 + 6 级决策（MEASURE / LOW_CONFIDENCE / 4 种 REJECT） | — |
| 10 | `result_out` | AXI4-Lite 结果寄存器 + 中断 | 32 bit × 13 |

另有三个协同模块：`bin_selector`（视觉距离 → 候选仓）、`robot_motion_if`（运动门控 + 控制字）、
`vs_engine_fsm`（逐候选通道调度，两个 FIR / 两个 DFT 分时复用）。

## 3. Block Design 组成（28 个单元）

| 类别 | 数量 | 说明 |
|---|---:|---|
| 算法模块（module reference） | **19** | 17 个模块，其中 `fir_bandpass` / `goertzel_sweep` 各两次 |
| Xilinx IP | **6** | `processing_system7`、`axi_dma`、`smartconnect`、`axi_gpio`、`axi_protocol_converter`、`proc_sys_reset` |
| 常量 | **3** | `xlconstant`：频带选择 ×2、网格选择 ×1 |
| 合计 | **28** | 连线 129 条 |

数据通路的两处结构值得注意：

* **窗口存储器是"一写两读"**：`integrate_detrend_0` 只有一组读口，靠 `fir_card_0/busy` 作 `rd_sel`
  在两路 FIR 之间切换读地址。
* **`vs_defaults_0` 是刻意的**：所有尚无数据源的输入（共模参考、分量统计量、运动阈值、
  雷达自定位开关、标称呼吸基频）都收敛到这一个块上。BD 对未连接输入会**静默 tie 成 0**，
  集中到一处之后，"哪部分还是占位"在数据流图上一眼可见，且占位值集中在一个文件里改。

## 4. Python 参考实现 ↔ Verilog 映射

| Python（`python代码/scr/`） | Verilog | 定点化方式 |
|---|---|---|
| `dataio.py` 复距离像读入 | `src/rtl/frontend/radar_frame_if.v` | 帧格式 `{Q[15:0], I[15:0]}` |
| `dsp.dacm_phase` | `src/rtl/frontend/dacm_phase.v` | 24 bit Q8.16，除法用参数化逐位恢复除法器 |
| `dsp.hampel` | `src/rtl/frontend/hampel7.v` | 窗 7 中值网络 + MAD × 4.4478（Q4.12） |
| `dsp.integrate` / `detrend` | `src/rtl/frontend/integrate_detrend.v` | 逐通道最小二乘，斜率用递增累加代替乘法 |
| `dsp.bandpass`（butter + filtfilt） | `src/rtl/filter/fir_bandpass.v` | 改为 1024 抽头线性相位 FIR（见 §5） |
| `dsp.spectrum`（FFT） | `src/rtl/spectral/goertzel_sweep.v` | 改为任意频点精确 DFT（见 §5） |
| `estimator._harmonic_residual` | `src/rtl/spectral/null_model_cancel.v` | LMS 自适应抵消，步长 μ = 2⁻⁷ |
| `estimator._accumulate` | `src/rtl/spectral/spectrum_accum.v` | 非相干累加，双写口 + 单读口 |
| `estimator.peak_pick` | `src/rtl/spectral/peak_argmax.v` | argmax + 抛物线插值 + 对比度 |
| `estimator.certificate` | `src/rtl/cert/certificate_fsm.v` | 门限与 Python 一致（如 `vr_min = 0.05`） |
| `run.py` 机器人闭环 | `src/rtl/spatial/robot_motion_if.v` | 速度门控 + 控制字 |

## 5. 四个关键设计决策

**① 带通改用 1024 抽头线性相位 FIR，不用双二阶级联。**
scipy 的 SOS 分解把全部增益压进第一节，`b0 ≈ 2e-5`，而 Q4.14 的量化步长是 `6.1e-5` —— 系数会被量化成 0；
各级增益跨 4 个数量级（0.011 ~ 472），级间必然下溢。换成对称 FIR 后系数最大 0.123、通带增益 0.997–1.003、
阻带 −54 dB，而且对称 FIR 本身就是零相位，等价于 `filtfilt` 的正反向两遍。时延代价可忽略
（20 Hz 帧率下 512×600 = 30.7 万 MAC/通道）。

**② 频谱用任意频点 DFT，不用 FFT IP。**
算法只需要约 200 个特定频点，而且频点非均匀（心率网格步进 0.25 bpm）。DFT 扫描
201×600 ≈ 12 万拍 ≈ 1.2 ms @100 MHz，资源远小于 4096 点 FFT。

**③ 大数组必须显式声明 `ram_style`，否则会吃掉几万个触发器。**
窗口存储器 1.15 Mbit：声明成 `block` 且同步读才能进 BRAM；组合读（同一拍读多个地址）只能走分布式 RAM，
必须显式写 `distributed`，否则综合器会用触发器实现。这一条对 `fir_bandpass.samp_buf`、
`peak_argmax.vals`、`spectrum_accum.mem` 同样成立。

**④ AXI 协议必须转换。**
Zynq-7000 的 `S_AXI_HP0` 从机口固定为 **AXI3**，而 AXI-DMA 的主机口是 **AXI4**，
直连会报协议不兼容。中间插 `axi_protocol_converter`（S = AXI4, M = AXI3），
并且三方数据宽度必须都是 **32 位**（HP0 默认 64，需要显式改成 32）。

## 6. 目录结构

```
mmwave-vital-signs-fpga/
├── README.md                    本文件：项目简介 + 复现步骤
├── src/
│   ├── rtl/                     可综合 Verilog（25 个 .v + 5 个 .mem）
│   │   └── common/ frontend/ spatial/ filter/ spectral/ cert/ output/ top/
│   └── ps/README.md             PS 侧：寄存器映射、帧格式、DMA 时序
├── sim/
│   ├── tb/                      4 个单元 testbench
│   ├── tcl/run_sim.tcl          批量跑仿真
│   ├── scripts/                 rtl_lint.py、check_bd_nets.py（无 Vivado 依赖）
│   └── results/                 仿真与检查结果
├── build/
│   ├── build_vivado.bat         一键构建入口
│   ├── tcl/                     建工程 / 建 BD / 连线 / 综合实现 / 导出框图
│   ├── scripts/                 gen_rom.py、export_tables.py
│   ├── reports/                 综合与实现报告
│   └── vivado/                  Vivado 工程目录（本地生成）
├── board/README.md              上板流程、串口输出、实测记录
├── data/rom_tables/             FIR 系数 / DFT 网格 / 正弦表的 CSV 参考值
├── skill/README.md              工程技能包：8 条技能（校验脚本 / 踩坑清单 / 模板 / 提示词）
└── report/                      设计报告、BD 说明、模块图、协作记录
```

### 与竞赛推荐目录的对照

| 推荐目录 | 本仓库 | 说明 |
|---|---|---|
| `README.md` | `README.md` | 项目简介 + 复现步骤 |
| `src/` | `src/rtl/`、`src/ps/` | 设计源码；PS 侧目前只有接口说明，无 Vitis 工程 |
| `sim/` | `sim/tb/`、`sim/tcl/`、`sim/scripts/`、`sim/results/` | 仿真与验证脚本及其结果 |
| `build/` | `build/tcl/`、`build/scripts/`、`build/reports/` | 构建脚本 + 报告；生成的工程放在 `build/vivado/`（不入库） |
| `board/` | `board/` | 上板说明与实测记录；`board/artifacts/` 放 `.bit` / `.xsa`（本地生成） |
| `data/` | `data/rom_tables/` | 确定性参考数据（ROM 表的可读版本） |
| `skill/` | `skill/README.md` | 技能包 |
| `report/` | `report/` | 设计报告 + 大模型协作记录 + 模块图 |

## 7. 复现步骤

### 7.1 环境

| 项 | 版本 |
|---|---|
| Vivado | 2019.1（工程器件 `xc7z020clg400-2`） |
| Python | 3.8+，需 `numpy`、`scipy`；重新生成报告图另需 `matplotlib` |
| 系统 | Windows（脚本为 `.bat` + Tcl，Tcl 部分跨平台） |

### 7.2 生成 ROM 初始化文件

`.mem` 已随仓库提交，只有改了频带 / 网格 / 采样率时才需要重跑：

```bash
python build/scripts/gen_rom.py        # -> src/rtl/{common,filter,spectral}/*.mem
python build/scripts/export_tables.py  # -> data/rom_tables/*.csv（可读参考值）
```

### 7.3 构建工程与 Block Design

```bat
cd build
build_vivado.bat bd        :: 建工程 + Block Design（只到这里，最省时）
build_vivado.bat           :: 全流程：+ wrapper + 综合 + 实现 + 比特流 + .xsa
build_vivado.bat gui       :: 建完 BD 直接打开 GUI 查看数据流
```

`build/build_vivado.bat` 顶部的 `VIVADO_BIN` 是 Vivado 安装路径，换机器时改这一行。

也可以直接在 Vivado 的 Tcl Console 里：

```tcl
source <repo>/build/tcl/build_everything.tcl
```

产物：

| 产物 | 路径 |
|---|---|
| 工程 | `build/vivado/vs_fpga.xpr` |
| Block Design | `build/vivado/vs_fpga.srcs/sources_1/bd/vs_bd/vs_bd.bd` |
| 比特流 / `.xsa` | `board/artifacts/` |
| 利用率 / 时序报告 | `build/reports/` |

打开 `vs_bd.bd` 就是那张完整的图形化数据流（28 个单元、129 条连线）。
不想开 Vivado 也可以直接看 [`report/flow_diagram.html`](report/flow_diagram.html)。

### 7.4 验证

```bash
python sim/scripts/rtl_lint.py        # 结构 / 例化端口 / 保留字 / 非法字面量 / ROM 文件
python sim/scripts/check_bd_nets.py   # 引脚存在性、位宽一致性、悬空输入（预演 BD 校验）
```

两者都不依赖 Vivado，秒级出结果；`check_bd_nets.py` 直接解析 RTL 端口与 `build_bd.tcl`
的连线，理想输出是 `真实问题 0 / 悬空输入 0`。

单元仿真：

```tcl
source <repo>/sim/tcl/run_sim.tcl     # tb_dacm_phase / tb_hampel7 / tb_fir_bandpass / tb_goertzel_sweep
```

### 7.5 上板

导入 `board/artifacts/vs_design.xsa` 到 Vitis，PS 侧流程见
[`src/ps/README.md`](src/ps/README.md)，板上调试与实测记录见 [`board/README.md`](board/README.md)。

## 8. 接口约定（摘要）

**帧格式**：每帧 80 个 32 位字（4 RX × 20 距离仓），字内 `{Q[15:0], I[15:0]}`，
首字 `TUSER = 1`、末字 `TLAST = 1`，20 Hz。

**结果寄存器**（`result_out`，基址 `0x43C0_0000`）：

| 偏移 | 内容 |
|---:|---|
| `0x00` | `heart_bpm`（Q8.8，**读到的值 ÷256 才是 bpm**） |
| `0x04` | `resp_bpm`（Q8.8） |
| `0x08` | `decision`（6 级）+ `quality`（Q1.15） |
| `0x0C` | `support` + `confidence`（Q1.15） |
| `0x10` | `vr_contrast`（Q4.12）+ `compet_vr`（Q1.15） |
| `0x14` | 标志位：野点 / 越界 / 运动拒绝 / 谐波碰撞 |
| `0x18` | 候选仓掩码（20 bit） |
| `0x1C` | 空仓数 / 选中仓数 |
| `0x20` | 有效距离（Q16.16） |
| `0x24` | `win_ready` / `busy` |
| `0x28` | `robot_cmd`（回给底盘的控制字） |
| `0x2C` | 呼吸基频相位增量 |
| `0x30` | 累计帧数 |

完整位域见 [`src/ps/README.md`](src/ps/README.md)。

## 9. 文档索引

| 文档 | 内容 |
|---|---|
| [`report/design_report.md`](report/design_report.md) | 设计报告：逐阶段映射、定点规格、时序与吞吐、近似清单 A1–A10 |
| [`report/bd_structure.md`](report/bd_structure.md) | Block Design 28 个单元逐个说明、核心算法定位、资源优化路线 |
| [`report/bd_modules_and_nets.docx`](report/bd_modules_and_nets.docx) | 19 张模块图 + 129 条连接关系总表（Word） |
| [`report/flow_diagram.html`](report/flow_diagram.html) | 数据流图（浏览器直接打开） |
| [`report/llm_collaboration.md`](report/llm_collaboration.md) | 大模型协作记录（提示词 / 自我纠错轨迹 / 智能体工作流）+ 技能包提炼过程 |
| [`report/vivado_guide.md`](report/vivado_guide.md) | Vivado 流程总览 |
| [`report/vivado_click_through.md`](report/vivado_click_through.md) | 逐条打勾的手动点击清单（78 步） |
| [`skill/README.md`](skill/README.md) | 工程技能包：8 条技能，每条含适用范围 / 使用方法 / 已验证效果 / 失效条件 |
| [`build/README.md`](build/README.md) | 构建脚本分工与产物位置 |
| [`src/README.md`](src/README.md) | RTL 清单、ROM 表、定点格式速查 |

## 10. 术语

| 缩写 | 含义 |
|---|---|
| DACM | Differentiate and Cross Multiply，相位差分提取 |
| Hampel | 窗内中值 + MAD 的鲁棒野值剔除 |
| VR | Vital Rate，本项目中指心率频段 |
| LMS | Least Mean Squares，自适应滤波 |
| BD | Vivado Block Design |
| XSA | Xilinx Support Archive，硬件平台包（导出给 Vitis） |
