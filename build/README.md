# build — 可复现的构建脚本

```
build/
├── build_vivado.bat    一键入口（Windows 双击 / cmd）
├── tcl/                Vivado 批处理脚本（ASCII-only，GUI 与 batch 通用）
├── scripts/            ROM 初始化文件与参考表的生成器
├── reports/            综合 / 实现报告的归档位置（脚本自动拷入）
└── vivado/             Vivado 工程目录（本地生成，不入库）
```

## 1. 一键构建

```bat
cd <repo>\build
build_vivado.bat            :: 全流程：工程 → BD → 综合 → 实现 → 比特流 → xsa
build_vivado.bat bd         :: 只到 Block Design
build_vivado.bat synth      :: 只到综合
build_vivado.bat gui        :: 建完 BD 直接打开 GUI
```

脚本顶部的 `VIVADO_BIN` 是 Vivado 安装路径，换机器时改这一行即可。
工程根目录由 `%~dp0..` 推出，所以从任何位置调用都可以。

等价的命令行形式：

```bat
D:\vivado2019\Vivado\2019.1\bin\vivado.bat -mode batch ^
    -source <repo>\build\tcl\build_everything.tcl
```

Vivado GUI 里则是在 Tcl Console：

```tcl
source <repo>/build/tcl/build_everything.tcl
```

## 2. 脚本分工

| 脚本 | 职责 |
|---|---|
| `tcl/build_everything.tcl` | 总入口：调 Stage 1 + Stage 2，打印耗时与产物路径 |
| `tcl/build_all.tcl` | 建工程、加 RTL / `.mem` / testbench、设搜索路径、调 `build_bd.tcl` |
| `tcl/build_bd.tcl` | **新建 Block Design**：28 个单元 + 全部连线 + 地址分配 + 校验 + 生成输出 |
| `tcl/wire_only.tcl` | 只连线：给"自己手工拖模块进画布"的用法准备的，会先检查单元是否齐全 |
| `tcl/build_after_bd.tcl` | HDL Wrapper → 综合 → 实现 → 比特流 → 导出 `.xsa` → 归档报告 |
| `tcl/export_bd_diagram.tcl` | 把 Block Design 导出成 PDF / SVG |
| `scripts/gen_rom.py` | 生成 5 个 `.mem` 初始化文件（正弦表 / FIR 系数 / 相位增量） |
| `scripts/export_tables.py` | 把 `.mem` 解码成 `data/rom_tables/*.csv` 参考表 |

## 3. 可截断的流程

改 `build_everything.tcl` 顶部的 `STOP_AFTER`，或设环境变量：

| `VS_STOP_AFTER` | 停在哪 |
|---|---|
| `bd` | 建完并校验 Block Design |
| `synth` | 综合完成 |
| `impl` | 实现完成 |
| `bit`（默认） | 全流程 + `.xsa` |

```powershell
$env:VS_STOP_AFTER = "bd"
& "D:\vivado2019\Vivado\2019.1\bin\vivado.bat" -mode batch -source "D:\...\build\tcl\build_everything.tcl"
```

## 4. 产物落在哪

| 产物 | 路径 |
|---|---|
| Vivado 工程 | `build/vivado/vs_fpga.xpr` |
| Block Design | `build/vivado/vs_fpga.srcs/sources_1/bd/vs_bd/vs_bd.bd` |
| 比特流 / `.xsa` | `board/artifacts/`（脚本拷入） |
| 利用率 / 时序报告 | `build/reports/`（脚本拷入） |

`build/vivado/` 体积达数百 MB 且完全可由脚本重建，默认不进版本库。

## 5. 两个踩过的坑（写进脚本里了）

**① `.mem` 必须设成 `Memory Initialization Files` 类型。**
`build_all.tcl` 加完 5 个 `.mem` 后会 `set_property file_type {Memory Initialization Files}`；
不改的话综合期 `$readmemh` 找不到文件。

**② 不要给 RTL 用 `` `include ``。**
Block Design 的 `create_bd_cell -type module -reference` 走的是另一个 HDL 解析器，
**不认 `include_dirs`**，模块里带 `` `include `` 会直接建单元失败。
因此全工程参数一律内联成字面量，`include_dirs` 只用于让 `$readmemh` 找到 `.mem`。
