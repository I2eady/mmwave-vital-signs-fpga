# sim — 仿真与验证

本目录放**不产生硬件**的验证手段，分三层：单元 testbench、可独立运行的静态检查、仿真结果。

```
sim/
├── tb/         4 个单元 testbench（Verilog）
├── tcl/        run_sim.tcl：批量跑全部 testbench
├── scripts/    无 Vivado 依赖的静态检查（Python）
└── results/    波形 / 日志 / 结果记录
```

## 1. 单元 testbench

| testbench | 被测模块 | 激励 | 判定依据 |
|---|---|---|---|
| `tb_dacm_phase.v` | `dacm_phase` | 恒定相位步进 `θ[n] = n·Δθ` 的复数序列 | 输出 `dphi` 恒为 `Δθ`（Q4.20） |
| `tb_hampel7.v` | `hampel7` | 恒定值序列中插入 3 个大幅尖峰 | 尖峰被中值替换，`outlier_cnt` 计到 3 |
| `tb_fir_bandpass.v` | `fir_bandpass` | 带内 0.30 Hz + 带外 4 Hz 的合成正弦 | 输出幅度 ≈ 0.5（带内保留、带外抑制）、与输入同相 |
| `tb_goertzel_sweep.v` | `goertzel_sweep` | 单音 0.30 Hz（呼吸网格第 30 点） | 结果 RAM 第 30 号地址幅度最大 |

批量运行（先有工程，`build/tcl/build_all.tcl` 建的即可）：

```tcl
# Vivado Tcl Console
source <repo>/sim/tcl/run_sim.tcl
```

命令行：

```bat
D:\vivado2019\Vivado\2019.1\bin\vivado.bat -mode batch -source <repo>\sim\tcl\run_sim.tcl
```

## 2. 静态检查（不依赖 Vivado）

两个脚本把"必须开 Vivado 才能发现"的一批问题提前到秒级：

```bash
python sim/scripts/rtl_lint.py       # RTL 结构检查
python sim/scripts/check_bd_nets.py  # Block Design 连线预检
```

### `rtl_lint.py`

| 检查项 | 为什么重要 |
|---|---|
| `module/endmodule`、`begin/end`、`case/endcase` 配平 | 语法级错误，Vivado 报错位置常常偏移几十行 |
| 例化端口名是否存在于被例化模块 | 端口名拼错时 Verilog 只是"悬空"，不报错但功能丢失 |
| Verilog 保留字是否被当标识符 | `buf` / `not` / `tran` 这类内建原语名会直接语法错误 |
| sized literal 后是否紧跟括号 | `32'sd(NTAP-1)` 是非法写法 |
| `function` 是否在调用点之前声明 | Verilog 要求先声明后使用 |
| ROM 初始化文件是否存在 | `$readmemh` 找不到文件，综合期才报 |

### `check_bd_nets.py`

解析 `src/rtl/**/*.v` 的端口位宽（参数代入默认值）+ `build/tcl/build_bd.tcl` 的全部连线，
在不开 Vivado 的前提下预演三类检查：

| 输出前缀 | 含义 | 对应的 Vivado 报错 |
|---|---|---|
| `!!` | 引脚不存在 / 位宽不匹配 | `BD 5-3`、`BD 41-1228` |
| `??` | RTL 输入脚没被任何连线驱动 | `BD 41-759`（会被静默 tie 成 0） |
| `--` | 输出脚没人用（仅提示） | — |

理想输出：`真实问题 0 / 悬空输入 0`。

## 3. results

见 [`results/README.md`](results/README.md)：波形导出、仿真日志与逐用例结论记在这里。
