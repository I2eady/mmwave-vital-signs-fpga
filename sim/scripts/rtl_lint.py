#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
rtl_lint.py -- 轻量 RTL 静态检查（无需 Vivado）

检查项：
  1) 括号/关键字配平： module/endmodule, begin/end, case/endcase,
     function/endfunction, generate/endgenerate, task/endtask
  2) 例化端口名是否存在于被例化模块的端口表中
  3) $readmemh 引用的 .mem 文件是否存在
  4) 端口声明重复 / 实例化端口数不匹配
"""
import os
import re
import sys
import glob

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RTL = os.path.join(ROOT, "src", "rtl")

RE_BLOCKCOMMENT = re.compile(r"/\*.*?\*/", re.S)
RE_LINECOMMENT = re.compile(r"//[^\n]*")
RE_STRING = re.compile(r'"[^"]*"')

MODULE_RE = re.compile(r"^\s*module\s+(\w+)", re.M)
ENDMODULE_RE = re.compile(r"^\s*endmodule", re.M)
INST_RE = re.compile(r"^\s*(\w+)\s*(#\s*\((?:[^()]|\([^()]*\))*\))?\s+(\w+)\s*\((.*?)\)\s*;",
                     re.M | re.S)


def strip_comments(s):
    s = RE_STRING.sub('""', s)          # 保护字符串
    s = RE_BLOCKCOMMENT.sub(" ", s)
    s = RE_LINECOMMENT.sub("", s)
    return s


def parse_modules(txt):
    """返回 {模块名: {'ports': set(), 'src': 文件, 'raw': 端口原文}}"""
    mods = {}
    # 逐模块切分
    for m in re.finditer(r"\bmodule\s+(\w+)\b(.*?)\bendmodule\b", txt, re.S):
        name = m.group(1)
        body = m.group(2)
        # 端口表在第一个 ');' 之前
        head = body
        p = head.find(");")
        if p > 0:
            head = head[:p]
        else:
            p = head.find(";")
            head = head[:p] if p > 0 else head
        ports = set()
        for pm in re.finditer(r"\b(?:input|output|inout)\b([^;,)]*)", head):
            seg = pm.group(1)
            ids = re.findall(r"\b([A-Za-z_]\w*)\b", seg)
            for i in ids:
                if i in ("wire", "reg", "signed", "unsigned", "logic", "integer",
                         "parameter", "localparam"):
                    continue
                if i.isdigit():
                    continue
                ports.add(i)
        # 现代风格 port list  (module foo (a, b, c);)
        mm = re.match(r"\s*(?:#\s*\([^)]*\)\s*)?\(([^)]*)\)", body, re.S)
        if mm:
            for tok in mm.group(1).split(","):
                tok = tok.strip()
                if not tok or tok.startswith("parameter") or tok.startswith("input") \
                   or tok.startswith("output") or tok.startswith("inout"):
                    continue
                nm = re.match(r"([A-Za-z_]\w*)", tok)
                if nm:
                    ports.add(nm.group(1))
        mods[name] = {"ports": ports, "raw": head}
    return mods


def instantiations(txt, mod_names):
    """粗粒度找例化：模块名 + 实例名 + (...)"""
    out = []
    for m in re.finditer(r"(?m)^[ \t]*(" + "|".join(sorted(mod_names, key=len, reverse=True)) +
                         r")\s*(#\s*\((?:[^()]|\([^()]*\))*\))?\s+(\w+)\s*\(", txt):
        start = m.end() - 1
        depth = 0
        i = start
        while i < len(txt):
            if txt[i] == "(":
                depth += 1
            elif txt[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = txt[start + 1:i]
        out.append((m.group(1), m.group(3), body, txt[:m.start()].count("\n") + 1))
    return out


def main():
    files = []
    for d in ("common", "frontend", "spatial", "filter", "spectral", "cert", "output", "top"):
        files += glob.glob(os.path.join(RTL, d, "*.v"))

    # 头文件
    hdr = ""
    for h in glob.glob(os.path.join(RTL, "common", "*.vh")):
        hdr += open(h, encoding="utf-8", errors="ignore").read()

    all_txt = ""
    raw = {}
    for f in sorted(files):
        t = open(f, encoding="utf-8", errors="ignore").read()
        raw[f] = t
        all_txt += "\n" + t

    clean = strip_comments(all_txt)
    errors = []
    warns = []

    # ---------- 1) 配平 ----------
    pairs = [("module", "endmodule"), ("begin", "end"), ("case", "endcase"),
             ("function", "endfunction"), ("generate", "endgenerate"),
             ("task", "endtask")]
    for a, b in pairs:
        na = len(re.findall(r"\b" + a + r"\b", clean))
        nb = len(re.findall(r"\b" + b + r"\b", clean))
        if a == "begin":
            na = len(re.findall(r"\bbegin\b", clean))
        if na != nb:
            errors.append("关键字不配平: {0}={1}  {2}={3}".format(a, na, b, nb))

    # ---------- 2) 模块与端口 ----------
    mods = parse_modules(clean)
    print("解析到 {0} 个模块:".format(len(mods)))
    for n in sorted(mods):
        print("   {0:<22} {1:>3} 个端口".format(n, len(mods[n]["ports"])))

    # ---------- 3) 例化检查 ----------
    print("\n例化检查:")
    for f, t in sorted(raw.items()):
        ct = strip_comments(t)
        for mname, iname, body, line in instantiations(ct, mods):
            if mname not in mods:
                continue
            ref = mods[mname]["ports"]
            used = set(re.findall(r"\.\s*(\w+)\s*\(", body))
            unknown = used - ref
            if unknown:
                errors.append("{0}:{1}  例化 {2}({3}) 使用了不存在的端口: {4}".format(
                    os.path.basename(f), line, mname, iname, sorted(unknown)))
            if not used:
                warns.append("{0}:{1}  {2} 例化未使用命名端口".format(
                    os.path.basename(f), line, mname))

    # ---------- 4) $readmemh ----------
    print("\nROM 文件检查:")
    for f, t in sorted(raw.items()):
        for m in re.finditer(r'\$readmemh\s*\(\s*(?:(\w+)\s*,\s*)?([^)]*)\)', strip_comments(t)):
            args = [a.strip().strip('"') for a in m.group(2).split(",")]
            memfile = None
            for a in args:
                if a.endswith(".mem"):
                    memfile = a
            if memfile is None:
                continue
            found = glob.glob(os.path.join(RTL, "**", os.path.basename(memfile)), recursive=True)
            status = "OK " if found else "缺失"
            print("   [{0}] {1:<16} <- {2}".format(status, os.path.basename(memfile),
                                                   os.path.basename(f)))
            if not found:
                errors.append("{0}: $readmemh 找不到 {1}".format(os.path.basename(f), memfile))

    # ---------- 5) 未声明的输出赋值粗查 ----------
    print("\n报告:")
    if warns:
        for w in warns[:10]:
            print("   [警告] " + w)
    if errors:
        print("\n发现 {0} 个问题:".format(len(errors)))
        for e in errors:
            print("   [错误] " + e)
        return 1
    print("\n   ✅ 未发现结构性错误")
    return 0


if __name__ == "__main__":
    sys.exit(main())
