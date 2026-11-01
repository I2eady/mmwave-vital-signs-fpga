#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_bd_doc_assets.py -- 从真实 RTL 端口 + build_bd.tcl 的实际连线，生成

  * docs/bd_images/00_overview.png      算法模块总览（含数据流箭头）
  * docs/bd_images/<cell>.png           每个算法模块一张单独图（端口 + 上下游连接）
  * docs/bd_images/nets_*.md            分类连接关系表（Markdown）

所有信息都从 rtl/**/*.v 的端口声明与 tcl/build_bd.tcl 的 vs_net / vs_link 解析出来，
不手写，保证与工程一致。图中只出现 ASCII（模块名/端口名/位宽），中文说明放在 Word 里。
"""

import io, os, re, glob
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrow

# 图里要出现中文（模块功能说明），找一个系统里的中文字体
CJK = None
for _p in ("C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/msyhl.ttc",
           "C:/Windows/Fonts/simhei.ttf", "C:/Windows/Fonts/simsun.ttc"):
    if os.path.exists(_p):
        CJK = fm.FontProperties(fname=_p)
        break
if CJK is None:
    print("WARNING: no CJK font found, Chinese labels will be boxes")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "bd_images")
os.makedirs(OUT, exist_ok=True)

DPI = 200
FIG_W = 6.5

# ---------------------------------------------------------------------------
# 每个模块的中文说明（写文档用，不进图）
# ---------------------------------------------------------------------------
INFO = {
 "radar_frame_if":    ("帧接口", "AXI-Stream 解帧、通道解复用(ch=rx*20+bin)、分析窗门控"),
 "dacm_phase":        ("相位增量", "DACM: dphi=(I*dQ-Q*dI)/(I^2+Q^2)，内含逐位恢复除法器"),
 "hampel7":           ("鲁棒清洗", "窗7中值 + MAD 野值剔除"),
 "integrate_detrend": ("积分去趋势", "相位积分 + 逐通道最小二乘去趋势 + 600x80 窗口存储器"),
 "fir_bandpass":      ("线性相位带通", "1024抽头对称FIR，折叠MAC，对称即零相位(等价filtfilt)"),
 "goertzel_sweep":    ("谱扫描", "任意频率网格的精确DFT(非FFT)，呼吸91点 / VR 201点"),
 "null_model_cancel": ("谐波抵消", "呼吸谐波+共模的LMS自适应抵消"),
 "spectrum_accum":    ("谱累加", "跨(bin,RX)非相干累加 P_fuse(f)=sum_c P_c(f)"),
 "peak_argmax":       ("峰值搜索", "argmax + 抛物线亚bin插值 + 峰/中位对比度"),
 "bpm_map":           ("频率换算", "峰值索引->心率/呼吸率 Q8.8 (仿射: bpm=base+k*step)"),
 "ratio_q15":         ("竞争比", "peak/sum -> Q1.15"),
 "certificate_fsm":   ("质量证书", "质量分加权 + 门限分级 MEASURE/LOW_CONF/REJECT"),
 "bin_selector":      ("候选仓", "视觉距离->候选仓掩码/空仓掩码"),
 "robot_motion_if":   ("运动门控", "机器人运动门控 + 反向控制字 hold/slow/meas"),
 "vs_engine_fsm":     ("时序编排", "状态机: 逐候选通道调度 FIR->DFT->抵消->峰值->证书"),
 "vs_defaults":       ("占位默认值", "尚未实现的输入集中于此(共模参考/分量统计/运动阈值)"),
 "result_out":        ("结果寄存器", "14个32位寄存器 + AXI4-Lite从端 + 中断"),
}

# 模块 -> 中文链名（用于总览配色）
CHAIN = {
 "radar_frame_if": "A", "dacm_phase": "B", "hampel7": "B", "integrate_detrend": "B",
 "fir_bandpass": "C", "goertzel_sweep": "D", "null_model_cancel": "D",
 "spectrum_accum": "E", "peak_argmax": "E", "bpm_map": "E", "ratio_q15": "E",
 "certificate_fsm": "F", "bin_selector": "G", "robot_motion_if": "G",
 "vs_engine_fsm": "H", "vs_defaults": "H", "result_out": "F",
}
CHAIN_NAME = {"A": "入口", "B": "相位链", "C": "滤波", "D": "谱/鲁棒",
              "E": "融合取峰", "F": "决策输出", "G": "空间/机器人", "H": "控制"}


# ---------------------------------------------------------------------------
# 解析
# ---------------------------------------------------------------------------
def strip_c(t):
    t = re.sub(r"/\*.*?\*/", " ", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def resolve_width(rng, params):
    if not rng:
        return 1
    m = re.match(r"\[\s*(.*?)\s*:\s*(.*?)\s*\]$", rng.strip())
    if not m:
        return None
    env = dict(params)

    def clog2(mo):
        try:
            v = int(eval(mo.group(1), {"__builtins__": {}}, env))
            return str(max(1, (v - 1).bit_length()))
        except Exception:
            return "0"
    out = []
    for e in (m.group(1), m.group(2)):
        e = re.sub(r"\$clog2\s*\(([^()]*)\)", clog2, e)
        for k, v in env.items():
            e = re.sub(r"\b%s\b" % re.escape(k), str(v), e)
        if re.search(r"[A-Za-z_]", e):
            return None
        try:
            out.append(int(eval(e, {"__builtins__": {}}, {})))
        except Exception:
            return None
    return abs(out[0] - out[1]) + 1


def parse_modules():
    mods = {}
    for f in glob.glob(os.path.join(ROOT, "rtl", "**", "*.v"), recursive=True):
        text = strip_c(io.open(f, encoding="utf-8", errors="ignore").read())
        for mm in re.finditer(r"\bmodule\s+(\w+)\b(.*?)\bendmodule\b", text, re.S):
            name, body = mm.group(1), mm.group(2)
            params = {}
            pm0 = re.search(r"#\s*\((.*?)\)\s*\(", body, re.S)
            if pm0:
                for pm in re.finditer(r"\bparameter\b[^=\n]*?(\w+)\s*=\s*([^,\n]+)", pm0.group(1)):
                    try:
                        params[pm.group(1)] = int(eval(pm.group(2).strip(), {"__builtins__": {}}, {}))
                    except Exception:
                        pass
            pm = re.match(r"\s*(#\s*\((?:[^()]|\([^()]*\))*\))?\s*\((.*?)\)\s*;", body, re.S)
            if not pm:
                continue
            ports = {}
            for am in re.finditer(r"\b(input|output|inout)\b\s*(?:wire|reg|logic)?\s*"
                                  r"(?:signed|unsigned)?\s*(\[[^\]]*\])?\s*([^,;)]+)", pm.group(2)):
                d, rng, names = am.groups()
                w = resolve_width(rng, params)
                for pn in names.split(","):
                    if pn.strip():
                        ports[pn.strip()] = (d, w)
            mods[name] = {"file": os.path.relpath(f, ROOT).replace("\\", "/"), "ports": ports}
    return mods


def parse_tcl():
    txt = io.open(os.path.join(ROOT, "tcl", "build_bd.tcl"), encoding="utf-8").read()
    cell2mod = {}
    for m in re.finditer(r"^mkmod\s+(\S+)\s+(\S+)\s*$", txt, re.M):
        cell2mod[m.group(2)] = m.group(1)
    nets, intfs, loops = [], [], []
    for m in re.finditer(r"^vs_net\s+(\S+)\s+(\S+)\s*$", txt, re.M):
        a, b = m.group(1).split("/"), m.group(2).split("/")
        if len(a) == 2 and len(b) == 2:
            nets.append((a[0], a[1], b[0], b[1]))
    for m in re.finditer(r"^vs_link\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$", txt, re.M):
        intfs.append((m.group(1), m.group(2), m.group(3), m.group(4)))
    # 循环里的批量连线（时钟/复位）
    for m in re.finditer(r"foreach c \$(rtl_clk|rtl_rst) \{ vs_net (\S+) \$c/(\w+) \}", txt):
        kind, src, pin = m.group(1), m.group(2), m.group(3)
        loops.append((kind, src, pin))
    return cell2mod, nets, intfs, loops


# ---------------------------------------------------------------------------
# 生成单模块图
# ---------------------------------------------------------------------------
def draw_module(cell, modinfo, in_rows, out_rows, mods):
    n = max(len(in_rows) + len(out_rows), 1)
    row_h, hdr_h, pad = 0.185, 0.62, 0.14
    H = hdr_h + n * row_h + pad * 2

    fig = plt.figure(figsize=(FIG_W, H), dpi=DPI)
    fig.patch.set_facecolor("white")

    def T(x, y, s, size=7.6, weight="normal", color="#1a1a1a", family="monospace",
          ha="left", cjk=False):
        fig.text(x / FIG_W, 1 - y / H, s, fontsize=size, fontweight=weight, color=color,
                 ha=ha, va="center",
                 **({"fontproperties": CJK} if (cjk and CJK) else {"family": family}))

    mod = modinfo["mod"]
    zh, algo = INFO.get(mod, ("", ""))
    T(pad, 0.22, "%s" % cell, size=13, weight="bold")
    T(pad, 0.44, "module %s   [%s]   %s" % (mod, zh, modinfo["file"]), size=7.8,
      color="#555555", cjk=True)
    T(pad, 0.62, algo, size=7.8, color="#333333", cjk=True)

    y = hdr_h + pad
    for (port, w, peers) in in_rows:
        fig.patches.append(Rectangle((0, (H - y - row_h) / H), 1, row_h / H,
                                     transform=fig.transFigure, facecolor="#378ADD",
                                     alpha=0.07, edgecolor="none", zorder=0))
        arrow = "->" if peers else "  "
        T(pad, y + row_h / 2, "IN   %-46s %s %s" % (peers[:46], arrow, port), size=7.6)
        if w:
            T(FIG_W - pad, y + row_h / 2, "%sb" % w, size=7.0, color="#777777", ha="right")
        y += row_h
    for (port, w, peers) in out_rows:
        fig.patches.append(Rectangle((0, (H - y - row_h) / H), 1, row_h / H,
                                     transform=fig.transFigure, facecolor="#1D9E75",
                                     alpha=0.07, edgecolor="none", zorder=0))
        T(pad, y + row_h / 2, "OUT  %-30s -> %s" % (port, peers[:46]), size=7.6)
        if w:
            T(FIG_W - pad, y + row_h / 2, "%sb" % w, size=7.0, color="#777777", ha="right")
        y += row_h
    if not in_rows and not out_rows:
        T(pad, y + row_h / 2, "(no connections)", size=7.6, color="#999999")

    fig.patches.append(Rectangle((0, 0), 1, 1, transform=fig.transFigure,
                                 facecolor="none", edgecolor="#BBBBBB", linewidth=0.6))
    fig.savefig(os.path.join(OUT, "%s.png" % cell), dpi=DPI,
                facecolor="white", bbox_inches=None)
    plt.close(fig)


# ---------------------------------------------------------------------------
# 总览图
# ---------------------------------------------------------------------------
ROWS = [
    ("入口", ["radar_frame_if_0"]),
    ("相位链", ["dacm_phase_0", "hampel7_0", "integrate_detrend_0"]),
    ("滤波", ["fir_resp_0", "fir_card_0"]),
    ("谱 / 鲁棒", ["goertzel_resp_0", "null_model_cancel_0", "goertzel_vr_0"]),
    ("融合取峰", ["spectrum_accum_0", "peak_argmax_0", "bpm_map_0", "ratio_q15_0"]),
    ("决策输出", ["certificate_0", "result_out_0"]),
    ("协同编排", ["bin_selector_0", "robot_motion_if_0", "vs_engine_0", "vs_defaults_0"]),
]


def draw_overview():
    H = 0.72 + len(ROWS) * (0.30 + 0.055) + 0.34
    fig = plt.figure(figsize=(FIG_W, H), dpi=DPI)
    fig.patch.set_facecolor("white")

    def T(x, y, s, size=7.4, weight="normal", color="#1a1a1a", family="monospace",
          ha="left", va="center", cjk=False):
        fig.text(x / FIG_W, 1 - y / H, s, fontsize=size, fontweight=weight, color=color,
                 ha=ha, va=va,
                 **({"fontproperties": CJK} if (cjk and CJK) else {"family": family}))

    T(0.10, 0.22, "vs_bd 算法模块总览 — 19 个实例 / 17 个模块",
      size=11, weight="bold", cjk=True)
    T(0.10, 0.40, "+ 6 个 Xilinx IP（PS7 / DMA / SmartConnect / GPIO / 协议转换器 / 复位）"
                  " + 3 个常量", size=7.4, color="#555555", cjk=True)

    top, rh, gap, bw = 0.72, 0.30, 0.055, 4.42
    lx, lw = 0.12, 0.80
    for i, (name, cells) in enumerate(ROWS):
        y = top + i * (rh + gap)
        fig.patches.append(Rectangle((lx / FIG_W, 1 - (y + rh) / H), lw / FIG_W, rh / H,
                                     transform=fig.transFigure, facecolor="#F1EFE8",
                                     edgecolor="#B4B2A9", linewidth=0.6))
        T(lx + lw / 2, y + rh / 2, name, size=7.6, cjk=True, ha="center")
        n = len(cells)
        cw = (bw - (n - 1) * 0.06) / n
        for j, c in enumerate(cells):
            x = lx + lw + 0.14 + j * (cw + 0.06)
            tint = {"A": "#E6F1FB", "B": "#E6F1FB", "C": "#EAF3DE", "D": "#EEEDFE",
                    "E": "#FAEEDA", "F": "#FCEBEB", "G": "#E1F5EE", "H": "#F1EFE8"}
            mod = cell_mod.get(c, "")
            col = tint.get(CHAIN.get(mod, "H"), "#F1EFE8")
            fig.patches.append(FancyBboxPatch((x / FIG_W, 1 - (y + rh) / H),
                                              cw / FIG_W, rh / H,
                                              boxstyle="round,pad=0,rounding_size=0.015",
                                              transform=fig.transFigure, facecolor=col,
                                              edgecolor="#888780", linewidth=0.6))
            T(x + cw / 2, y + rh / 2, c, size=7.0, ha="center")
        if i < len(ROWS) - 1:
            fig.patches.append(FancyArrow(lx + lw / 2 / FIG_W, 1 - (y + rh + 0.005) / H,
                                          0, -(gap - 0.012) / H,
                                          transform=fig.transFigure, width=0.0012,
                                          head_width=0.012, head_length=0.010,
                                          length_includes_head=True,
                                          facecolor="#888780", edgecolor="none"))
    yb = top + len(ROWS) * (rh + gap) + 0.06
    T(0.10, yb, "数据流自上而下；vs_engine_fsm 逐候选通道调度，两个 FIR / 两个 DFT 为分时复用",
      size=7.4, color="#555555", cjk=True)
    fig.savefig(os.path.join(OUT, "00_overview.png"), dpi=DPI, facecolor="white")
    plt.close(fig)


# ---------------------------------------------------------------------------
# 连接表
# ---------------------------------------------------------------------------
CATS = [
    ("1. AXI-Stream 数据流（PS / DMA -> 相位链）", "axis"),
    ("2. 普通数据流 data / valid / ready（滤波 -> 谱）", "stream"),
    ("3. 窗口存储器读端口（600x80 滤波器输入）", "winram"),
    ("4. 引擎控制握手（start / done / 选择信号）", "ctrl"),
    ("5. 谱累加与峰值搜索", "spec"),
    ("6. 空间选择与机器人协同", "spatial"),
    ("7. 结果寄存器输出（-> PS）", "result"),
    ("8. 常量（频带 / 频率网格 / 默认值）", "const"),
    ("9. 时钟与复位", "clk"),
    ("10. AXI 总线（PS 侧寄存器通路）", "axi"),
]


def categorize(a, pa, b, pb):
    s = "%s/%s %s/%s" % (a, pa, b, pb)
    if a in ("axi_dma_0",) or b in ("axi_dma_0", "radar_frame_if_0"):
        return "axis" if "MM2S" in s or "s_axis" in s or "m_axis" in s else "axi"
    if a.startswith("const_") or b.startswith("const_"):
        return "const"
    if "integrate_detrend_0/rd_" in s or "integrate_detrend_0/mem_" in s or \
       "fir_card_0/busy" in s:
        return "winram"
    if a.startswith(("processing_system7_0", "rst_ps7", "axi_smc", "axi_pc",
                     "axi_gpio_ctrl")) or b.startswith(("processing_system7_0", "rst_ps7",
                                                        "axi_smc", "axi_pc")):
        return "clk" if ("FCLK" in s or "ACLK" in s or "aclk" in s or "aresetn" in s
                         or "reset" in s) else "axi"
    if a in ("fir_resp_0", "fir_card_0", "null_model_cancel_0") and \
            b in ("goertzel_resp_0", "goertzel_vr_0", "null_model_cancel_0"):
        return "stream"
    if "spectrum_accum_0" in s or "peak_argmax_0" in s:
        return "spec"
    if "vs_engine_0" in s:
        return "ctrl"
    if a in ("bin_selector_0", "robot_motion_if_0") or b in ("bin_selector_0",
                                                              "robot_motion_if_0"):
        return "spatial"
    if b == "result_out_0":
        return "result"
    return "ctrl"


def main():
    mods = parse_modules()
    cell2mod, nets, intfs, loops = parse_tcl()
    global cell_mod
    cell_mod = cell2mod

    # 建立 pin -> peers
    pin_peers = {}
    for a, pa, b, pb in nets:
        pin_peers.setdefault((a, pa), []).append("%s/%s" % (b, pb))
        pin_peers.setdefault((b, pb), []).append("%s/%s" % (a, pa))
    for a, pa, b, pb in intfs:
        pin_peers.setdefault((a, pa), []).append("%s/%s" % (b, pb))
        pin_peers.setdefault((b, pb), []).append("%s/%s" % (a, pa))
    for kind, src, pin in loops:
        for c in cell2mod:
            if (kind == "rtl_clk") == (pin == "aclk"):
                pin_peers.setdefault((c, pin), []).append(src)
    # 常量 + 时钟批量
    for c in sorted(cell2mod):
        for pin in ("aclk", "aresetn"):
            p = pin_peers.get((c, pin))
            if p and len(p) == 1 and p[0] == "processing_system7_0/FCLK_CLK0":
                pin_peers[(c, pin)] = ["processing_system7_0/FCLK_CLK0 (100MHz)"]
            if p and len(p) == 1 and p[0] == "rst_ps7_100M/peripheral_aresetn":
                pin_peers[(c, pin)] = ["rst_ps7_100M/peripheral_aresetn"]

    def peers_of(cell, pname):
        """先按端口名查；若该端口属于某个接口（s_axis_/m_axis_/s_axi_），退回到接口名查。"""
        p = pin_peers.get((cell, pname), [])
        if p:
            return p
        m = re.match(r"^(s_axis|m_axis|s_axi|m_axi)_", pname)
        if m:
            return pin_peers.get((cell, m.group(1)), [])
        return []

    drawn = 0
    for cell in sorted(cell2mod):
        mod = cell2mod[cell]
        if mod not in mods:
            continue
        ports = mods[mod]["ports"]
        in_rows, out_rows, seen = [], [], set()
        for pname in sorted(ports):
            d, w = ports[pname]
            if d == "input":
                peers = peers_of(cell, pname)
                if pname in ("aclk", "aresetn") or peers:
                    in_rows.append((pname, w, " , ".join(peers) if peers else "(unconnected)"))
                    seen.add(pname)
        for pname in sorted(ports):
            d, w = ports[pname]
            if d == "output":
                peers = peers_of(cell, pname)
                out_rows.append((pname, w, " , ".join(peers) if peers else "(unused)"))
        modinfo = dict(mods[mod]); modinfo["mod"] = mod
        draw_module(cell, modinfo, in_rows, out_rows, mods)
        drawn += 1

    draw_overview()

    # ---- 连接表 ----
    buckets = {tag: [] for _, tag in CATS}
    all_pairs = list(nets) + [("__intf__",) + tuple(x) for x in intfs]
    for item in all_pairs:
        if item[0] == "__intf__":
            _, a, pa, b, pb = item
        else:
            a, pa, b, pb = item
        cat = categorize(a, pa, b, pb)
        if cat not in buckets:
            cat = "ctrl"
        buckets[cat].append((a, pa, b, pb))

    lines = []
    total = 0
    for title, tag in CATS:
        rows = buckets[tag]
        if not rows:
            continue
        lines.append("### %s\n" % title)
        lines.append("| 源 | 源端口 | 目标 | 目标端口 |")
        lines.append("|---|---|---|---|")
        for a, pa, b, pb in sorted(rows):
            lines.append("| `%s` | `%s` | `%s` | `%s` |" % (a, pa, b, pb))
        lines.append("")
        total += len(rows)
    io.open(os.path.join(OUT, "nets.md"), "w", encoding="utf-8").write("\n".join(lines))

    print("生成 %d 张模块图 + 1 张总览图 + 连接表（%d 条连线）" % (drawn, total))
    print("输出目录:", OUT)


if __name__ == "__main__":
    main()
