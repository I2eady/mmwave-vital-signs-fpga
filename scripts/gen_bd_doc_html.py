#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_bd_doc_html.py -- 把算法模块图 + 连接关系表组装成一份 HTML，
交给 tencent-local-office-edit 的 doc_insert_html_content 插入 Word。

输出：docs/bd_images/doc.html
"""

import io, os, sys, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_bd_doc_assets as A          # 复用它的解析逻辑

ROOT = A.ROOT
IMG = os.path.join(ROOT, "docs", "bd_images").replace("\\", "/")

# 流水线顺序（3.x 小节的排列顺序）
ORDER = ["radar_frame_if_0", "dacm_phase_0", "hampel7_0", "integrate_detrend_0",
         "fir_resp_0", "fir_card_0", "goertzel_resp_0", "null_model_cancel_0",
         "goertzel_vr_0", "spectrum_accum_0", "peak_argmax_0", "bpm_map_0",
         "ratio_q15_0", "certificate_0", "bin_selector_0", "robot_motion_if_0",
         "vs_engine_0", "vs_defaults_0", "result_out_0"]

# 模块 -> Python 对应（写文档用）
PY = {
 "radar_frame_if":    "dataio.load_radar + 窗口切片",
 "dacm_phase":        "dsp.dacm_phase",
 "hampel7":           "dsp.hampel_axis",
 "integrate_detrend": "dsp.integrate_axis + detrend_axis",
 "fir_bandpass":      "dsp.bandpass_axis (butter(4)+filtfilt)",
 "goertzel_sweep":    "dsp.spectrum + _vr_sweep 频率轴",
 "null_model_cancel": "_harmonic_residual + _vr_sweep 的 QR 投影",
 "spectrum_accum":    "_fused_spectrum",
 "peak_argmax":       "np.argmax + dsp.parabolic_peak",
 "bpm_map":           "vr_grid[k_best] / resp_grid[k]",
 "ratio_q15":         "competitive_vr",
 "certificate_fsm":   "estimator._certificate",
 "bin_selector":      "estimator.candidate_bins",
 "robot_motion_if":   "vision_geometry.motion_safe",
 "vs_engine_fsm":     "VitalSignsEstimator.estimate 的控制流",
 "vs_defaults":       "（硬件侧占位，无对应）",
 "result_out":        "run.py 的 EstimateResult 输出字段",
}

CLK = ("processing_system7_0", "rst_ps7_100M")
SKIP_IN = ("aclk", "aresetn")


def short(s):
    return s.split("(")[0].strip()


def html_table(rows, headers):
    h = "<table border=1 cellspacing=0 cellpadding=4 style=\"border-collapse:collapse\">"
    h += "<tr>" + "".join("<th style=\"background:#F1EFE8\">%s</th>" % x for x in headers) + "</tr>"
    for r in rows:
        h += "<tr>" + "".join("<td>%s</td>" % x for x in r) + "</tr>"
    return h + "</table>"


def main():
    mods = A.parse_modules()
    cell2mod, nets, intfs, _ = A.parse_tcl()

    pin_peers = {}

    def add(a, pa, b, pb):
        pin_peers.setdefault((a, pa), []).append((b, pb))
        pin_peers.setdefault((b, pb), []).append((a, pa))

    for a, pa, b, pb in nets:
        add(a, pa, b, pb)
    for a, pa, b, pb in intfs:
        add(a, pa, b, pb)

    def peers_of(cell, pname):
        p = pin_peers.get((cell, pname), [])
        if p:
            return p
        m = re.match(r"^(s_axis|m_axis|s_axi|m_axi)_", pname)
        if m:
            return pin_peers.get((cell, m.group(1)), [])
        return []

    H = []
    H.append("<h1>ZYNQ7020 毫米波雷达非接触心率估计 —— Block Design 算法模块与连接关系</h1>")
    H.append("<p>器件 xc7z020clg400-2。Block Design 名称 <b>vs_bd</b>，共 <b>28 个单元</b>："
             "19 个算法模块实例（17 个模块，<code>fir_bandpass</code> 与 <code>goertzel_sweep</code> "
             "各例化两次）+ 6 个 Xilinx IP + 3 个 xlconstant。</p>")
    H.append("<p>本文中的模块图与连接表由脚本 "
             "<code>scripts/gen_bd_doc_assets.py</code> 直接从 "
             "<code>rtl/**/*.v</code> 的端口声明与 <code>tcl/build_bd.tcl</code> 的 "
             "<code>vs_net</code> / <code>vs_link</code> 连线解析生成，共 <b>129 条连线</b>，"
             "与工程完全一致，不是手绘。</p>")

    # ---------------- 一、总览 ----------------
    H.append("<h2>一、算法模块总览</h2>")
    H.append("<img src=\"%s/00_overview.png\" style=\"width:605px\">" % IMG)
    H.append("<p>数据流自上而下经过 7 级；<code>vs_engine_fsm</code> 是控制中枢，"
             "它<b>逐候选通道</b>调度整个流程，因此两个 FIR 与两个 DFT 在时间上是分时复用的，"
             "并不会同时工作。</p>")

    rows = []
    for tag, title in sorted(A.CHAIN_NAME.items()):
        cells = [c for c in ORDER if A.CHAIN.get(cell2mod.get(c, ""), "") == tag]
        if not cells:
            continue
        rows.append([title, str(len(cells)), "、".join("`%s`" % c for c in cells).replace("`", "")])
    H.append("<p><b>按链分组</b></p>")
    H.append(html_table(rows, ["链", "实例数", "实例"]))

    # ---------------- 二、数据流 ----------------
    H.append("<h2>二、数据流（8 级）</h2>")
    H.append("<pre style=\"font-family:Consolas,monospace;font-size:9pt\">"
             "PS7/DDR\n"
             "  | AXI-DMA MM2S（每帧 80 个 {Q[15:0],I[15:0]}，首字 TUSER=1）\n"
             "  v\n"
             "radar_frame_if -> dacm_phase -> hampel7 -> integrate_detrend\n"
             "                                              |  600x80x24b 窗口存储器\n"
             "               +------------------------------+------------------------------+\n"
             "               v (rd_sel=0)                                                  v (rd_sel=1)\n"
             "        fir_resp（呼吸带 0.15-0.60Hz）                        fir_card（心脏带 0.80-2.00Hz）\n"
             "               |                                                              |\n"
             "               v                                                              v\n"
             "    goertzel_resp（91 点谱）                          null_model_cancel（LMS 谐波抵消）\n"
             "               |                                                              |\n"
             "               |                                                              v\n"
             "               |                                                   goertzel_vr（201 点 VR 曲线）\n"
             "               +--------------------------+-----------------------------------+\n"
             "                                          v  （双写口）\n"
             "                              spectrum_accum（跨 (bin,RX) 非相干累加）\n"
             "                                          v\n"
             "                              peak_argmax（argmax + 抛物线插值 + 对比度）\n"
             "                        +-----------------+------------------+\n"
             "                        v                 v                  v\n"
             "                   bpm_map          ratio_q15        certificate_fsm  <-- bin_selector\n"
             "                （-> 心率/呼吸率）  （-> 竞争比）      （质量分级）      <-- robot_motion_if\n"
             "                                          |\n"
             "                                          v\n"
             "                              result_out（14x32b 寄存器 + IRQ）---> PS7 中断\n"
             "</pre>" % ())

    # ---------------- 三、逐个模块 ----------------
    H.append("<h2>三、逐个算法模块的连接关系</h2>")
    H.append("<p>每张图里：<b>蓝底行 = 输入</b>（左侧写出源端口），"
             "<b>绿底行 = 输出</b>（右侧写出目标端口），最右列为位宽。</p>")

    idx = 0
    for cell in ORDER:
        mod = cell2mod.get(cell)
        if mod is None or mod not in mods:
            continue
        idx += 1
        zh, algo = A.INFO.get(mod, ("", ""))
        ports = mods[mod]["ports"]
        H.append("<h3>3.%d %s —— %s</h3>" % (idx, cell, zh))
        H.append("<img src=\"%s/%s.png\" style=\"width:605px\">" % (IMG, cell))
        H.append("<p><b>模块</b> <code>%s</code>　<b>文件</b> <code>%s</code><br>"
                 "<b>关键算法</b> %s<br><b>对应 Python</b> <code>%s</code></p>"
                 % (mod, mods[mod]["file"], algo, PY.get(mod, "—")))

        ups, downs = [], []
        for pname, (d, w) in sorted(ports.items()):
            for (pc, pp) in peers_of(cell, pname):
                if pc in CLK or pp in SKIP_IN or pname in SKIP_IN:
                    continue
                (ups if d == "input" else downs).append(pc)
        ups = [x for x in dict.fromkeys(ups)]
        downs = [x for x in dict.fromkeys(downs)]
        H.append("<p><b>上游模块</b> %s<br><b>下游模块</b> %s</p>"
                 % ("、".join("`%s`" % x for x in ups).replace("`", "") or "（无，接 PS）",
                    "、".join("`%s`" % x for x in downs).replace("`", "") or "（无，仅状态位）"))

    # ---------------- 四、连接总表 ----------------
    H.append("<h2>四、连接关系总表</h2>")
    buckets = {tag: [] for _, tag in A.CATS}
    allp = list(nets) + list(intfs)
    for a, pa, b, pb in allp:
        cat = A.categorize(a, pa, b, pb)
        buckets.setdefault(cat if cat in buckets else "ctrl", []).append((a, pa, b, pb))
    total = 0
    for title, tag in A.CATS:
        rows = sorted(buckets[tag])
        if not rows:
            continue
        total += len(rows)
        H.append("<h3>%s（%d 条）</h3>" % (title, len(rows)))
        H.append(html_table([["<code>%s</code>" % a, "<code>%s</code>" % pa,
                              "<code>%s</code>" % b, "<code>%s</code>" % pb]
                             for a, pa, b, pb in rows],
                            ["源单元", "源端口", "目标单元", "目标端口"]))
    H.append("<p>以上合计 <b>%d 条</b>连线。</p>" % total)

    # ---------------- 五、资源 ----------------
    H.append("<h2>五、资源占用实测（Vivado 2019.1，各模块单独综合）</h2>")
    res = [("integrate_detrend", 92130, 48000, 17136, 0, 6),
           ("spectrum_accum", 25014, 0, 8491, 0, 0),
           ("null_model_cancel", 18497, 0, 1581, 0, 52),
           ("peak_argmax", 17949, 0, 8699, 0, 0),
           ("fir_card", 9231, 0, 14541, 0, 2),
           ("fir_resp", 9231, 0, 14541, 0, 2),
           ("goertzel_resp", 6781, 0, 14728, 0, 10),
           ("goertzel_vr", 6781, 0, 14728, 0, 10),
           ("hampel7", 5175, 0, 11612, 0, 1),
           ("certificate_fsm", 3025, 0, 28, 0, 6),
           ("ratio_q15", 1584, 0, 16, 0, 0),
           ("dacm_phase", 1092, 0, 2825, 0, 4),
           ("bin_selector", 854, 0, 38, 0, 1),
           ("result_out", 119, 0, 39, 0, 0),
           ("vs_engine_fsm", 63, 0, 72, 0, 0),
           ("robot_motion_if", 56, 0, 87, 0, 0),
           ("bpm_map", 24, 0, 26, 0, 0),
           ("radar_frame_if", 19, 0, 67, 0, 0),
           ("vs_defaults", 19, 0, 0, 0, 0)]
    tl = sum(r[1] for r in res); tm = sum(r[2] for r in res)
    tf = sum(r[3] for r in res); td = sum(r[5] for r in res)
    H.append(html_table([[n, str(a), str(b), str(c), "0", str(d)]
                         for n, a, b, c, e, d in res],
                        ["模块", "LUT", "其中当 RAM", "FF", "BRAM36", "DSP48"]))
    H.append(html_table([["<b>RTL 合计</b>", "<b>%d</b>" % tl, "<b>%d</b>" % tm,
                          "<b>%d</b>" % tf, "<b>0</b>", "<b>%d</b>" % td],
                         ["<b>ZYNQ7020 上限</b>", "<b>53200</b>", "<b>17400</b>",
                          "<b>106400</b>", "<b>140</b>", "<b>220</b>"],
                         ["<b>占用率</b>", "<b>%.0f%%</b>" % (tl / 53200 * 100),
                          "<b>%.0f%%</b>" % (tm / 17400 * 100),
                          "<b>%.0f%%</b>" % (tf / 106400 * 100),
                          "<b>0%%</b>", "<b>%.0f%%</b>" % (td / 220 * 100)]],
                        ["项目", "LUT", "LUT 当 RAM", "FF", "BRAM36", "DSP48"]))
    H.append("<p><b>结论</b>：算法结构本身没问题（综合全部通过），但存储器的映射方式让设计"
             "放不进 xc7z020 —— 1.15 Mbit 的窗口存储器被实现成分布式 RAM（48000 个 LUT），"
             "而 BRAM 一个都没用上。根因是 <code>integrate_detrend.v</code> 的 "
             "<code>S_APPLY</code> 状态里 <code>ap_val = mem[ap_idx]</code> 是组合读，"
             "BRAM 做不到异步读。改法见 <code>docs/BlockDesign结构说明.md</code> 第六节。</p>")

    html = "\n".join(H)
    out = os.path.join(A.OUT, "doc.html")
    io.open(out, "w", encoding="utf-8").write(html)
    print("HTML 生成: %s  (%d 字符)" % (out, len(html)))
    print("  小节: 19 个模块图 + 1 张总览 + %d 条连线表" % total)


if __name__ == "__main__":
    main()
