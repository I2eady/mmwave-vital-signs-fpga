# build/reports — 综合与实现报告

构建脚本（`tcl/build_after_bd.tcl` 第 5 步）会把 Vivado 原始 run 目录里的关键报告
复制到这里，文件名固定，便于跨轮次比对：

| 文件 | 来源 | 看什么 |
|---|---|---|
| `synthesis_utilization.rpt` | `synth_1/*_utilization_synth.rpt` | 顶层的 LUT / FF / BRAM / DSP |
| `synthesis_utilization_hier.rpt` | 同上（hierarchical 版） | **按模块分解的资源占用**，定位大头 |
| `implementation_utilization.rpt` | `impl_1/*_utilization_placed.rpt` | 布局后的实际占用 |
| `implementation_timing.rpt` | `impl_1/*_timing_summary_routed.rpt` | **WNS / WHS / TNS** |
| `implementation_clock.rpt` | `impl_1/*_clock_utilization_routed.rpt` | 时钟域与 BUFG 使用 |

## 器件上限（xc7z020clg400-2）

| 资源 | 数量 |
|---|---:|
| Slice LUT | 53 200 |
| LUT as Memory（分布式 RAM） | 17 400 |
| Slice Register（FF） | 106 400 |
| Block RAM Tile（RAMB36） | 140 |
| DSP48E1 | 220 |

## 需要注意的两个判据

1. **时序**：`implementation_timing.rpt` 里 `WNS ≥ 0` 才算收敛。本设计数据率极低
   （20 Hz 帧率，30 s 分析窗），若 100 MHz 余量不足，把 `build/tcl/build_bd.tcl` 里
   PS7 的 `PCW_FPGA0_PERIPHERAL_FREQMHZ` 改成 50 重跑即可。
2. **BRAM 是否为 0**：如果 `Block RAM Tile = 0` 而 `LUT as Memory` 接近上限，说明某个大数组
   被综合成了分布式 RAM —— 去看 `synthesis_utilization_hier.rpt` 里哪个模块最大，
   再检查该模块数组的 `ram_style` 属性与读口时序（见 `report/bd_structure.md` 第六节）。

> 报告随器件版本、Vivado 版本变化，保留一份有代表性的即可，不必每次提交。
