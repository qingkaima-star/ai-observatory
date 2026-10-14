//
//  Columns.swift
//  AIObservatoryUI / DesignSystem
//
//  Owner: ws/consistency（批 3 · #83 表格与数字列对齐）
//  ─────────────────────────────────────────────────────────
//  **列表/表格里列宽与对齐的唯一档位源**（与 `Spacing`、`Sizing` 同族）。
//
//  【治的病：四页各一档、互不同名】本仓没有 `Table`/`LabeledContent`，
//  列对齐全靠 `HStack + .frame(width:)` 手搓。改之前实测到的是这个样子：
//    · `TimelineEventRow`        62 / 104 / 16 / 240
//    · `PerformanceSessionBreakdown`  82 / 60 / 78
//    · `DashboardActiveAgentsList`    三列同 88，数字却 `.leading`
//    · `ProjectHotFilesPanel`         rank 20 `.trailing`
//    · `CommandAuditRow` / `FileChangeRow` / `RiskEventRow`
//      三个数字列**根本没有定宽**，只靠 `Spacer` 推右 ⇒ 同一列在行间是锯齿状的
//  两个同名的东西（"时间列"）在两张表里差 20pt，两个不同名的东西（`readoutColumnWidth`
//  与 `cpuColumnWidth`）说的却是同一件事。这就是"表格看着不规整"的字面来源。
//
//  【口径（台账 整改波次-2026-09-22 第六节 C / #83）】
//  ① 列宽只从这里取；页内允许留自己的**语义别名**（如 `TimelineMetrics.timeColumnWidth`），
//     但别名必须等于本文件的某一档，不许再出现第三个数。
//  ② 数字一律 `monospacedDigit` + **同一对齐方向**（一律 `.trailing`：等宽数字末位对齐
//     才叫成列，左对齐只把小数点前的位数差暴露成锯齿）。
//     "数字列"的射程不止那七张行表：**任何**「定宽 + 末位对齐」的那一格都算
//     （菜单栏读数、diff 的行号列都是），所以用例 ⑥ 是全 UI 扫描、零豁免。
//  ③ **不引入 `Table`**：那要重写每页的取数路径（分页、上限、排序都在查询里），
//     属于扩大范围。这一档只是把已有手搓列收成一处。
//
//  ⚠️ 档位不够用时优先怀疑"这一列在装两种东西"：`duration` 与 `memory` 分开是因为
//  "12h47m" 与 "1.16 GB" 最长串不同；把它们并成一个"大数档"会让窄的那列白占位。
//

import SwiftUI

/// 列表与表格的列宽档位。命名与 `Spacing` 同族：只有语义，没有页名。
enum Column {
    /// 等宽时间列：`HH:mm:ss`（`axMeta` / `axMetaMono` 两种字号都放得下）。
    static let time: CGFloat = 68
    /// Agent 身份列：图标 + 产品名。
    /// 104 → 132 是 **#82 的账**：紧凑态不再切首词之后，最长的那一个
    /// （"OpenAI Codex CLI"）必须在列里完整站下，否则只是把"即兴截断"换成"即兴省略"。
    static let agentIdentity: CGFloat = 132
    /// 单个 SF Symbol 的图标列。
    static let glyph: CGFloat = 16
    /// 排名列（"1"…"12"）。
    static let rank: CGFloat = 24
    /// 纯计数列（"26"、"142"），以及 diff 的**行号列**（统一视图两格 + 并排视图一格共用）。
    /// 行号不另起一档是算过的：44pt 在 12pt 等宽字下装到 6 位数，与计数列同一容量，
    /// 再起一档就是"12 个数装 11 件事"（#83 的反面是档数失控，不是收不干净）。
    /// 行号从 36 提到 44 是复核补的洞：同一个东西在同一个文件的两种排法里差 8pt，
    /// 就是台账说的"两个同名的东西各写各的"。
    static let count: CGFloat = 44
    /// 百分比列（"100.0%"）。
    static let percent: CGFloat = 60
    /// 时长列（"12h47m"、"3.4s"）。
    static let duration: CGFloat = 64
    /// 内存列（"1.16 GB"）。
    static let memory: CGFloat = 72
    /// 增删行数列（"+612 -188"）。
    static let delta: CGFloat = 84
    /// 退出码列（"exit 128"）。
    static let exitCode: CGFloat = 56
    /// 标题右侧「补充线索」列的**上限**（文件名 / 命令首行 / 摘要三选一）。
    /// 封顶的意义：尾部那些状态类读数才始终落在同一条竖线上。
    static let detail: CGFloat = 240

    /// 全部档位，**给门禁数的**（`ColumnAlignmentTests` ⑦）。
    /// 加一档必须同时在这里列出，并且写清"为什么不能复用既有那一档"——
    /// #83 的反面不是"没收干净"，是"12 个数装 11 件事"。
    static let allTiers: [CGFloat] = [
        time, agentIdentity, glyph, rank, count, percent, duration, memory, delta, exitCode, detail,
    ]
}

// MARK: - 列修饰符

extension View {
    /// 数字列：**等宽数字 + 右端对齐 + 定宽**。
    ///
    /// 这一颗是 #83 的全部口径压在一个修饰符里：对齐方向不再由调用点决定，
    /// 所以"这一页数字左对齐、那一页右对齐"在写法上就不成立了。
    /// `monospacedDigit()` 放在这里而不是每个调用点：漏一处的表现是
    /// "9 与 1 对不齐"，那是只有实拍才看得见的缺陷。
    func axNumberColumn(_ width: CGFloat) -> some View {
        self.monospacedDigit()
            .frame(width: width, alignment: .trailing)
    }

    /// 文本 / 时间列：定宽、左对齐（读的顺序就是它的顺序）。
    func axLeadingColumn(_ width: CGFloat) -> some View {
        self.frame(width: width, alignment: .leading)
    }

    /// 图标列：定宽、居中（居中是"符号挂在一行文字中间"那一档，不是数字的档）。
    func axGlyphColumn(_ width: CGFloat) -> some View {
        self.frame(width: width, alignment: .center)
    }
}
