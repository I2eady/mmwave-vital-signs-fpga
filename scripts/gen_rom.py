#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_rom.py -- 生成 FPGA 所需的 ROM 初始化文件

输出:
  rtl/common/sin_lut.mem        4096 点正余弦表 (s16 Q1.15)
  rtl/filter/fir_coeff.mem      3 频带 x 256 抽头 (s18 Q1.15, 对称 FIR 半系数)
  rtl/spectral/dft_delta.mem    3 网格 x 256 点 频率增量 (uint32)

关于滤波器结构的说明
--------------------
Python 用 scipy butter(order=4) + filtfilt 做零相位带通。直接定点化会出问题：
scipy 的 SOS 分解把增益全部压到第一个二阶节，b 系数小到 2e-5，Q4.14 直接量化成 0；
且各级增益跨越 4 个数量级（0.011 ~ 472），级间中间量必然下溢。

因此硬件改用**线性相位 FIR**：
  * 系数天然 O(1)，Q1.15 精度充足；
  * FIR 本身即零相位（对称系数），不需要 filtfilt 的正/反向两遍；
  * 不存在稳定性与级间定标问题。
时延代价可忽略：数据率仅 20 Hz 帧率，512 抽头 x 600 样本 = 30.7 万 MAC/通道，
100 MHz 单乘法器下 ~3 ms。

频带设置与 config.py 一致：
  呼吸带   0.15 - 0.60 Hz
  心脏带   0.80 - 2.00 Hz
  共模带   0.95 - 1.20 Hz
"""
import math
import os

FS = 20.0                     # config.fs
NTAP = 1024                   # FIR 抽头数（偶数，对称）
NHALF = NTAP // 2             # 唯一系数个数 = 512

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (名称, 设计下限, 设计上限, 目标通带下限, 目标通带上限)
#   设计截止点相对目标带外扩半个过渡带 (Hamming, ~3.3/N * fs)
#   过渡带宽 = 3.3/1024*20 = 0.064 Hz -> 外扩 0.032 Hz
#   这样 0.15-0.60 / 0.80-2.00 / 0.95-1.20 的目标带内都能达到平坦通带。
BANDS = [
    ("resp",    0.118, 0.632, 0.15, 0.60),
    ("cardiac", 0.768, 2.032, 0.80, 2.00),
    ("cm",      0.918, 1.232, 0.95, 1.20),
]


def to_hex(v, bits):
    return format(v & ((1 << bits) - 1), "0{}x".format(bits // 4))


def main():
    # ------------------------------------------------------------------
    # 1) 正余弦表 (4096 x s16 Q1.15)
    # ------------------------------------------------------------------
    n = 4096
    lines = []
    for k in range(n):
        v = int(round(math.sin(2 * math.pi * k / n) * 32767))
        v = max(-32768, min(32767, v))
        lines.append(to_hex(v, 16))
    p = os.path.join(ROOT, "rtl", "common", "sin_lut.mem")
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", p, len(lines), "lines")

    # ------------------------------------------------------------------
    # 2) FIR 系数 (3 频带 x 256 抽头, s18 Q1.15)
    # ------------------------------------------------------------------
    from scipy.signal import firwin, freqz
    import numpy as np

    clines = []
    for name, dlo, dhi, lo, hi in BANDS:
        h = firwin(NTAP, [dlo, dhi], pass_zero=False, fs=FS, window="hamming")
        # 频带中心归一到单位增益（与 butter 带通的中心增益对齐）
        fc = math.sqrt(lo * hi)
        w, H = freqz(h, worN=[2 * math.pi * fc / FS])
        g = abs(H[0])
        if g > 1e-30:
            h = h / g
        # 对称 FIR：只存前 NHALF 个系数
        hh = h[:NHALF]
        mx = float(np.max(np.abs(hh)))
        if mx > 0.9999:
            hh = hh / mx * 0.9999
        q = [int(round(v * 32768)) for v in hh]
        q = [max(-131072, min(131071, v)) for v in q]
        clines += [to_hex(v, 18) for v in q]
        # 校验：目标通带内的平坦度与阻带衰减
        w2, H2 = freqz(np.concatenate([hh, hh[::-1]]), worN=8192)
        fr = w2 / (2 * math.pi) * FS
        m = np.abs(H2)
        pb = m[(fr >= lo) & (fr <= hi)]
        stop = m[(fr >= 0.02) & (fr <= max(dlo - 0.10, 0.05))]
        print("  {:8s} 目标 {:0.2f}-{:0.2f} Hz  通带增益 {:.3f}..{:.3f}  "
              "阻带最大 {:.2e}  最大|系数|={:.4f}".format(
                  name, lo, hi, pb.min(), pb.max(),
                  (stop.max() if stop.size else float("nan")), mx))

    p = os.path.join(ROOT, "rtl", "filter", "fir_coeff.mem")
    with open(p, "w") as f:
        f.write("\n".join(clines) + "\n")
    print("wrote", p, len(clines), "lines")

    # ------------------------------------------------------------------
    # 3) DFT 频率网格相位增量
    # ------------------------------------------------------------------
    grids = [
        ("resp",    [0.15 + 0.005 * k for k in range(91)]),
        ("vr",      [1.0 + (0.25 / 60.0) * k for k in range(201)]),
        ("cardiac", [0.80 + 0.01 * k for k in range(121)]),
    ]
    MAXPTS = 256
    dlines = []
    for gi, (name, fr) in enumerate(grids):
        fr = fr + [fr[-1]] * (MAXPTS - len(fr))
        for f in fr:
            inc = int(round((f / FS) * (1 << 32))) & 0xFFFFFFFF
            dlines.append(to_hex(inc, 32))
        print("  grid {} {:8s} {} 点  {:.4f}..{:.4f} Hz".format(
            gi, name, len(grids[gi][1]), grids[gi][1][0], grids[gi][1][-1]))
    while len(dlines) < 4 * MAXPTS:
        dlines.append("0" * 8)

    p = os.path.join(ROOT, "rtl", "spectral", "dft_delta.mem")
    with open(p, "w") as f:
        f.write("\n".join(dlines) + "\n")
    print("wrote", p, len(dlines), "lines")


if __name__ == "__main__":
    main()
