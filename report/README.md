# report — 设计报告与协作记录

| 文件 | 内容 | 建议阅读顺序 |
|---|---|---|
| [`design_report.md`](design_report.md) | **设计报告**：Python 10 个算法阶段逐阶段映射到 RTL、定点规格、时序与吞吐分析、近似清单 A1–A10 | ① |
| [`bd_structure.md`](bd_structure.md) | **Block Design 说明**：28 个单元逐个职责、8 级数据流、核心算法定位、逐模块资源实测、资源优化路线 | ② |
| [`bd_modules_and_nets.docx`](bd_modules_and_nets.docx) | 19 张算法模块单独图 + 总览图 + 129 条连接关系总表（Word，可直接用于提交材料） | ③ |
| [`flow_diagram.html`](flow_diagram.html) | 数据流图（浏览器打开即可，不必装 Vivado） | ③ |
| [`vivado_guide.md`](vivado_guide.md) | Vivado 流程总览：从建工程到导出 `.xsa`，以及 PS 端要做什么 | ④ |
| [`vivado_click_through.md`](vivado_click_through.md) | 逐条打勾的手动点击清单（78 步），不想用脚本时照这个点 | ⑤ |
| [`llm_collaboration.md`](llm_collaboration.md) | **大模型协作记录**：需求拆解、每轮报错的根因、修复与判据 | ⑥ |
| [`figures/`](figures/) | 模块图 PNG（19 张）+ `nets.md` 连线总表 | — |
| [`scripts/`](scripts/) | `gen_bd_doc_assets.py`（从真实端口与连线自动画图）/ `gen_bd_doc_html.py`（组装成 Word 用 HTML） | — |

## 图是怎么来的

`report/figures/` 下的图和 `nets.md` **不是手画的**，由 `scripts/gen_bd_doc_assets.py` 直接解析：

* `src/rtl/**/*.v` 的端口声明（含位宽、参数默认值）
* `build/tcl/build_bd.tcl` 的全部 `vs_net` / `vs_link` 连线（129 条）

因此改完 RTL 或连线后重跑即可刷新，不会出现"文档和图不一致"。

```bash
python report/scripts/gen_bd_doc_assets.py    # 出图 + nets.md
python report/scripts/gen_bd_doc_html.py      # 组装 report/figures/doc.html
```

## 提交材料对应关系

| 竞赛要求 | 对应文件 |
|---|---|
| 设计报告 | `design_report.md` + `bd_structure.md` |
| 大模型协作记录 | `llm_collaboration.md` |
| 设计框图 / 数据流 | `bd_modules_and_nets.docx`、`flow_diagram.html`、`figures/` |
| 完整源码与工程 | `src/`、`build/` |
