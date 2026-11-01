# sim/results — 仿真与验证结果

本目录保存**每次跑仿真/检查产出的可追溯结果**，不存二进制波形以外的构建产物。

## 建议的命名

```
results/
├── sim_<日期>.log            run_sim.tcl 的控制台输出
├── lint_<日期>.txt           rtl_lint.py 输出
├── bd_nets_<日期>.txt        check_bd_nets.py 输出
└── waves/
    └── tb_<模块>.vcd         需要讨论时导出的波形
```

## 一份结果里应该记什么

| 项目 | 说明 |
|---|---|
| 用例 / 脚本 | 哪个 testbench 或哪个检查脚本 |
| 结论 | 通过 / 不通过，以及**判定依据**（不是"看起来对"） |
| 关键数值 | 例如 FIR 用例实测通带幅度、DFT 用例的 argmax 位置 |
| 工具版本 | `Vivado v2019.1`、Python 与 numpy/scipy 版本 |

## 各用例的判定要点

| 用例 | 判定点 | 期望 |
|---|---|---|
| `tb_dacm_phase` | 稳态后每个输出的相位增量 | 精确等于激励的 `Δθ`（Q4.20 量化内） |
| `tb_hampel7` | 尖峰位置的输出值 | 回到局部中值，`outlier_cnt = 3` |
| `tb_fir_bandpass` | 带内 0.30 Hz 的输出峰峰值 | ≈ 输入幅度（0.5），且相位与输入一致 |
| `tb_goertzel_sweep` | 结果 RAM 的 argmax 下标 | 落在 0.30 Hz 对应的网格点 |

> 波形文件（`.vcd` / `.wdb`）体积大，默认不进版本库（见根目录 `.gitignore`）；
> 需要留证的只保留截图或 CSV 化的数值。
