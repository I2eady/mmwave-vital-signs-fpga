# src — 设计源码

## 目录

```
src/
├── rtl/            可综合 Verilog（PL 侧）
│   ├── common/     公共原语：逐位除法器、7 输入中值网络、正余弦 ROM
│   ├── frontend/   相位提取链：帧接口 → DACM → Hampel → 积分/去趋势 + 窗口存储器
│   ├── spatial/    空间选择与机器人协同：候选仓位选择、运动门控
│   ├── filter/     1024 抽头线性相位 FIR（含备用的 IIR 二阶节路径）
│   ├── spectral/   谱估计：任意频点 DFT 扫描、LMS 谐波抵消、谱累加、峰值搜索
│   ├── cert/       质量证书分级状态机
│   ├── output/     结果寄存器块（自写 AXI4-Lite 从端 + 中断）
│   └── top/        引擎编排 FSM、bpm 换算、默认值源、单块集成版顶层
└── ps/             PS 侧（ARM）软件说明：寄存器映射与 DMA 时序
```

## RTL 清单（25 个 `.v`）

### 进 Block Design 的算法模块（17 个模块 / 19 个实例）

| 模块 | 文件 | 说明 |
|---|---|---|
| `radar_frame_if` | `frontend/radar_frame_if.v` | AXI-Stream 帧入口，拆成 `(ch, I, Q)` 通道流，维护分析窗计数 |
| `dacm_phase` | `frontend/dacm_phase.v` | DACM 相位差分提取 |
| `hampel7` | `frontend/hampel7.v` | 窗 7 中值 + MAD 野值剔除 |
| `integrate_detrend` | `frontend/integrate_detrend.v` | 积分、逐通道最小二乘去趋势、600×80 窗口存储器 |
| `bin_selector` | `spatial/bin_selector.v` | 视觉距离 → 候选仓集合与空仓掩码 |
| `robot_motion_if` | `spatial/robot_motion_if.v` | 底盘速度 → 运动门控 + 反向控制字 |
| `fir_bandpass` ×2 | `filter/fir_bandpass.v` | 1024 抽头对称线性相位带通（呼吸带 / 心脏带） |
| `goertzel_sweep` ×2 | `spectral/goertzel_sweep.v` | 可编程频率网格的精确 DFT 扫描 |
| `null_model_cancel` | `spectral/null_model_cancel.v` | 呼吸谐波 + 共模参考的 LMS 自适应抵消 |
| `spectrum_accum` | `spectral/spectrum_accum.v` | 跨 (bin, RX) 非相干谱累加 |
| `peak_argmax` | `spectral/peak_argmax.v` | 谱峰 argmax + 抛物线亚 bin 插值 + 对比度 |
| `ratio_q15` | `spectral/ratio_q15.v` | 峰值 / 谱和 → Q1.15 竞争比 |
| `certificate_fsm` | `cert/certificate_fsm.v` | 质量分与决策分级 |
| `result_out` | `output/result_out.v` | AXI4-Lite 结果寄存器 + 中断 |
| `vs_engine_fsm` | `top/vs_engine_fsm.v` | 全流程调度（频带 / 网格 / 峰值 / 证书） |
| `bpm_map` | `top/bpm_map.v` | 峰值索引 → bpm（Q8.8） |
| `vs_defaults` | `top/vs_defaults.v` | 尚未有数据源的输入的集中默认值源 |

### 公共子模块（在模块内部例化，画布上不可见）

| 模块 | 文件 | 被谁使用 |
|---|---|---|
| `u_div` | `common/u_div.v` | `dacm_phase`（逐位恢复除法） |
| `median7` | `common/median7.v` | `hampel7` |
| `sin_lut` | `common/sin_lut.v` | `null_model_cancel`（谐波基） |
| `iir_biquad` | `filter/iir_biquad.v` | `biquad_cascade` |
| `biquad_coeff_rom` | `filter/biquad_coeff_rom.v` | `biquad_cascade` |

### 备选 / 预留路径（不参与当前 Block Design）

| 模块 | 文件 | 说明 |
|---|---|---|
| `biquad_cascade` | `filter/biquad_cascade.v` | IIR 二阶节级联的备选滤波路径，保留以便与 FIR 结果对照 |
| `cm_ref_extract` | `spectral/cm_ref_extract.v` | 共模参考通道（空仓带通均值 + 延迟正交），已实现待调度 |
| `vital_signs_top` | `top/vital_signs_top.v` | 纯 RTL 单块集成版顶层，用于不建 BD 时的整体综合/仿真 |

## ROM 初始化文件（`.mem`）

| 文件 | 内容 | 行数 |
|---|---|---|
| `common/sin_lut.mem` | 4096 点正弦表（s16 Q1.15） | 4096 |
| `spectral/sin_lut.mem` | 同上副本，供 `spectral/` 下的模块就近读取 | 4096 |
| `filter/fir_coeff.mem` | 3 频带 × 512 个唯一系数（s18 Q1.15，对称 FIR 半系数） | 1536 |
| `filter/coeff_rom.mem` | IIR 备选路径的二阶节系数（Q4.14） | 80 |
| `spectral/dft_delta.mem` | 4 网格 × 256 点相位增量（uint32） | 1024 |

全部由 `build/scripts/gen_rom.py` 生成，不要手工编辑；其可读版本见 `data/rom_tables/`。

## 定点格式速查

| 量 | 位宽 | 格式 | 小数位 |
|---|---:|---|---:|
| 相位 / 差分相位 | 24 | 有符号定点 | 16 |
| 样本 `I/Q` | 16 | 有符号整数 | 0 |
| FIR 系数 | 18 | Q1.15 | 15 |
| 谱幅度（累加后） | 32 | 无符号 | 0 |
| 频带中心增益 | 24 | 有符号 | 16 |
| bpm | 16 | Q8.8 | 8 |
| 概率 / 一致性（support、quality） | 16 | Q1.15 | 15 |
| 频带选择 / 网格号 | 2 | 无符号整数 | 0 |
