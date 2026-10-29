#!/usr/bin/env python3
"""调优报告生成器。

读取 KAT 训练目录中的 train.db + kat_run.log，生成一个自包含的静态 HTML
可视化报告（无外部依赖，离线可用），版式仿照 DevKit AI 参数调优报告：
  - 顶栏（与内容区同宽，标题 鲲鹏自动调优_{应用} + Produced by Kunpeng DevKit）
  - 页签：参数调优报告 / 任务信息
  - 调优成功横幅
  - 性能统计（调优轮数 / 最优轮数 / 最优性能 / 提升幅度）
  - 应用 | 算法 | 指标 信息条
  - 收敛曲线（每轮性能 + 累计最优 + baseline 参考线，支持数据点悬浮提示）
  - 参数重要性（横向条形图表格，完整显示无横向滚动）
  - TOP 10 性能表（前三名金银铜奖牌）
  - 任务信息页含全部轮次汇总表（滚动显示约 20 行，点击行显示该轮参数分组 Tab 详情并高亮）
  - AI 分析区（脚本根据训练数据自动生成 markdown 分析并渲染）

用法:
  python3 report.py <训练目录>
  python3 report.py <训练目录> -o 自定义输出路径
  python3 report.py <训练目录> --ai-note 自定义分析.md

输出: 训练目录下的 report_{YYYYMMDD_HHMMSS}.html（时间戳绑定训练创建时间，或 -o 指定路径）。
"""

import argparse
import html
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

# ── 调色板（暗色 DevKit 风格）──────────────────────────────────────
PALETTE = {
    "series": "#4d8dff",     # 每轮性能（蓝）
    "best": "#8ab6ff",       # 累计最优（浅蓝虚线）
    "baseline": "#e0854f",   # baseline 参考线（橙）
    "positive": "#3fb950",   # 提升（绿）
    "negative": "#f85149",   # 下降（红）
    "bar": "#3d7eff",        # 重要性条形（蓝）
    "accent": "#4a7dff",     # 页签高亮 / 链接
}


# ── 数据加载 ────────────────────────────────────────────────────────

def load_train_db(db_path):
    """从 train.db 读取训练数据。"""
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    tune = None
    try:
        cur.execute("SELECT * FROM tune_info")
        row = cur.fetchone()
        tune = dict(row) if row else None
    except Exception:
        pass

    rounds = []
    try:
        cur.execute(
            "SELECT round_num, performance, params FROM round_info ORDER BY round_num"
        )
        for row in cur.fetchall():
            params = {}
            param_groups = {}
            if row["params"]:
                try:
                    raw = json.loads(row["params"])
                    # 键格式 "{组索引}_{参数名}"，如 "0_maxmemory"/"1_vm.swappiness"
                    for k, v in raw.items():
                        if "_" in k:
                            gidx, pk = k.split("_", 1)
                        else:
                            gidx, pk = "0", k
                        try:
                            g = int(gidx)
                        except ValueError:
                            g = 0
                        params[pk] = v
                        param_groups[pk] = g
                except Exception:
                    params = {}
                    param_groups = {}
            rounds.append(
                {
                    "round": int(row["round_num"]),
                    "performance": float(row["performance"]),
                    "params": params,
                    "param_groups": param_groups,
                }
            )
    except Exception:
        pass

    sp = {}
    try:
        cur.execute("SELECT round_type, performance FROM sp_round_info")
        for row in cur.fetchall():
            sp[row["round_type"]] = row["performance"]
    except Exception:
        pass

    conn.close()
    return {"tune": tune, "rounds": rounds, "sp": sp}


def parse_importance(log_path):
    """从 kat_run.log 解析参数重要性。

    KAT 的 "show importance" 表格式（param 名可能在显示时被截断到 ~16 字符）：
        <group> | <param> | <..> | <..> | <..> | <xx.xx>% | <range>
    实际日志中重要性 % 位于第 6 列（index 5）。为兼容不同版本，扫描所有列，
    找到匹配 "[0-9.]+%" 的列作为重要性，取第 2 列为参数名。

    参数名可能被截断且跨多行显示（续行是名字后缀），
    这里把紧邻续行后缀拼接到名字上，避免截断前缀去重时丢失。
    """
    importance = []
    if os.path.exists(log_path):
        with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
        i = 0
        while i < len(lines):
            fields = [x.strip() for x in lines[i].split("|")]
            if len(fields) < 3:
                i += 1
                continue
            pct = None
            for fld in fields[2:]:
                if re.fullmatch(r"[0-9.]+%", fld):
                    pct = fld
                    break
            if pct is None:
                i += 1
                continue
            param = fields[1].strip()
            # 续行拼接：下一行可能是本参数名的后缀（无 %，且第 2 列为短后缀）
            if i + 1 < len(lines):
                nf = [x.strip() for x in lines[i + 1].split("|")]
                nf_has_pct = any(re.fullmatch(r"[0-9.]+%", x) for x in nf[2:])
                if len(nf) >= 2 and nf[1].strip() and not nf_has_pct:
                    suffix = nf[1].strip()
                    if suffix and not re.fullmatch(r"[-=]+", suffix):
                        param = param.rstrip("-") + suffix
            importance.append({"param": param, "importance": float(pct.rstrip("%"))})
            i += 1

    # 去重（按拼接后的名字；不同参数因截断名不同可区分）
    seen, result = set(), []
    for item in importance:
        if item["param"] not in seen:
            seen.add(item["param"])
            result.append(item)
    return result


def _norm(name):
    """去掉所有非字母数字字符，用于宽容匹配截断/拼接后的参数名。"""
    return re.sub(r"[^a-zA-Z0-9]", "", name)


def resolve_param_names(importance, rounds):
    """将日志中截断/拼接的参数名匹配到完整参数名（来自 round_info.params）。"""
    full_names = set()
    for r in rounds:
        full_names.update(r["params"].keys())

    # 规范化映射：如 "hash-max-ziplistentries" → "hash-max-ziplist-entries"
    norm_map = {}
    for full in full_names:
        norm_map.setdefault(_norm(full), full)

    def resolve(name):
        if name in full_names:
            return name
        n = _norm(name)
        if n in norm_map:
            return norm_map[n]
        # 前缀匹配兜底
        for full in full_names:
            if full.startswith(name):
                return full
        return name

    return [{"param": resolve(i["param"]), "importance": i["importance"]} for i in importance]


# ── 数据汇总 ────────────────────────────────────────────────────────

def summarize(data, importance):
    """计算报告所需的汇总指标。"""
    tune = data["tune"] or {}
    rounds = data["rounds"]
    sp = data["sp"]

    baseline = (
        sp.get("baseline")
        or tune.get("baseline_performance")
    )
    if baseline is None and rounds:
        baseline = min(r["performance"] for r in rounds)

    best = max(rounds, key=lambda r: r["performance"]) if rounds else None
    best_round = best["round"] if best else None
    best_perf = best["performance"] if best else None

    improvement = None
    if baseline and best_perf is not None:
        improvement = (best_perf - baseline) / baseline * 100.0

    app = tune.get("parameter_groups") or "N/A"
    direction = tune.get("tune_direction") or (sp and "maximize")
    perf_info = tune.get("performance_info") or "performance"
    algorithm = tune.get("algorithm") or "HPO"
    total_rounds = tune.get("total_rounds") or len(rounds)
    random_ratio = tune.get("random_initial_ratio")
    run_times = tune.get("run_times")
    fail_times = tune.get("failure_times")
    created_at = tune.get("created_at")

    return {
        "app": app,
        "perf_info": perf_info,
        "direction": direction,
        "algorithm": algorithm,
        "total_rounds": total_rounds,
        "random_ratio": random_ratio,
        "run_times": run_times,
        "fail_times": fail_times,
        "created_at": created_at,
        "baseline": baseline,
        "best_round": best_round,
        "best_perf": best_perf,
        "improvement": improvement,
        "rounds": rounds,
        "importance": importance,
    }


# ── SVG 图表 ────────────────────────────────────────────────────────

def esc(s):
    """HTML 转义。"""
    return html.escape(str(s) if s is not None else "")


def fmt_num(n):
    """千分位格式化数字。"""
    if n is None:
        return "N/A"
    return f"{n:,.0f}"


def svg_convergence(rounds, baseline, best_perf):
    """生成收敛曲线 SVG（每轮性能 + 累计最优 + baseline 参考线 + 悬浮提示）。

    纵轴范围：y_min = min(所有值) * 0.92，y_max = max(所有值) * 1.05。
    """
    if not rounds:
        return "<p>无轮次数据</p>"

    w, h = 960, 340
    pad_l, pad_r, pad_t, pad_b = 80, 24, 24, 56
    n = len(rounds)

    # 纵轴范围：所有绘制值（每轮性能 + baseline + 最优）的 min/max 外扩
    all_vals = [r["performance"] for r in rounds]
    if baseline is not None:
        all_vals.append(baseline)
    if best_perf is not None:
        all_vals.append(best_perf)
    y_min = min(all_vals) * 0.92
    y_max = max(all_vals) * 1.05
    if y_max <= y_min:
        y_max = y_min + 1

    def x(i):
        return pad_l + (i / max(n - 1, 1)) * (w - pad_l - pad_r)

    def y(v):
        return pad_t + (1 - (v - y_min) / (y_max - y_min)) * (h - pad_t - pad_b)

    # 网格线（4 条横向）
    grid = []
    for g in range(5):
        gy = pad_t + (h - pad_t - pad_b) * g / 4
        val = y_max - (y_max - y_min) * g / 4
        grid.append(
            f'<line x1="{pad_l}" y1="{gy:.1f}" x2="{w - pad_r}" y2="{gy:.1f}" '
            f'class="gridline"/>'
            f'<text x="{pad_l - 10}" y="{gy + 4:.1f}" class="tick" '
            f'text-anchor="end">{fmt_num(val)}</text>'
        )

    # X 轴标签（约 16 个刻度以内）
    xticks = []
    step = max((n + 15) // 16, 1)
    for i in range(0, n, step):
        r = rounds[i]["round"]
        xticks.append(
            f'<text x="{x(i):.1f}" y="{pad_t + (h - pad_t - pad_b) + 20}" '
            f'class="tick" text-anchor="middle">{r}</text>'
        )
    last = rounds[-1]["round"]
    if (n - 1) % step != 0:
        xticks.append(
            f'<text x="{x(n - 1):.1f}" y="{pad_t + (h - pad_t - pad_b) + 20}" '
            f'class="tick" text-anchor="middle">{last}</text>'
        )
    # X 轴标题
    x_title = (
        f'<text x="{(pad_l + w - pad_r) / 2:.1f}" y="{h - 12}" class="tick" '
        f'text-anchor="middle">轮次（轮）</text>'
    )

    # cumulative best
    cum_best = []
    m = 0
    for r in rounds:
        m = max(m, r["performance"])
        cum_best.append(m)

    def poly(points):
        return " ".join(f"{x(i):.1f},{y(v):.1f}" for i, v in enumerate(points))

    # baseline 参考线（橙）
    bl = ""
    if baseline is not None:
        by = y(baseline)
        bl = (
            f'<line x1="{pad_l}" y1="{by:.1f}" x2="{w - pad_r}" y2="{by:.1f}" '
            f'class="baseline-line"/>'
        )

    # 每轮性能线（主，蓝实线圆点） + 累计最优线（浅蓝虚线）
    main_line = (
        f'<polyline points="{poly([r["performance"] for r in rounds])}" '
        f'fill="none" class="series-line"/>'
    )
    cum_line = (
        f'<polyline points="{poly(cum_best)}" fill="none" class="best-line"/>'
    )
    dots = "".join(
        f'<circle cx="{x(i):.1f}" cy="{y(r["performance"]):.1f}" r="3" class="series-dot"/>'
        for i, r in enumerate(rounds)
    )

    # 数据点悬浮热区（透明，鼠标悬浮显示轮次/性能提示）
    hits = "".join(
        f'<circle class="hit" cx="{x(i):.1f}" cy="{y(r["performance"]):.1f}" r="8" '
        f'data-round="{r["round"]}" data-perf="{fmt_num(r["performance"])}"/>'
        for i, r in enumerate(rounds)
    )

    legend = (
        '<div class="legend">'
        '<span class="legend-item"><span class="swatch series"></span>每轮性能</span>'
        '<span class="legend-item"><span class="swatch best"></span>累计最优</span>'
        '<span class="legend-item"><span class="swatch baseline"></span>baseline</span>'
        "</div>"
    )

    return (
        f'<figure class="chart">'
        f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="收敛曲线">'
        f"<g>{''.join(grid)}</g>"
        f"<g>{bl}</g>"
        f"<g>{''.join(xticks)}</g>"
        f"{x_title}"
        f"<g>{main_line}</g>"
        f"<g>{cum_line}</g>"
        f"<g>{dots}</g>"
        f"<g>{hits}</g>"
        f"</svg>{legend}</figure>"
    )


def importance_table(importance):
    """参数重要性：表格 + 蓝色横向条形（完整显示，无横向拖动条）。"""
    if not importance:
        return "<p>日志中未解析到参数重要性数据。</p>"

    top = sorted(importance, key=lambda i: i["importance"], reverse=True)[:12]
    max_imp = top[0]["importance"] if top else 1

    rows = []
    for item in top:
        # 条形最大占轨道 75%，为右侧百分比标签预留空间，避免表格溢出
        pct_w = item["importance"] / max_imp * 75
        rows.append(
            f"<tr><td class='param'>{esc(item['param'])}</td>"
            f"<td><div class='bar-track'>"
            f"<div class='bar' style='width:{pct_w:.1f}%'></div>"
            f"<span class='bar-val'>{item['importance']:.2f}%</span>"
            f"</div></td></tr>"
        )
    return (
        '<div class="table-wrap table-fit"><table class="imp-table">'
        "<thead><tr><th style='width:42%'>参数名</th><th>重要性占比</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table></div>"
    )


def medal_html(rank):
    """前三名金银铜奖牌徽章。"""
    if rank <= 3:
        cls = {1: "gold", 2: "silver", 3: "bronze"}[rank]
        return f"<span class='medal {cls}'>{rank}</span>"
    return str(rank)


def top10_table(rounds, baseline, perf_info):
    """TOP 10 性能表（排名 / 轮次 / 性能 / 对比基线提升百分比，后两列居中）。"""
    if not rounds:
        return "<p>无轮次数据</p>"
    ranked = sorted(rounds, key=lambda r: r["performance"], reverse=True)[:10]
    rows = []
    for i, r in enumerate(ranked, 1):
        imp = "--"
        if baseline:
            pct = (r["performance"] - baseline) / baseline * 100.0
            sign = "+" if pct >= 0 else ""
            cls = "pos" if pct >= 0 else "neg"
            imp = f'<span class="{cls}">{sign}{pct:.1f}%</span>'
        rows.append(
            f"<tr><td>{medal_html(i)}</td><td>round {r['round']}</td>"
            f"<td class='ctr'>{fmt_num(r['performance'])}</td>"
            f"<td class='ctr'>{imp}</td></tr>"
        )
    return (
        '<div class="table-wrap"><table>'
        f"<thead><tr><th>排名</th><th>轮次</th>"
        f"<th class='ctr'>性能（{esc(perf_info)}）</th>"
        f"<th class='ctr'>对比基线提升百分比</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table></div>"
    )


def all_rounds_table(s):
    """全部轮次汇总表（n 行 × 3 列：轮次 / 性能 / 对比基线提升百分比，居中，可点击）。"""
    baseline = s["baseline"]
    rows = []
    for idx, r in enumerate(s["rounds"]):
        imp = "--"
        if baseline:
            pct = (r["performance"] - baseline) / baseline * 100.0
            sign = "+" if pct >= 0 else ""
            cls = "pos" if pct >= 0 else "neg"
            imp = f'<span class="{cls}">{sign}{pct:.1f}%</span>'
        rows.append(
            f"<tr data-idx='{idx}' title='点击查看该轮详细信息'>"
            f"<td>{r['round']}</td>"
            f"<td>{fmt_num(r['performance'])}</td>"
            f"<td>{imp}</td></tr>"
        )
    return (
        '<p class="series-note">全部轮次汇总（滚动查看，点击任意行查看该轮参数详情）：</p>'
        '<div class="table-wrap rounds-scroll"><table id="rounds-table">'
        f"<thead><tr><th>轮次</th>"
        f"<th>性能（{esc(s['perf_info'])}）</th>"
        f"<th>对比基线提升百分比</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table></div>"
        '<div id="round-detail" class="round-detail" style="display:none"></div>'
    )


def rounds_payload_json(s):
    """生成全部轮次数据 JSON（供任务信息页点击展示详情）。

    params 按参数组拆分为 tabs：既有系统参数又有应用参数时分为两个 tab，
    只有应用参数时仅一个"应用参数" tab。
    """
    baseline = s["baseline"]
    group_names = [g.strip() for g in str(s["app"]).split(",") if g.strip()]

    def group_label(g):
        name = group_names[g] if g < len(group_names) else f"组{g}"
        if name.lower() == "system":
            return "系统参数"
        return f"{name}参数"

    def make_tabs(params, groups):
        buckets = {}
        for pk, g in groups.items():
            buckets.setdefault(g, {})[pk] = params.get(pk)
        idxs = sorted(buckets.keys())
        if not idxs:
            return {}
        if len(idxs) == 1:
            g = idxs[0]
            name = group_names[g].lower() if g < len(group_names) else ""
            label = "系统参数" if name == "system" else "应用参数"
            return {label: buckets[g]}
        return {group_label(g): buckets[g] for g in idxs}

    payload = []
    for r in s["rounds"]:
        if baseline:
            pct = (r["performance"] - baseline) / baseline * 100.0
            sign = "+" if pct >= 0 else ""
            imp_disp = f"{sign}{pct:.1f}%"
        else:
            imp_disp = "--"
        payload.append(
            {
                "round": r["round"],
                "perf_disp": fmt_num(r["performance"]),
                "imp_disp": imp_disp,
                "tabs": make_tabs(r["params"], r.get("param_groups", {})),
            }
        )
    return json.dumps(payload, ensure_ascii=False)


# ── HTML 组装 ───────────────────────────────────────────────────────

def stats_panel(s):
    """性能统计面板：调优轮数 / 最优轮数 / 最优性能 / 提升幅度。"""
    def stat(label, value, unit="", accent=None):
        u = f"<span class='stat-unit'>{unit}</span>" if unit else ""
        color = f" style='color:{accent}'" if accent else ""
        return (
            f"<div class='stat'>"
            f"<div class='stat-label'>{label}</div>"
            f"<div class='stat-value'{color}>{value}{u}</div>"
            f"</div>"
        )

    stats = [
        stat("调优轮数", esc(s["total_rounds"]), "轮"),
        stat("最优轮数", esc(s["best_round"] if s["best_round"] is not None else "--"), "轮"),
        stat("最优性能", fmt_num(s["best_perf"])),
    ]
    # 提升幅度：仅数值标亮（正向绿/负向红），标签保持默认颜色
    if s["improvement"] is not None:
        sign = "+" if s["improvement"] >= 0 else ""
        imp_txt = f"{sign}{s['improvement']:.1f}%"
        imp_accent = PALETTE["positive"] if s["improvement"] >= 0 else PALETTE["negative"]
        stats.append(stat("提升幅度（相对baseline）", imp_txt, accent=imp_accent))
    else:
        stats.append(stat("提升幅度（相对baseline）", "--"))
    return (
        "<section class='panel'>"
        "<div class='panel-title'>"
        "<svg width='16' height='16' viewBox='0 0 16 16' aria-hidden='true'>"
        f"<rect x='1' y='8' width='3.4' height='7' rx='0.8' fill='{PALETTE['accent']}'/>"
        f"<rect x='6.3' y='4' width='3.4' height='11' rx='0.8' fill='{PALETTE['accent']}'/>"
        f"<rect x='11.6' y='1' width='3.4' height='14' rx='0.8' fill='{PALETTE['accent']}'/>"
        "</svg>"
        "<span>性能统计</span></div>"
        f"<div class='stats-row'>{''.join(stats)}</div>"
        "</section>"
        "<div class='info-strip'>"
        f"<span><span class='k'>应用:</span> {esc(str(s['app']).replace(',', ', '))}</span>"
        f"<span class='sep'></span>"
        f"<span><span class='k'>算法:</span> {esc(s['algorithm'])}</span>"
        f"<span class='sep'></span>"
        f"<span><span class='k'>指标:</span> {esc(s['perf_info'])}</span>"
        "</div>"
    )


def success_banner(s):
    """调优成功横幅。"""
    groups = str(s["app"]).replace(",", ", ")
    imp = s["improvement"]
    if imp is not None and imp > 0:
        text = f"{groups}参数调优成功。您可以根据建议选择最终参数轮次，提升性能。"
        cls = "banner-success"
    else:
        text = f"{groups}参数调优完成。未取得正向提升，建议扩大参数范围或增加轮次后重试。"
        cls = "banner-warn"
    return (
        f"<div class='banner {cls}'>"
        f"<span class='banner-icon'>"
        f"<svg width='15' height='15' viewBox='0 0 16 16' aria-hidden='true'>"
        f"<circle cx='8' cy='8' r='7' fill='none' stroke='currentColor' stroke-width='1.6'/>"
        f"<path d='M4.6 8.3l2.3 2.3 4.5-4.8' fill='none' stroke='currentColor' "
        f"stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'/></svg>"
        f"</span>{esc(text)}</div>"
    )


def task_info_table(s, train_dir, title):
    """任务信息页签内容（元数据表 + 全部轮次汇总表）。"""
    rows = [
        ("任务名称", title),
        ("应用（参数组）", s["app"]),
        ("算法", s["algorithm"]),
        ("调优方向", s["direction"] or "maximize"),
        ("性能指标", s["perf_info"]),
        ("调优轮数", s["total_rounds"]),
        ("随机初始占比", s["random_ratio"] if s["random_ratio"] is not None else "--"),
        ("运行次数", s["run_times"] if s["run_times"] is not None else "--"),
        ("失败次数", s["fail_times"] if s["fail_times"] is not None else "--"),
        ("Baseline", fmt_num(s["baseline"])),
        ("最优性能", fmt_num(s["best_perf"])),
        ("最优轮次", s["best_round"] if s["best_round"] is not None else "--"),
        ("数据目录", train_dir),
    ]
    trs = "".join(
        f"<tr><td class='k'>{esc(k)}</td><td>{esc(v)}</td></tr>" for k, v in rows
    )
    return (
        '<div class="table-wrap"><table class="task-table"><tbody>'
        f"{trs}</tbody></table></div>"
        f"<h2>轮次信息</h2>{all_rounds_table(s)}"
    )


def build_html(data, out_name, title, train_dir):
    """组装完整 HTML。"""
    importance = resolve_param_names(data["importance"], data["rounds"])
    s = summarize(data, importance)

    generated = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    rounds_json = rounds_payload_json(s)

    # AI 分析占位符（由 build_ai_note / --ai-note 替换）
    ai_placeholder = (
        "<!-- AI_ANALYSIS -->\n"
        "    <p class='ai-placeholder'>（AI 分析待生成）</p>"
    )

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>调优报告 · {esc(title)}</title>
<style>
  :root {{
    color-scheme: light;
    --page: #f5f6f8;
    --topbar: #eceef1;
    --surface: #ffffff;
    --surface-2: #f0f2f5;
    --ink: #1b1f24;
    --ink-2: #41464e;
    --muted: #6e747c;
    --border: #d8dce2;
    --border-2: #c6ccd4;
    --grid: #e6e9ed;
    --series: #2e6fdb;
    --best: #86b3f2;
    --baseline: #e07b3f;
    --pos: #1a7f37;
    --neg: #cf222e;
    --accent: #2e6bdb;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 0;
    background: var(--page); color: var(--ink);
    font-family: system-ui, -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
    line-height: 1.55; font-size: 14px;
  }}
  /* ── 主体框架（与内容区同宽）── */
  .frame {{
    max-width: 1080px; margin: 0 auto; min-height: 100vh;
    background: var(--page);
    border-left: 1px solid var(--border); border-right: 1px solid var(--border);
  }}
  /* ── 顶栏 ── */
  .topbar {{
    display: flex; align-items: center; justify-content: space-between;
    background: var(--topbar); border-bottom: 1px solid var(--border);
    padding: 12px 28px;
  }}
  .topbar-left {{ display: flex; align-items: center; gap: 12px; }}
  .topbar-icon {{
    width: 34px; height: 34px; border-radius: 8px; background: #2ea043;
    display: inline-flex; align-items: center; justify-content: center; flex: none;
  }}
  .topbar-title {{ font-size: 16px; font-weight: 700; line-height: 1.3; }}
  .topbar-sub {{ font-size: 12px; color: var(--muted); }}
  .topbar-right {{ text-align: right; font-size: 12px; color: var(--muted); }}
  .topbar-right .brand {{ color: var(--accent); font-weight: 600; }}
  /* ── 页签 ── */
  .tabs {{
    display: flex; gap: 28px; padding: 0 28px;
    border-bottom: 1px solid var(--border); background: var(--topbar);
  }}
  .tab {{
    padding: 10px 2px; font-size: 14px; color: var(--muted); cursor: pointer;
    border: none; background: none; border-bottom: 2px solid transparent;
    font-family: inherit;
  }}
  .tab.active {{ color: var(--accent); border-bottom-color: var(--accent); font-weight: 600; }}
  .container {{ padding: 20px 28px 40px; }}
  /* ── 横幅 ── */
  .banner {{
    display: flex; align-items: center; gap: 10px;
    border: 1px solid; border-radius: 6px; padding: 10px 14px; margin: 4px 0 16px;
    font-size: 14px;
  }}
  .banner-success {{
    background: rgba(31, 155, 58, 0.08); border-color: rgba(26, 127, 55, 0.45);
    color: #1a7f37;
  }}
  .banner-warn {{
    background: rgba(187, 128, 9, 0.08); border-color: rgba(154, 103, 0, 0.45);
    color: #9a6700;
  }}
  .banner-icon {{ display: inline-flex; flex: none; }}
  /* ── 面板 / 性能统计 ── */
  .panel {{
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 18px 24px 22px;
  }}
  .panel-title {{
    display: flex; align-items: center; gap: 8px;
    font-size: 15px; font-weight: 700; margin-bottom: 14px;
  }}
  .stats-row {{
    display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px;
  }}
  @media (max-width: 720px) {{ .stats-row {{ grid-template-columns: repeat(2, 1fr); }} }}
  .stat-label {{ color: var(--muted); font-size: 13px; margin-bottom: 6px; }}
  .stat-value {{ font-size: 30px; font-weight: 700; line-height: 1.15;
    font-variant-numeric: tabular-nums; }}
  .stat-unit {{ font-size: 13px; font-weight: 400; color: var(--ink-2); margin-left: 4px; }}
  .info-strip {{
    display: flex; align-items: center; flex-wrap: wrap; gap: 20px;
    border: 1px solid var(--border); border-radius: 6px;
    background: var(--surface); padding: 10px 18px; margin-top: 12px;
    font-size: 13px;
  }}
  .info-strip .k {{ color: var(--muted); }}
  .info-strip .sep {{ width: 1px; height: 14px; background: var(--border-2); }}
  /* ── 章节标题 ── */
  h2 {{ font-size: 17px; font-weight: 700; margin: 30px 0 6px; }}
  h3 {{ font-size: 15px; font-weight: 600; margin: 14px 0 6px; color: var(--ink); }}
  .series-note {{ color: var(--muted); font-size: 12px; margin: 0 0 10px; }}
  /* ── 图表 ── */
  .chart {{ margin: 0; }}
  .chart svg {{ width: 100%; height: auto; }}
  .gridline {{ stroke: var(--grid); stroke-width: 1; }}
  .tick {{ fill: var(--muted); font-size: 12px; }}
  .series-line {{ stroke: var(--series); stroke-width: 2; fill: none; }}
  .best-line {{ stroke: var(--best); stroke-width: 2; fill: none; stroke-dasharray: 6 4; }}
  .series-dot {{ fill: var(--series); }}
  .baseline-line {{ stroke: var(--baseline); stroke-width: 1.6; stroke-dasharray: 6 4; }}
  .hit {{ fill: transparent; cursor: pointer; }}
  #chart-tip {{
    position: fixed; display: none; z-index: 60;
    background: #ffffff; border: 1px solid var(--border-2);
    color: var(--ink); padding: 6px 10px; border-radius: 6px;
    font-size: 12px; pointer-events: none; white-space: nowrap;
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
    font-variant-numeric: tabular-nums;
  }}
  .legend {{
    display: flex; gap: 18px; justify-content: center;
    margin-top: 8px; font-size: 12px; color: var(--ink-2);
  }}
  .legend-item {{ display: inline-flex; align-items: center; gap: 6px; }}
  .swatch {{ width: 18px; height: 0; border-top: 2px solid; display: inline-block; }}
  .swatch.series {{ border-top-color: var(--series); border-top-style: solid; }}
  .swatch.best {{ border-top-color: var(--best); border-top-style: dashed; }}
  .swatch.baseline {{ border-top-color: var(--baseline); border-top-style: dashed; }}
  /* ── 表格 ── */
  .table-wrap {{ overflow-x: auto; }}
  /* 重要性表格：完整显示在页面上，不出横向拖动条 */
  .table-fit {{ overflow-x: visible; }}
  .imp-table {{ table-layout: fixed; }}
  .imp-table td.param {{ word-break: break-all; }}
  table {{
    width: 100%; border-collapse: collapse; font-size: 13.5px;
    font-variant-numeric: tabular-nums;
  }}
  th, td {{ padding: 9px 14px; text-align: left; border-bottom: 1px solid var(--border); }}
  thead th {{
    background: var(--surface-2); color: var(--ink-2);
    font-weight: 600; font-size: 13px;
  }}
  tbody tr:hover {{ background: rgba(0, 0, 0, 0.03); }}
  td.num, th.num {{ text-align: right; }}
  td.ctr, th.ctr {{ text-align: center; }}
  td.param {{ font-family: Consolas, "Courier New", monospace; color: var(--ink-2); }}
  .pos {{ color: var(--pos); font-weight: 600; }}
  .neg {{ color: var(--neg); font-weight: 600; }}
  .imp-table .bar-track {{ display: flex; align-items: center; width: 100%; }}
  .imp-table .bar {{
    height: 16px; border-radius: 2px; background: var(--series); flex: none;
  }}
  .imp-table .bar-val {{ margin-left: 10px; font-size: 12.5px; color: var(--ink-2); white-space: nowrap; }}
  .task-table td.k {{ color: var(--muted); width: 180px; }}
  /* ── 奖牌徽章 ── */
  .medal {{
    display: inline-flex; align-items: center; justify-content: center;
    width: 22px; height: 22px; border-radius: 50%;
    font-weight: 700; font-size: 12px;
  }}
  .medal.gold {{ background: #f0b429; color: #231a00; box-shadow: 0 0 6px rgba(240, 180, 41, 0.45); }}
  .medal.silver {{ background: #c8cdd6; color: #1c1f24; box-shadow: 0 0 6px rgba(200, 205, 214, 0.35); }}
  .medal.bronze {{ background: #cd8b4a; color: #241300; box-shadow: 0 0 6px rgba(205, 139, 74, 0.35); }}
  /* ── 轮次信息表（任务信息页，滚动显示约 20 行）── */
  .rounds-scroll {{ max-height: 820px; overflow-y: auto; }}
  #rounds-table thead th {{
    position: sticky; top: 0; z-index: 2;
    background: var(--surface-2);
  }}
  #rounds-table tbody tr {{ cursor: pointer; }}
  #rounds-table tbody tr:hover {{ background: rgba(0, 0, 0, 0.04); }}
  #rounds-table tbody tr.hl {{
    background: rgba(46, 109, 219, 0.12);
    box-shadow: inset 3px 0 0 var(--series);
  }}
  .round-detail {{
    margin-top: 14px; background: var(--surface);
    border: 1px solid var(--border); border-radius: 8px; padding: 16px 20px;
  }}
  .round-detail h3 {{ margin-top: 0; }}
  .param-scroll {{ max-height: 320px; overflow-y: auto; }}
  /* ── 轮次详情参数分组 Tab ── */
  .detail-tabs {{
    display: flex; gap: 4px; margin: 12px 0 0;
    border-bottom: 1px solid var(--border);
  }}
  .detail-tab {{
    padding: 7px 16px; font-size: 13px; cursor: pointer;
    border: none; background: none; font-family: inherit;
    color: var(--muted); border-bottom: 2px solid transparent;
  }}
  .detail-tab.active {{
    color: var(--accent); border-bottom-color: var(--accent); font-weight: 600;
  }}
  .detail-pane {{ padding-top: 10px; }}
  /* 详情参数表：固定列宽，不随轮次/Tab 内容变化 */
  .detail-pane .task-table {{ table-layout: fixed; }}
  .detail-pane .task-table th:first-child,
  .detail-pane .task-table td:first-child {{ width: 45%; }}
  .detail-pane .task-table td {{ word-break: break-all; }}
  /* ── AI 分析 ── */
  .ai-panel {{
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 18px 24px; margin-top: 10px;
  }}
  .ai-panel h3 {{ margin-top: 0; }}
  .ai-panel h4, .ai-panel h5, .ai-panel h6 {{ margin: 16px 0 6px; }}
  .ai-panel p, .ai-panel li {{ color: var(--ink-2); font-size: 13.5px; }}
  .ai-panel table {{ margin: 8px 0; }}
  .ai-panel code {{
    background: var(--surface-2); border: 1px solid var(--border);
    border-radius: 4px; padding: 1px 5px; font-size: 12.5px;
    font-family: Consolas, "Courier New", monospace; color: #1f4fb8;
  }}
  .ai-panel blockquote {{
    margin: 8px 0; padding: 6px 14px; border-left: 3px solid var(--accent);
    background: var(--surface-2); border-radius: 0 6px 6px 0;
    color: var(--muted);
  }}
  .ai-panel hr {{ border: none; border-top: 1px solid var(--border); margin: 16px 0; }}
  .ai-placeholder {{ color: var(--muted); font-style: italic; }}
  footer {{
    margin-top: 36px; padding-top: 14px; border-top: 1px solid var(--border);
    color: var(--muted); font-size: 12px; line-height: 1.7;
  }}
</style>
</head>
<body>
<div class="frame">
<header class="topbar">
  <div class="topbar-left">
    <span class="topbar-icon">
      <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true">
        <rect x="2.5" y="2.5" width="15" height="15" rx="2.5" fill="none"
          stroke="#fff" stroke-width="1.6"/>
        <path d="M5.5 13.5l3-4 2.5 2.5 3.5-5" fill="none" stroke="#fff"
          stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
    </span>
    <div>
      <div class="topbar-title">{esc(title)}</div>
      <div class="topbar-sub">DevKit AI 参数调优</div>
    </div>
  </div>
  <div class="topbar-right">
    <div>Produced by <span class="brand">Kunpeng DevKit</span></div>
  </div>
</header>
<nav class="tabs">
  <button class="tab active" id="tab-btn-report" onclick="switchTab('report')">参数调优报告</button>
  <button class="tab" id="tab-btn-task" onclick="switchTab('task')">任务信息</button>
</nav>
<div class="container">
<div id="chart-tip"></div>
<section id="tab-report">
  {success_banner(s)}

  {stats_panel(s)}

  <h2>收敛曲线</h2>
  <h3>调优结果趋势</h3>
  <p class="series-note">调优性能数据（{esc(s['perf_info'])}，悬浮数据点可查看轮次与性能）</p>
  {svg_convergence(s['rounds'], s['baseline'], s['best_perf'])}

  <h2>参数重要性</h2>
  {importance_table(importance)}

  <h2>TOP 10 性能</h2>
  {top10_table(s['rounds'], s['baseline'], s['perf_info'])}

  <h2>AI 分析</h2>
  <div class="ai-panel">
    {ai_placeholder}
  </div>
</section>
<section id="tab-task" style="display:none">
  <h2>任务信息</h2>
  {task_info_table(s, esc(train_dir), esc(title))}
</section>
<script id="rounds-data" type="application/json">{rounds_json}</script>

  <footer>
    调优报告 · 数据来源：train.db + run.log<br>
    报告文件：{esc(out_name)} · 生成时间：{generated}
  </footer>
</div>
</div>
<script>
function switchTab(name) {{
  for (const id of ['report', 'task']) {{
    document.getElementById('tab-' + id).style.display = id === name ? '' : 'none';
    const btn = document.getElementById('tab-btn-' + id);
    btn.classList.toggle('active', id === name);
  }}
}}
/* 收敛曲线数据点悬浮提示 */
(function() {{
  const tip = document.getElementById('chart-tip');
  if (!tip) return;
  document.querySelectorAll('.hit').forEach(function(c) {{
    c.addEventListener('mouseenter', function() {{
      tip.textContent = '轮次 ' + c.getAttribute('data-round')
        + ' | 性能: ' + c.getAttribute('data-perf');
      tip.style.display = 'block';
    }});
    c.addEventListener('mousemove', function(e) {{
      tip.style.left = (e.clientX + 14) + 'px';
      tip.style.top = (e.clientY - 34) + 'px';
    }});
    c.addEventListener('mouseleave', function() {{
      tip.style.display = 'none';
    }});
  }});
}})();
/* 任务信息页：轮次表点击显示该轮详情并高亮 */
(function() {{
  function escJ(v) {{
    return String(v).replace(/[&<>"']/g, function(c) {{
      return {{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}}[c];
    }});
  }}
  const dataEl = document.getElementById('rounds-data');
  const tbl = document.getElementById('rounds-table');
  const detail = document.getElementById('round-detail');
  if (!dataEl || !tbl || !detail) return;
  let roundsData = [];
  try {{ roundsData = JSON.parse(dataEl.textContent); }} catch (e) {{ roundsData = []; }}
  tbl.querySelectorAll('tbody tr').forEach(function(tr) {{
    tr.addEventListener('click', function() {{
      tbl.querySelectorAll('tbody tr').forEach(function(x) {{ x.classList.remove('hl'); }});
      tr.classList.add('hl');
      const r = roundsData[parseInt(tr.getAttribute('data-idx'), 10)];
      if (!r) return;
      const tabsObj = r.tabs || {{}};
      const labels = Object.keys(tabsObj);
      /* 参数个数与当前 Tab 联动，初始显示第一个 Tab 的数量 */
      const initialCount = labels.length > 0
        ? Object.keys(tabsObj[labels[0]] || {{}}).length
        : 0;
      let h = '<h3>round ' + escJ(r.round) + ' 详细信息</h3>';
      h += '<p><span class="k">性能:</span> <strong>' + escJ(r.perf_disp) + '</strong>'
        + '　<span class="k">对比基线提升:</span> <strong>' + escJ(r.imp_disp) + '</strong>'
        + '　<span class="k">参数个数:</span> <span id="detail-param-count">' + initialCount + '</span></p>';
      if (labels.length > 0) {{
        /* 参数分组 Tab：既有系统参数又有应用参数时分两个 tab，仅应用参数时单个 tab */
        h += '<div class="detail-tabs">';
        for (let t = 0; t < labels.length; t++) {{
          h += '<button type="button" class="detail-tab' + (t === 0 ? ' active' : '')
            + '" data-t="' + t + '">' + escJ(labels[t]) + '</button>';
        }}
        h += '</div>';
        for (let t = 0; t < labels.length; t++) {{
          const obj = tabsObj[labels[t]] || {{}};
          const keys = Object.keys(obj);
          h += '<div class="detail-pane" data-p="' + t + '"'
            + (t === 0 ? '' : ' style="display:none"') + '>'
            + '<div class="param-scroll"><table class="task-table">'
            + '<thead><tr><th>参数名</th><th>参数值</th></tr></thead><tbody>';
          if (keys.length === 0) {{
            h += '<tr><td colspan="2">无参数记录</td></tr>';
          }}
          for (let i = 0; i < keys.length; i++) {{
            h += '<tr><td class="param">' + escJ(keys[i]) + '</td>'
              + '<td>' + escJ(obj[keys[i]]) + '</td></tr>';
          }}
          h += '</tbody></table></div></div>';
        }}
      }} else {{
        h += '<p>无参数记录</p>';
      }}
      detail.innerHTML = h;
      detail.style.display = 'block';
      /* Tab 切换：显示对应分组参数表 */
      const tabBtns = detail.querySelectorAll('.detail-tab');
      const panes = detail.querySelectorAll('.detail-pane');
      tabBtns.forEach(function(btn) {{
        btn.addEventListener('click', function() {{
          tabBtns.forEach(function(b) {{ b.classList.remove('active'); }});
          btn.classList.add('active');
          const t = btn.getAttribute('data-t');
          panes.forEach(function(p) {{
            p.style.display = p.getAttribute('data-p') === t ? '' : 'none';
          }});
          /* 参数个数随当前 Tab 对应分组动态更新 */
          const cnt = Object.keys(tabsObj[labels[parseInt(t, 10)]] || {{}}).length;
          const cntEl = document.getElementById('detail-param-count');
          if (cntEl) cntEl.textContent = cnt;
        }});
      }});
      /* 自动滚动到该轮详情区域，无需用户手动滚动 */
      detail.scrollIntoView({{ behavior: 'smooth', block: 'start' }});
    }});
  }});
}})();
</script>
</body>
</html>
"""


# ── AI 分析自动生成 ─────────────────────────────────────────────────

# 常见调优参数的解读关键词（按匹配顺序）
PARAM_NOTES = [
    ("io-threads", "IO 线程数直接影响并发处理能力，适当增大可提升多核利用率"),
    ("maxmemory-policy", "内存淘汰策略，影响缓存命中与内存管理行为"),
    ("maxmemory", "内存上限，影响缓存容量与淘汰触发时机"),
    ("maxmemory-samples", "淘汰策略采样数，影响淘汰精度与 CPU 开销"),
    ("timeout", "客户端空闲超时，合理设置可及时释放僵死连接"),
    ("tcp-keepalive", "TCP keepalive 探测间隔，影响死连接回收速度"),
    ("keepalive", "TCP keepalive 参数，影响连接保活与回收"),
    ("tcp-backlog", "监听队列长度，影响高并发建连能力"),
    ("hz", "定时器频率，影响过期键清理与后台任务调度"),
    ("active-defrag", "主动碎片整理，影响内存碎片回收效率"),
    ("lazyfree", "惰性删除，可降低主线程阻塞"),
    ("appendonly", "AOF 持久化，影响数据安全与写入开销"),
    ("appendfsync", "AOF 刷盘策略，影响持久化粒度与性能"),
    ("save", "RDB 快照策略，影响持久化开销"),
    ("sched_wakeup_granularity_ns", "内核调度唤醒粒度，减小可降低唤醒延迟、提升吞吐"),
    ("sched_latency_ns", "内核调度周期，影响任务调度延迟"),
    ("sched_min_granularity_ns", "内核最小调度粒度，影响时间片切换频率"),
    ("sched_migration_cost_ns", "迁移开销阈值，影响任务跨核迁移频率与缓存亲和性"),
    ("dirty_background_ratio", "后台脏页回收阈值，影响刷盘节奏与 IO 抖动"),
    ("dirty_ratio", "脏页上限，影响写入吞吐与回压"),
    ("swappiness", "换页倾向，降低可减少内存交换开销"),
    ("max_map_count", "进程最大内存映射数，影响映射能力"),
    ("overcommit_memory", "内存过量提交策略，影响内存分配行为"),
    ("tcp_fin_timeout", "FIN_WAIT2 超时，影响连接释放速度"),
    ("tcp_tw_reuse", "TIME_WAIT 复用，影响短连接吞吐"),
    ("somaxconn", "监听队列上限，影响高并发建连"),
    ("tcp_max_syn_backlog", "SYN 队列长度，影响突发建连能力"),
    ("netdev_max_backlog", "网卡收包队列长度，影响突发流量处理"),
    ("tcp_keepalive_time", "TCP keepalive 探测间隔，影响死连接回收速度"),
    ("transparent_hugepage", "透明大页策略，影响内存管理延迟"),
    ("tcp_congestion_control", "TCP 拥塞控制算法，影响网络吞吐"),
]


def note_for_param(name):
    """根据参数名关键词生成解读文字。"""
    low = name.lower()
    for key, note in PARAM_NOTES:
        if key in low:
            return note
    return "对该应用性能存在影响的可调参数，建议结合业务压测进一步验证"


def build_ai_note(s, train_dir):
    """根据训练数据自动生成 AI 分析 markdown。"""
    app_disp = str(s["app"]).replace(",", ", ")
    perf = s["perf_info"]
    baseline = s["baseline"] or 0
    best = s["best_perf"]
    best_round = s["best_round"]
    imp = s["improvement"] or 0.0
    rounds = s["rounds"]
    n = len(rounds)
    algo = s["algorithm"] or "HPO"
    ratio = s["random_ratio"]
    m = 0
    if isinstance(ratio, (int, float)) and 0 < ratio < 1 and n > 2:
        m = max(1, int(round(n * ratio)))

    perfs = [r["performance"] for r in rounds]

    # 趋势解读
    if m and n > m:
        rp, hp = perfs[:m], perfs[m:]
        trend = (
            f"**随机探索阶段（第 1-{m} 轮）**\n\n"
            f"随机采样阶段性能波动较大，范围 {fmt_num(min(rp))} ~ {fmt_num(max(rp))} {perf}，"
            f"该阶段数据用于算法建模，整体处于探索状态。\n\n"
            f"**引导优化阶段（第 {m + 1}-{n} 轮）**\n\n"
            f"引入 {algo} 算法后性能区间收敛至 {fmt_num(min(hp))} ~ {fmt_num(max(hp))} {perf}，"
            f"最优解出现在第 {best_round} 轮。"
        )
        if best_round is not None and best_round >= n - 5:
            trend += "最优出现在末段，说明算法尚未完全收敛，建议增加轮次观察是否进一步提升。"
        else:
            trend += "最优解之后性能保持稳定，算法已基本收敛。"
        trend += "\n\n"
    else:
        trend = (
            f"全部 {n} 轮性能范围为 {fmt_num(min(perfs))} ~ {fmt_num(max(perfs))} {perf}，"
            f"最优解出现在第 {best_round} 轮。\n\n"
        )

    # 关键参数分析
    imp_sorted = sorted(s["importance"], key=lambda x: x["importance"], reverse=True)[:5]
    tbl_lines = ["依据参数重要性排序，影响最大的参数为：", ""]
    if imp_sorted:
        tbl_lines.append("| 排名 | 参数名 | 重要性 | 解读 |")
        tbl_lines.append("| --- | --- | --- | --- |")
        for i, item in enumerate(imp_sorted, 1):
            tbl_lines.append(
                f"| {i} | {item['param']} | {item['importance']:.2f}% | {note_for_param(item['param'])} |"
            )
        tbl_lines.append("")
        top2 = "、".join(x["param"] for x in imp_sorted[:2])
        top2_sum = sum(x["importance"] for x in imp_sorted[:2])
        tbl_lines.append(
            f"核心发现：**{top2}** 是影响本环境 {app_disp} 性能的最关键参数，"
            f"合计重要性约 {top2_sum:.1f}%，调优时应优先关注其取值组合。"
        )
    else:
        tbl_lines.append("日志中未解析到参数重要性数据。")
    tbl_lines.append("")
    params_md = "\n".join(tbl_lines)

    # 优化建议
    first_param = imp_sorted[0]["param"] if imp_sorted else "关键参数"
    good = imp > 0
    overview_verdict = (
        "调优取得显著收益，说明默认参数配置在本机环境下存在较大优化空间"
        if good
        else "调优未取得正向提升，建议扩大参数搜索范围或增加调优轮次后重试"
    )
    sign = "+" if imp >= 0 else ""
    note = f"""# {app_disp} 参数调优 — AI 分析报告

## 1. 结果概览

本次调优在 {app_disp} 应用上进行了 {n} 轮 {algo} 算法参数调优，以「{perf}」为优化指标。

- **基础性能**: {fmt_num(baseline)} {perf}
- **最优性能**: {fmt_num(best)} {perf}（第 {best_round} 轮）
- **提升幅度**: {sign}{imp:.2f}%
- **运行/失败次数**: {s['run_times']}/{s['fail_times']}

{overview_verdict}。

## 2. 趋势解读

{trend}## 3. 关键参数分析

{params_md}

## 4. 优化建议

**短期应用建议**

1. 将第 {best_round} 轮最优参数组合应用到当前环境，应用前先在等价环境完成一轮回归验证；
2. 可通过 DevKit 导入本次调优结果以便复用；
3. 优先关注 **{first_param}** 的取值，在业务高峰期观察运行稳定性。

**进一步优化建议**

1. 若最优解出现在最后几轮，建议增加 20~50 轮并适当调低 random_initial_ratio；
2. 聚焦高重要性参数、缩小低敏感参数的搜索空间，让算法集中在关键维度探索；
3. 可适当扩大 **{first_param}** 的搜索边界后复测，确认当前取值是否为局部最优；
4. 多场景验证：分别在读写混合、大 value 等典型负载下分别调优，形成场景化配置模板。
"""
    return note


def _md_to_html(md_text):
    """将 markdown 转换为 HTML（标题/列表/表格/引用/分隔线/行内格式）。"""

    import html as html_mod

    def inline(text):
        """行内格式：转义后解析 加粗/斜体/行内代码/链接。"""
        txt = html_mod.escape(text)
        # 行内代码（先处理，避免其内容被加粗/斜体规则改写）
        txt = re.sub(r"`([^`]+)`", r"<code>\1</code>", txt)
        # 加粗（两个星号）
        txt = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", txt)
        # 斜体（单个星号，避免与加粗冲突）
        txt = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", txt)
        # 链接 [text](url)
        txt = re.sub(
            r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2" target="_blank">\1</a>', txt
        )
        return txt

    lines = md_text.strip().splitlines()
    parts = []
    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        if not line:
            i += 1
            continue
        m = re.match(r"^(#{1,4})\s+(.*)", line)
        if m:
            lvl = len(m.group(1))
            parts.append(f"<h{lvl + 2}>{inline(m.group(2))}</h{lvl + 2}>")
            i += 1
            continue
        # 水平分隔线 --- / ***
        if re.fullmatch(r"\s*(-{3,}|\*{3,})\s*", line):
            parts.append("<hr>")
            i += 1
            continue
        # 引用块 > text
        if re.match(r"^\s*>\s?", line):
            quote = []
            while i < len(lines) and re.match(r"^\s*>\s?", lines[i]):
                quote.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            parts.append(f"<blockquote>{inline(' '.join(quote))}</blockquote>")
            continue
        # markdown 表格（| a | b | 形式，含分隔行）
        if re.match(r"^\s*\|.*\|\s*$", line):
            tbl_lines = []
            while i < len(lines) and re.match(r"^\s*\|.*\|\s*$", lines[i]):
                tbl_lines.append(lines[i])
                i += 1
            cells = [
                [c.strip() for c in tl.strip().strip("|").split("|")]
                for tl in tbl_lines
                if not re.match(r"^\s*\|[\s:|-]+\|\s*$", tl)
            ]
            if cells:
                head, *body = cells
                ths = "".join(f"<th>{inline(c)}</th>" for c in head)
                trs = "".join(
                    "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>"
                    for row in body
                )
                parts.append(
                    f"<table><thead><tr>{ths}</tr></thead><tbody>{trs}</tbody></table>"
                )
            continue
        if re.match(r"^\s*[-*]\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\s*[-*]\s+", lines[i]):
                li_text = re.sub(r"^\s*[-*]\s+", "", lines[i])
                items.append(f"<li>{inline(li_text)}</li>")
                i += 1
            parts.append("<ul>" + "".join(items) + "</ul>")
            continue
        if re.match(r"^\s*\d+[.、]\s+", line):
            items = []
            while i < len(lines) and re.match(r"^\s*\d+[.、]\s+", lines[i]):
                li_text = re.sub(r"^\s*\d+[.、]\s+", "", lines[i])
                items.append(f"<li>{inline(li_text)}</li>")
                i += 1
            parts.append("<ol>" + "".join(items) + "</ol>")
            continue
        parts.append(f"<p>{inline(line)}</p>")
        i += 1
    return "".join(parts)


def inject_ai_note(html_string, md_text):
    """将 AI 分析（markdown）注入报告占位符。返回 (注入后的 html, 是否找到占位符)。"""
    placeholder = "<!-- AI_ANALYSIS -->"
    if placeholder not in html_string:
        return html_string, False
    ai_html = _md_to_html(md_text)
    result = html_string.replace(placeholder, ai_html)
    result = result.replace(
        "<p class='ai-placeholder'>（AI 分析待生成）</p>", ""
    )
    return result, True


def validate_report(html_string, require_ai_replacement=True):
    """注入后校验：关键 section 齐全。返回 (是否通过, 缺失列表)。"""
    checks = {
        "性能统计": "性能统计</span>" in html_string,
        "收敛曲线": "<h2>收敛曲线</h2>" in html_string,
        "参数重要性": "<h2>参数重要性</h2>" in html_string,
        "TOP 10 性能": "<h2>TOP 10 性能</h2>" in html_string,
        "AI 分析区": "<h2>AI 分析</h2>" in html_string,
        "成功横幅": "banner-success" in html_string or "banner-warn" in html_string,
    }
    if require_ai_replacement:
        checks["AI 占位符已替换"] = "<!-- AI_ANALYSIS -->" not in html_string
    missing = [name for name, ok in checks.items() if not ok]
    return (not missing), missing


def print_summary(data, s):
    """打印紧凑文本摘要，供 LLM 生成 AI 分析时参考。"""
    print("=" * 50)
    print(f"调优结果摘要 — {s['app']}")
    print("=" * 50)
    print(f"指标: {s['perf_info']} | 方向: {s['direction'] or 'maximize'}")
    print(f"算法: {s['algorithm']} | 轮次: {s['total_rounds']} | 随机占比: {s['random_ratio']}")
    print(f"运行/失败: {s['run_times']}/{s['fail_times']}")
    print(f"baseline: {fmt_num(s['baseline'])}")
    print(f"最优: {fmt_num(s['best_perf'])} (round {s['best_round']})")
    if s["improvement"] is not None:
        sign = "+" if s["improvement"] >= 0 else ""
        print(f"提升幅度: {sign}{s['improvement']:.2f}%")
    print("\n每轮性能:")
    for r in s["rounds"]:
        imp = ""
        if s["baseline"]:
            pct = (r["performance"] - s["baseline"]) / s["baseline"] * 100.0
            imp = f"  ({pct:+.1f}%)"
        print(f"  round {r['round']}: {fmt_num(r['performance'])}{imp}")
    if s["importance"]:
        print("\n参数重要性 (Top 5):")
        for i in sorted(s["importance"], key=lambda x: x["importance"], reverse=True)[:5]:
            print(f"  {i['param']}: {i['importance']:.2f}%")
    print("=" * 50)


# ── CLI ─────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="调优报告生成器：读取 train.db + run.log，生成 DevKit 静态 HTML 报告",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n  %(prog)s /path/to/train_dir\n  %(prog)s /path/to/train_dir -o report.html\n  %(prog)s /path/to/train_dir --summary",
    )
    parser.add_argument("train_dir", help="训练目录（含 train.db 和 kat_run.log）")
    parser.add_argument("-o", "--output", help="输出 HTML 路径（默认 {train_dir}/report_{训练创建时间戳}.html）")
    parser.add_argument(
        "-s", "--summary", action="store_true",
        help="打印文本摘要（供 LLM 生成 AI 分析），不生成 HTML",
    )
    parser.add_argument(
        "--ai-note", metavar="FILE",
        help="自定义 AI 分析 markdown 文件（默认根据训练数据自动生成）",
    )
    parser.add_argument(
        "-t", "--title", default=None,
        help="报告顶栏任务标题（默认: 鲲鹏自动调优_{调优的应用}）",
    )
    args = parser.parse_args()

    train_dir = os.path.abspath(args.train_dir)
    if not os.path.isdir(train_dir):
        print(f"错误: 目录不存在: {train_dir}", file=sys.stderr)
        sys.exit(1)

    db_path = os.path.join(train_dir, "train.db")
    log_path = os.path.join(train_dir, "kat_run.log")
    if not os.path.exists(db_path):
        print(f"错误: 未找到 train.db: {db_path}", file=sys.stderr)
        sys.exit(1)

    data = load_train_db(db_path)
    data["importance"] = parse_importance(log_path)
    importance = resolve_param_names(data["importance"], data["rounds"])
    s = summarize(data, importance)

    if args.summary:
        print_summary(data, s)
        return

    # 标题默认: 鲲鹏自动调优_{调优的应用}
    title = args.title or f"鲲鹏自动调优_{s['app']}"

    out_name = args.output
    if not out_name:
        # 默认报告名绑定训练创建时间（tune_info.created_at），保证同一批调优数据对应唯一报告名，
        # 不同批次调优互不覆盖，避免新调优结果与旧报告混淆。
        # 注意: created_at 为 UTC，需转本地时区后再格式化；异常时回退到 train.db 修改时间。
        ts = None
        created = (data.get("tune") or {}).get("created_at")
        if created:
            try:
                dt = datetime.strptime(created, "%Y-%m-%d %H:%M:%S.%f")
                ts = dt.replace(tzinfo=timezone.utc).astimezone().strftime("%Y%m%d_%H%M%S")
            except ValueError:
                ts = None
        if not ts:
            ts = datetime.fromtimestamp(os.path.getmtime(db_path)).strftime("%Y%m%d_%H%M%S")
        out_name = os.path.join(train_dir, f"report_{ts}.html")
    out_dir = os.path.dirname(os.path.abspath(out_name))
    os.makedirs(out_dir, exist_ok=True)

    html_string = build_html(data, out_name, title, train_dir)

    # AI 分析：优先使用 --ai-note 注入，否则根据训练数据自动生成
    if args.ai_note:
        with open(args.ai_note, "r", encoding="utf-8") as f:
            md_text = f.read()
        ai_source = f"已注入 ({args.ai_note})"
    else:
        md_text = build_ai_note(s, train_dir)
        ai_source = "自动生成"
    html_string, found = inject_ai_note(html_string, md_text)
    if not found:
        print("错误: 报告中未找到 AI 分析占位符（AI 分析注入失败）", file=sys.stderr)
        sys.exit(1)

    with open(out_name, "w", encoding="utf-8") as f:
        f.write(html_string)

    # 注入后校验（占位符清零 + 关键 section 齐全）
    ok, missing = validate_report(html_string, require_ai_replacement=True)
    if ok:
        print("OK 报告校验通过")
    else:
        print(f"WARN 报告校验发现缺失: {', '.join(missing)}", file=sys.stderr)

    print(f"OK 报告已生成: {out_name}")
    print(f"   - 轮次数据: {len(data['rounds'])} 轮")
    print(f"   - 参数重要性: {len(data['importance'])} 个参数")
    print(f"   - AI 分析: {ai_source}")
    print("   - 打开方式: 用浏览器打开该 HTML 文件")


if __name__ == "__main__":
    main()
