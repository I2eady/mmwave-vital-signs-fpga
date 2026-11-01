#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
export_tables.py -- 把 ROM 初始化文件解码成可读的参考表（CSV）

`.mem` 是 $readmemh 读的十六进制文本，人看不懂；本脚本把它还原成定点真值，
输出到 data/rom_tables/，用于：
  * 对照 FPGA 内部 ROM 与 Python 参考模型（config.py 的频带 / 网格定义）
  * 画频响曲线、检查量化误差
  * 论文 / 报告里直接引用

输出:
  data/rom_tables/fir_coeff.csv     3 频带 x 512 个唯一系数（对称 FIR 半系数）
  data/rom_tables/dft_grids.csv     3 个频率网格：k / 频率 / bpm / 相位增量
  data/rom_tables/sin_lut.csv       4096 点正余弦表（每 16 点抽样，便于查看）

用法:
  python build/scripts/export_tables.py
"""
import csv
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RTL = os.path.join(ROOT, "src", "rtl")
OUT = os.path.join(ROOT, "data", "rom_tables")

FS = 20.0
NTAP = 1024
NHALF = NTAP // 2

BAND_NAMES = ["resp", "cardiac", "cm"]
BAND_HZ = [(0.15, 0.60), (0.80, 2.00), (0.95, 1.20)]

# DFT 网格定义，必须与 gen_rom.py / goertzel_sweep 一致
GRIDS = [
    ("resp",    "呼吸",  [0.15 + 0.005 * k for k in range(91)]),
    ("vr",      "心率",  [1.0 + (0.25 / 60.0) * k for k in range(201)]),
    ("cardiac", "心脏",  [0.80 + 0.01 * k for k in range(121)]),
]


def read_hex(path):
    with open(path) as f:
        return [ln.strip() for ln in f if ln.strip()]


def sxt(v, bits):
    """把 bits 位的无符号值解释成有符号值"""
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def export_fir():
    raw = read_hex(os.path.join(RTL, "filter", "fir_coeff.mem"))
    rows = []
    for i, h in enumerate(raw):
        band = i // NHALF
        tap = i % NHALF
        q = sxt(int(h, 16), 18)
        rows.append({
            "band": BAND_NAMES[band] if band < len(BAND_NAMES) else "unused",
            "tap": tap,
            # 对称 FIR 只存前半段，后半段由 tap 镜像得到
            "mirror_tap": NTAP - 1 - tap,
            "coeff_q15": round(q / 32768.0, 8),
            "raw_hex": h,
        })
    dst = os.path.join(OUT, "fir_coeff.csv")
    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print("wrote %-40s %d rows" % (os.path.relpath(dst, ROOT), len(rows)))


def export_grids():
    raw = read_hex(os.path.join(RTL, "spectral", "dft_delta.mem"))
    rows = []
    for gi, (name, zh, freqs) in enumerate(GRIDS):
        for k in range(len(freqs)):
            inc = int(raw[gi * 256 + k], 16)
            f_hz = freqs[k]
            rows.append({
                "grid": gi,
                "grid_name": name,
                "k": k,
                "freq_hz": round(f_hz, 6),
                "bpm": round(f_hz * 60.0, 4),
                "phase_inc": inc,
                # 反算值：用 32 位相位累加器还原的实际频率
                "freq_hz_from_inc": round(inc / float(1 << 32) * FS, 8),
                "quant_err_hz": round(inc / float(1 << 32) * FS - f_hz, 10),
            })
    dst = os.path.join(OUT, "dft_grids.csv")
    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print("wrote %-40s %d rows" % (os.path.relpath(dst, ROOT), len(rows)))


def export_sin():
    raw = read_hex(os.path.join(RTL, "common", "sin_lut.mem"))
    n = len(raw)
    rows = []
    for k, h in enumerate(raw):
        if k % 16 and k not in (0, n // 4, n // 2, 3 * n // 4, n - 1):
            continue
        v = sxt(int(h, 16), 16)
        rows.append({
            "idx": k,
            "addr_hex": "%03x" % k,
            "phase_rad": round(2 * math.pi * k / n, 8),
            "sin_q15": round(v / 32768.0, 8),
            "raw_hex": h,
        })
    dst = os.path.join(OUT, "sin_lut.csv")
    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print("wrote %-40s %d rows（%d 点表，每 16 点抽样）" %
          (os.path.relpath(dst, ROOT), len(rows), n))


def export_bands():
    """频带与网格的文字定义，便于与 Python 配置对照"""
    dst = os.path.join(OUT, "bands.csv")
    rows = []
    for i, (name, (lo, hi)) in enumerate(zip(BAND_NAMES, BAND_HZ)):
        rows.append({"type": "fir_band", "id": i, "name": name,
                     "f_low_hz": lo, "f_high_hz": hi,
                     "f_center_hz": round(math.sqrt(lo * hi), 6),
                     "taps": NTAP})
    for gi, (name, zh, freqs) in enumerate(GRIDS):
        rows.append({"type": "dft_grid", "id": gi, "name": name,
                     "f_low_hz": round(freqs[0], 6),
                     "f_high_hz": round(freqs[-1], 6),
                     "f_center_hz": "",
                     "taps": len(freqs)})
    dst = os.path.join(OUT, "bands.csv")
    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["type", "id", "name", "f_low_hz",
                                          "f_high_hz", "f_center_hz", "taps"])
        w.writeheader()
        w.writerows(rows)
    print("wrote %-40s %d rows" % (os.path.relpath(dst, ROOT), len(rows)))


def main():
    os.makedirs(OUT, exist_ok=True)
    export_fir()
    export_grids()
    export_sin()
    export_bands()


if __name__ == "__main__":
    main()
