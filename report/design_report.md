# 架构与移植说明：Python `scr/` → FPGA Verilog

> 目标器件：**Xilinx ZYNQ-7020（xc7z020clg400-2）**
> 时钟：PS FCLK_CLK0 = 100 MHz，PL 单一时钟域
> 源码：`fpga/src/rtl/`　工程：`fpga/build/vivado/vs_fpga.xpr`　Block Design：`vs_bd`

---

## 1. 总体策略

Python 管线是"**批处理 + 浮点 + 矩阵分解**"：600×80 复数张量一次读入，
用 numpy/scipy 做 SVD、lstsq、QR、FFT。直接照搬到 RTL 不可综合也不可能。

移植遵循三条原则：

1. **数值上可映射的阶段严格等价移植**（DACM、Hampel、积分/去趋势、argmax、抛物线插值、证书门限）。
2. **矩阵分解类操作换成硬件可行的等价目标函数实现**，并明确记录近似程度。
3. **结构上与数据率匹配的替换**：20 Hz 帧率意味着每秒只有 1600 个复数样本，
   吞吐完全不是瓶颈，**资源与数值稳定性才是**。因此优先选择系数良态、
   无需逐级定标的结构（线性相位 FIR、频点精确 DFT）。

---

## 2. 逐阶段映射表

### 2.1 采集与窗口

| Python | Verilog | 说明 |
|---|---|---|
| `dataio.load_radar` → `X:(M,R,B)` | `radar_frame_if` | 硬件按帧串行输入：每帧 80 个复数样本，顺序 `ch = rx*20 + bin` |
| `estimator.estimate` 的 `X[start:stop]` | `radar_frame_if` 的 `win_active` / `win_done` | 帧计数 300…899（=15 s…45 s @20 Hz）对应正式分析窗 |
| — | 输入接口 | AXI4-Stream，32 bit `{Q[15:0], I[15:0]}`，由 PS 侧 DMA(MM2S) 送入 |

**定点**：`I, Q : s16`（雷达 TLV 原生 16 bit）。

---

### 2.2 相位提取：DACM

```python
# dsp.py
dphi[m] = (I[m]*dQ[m] - Q[m]*dI[m]) / (I[m]**2 + Q[m]**2)
```

`src/rtl/frontend/dacm_phase.v`

| 环节 | 位宽 / 格式 |
|---|---|
| `dI, dQ` | s17 |
| `I*dQ`, `Q*dI` | s33 |
| `num = I*dQ - Q*dI` | **s34** |
| `den = I^2 + Q^2` | **u32** |
| `dphi = ±|num|<<20 / den` | **s24, Q4.20**（弧度） |
| 除法器 | `u_div`，逐位恢复余数法，34+20=54 拍 |

- 每通道独立保存上一帧 `I/Q`（80 组，分布式 RAM）。
- 除法器吞吐 54 拍/样本，数据率仅 80 样本/50 ms → 占用率 < 0.1%。
- **保真度：等价**（仅定点量化误差，Q4.20 分辨率 ≈ 1e-6 rad）。

---

### 2.3 鲁棒清洗：Hampel（窗 7，3σ）

```python
win = x[i-3 .. i+3]          # 居中窗，边界 reflect 填充
med = median(win); mad = median(|win - med|)
out = |x[i] - med| > 3.0*1.4826*mad ? med : x[i]
```

`src/rtl/frontend/hampel7.v` + `src/rtl/common/median7.v`

- `median7`：奇偶转置排序网络（7 级、最多 21 个比较器），纯组合。
- 两个 `median7` 实例：一个求 `med`，一个求 MAD。
- 每通道 7 级移位窗（80×7×24 bit）。
- 阈值系数 `K = 3.0 × 1.4826 = 4.4478` 以 **Q4.12 = 18218** 存；
  `thr = (mad * K) >> 12`。
- 时序：输出对应"当前窗中心样本"（3 个样本前），通道号与 `tlast` 延迟 3 拍对齐。

**与 Python 的差异**：Python 用 `reflect` 填充边界；硬件从零起步，
只影响每个通道前 3 个样本，对 600 样本窗可忽略。

---

### 2.4 积分 + 最小二乘去趋势 + 窗口存储器

```python
phi   = cumsum(dphi)
t     = arange(N) - (N-1)/2
mean  = phi.mean()
slope = sum(phi*t) / sum(t*t)
y     = phi - mean - slope*t
```

`src/rtl/frontend/integrate_detrend.v`

三段式 FSM：

| 阶段 | 动作 | 拍数 |
|---|---|---|
| `S_FILL` | 逐通道累加得 φ，写入 BRAM，同时累加 `sum(φ)` 与 `sum(n·φ)` | 48000 |
| `S_CALC` | 每通道用 `u_div` 求 `mean` 与 `slope` | 80 × ~130 |
| `S_APPLY` | 遍历 48000 个地址，读-改-写 `y = φ - mean - slope·t` | 48000 |
| `S_READY` | `win_ready` 拉高，供下游引擎读取 | — |

推导（避免宽位除法）：
```
tmean = (N-1)/2
slope = (2·sum(nφ) − (N−1)·sum(φ)) / ( N(N²−1)/6 )
      = num2 / den2 ,  den2 = 35,999,900 (N=600)
```

**定点**
| 量 | 格式 |
|---|---|
| φ（位移） | s24 **Q8.16**，累加器 32 bit 饱和 |
| `sum(φ)` | s48 |
| `sum(n·φ)` | s56 |
| `mean` | s24 Q8.16 |
| `slope` | s40 **Q16.24** |

**窗口存储器**：48000 × 24 bit = **1.15 Mb ≈ 32 个 BRAM36**，
双读地址端口（`rd_addr` 给呼吸 FIR，`rd_addr_b` 给心脏 FIR，`rd_sel` 选择）。

**保真度：等价**（对 600 点窗口的严格最小二乘，误差仅来自定点）。

---

### 2.5 空间选择

```python
center = round((range_m - 0.35) * 38)        # 1/bin_spacing = 38
half   = ceil(0.12 * 38) = 5
bins   = [clamp(center-5,0,19), clamp(center+6,0,20))
free   = 其余仓
out_of_range = 距 0.35~0.85 m 带的余量 > 0.12 m
```

`src/rtl/spatial/bin_selector.v`

- 距离用 **Q16.16**（来自 PS 的视觉几何 / AXI-GPIO）。
- 全组合实现，输出 `bin_mask[19:0]` / `free_mask[19:0]` / `subject_bin` / `out_of_range`。
- **Abation A（雷达自定位回退）**：视觉距离越界且 `radar_loc_valid` 时，
  改用输入 `radar_loc_bin`（呼吸带距离能量峰）反算等效距离，
  避免误判 `REJECT_RANGE`——与 Python 的 `_effective_range` 同逻辑。

**保真度：等价。**

---

### 2.6 机器人运动门控

`src/rtl/spatial/robot_motion_if.v`

| 输入（AXI-GPIO） | 输出 |
|---|---|
| `reg_vision_range` 视觉距离 Q16.16 | `vision_range_q16` → bin_selector |
| `reg_robot_vel` 机器人速度 mm/s | `motion_safe` / `motion_reject` → certificate |
| `reg_motion_thresh` 运动门限 mm/s | `robot_cmd_out` → 机器人（hold / slow / meas / unsafe） |
| `reg_ctrl[0]` 测量使能 | `meas_enable` |

**闭环语义**：测量窗内速度超门限 → `motion_reject=1` → 证书判 `REJECT_MOTION`，
同时反向请求机器人减速/悬停。"机器人控制"与"雷达心率监测"因此在 PL 内闭环。

Python 侧对应 `vision_geometry.json` 的 `motion_safe` 与
`estimator` 里基于 `outlier_fraction` 的运动判据。

---

### 2.7 带通滤波 —— **结构替换：FIR**

```python
# dsp.py
b, a = butter(4, [lo/nyq, hi/nyq], btype='band')
y    = filtfilt(b, a, x)     # 零相位，等效 8 阶
```

`src/rtl/filter/fir_bandpass.v`

#### 为什么换掉 IIR？

对 `resp = (0.15, 0.60) Hz @ fs=20 Hz` 实测 scipy SOS：

| 二阶节 | b0 | 该节带中心增益 |
|---|---:|---:|
| #0 | 2.0e-5 | 0.011 |
| #1 | 1.0 | 472 |
| #2 | 1.0 | — |
| #3 | 1.0 | — |

问题有三：
1. **b 系数小到 2e-5**，Q4.14 的量化步长是 6.1e-5 → 直接量化成 0，滤波器退化。
2. **各级增益跨 4 个数量级**（0.011 ~ 472），级间中间量必然下溢/溢出，
   需要逐级定标（每级一个 2^k 移位），且中间量位宽要额外加宽。
3. `filtfilt` 还要正/反向各跑一遍，中间结果要暂存。

#### 改用 1024 抽头线性相位 FIR

| 项 | 值 |
|---|---|
| 抽头数 | 1024（偶数、对称 → 512 个唯一系数） |
| 设计 | `firwin(1024, [lo,hi], window='hamming')`，带中心归一到单位增益 |
| 设计截止点 | 目标带外扩半个过渡带（≈0.032 Hz），保证目标带内平坦 |
| 系数格式 | **s18 Q1.15**（最大 \|h\| = 0.123，精度 0.05%） |
| 边界 | 镜像延拓 `reflect`，600 个输出样本全部有效 |
| 实测 | 通带增益 **0.997 ~ 1.003**，阻带 ≤ **2e-3（−54 dB）** |

对称 FIR **本身就是零相位**，不需要 filtfilt 的正/反向两遍，也不需要级联定标。

**计算量**：512 MAC × 600 = 30.7 万拍/通道。约 40 个候选通道 × 2 条路径
= 24.6 M 拍 ≈ **246 ms**（100 MHz），相对 30 s 窗长余量充足。

**与 Python 的差异**：`butter(4)+filtfilt` 的过渡带更陡（8 阶 IIR），
FIR 的过渡带为 ~0.064 Hz。对呼吸/心率估计而言，带内平坦度才是关键量，
两者的带内增益都归一到 1，因此不构成实质性差异。

---

### 2.8 频谱 —— **结构替换：频点精确 DFT**

```python
freqs, P = dsp.spectrum(x, fs, pad_factor=4)   # Blackman 窗 + 4096 点 rfft
```

`src/rtl/spectral/goertzel_sweep.v`

硬件不做 FFT，而是直接在**需要的频点上**求 DTFT：

```
X(f_k) = Σ_n x[n]·exp(-j·2π·f_k·n/fs)
|X|²  = Re² + Im²
```

- 每个频点的相位增量 `Δ_k = f_k/fs · 2³²` 存入 ROM（`dft_delta.mem`）。
- sin/cos 由共享 4096 点 LUT（`sin_lut.mem`）给出。
- 内部把整窗（600×24 bit）缓存，对每个频点重放一遍。
- 采用矩形窗（不加 Blackman）—— 因为频点是**任意指定**的，不存在 FFT 的
  bin 量化栅栏效应；Blackman 窗的作用（抑制旁瓣泄漏）在这里由后续的
  `null_model_cancel` 与证书的对比度判据部分承担。

三个网格：

| 网格 | 用途 | 范围 | 步长 | 点数 |
|---|---|---|---:|---:|
| 0 | 呼吸率谱峰 | 0.15 – 0.60 Hz | 0.005 Hz | 91 |
| 1 | **VR 扫描（心率）** | 60 – 110 bpm | 0.25 bpm | **201** |
| 2 | 心脏带谱（诊断） | 0.80 – 2.00 Hz | 0.01 Hz | 121 |

**计算量**：201 × 600 = 12.1 万拍/频点扫描，约 1.2 ms @100 MHz。

---

### 2.9 零模型抵消 —— **近似：LMS 自适应抵消**

Python 做的是两件事：

```python
# _harmonic_residual：拟合呼吸谐波的 sin/cos 并减去
H = [1, sin(k·w_r·t), cos(k·w_r·t)]  k=2..12
beta = lstsq(H, phi)
resid = phi - H·beta

# _vr_sweep：把零模型 A 正交化后，测每个候选频率的额外方差解释比例
QH = qr(H)
VR(f) = (RSS_A - RSS_B)/RSS_A
```

`src/rtl/spectral/null_model_cancel.v`

硬件用一个 **LMS 自适应抵消器**实现同一目标函数：

```
零模型 A = span{ sin/cos(k·w_r), k=2..12 ; ref_I, ref_Q }
e = x − Σ_k (a_k·sin_k + b_k·cos_k) − (c_I·ref_I + c_Q·ref_Q)
w ← w + μ·e·u        μ = 2⁻⁷ ≈ 0.0078
```

抵消后的残差 `e` 直接送 `goertzel_sweep` 做 VR 扫描：

```
VR_hw(f) ≈ |DFT_e(f)|² / 归一化
```

这与"先投影掉零模型、再测 f 处的新增方差"在数学上是同一件事的两种写法：
零模型频率处（呼吸谐波、~1.0 Hz 共模）的谱分量被抵消器吃掉，
因此该处的 VR 自然趋近于 0 —— 正是 Python 用 QR 正交化想表达的效果
（"与呼吸谐波重合的心搏基频会得到接近零的得分并被标记"）。

**参数与资源**
| 项 | 值 |
|---|---|
| 谐波阶数 | k = 2..12（11 个，对应 `harmonic_max_order=12`） |
| 抽头数 | 11×2 + 2 = **24** |
| 每样本乘加 | 48（并行 DSP48） |
| 相位累加器 | 12 个 32 bit，`Δ = k·fr_inc` |

**近似程度（重要）**：
- Python 是**批处理最小二乘**，硬件是**在线 LMS**。在 600 样本、干扰源频率已知
  且平稳的条件下，LMS 的稳态解收敛到同一组系数；**收敛速度**与 `μ` 相关。
- Python 的 `th_r` 由呼吸带谱峰给出（0.005 Hz 网格 + 抛物线），
  硬件同样用 `goertzel_resp`+`peak_argmax` 给出，量级一致。
- 常数项（DC）未显式建模 —— 上游心脏带 FIR 已经去掉了 DC。

---

### 2.10 共模参考 —— **近似：均值 + 正交副相**

```python
# _common_mode_reference
eb = bandpass(phi[:, free_bins, :], 0.95, 1.20, fs)
_, sv, vt = svd(eb.T)
r = vt[0] / std(vt[0])       # 第一主成分
cols = [r, hilbert(r)]        # + 希尔伯特正交分量
```

`src/rtl/spectral/cm_ref_extract.v`

硬件的替代实现：

| Python | 硬件 |
|---|---|
| 空仓集合上做 80×80（或 nfree×nfree）SVD 取 PC1 | 空仓带通信号的**加权均值**（近似的"最优线性组合"） |
| `scipy.signal.hilbert` 做 90° 相移 | 固定 **5 个样本延迟**（≈ fs/4/f_cm = 20/4/1.05）近似 90° 相移 |

两列张成的子空间性质相同：都能在心脏带内把 0.95–1.20 Hz 的共模扰动投影掉。
带宽刻意保持窄（`cm_ref_band`）—— 因为距离旁瓣会把被试能量泄进"空"仓，
参考带放宽反而会抵消心搏本身。

**近似程度（本移植最主要的近似之一）**：若各空仓的共模分量相位一致，
均值等价于 PC1；实际存在相位散布时，均值会略微削弱参考幅度（不改变频率特性）。

---

### 2.11 谱融合

```python
# _fused_spectrum：按"带内峰/带内中位 dB"加权，75 分位封顶，非相干平均
q = 20*log10(peak/median)
w = clip(q, 0, percentile(w,75))
P_fuse = Σ w_c·P_c / Σ w_c
```

`src/rtl/spectral/spectrum_accum.v`

硬件用**等权非相干累加**：`P_fuse(f) = Σ_c P_c(f)`。

**近似程度**：省掉了 80 组对数 / 中位数 / 分位数运算。
在 4 RX × ~10 候选仓（约 40 个分量）的规模下，等权与加权结果的排序高度一致，
而最终只用得到 argmax 与其峰/中位对比度，因此不影响决策。

累加器为 256 × 32 bit，配 3 级流水的读-改-写，有 A/B 两个写端口
（呼吸 DFT 与心脏/VR DFT 各一路）。

---

### 2.12 峰值搜索与亚 bin 插值

```python
k_best = np.argmax(vr_curve)
contrast = vr_curve[k] / np.median(vr_curve)
delta = 0.5*(a-c)/(a-2b+c)      # 抛物线插值
f = grid[k] + delta * step
```

`src/rtl/spectral/peak_argmax.v`

- 把 npts 个幅度一次性读入本地寄存器阵列（≤256 × 32 bit）。
- **argmax + 谱和**：单遍。
- **中位数**：计数法 O(n²)（`cnt_i = #{j : v_j < v_i}`，取 `cnt ≤ n/2` 中最大的），
  201² ≈ 4 万拍 ≈ 0.4 ms。与 Python 的 `np.median` 一致。
- **抛物线插值**：`delta = 0.5·num/den`，输出 **Q1.10**（±512），下游换算成频率。
- **对比度**：`peak·4096/median`，输出 **Q4.12**，直接与 `vr_contrast_min=1.15` 比较。

**保真度：等价。**

---

### 2.13 质量证书

```python
# _certificate
if out_of_range:                     REJECT_RANGE
elif not finite(candidate):          NO_CANDIDATE
elif outlier_frac > 0.12:            REJECT_MOTION
elif competitive_vr < 0.05:          REJECT_HARMONIC_UNRESOLVABLE
elif vr_contrast < 1.15:             REJECT_HARMONIC_UNRESOLVABLE
else:  heart_bpm = candidate
       support >= 0.50 ? MEASURE : LOW_CONFIDENCE

q = 20 + 20·clip(cdb/12) + 15·support + 10·clip(1−disp/10)
      + 10·clip(1−Δtsub/12) − 20·clip(ofrac/0.20) − 5·[harmonic_collision]
```

`src/rtl/cert/certificate_fsm.v`

**判定优先级、门限值、质量分公式全部与 Python 一致**，门限来自
直接写在 `certificate_fsm.v` 里（早期放在 `vs_params.vh` 用宏，后因
**BD 的 HDL 解析器不支持 `` `include ``** 而全部内联为字面量）：

| 字面量（在 certificate_fsm.v 中） | 值 | 对应 `config.py` |
|---|---:|---|
| `outlier_q15 > 16'd3932` | 3932 | `outlier_fraction_limit = 0.12` |
| `support_q15 >= 16'd16384` | 16384 | `support_min = 0.50` |
| `compet_vr_q15 < 16'd1638` | 1638 | `vr_min = 0.05` |
| `vr_contrast_q12 < 32'd4710` | 4710 | `vr_contrast_min = 1.15` |
| `K_Q12 = 18218`（hampel7.v） | 18218 | `3.0 × 1.4826 = 4.4478` @ Q4.12 |
| `NPTS_VR = 201`（vs_engine_fsm.v） | 201 | `(110-60)/0.25 + 1` |

**当前缺口（必须知道）**：`support`（分量一致度）与 `disperison_bpm`
需要**逐分量**保存 argmax 并做中位数统计。当前版本用常量 0.8 占位，
因此证书会输出 MEASURE 级；`harmonic_collision` 也置 0。
要完整复现，需要把 `spectrum_accum` 扩展为"逐分量独立累加 + 分量级 argmax 缓存 + MAD 统计"。

---

### 2.14 结果输出

`src/rtl/output/result_out.v` —— 自实现的 AXI4-Lite 从端（16 个 32 bit 寄存器）+ IRQ。

| 偏移 | 内容 |
|---|---|
| 0x00 | `heart_bpm` Q8.8（0xFFFF = 无输出） |
| 0x04 | `respiration_bpm` Q8.8 |
| 0x08 | `{decision[2:0], quality[15:0]}` |
| 0x0C | `{support, confidence}` |
| 0x10 | `{vr_contrast Q4.12, competitive_vr Q1.15}` |
| 0x14 | `{harmonic_collision, motion_reject, out_of_range, outlier_frac}` |
| 0x18 | `bin_mask[19:0]` |
| 0x1C | `{n_free_bins, n_bins_sel}` |
| 0x20 | `effective_range` Q16.16 |
| 0x24 | `{busy, win_ready}` |
| 0x28 | `robot_cmd_out` |
| 0x2C | `fr_inc`（呼吸率相位增量，诊断） |
| 0x30 | `frame_cnt` |
| 0x34 | 写任意值清 IRQ |

---

## 3. 时序编排

`src/rtl/top/vs_engine_fsm.v` —— 对应 `VitalSignsEstimator.estimate()` 的控制流。

```
IDLE ──win_ready──▶ CLR(清谱累加器)
                     │
        ┌────────────┴─── 对每个候选通道 ch ∈ bin_mask ────────────┐
        │  R_REQ → fir_resp.start → R_BFW → goertzel_resp.start    │
        │        → R_GZW → 下一个 ch                               │
        └──────────────────────┬──────────────────────────────────┘
                               ▼
                            R_PK (pk_sel=0, 91 点 → f_r)
                               ▼
        ┌────────────┴─── 对每个候选通道 ch ∈ bin_mask ────────────┐
        │  C_REQ → fir_card.start → C_BFW → nc_clr                 │
        │        → goertzel_vr.start → C_GZW → 下一个 ch           │
        └──────────────────────┬──────────────────────────────────┘
                               ▼
                            C_PK (pk_sel=1, 201 点 → 心率候选 + 对比度)
                               ▼
                            CERT → DONE(meas_done 脉冲)
```

band/grid 的译码（`bf_start_resp/card`、`gz_start_resp/vr`）放在 FSM 内部，
使 Block Design 中各引擎与编排器之间是直接的 1:1 控制线，数据流图更干净。

---

## 4. 定点格式总表

| 信号 | 位宽 | 格式 | 说明 |
|---|---:|---|---|
| I / Q | 16 | s16 | 雷达 TLV 原生 |
| dphi | 24 | **Q4.20** | 相位增量 (rad) |
| dphi_clean | 24 | Q4.20 | Hampel 清洗后 |
| φ（位移） | 24 | **Q8.16** | 积分结果，饱和 |
| mean | 24 | Q8.16 | 通道均值 |
| slope | 40 | **Q16.24** | 去趋势斜率 |
| FIR 系数 | 18 | **Q1.15** | 最大 0.123 |
| FIR 数据 / 输出 | 24 | Q8.16 | 零相位带通 |
| DFT 相位增量 | 32 | 2³² ≡ 1 圈 | `sin_lut` 地址取高 12 位 |
| sin / cos | 16 | Q1.15 | — |
| LMS 权重 | 24 | Q8.16 | μ = 2⁻⁷ ≈ 0.0078 |
| 谱幅度 \|X\|² | 32 | 无量纲（比较用） | 饱和 |
| bpm | 16 | **Q8.8** | 0xFFFF = 无效 |
| 0..1 比例量 | 16 | **Q1.15** | support / outlier_frac / vr |
| 频率（Hz） | 32 | Q16.16 | 视觉距离 / 呼吸率 |
| 对比度 | 32 | **Q4.12** | peak/median |

---

## 5. 资源与时间预算

### 资源（ZYNQ-7020：140×BRAM36 / 220×DSP48E1 / 106 400 FF / 53 200 LUT）

| 模块 | BRAM36 | DSP48 | 说明 |
|---|---:|---:|---|
| `integrate_detrend` 窗口存储器 | 32 | 1 | 48000×24 bit |
| `fir_bandpass` ×2 | 2×2 | 2×1 | 600×24 缓冲 + 3×512 系数 |
| `goertzel_sweep` ×2 | 2×2 | 2×1 | 600×24 缓存 + 正弦 LUT |
| `null_model_cancel` | 12 | 6 | 12 个 sin/cos LUT 副本 |
| `median7` / `hampel7` | 0 | 0 | LUTRAM |
| `spectrum_accum` / `peak_argmax` | 1 | 0 | — |
| `result_out` / 其他 | 1 | 0 | — |
| **合计（估）** | **≈ 54** | **≈ 14** | 余量充足 |

### 时间（100 MHz，单个 30 s 分析窗）

| 阶段 | 拍数 | 时间 |
|---|---:|---:|
| 相位链（流式，与采集同步） | — | 实时 |
| 去趋势（FILL + CALC + APPLY） | ~106 k | 1.1 ms |
| 呼吸路径：40 通道 × (FIR 307 k + DFT 55 k) | 14.5 M | 145 ms |
| 心脏路径：40 通道 × (FIR 307 k + LMS 29 k + DFT 121 k) | 18.3 M | 183 ms |
| 峰值 + 证书 | ~0.2 M | 2 ms |
| **合计** | **≈ 33 M** | **≈ 331 ms** |

**实时余量 ≈ 90 倍**（30 s 窗内只需 0.33 s 计算）。

---

## 6. 全部近似点清单（移植审计用）

| # | Python | 硬件 | 影响 |
|---|---|---|---|
| A1 | `butter(4)+filtfilt` | 1024 抽头线性相位 FIR | 过渡带更宽；带内增益均归一到 1 |
| A2 | `rfft` + Blackman 窗 + 4× 零填充 | 频点精确 DFT + 矩形窗 | 无栅栏效应；旁瓣抑制由抵消器承担 |
| A3 | `np.linalg.lstsq`（谐波回归） | LMS 在线抵消 | 稳态一致；收敛依赖 μ 与样本数 |
| A4 | `np.linalg.svd`（共模 PC1） | 空仓带通均值 | 相位散布时参考幅度略弱 |
| A5 | `np.linalg.qr`（VR 投影） | 抵消后取周期图 | 功能等价（谐波处 VR→0） |
| A6 | `scipy.signal.hilbert` | 5 样本延迟近似 90° | 仅共模带（0.95–1.20 Hz）近似 |
| A7 | 质量加权谱融合 | 等权非相干累加 | 影响有限（仅用于 argmax） |
| A8 | `Hampel` 边界 `reflect` | 零起步 | 每通道前 3 个样本 |
| A9 | `support` / `dispersion` / `subwin_delta` / `outlier` 分量统计 | `vs_defaults` 送常量（support=0.8，其余 0） | 证书恒为 MEASURE 级 —— **需补全**。这些占位值集中写在 `src/rtl/top/vs_defaults.v` 的参数里，改一处即可 |
| A10 | `harmonic_collision` 标记 | 置 0 | 不影响硬性闸门 |

---

## 7. 后续工作建议

1. **补全 `support`**：扩展 `spectrum_accum` 为逐分量累加 + 分量级 argmax 缓存，
   再加一个 MAD 统计单元。这是当前与原算法差距最大的一处。
2. **共模参考改进**：用 3 抽头 LMS（离线收敛）替代均值，逼近 PC1。
3. **`radar_loc_bin`**：把"呼吸带距离能量剖面 argmax"（`_radar_energy_profile`）
   做成一个独立小模块（逐仓能量累加 + 比较树），补上 Ablation A 的完整回退路径。
4. **上板验证**：用 `测量数据/` 里的 `radar_frames.npz` 抽出若干会话，
   经 Python 脚本转成 AXI-Stream 激励文件，做 RTL 与 numpy 的逐阶段比对
   （`sim/tb/` 已给出 DACM / Hampel / FIR / DFT 的单元仿真骨架）。

---

## 8. 参考：模块与 Python 函数对照（速查）

| Verilog 文件 | 行数 | Python 对应 |
|---|---:|---|
| `src/rtl/common/u_div.v` | 118 | `numpy` 除法（所有 `/`） |
| `src/rtl/common/median7.v` | 60 | `np.median`（7 元素） |
| `src/rtl/common/sin_lut.v` | 34 | `np.sin` / `np.cos` |
| `src/rtl/frontend/radar_frame_if.v` | 100 | `dataio.load_radar` + 窗口切片 |
| `src/rtl/frontend/dacm_phase.v` | 148 | `dsp.dacm_phase` |
| `src/rtl/frontend/hampel7.v` | 150 | `dsp._hampel_1d` / `hampel_axis` |
| `src/rtl/frontend/integrate_detrend.v` | 250 | `dsp.integrate_axis` + `detrend_axis` |
| `src/rtl/spatial/bin_selector.v` | 105 | `estimator.candidate_bins` / `_subject_free_bins` / `_effective_range` |
| `src/rtl/spatial/robot_motion_if.v` | 90 | `vision_geometry.motion_safe` + 机器人控制 |
| `src/rtl/filter/fir_bandpass.v` | 175 | `dsp.bandpass_axis` |
| `src/rtl/spectral/goertzel_sweep.v` | 190 | `dsp.spectrum` + `_vr_sweep` 频率轴 |
| `src/rtl/spectral/null_model_cancel.v` | 150 | `_harmonic_residual` + `_common_mode_reference` + `_vr_sweep` |
| `src/rtl/spectral/cm_ref_extract.v` | 95 | `_common_mode_reference` |
| `src/rtl/spectral/spectrum_accum.v` | 105 | `_fused_spectrum` |
| `src/rtl/spectral/peak_argmax.v` | 175 | `np.argmax` + `dsp.parabolic_peak` + `vr_contrast` |
| `src/rtl/cert/certificate_fsm.v` | 140 | `estimator._certificate` |
| `src/rtl/output/result_out.v` | 165 | `run.py` 输出字段 |
| `src/rtl/top/vs_engine_fsm.v` | 215 | `estimator.estimate` 控制流 |
| `src/rtl/top/vital_signs_top.v` | 400 | 整体集成 |
