# Vivado 手动点击清单（一条一条来）

> 每个 ☐ 就是一次操作。做完打勾，一批做完对照「你应该看到」确认。
> 全程在 **Vivado 2019.1** GUI 里，器件 **xc7z020clg400-2**。
> 工程目录固定为 `D:\A_university_project\FPGAmmwave\fpga\`。

---

---

## 先确认你在哪个 shell

| 你要做的事 | cmd 里这样写 | PowerShell 里这样写 |
|---|---|---|
| 切目录 | `cd /d D:\A_university_project\FPGAmmwave\fpga` | `cd D:\A_university_project\FPGAmmwave\fpga`（**没有 `/d`**） |
| 跑当前目录的 bat | `build_vivado.bat bd` | `.\build_vivado.bat bd`（**要加 `.\`**） |
| 设环境变量 | `set VS_STOP_AFTER=bd` | `$env:VS_STOP_AFTER = "bd"` |
| 续行符 | `^` | `` ` `` |

> PowerShell 里如果直接敲 `build_vivado.bat` 会报
> `无法将"build_vivado.bat"项识别为 cmdlet...` —— 那是因为 PowerShell 出于安全
> 考虑**不会执行当前目录的程序**，加 `.\` 即可。
> 用绝对路径调用也完全可以：
> `& "D:\A_university_project\FPGAmmwave\fpga\build_vivado.bat" bd`

---

## 先记住 4 个省力技巧

1. **加 RTL 模块进 BD 用拖拽**：左侧 Sources 面板里把模块名**拖到 BD 画布上**，
   比右键菜单快得多。
2. **时钟/复位/AXI 让机器连**：BD 画布上方会出现绿色横条
   "Designer Assistance available. Run Connection Automation"，
   点它，能省掉 40 多根线。
3. **分阶段校验**：连完一类线就按一次 **F6**，别攒到最后一起查。
4. **60 根手工连线可以省掉**：按第 10 阶段做完后，在 Tcl Console 粘一行
   `source tcl/wire_only.tcl` 就能一次接完（详见阶段 10）。

---

# 阶段 0 · 建工程（8 步）

### ☐ 1. 启动 Vivado
双击 `D:\vivado2019\Vivado\2019.1\bin\vivado.bat`。
开始菜单也可以：**Xilinx Design Tools → Vivado 2019.1**。

**你应该看到**：一个带左右两栏的欢迎界面（Quick Start / Tasks / Learning Center / Recent Projects）。
**如果它自动打开了上次的工程** → `File → Close Project`，回到欢迎界面。

### ☐ 2. 点 Create Project
欢迎界面左侧 **Quick Start** 面板里点 **Create Project**。
（等价菜单：`File → Project → New...`）

**你应该看到**：New Project 向导，第 1 页 "Project Name"。

### ☐ 3. 填工程名和位置

| 字段 | 填什么 |
|---|---|
| Project name | `vs_fpga` |
| Project location | `D:/A_university_project/FPGAmmwave/fpga/prj` |
| Create project subdirectory | **☐ 取消勾选**（很重要，不取消会多套一层目录） |

点 **Next**。

### ☐ 4. 选工程类型
选 **RTL Project**。
下面 **☑ 勾上 "Do not specify sources at this time"**（源文件后面单独加，好排查）。

点 **Next**。

### ☐ 5. 忽略 Add Sources 页
直接 **Next**（一会儿在 Flow Navigator 里加）。

### ☐ 6. 忽略 Add Constraints 页
直接 **Next**。

### ☐ 7. 选器件 ★

这一页最关键的：

1. 上方有三个标签：**Boards** / **Parts** / **Specify**
2. 点 **Parts** 标签
3. 在搜索框（"Search:"）里输入 `xc7z020clg400-2`
4. 列表里应该剩 1 条 → **选中它**（点一下让整行变蓝）
5. 右侧 "Product Category / Family / Package / Speed Grade / Temp Grade" 会显示
   `Zynq-7000 / clg400 / -2`

点 **Next**。

> 如果 Parts 列表是空的 → 说明器件库没装。去
> `D:\vivado2019\Vivado\2019.1\bin\vivado.bat` 启动后
> `Help → Add Design Tools or Devices` 补装 Zynq-7000 器件包。
> 或者也可以在 Boards 标签里搜 `ZYNQ` 找板卡（如果装了板卡文件）。

### ☐ 8. 完成
New Project Summary 页看一眼，确认器件是 `xc7z020clg400-2`，点 **Finish**。

**你应该看到**：主界面出现，左侧是 **Flow Navigator**（PROJECT MANAGER / IP INTEGRATOR /
SIMULATION / RTL ANALYSIS / SYNTHESIS / IMPLEMENTATION / PROGRAM AND DEBUG），
中间是空的 **Sources**、**Properties** 等面板。

---

# 阶段 1 · 加 22 个 RTL 源文件（4 步）

### ☐ 9. 打开 Add Sources
左侧 **Flow Navigator → PROJECT MANAGER → Add Sources**（快捷键 `Alt+A`）。

**你应该看到**：Add Sources 对话框，三个单选：
`Add or create design sources` / `Add or create simulation sources` / `Add or create constraints`。

### ☐ 10. 选类型
选 **Add or create design sources**（默认就是）→ **Next**。

### ☐ 11. 加文件 ★

点 **Add Files**，然后**按目录分 5 批加**（一批选不完整没关系）：

| 批次 | 打开到 | 全选 |
|---|---|---|
| 1 | `fpga\rtl\common` | `median7.v`、`sin_lut.v`、`u_div.v` |
| 2 | `fpga\rtl\frontend` | `dacm_phase.v`、`hampel7.v`、`integrate_detrend.v`、`radar_frame_if.v` |
| 3 | `fpga\rtl\spatial` | `bin_selector.v`、`robot_motion_if.v` |
| 4 | `fpga\rtl\filter` | `biquad_cascade.v`、`biquad_coeff_rom.v`、`fir_bandpass.v`、`iir_biquad.v` |
| 5 | `fpga\rtl\spectral` | `cm_ref_extract.v`、`goertzel_sweep.v`、`null_model_cancel.v`、`peak_argmax.v`、`spectrum_accum.v` |
| 6 | `fpga\rtl\cert` | `certificate_fsm.v` |
| 7 | `fpga\rtl\output` | `result_out.v` |
| 8 | `fpga\rtl\top` | `vital_signs_top.v`、`vs_engine_fsm.v` |

也可以走捷径：第 1 批用 **Add Directories**，
把 `rtl\common`、`rtl\frontend` … 8 个目录一次性全加进去（推荐，少点几次）。

> **不要把 `fpga\tb\` 里的文件加进来**，那是仿真用的。

### ☐ 12. Finish + 处理弹窗

点 **Finish**。

**可能弹窗 1**：`... do not match the file extension ...` → 选 **OK** 继续。
**可能弹窗 2**：`Module ... is not referenced` → 直接 **OK**。

**你应该看到**：左侧 Sources 面板（Hierarchy 标签）里列出 **22 个 `.v`**，
每个前面是个小方块图标。

---

# 阶段 2 · 加 5 个 ROM 初值文件 ★★（最容易漏，漏了综合必失败）

### ☐ 13. 再次 Add Sources
`Alt+A` → 选 **Add or create design sources** → Next → **Add Files**。

### ☐ 14. 选这 5 个 `.mem`

```
fpga\rtl\common\sin_lut.mem
fpga\rtl\spectral\sin_lut.mem
fpga\rtl\filter\fir_coeff.mem
fpga\rtl\filter\coeff_rom.mem
fpga\rtl\spectral\dft_delta.mem
```

（要切 3 个目录，分 3 批 Add。）

点 **Finish**。

**你应该看到**：Sources 面板里多出 5 个 `.mem` 条目，图标是「文档」样式。

### ☐ 15. 改成 Memory Initialization Files ★

在 Sources 面板里**框选这 5 个 `.mem`** → **右键 → Set File Type...**

**你应该看到**：一个对话框，里面有一列文件类型选项。

选 **Memory Initialization Files** → **OK**。

**你应该看到**：这 5 个条目的图标变了，而且点中任意一个时，
下方 Properties 面板的 `Type` 显示 `Memory Initialization Files`。

> **如果 Set File Type 里找不到这个选项**，或者懒得点：
> 打开底部 **Tcl Console**，粘这一行回车：
> ```tcl
> set_property file_type {Memory Initialization Files} [get_files *.mem]
> ```
> 效果一样。

### ☐ 16. 确认 5 个都在
数一下 Sources 面板里的 `.mem` 条目 = **5 个**。少一个后面综合就会报
`$readmemh: cannot open file`。

---

# 阶段 3 · 刷新编译顺序（1 步）

> **原先这里要设 include_dirs，现在不需要了。**
> 我一开始把全局参数放在 `vs_params.vh` 里用 `` `include `` 引用，但实测发现
> **Vivado 的 Block Design HDL 解析器不走 include_dirs**——解析模块端口时
> include 解不开，`create_bd_cell -type module -reference` 直接失败。
> （你之前那次卡在 `hampel7_0` 就是这个原因。）
> 现在所有参数都已内联成字面量，全工程没有任何 `` `include ``，这个坑没有了。

### ☐ 17. Tcl Console 刷新编译顺序

点底部 **Tcl Console**，粘一行回车：

```tcl
update_compile_order -fileset sources_1
```

**你应该看到**：Console 回显提示，没有红色 ERROR。

# 阶段 4 · 建 Block Design（1 步）

### ☐ 18. 创建 BD

左侧 **Flow Navigator → IP INTEGRATOR → Create Block Design**。

弹出的对话框：

| 字段 | 填什么 |
|---|---|
| Design name | `vs_bd` |
| Directory | **留空**（默认落在工程目录） |
| Specify source set | 保持 `Design Sources` |

点 **OK**。

**你应该看到**：中间出现一个**纯白画布**，左上角有一竖排图标按钮
（箭头、加号、方块+ 等）。左下 **Block Design File** 面板空着。

---

# 阶段 5 · 加 Xilinx IP（6 步，一个一个来）

> 每次都是：**画布左侧竖排图标里点那个「+」加号按钮**（鼠标移上去提示 "Add IP"），
> 或者**在画布空白处右键 → Add IP...**。
> 弹出 "Search" 对话框，**在搜索框打字 → 列表里双击那一项** → IP 就落到画布上了。

### ☐ 19. 加 ZYNQ7 Processing System

搜索框输入 `zynq` → 列表里选 **ZYNQ7 Processing System** → 双击。

**你应该看到**：画布上出现一个蓝色大块 `processing_system7_0`，
画布上方弹出绿色横条。

> **先别点那个绿色横条**，把剩下的 IP 都加完再一起处理。

### ☐ 20. 加 AXI Direct Memory Access

搜索 `dma` → 选 **AXI Direct Memory Access** → 双击。
画布上出现 `axi_dma_0`。

### ☐ 21. 加 AXI SmartConnect

搜索 `smartconnect` → 选 **AXI SmartConnect** → 双击。
画布上出现 `axi_smc`。

### ☐ 22. 加 AXI GPIO

搜索 `axi gpio` → 选 **AXI GPIO** → 双击。
画布上出现 `axi_gpio_0`。

**立刻改名**：双击那块 → 在 Re-customize IP 窗口顶部的
**Component Name** 字段，把 `axi_gpio_0` 改成 `axi_gpio_ctrl` → OK。

> 改名是为了跟后面的连线清单对上。也可以在画布上选中它按 `F2` 改名。

### ☐ 22b. 加 AXI Protocol Converter ★

搜索 `protocol converter` → 选 **AXI Protocol Converter** → 双击。

**立刻改名**为 `axi_pc`（F2）。

**然后双击它**，在 Re-customize IP 里设 3 个下拉：

| 字段 | 设成 | Tcl 属性名 |
|---|---|---|
| **SI Protocol** | **AXI4** | `CONFIG.SI_PROTOCOL` |
| **MI Protocol** | **AXI3** | `CONFIG.MI_PROTOCOL` |
| **Data Width** | **32** | `CONFIG.DATA_WIDTH` |

OK 关闭。

> ⚠️ 这个 IP 的字段叫 **SI Protocol / MI Protocol**（不是 Slave/Master），
> 对应 Tcl 属性 `CONFIG.SI_PROTOCOL` / `CONFIG.MI_PROTOCOL`。
> 写成 `CONFIG.C_S_AXI_PROTOCOL` 只会得到一个
> `CRITICAL WARNING: [BD 41-1276] Parameter does not exist`，
> **属性不会被写进去，也不报错**——很难察觉。
>
> ⚠️ **Data Width 必须设 32**。这个转换器主从两侧共用一个数据宽度，
> 默认 32，而 PS 的 HP0 默认是 64，不改就会在 F6 时报
> `ERROR: [BD 41-237] Bus interface property DATA_WIDTH does not match
> between /processing_system7_0/S_AXI_HP0(64) and /axi_pc/M_AXI(32)`。

> **为什么必须加这个**：Zynq-7000 的 `S_AXI_HP0` 从机口是 **AXI3**，
> 而 AXI-DMA 的 `M_AXI_MM2S` 主机口是 **AXI4**。直接连会报
> `ERROR: [BD 41-1285] The protocols ... (AXI3) and ... (AXI4) are incompatible`。
> 必须中间插一个协议转换器。

### ☐ 23. 加 Processor System Reset

搜索 `processor system reset` → 选 **Processor System Reset** → 双击。
画布上出现 `proc_sys_reset_0`。

**立刻改名**为 `rst_ps7_100M`（同一个 Re-customize / F2 方式）。

**你应该看到**：画布上现在有 **6 个 Xilinx IP 块**：
`processing_system7_0`、`axi_dma_0`、`axi_smc`、`axi_gpio_ctrl`、`axi_pc`、`rst_ps7_100M`。

### ☐ 24. 点绿色横条跑 Block Automation

画布上方绿色横条写着
**"Designer Assistance available. Run Block Automation"** → **点它**。

弹出对话框，勾选 **All Automation**（如果有）→ OK。

**你应该看到**：
- `processing_system7_0` 块变大了，多出 `DDR`、`FIXED_IO` 两个接口引脚
- 画布右下角出现 `DDR` / `FIXED_IO` 两个外部端口
- Console 里打印若干条自动化信息

---

# 阶段 6 · 配置 PS7（7 步）

### ☐ 25. 打开 PS7 配置

**双击** `processing_system7_0` 块。
（或右键 → **Customize Block**）

**你应该看到**：Re-customize IP 窗口，左侧一长列配置树
（Zynq Block Design / PS-PL Configuration / Peripheral I/O Pins / ... / Clock Configuration / DDR Configuration / Interrupts）。

### ☐ 26. 开 GP0 主机口

左侧点 **PS-PL Configuration** → 展开 **AXI Non Secure Enablement → GP Master AXI Interface**
→ 勾选 **☑ M AXI GP0 interface**。

### ☐ 27. 开 HP0 从机口 + 把数据宽度设成 32 ★

同一个 **PS-PL Configuration** 页 → 展开 **AXI Non Secure Enablement → HP Slave AXI Interface**
→ 勾选 **☑ S AXI HP0 interface**。

然后**同一页里**找到 **HP0 Data Width** 下拉，从 `64` 改成 **`32`**。

> **为什么**：AXI-DMA 的 MM2S 口是 32 位，协议转换器两侧共用一个宽度也是 32 位。
> HP0 留在默认的 64 位，F6 校验会报
> `ERROR: [BD 41-237] Bus interface property DATA_WIDTH does not match
> between /processing_system7_0/S_AXI_HP0(64) and /axi_pc/M_AXI(32)`。
> 本设计每帧只有 80 个 32 位字、帧率 20 Hz，32 位带宽绰绰有余。

### ☐ 28. 确认 FCLK_RESET0_N

**PS-PL Configuration** → 展开 **General → Enable Clock Resets**
→ 勾选 **☑ FCLK_RESET0_N**。

### ☐ 29. PL 时钟设 100 MHz ★

左侧点 **Clock Configuration → PL Fabric Clocks**。

勾选 **☑ FCLK_CLK0**，右边 **Frequency (MHz)** 填 **`100`**。

> 下面 **Requested Frequency** 和 **Actual Frequency** 都应该显示 100.000。
> 如果实现后时序不收敛（WNS<0），回这里改成 50 再重跑一遍全流程。

### ☐ 30. 开 PL→PS 中断

左侧点 **Interrupts → Fabric Interrupts → PL-PS Interrupt Ports**
→ 勾选 **☑ IRQ_F2P**。

### ☐ 31. 开调试串口（可选但推荐）

左侧点 **Peripheral I/O Pins** → 在右侧表格里找到 **UART 1**
→ 勾选它的 **MIO** 那一列（会显示 `MIO 48 .. 49`）。

点 **OK** 关闭窗口。

**你应该看到**：`processing_system7_0` 块上多出 `M_AXI_GP0`、`S_AXI_HP0`、
`IRQ_F2P` 等引脚，`FCLK_CLK0` 也在。

---

# 阶段 7 · 把 19 个 RTL 模块拖进画布（19 步）★★

> **做法**：左侧 Sources 面板（Hierarchy 标签）里找到模块名 → **按住拖到画布空白处松手**。
> 模块会被放成一个块，名字自动加 `_0` 后缀。
> 拖完在画布空白处**右键 → Regenerate Layout** 让它们排列整齐。
>
> **加完每个之后，用 `F2` 或右键 → Rename 改成下表的实例名。** 名字必须对上。

| 步 | ☐ | 从 Sources 里拖这个模块 | 改名成 | 备注 |
|---|:-:|---|---|---|
| 32 | ☐ | `radar_frame_if` | `radar_frame_if_0` | 名字天然对，不用改 |
| 33 | ☐ | `dacm_phase` | `dacm_phase_0` | 不用改 |
| 34 | ☐ | `hampel7` | `hampel7_0` | 不用改 |
| 35 | ☐ | `integrate_detrend` | `integrate_detrend_0` | 不用改 |
| 36 | ☐ | `bin_selector` | `bin_selector_0` | 不用改 |
| 37 | ☐ | `robot_motion_if` | `robot_motion_if_0` | 不用改 |
| 38 | ☐ | `fir_bandpass` | `fir_resp_0` | **要改名** |
| 39 | ☐ | `fir_bandpass`（再拖一次） | `fir_card_0` | **要改名** |
| 40 | ☐ | `null_model_cancel` | `null_model_cancel_0` | 不用改 |
| 41 | ☐ | `goertzel_sweep` | `goertzel_resp_0` | **要改名** |
| 42 | ☐ | `goertzel_sweep`（再拖一次） | `goertzel_vr_0` | **要改名** |
| 43 | ☐ | `spectrum_accum` | `spectrum_accum_0` | 不用改 |
| 44 | ☐ | `peak_argmax` | `peak_argmax_0` | 不用改 |
| 45 | ☐ | `certificate_fsm` | `certificate_0` | **要改名** |
| 46 | ☐ | `vs_engine_fsm` | `vs_engine_0` | **要改名** |
| 47 | ☐ | `result_out` | `result_out_0` | 不用改 |
| 47a | ☐ | `bpm_map` | `bpm_map_0` | 不用改（峰值索引 → bpm） |
| 47b | ☐ | `ratio_q15` | `ratio_q15_0` | 不用改（peak/sum → 竞争比） |
| 47c | ☐ | `vs_defaults` | `vs_defaults_0` | 不用改（占位/默认值源） |

### ☐ 48. 核对
数一下画布上的块：**6 个 Xilinx IP + 19 个 RTL 模块 = 25 个**，加上阶段 8 的 3 个常量共 **28 个**。

> `vs_defaults` 是**故意**的一个块：所有还没有数据源的输入（共模参考、分量统计量、
> 运动阈值、雷达自定位开关……）都收敛到它上面，这样 BD 里没有悬空输入
> （Vivado 对未连接输入只给 `BD 41-759` 然后静默 tie 成 0），
> 而"哪部分还是占位"在数据流图上一眼可见。

> 拖不进去 / 列表里找不到某个模块 → 说明 Sources 里那个 `.v` 解析失败。
> 去底部 **Messages** 搜模块名，看有没有红色 ERROR。

---

# 阶段 8 · 加 3 个常量（4 步）

### ☐ 49~51. 加 xlconstant

**"+"（Add IP）** → 搜索 `constant` → 选 **Constant** → 双击。加 3 次。

然后**双击每个常量块**，在 Re-customize IP 里改：

| ☐ | 实例名（点中按 F2 改） | CONST_WIDTH | CONST_VAL |
|:-:|---|---|---|
| 49 | `const_resp` | 2 | 0 |
| 50 | `const_card` | 2 | 1 |
| 51 | `const_vrgrid` | 2 | 1 |

（在 Re-customize 的 "Const Width" 和 "Const Val" 两个字段里填。

**此时画布上一共 24 个块。**

> **为什么要常量**：`fir_bandpass` 的 `band_sel`、`goertzel_sweep` 的 `grid_sel`
> 是选择呼吸带/心脏带、呼吸网格/VR 网格的输入。模块引用方式下不能像 IP 那样设
> 参数默认值，所以用常量块拉死。

---

# 阶段 9 · 让机器连时钟 / 复位 / AXI（3 步）

### ☐ 52. 点 Run Connection Automation

画布上方绿色横条 → **Run Connection Automation**。

弹出对话框，**勾上最上面的 All Automation**（会连带勾选下面所有项）→ **OK**。

**你应该看到**：
- Console 打印一长串 `connect_bd_net` 之类
- 画布上出现 `rst_ps7_100M` 连到各块的线
- 各块的 `aclk` / `aresetn` 都接上了
- 底部 **Messages** 标签可能提示几条 warning，正常

### ☐ 53. 补连 SmartConnect 的复位

自动连线有时漏掉这个。检查 `axi_smc` 有没有 `aresetn` 接线；
没有就手动拖：从 `rst_ps7_100M` 的 `peripheral_aresetn` 输出引脚
拖到 `axi_smc` 的 `aresetn` 输入引脚。

Tcl 一行也行：
```tcl
connect_bd_net [get_bd_pins rst_ps7_100M/peripheral_aresetn] [get_bd_pins axi_smc/aresetn]
```

### ☐ 54. 核对接上的 AXI

点开 **Address Editor** 标签页（在画布上方，和 "Block Design" 并排），
看三个从机是否都被分配了地址：

| Slave | Offset Address |
|---|---|
| `axi_dma_0/S_AXI_LITE` | 0x4040_0000 附近 |
| `axi_gpio_ctrl/S_AXI` | 0x4120_0000 附近 |
| `result_out_0/s_axi` | 0x43C0_0000 附近 |

如果 Address Editor 是空的 → Tcl Console 敲 `assign_bd_address`。

---

# 阶段 10 · 连数据流（1 步，或 60 步）

## 路线 A（推荐）：粘一行

### ☐ 55. Tcl Console 粘这一行

```tcl
source D:/A_university_project/FPGAmmwave/fpga/tcl/wire_only.tcl
```

它会把剩下的数据流、控制线、常量线全部接完，最后分配地址 + 保存 + 校验。
Console 会分组打印进度（`--- 时钟 / 复位 ---`、`--- AXI ---`、`--- 雷达数据流 ---` …），
**没有 `!!` 开头的行就是全接上了**。

跑完跳到 **阶段 11**。

## 路线 B：纯手工一根根拖

> 一共 60 多根线。**强烈建议连完一类立刻按 F6 校验。**
> 连线方式：从源块的**输出引脚**按住拖到目标块的**输入引脚**松手。
> 对于 `m_axis_*` → `s_axis_*` 这种成组接口，拖一下会**自动连一整组**。

### ☐ 56. 先连窗口存储器与两条 FIR 分支

| 从 | 到 |
|---|---|
| `fir_resp_0/mem_addr` | `integrate_detrend_0/rd_addr` |
| `fir_card_0/mem_addr` | `integrate_detrend_0/rd_addr_b` |
| `fir_card_0/busy` | `integrate_detrend_0/rd_sel` |
| `integrate_detrend_0/rd_data` | `fir_resp_0/mem_data` |
| `integrate_detrend_0/rd_data` | `fir_card_0/mem_data` |

按 **F6** 校验一次。

### ☐ 57. 连常量

| 从 | 到 |
|---|---|
| `const_resp/dout` | `fir_resp_0/band_sel` |
| `const_resp/dout` | `goertzel_resp_0/grid_sel` |
| `const_card/dout` | `fir_card_0/band_sel` |
| `const_vrgrid/dout` | `goertzel_vr_0/grid_sel` |

> **注意**：一个输出接多个输入时，拖第二次会问 "Do you want to connect to an existing net?"
> 之类的提示 → 选 **Yes / 使用已有网络**。

按 **F6**。

### ☐ 58. 连两条 FIR 的启动与完成

| 从 | 到 |
|---|---|
| `vs_engine_0/bf_start_resp` | `fir_resp_0/start` |
| `vs_engine_0/bf_start_card` | `fir_card_0/start` |
| `vs_engine_0/bf_base_addr` | `fir_resp_0/base_addr` |
| `vs_engine_0/bf_base_addr` | `fir_card_0/base_addr` |
| `fir_resp_0/done` | `vs_engine_0/bf_done_resp` |
| `fir_card_0/done` | `vs_engine_0/bf_done_card` |

### ☐ 59. 连两个 DFT

| 从 | 到 |
|---|---|
| `vs_engine_0/gz_start_resp` | `goertzel_resp_0/start` |
| `vs_engine_0/gz_start_vr` | `goertzel_vr_0/start` |
| `vs_engine_0/gz_npts` | `goertzel_resp_0/npts` |
| `vs_engine_0/gz_npts` | `goertzel_vr_0/npts` |
| `goertzel_resp_0/done` | `vs_engine_0/gz_done_resp` |
| `goertzel_vr_0/done` | `vs_engine_0/gz_done_vr` |

### ☐ 60. 连谱累加

| 从 | 到 |
|---|---|
| `goertzel_resp_0/res_we` | `spectrum_accum_0/acc_we` |
| `goertzel_resp_0/res_addr` | `spectrum_accum_0/acc_addr` |
| `goertzel_resp_0/res_mag` | `spectrum_accum_0/acc_mag` |
| `goertzel_vr_0/res_we` | `spectrum_accum_0/acc_we_b` |
| `goertzel_vr_0/res_addr` | `spectrum_accum_0/acc_addr_b` |
| `goertzel_vr_0/res_mag` | `spectrum_accum_0/acc_mag_b` |
| `vs_engine_0/accum_clr` | `spectrum_accum_0/clr` |

### ☐ 61. 连峰值搜索与证书

| 从 | 到 |
|---|---|
| `vs_engine_0/pk_start` | `peak_argmax_0/start` |
| `vs_engine_0/pk_npts` | `peak_argmax_0/npts` |
| `peak_argmax_0/rd_addr` | `spectrum_accum_0/rd_addr` |
| `spectrum_accum_0/rd_mag` | `peak_argmax_0/rd_mag` |
| `peak_argmax_0/done` | `vs_engine_0/pk_done` |
| `vs_engine_0/cert_start` | `certificate_0/start` |
| `certificate_0/done` | `vs_engine_0/cert_done` |
| `peak_argmax_0/peak_val` | `certificate_0/compet_vr_q15` |
| `peak_argmax_0/contrast_q12` | `certificate_0/vr_contrast_q12` |
| `integrate_detrend_0/win_ready` | `vs_engine_0/win_ready` |

按 **F6**。

### ☐ 62. 连空间选择与机器人接口

| 从 | 到 |
|---|---|
| `axi_gpio_ctrl/gpio_io_o` | `robot_motion_if_0/reg_vision_range` |
| `axi_gpio_ctrl/gpio2_io_o` | `robot_motion_if_0/reg_robot_vel` |
| `robot_motion_if_0/vision_range_q16` | `bin_selector_0/vision_range_q16` |
| `bin_selector_0/bin_mask` | `vs_engine_0/bin_mask` |
| `bin_selector_0/out_of_range` | `certificate_0/out_of_range` |
| `robot_motion_if_0/motion_reject` | `certificate_0/motion_reject` |
| `vs_engine_0/fr_inc_out` | `null_model_cancel_0/fr_inc` |

### ☐ 63. 连结果输出

| 从 | 到 |
|---|---|
| `certificate_0/decision` | `result_out_0/decision` |
| `certificate_0/quality_q8` | `result_out_0/quality_q8` |
| `certificate_0/confidence_q15` | `result_out_0/confidence_q15` |
| `peak_argmax_0/contrast_q12` | `result_out_0/vr_contrast_q12` |
| `bin_selector_0/bin_mask` | `result_out_0/bin_mask` |
| `bin_selector_0/eff_range_q16` | `result_out_0/eff_range_q16` |
| `robot_motion_if_0/robot_cmd_out` | `result_out_0/robot_cmd` |
| `vs_engine_0/meas_done` | `result_out_0/meas_done` |
| `integrate_detrend_0/win_ready` | `result_out_0/win_ready` |
| `vs_engine_0/fr_inc_out` | `result_out_0/fr_inc` |
| `result_out_0/irq` | `processing_system7_0/IRQ_F2P` |

### ☐ 64. 临时连雷达输入（先让 BD 能过校验）

`radar_frame_if_0/s_axis` 应该已经被 Connection Automation 接到
`axi_dma_0/M_AXIS_MM2S`。核对一下：

| 从 | 到 |
|---|---|
| `axi_dma_0/M_AXIS_MM2S` | `radar_frame_if_0/s_axis` |

### ☐ 65. 连四条模块之间的 stream

| 从 | 到 |
|---|---|
| `radar_frame_if_0/m_axis` | `dacm_phase_0/s_axis` |
| `dacm_phase_0/m_axis` | `hampel7_0/s_axis` |
| `hampel7_0/m_axis` | `integrate_detrend_0/s_axis` |
| `fir_resp_0/m_data` | `goertzel_resp_0/s_data` |
| `fir_resp_0/m_valid` | `goertzel_resp_0/s_valid` |
| `fir_resp_0/m_ready` | `goertzel_resp_0/s_ready` |
| `fir_card_0/m_data` | `null_model_cancel_0/s_data` |
| `fir_card_0/m_valid` | `null_model_cancel_0/s_valid` |
| `fir_card_0/m_ready` | `null_model_cancel_0/s_ready` |
| `null_model_cancel_0/m_data` | `goertzel_vr_0/s_data` |
| `null_model_cancel_0/m_valid` | `goertzel_vr_0/s_valid` |
| `null_model_cancel_0/m_ready` | `goertzel_vr_0/s_ready` |

> 这三组是 `data/valid/ready` 普通信号流，**不是 AXI-Stream 接口**，
> 三根线要各自单独拖。注意 `m_ready` 是 FIR 的**输入**、`s_ready` 是下游的**输出**。
> `m_ready` / `s_ready` 如果报未连接，接一个 Constant=1 或者两两对接。

---

# 阶段 11 · 校验（2 步）

### ☐ 66. Validate Design

按 **F6**（或画布右键 → **Validate Design**）。

**你应该看到**：弹窗 **"Validation successful"** → 点 OK。

**如果报 ERROR**：点弹窗里的 "Critical Messages" 或去 **Messages** 标签看红色条目。
常见就三类：

| 报错 | 处理 |
|---|---|
| `input pin ... is not connected` | 按阶段 10 的表补线；确认不用的输入接 Constant |
| `... has no address assigned` | Tcl Console：`assign_bd_address` |
| `... clock pin is not connected` | 补 `FCLK_CLK0` → 该块 `aclk` 的线 |

> **黄色 warning（unconnected、unused）可以忽略**，不算失败。

### ☐ 67. 保存
`Ctrl+S`，或画布上方保存图标。

**你应该看到**：左侧 Sources → Hierarchy 里出现 `vs_bd`（带一个小图标）。

---

# 阶段 12 · 生成 HDL Wrapper（3 步）

### ☐ 68. 右键 Create HDL Wrapper

左侧 **Sources** 面板（切到 **Hierarchy** 标签）→ 找到 **`vs_bd`**
→ **右键 → Create HDL Wrapper...**

### ☐ 69. 选自动管理
弹窗里选 **Let Vivado manage wrapper and auto-update** → **OK**。

**你应该看到**：Sources 里多出 `vs_bd_wrapper (vs_bd_wrapper.v)`，
且名字是**粗体**（表示是顶层）。

### ☐ 70. 确认顶层
如果不是粗体：右键 `vs_bd_wrapper` → **Set as Top**。

---

# 阶段 13 · 综合（3 步）

### ☐ 71. Run Synthesis
左侧 **Flow Navigator → SYNTHESIS → Run Synthesis**。

弹窗里：
- **Number of jobs** 填 `8`
- **Strategy** 保持 `Vivado Synthesis Defaults`
- **☐ Launch runs on local host**（保持默认勾选）

→ **OK**。等 **3~6 分钟**（右下角有进度条）。

### ☐ 72. 处理 ROM 报错 ★

跑完如果弹窗提示 **Failed**，切到 **Messages** 找红色条目。

**最常见的一条**：
```
ERROR: [Synth 8-4445] $readmemh: cannot open file sin_lut.mem
```
→ 说明阶段 2 的 `.mem` 文件类型没设对。补救：
1. 回阶段 2 第 15 步重设类型，重跑综合。
2. 或者干脆在文件管理器里把 5 个 `.mem` 复制到
   `D:\A_university_project\FPGAmmwave\fpga\prj\vs_fpga.runs\synth_1\`
   再 `Run Synthesis`。

**如果提示 "Synthesis completed"** → 弹窗选 **Open Synthesized Design**（可以）。

### ☐ 73. 看资源占用

左侧 **Open Synthesized Design → Report Utilization**
（或菜单 `Reports → Report Utilization`）。

**你应该看到**（量级对得上就行）：

| 资源 | 预计 | 器件总量 |
|---|---:|---:|
| Block RAM Tile | ~54 | 140 |
| DSPs | ~14 | 220 |
| Slice Registers | ~15 000 | 106 400 |
| Slice LUTs | ~12 000 | 53 200 |

---

# 阶段 14 · 实现 + 比特流（3 步）

### ☐ 74. Run Implementation
左侧 **Flow Navigator → IMPLEMENTATION → Run Implementation** → OK。
等 **5~15 分钟**。

### ☐ 75. 看时序 ★

跑完后左侧 **Open Implemented Design → Report Timing Summary**
（或 `Reports → Timing → Report Timing Summary`）。

**看 `WNS`（Worst Negative Slack）**：
- **WNS ≥ 0** → ✅ 时序收敛，继续
- **WNS < 0** → ❌ 降频：回阶段 6 第 29 步把 FCLK_CLK0 从 100 改成 **50**
  → 重新 `F6` 校验 → 重做 wrapper → 重跑综合实现

### ☐ 76. Generate Bitstream
左侧 **Flow Navigator → PROGRAM AND DEBUG → Generate Bitstream** → OK。等 **2~5 分钟**。

**你应该看到**：
```
D:\A_university_project\FPGAmmwave\fpga\prj\vs_fpga.runs\impl_1\vs_bd_wrapper.bit
```

---

# 阶段 15 · 导出硬件平台（2 步）

### ☐ 77. Export Hardware
菜单 **File → Export → Export Hardware...**

### ☐ 78. 勾 bitstream
- **☑ Include bitstream**
- **Export to**：默认 `.../fpga/prj/vs_design.xsa`

→ **OK**。

**你应该看到**：`prj\vs_design.xsa` 生成（几十 MB）。

---

# 阶段 16 · 上板 / 写 PS 程序

导出的 `.xsa` 给 **Vitis 2019.1**（或 Xilinx SDK）：

1. `File → New → Platform Project` → 导入 `vs_design.xsa`
2. `File → New → Application Project` → Hello World 模板
3. PS 程序要干的三件事：
   - 配 AXI-GPIO 写视觉距离 / 机器人速度 / 门限
   - 用 `XAxiDma_SimpleTransfer()` 每帧送 80 个 `{Q[15:0], I[15:0]}` 到 MM2S
     （首字 TUSER=1，末字 TLAST=1）
   - 中断里读 `result_out` 寄存器：**`heart_bpm` 在偏移 `0x00`，
     Q8.8 格式，读到的值 ÷256 才是 bpm**

上板时用 **Hardware Manager** 下载 `.bit`（或固化进 QSPI/SD），
开串口终端 115200 看结果。

---

# 卡住时的排查顺序

1. **Sources 里某个模块是灰的/带问号** → 那个 `.v` 语法有问题，
   去 Messages 搜文件名。
2. **BD 里拖不进模块** → 先 `update_compile_order -fileset sources_1`，
   再 `Regenerate Layout`。
3. **校验报未连接** → 对照阶段 10 的表；实在找不到就
   `Report → Report DRC` 列出所有未连端口。
4. **综合找不到 include 文件** → 阶段 3 那段 Tcl 重跑一遍。
5. **综合找不到 .mem** → 阶段 2 第 15 步 / 第 72 步。
6. **时序不收敛** → FCLK_CLK0 降到 50 MHz。

---

# 相关文件

| 文件 | 作用 |
|---|---|
| `tcl/wire_only.tcl` | **只连线**（阶段 10 的省力路线 A） |
| `tcl/build_bd.tcl` | 从头自动建 BD（跳过阶段 4~10 全部） |
| `tcl/build_all.tcl` | 建工程 + 源码 + BD 一次做完 |
| `tcl/build_after_bd.tcl` | 阶段 12~15 全自动（wrapper→综合→实现→bit→xsa） |
| `docs/数据流图.html` | 连完线后对照检查用 |
| `docs/架构与移植说明.md` | 每个模块干什么、对应 Python 哪一步 |
