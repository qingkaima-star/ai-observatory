#!/usr/bin/env python3
"""Tools/UIProbe/ab-report.py — 配对开销报告的汇总步骤（#92 装置第三格：报告只比截距）。

Owner: ws/rig（测量装置，不进产品 target）

────────────────────────────────────────────────────────────────────────────
为什么要有这个文件，而不是"跑完把两臂的 CPU% 减一下"：
  §13 那张表就是这么做的，于是首页那格 `434 vs 112 ms/tick` 被当成"本波让首页变贵 +3~+12 pt"
  收了。§14 用**同一批原始件**重算，主项是**窗口内被观测到的 agent 命令数**：
      Δcpu_s = −0.10 + 0.353 × events，r = 0.822（26 扇窗、三页、两臂通吃）
  四对 dashboard 的 Δcpu 比值 1.81/3.21/6.44/0.17 与窗口内事件数比值 3.3/1.76/7.2/0.30
  **四对同号**——包含 §13 因 load 丢掉的那一对（r5：A 8 笔 / B 27 笔 ⇒ A 反而便宜）。
  ⇒ 只要自变量不在表里，"总量"就会被当成"成本"比，而本产品的开销**按设计**随机器活动量增长
    （AGENTS §6）。这个文件把两件事分开：
      · **截距** = 一扇窗里与活动量无关的固定开销（引擎 tick + 前台重算）⇒ **归因只引用它**；
      · **斜率** = 每笔被观测事件摊走的成本 ⇒ **它不是被测构建的成本，不许参与归因**，
                   报告里明写这一句，因为它是这台机器上最容易顺手引用错的一列。

丢掉的对怎么办（§14 点名的两条纪律）：
  1. **两臂对称**：一对里任何一侧不合格 ⇒ 两侧一起不计。上一轮丢掉 dashboard r5 用的是
     "对内两臂 load 均值之差"这类**不对称**规则，而那一丢恰好把**唯一反号**的对丢掉了 ⇒
     剩下的三对同号，方向就被"造"了出来。
  2. **只允许一条理由**：静默前置闸不过（load 超闸 / 未开窗）。其它异常一律算仪器坏了，
     由驱动器当场中止，不在这张表里留"悄悄少一行"。
  丢掉的对**连同各自的事件数**一起列出来（取不到的写 `na(未开窗)`，绝不写 0）。

两种输入都吃：
  · 新：`Tools/UIProbe/ab-sweep.sh` 产的 `manifest.csv`（列 = measure-pages.sh 全列 + `pair`，
    活动量在 `events_delta` 等列里，墙钟在 `t0_epoch/t1_epoch/measured_wall_s`）。
  · 旧：§13 留下的 `tmp/ab-perf/manifest.tsv`（只有 `t0/t1` 与一行 CSV 读数，**没有活动量列**
    ⇒ 那正是它翻车的原因）。这种输入用 `--db-a/--db-b` 指到**各自副本库**，由
    `db-activity.sh --window` 从行时间戳回溯每窗活动量（库内是 ReferenceDate 秒，换算见那档）。

用法：
    python3 Tools/UIProbe/ab-report.py --manifest tmp/ab-sweep/manifest.csv
    python3 Tools/UIProbe/ab-report.py --manifest <§13 manifest.tsv> \\
        --db-a <臂A副本库或目录> --db-b <臂B副本库或目录> --inner-overhead 52
    … --json out.json            # 同一套数，机器读一份（回归系数别只活在人读表里）
退出码：0 出表且至少有一对合格；3 **一扇窗都没跑/合格对为 0** ⇒ 只出诊断、不作归因；
        2 输入坏了（缺列、库不可读、两臂一行都没有）。
"""
import argparse
import csv
import json
import math
import os
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DB_ACTIVITY = os.path.join(ROOT, "Tools", "UIProbe", "db-activity.sh")

# §13 那把原尺子的列序（2026-09-23 之前的 measure-pages.sh 表头，逐字照抄，不猜）。
# 只在"旧 manifest"路径上用；新路径按列名读，列序变了也不会错位。
OLD_CSV_HEADER = ["section", "window_title", "footprint_max_MB", "footprint_last_MB",
                  "footprint_peak_MB", "samples", "window_s", "cpu_pct",
                  "cputime_delta_s", "load_before", "load_after"]

NA = "na"


def fnum(v):
    """把表里的一个值变成 float；空/na/坏值一律 None（= 没测），**绝不变成 0.0**。"""
    if v is None:
        return None
    s = str(v).strip()
    if s in ("", NA, "n/a", "na(未开窗)"):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def load1_from_uptime(text):
    """从 `uptime` 原文里取 1 分钟负载首段（§13 的 manifest 只有 uptime）。"""
    import re
    m = re.search(r"load averages?:\s*([0-9]+(?:\.[0-9]+)?)", str(text or ""))
    return float(m.group(1)) if m else None


# ── 只读活动量回溯（旧 manifest 才需要）────────────────────────────────────
def win_events_via_db(db, t0, t1):
    """调 db-activity.sh 的 `--window` 档取该窗内的行增量。取不到 ⇒ None，不当 0。"""
    if not db or t0 is None or t1 is None:
        return None, None
    try:
        out = subprocess.run(["bash", DB_ACTIVITY, "--db", db, "--window", f"{int(t0)}:{int(t1)}"],
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return None, None
    kv = {}
    for ln in out.splitlines():
        if "=" in ln:
            k, _, v = ln.partition("=")
            kv[k.strip()] = v.strip()
    return fnum(kv.get("win_events")), fnum(kv.get("tick_cadence_s"))


def read_rows(path, db_by_arm, inner_overhead):
    """把两种 manifest 读成同一组行字典；任何缺失都是 None，不是 0。"""
    with open(path, newline="") as fh:
        head = fh.readline()
        fh.seek(0)
        old_format = "\t" in head and "csv_data_line" in head
        rows = []
        if old_format:
            for rec in csv.DictReader(fh, delimiter="\t"):
                if not (rec.get("round") or "").strip().isdigit():
                    continue
                data = dict(zip(OLD_CSV_HEADER, (rec.get("csv_data_line") or "").split(",")))
                t0, t1 = fnum(rec.get("t0")), fnum(rec.get("t1"))
                outer = None if t0 is None or t1 is None else t1 - t0
                ev, cad = win_events_via_db(db_by_arm.get((rec.get("arm") or "").strip()), t0, t1)
                rows.append(dict(
                    page=(rec.get("page") or "").strip(), arm=(rec.get("arm") or "").strip(),
                    round=int(rec["round"]), t0=t0, t1=t1,
                    measured_wall=None, outer_wall=outer,
                    wall=(None if outer is None else outer - inner_overhead),
                    dcpu=fnum(data.get("cputime_delta_s")), events=ev,
                    cadence=cad, load_before=load1_from_uptime(rec.get("uptime_before")),
                    load_after=load1_from_uptime(rec.get("uptime_after")),
                    gate="pass" if (rec.get("exit") or "").strip() == "0" else "fail",
                    fp_max=fnum(data.get("footprint_max_MB")),
                    nominal_window=fnum(data.get("window_s")),
                    pair=f'r{rec["round"]}-{(rec.get("page") or "").strip()}'))
        else:
            for rec in csv.DictReader(fh):
                page = (rec.get("section") or rec.get("page") or "").strip()
                arm = (rec.get("arm") or "").strip()
                if not page or not arm:
                    continue          # 表头行 / 驱动器写下的无身份行 ⇒ 整行不进统计
                t0, t1 = fnum(rec.get("t0_epoch")), fnum(rec.get("t1_epoch"))
                outer = None if t0 is None or t1 is None else t1 - t0
                wall = fnum(rec.get("measured_wall_s"))
                ev = fnum(rec.get("events_delta"))
                cad = fnum(rec.get("tick_cadence_s"))
                if ev is None and (arm in db_by_arm) and t0 is not None:
                    ev, cad2 = win_events_via_db(db_by_arm[arm], t0, t1)
                    cad = cad or cad2
                rows.append(dict(
                    page=page, arm=arm, round=int(fnum(rec.get("round")) or 0),
                    t0=t0, t1=t1, measured_wall=wall, outer_wall=outer, wall=wall,
                    dcpu=fnum(rec.get("cputime_delta_s")), events=ev, cadence=cad,
                    load_before=fnum(rec.get("load1_before")), load_after=fnum(rec.get("load1_after")),
                    gate=(rec.get("gate") or "pass").strip(),
                    fp_max=fnum(rec.get("footprint_max_MB")),
                    nominal_window=fnum(rec.get("window_s")),
                    pair=(rec.get("pair") or f'r{rec.get("round")}-{page}').strip()))
    return rows


# ── 回归件（stdlib 手算：装置不引第三方依赖，系数才经得起核对）────────────────
def ols_pair(xs, ys):
    """一元最小二乘 Δcpu ~ events ⇒ (截距, 斜率, r, n)。"""
    n = len(xs)
    if n < 3:
        return None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    syy = sum((y - my) ** 2 for y in ys)
    if sxx == 0:
        return None
    b = sxy / sxx
    a = my - b * mx
    r = sxy / math.sqrt(sxx * syy) if syy > 0 else float("nan")
    return dict(intercept=a, slope=b, r=r, n=n, mx=mx, my=my)


def ols_multiple(X, y):
    """多元最小二乘（正规方程 + 列主元消元）：y = Xβ。返回 β 列表或 None。"""
    k = len(X[0])
    if len(y) < k + 2:
        return None
    XtX = [[sum(X[i][a] * X[i][b] for i in range(len(X))) for b in range(k)] for a in range(k)]
    Xty = [sum(X[i][a] * y[i] for i in range(len(X))) for a in range(k)]
    m = [row[:] + [Xty[i]] for i, row in enumerate(XtX)]
    for c in range(k):
        p = max(range(c, k), key=lambda r: abs(m[r][c]))
        if abs(m[p][c]) < 1e-12:
            return None
        m[c], m[p] = m[p], m[c]
        for r in range(k):
            if r == c:
                continue
            f = m[r][c] / m[c][c]
            for cc in range(c, k + 1):
                m[r][cc] -= f * m[c][cc]
    return [m[i][k] / m[i][i] for i in range(k)]


def ms_per_tick(row):
    """ms/tick = Δcpu ÷ (内窗 ÷ 节奏)。节奏缺失退回名义 3 s 并**在列名里写明**。"""
    if row["dcpu"] is None or not row.get("wall"):
        return None, None
    cad = row.get("cadence") or 3.0
    return 1000.0 * row["dcpu"] / (row["wall"] / cad), "measured" if row.get("cadence") else "nominal3"


def qualify(row, ceiling):
    """一扇窗合不合格：**只有**「load 超闸 / 未开窗 / 活动量取不到」三条，且两臂同规则。"""
    if row["gate"] != "pass":
        return False, "未开窗（闸拦下）"
    if row["dcpu"] is None:
        return False, "Δcpu 读数缺失"
    if row["events"] is None:
        return False, "活动量取不到（na 不参与回归，也不当 0）"
    ls = [v for v in (row["load_before"], row["load_after"]) if v is not None]
    if not ls:
        return False, "load 读数缺失"
    if max(ls) >= ceiling:
        return False, f"load 超闸（max {max(ls):.2f} ≥ {ceiling}）"
    return True, ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--db-a", default="", help="臂 A 的副本库（或含 observatory.sqlite 的目录）——旧 manifest 回溯活动量用")
    ap.add_argument("--db-b", default="", help="臂 B 的副本库（或目录）")
    ap.add_argument("--load-ceiling", type=float, default=4.0, help="与 quiet-gate.sh 同一个默认值")
    ap.add_argument("--balance-ceiling", type=float, default=12.0, help="配平对照的事件数上限（§14 用的是 12）")
    ap.add_argument("--inner-overhead", type=float, default=52.0,
                    help="旧 manifest 只有外窗：内窗 = 外窗 − 本常数（5 启动 + 45 预热 + 2 收尾）")
    ap.add_argument("--json", default="", help="同一套数另存一份机器读的")
    a = ap.parse_args()

    def norm_db(p):
        if not p:
            return None
        if os.path.isdir(p):
            p = os.path.join(p, "observatory.sqlite")
        return p if os.path.exists(p) else None

    db_by_arm = {k: v for k, v in
                 (("a", norm_db(a.db_a)), ("b", norm_db(a.db_b))) if v}
    if not os.path.exists(a.manifest):
        print(f"❌ manifest 不存在：{a.manifest}", file=sys.stderr)
        return 2
    rows = read_rows(a.manifest, db_by_arm, a.inner_overhead)
    arms = sorted({r["arm"] for r in rows})
    if not rows or len(arms) < 2:
        print(f"❌ 表里读不到两臂的行（rows={len(rows)} arms={arms}）⇒ 配对报告无从谈起", file=sys.stderr)
        return 2

    for r in rows:
        ok, why = qualify(r, a.load_ceiling)
        r["ok"], r["why"] = ok, why
        r["mst"], r["cad_src"] = ms_per_tick(r)

    W = sys.stdout.write
    W(f"== 配对开销报告（manifest={os.path.relpath(a.manifest, ROOT)}）\n")
    W(f"   行 {len(rows)} · 臂 {arms} · 页 {sorted({r['page'] for r in rows})} · "
      f"静默闸上限 load_1m<{a.load_ceiling} · 配平上限 events≤{a.balance_ceiling:g}\n")

    W("\n== ① 逐窗台账（每行 = 一扇窗：页/臂/窗/Δcpu/活动量/load/合格与否）\n")
    W(f"{'对':<16}{'臂':<3}{'Δcpu_s':>8}{'events':>8}{'load前':>8}{'load后':>8}"
      f"{'内窗s':>7}{'ms/tick':>9}  合格\n")
    for r in rows:
        W(f"{r['pair']:<16}{r['arm']:<3}"
          f"{('%.2f' % r['dcpu']) if r['dcpu'] is not None else NA:>8}"
          f"{('%g' % r['events']) if r['events'] is not None else NA:>8}"
          f"{('%.2f' % r['load_before']) if r['load_before'] is not None else NA:>8}"
          f"{('%.2f' % r['load_after']) if r['load_after'] is not None else NA:>8}"
          f"{('%.0f' % r['wall']) if r['wall'] else NA:>7}"
          f"{('%.1f' % r['mst']) if r['mst'] is not None else NA:>9}  "
          f"{'✅' if r['ok'] else '⛔ ' + r['why']}\n")

    # ── ② 活动量 ↔ 开销：全样本回归（诊断用，两臂各一次 + 合并）
    W("\n== ② Δcpu ~ 窗口内 events（这是**诊断**：证明读数是被别人的活动推着走的）\n")
    diag = {}
    for name, sub in ([("全部", rows)] + [(f"臂 {arm}", [r for r in rows if r["arm"] == arm]) for arm in arms]):
        pts = [(r["events"], r["dcpu"]) for r in sub if r["events"] is not None and r["dcpu"] is not None]
        if not pts:
            W(f"   {name:<8} 无可用点\n"); continue
        g = ols_pair([x for x, _ in pts], [y for _, y in pts])
        diag[name] = g
        if g:
            W(f"   {name:<8} n={g['n']:>3}  Δcpu_s = {g['intercept']:+.3f} + {g['slope']:.3f} × events"
              f"   r={g['r']:.3f}  r²={g['r']**2:.3f}\n")
        else:
            W(f"   {name:<8} n={len(pts)} events 全相同 ⇒ 斜率不可估（这台机器这窗**零活动**）\n")
    W("   ⚠️ **斜率不参与归因**：它是「这一窗里每笔被观测事件摊走多少 CPU」，"
      "记的是被观测对象的活动，不是被测构建的成本（AGENTS §6）。\n")
    W("      允许引用的只有下面那张**截距**表。\n")

    # ── ③ 配对表：两臂对称，丢掉的对连事件数一起列
    W("\n== ③ 配对表（同一对里两臂共用一条规则：静默前置闸不过 ⇒ 整对不计）\n")
    bypair = {}
    for r in rows:
        bypair.setdefault(r["pair"], {})[r["arm"]] = r
    kept, dropped = [], []
    for pair, d in sorted(bypair.items()):
        if len(d) < 2:
            missing = [x for x in arms if x not in d]
            dropped.append((pair, "缺一臂（" + ",".join(missing) + "）⇒ 整对不计（对称）",
                            *(("%.0f" % d[x]["events"]) if x in d and d[x]["events"] is not None else NA for x in arms)))
            continue
        bad = [(arm, d[arm]["why"]) for arm in arms if not d[arm]["ok"]]
        if bad:
            arm, why = bad[0]
            dropped.append((pair, f"{why}（臂 {arm}）⇒ 整对不计（对称）",
                            *(("%.0f" % d[x]["events"]) if d[x]["events"] is not None else NA for x in arms)))
        else:
            kept.append(pair)
    W(f"{'对':<16}" + "".join(f"{('Δcpu_'+arm):>10}" for arm in arms)
      + "".join(f"{('events_'+arm):>11}" for arm in arms) + "  判定\n")
    for pair in kept:
        d = bypair[pair]
        W(f"{pair:<16}" + "".join(f"{d[x]['dcpu']:>10.2f}" for x in arms)
          + "".join(f"{('%g' % d[x]['events']):>11}" for x in arms) + "  ✅ 保留\n")
    for row in dropped:
        d = bypair.get(row[0], {})
        W(f"{row[0]:<16}"
          + "".join(f"{d[x]['dcpu']:>10.2f}" if x in d and d[x]["dcpu"] is not None else " " * 10 for x in arms)
          + "".join(f"{('%g' % d[x]['events']):>11}" if x in d and d[x]["events"] is not None else " " * 11 for x in arms)
          + f"  ⛔ {row[1]}\n")
    W(f"   保留 {len(kept)} 对 / 丢掉 {len(dropped)} 对（丢对理由只有「load 超闸 / 未开窗 / 缺一臂」三种，两臂同规则）\n")

    # ── ④ 归因表：只比截距
    W("\n== ④ 归因（**只比截距**：同活动量下每一窗的固定开销 = 引擎 tick + 前台重算）\n")
    att = {}
    usable = [r for r in rows if r["ok"]]
    for arm in arms:
        pts = [(r["events"], r["dcpu"]) for r in usable if r["arm"] == arm]
        g = ols_pair([x for x, _ in pts], [y for _, y in pts]) if len(pts) >= 3 else None
        att[f"arm_{arm}"] = g
        W(f"   合格窗内臂 {arm}：" + (
            f"n={g['n']} 截距 = {g['intercept']:+.3f} s/窗（斜率 {g['slope']:.3f} s/笔，仅列出不参与归因）"
            if g else f"合格窗不足 {max(0, min(3, len(pts)))} 扇（实得 {len(pts)}）⇒ 不可估"))
        W("\n")
    beta = None
    if len(usable) >= 6 and len(arms) == 2:
        X = [[1.0, r["events"], 1.0 if r["arm"] == arms[0] else 0.0] for r in usable]
        y = [r["dcpu"] for r in usable]
        beta = ols_multiple(X, y)
    if beta:
        med_wall = statistics.median([r["wall"] for r in usable if r["wall"]])
        W(f"   合并同活动量对照（哑变量臂项，n={len(usable)}）：\n"
          f"     Δcpu_s = {beta[0]:+.3f} + {beta[1]:.3f}×events + {beta[2]:+.3f}×[臂={arms[0]}]\n"
          f"     ⇒ **同事件数下臂 {arms[0]} 相对臂 {arms[1]} 的固定开销差 = {beta[2]:+.3f} s/窗"
          f"（按每窗 {med_wall:g} s / 名义 3 s 折算 ≈ {beta[2]*1000/(med_wall/3.0):+.0f} ms/tick）**\n")
    else:
        W("   合并对照不可估（合格窗 < 6 或臂数 ≠ 2）⇒ **合格窗里本轮不作归因**。\n")

    # 配平子集上的同一个回归：合格窗为 0 时（§13 那种场子）这是唯一还能给出的截距对照，
    # 但它**建在不合格窗上** ⇒ 只能当"下一步该在静默窗里复验什么"的线索，一句都不能进归因。
    bsub = [r for r in rows if r["events"] is not None and r["dcpu"] is not None
            and r["events"] <= a.balance_ceiling]
    if len(arms) == 2 and len({r["arm"] for r in bsub}) == 2:
        Xb = [[1.0, r["events"], 1.0 if r["arm"] == arms[0] else 0.0] for r in bsub]
        bb = ols_multiple(Xb, [r["dcpu"] for r in bsub])
        nb = {x: sum(1 for r in bsub if r["arm"] == x) for x in arms}
        W(f"\n   配平子集（events ≤ {a.balance_ceiling:g}，n={len(bsub)} = "
          + " + ".join(f"{k}:{v}" for k, v in nb.items())
          + "）上的同活动量截距对照 —— ⚠️ 建在**不合格窗**上，只作线索，不得进归因：\n")
        if bb:
            W(f"     Δcpu_s = {bb[0]:+.3f} + {bb[1]:.3f}×events + {bb[2]:+.3f}×[臂={arms[0]}]"
              f"  ⇒ 截距差 {bb[2]:+.3f} s/窗（臂 {arms[0]} {'更低' if bb[2] < 0 else '更高'}）\n")
        else:
            W("     子集里活动量太集中 ⇒ 截距差**不可估**（「配平后没有分辨力」不等于「两臂相同」）\n")

    # ── ⑤ 配平对照（§14 的口径：把活动量压到 ≤N 笔/窗再比每 tick 固定开销）
    W(f"\n== ⑤ 配平后的每 tick 固定开销对照（events ≤ {a.balance_ceiling:g}；§14 用的就是这一档）\n")
    balanced = {}
    for arm in arms:
        vals = sorted(round(r["mst"]) for r in rows
                      if r["arm"] == arm and r["mst"] is not None
                      and r["events"] is not None and r["events"] <= a.balance_ceiling)
        balanced[arm] = vals
        W(f"   臂 {arm}: {vals}" + (f"  中位 {statistics.median(vals):g} ms/tick" if vals else "  （无满足条件的窗）") + "\n")
    if len(arms) == 2 and all(balanced.values()):
        d = statistics.median(balanced[arms[0]]) - statistics.median(balanced[arms[1]])
        W(f"   ⇒ 配平后 {arms[0]}−{arms[1]} 中位差 {d:+g} ms/tick（{arms[0]} "
          f"{'更低' if d < 0 else '更高' if d > 0 else '相同'}）；两臂取到的窗数不等（{len(balanced[arms[0]])} vs "
          f"{len(balanced[arms[1]])}）⇒ 这一格是**对照**，不是配对，别当验收。\n")
    W("   ⚠️ 配平靠「少几笔事件」换来，不是靠「没有事件」：残留的活动量差仍会进均值。\n")

    # ── ⑥ 丢掉的对（必须列出来，连事件数）
    W("\n== ⑥ 被丢掉的对（连各自事件数一起；上一轮的教训：丢掉的那对恰好是唯一反号的那对）\n")
    if not dropped:
        W("   （无）\n")
    for row in dropped:
        W(f"   {row[0]}：{row[1]}；事件数 " + " / ".join(f"{arms[i]}={row[2+i]}" for i in range(len(arms))) + "\n")
    # 反号一览：把每一对的差值符号摊开，免得"挑同号的对讲故事"
    if len(arms) == 2:
        signs = {}
        for pair in kept + [d[0] for d in dropped]:
            dd = bypair.get(pair, {})
            if len(dd) == 2 and all(dd[x]["dcpu"] is not None for x in arms):
                s = f"{arms[0]}>{arms[1]}" if dd[arms[0]]["dcpu"] > dd[arms[1]]["dcpu"] else f"{arms[0]}<{arms[1]}"
                signs.setdefault(s, []).append(pair)
        W(f"   全部 {len(arms)} 臂对的符号分布（含被丢掉的）：{ {k: v for k, v in signs.items()} }\n")
        W("   ⇒ 若某一符号**只出现在被丢掉的那一侧**，那这条方向结论不成立（本轮就是这种形状）。\n")

    # ── ⑦ 限制声明
    W("\n== ⑦ 读这张表之前\n")
    W("   · 截距 = 每窗固定开销（引擎 tick + 前台重算）；**引擎 tick 与前台重算再分一档见"
      "`family-sample.sh` / `turn-trace.sh` 两列**（引擎族帧头 vs UI 族帧头），不在这份表里。\n")
    W("   · 遮挡法不是分离器：它只判「有没有合成」，判不了「有没有重算」（§13.7 已吃过）。\n")
    W("   · 合格对为 0 的场子里，本文件的一切数字都只是「这台机器当时」的读数，"
      "与臂无关、与构建无关。\n")

    if a.json:
        with open(a.json, "w") as fh:
            json.dump(dict(manifest=os.path.abspath(a.manifest), load_ceiling=a.load_ceiling,
                           balance_ceiling=a.balance_ceiling, arms=arms,
                           regression_diag={k: v for k, v in diag.items()},
                           attribution=att, pooled_beta=beta,
                           balanced={k: v for k, v in balanced.items()},
                           kept=kept, dropped=[list(x) for x in dropped],
                           rows=rows), fh, ensure_ascii=False, indent=1)
        print(f"   机器读的一份：{a.json}", file=sys.stderr)

    if not kept:
        W("\n⛔ 合格对 = 0 ⇒ 只出诊断，不出归因（这不是「达标」，也不是「超标」，是「没测」）。\n")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
