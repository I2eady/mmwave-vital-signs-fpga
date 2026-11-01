# data — 测试数据与参考结果

```
data/
└── rom_tables/     由 .mem 解码出的定点参考表（CSV）
```

## rom_tables

`build/scripts/export_tables.py` 把 verilog `$readmemh` 用的十六进制初始化文件还原成定点真值，
用于对照 Python 参考模型、画频响曲线、检查量化误差。

```bash
python build/scripts/export_tables.py
```

| 文件 | 行数 | 内容 | 列 |
|---|---:|---|---|
| `fir_coeff.csv` | 1536 | 3 频带 × 512 个唯一系数 | `band, tap, mirror_tap, coeff_q15, raw_hex` |
| `dft_grids.csv` | 413 | 3 个频率网格的全部频点 | `grid, grid_name, k, freq_hz, bpm, phase_inc, freq_hz_from_inc, quant_err_hz` |
| `sin_lut.csv` | 257 | 4096 点正弦表（每 16 点抽样） | `idx, addr_hex, phase_rad, sin_q15, raw_hex` |
| `bands.csv` | 6 | 频带与网格的边界定义 | `type, id, name, f_low_hz, f_high_hz, f_center_hz, taps` |

### 频带与网格（与 Python `config.py` 一致）

| 类型 | 名称 | 频率范围 | 点数 / 抽头 |
|---|---|---|---|
| FIR 带通 | 呼吸 `resp` | 0.15 – 0.60 Hz | 1024 抽头 |
| FIR 带通 | 心脏 `cardiac` | 0.80 – 2.00 Hz | 1024 抽头 |
| FIR 带通 | 共模 `cm` | 0.95 – 1.20 Hz | 1024 抽头 |
| DFT 网格 | 呼吸 `resp` | 0.150 – 0.600 Hz，步进 0.005 | 91 点 |
| DFT 网格 | 心率 `vr` | 1.000 – 1.833 Hz，步进 0.25 bpm | 201 点 |
| DFT 网格 | 心脏 `cardiac` | 0.80 – 2.00 Hz，步进 0.01 | 121 点 |

### 量化误差的量级

`dft_grids.csv` 的 `quant_err_hz` 列给出 32 位相位累加器带来的频率误差，
典型值在 `1e-9 Hz` 量级 —— 相当于 30 s 窗口内相位误差远小于 1°，
因此 DFT 频点的位置误差可以忽略，误差来源只剩窗长与信噪比。

## 为什么参考数据是 CSV 而不是原始帧

雷达原始帧体积大（20 Hz × 80 字），且涉及受试者生理数据，不适合入库。
仓库里保留的是**完全可复现的确定性数据**：ROM 表由 `gen_rom.py` 从公开参数算出，
任何人重跑都能得到逐位相同的结果，这才是比对 RTL 所需要的"金标准"。
