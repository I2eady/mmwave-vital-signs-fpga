#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_bd_nets.py -- 在不开 Vivado 的前提下预演 Block Design 的连线检查

它能查出 Vivado 会在 `validate_bd_design` / `generate_target` 里报的三类问题：

  1. 连到了不存在的引脚          -> ERROR   [BD 5-3] / create_bd_net failed
  2. 位宽不匹配                  -> CRITICAL WARNING [BD 41-1228]
  3. RTL 模块引用的输入脚没接     -> CRITICAL WARNING [BD 41-759]（静默 tie 成 0）

做法：
  * 解析 src/rtl/ 下所有 module 的端口名与位宽（参数用默认值代入）
  * 从 build/tcl/build_bd.tcl 的 `mkmod <module> <cell>` 行建立 单元名 -> 模块名 映射
  * 逐条检查 `vs_net A/pin B/pin`：引脚存在性与位宽一致性
  * 最后列出每个 RTL 单元"从未出现在任何 vs_net 左侧供出、也从未作为接收端"的输入脚

用法：
  python scripts/check_bd_nets.py
"""

import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))   # sim/scripts/ -> repo root


# ---------------------------------------------------------------------------
# 解析 RTL 模块
# ---------------------------------------------------------------------------
def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", " ", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def parse_params(text):
    """module 参数默认值 -> dict（只收能算成整数的）"""
    params = {}
    m = re.search(r"module\s+\w+\s*#\s*\((.*?)\)\s*\(", text, re.S)
    if not m:
        return params
    body = m.group(1)
    for pm in re.finditer(r"\bparam(?:eter)?\b\s+(?:integer|int|real|signed|unsigned)?\s*"
                          r"[^=\n]*?(\w+)\s*=\s*([^,\n]+)", body):
        name, val = pm.group(1), pm.group(2).strip()
        try:
            params[name] = int(eval(val, {"__builtins__": {}}, {}))
        except Exception:
            pass
    return params


def resolve_width(rng, params):
    """'[DW-1:0]' -> 24 ；解析不了返回 None"""
    if not rng:
        return 1
    m = re.match(r"\[\s*(.*?)\s*:\s*(.*?)\s*\]$", rng.strip())
    if not m:
        return None
    env = dict(params)
    # $clog2(x) -> 需要的位宽
    def clog2(mo):
        try:
            v = int(eval(mo.group(1), {"__builtins__": {}}, env))
            return str(max(1, (v - 1).bit_length()))
        except Exception:
            return "0"
    out = []
    for e in (m.group(1), m.group(2)):
        e = re.sub(r"\$clog2\s*\(([^()]*)\)", clog2, e)
        e = re.sub(r"\$signed|\(\)", "", e)
        for k, v in env.items():
            e = re.sub(r"\b%s\b" % re.escape(k), str(v), e)
        if re.search(r"[A-Za-z_]", e):
            return None
        try:
            out.append(int(eval(e, {"__builtins__": {}}, {})))
        except Exception:
            return None
    hi, lo = out
    return abs(hi - lo) + 1


def parse_modules():
    mods = {}
    for dirpath, _, files in os.walk(os.path.join(ROOT, "src", "rtl")):
        for fn in sorted(files):
            if not fn.endswith(".v"):
                continue
            path = os.path.join(dirpath, fn)
            text = strip_comments(io.open(path, encoding="utf-8", errors="ignore").read())
            for mm in re.finditer(r"\bmodule\s+(\w+)\b(.*?)\bendmodule\b", text, re.S):
                name, body = mm.group(1), mm.group(2)
                params = parse_params("module %s %s" % (name, body))
                ports = {}
                # ANSI 端口列表
                pm = re.match(r"\s*(#\s*\((?:[^()]|\([^()]*\))*\))?\s*\((.*?)\)\s*;", body, re.S)
                if not pm:
                    continue
                for am in re.finditer(r"\b(input|output|inout)\b\s*(?:wire|reg|logic)?\s*"
                                      r"(?:signed|unsigned)?\s*(\[[^\]]*\])?\s*([^,;)]+)",
                                      pm.group(2)):
                    direction, rng, names = am.groups()
                    w = resolve_width(rng, params)
                    for pn in names.split(","):
                        pn = pn.strip()
                        if pn:
                            ports[pn] = (direction, w)
                mods[name] = {"file": os.path.relpath(path, ROOT), "ports": ports}
    return mods


# ---------------------------------------------------------------------------
# 解析 build_bd.tcl
# ---------------------------------------------------------------------------
def parse_tcl():
    txt = io.open(os.path.join(ROOT, "build", "tcl", "build_bd.tcl"), encoding="utf-8").read()
    cell2mod = {}
    for m in re.finditer(r"^mkmod\s+(\S+)\s+(\S+)\s*$", txt, re.M):
        cell2mod[m.group(2)] = m.group(1)
    nets = []
    for m in re.finditer(r"^vs_net\s+(\S+)\s+(\S+)\s*(?:#.*)?$", txt, re.M):
        a = m.group(1).split("/")
        b = m.group(2).split("/")
        if len(a) == 2 and len(b) == 2:
            nets.append((a[0], a[1], b[0], b[1]))
    return cell2mod, nets


# ---------------------------------------------------------------------------
# 检查
# ---------------------------------------------------------------------------
def main():
    mods = parse_modules()
    cell2mod, nets = parse_tcl()
    problems = 0

    print("RTL 模块: %d 个   BD 单元(mkmod): %d 个   vs_net 连线: %d 条"
          % (len(mods), len(cell2mod), len(nets)))
    print("")

    # ---- 1) 引脚存在性 + 位宽 ----
    print("=== 1) 引脚存在性 / 位宽一致性 ===")
    IFACE = ("s_axi", "s_axis", "m_axis", "m_axi", "irq")
    used = {}          # (cell, port) -> True  （被连线用到过）
    for ca, pa, cb, pb in nets:
        for cell, port in ((ca, pa), (cb, pb)):
            mod = cell2mod.get(cell)
            if mod is None:
                continue                     # Xilinx IP / PS7，端口表未知，跳过
            if mod not in mods:
                print("  !! 单元 %s 引用了不存在的模块 %s" % (cell, mod))
                problems += 1
                continue
            ports = mods[mod]["ports"]
            used[(cell, port)] = True
            if port in IFACE or port.startswith(("s_axis", "m_axis", "s_axi")):
                continue                     # 接口脚，不是普通 pin
            if port not in ports:
                print("  !! %s/%s 不存在（%s 的端口表里没有）" % (cell, port, mod))
                problems += 1
        # 宽度
        ma, mb = cell2mod.get(ca), cell2mod.get(cb)
        if ma in mods and mb in mods:
            wa = mods[ma]["ports"].get(pa, (None, None))[1]
            wb = mods[mb]["ports"].get(pb, (None, None))[1]
            if wa and wb and wa != wb:
                print("  !! 位宽不匹配 %s/%s(%s) -> %s/%s(%s)"
                      % (ca, pa, wa, cb, pb, wb))
                problems += 1
    if problems == 0:
        print("  OK  所有 RTL 引脚都存在且位宽一致")
    print("")

    # ---- 2) 悬空输入（Vivado BD 41-759 会静默 tie 0）----
    print("=== 2) 悬空的 RTL 输入脚（Vivado 会 tie 成 0 并报 BD 41-759）===")
    SKIP = ("aclk", "aresetn", "s_axis", "m_axis", "s_axi", "irq")
    dangling = 0
    for cell, mod in sorted(cell2mod.items()):
        if mod not in mods:
            continue
        for pname, (d, w) in sorted(mods[mod]["ports"].items()):
            if d != "input":
                continue
            if pname in SKIP or pname.startswith(("s_axis", "m_axis", "s_axi")):
                continue
            if (cell, pname) not in used:
                print("  ?? %s/%s" % (cell, pname))
                dangling += 1
    if dangling == 0:
        print("  OK  没有悬空输入")
    print("")

    # ---- 3) 输出脚没人用（只是提示，不是错误）----
    print("=== 3) 未被使用的 RTL 输出脚（仅提示）===")
    unused_out = 0
    for cell, mod in sorted(cell2mod.items()):
        if mod not in mods:
            continue
        for pname, (d, w) in sorted(mods[mod]["ports"].items()):
            if d != "output":
                continue
            if pname.startswith(("s_axis", "m_axis", "s_axi")):
                continue
            if (cell, pname) not in used:
                print("  -- %s/%s" % (cell, pname))
                unused_out += 1
    if unused_out == 0:
        print("  （无）")
    print("")

    print("=" * 70)
    print("  真实问题（引脚/位宽）: %d    悬空输入: %d    未用输出: %d"
          % (problems, dangling, unused_out))
    print("=" * 70)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
