# Block Design `vs_bd` 结构说明

> 面向 ZYNQ7020（`xc7z020clg400-2`）的 IWR6843 毫米波雷达非接触心率估计 PL 实现。
> 本文说明 **Block Design 里有什么、一共几个模块、核心算法在哪些文件里**。
> 数据来源：`tcl/build_bd.tcl` 生成的 `prj/vs_fpga.srcs/sources_1/bd/vs_bd/vs_bd.bd`，
> 以及 Vivado 2019.1 实测跑出的各模块综合利用率报告。

---

## 一、总数一览

| 项目 | 数量 | 说明 |
|---|---:|---|
| RTL 源文件 | **25 个 `.v`** | `rtl/` 下 8 个子目录 |
| 其中**进 Block Design 的算法模块** | **17 个**（例化 **19 次**） | `fir_bandpass`、`goertzel_sweep` 各用两次 |
| 其中**公共子模块**（在模块内部例化，不出现在 BD 画布上） | **5 个** | `median7` `sin_lut` `u_div` `iir_biquad` `biquad_coeff_rom` |
| 其中**未被例化**（备选路径 / 预留） | **3 个** | `biquad_cascade` `cm_ref_extract` `vital_signs_top` |
| **Block Design 单元总数** | **28 个** | 19 个 RTL 实例 + 6 个 Xilinx IP + 3 个常量 |
| Block Design 校验状态 | `validate_bd_design OK`、悬空输入 0 | 位宽全部匹配 |

**28 个单元 = 19（算法）+ 6（PS/总线）+ 3（常量）**

---

## 二、Block Design 里的 28 个单元

### 1. PS 接口与总线（6 个 Xilinx IP，不是算法，是"通道"）

| 单元 | IP | 干什么 |
|---|---|---|
| `processing_system7_0` | Zynq PS7 | ARM 核 + DDR 控制器；`M_AXI_GP0` 走控制，`S_AXI_HP0` 走雷达数据，`FCLK_CLK0` = 100 MHz，`IRQ_F2P` 收中断 |
| `axi_dma_0` | AXI DMA | **雷达数据入口**：MM2S 从 DDR 读原始帧，按 32 位 AXI-Stream 送进算法链 |
| `axi_smc` | SmartConnect | 1 主 3 从的 AXI 互联（DMA 控制寄存器 / GPIO / 结果寄存器） |
| `axi_gpio_ctrl` | AXI GPIO（双路） | PS 写两个 32 位量：视觉测距值、机器人速度 |
| `axi_pc` | AXI Protocol Converter | PS7 的 HP0 是 **AXI3**、DMA 的 MM2S 是 **AXI4**，必须插协议转换器 |
| `rst_ps7_100M` | Processor System Reset | 同步复位 |

### 2. 常量（3 个 `xlconstant`）

`const_resp`（=0，呼吸频带选择）、`const_card`（=1，心脏频带）、`const_vrgrid`（=1，VR 频率网格）。
它们驱动两个 FIR 的 `band_sel` 和两个 DFT 的 `grid_sel`。

### 3. 算法模块（19 个实例 = 17 个模块）

| # | 实例名 | 模块 | 在流水线里的位置 |
|---:|---|---|---|
| 1 | `radar_frame_if_0` | `radar_frame_if` | 入口：AXI-Stream 解帧、通道解复用、分析窗门控 |
| 2 | `dacm_phase_0` | `dacm_phase` | **相位链 ①** DACM 相位增量 |
| 3 | `hampel7_0` | `hampel7` | **相位链 ②** Hampel 鲁棒清洗 |
| 4 | `integrate_detrend_0` | `integrate_detrend` | **相位链 ③** 积分 + 最小二乘去趋势 + **600×80 窗口存储器** |
| 5 | `fir_resp_0` | `fir_bandpass` | **滤波** 呼吸带 0.15–0.60 Hz（1024 抽头） |
| 6 | `fir_card_0` | `fir_bandpass` | **滤波** 心脏带 0.80–2.00 Hz（同一份代码，第二次例化） |
| 7 | `null_model_cancel_0` | `null_model_cancel` | **鲁棒** 呼吸谐波 LMS 抵消 |
| 8 | `goertzel_resp_0` | `goertzel_sweep` | **谱估计** 呼吸谱 91 点 |
| 9 | `goertzel_vr_0` | `goertzel_sweep` | **谱估计** VR 曲线 201 点（60–110 bpm） |
| 10 | `spectrum_accum_0` | `spectrum_accum` | 跨 (bin,RX) 非相干谱累加（双写口 + 单读口） |
| 11 | `peak_argmax_0` | `peak_argmax` | 谱峰 + 抛物线亚 bin 插值 + 峰/中位对比度 |
| 12 | `bpm_map_0` | `bpm_map` | 峰值索引 → 心率 / 呼吸率（Q8.8） |
| 13 | `ratio_q15_0` | `ratio_q15` | peak/sum → Q1.15 竞争比 |
| 14 | `certificate_0` | `certificate_fsm` | **决策** 质量证书与分级（MEASURE / LOW_CONFIDENCE / REJECT_*） |
| 15 | `bin_selector_0` | `bin_selector` | 视觉距离 → 候选仓 / 空仓掩码 |
| 16 | `robot_motion_if_0` | `robot_motion_if` | 机器人运动门控 + 反向控制字 |
| 17 | `result_out_0` | `result_out` | **出口** 14 个 32 位结果寄存器 + AXI4-Lite 从端 + IRQ |
| 18 | `vs_engine_0` | `vs_engine_fsm` | **控制中枢**：按状态机调度上面每一步 |
| 19 | `vs_defaults_0` | `vs_defaults` | 占位/默认值源（尚未实现的输入集中在这里） |

> `vs_defaults_0` 是**故意**设的一个块：Vivado 对未连接的输入只给一条
> `BD 41-759` 警告然后**静默 tie 成 0**，分不清"设计成 0"和"忘了接线"。
> 把所有还没有数据源的输入（共模参考、分量统计量、运动阈值、自定位开关……）
> 收敛到它一处，BD 里就没有悬空输入，而"哪部分还是占位"在数据流图上一眼可见。

---

## 三、数据流：8 级

```
 PS7/DDR
   │ AXI-DMA MM2S（每帧 80 个 {Q[15:0],I[15:0]}，TUSER 标首字）
   ▼
①  radar_frame_if ──► dacm_phase ──► hampel7 ──► integrate_detrend
                                                   │ 600×80×24b 窗口存储器
                    ┌──────────────────────────────┴───────────────┐
                    ▼ (rd_sel=0)                                   ▼ (rd_sel=1)
②          fir_resp（呼吸带）                             fir_card（心脏带）
                    │                                              │
③                   ▼                                              ▼
        goertzel_resp（91 点谱）                        null_model_cancel（LMS 抵消）
                    │                                              │
                    │                                              ▼
                    │                                    goertzel_vr（201 点 VR 曲线）
                    └──────────────────┬───────────────────────────┘
                                       ▼ 双写口
④                            spectrum_accum（跨分量非相干累加）
                                       ▼
⑤                              peak_argmax（argmax + 抛物线插值 + 对比度）
                          ┌────────────┼─────────────┐
                          ▼            ▼             ▼
                    bpm_map      ratio_q15      certificate_fsm ◄── bin_selector
                 （→ 心率/呼吸率） （→ 竞争比）   （质量分级）        ◄── robot_motion_if
                                       │
⑥                                      ▼
                              result_out（14×32b 寄存器 + IRQ）──► PS7 中断
                                       ▲
⑦                        axi_gpio_ctrl（PS 写：视觉距离 / 机器人速度）
                                       ▲
⑧                        vs_engine_0（控制中枢：start/done 握手、band/grid 译码、
                                      窗口重开 win_start、测量完成 meas_done）
```

**关键特征**：`vs_engine_0` 调度的是 **"逐候选通道"** 的串行流程 ——
对 80 个 (RX,bin) 通道里命中 `bin_mask` 的那些，依次跑
`FIR → DFT →（心脏段）抵消 → DFT`，最后一次性做谱累加和决策。
所以两个 FIR、两个 DFT 虽然画成两个块，**实际是分时复用**。

---

## 四、核心算法在哪里（这是你最关心的部分）

核心算法全部在 **17 个模块**里，按功能分成 **5 条链**。真正承载 Python 算法的是其中
**11 个**（其余 6 个是接口/控制/换算）：

### 相位提取链（前处理，`rtl/frontend/`）

| Verilog 文件 | 关键算法 | 对应 Python |
|---|---|---|
| `dacm_phase.v` | **DACM**：`Δφ = (I·dQ − Q·dI) / (I² + Q²)`，内部用参数化逐位恢复除法器 `u_div` | `dsp.dacm_phase` |
| `hampel7.v` | 窗 7 **中值滤波 + MAD 野值剔除**（中值网络见 `common/median7.v`） | `dsp.hampel_axis` |
| `integrate_detrend.v` | **相位积分 → 逐通道最小二乘去趋势 → 600×80 窗口存储器**；均值/斜率各用一次除法 | `dsp.integrate_axis` + `detrend_axis` |
| `radar_frame_if.v` | 帧同步、通道解复用、分析窗门控 | `dataio.load_radar` + 窗口切片 |

### 数字滤波链（`rtl/filter/`）

| Verilog 文件 | 关键算法 | 对应 Python |
|---|---|---|
| `fir_bandpass.v` | **1024 抽头对称线性相位 FIR 带通**。镜像边界延拓 + 折叠 MAC（每拍一个抽头，只用 1 个乘法器）。对称 FIR 本身就是零相位，等价 `filtfilt`，不需要正反跑两遍 | `dsp.bandpass_axis`（butter+filtfilt） |

### 谱估计链（`rtl/spectral/`，算法的重心）

| Verilog 文件 | 关键算法 | 对应 Python |
|---|---|---|
| `goertzel_sweep.v` | **任意频率网格的精确 DFT 扫描**（不是 FFT！）：只需 ~200 个特定频点，用旋转因子递推逐点算，资源远小于 4096 点 FFT 且频点可任意非均匀 | `dsp.spectrum` + `_vr_sweep` 频率轴 |
| `null_model_cancel.v` | **呼吸谐波 + 共模的 LMS 自适应抵消**（权重 w←w+μ·e·u，μ≈2⁻⁷，sin/cos 查表见 `common/sin_lut.v`） | `_harmonic_residual` + `_vr_sweep` 的 QR 投影 |
| `spectrum_accum.v` | **跨 (bin,RX) 非相干谱累加** `P_fuse(f) = Σ_c P_c(f)` | `_fused_spectrum` |
| `peak_argmax.v` | **argmax + 抛物线亚 bin 插值** `δ = ½(a−c)/(a−2b+c)` + 峰/中位对比度；中位数用计数法 O(n²) | `np.argmax` + `dsp.parabolic_peak` |
| `ratio_q15.v` | 峰值竞争比 `peak/Σ` → Q1.15 | `competitive_vr` |
| `cm_ref_extract.v` | 共模参考通道（**已写好，但还没被引擎调度**） | `_common_mode_reference` 的 SVD 主成分 |

### 决策与协同（`rtl/cert/` `rtl/spatial/`）

| Verilog 文件 | 关键算法 | 对应 Python |
|---|---|---|
| `certificate_fsm.v` | **质量证书**：对比度/离散度/子窗偏差/野点比例加权成质量分 → `MEASURE / LOW_CONFIDENCE / REJECT_RANGE / MOTION / HARM`，门限与 Python 完全一致 | `estimator._certificate` |
| `bin_selector.v` | 视觉距离 → 候选仓掩码 + 空仓掩码 | `estimator.candidate_bins` |
| `robot_motion_if.v` | 机器人运动门控 + 反向控制字（hold/slow/meas） | `vision_geometry.motion_safe` |

### 换算与控制（`rtl/top/` `rtl/output/`）

| Verilog 文件 | 作用 |
|---|---|
| `bpm_map.v` | 峰值索引 → 心率/呼吸率 Q8.8（仿射：VR 网格 60+0.25k，呼吸网格 9+0.3k） |
| `vs_engine_fsm.v` | 时序编排状态机（把上面每一步按 start/done 握手串起来） |
| `vs_defaults.v` | 占位/默认值源 |
| `result_out.v` | 结果寄存器组 + AXI4-Lite 从端 + 中断 |

**一句话**：核心算法 = **`dacm_phase`（相位）→ `hampel7`（鲁棒）→ `integrate_detrend`（积分去趋势）→
`fir_bandpass`（带通）→ `goertzel_sweep`（谱）→ `null_model_cancel`（抵消）→
`spectrum_accum`（融合）→ `peak_argmax`（取峰）→ `certificate_fsm`（决策）** 这 9 个。

---

## 五、PS 端要做的三件事

1. **送数据**：DMA 每帧 80 个 32 位字，格式 `{Q[15:0], I[15:0]}`，首字 `TUSER=1`、末字 `TLAST=1`。
2. **收结果**：中断后读 `result_out` 寄存器（基址 `0x43C0_0000`）。
   **`heart_bpm` 在偏移 `0x00`，Q8.8 —— 读到的值除以 256 才是 bpm**；无输出时为 `0xFFFF`。
3. **回控机器人**：`0x28` 是回给机器人的控制字（bit0=hold / bit1=slow / bit2=meas），
   可以做"先停稳再测心率"的闭环。

---

## 六、资源实测（Vivado 2019.1，各模块 OOC 综合报告）

| 模块 | LUT | 其中当 RAM | FF | BRAM36 | DSP48 |
|---|---:|---:|---:|---:|---:|
| `integrate_detrend` | **92130** | **48000** | 17136 | 0 | 6 |
| `spectrum_accum` | 25014 | 0 | 8491 | 0 | 0 |
| `null_model_cancel` | 18497 | 0 | 1581 | 0 | 52 |
| `peak_argmax` | 17949 | 0 | 8699 | 0 | 0 |
| `fir_card` | 9231 | 0 | 14541 | 0 | 2 |
| `fir_resp` | 9231 | 0 | 14541 | 0 | 2 |
| `goertzel_resp` | 6781 | 0 | 14728 | 0 | 10 |
| `goertzel_vr` | 6781 | 0 | 14728 | 0 | 10 |
| `hampel7` | 5175 | 0 | 11612 | 0 | 1 |
| `certificate_fsm` | 3025 | 0 | 28 | 0 | 6 |
| `ratio_q15` | 1584 | 0 | 16 | 0 | 0 |
| `dacm_phase` | 1092 | 0 | 2825 | 0 | 4 |
| `bin_selector` | 854 | 0 | 38 | 0 | 1 |
| 其余 6 个（result_out / vs_engine / robot / bpm_map / radar / defaults） | 300 | 0 | 291 | 0 | 0 |
| **合计** | **197644** | **48000** | **109255** | **0** | **94** |
| **ZYNQ7020 上限** | 53200 | 17400 | 106400 | 140 | 220 |
| 占用率 | **371%** | **276%** | **103%** | 0% | 43% |

**结论：算法结构没问题，但存储器的映射方式让它放不进 7020。**
`place_design` 报 `[Place 30-640] This design requires more Slice LUTs ... 187451 / 53200` 就是这个原因。

三个根因（按影响排序）：

1. **BRAM 用量是 0，1.15 Mbit 的窗口存储器全塞进了分布式 RAM**（48000 个 LUT）。
   根因在 `integrate_detrend.v` 的 `S_APPLY` 状态：`ap_val = mem[ap_idx]` 是**组合读**，
   BRAM 做不到异步读，综合器只能整块退化成 LUTRAM。
2. **同一模块还有 44130 个纯逻辑 LUT**：`c = ap_idx / N_CH` 是**组合除法器**、
   `mean_r[c]` / `slope_r[c]` 是 **80:1 组合多路选择器**、`for k=0..79` 的并行复位网络。
3. **FF 超限**（109255 > 106400）：大数组被实现成了触发器
   （FIR 的 `samp_buf` 14400×2、`peak_argmax.vals` 8192、`spectrum_accum.mem` 8192）。

### 本轮已经修掉的（不改变任何功能，只改 `ram_style` 属性）

| 文件 | 改动 | 收益 |
|---|---|---|
| `fir_bandpass.v` | `samp_buf` 由 `ram_style="block"` 改为 `"distributed"`（异步读根本用不了 BRAM，写 block 只会逼它变触发器） | 省 **28800 FF** |
| `peak_argmax.v` | `vals` 显式声明 `ram_style="distributed"`（同拍要读 5 个地址，只能用 LUTRAM 复制） | 省 **8192 FF** |
| `spectrum_accum.v` | `mem` 显式声明 `ram_style="distributed"`（双写口 BRAM 实现不了，LUTRAM 复制两份即可） | 省 **8192 FF** |

预计修正后：**FF ≈ 63k / 106400 ✓、LUT 当 RAM ≈ 1.5k / 17400 ✓**，剩下 LUT 仍约 150k / 53200（2.8×）。

### 还需要做的（按性价比排序）

| # | 动作 | 预计省 |
|---:|---|---|
| 1 | `integrate_detrend` 重构：窗口存储器改**同步读**（把 `S_APPLY` 的读-改-写改成两级流水），加 `ram_style="block"` | 48000 LUTRAM → 32 BRAM36，LUT −48000 |
| 2 | 同上：`ap_idx / N_CH` 换成 `(n_cnt, ch_cnt)` 两个计数器 | 去掉组合除法器，LUT −数 k |
| 3 | 同上：`mean_r` / `slope_r` 也搬进小 BRAM（80×24b / 80×40b），消除 80:1 组合 mux | LUT −2 万量级 |
| 4 | `null_model_cancel`：LMS 权重更新串行化（现在一次算完所有谐波，52 个 DSP + 18.5k LUT） | LUT −1 万量级，DSP 也降 |
| 5 | `peak_argmax`：两个 64 位**组合**除法器换成复用 `u_div`（多周期） | LUT −1 万量级 |
| 6 | `spectrum_accum`：并行清零网络改顺序清零 | LUT −1 万量级 |
| 7 | 可选：两个 FIR 合并成一个分时复用（引擎加一个 `band_sel` 输出） | LUT −9231、FF −14541 |

---

## 七、当前状态小结

| 项 | 状态 |
|---|---|
| RTL 结构完整性 | ✅ 25 个 `.v`，静态检查通过 |
| Block Design | ✅ 28 个单元、`validate_bd_design OK`、悬空输入 0、位宽全匹配 |
| 综合 | ✅ 通过（各模块均 OOC 综合成功） |
| 实现 | ❌ `place_design` 失败：器件资源不够（见第六节） |
| 功能完整性 | ⚠️ 3 处设计内占位：共模参考未调度、分量统计量取常量、运动阈值走常量 |
