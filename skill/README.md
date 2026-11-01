# skill — 工程技能包

本文件把"如何安全地修改并复现这个工程"固化成一份可复用的操作手册，供人或 AI 助手按图施工。
它不介绍算法原理（那在 `report/design_report.md`），只回答**改哪里、怎么验证、别踩什么**。

## 1. 适用场景

| 触发 | 该看哪一节 |
|---|---|
| 改动算法参数（频带、网格、门限） | §3 参数在哪 |
| 新增 / 替换一个算法模块 | §4 改 RTL 的流程 |
| 改 Block Design 的连线或单元 | §5 改 BD 的流程 |
| 换器件 / 换板卡 | §6 移植清单 |
| 报告数字不对、资源爆掉 | §7 排障 |

## 2. 仓库约定（硬性）

1. **目录与文件名只用小写英文、数字、下划线、连字符**；中文只出现在文件正文。
2. **`.tcl` 与 `.bat` 必须是纯 ASCII。** Vivado 的 Tcl 在中文 Windows 上按系统代码页读文件，
   非 ASCII 会变乱码（表现为 `闃舵??`），且 `catch` 后的报错信息也会被吞掉。
3. **RTL 里禁止 `` `include ``。** Block Design 的 `create_bd_cell -type module -reference`
   用的是另一个 HDL 解析器，不认 `include_dirs`，带 include 的模块建单元必失败。
   全局参数一律内联成字面量。
4. **中文注释可以，但不要写进需要被 Vivado 解析的字符串**（如 `$display` 格式串）。
5. **`$readmemh` 的文件必须加进工程并设成 `Memory Initialization Files`**，
   由 `build/tcl/build_all.tcl` 自动完成，新增 `.mem` 时记得同步那张表。

## 3. 参数在哪

| 参数 | 位置 | 备注 |
|---|---|---|
| 采样率 / 帧率（20 Hz） | `build/scripts/gen_rom.py` 的 `FS` | 同时影响相位增量与滤波器设计 |
| FIR 频带与抽头数 | `gen_rom.py` 的 `BANDS` / `NTAP` | 改完必须重跑 `gen_rom.py` |
| DFT 网格 | `gen_rom.py` 的 `grids` | 与 `bpm_map.v` 的网格定义必须同步 |
| 窗口长度 / 通道数 | `src/rtl/frontend/radar_frame_if.v`（`ACQ_START` / `ACQ_LEN`）、`integrate_detrend.v`（`NSAMP` / `N_CH`） | 改长度要同步 `vs_engine_fsm.v` 的 `NPTS_RESP` |
| 证书门限 | `src/rtl/cert/certificate_fsm.v` 里的字面量 | 对应 Python 的 `outlier_fraction_limit` 等 |
| 运动阈值 / 默认值 | `src/rtl/top/vs_defaults.v` | 占位值集中在这一个文件 |

**改参数的固定动作**：改 `gen_rom.py` → 重跑 → 重跑 `export_tables.py` 更新 `data/rom_tables/` →
检查 `check_bd_nets.py` 仍为 0 问题 → 重建工程。

## 4. 改 RTL 的流程

```
1. 改 src/rtl/<layer>/<module>.v
2. python sim/scripts/rtl_lint.py          # 结构 / 端口 / 保留字 / 字面量
3. python sim/scripts/check_bd_nets.py     # 若端口名或位宽变了，BD 连线要同步
4. 如果端口变了 -> 改 build/tcl/build_bd.tcl 里对应的 vs_net
5. 新模块 -> 在 build_bd.tcl 里加一行 mkmod <module> <cell>，并加入 rtl_clk / rtl_rst 清单
6. 需要验证功能 -> 补 sim/tb/tb_<module>.v，加进 sim/tcl/run_sim.tcl 的 tests 列表
```

**位宽陷阱（反复踩过）**：Verilog 的 `a * b` 位宽按 `max(左值, 操作数)` 计算，
`wire [15:0] y = a * b;` 会把乘积截断到 16 位。任何要保留高位的乘法都必须先赋给足够宽的中间量：

```verilog
// 错：3072 * 32767 在 16 位上下文里溢出
wire [15:0] y = (x * 16'd32767) / 16'sd3072;
// 对：
wire signed [47:0] num = $signed({32'd0, x}) * 48'sd32767;
wire [15:0] y = num / 48'sd3072;
```

## 5. 改 Block Design 的流程

`build/tcl/build_bd.tcl` 是**唯一事实来源**——它每次从头重建 BD，不要在 GUI 里改完就提交。

```
1. 加单元：在对应小节加 mkmod <module> <cell_name>
2. 加时钟复位：把新 cell 名加进 rtl_clk 和 rtl_rst 两个列表
3. 连线：用 vs_net <cellA>/<portA> <cellB>/<portB>
        AXI-Stream 接口用 vs_link <cellA> <m_axis> <cellB> <s_axis>
4. python sim/scripts/check_bd_nets.py     # 先本地预检，比开 Vivado 快 100 倍
5. build_vivado.bat bd                     # 再真跑一遍，看 validate_bd_design
```

排错优先级：`!!` 引脚不存在 / 位宽不匹配 → `??` 悬空输入 → `BD 41-759` / `BD 41-1228`。

**不要把"没有数据源"的输入真的悬空**：BD 会静默 tie 成 0，从日志看不出来。
统一接到 `vs_defaults_0`，这样图上一眼能看出哪部分是占位。

## 6. 换器件 / 换板卡

1. `build/tcl/build_all.tcl` 的 `part` 改型号；
2. PS7 的 DDR 型号、时钟频率、外设使能在 `build_bd.tcl` 的 `CONFIG.PCW_*` 里；
3. HP0 数据宽度必须与 `axi_pc` 的 `DATA_WIDTH`、DMA 的 `c_m_axi_mm2s_data_width` 三者一致；
4. 综合后看 `build/reports/synthesis_utilization_hier.rpt` 决定是否需要降频或裁剪通道数。

## 7. 排障速查

| 现象 | 真因 | 修法 |
|---|---|---|
| 脚本输出 `闃舵??` | `.tcl` 里有非 ASCII | 改成纯英文 |
| `create_bd_cell` 失败且 `$e` 为空 | 模块里有 `` `include `` 或 HDL 语法错 | 内联参数；单独 `read_verilog` 该文件看报错 |
| `Syntax error near "buf"` | 用了 Verilog 内建原语名当标识符 | 改名（`buf` → `samp_buf`） |
| `Syntax error near "("` | `32'sd(NTAP-1)` 这种写法非法 | 先用 `localparam` 算好 |
| `BD 41-1276 Parameter does not exist` | 属性名猜错（如 `SYNTH_CHECKPOINT_MODE`） | 先 `list_property` 枚举再 set |
| `BD 41-1228` 位宽不匹配 | 连线两端位宽不同 | 改端口位宽，别靠自动截断 |
| `BD 41-1285` 协议不兼容 | PS 的 HP 口是 AXI3、DMA 是 AXI4 | 中间插 `axi_protocol_converter`（S=AXI4, M=AXI3） |
| `BD 41-758` 时钟脚未接 | Xilinx IP 的时钟脚名不是 `aclk` | 逐个显式连（`s_axi_lite_aclk` / `m_axi_mm2s_aclk` / `s_axi_aclk`…） |
| `$readmemh: cannot open file` | `.mem` 没进工程或没设文件类型 | 检查 `build_all.tcl` 的 mem 列表 |
| BRAM = 0、`LUT as Memory` 爆掉 | 大数组是组合读或声明成 `block` 却被当作 RAM | 见下条 |

**存储器映射是资源的第一杀手**。同步读 + `ram_style="block"` 才能进 BRAM；
组合读（同一拍读多个地址）必须用 `ram_style="distributed"`，否则综合器会用触发器实现，
一个 600×80×24 bit 的窗口存储器会吃掉几万个 FF。
