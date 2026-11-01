# src/ps — PS 侧（ARM Cortex-A9）接口说明

本仓库的 RTL 只负责 PL 侧计算。PS 侧要做的事只有三件：**灌数据 → 等中断 → 读寄存器**。
下面把接口固化下来，PS 程序按此实现即可，不需要再读 RTL。

## 1. 数据通路

```
DDR (帧缓冲)  --AXI-DMA MM2S-->  radar_frame_if  -->  ... -->  result_out (AXI4-Lite)
     ^                                                              |
     |                                                              v
     +--------  PL 侧中断 IRQ_F2P  ---------------------->  GIC 91 (共享外设中断)
```

* AXI-DMA 配置为 **MM2S only**（`c_include_s2mm = 0`），无 scatter-gather，简单模式。
* DMA 的 `M_AXI_MM2S` 经 `axi_protocol_converter`（AXI4 → AXI3）接到 PS 的 `S_AXI_HP0`，
  数据宽度两侧都是 **32 位**。
* `result_out` 作为 AXI4-Lite 从端挂在 `M_AXI_GP0` 上，基地址 **`0x43C0_0000`**（64 KB）。

## 2. 帧格式

每帧 **80 个 32 位字**（4 RX × 20 距离仓），字内布局：

```
 bit 31              16 15               0
+---------------------+------------------+
|      Q[15:0]        |     I[15:0]      |
+---------------------+------------------+
```

* 字序号 `w = 0 .. 79`，通道号 `ch = w`；`radar_frame_if` 按 `ch = rx*20 + bin` 拆包。
* **首字 `TUSER = 1`**（标记帧起点），**末字 `TLAST = 1`**（标记帧结束）。
* 帧率 20 Hz；分析窗 600 帧 = 30 s，前 300 帧（15 s）用于稳定，之后进入估计。
* 帧数据来自 `ddc` 后的复数距离像（每仓一个复数），即 Python 侧 `radar` 输出的
  `(n_frame, n_rx, n_bin)` 复数组，按 `np.float16/int16` 打包。

## 3. 寄存器映射（`result_out`，偏移以字节计）

| 偏移 | 名称 | 位域 | 说明 |
|---:|---|---|---|
| `0x00` | `heart_bpm` | `[15:0]` **Q8.8** | 心率，读到的值 **÷256** 才是 bpm |
| `0x04` | `resp_bpm` | `[15:0]` Q8.8 | 呼吸率 |
| `0x08` | `decision` / `quality` | `[18:16]` / `[15:0]` Q1.15 | 决策码 + 质量分 |
| `0x0C` | `support` / `confidence` | `[31:16]` / `[15:0]` Q1.15 | 分量一致度 / 置信度 |
| `0x10` | `vr_contrast` / `compet_vr` | `[31:16]` Q4.12 / `[15:0]` Q1.15 | 谱峰对比度 / 竞争比 |
| `0x14` | 标志位组 | `[3:0]` | `[0]` outlier, `[1]` out_of_range, `[2]` motion_reject, `[3]` harmonic_collision |
| `0x18` | `bin_mask` | `[19:0]` | 20 个距离仓的候选掩码 |
| `0x1C` | `n_free` / `n_sel` | `[12:8]` / `[4:0]` | 空仓数 / 选中仓数 |
| `0x20` | `eff_range` | `[31:0]` Q16.16 | 有效距离（m） |
| `0x24` | 状态 | `[1:0]` | `[0]` win_ready, `[1]` busy |
| `0x28` | `robot_cmd` | `[31:0]` | 回给底盘的限速/停机控制字 |
| `0x2C` | `fr_inc` | `[31:0]` | 呼吸基频相位增量（`f/20 * 2^32`） |
| `0x30` | `frame_cnt` | `[15:0]` | 累计帧数 |

**决策码 `decision`**：

| 值 | 含义 |
|---:|---|
| 0 | `MEASURE` 可信测量 |
| 1 | `LOW_CONFIDENCE` 低置信 |
| 2 | `REJECT_RANGE` 距离越界 |
| 3 | `NO_CANDIDATE` 无候选仓 |
| 4 | `REJECT_MOTION` 机器人运动 |
| 5 | `REJECT_HARMONIC` 谐波碰撞 |

## 4. 典型 PS 流程

```c
/* 1. 初始化 DMA：源地址 = 帧缓冲，长度 = 80*4 字节，简单模式 */
XDmaPs_SetSrcAddress(&dma, (u32)frame_buf, XDmaPs_GetSrcAddress(&dma));
XDmaPs_SetDmaLength(&dma, 80 * 4, 0);

/* 2. 每帧触发一次（可由定时器 20 Hz 驱动，或由 I2S/雷达采集中断驱动） */
XDmaPs_Start(&dma, 0, 0);

/* 3. 等 PL 中断（GIC 91）——一次估计完成才来一次，不是每帧都来 */
XDmaPs_WaitForIrq();

/* 4. 读结果 */
u32 raw   = Xil_In32(RESULT_BASE + 0x00);
float bpm = (int16_t)(raw & 0xFFFF) / 256.0f;
u32 dec   = (Xil_In32(RESULT_BASE + 0x08) >> 16) & 0x7;

/* 5. 低速闭环：把控制字回给底盘 */
Xil_Out32(ROBOT_CMD_REG, robot_cmd);   /* 或经 AXI GPIO 送出 */
```

## 5. 与 Python 侧的对应关系

| PS 侧动作 | Python 侧对应 |
|---|---|
| 20 Hz 灌 80 字帧 | `dataio.py` 逐帧送 `(n_rx, n_bin)` 复数矩阵 |
| 读 `heart_bpm` | `estimator.py` 返回的 `heart_bpm` |
| 读 `decision` | `certificate` 分级结果 |
| 写 `robot_cmd` | `run.py` 里根据运动状态下发的控制字 |

> 本目录只描述接口，不含 Vitis 工程。建工程时把 `board/artifacts/vs_design.xsa`
> 导入 Vitis，地址常量会出现在 `xparameters.h`（`XPAR_RESULT_OUT_0_S_AXI_BASEADDR`）。
