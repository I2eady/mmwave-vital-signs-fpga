#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
md_to_docx.py -- 把项目里的 Markdown 报告转成可直接并入项目书的 .docx

只支持本项目实际用到的 Markdown 子集，够用且不引入 pandoc 依赖：
  标题 #/##/###、段落、**粗体**、`行内代码`、围栏代码块、
  管道表格、引用块 >、无序/有序列表、分隔线 ---

用法:
  python report/scripts/md_to_docx.py report/llm_collaboration.md report/collaboration_and_skill.docx
  python report/scripts/md_to_docx.py <in.md> <out.docx> --title "文档标题"
"""
import argparse
import os
import re
import sys

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor, Cm

CJK_FONT = "微软雅黑"
CJK_BODY = "宋体"
MONO_FONT = "Consolas"
ACCENT = RGBColor(0x1F, 0x4E, 0x79)


# ---------------------------------------------------------------- 低层工具
def set_run_font(run, name, size=None, bold=None, color=None, mono=False):
    run.font.name = name
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:ascii"), name)
    rfonts.set(qn("w:hAnsi"), name)
    rfonts.set(qn("w:eastAsia"), CJK_BODY if not mono else name)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if color is not None:
        run.font.color.rgb = color


def shade(el, hex_fill):
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), hex_fill)
    el.append(shd)


def para_shade(p, hex_fill):
    shade(p._p.get_or_add_pPr(), hex_fill)


def para_left_border(p, color="BFBFBF", size=18):
    pPr = p._p.get_or_add_pPr()
    borders = OxmlElement("w:pBdr")
    left = OxmlElement("w:left")
    left.set(qn("w:val"), "single")
    left.set(qn("w:sz"), str(size))
    left.set(qn("w:space"), "8")
    left.set(qn("w:color"), color)
    borders.append(left)
    pPr.append(borders)


# ---------------------------------------------------------------- 行内解析
INLINE = re.compile(r"(\*\*.+?\*\*|`[^`]+`|\[[^\]]+\]\([^)]*\))")


def strip_links(text):
    """[文字](路径) -> 文字（路径）；http 链接保留 URL 便于点击查看"""
    def _f(m):
        label, url = m.group(1), m.group(2)
        if url.startswith("http"):
            return "%s（%s）" % (label, url)
        return label if label.replace("`", "").endswith(url.split("/")[-1]) else "%s（%s）" % (label, url)
    return re.sub(r"\[([^\]]+)\]\(([^)]*)\)", _f, text)


def add_inline(par, text, size=10.5, base_bold=False, color=None):
    """把 **粗体**、`代码`、[链接](url) 解析成 run"""
    text = strip_links(text)
    for seg in INLINE.split(text):
        if not seg:
            continue
        if seg.startswith("**") and seg.endswith("**") and len(seg) > 4:
            r = par.add_run(seg[2:-2])
            set_run_font(r, CJK_BODY, size, bold=True, color=color)
        elif seg.startswith("`") and seg.endswith("`") and len(seg) > 2:
            r = par.add_run(seg[1:-1])
            set_run_font(r, MONO_FONT, size - 1, bold=base_bold, color=RGBColor(0xA3, 0x1A, 0x1A), mono=True)
        else:
            r = par.add_run(seg)
            set_run_font(r, CJK_BODY, size, bold=base_bold, color=color)


# ---------------------------------------------------------------- 块级渲染
def add_table(doc, rows):
    header = [c.strip() for c in rows[0].strip().strip("|").split("|")]
    body = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows[2:]]
    ncol = len(header)
    t = doc.add_table(rows=1, cols=ncol)
    t.style = "Table Grid"
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = True

    hdr = t.rows[0].cells
    for i, h in enumerate(header):
        cell = hdr[i]
        cell.text = ""
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        add_inline(p, h, size=9)
        for r in p.runs:
            r.bold = True
        shade(cell._tc.get_or_add_tcPr(), "DCE6F1")

    for row in body:
        cells = t.add_row().cells
        for i in range(ncol):
            txt = row[i] if i < len(row) else ""
            p = cells[i].paragraphs[0]
            add_inline(p, txt, size=9)

    doc.add_paragraph()
    return t


def add_code(doc, lines):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.4)
    p.paragraph_format.space_before = Pt(3)
    p.paragraph_format.space_after = Pt(6)
    para_shade(p, "F4F4F4")
    for i, ln in enumerate(lines):
        if i:
            p.add_run().add_break()
        r = p.add_run(ln if ln else " ")
        set_run_font(r, MONO_FONT, 8.5, mono=True)


def render(doc, md_lines, title):
    # 文档标题
    tp = doc.add_paragraph()
    tp.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = tp.add_run(title)
    set_run_font(r, CJK_FONT, 18, bold=True, color=ACCENT)
    tp.paragraph_format.space_after = Pt(14)

    i = 0
    n = len(md_lines)
    while i < n:
        line = md_lines[i]
        stripped = line.strip()

        # 围栏代码块
        if stripped.startswith("```"):
            i += 1
            buf = []
            while i < n and not md_lines[i].strip().startswith("```"):
                buf.append(md_lines[i])
                i += 1
            i += 1
            add_code(doc, buf)
            continue

        # 表格
        if stripped.startswith("|") and i + 1 < n and re.match(r"^\|[\s:\-|]+\|$", md_lines[i + 1].strip()):
            buf = []
            while i < n and md_lines[i].strip().startswith("|"):
                buf.append(md_lines[i])
                i += 1
            add_table(doc, buf)
            continue

        # 标题
        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            level = len(m.group(1))
            txt = m.group(2).strip()
            if level == 1:
                # 文件标题：用文档标题已表达，这里作为一级小节
                p = doc.add_paragraph()
                add_inline(p, txt, size=15, base_bold=True, color=ACCENT)
                p.paragraph_format.space_before = Pt(10)
                p.paragraph_format.space_after = Pt(6)
            elif level == 2:
                p = doc.add_paragraph()
                add_inline(p, txt, size=13, base_bold=True, color=ACCENT)
                p.paragraph_format.space_before = Pt(14)
                p.paragraph_format.space_after = Pt(6)
            else:
                p = doc.add_paragraph()
                add_inline(p, txt, size=11.5, base_bold=True)
                p.paragraph_format.space_before = Pt(9)
                p.paragraph_format.space_after = Pt(4)
            # 标题下不设大纲级别时，导航窗格里会缺，这里补上
            i += 1
            continue

        # 分隔线
        if re.match(r"^-{3,}$", stripped):
            p = doc.add_paragraph()
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            pPr = p._p.get_or_add_pPr()
            pbdr = OxmlElement("w:pBdr")
            bottom = OxmlElement("w:bottom")
            bottom.set(qn("w:val"), "single")
            bottom.set(qn("w:sz"), "6")
            bottom.set(qn("w:space"), "1")
            bottom.set(qn("w:color"), "D0D0D0")
            pbdr.append(bottom)
            pPr.append(pbdr)
            i += 1
            continue

        # 引用块（连续多行合并为一个段落集）
        if stripped.startswith(">"):
            while i < n and md_lines[i].strip().startswith(">"):
                body = md_lines[i].strip().lstrip(">").strip()
                if body:
                    p = doc.add_paragraph()
                    p.paragraph_format.left_indent = Cm(0.6)
                    p.paragraph_format.space_after = Pt(3)
                    para_left_border(p)
                    add_inline(p, body, size=10, color=RGBColor(0x44, 0x44, 0x44))
                i += 1
            continue

        # 列表
        m = re.match(r"^([-*]|\d+\.)\s+(.*)$", stripped)
        if m:
            body = m.group(2)
            p = doc.add_paragraph(style="List Bullet" if not m.group(1)[0].isdigit() else "List Number")
            p.paragraph_format.space_after = Pt(2)
            add_inline(p, body, size=10.5)
            i += 1
            continue

        # 空行
        if not stripped:
            i += 1
            continue

        # 普通段落（合并连续非空行）
        buf = [stripped]
        i += 1
        while i < n and md_lines[i].strip() and not re.match(
                r"^(#{1,4}\s|\||```|>|-{3,}$|[-*]\s|\d+\.\s)", md_lines[i].strip()):
            buf.append(md_lines[i].strip())
            i += 1
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(5)
        p.paragraph_format.line_spacing = 1.25
        add_inline(p, "".join(buf), size=10.5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--title", default=None)
    a = ap.parse_args()

    md = open(a.src, encoding="utf-8").read().split("\n")
    title = a.title
    if title is None:
        for ln in md:
            if ln.startswith("# "):
                title = ln[2:].strip()
                break
        else:
            title = os.path.splitext(os.path.basename(a.src))[0]

    doc = Document()
    sec = doc.sections[0]
    sec.left_margin = Cm(2.2)
    sec.right_margin = Cm(2.2)
    sec.top_margin = Cm(2.2)
    sec.bottom_margin = Cm(2.2)

    style = doc.styles["Normal"]
    style.font.name = CJK_BODY
    style.font.size = Pt(10.5)
    style.element.rPr.rFonts.set(qn("w:eastAsia"), CJK_BODY)

    render(doc, md, title)

    out = os.path.abspath(a.dst)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    doc.save(out)
    print("wrote %s  (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))


if __name__ == "__main__":
    main()
