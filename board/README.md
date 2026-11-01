# board — 上板工程与实测

## 硬件平台

| 项 | 值 |
|---|---|
| 器件 | ZYNQ-7020 `xc7z020clg400-2` |
| PL 时钟 | `FCLK_CLK0 = 100 MHz`（可由 PS7 配置改成 50 MHz） |
| DDR | MT41J256M16 RE-125（PS7 默认配置） |
| 串口 | `UART1`，115200 8N1（PS 侧打印用） |
| 雷达前端 | TI IWR6843，20 Hz 帧率，4 RX × 20 距离仓复数距离像 |
| 底盘 | AlohaMini（串口/CAN 收控制字） |

> 本设计的 PL 侧**没有自定义管脚**：数据从 PS 的 DDR 经 AXI-DMA 进入 PL，
> 结果经 AXI4-Lite 回到 PS。因此不需要写 `.xdc` 约束文件，
> 只有 PS7 的 DDR / MIO / UART 配置（全部在 Block Design 里）。

## 1. 生成上板文件

```bat
cd <repo>\build
build_vivado.bat
```

跑完会得到：

| 文件 | 位置 | 用途 |
|---|---|---|
| `vs_design.xsa` | `board/artifacts/` | 导入 Vitis，生成 PS 侧 BSP 与地址常量 |
| `vs_bd_wrapper.bit` | `board/artifacts/` | 烧到 PL（通常由 Vitis 打包进 BOOT.bin） |

## 2. PS 侧程序

接口（寄存器映射、帧格式、DMA 时序）见 [`../src/ps/README.md`](../src/ps/README.md)。

Vitis 里的做法：

1. `File → New → Platform Project`，导入 `board/artifacts/vs_design.xsa`；
2. `File → New → Application Project`，模板选 `Hello World`，基于上一步的 platform；
3. 把 `src/ps/README.md` 里的流程实现进 `main.c`：初始化 DMA → 20 Hz 触发 → 等中断 → 读 `0x43C0_0000`；
4. Build 后 `Run Configuration` 直接下载，或打包 `BOOT.bin` 从 SD 卡启动。

地址常量的名字来自 `.xsa`：

```c
#define RESULT_BASE   XPAR_RESULT_OUT_0_S_AXI_BASEADDR   /* 0x43C0_0000 */
```

## 3. 串口输出建议

一次估计完成打一行，便于与 Python 侧日志逐一对照：

```
frame=0612 win=READY  hr=72.3bpm  rr=15.1bpm  q=0.86  dec=MEASURE  sel=6/20  range=1.85m
```

## 4. 实测记录

结果记在本节表格里（每轮实验一行），原始日志放 `board/logs/`。

| 日期 | 受试者 / 场景 | 距离 | 心率 (bpm) | 呼吸 (bpm) | 质量分 | 决策 | 备注 |
|---|---|---:|---:|---:|---:|---|---|
|  | 静坐，正面 |  |  |  |  |  |  |
|  | 静坐，侧向 45° |  |  |  |  |  |  |
|  | 底盘运动后停稳 |  |  |  |  |  |  |

**对照方法**：同一时间段用指夹式血氧仪/胸带取参考值，按
`|hr_fpga − hr_ref|` 统计 MAE；Python 参考实现的输出见 `python代码/`（不在本仓库）。

## 5. 常见现象与排查

| 现象 | 可能原因 | 排查 |
|---|---|---|
| `heart_bpm` 恒为 0 | DMA 没送数，或帧格式不符（缺 `TUSER/TLAST`） | 读 `0x30 frame_cnt` 是否在涨 |
| 中断不来 | `.xsa` 里 IRQ_F2P 未接到 PS7，或 GIC 未使能 | 查 Block Design 的 `IRQ_F2P` 连线与 Vitis 的 `XScuGic` 初始化 |
| 心率跳变大 | 候选仓选错 / 机器人仍在动 | 读 `0x18 bin_mask`、`0x14 motion_reject` |
| 一直 `REJECT_RANGE` | 视觉距离与雷达仓索引对不上 | 读 `0x20 eff_range`，核对 `bin_selector` 的 R_MIN/R_MAX |
