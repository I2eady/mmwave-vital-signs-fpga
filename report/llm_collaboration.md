> **这是开发过程中的工作版记录**（含报错对照表、逐轮修复过程、剩余待办）。
> 项目总览请看仓库根目录的 [`README.md`](../README.md)。

# IWR6843 毫米波雷达非接触心率估计 —— ZYNQ7020 FPGA 实现

把 `python代码/scr/` 中的算法流水线（机器人载具 + IWR6843 雷达心率监测）
移植为可在 **Xilinx ZYNQ-7020（xc7z020clg400-2）** 上综合的 Verilog 实现，
并提供完整的 **Vivado Block Design** 图形化数据流。

---

## 0. 当前状态

| 项 | 状态 |
|---|---|
| RTL 模块（25 个 `.v`，17 个进 BD） | ✅ 完成，静态检查通过（关键字配平 / 例化端口 / ROM 文件） |
| 顶层例化 `vital_signs_top.v` | ✅ 完成（单块集成版，未进 BD） |
| **Block Design `vs_bd`** | ✅ **已在 Vivado 2019.1 实测跑通**：28 个单元全部创建成功、连线完成、`validate_bd_design OK`、`generate_target` 生成完毕；**悬空输入 0 个（BD 41-759 已消失）、位宽全部匹配（BD 41-1228 已消失）** |
| **结构说明** | ✅ **见 [`report/bd_structure.md`](bd_structure.md)** —— 28 个单元清单、数据流 8 级、核心算法在哪 11 个文件、逐模块资源实测 |
| ROM 初值 `build/scripts/gen_rom.py` | ✅ 已生成（正弦表 / FIR 系数 / 频率网格） |
| 单元 testbench（4 个） | ✅ 完成 |
| 数据流图 `report/flow_diagram.html` | ✅ 完成，可直接打开查看 |
| **综合** | ✅ 通过（各模块 OOC 综合均成功） |
| **实现（place/route）** | ❌ `place_design` 失败：**设计比 ZYNQ7020 大 3.7 倍**（LUT 197644 / 53200、FF 109255 / 106400、LUT 当 RAM 48000 / 17400、**BRAM 用量 0**）。原因与逐条修法见 `report/bd_structure.md` 第六节 |

> **资源超标的根因（已定位，不是算法架构问题）**：1.15 Mbit 的 600×80 窗口存储器
> 被实现成了**分布式 RAM**（48000 个 LUT），而不是 BRAM —— 因为
> `integrate_detrend.v` 的 `S_APPLY` 状态里 `ap_val = mem[ap_idx]` 是**组合读**，
> BRAM 做不到异步读。同模块还有 44130 个纯逻辑 LUT（组合除法器 `ap_idx/N_CH` +
> `mean_r[c]`/`slope_r[c]` 的 80:1 组合多路选择器）。
> 另有大数组被实现成触发器（FIR `samp_buf` 14400×2、`peak_argmax.vals` 8192、
> `spectrum_accum.mem` 8192）——**这一批已用 `ram_style` 属性修掉，省约 46k FF**。


> BD 的 28 个单元 = **19 个算法模块**（16 个原有 + `bpm_map` / `ratio_q15` / `vs_defaults`）
> + 6 个 Xilinx IP（PS7 / DMA / SmartConnect / GPIO / 协议转换器 / 复位）
> + 3 个 `xlconstant`（频带 / 网格选择）。

> **关于"我这边跑 Vivado"**：本会话所在的受管 shell 无法驱动 Vivado 2019.1 的
> 批处理模式（`vivado.bat -mode batch -source ...` 会卡在加载器阶段，
> `-version` 正常、沙箱内外表现一致）。因此工程构建改为**一键脚本**形式交付，
> 在您本机的 cmd 里执行即会生成 `build/vivado/vs_fpga.xpr` 与 `vs_bd` Block Design。
RTL 与连线侧我做了两个**无依赖的静态检查器**（见 3.5 节），其中
`sim/scripts/check_bd_nets.py` 会解析 RTL 端口位宽 + `build_bd.tcl` 的全部 `vs_net` 连线，
在不开 Vivado 的前提下预演"引脚存在性 / 位宽一致性 / 悬空输入"三类检查——
上面那 34 个悬空输入就是这么找出来并一次性接完的。

---

## 1. 一眼看全：目录结构

```
mmwave-vital-signs-fpga/
├── README.md                    项目简介 + 复现步骤
├── src/
│   ├── rtl/                     可综合 Verilog（25 个 .v）
│   │   ├── common/              u_div / median7 / sin_lut
│   │   ├── frontend/            radar_frame_if / dacm_phase / hampel7 / integrate_detrend
│   │   ├── spatial/             bin_selector / robot_motion_if
│   │   ├── filter/              fir_bandpass / iir_biquad / biquad_cascade / biquad_coeff_rom
│   │   ├── spectral/            goertzel_sweep / null_model_cancel / spectrum_accum
│   │   │                        / peak_argmax / ratio_q15 / cm_ref_extract
│   │   ├── cert/                certificate_fsm
│   │   ├── output/              result_out
│   │   └── top/                 vs_engine_fsm / bpm_map / vs_defaults / vital_signs_top
│   └── ps/README.md             PS 侧寄存器映射与 DMA 时序
├── sim/
│   ├── tb/                      4 个单元 testbench
│   ├── tcl/run_sim.tcl          批量跑仿真
│   ├── scripts/                 rtl_lint.py / check_bd_nets.py（无 Vivado 依赖）
│   └── results/                 仿真与检查结果记录
├── build/
│   ├── build_vivado.bat         一键入口
│   ├── tcl/                     build_everything / build_all / build_bd / wire_only
│   │                            / build_after_bd / export_bd_diagram
│   ├── scripts/                 gen_rom.py（生成 .mem）/ export_tables.py（导出 CSV）
│   ├── reports/                 综合与实现报告归档
│   └── vivado/                  Vivado 工程（本地生成，不入库）
├── board/
│   ├── README.md                上板流程、串口协议、实测记录
│   └── artifacts/               bit / xsa（本地生成，不入库）
├── data/
│   └── rom_tables/              FIR 系数、DFT 网格、正弦表的 CSV 参考值
├── skill/README.md              工程技能包：改哪里、怎么验证、别踩什么
└── report/
    ├── design_report.md         设计报告：Python→Verilog 逐阶段映射、定点规格、近似点
    ├── bd_structure.md          Block Design 结构：28 个单元、数据流、核心算法定位
    ├── bd_modules_and_nets.docx 19 张模块图 + 连带关系表（Word）
    ├── flow_diagram.html        数据流图（浏览器直接打开）
    ├── vivado_guide.md          Vivado 流程总览
    ├── vivado_click_through.md  逐条打勾的手动点击清单
    ├── llm_collaboration.md     本文件：与大模型协作的过程记录
    ├── figures/                 模块图 PNG + 连线总表
    └── scripts/                 从真实端口与连线自动生成图与表的脚本
```

> **另有一份 Word 交付物**：`report/bd_modules_and_nets.docx`
> （19 张模块图 + 1 张总览图 + 129 条连线总表，共 35 个标题 / 13 张表 / 20 张图）。
> 改完 RTL 后重跑 `report/scripts/gen_bd_doc_assets.py` + `gen_bd_doc_html.py` 即可刷新图与表。

---

## 2. 数据流（Block Design 呈现的就是这张图）

```
                          ┌──────────────────────────────┐
   PS(ARM) ──DMA MM2S──▶  │        radar_frame_if        │  打通道号 / 开 30s 分析窗
                          └───────────────┬──────────────┘
                                          ▼  32bit {Q,I}
                          ┌──────────────────────────────┐
                          │          dacm_phase          │  dφ=(I·dQ−Q·dI)/(I²+Q²)
                          └───────────────┬──────────────┘
                                          ▼  24bit Q4.20
                          ┌──────────────────────────────┐
                          │           hampel7            │  窗 7 中值 + MAD
                          └───────────────┬──────────────┘
                                          ▼
                          ┌──────────────────────────────┐
                          │      integrate_detrend       │  积分 + 线性去趋势
                          │   [ 600×80×24b 窗口存储器 ]   │  ← 后续所有引擎的数据源
                          └───────┬──────────────┬───────┘
                                  ▼              ▼
                     ┌─────────────────┐  ┌─────────────────┐
                     │   fir_resp      │  │   fir_card      │
                     │ 0.15–0.60 Hz    │  │ 0.80–2.00 Hz    │
                     └────────┬────────┘  └────────┬────────┘
                              ▼                    ▼
                     ┌─────────────────┐  ┌──────────────────────┐
                     │ goertzel_resp   │  │  null_model_cancel   │
                     │  91 点 0.005Hz  │  │ 呼吸谐波 k=2..12 LMS │
                     └────────┬────────┘  │      + 共模参考       │
                              │           └──────────┬───────────┘
                              │                      ▼
                              │           ┌──────────────────────┐
                              │           │    goertzel_vr       │
                              │           │ 201 点 60–110 bpm    │
                              │           │     步长 0.25 bpm     │
                              │           └──────────┬───────────┘
                              ▼                      ▼
                     ┌─────────────────────────────────────┐
                     │          spectrum_accum             │ 跨 (bin,RX) 非相干累加
                     └─────────────────┬───────────────────┘
                                       ▼
                     ┌─────────────────────────────────────┐
                     │            peak_argmax              │ argmax + 抛物线 + 峰/中位
                     └─────────────────┬───────────────────┘
                                       ▼
                     ┌─────────────────────────────────────┐
                     │          certificate_fsm            │ MEASURE / LOW_CONF / REJECT_*
                     └─────────────────┬───────────────────┘
                                       ▼
   PS(ARM) ◀──AXI4-Lite + IRQ──  result_out

   旁路：
     axi_gpio ──▶ robot_motion_if ──┬──▶ bin_selector ──▶ 候选仓掩码 ──▶ vs_engine
                                    └──▶ motion_reject ──▶ certificate_fsm
     vs_engine_fsm ──▶ 所有引擎的 start/done 握手（唯一的控制中枢）
```

---

## 3. 快速开始

### 3.1 生成 ROM 初值（已生成，改参数后需重跑）

```bash
cd fpga/scripts
python gen_rom.py        # 需要 numpy + scipy
```

生成：`src/rtl/common/sin_lut.mem`、`src/rtl/spectral/sin_lut.mem`、
`src/rtl/filter/fir_coeff.mem`、`src/rtl/filter/coeff_rom.mem`、`src/rtl/spectral/dft_delta.mem`

### 3.2 一条命令全做完 ★

**在 cmd 里：**

```bat
cd /d D:\A_university_project\FPGAmmwave\fpga
build/build_vivado.bat
```

**在 PowerShell 里：** 注意两点 —— `cd` 不要加 `/d`（那是 cmd 的写法），
当前目录下的脚本必须加 `.\` 前缀：

```powershell
cd D:\A_university_project\FPGAmmwave\fpga
.\build/build_vivado.bat
```

PowerShell 里也可以绕过 .bat 直接调 Vivado
（反引号 `` ` `` 才是续行符，不是 `^`）：

```powershell
& "D:\vivado2019\Vivado\2019.1\bin\vivado.bat" -mode batch `
  -source "D:\A_university_project\FPGAmmwave\fpga\tcl\build_everything.tcl"
```

在 GUI 里则是在 **Tcl Console** 粘一行：

```tcl
source D:/A_university_project/FPGAmmwave/fpga/build/tcl/build_everything.tcl
```

这一条会把下面 10 步全部串起来跑完（**约 10–25 分钟**）：

```
建工程 → 加 22 个 RTL + 5 个 ROM 初值 → 建 Block Design → 连全部线
→ 校验 → HDL Wrapper → 综合 → 实现 → 比特流 → 导出 vs_design.xsa
```

跑完产物：

| 文件 | 说明 |
|---|---|
| `build/vivado/vs_fpga.xpr` | 工程，打开后双击 `vs_bd.bd` 看数据流图 |
| `build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper.bit` | 比特流 |
| `build/vivado/vs_design.xsa` | 硬件平台，给 Vitis 用 |

**只想到某一步**（省时间）：

```bat
:: cmd
build/build_vivado.bat bd      :: 只建工程 + Block Design（约 2 分钟）
build/build_vivado.bat synth   :: 跑到综合完（约 6-10 分钟）
build/build_vivado.bat gui     :: 建完 BD 直接打开 GUI
```

```powershell
# PowerShell（注意 .\ 前缀）
.\build/build_vivado.bat bd
.\build/build_vivado.bat synth
.\build/build_vivado.bat gui

# 或者不用 .bat，直接设环境变量截断
$env:VS_STOP_AFTER = "bd"     # 可选 bd | synth | impl | bit
& "D:\vivado2019\Vivado\2019.1\bin\vivado.bat" -mode batch `
  -source "D:\A_university_project\FPGAmmwave\fpga\tcl\build_everything.tcl"
```

`build/build_vivado.bat` 里 Vivado 路径不对就改顶部的 `VIVADO_BIN`。

> 想看详细的 78 步手工点击过程（含每个 IP 从哪个菜单加、60 多根线怎么连），
> 见 `report/vivado_click_through.md`。

### 3.3 在 GUI 里看数据流图

打开 `fpga/build/vivado/vs_fpga.xpr` → 左侧 **Sources** → 双击 `vs_bd.bd`，
即可看到完整的图形化数据流（**25 个单元**：PS7 + DMA + SmartConnect + GPIO +
协议转换器 + 常量 + 全部 16 个算法模块）。

导出成 PDF/SVG 存进论文：

```bat
vivado.bat -mode batch -source tcl\export_bd_diagram.tcl
:: 输出 docs\bd_dataflow.pdf / .svg
```

**不想开 Vivado 也能看图**：直接打开 `report/flow_diagram.html`。

### 3.4 跑仿真

```bat
vivado.bat -mode batch -source tcl\run_sim.tcl
```

四个单元测试：`tb_dacm_phase`（DACM 相位步进）、`tb_hampel7`（尖峰剔除）、
`tb_fir_bandpass`（带内保留 / 带外抑制）、`tb_goertzel_sweep`（单音频率定位）。

### 3.5 不开 Vivado 的静态检查

```bash
python sim/scripts/rtl_lint.py       # 关键字配平 + 例化端口名 + ROM 文件存在性
python sim/scripts/check_bd_nets.py  # BD 连线预检：引脚存在性 / 位宽 / 悬空输入
```

`check_bd_nets.py` 会解析 `src/rtl/` 下所有模块的端口与位宽（参数代入默认值），
再逐条核对 `build_bd.tcl` 里的 `vs_net` 连线，输出三类结果：

| 输出前缀 | 含义 | Vivado 里对应的报错 |
|---|---|---|
| `!!` | 引脚不存在 / 位宽不匹配 | `BD 5-3`、`BD 41-1228` |
| `??` | RTL 输入脚没被任何连线驱动 | `BD 41-759`（会被静默 tie 成 0） |
| `--` | 输出脚没人用（仅提示） | 无 |

理想结果是 `真实问题 0 / 悬空输入 0`。

---

## 4. 资源与时间预算（ZYNQ-7020：140 BRAM36 / 220 DSP48 / 106k FF）

| 资源 | 估算占用 | 说明 |
|---|---|---|
| BRAM36 | ~46 | 窗口存储器 32 + FIR 缓冲/系数 2×2 + 谱累加 + 结果 |
| DSP48E1 | ~14 | DACM 4 + FIR 2 + DFT 2 + 中值 0 + LMS 6 |
| FF | ~15 k | 主要为各 FSM 与流水寄存器 |
| LUT | ~12 k | 中值网络、地址生成、控制逻辑 |

时间预算（100 MHz，一个 30 s 分析窗）：

| 阶段 | 拍数 | 时间 |
|---|---:|---:|
| 采集 + 相位链（实时流式） | — | 与采集同步 |
| 呼吸路径（~40 通道 × (FIR 307k + DFT 55k)） | 14.5 M | 145 ms |
| 心脏路径（~40 通道 × (FIR 307k + DFT 121k)） | 17.1 M | 171 ms |
| 峰值搜索 + 证书 | ~0.1 M | 1 ms |
| **合计** | **~32 M** | **~320 ms** |

远小于 30 s 的窗口长度，实时余量约 90 倍。

---

## 5. 与 Python 的对应关系（摘要）

完整映射、定点格式与**近似点**见 [`report/design_report.md`](design_report.md)。

| Python (scr/) | Verilog | 保真度 |
|---|---|---|
| `dataio.load_radar` + 窗口切片 | `radar_frame_if` | 等价 |
| `dsp.dacm_phase` | `dacm_phase` | 等价（定点 Q4.20） |
| `dsp.hampel_axis` | `hampel7` | 等价（因果窗，边界差异见文档） |
| `dsp.integrate_axis`/`detrend_axis` | `integrate_detrend` | 等价（定点最小二乘） |
| `dsp.bandpass_axis`(butter4+filtfilt) | `fir_bandpass` | **结构替换**：1024 抽头线性相位 FIR |
| `dsp.spectrum`(FFT) | `goertzel_sweep` | 结构替换：频点精确 DFT |
| `_harmonic_residual`(lstsq) | `null_model_cancel` | **近似**：LMS 自适应抵消 |
| `_common_mode_reference`(SVD) | `cm_ref_extract` | **近似**：均值 + 正交副相 |
| `_vr_sweep`(QR) | `null_model_cancel` + `goertzel_sweep` | 近似（抵消后取周期图） |
| `_fused_spectrum` | `spectrum_accum` | 近似：等权非相干累加 |
| `parabolic_peak` / `argmax` | `peak_argmax` | 等价 |
| `_certificate` | `certificate_fsm` | 等价（门限完全一致） |

---

## 6. 必须知道的三件事

1. **真值是血氧仪候选值，不是 ECG 金标准。** Python 侧所有 MAE/RMSE 都是与消费级
   血氧仪的**一致性**；本移植不改变这一点，FPGA 只是把同一条管线做进 PL。

2. **共模参考与谐波回归是定点近似。** Python 用 `np.linalg.svd`（80×80 矩阵）
   与 `np.linalg.lstsq`，硬件用"空仓带通均值 + 1/4 周期延迟正交"与 LMS 抵消。
   这是本移植最主要的算法近似，稳定性验证需要重新采集数据跑一遍。

3. **`support`（分量一致度）目前是占位常量 0.8。**
   Python 里它由逐 (bin,RX) 的 argmax 一致性统计得到，需要额外的分量级结果暂存与
   统计逻辑；当前版本先用常量，`certificate_fsm` 会相应输出 MEASURE 级。
   若要完整复现，需要扩展 `spectrum_accum` 为"逐分量独立累加 + 中位数统计"。

---

## 7. 报错对照表（都是实测踩过的）

| Vivado 报错 | 真正原因 | 已做的修复 |
|---|---|---|
| 输出全是 `闃舵??` 乱码 | Vivado 的 Tcl 用系统代码页(GBK)读 `.tcl`，UTF-8 中文被解错 | 全部 `.tcl` / `.bat` 改为纯 ASCII |
| BD 建到 `hampel7_0` 就失败，`reason` 是空的 | **BD 的 HDL 解析器不走 `include_dirs`**，`create_bd_cell -type module -reference` 解不开 `` `include "vs_params.vh" `` | 删掉 `vs_params.vh`，全部宏内联成字面量，全工程 0 个 `` `include `` |
| `Syntax error near "buf"` (fir_bandpass.v) | `buf` 是 Verilog 内建门级原语关键字，不能当标识符 | 改名 `samp_buf` |
| `Syntax error near "("` (fir_bandpass.v) | `32'sd(NTAP-1)` —— sized literal 后面不能跟括号表达式 | 引入 `localparam integer NTAP_M1 = NTAP - 1;` |
| `BD 41-758 ... clock pins are not connected` | Xilinx IP 的时钟引脚**不叫** `aclk`：DMA 是 `s_axi_lite_aclk`/`m_axi_mm2s_aclk`，GPIO 是 `s_axi_aclk`，PS7 自己还要接 `M_AXI_GP0_ACLK`/`S_AXI_HP0_ACLK` | 逐个显式连接 |
| `BD 41-1285 ... (AXI3) and ... (AXI4) are incompatible` | Zynq-7000 的 `S_AXI_HP0` 固定是 AXI3，DMA `M_AXI_MM2S` 是 AXI4 | 插入 `axi_protocol_converter`（`axi_pc`，SI=AXI4 / MI=AXI3） |
| `CRITICAL WARNING: [BD 41-1276] Cannot set the parameter C_M_AXI_PROTOCOL / C_S_AXI_PROTOCOL. Parameter does not exist` | 该 IP 的属性名是 `CONFIG.SI_PROTOCOL` / `CONFIG.MI_PROTOCOL`。**写错名字只是 CRITICAL WARNING，不会中断脚本，属性静默丢失** | Tcl 改用 `set_any` 过程：枚举真实属性名再设，并打印用的是哪一个 |
| `BD 41-237 Data width does not match ... HP0(64) / M_AXI(32)` | DMA MM2S 是 32 位，而 PS7 的 HP0 默认 **64 位**；协议转换器两侧共用一个数据宽度 | `CONFIG.PCW_S_AXI_HP0_DATA_WIDTH = 32` + `CONFIG.DATA_WIDTH = 32` |
| `NO PORT MATCH fir_resp_0/m_data -> goertzel_resp_0/s_data` | 这三对模块用的是普通 `data/valid/ready` 信号，不是 AXI-Stream（`tdata/tvalid`），连接助手认不出 | 改成三根线各自显式连接 |
| 16 条 `CRITICAL WARNING: [BD 41-1276] Cannot set the parameter SYNTH_CHECKPOINT_MODE. Parameter does not exist` | 我猜的属性名不对（module reference 根本没有这个属性）。**好消息是并不需要**：模块引用默认就是随顶层一起综合的，`vs_bd_fir_resp_0_0/` 目录里没有 `*_ooc.xdc`，说明它没有走 OOC，`$readmemh` 的搜索路径本来就是项目正常路径 | 整个 2b) 段已删除 |
| `CRITICAL WARNING: [BD 41-759]` 列出 34 个未连接输入脚 | BD 对未连接输入**静默 tie 成 0**，分不清"设计成 0"和"忘了接线"。其中 `integrate_detrend/win_start`（不接就只测量一次）、`result_out/heart_bpm_q8`（PS 读回全 0）、`null_model_cancel/clr`（引擎本来就有 `nc_clr` 输出却没接）是真缺口 | 逐个接上真实来源；确实还没有数据源的 30 个输入统一收敛到 `vs_defaults` 块；新增 `bpm_map`（索引->bpm）和 `ratio_q15`（peak/sum）两个模块 |

---

## 8. 日志里的"无害警告"（不用管它们）

BD 阶段跑完日志里还会剩几类 WARNING，都是**已知无害**的，不影响综合与实现：

| 警告 | 次数 | 为什么可以忽略 |
|---|---|---|
| `[BD 41-235] Width mismatch ... 's_sc_payld'(146) to net 'S_SC_AR_1_PAYLD'(142)` | ~32 条 | SmartConnect IP **内部**节点的载荷位宽提示，Xilinx IP 自带的，改不了也不影响功能 |
| `[BD 41-1306] The connection to interface pin /axi_gpio_ctrl/gpio_io_o is being overridden by the user` | 2 条 | 我们**故意**手动连 `gpio_io_o` 而不用它的接口捆绑，就是想要这个行为 |
| `[IP_Flow 19-587] HDL port or parameter 'xxx' has a dependency on the module local parameter 'yyy'` | 十几条 | BD 的 HDL 解析器看不懂 `localparam`/`derive` 表达式，只是**提示**它按默认值推断；真正的综合不看这个 |
| `[IP_Flow 19-3153] Bus Interface 'aclk': ASSOCIATED_BUSIF bus parameter is missing` | 十几条 | 纯组合模块（如 `bin_selector`）没有 AXIS 接口可关联，正常 |
| `[IP_Flow 19-1976] HDL Parser: Replacing 'AW_S' by 10` | 几条 | 解析器把局部参数按值展开，正常 |

> `BD 41-927`（`CLK_DOMAIN ... may not be synchronized`）曾经一次刷 19 条，
> 现在已经通过给每个 module-reference 的 `aclk` 脚显式打 `CONFIG.FREQ_HZ = 100 MHz` 消掉，
> 下次跑会多出一行 `clock pins tagged with FREQ_HZ : 19 / 19`。

---

## 9. 下一步：跑完综合 → 实现 → 比特流

Block Design 已经确认 OK，剩下的一次跑完：

```bat
cd /d D:\A_university_project\FPGAmmwave\fpga
build/build_vivado.bat
```

约 10–25 分钟（主要花在综合和实现）。也可以分两步，先用 `synth` 模式确认综合能过：

```bat
build/build_vivado.bat synth
```

完成后会打印：

```
  bitstream    : .../build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper.bit  (xxxxxxx bytes)
  hw platform  : .../build/vivado/vs_design.xsa  (xx.x MB)
```

**两个要看的判据**

| 判据 | 位置 | 期望 |
|---|---|---|
| 综合资源 | `build/vivado/vs_fpga.runs/synth_1/vs_bd_wrapper_utilization_synth.rpt` | BRAM36 ≈ 40–50 / 140，DSP48 ≈ 15 / 220，LUT/FF 都远有余量 |
| 实现时序 | `build/vivado/vs_fpga.runs/impl_1/vs_bd_wrapper_timing_summary_routed.rpt` | **WNS ≥ 0**。若为负，把 `build/tcl/build_bd.tcl` 里 PS7 的 `PCW_FPGA0_PERIPHERAL_FREQMHZ` 从 100 改成 50 重跑——本设计吞吐需求极低（每 30 s 窗口只跑约 32 M 拍），50 MHz 完全够 |

**`$readmemh` 的风险已经排除。** 之前担心 module reference 走 OOC 综合会找不到
`fir_coeff.mem` / `dft_delta.mem` / `sin_lut.mem`；实际检查 BD 生成的 `.xci`，
初值文件**已经被登记进每个 module reference 的源文件表**：

```
vs_bd_fir_resp_0_0.xci        -> fir_coeff.mem
vs_bd_fir_card_0_0.xci        -> fir_coeff.mem
vs_bd_goertzel_resp_0_0.xci   -> dft_delta.mem  sin_lut.mem
vs_bd_goertzel_vr_0_0.xci     -> dft_delta.mem  sin_lut.mem
```

这正说明把 `.mem` 加进工程并设成 **Memory Initialization Files** 是有效的
（`build_all.tcl` 第 3 步做的事），综合时能按文件名找到。

**两条通用经验**（写进 `sim/scripts/rtl_lint.py` 的检查项了）：

1. **不要给 RTL 文件加任何 `` `include ``。** BD 的 module-reference 解析器不理
   `include_dirs`，只要一个模块依赖 include，它就建不进 BD。
2. **`set_property` 写错属性名不会报错。** 只想设 IP 参数时，一定用
   `set_any`（枚举 + 打印实际生效的属性名），或者事后用
   `get_property` 回读确认，否则会像上面那条一样静默失效。
