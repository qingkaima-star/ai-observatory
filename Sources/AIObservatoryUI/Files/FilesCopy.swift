//
//  FilesCopy.swift
//  AIObservatoryUI / Files
//
//  Owner: WS-l10n（B3 后半 · 文件目录）
//  ─────────────────────────────────────────────────────────
//  文件目录的用户可见文案，**一个目录一张表**（形状与已合入的
//  `SessionsBilingualCopyGateTests` / `DashboardBilingualCopyGateTests` 一致：
//  UI 只有一个 target，共享一张表会与并行车道在同一个数组里撞行）。
//
//  本表目前覆盖 `FileChangeRow.swift`（变更类型标签 + 那一行的增删/风险摘要）。
//  文件页其余口径长句（「采集面：正在监控 N 个根 · 剔除 M 条…」「服务端匹配总数 · 与分页无关」
//  「这里没有记录，不等于没有发生」）**还没进来**——它们有用例逐字钉着，
//  必须和那些用例同一笔改（改成显式传语言取表），不能先改文案再回头补断言。
//
//  大小写按 uicopy 定的口径：HIG 句首大写（标签用 Created 这类词首大写，不整句大写）。
//

import Foundation
import AIObservatoryCore

/// 文件目录的用户可见文案表。
enum FilesCopy {

    /// 变更类型标签。英文用 macOS 文件列表的惯用词（Created / Deleted / Renamed / Modified），
    /// 不用 "New"（那是形容词，和旁边三个过去分词不成一类）。
    static let kindCreated = LocalizedString(zh: "新建", en: "Created")
    static let kindDeleted = LocalizedString(zh: "删除", en: "Deleted")
    static let kindRenamed = LocalizedString(zh: "重命名", en: "Renamed")
    static let kindModified = LocalizedString(zh: "修改", en: "Modified")

    /// 一行的增删摘要。中文用「新增 N 行，删除 M 行」，英文保持同样的信息顺序，
    /// 不改成 "M removed / N added"——那一行右边就是 diff 数字，顺序变了要对齐两次。
    static let lineDelta = LocalizedString(zh: "新增 %1$@ 行，删除 %2$@ 行",
                                           en: "Lines added %1$@, removed %2$@")
    static let riskPrefix = LocalizedString(zh: "风险 %1$@", en: "Risk %1$@")

    /// 同一段里各分句的连接符。中文是全角逗号，英文必须是 `, `——
    /// 留着 `，` 会让英文那行挂满全角标点。
    static let clauseJoiner = LocalizedString(zh: "，", en: ", ")

    /// diff 呈现模式的两个分段标签（`FilesDiffViewMode.displayName`）。
    /// 英文用句首大写、不整句大写（HIG）；`Side by side` 不写成 `Split View`——
    /// 旁边那颗分段控件已经是"视图"，再出现 View 就是同一个词说两遍。
    static let viewModeUnified = LocalizedString(zh: "统一", en: "Unified")
    static let viewModeSideBySide = LocalizedString(zh: "并排", en: "Side by side")

    /// 「有 diff 却一行都不显示」的三档成因（`FileLineDeltaReader.message`）。
    /// 三句的分工是语义红线：**偶发漏采**、**这一类结构上拿不到**、**连类型都不知道**，
    /// 任何两句合并都会让界面替没发生的事编理由，所以三条各自一条、不做通用模板。
    static let diffMissingCaptureMissed = LocalizedString(
        zh: "该变更没有可显示的文本 diff：可能是快照未捕获、文件已被清理，或改动发生在引擎启动之前。",
        en: "This change has no text diff to show: the snapshot may not have been captured,"
          + " the file may have been cleaned up, or the change happened before the engine started."
    )
    static let diffMissingNoNewContent = LocalizedString(
        zh: "该变更没有改动后的内容（删除与重命名不产生新内容），所以不存在逐行 diff"
          + "——这是变更类型决定的，不是这次没采到。",
        en: "This change has no resulting content — deletions and renames do not produce new content —"
          + " so there is no line-by-line diff. That follows from the kind of change,"
          + " it is not a missed capture."
    )
    static let diffMissingKindUnknown = LocalizedString(
        zh: "该变更没有可显示的文本 diff，且变更类型未知，无法判断应当有没有差异。",
        en: "This change has no text diff to show, and its kind is unknown,"
          + " so we cannot tell whether a diff should exist."
    )

    /// 逐行列表自己的空态，以及并排视图的两栏标题。
    /// 标题英文用 `Before` / `After`：`DiffBaselineReadout` 那几句里已经用 "Before =" 讲对比基准，
    /// 同一屏不该给同一个概念第二个名字。
    static let diffListEmptyTitle = LocalizedString(zh: "没有可显示的差异", en: "No differences to show")
    static let diffListEmptyMessage = LocalizedString(
        zh: "该变更没有记录到文本 diff（可能是二进制文件或采集已被隐私策略关闭）。",
        en: "This change has no text diff recorded — it may be a binary file,"
          + " or capture is switched off by the privacy policy."
    )
    static let diffSideBefore = LocalizedString(zh: "修改前", en: "Before")
    static let diffSideAfter = LocalizedString(zh: "修改后", en: "After")

    /// 「Before 是哪份」的四档说法（`DiffBaselineReader.message`）。
    /// `.compared` 带一个时刻参数：口径函数不自己格式化日期（那是另一把尺子），
    /// 所以参数按位置消费，英文侧语序不同也不会错位。
    static let baselineCompared = LocalizedString(
        zh: "Before = 与 %1$@ 观测到的版本对比（不是「Agent 动手前一刻」——那是事后拿不到的信息）。",
        en: "Before = compared with the version observed at %1$@ — not the moment before the agent"
          + " acted, which is information we cannot retrieve after the fact."
    )
    static let baselineComparedWithoutTimestamp = LocalizedString(
        zh: "Before = 与上一次观测到的版本对比（该次观测的时刻没有被记下来）。",
        en: "Before = compared with the previously observed version (the time of that observation"
          + " was not recorded)."
    )
    static let baselineFirstSighting = LocalizedString(
        zh: "首次观测到该文件，无改前版本可比；下面是单边 diff，当前内容全部按新增呈现。",
        en: "First time this file was observed, so there is no earlier version to compare with."
          + " The diff below is one-sided: all current content is shown as added."
    )
    static let baselineNotApplicable = LocalizedString(
        zh: "该变更没有改动后的内容（删除或重命名），因此不存在逐行差异。",
        en: "This change has no resulting content (it is a deletion or a rename),"
          + " so there is no line-by-line diff."
    )

    /// 「有 diff 记录却一行都不显示」的两种成因（`emptyLinesMessage`）。
    /// 说错方向的代价不对称：把"用户关了明文"说成"没有行级差异"，用户以为 Agent 什么都没改；
    /// 反过来则以为自己的开关坏了。所以两条各自一条，不共用模板。
    static let emptyLinesCapturedEmpty = LocalizedString(
        zh: "捕获到的 diff 为空：文件内容可能只有元数据或权限变化。",
        en: "The captured diff is empty: the file may have only metadata or permission changes."
    )
    static let emptyLinesPlaintextOff = LocalizedString(
        zh: "明文已按设置关闭：这里只保留增删统计与内容指纹，不保留逐行正文。",
        en: "Plaintext storage is switched off in settings: only line counts and a content"
          + " fingerprint are kept, not the text of each line."
    )

    // MARK: 采集面那一行与空态口径（`CaptureScope` / `CaptureAvailability`）
    //
    // 英文侧一律避开「数字紧跟复数名词」——本仓那把尺子（`B3PageCopyGate.pluralTrapNames`）
    // 会拦 `%1$d roots`，而拦它不是洁癖：英文没有复数机制，`1 roots` 只能靠写法避免。
    // 所以计数段落都写成 `标签: %1$d`，与已合入的 `Roots: %1$d · Projects: %2$d` 同一形状。
    //
    // ⚠️ 括号与冒号也进表：中文侧是全角 `（）``：`，英文侧必须是半角加空格——
    // 留着全角就是英文句子里挂满中文标点（`clauseJoiner` 同一个理由）。
    // 但**剔除原因那几个词**（`过浅：受保护根` 等）来自 §3 契约的
    // `MonitoringScope.Dropped.Reason.displayName`，界面这边换不掉 ⇒ 英文态那一行仍会夹中文，
    // 已作为 ICR 交回总控，不在这里偷偷复刻一份（复刻就是两把尺子）。

    static let coverageNoReading = LocalizedString(
        zh: "采集面：尚无采集面读数（引擎还没解析过任何一轮） · 本页范围 %1$@",
        en: "Capture: no scope reading yet (the engine has not resolved a pass)"
          + " · this page: %1$@"
    )
    static let coverageRoots = LocalizedString(zh: "采集面：正在监控 %1$d 个根",
                                               en: "Capture: roots watched %1$d")
    static let coverageDroppedNone = LocalizedString(zh: "剔除 0 条", en: "Excluded: 0")
    static let coverageRange = LocalizedString(zh: "本页范围 %1$@", en: "This page: %1$@")
    static let coverageResolved = LocalizedString(zh: "实况于 %1$@ 解析", en: "Resolved at %1$@")
    static let droppedList = LocalizedString(zh: "剔除 %1$d 条：%2$@", en: "Excluded %1$d: %2$@")
    static let droppedListWithMore = LocalizedString(
        zh: "剔除 %1$d 条：%2$@…另 %3$d 条",
        en: "Excluded %1$d: %2$@ … %3$d more not listed"
    )
    static let droppedEntry = LocalizedString(zh: "%1$@（%2$@）", en: "%1$@ (%2$@)")
    static let droppedNameJoiner = LocalizedString(zh: "、", en: ", ")
    static let droppedRuleColon = LocalizedString(zh: "：", en: ": ")

    static let headlineNotCollecting = LocalizedString(zh: "引擎没有在采集",
                                                       en: "The engine is not collecting")
    static let headlineNothingInScope = LocalizedString(zh: "这一页没有文件变更记录",
                                                        en: "No file changes on this page")
    static let explanationNotCollecting = LocalizedString(
        zh: "引擎当前是「%1$@」，没有在采集，所以这段时间不会有新的文件变更记录。",
        en: "The engine is currently \"%1$@\", so no new file changes are collected in that time."
    )
    /// 空态最后那句盲区声明。中文用 ` ⇒ `，英文用 ` — `：
    /// 箭头本身不是中文，但两边语感不同，写死一个就会有一边读起来怪。
    static let blindSpotSuffix = LocalizedString(
        zh: " ⇒ 这里没有记录，不等于没有发生。",
        en: " — no record here does not mean nothing happened."
    )

    // MARK: Diff 面板（`DiffView`）
    //
    // 无障碍标签单独一条，不复用可见那句：可见行为了塞进一行把信息压成「行数未采集 · 变更后 12 KB」，
    // 而读屏那句要成句。两者共用一条必然有一边将就。

    static let diffPickerView = LocalizedString(zh: "视图", en: "View")
    static let diffTruncated = LocalizedString(
        zh: "内容较大，引擎只保留了部分 diff（已截断）。",
        en: "The content is large, so the engine kept only part of the diff (truncated)."
    )
    static let diffRenamedFrom = LocalizedString(zh: "从 %1$@", en: "From %1$@")
    static let diffLinesNotCaptured = LocalizedString(
        zh: "行数未采集 · 变更后 %1$@",
        en: "Line counts not captured · now %1$@"
    )
    static let diffLinesNotCapturedA11y = LocalizedString(
        zh: "行数变化未采集，变更后大小 %1$@",
        en: "Line changes were not captured; the size after the change is %1$@"
    )
    /// #81：diff 面板那颗「在时间线看这一条」（这一条变更的取证出口）。
    static let diffJumpToTimeline = LocalizedString(
        zh: "在时间线看这一条",
        en: "See this change in timeline"
    )
    static let diffGenerating = LocalizedString(zh: "正在生成 diff…", en: "Building diff…")
    static let diffNoTextTitle = LocalizedString(zh: "没有可显示的文本 diff",
                                                 en: "No text diff to show")
    static let diffBinaryTitle = LocalizedString(zh: "二进制文件", en: "Binary file")
    static let diffBinaryMessage = LocalizedString(
        zh: "该文件不是文本文件，无法逐行对比。变更大小 %1$@。",
        en: "This file is not text, so it cannot be compared line by line. Change size %1$@."
    )
    static let diffPickChangeTitle = LocalizedString(zh: "选择一条文件变更",
                                                     en: "Select a file change")
    static let diffPickChangeMessage = LocalizedString(
        zh: "在左侧列表中点选任意一次变更，这里会显示它的逐行 diff。",
        en: "Pick any change in the list on the left; its line-by-line diff appears here."
    )
    static let diffNoLineChanges = LocalizedString(zh: "没有行级差异", en: "No line-level differences")

    // MARK: 筛选条（`FilesFilterBar`）
    //
    // 两个"选中几类"的汇总写法：中文是「N 种类型」「N 个 Agent」，
    // 英文不能照抄成 `%1$d types` / `%1$d agents`（英文没有复数机制，`1 agents` 只能靠写法避免，
    // 那把尺子拦的就是这个）⇒ 一律写成 `标签 · %1$d`，与已合入的 `Roots: %1$d` 同一形状。
    static let filterTimeRangeA11y = LocalizedString(zh: "时间范围", en: "Time range")
    static let filterAllKinds = LocalizedString(zh: "全部类型", en: "All types")
    static let filterKindFallback = LocalizedString(zh: "类型", en: "Type")
    static let filterKindsSummary = LocalizedString(zh: "%1$d 种类型", en: "Types · %1$d")
    static let filterKindsA11y = LocalizedString(zh: "变更类型", en: "Change type")
    static let filterAllAgents = LocalizedString(zh: "全部 Agent", en: "All agents")
    static let filterAgentsSummary = LocalizedString(zh: "%1$d 个 Agent", en: "Agents · %1$d")
    static let filterAgentsA11y = LocalizedString(zh: "Agent 类型", en: "Agent type")
    static let filterSensitiveOnly = LocalizedString(zh: "只看敏感路径", en: "Sensitive paths only")
    static let filterDiffModeA11y = LocalizedString(zh: "Diff 视图模式", en: "Diff view mode")
    static let filterSearchPath = LocalizedString(zh: "搜索文件路径…", en: "Search file paths…")
    static let filterClearSearchA11y = LocalizedString(zh: "清空搜索", en: "Clear search")
    static let filterReset = LocalizedString(zh: "重置", en: "Reset")

    // MARK: 文件页骨架（`FilesView`：hero、指标区、加载 / 空态 / 错误）
    //
    // 「共 N 个变更」英文写成 `%2$d in total`，不写 `%2$d changes`（复数陷阱，同筛选条那两条的理由）。
    // 「修改」那一格**复用** `kindModified`：它和列表行里的类型标签是同一个词，两条同文本就是两把尺子。
    static let heroSubtitle = LocalizedString(zh: "%1$@ · 共 %2$d 个变更", en: "%1$@ · %2$d in total")
    static let loadMore = LocalizedString(zh: "加载更多", en: "Load more")
    static let reload = LocalizedString(zh: "重新读取", en: "Reload")
    static let linesAddedTotal = LocalizedString(zh: "累计 +", en: "Total +")
    static let linesRemovedTotal = LocalizedString(zh: "累计 −", en: "Total −")
    static let dedupeNotice = LocalizedString(
        zh: "分类型各格都按路径去重，且这里只列新建 / 删除 / 修改三类（重命名不单独成格）："
          + "少一类会让相加偏小，而同一文件命中多类会让相加偏大，"
          + "所以三格相加通常不等于上面的总数——那个总数是本页全部事件按路径去重的结果。",
        en: "Each category tile is deduplicated by path, and only created / deleted / modified get"
          + " their own tile (renames do not): leaving a category out makes the sum too small, while"
          + " one file matching several categories makes it too large — so the three rarely add up to"
          + " the total above, which is every event on this page deduplicated by path."
    )
    static let tileTotalTitle = LocalizedString(zh: "变更文件总数", en: "Files changed")
    static let tileTotalCaption = LocalizedString(
        zh: "已加载 %1$d 条事件去重 · %2$@",
        en: "Events loaded: %1$d · %2$@"
    )
    static let tileCreatedTitle = LocalizedString(zh: "新建文件", en: "Files created")
    static let tileCreatedCaption = LocalizedString(
        zh: "本次范围新建过的文件 · 按路径去重",
        en: "Files created in this range · deduplicated by path"
    )
    static let tileDeletedTitle = LocalizedString(zh: "删除文件", en: "Files deleted")
    static let tileDeletedCaption = LocalizedString(
        zh: "本次范围删掉的文件 · 按路径去重",
        en: "Files deleted in this range · deduplicated by path"
    )
    static let tileSensitiveTitle = LocalizedString(zh: "敏感路径命中", en: "Sensitive paths")
    static let tileSensitiveCaption = LocalizedString(
        zh: "落在敏感目录内的变更",
        en: "Changes inside sensitive directories"
    )
    static let loadingMore = LocalizedString(zh: "正在载入更多变更…", en: "Loading more changes…")
    static let loadingInitial = LocalizedString(zh: "正在读取文件变更…", en: "Reading file changes…")
    static let loadingHint = LocalizedString(
        zh: "首次进入会聚合本范围内的文件改动与 diff。",
        en: "The first visit aggregates file changes and diffs in this range."
    )
    static let rescanNow = LocalizedString(zh: "立即重新扫描", en: "Rescan now")
    static let noSensitiveTitle = LocalizedString(zh: "没有敏感路径的变更",
                                                  en: "No sensitive-path changes")
    static let noSensitiveMessage = LocalizedString(
        zh: "当前已加载的变更都不在敏感目录内，关闭「只看敏感路径」即可查看全部。",
        en: "None of the loaded changes are inside a sensitive directory;"
          + " turn off Sensitive paths only to see everything."
    )
    static let closeSensitiveFilter = LocalizedString(zh: "关闭敏感过滤",
                                                      en: "Turn off the sensitive filter")
    static let loadFailedHeader = LocalizedString(zh: "文件变更加载失败",
                                                  en: "Could not load file changes")
    static let retry = LocalizedString(zh: "重试", en: "Retry")

    // MARK: row 组文案（7 条，key 前缀 row.*）
    static let rowCopy: [NamedCopy] = [
        NamedCopy("files.row.kind.created", kindCreated),
        NamedCopy("files.row.kind.deleted", kindDeleted),
        NamedCopy("files.row.kind.renamed", kindRenamed),
        NamedCopy("files.row.kind.modified", kindModified),
        NamedCopy("files.row.lineDelta", lineDelta),
        NamedCopy("files.row.riskPrefix", riskPrefix),
        NamedCopy("files.row.clauseJoiner", clauseJoiner),
    ]

    // MARK: viewMode 组文案（2 条，key 前缀 viewMode.*）
    static let viewModeCopy: [NamedCopy] = [
        NamedCopy("files.viewMode.unified", viewModeUnified),
        NamedCopy("files.viewMode.sideBySide", viewModeSideBySide),
    ]

    // MARK: diffMissing 组文案（3 条，key 前缀 diffMissing.*）
    static let diffMissingCopy: [NamedCopy] = [
        NamedCopy("files.diffMissing.captureMissed", diffMissingCaptureMissed),
        NamedCopy("files.diffMissing.noNewContent", diffMissingNoNewContent),
        NamedCopy("files.diffMissing.kindUnknown", diffMissingKindUnknown),
    ]

    // MARK: diffList 组文案（4 条，key 前缀 diffList.*）
    static let diffListCopy: [NamedCopy] = [
        NamedCopy("files.diffList.emptyTitle", diffListEmptyTitle),
        NamedCopy("files.diffList.emptyMessage", diffListEmptyMessage),
        NamedCopy("files.diffList.side.before", diffSideBefore),
        NamedCopy("files.diffList.side.after", diffSideAfter),
    ]

    // MARK: baseline 组文案（4 条，key 前缀 baseline.*）
    static let baselineCopy: [NamedCopy] = [
        NamedCopy("files.baseline.compared", baselineCompared),
        NamedCopy("files.baseline.comparedWithoutTimestamp", baselineComparedWithoutTimestamp),
        NamedCopy("files.baseline.firstSighting", baselineFirstSighting),
        NamedCopy("files.baseline.notApplicable", baselineNotApplicable),
    ]

    // MARK: emptyLines 组文案（2 条，key 前缀 emptyLines.*）
    static let emptyLinesCopy: [NamedCopy] = [
        NamedCopy("files.emptyLines.capturedEmpty", emptyLinesCapturedEmpty),
        NamedCopy("files.emptyLines.plaintextOff", emptyLinesPlaintextOff),
    ]

    // MARK: coverage 组文案（10 条，key 前缀 coverage.*）
    static let coverageCopy: [NamedCopy] = [
        NamedCopy("files.coverage.noReading", coverageNoReading),
        NamedCopy("files.coverage.roots", coverageRoots),
        NamedCopy("files.coverage.droppedNone", coverageDroppedNone),
        NamedCopy("files.coverage.range", coverageRange),
        NamedCopy("files.coverage.resolved", coverageResolved),
        NamedCopy("files.coverage.droppedList", droppedList),
        NamedCopy("files.coverage.droppedListWithMore", droppedListWithMore),
        NamedCopy("files.coverage.droppedEntry", droppedEntry),
        NamedCopy("files.coverage.nameJoiner", droppedNameJoiner),
        NamedCopy("files.coverage.ruleColon", droppedRuleColon),
    ]

    // MARK: empty 组文案（4 条，key 前缀 empty.*）
    static let emptyCopy: [NamedCopy] = [
        NamedCopy("files.empty.headlineNotCollecting", headlineNotCollecting),
        NamedCopy("files.empty.headlineNothingInScope", headlineNothingInScope),
        NamedCopy("files.empty.explanationNotCollecting", explanationNotCollecting),
        NamedCopy("files.empty.blindSpotSuffix", blindSpotSuffix),
    ]

    // MARK: diff 组文案（13 条，key 前缀 diff.*）
    static let diffCopy: [NamedCopy] = [
        NamedCopy("files.diff.pickerView", diffPickerView),
        NamedCopy("files.diff.truncated", diffTruncated),
        NamedCopy("files.diff.renamedFrom", diffRenamedFrom),
        NamedCopy("files.diff.linesNotCaptured", diffLinesNotCaptured),
        NamedCopy("files.diff.linesNotCapturedA11y", diffLinesNotCapturedA11y),
        NamedCopy("files.diff.jumpToTimeline", diffJumpToTimeline),
        NamedCopy("files.diff.generating", diffGenerating),
        NamedCopy("files.diff.noTextTitle", diffNoTextTitle),
        NamedCopy("files.diff.binaryTitle", diffBinaryTitle),
        NamedCopy("files.diff.binaryMessage", diffBinaryMessage),
        NamedCopy("files.diff.pickChangeTitle", diffPickChangeTitle),
        NamedCopy("files.diff.pickChangeMessage", diffPickChangeMessage),
        NamedCopy("files.diff.noLineChanges", diffNoLineChanges),
    ]

    // MARK: filter 组文案（13 条，key 前缀 filter.*）
    static let filterCopy: [NamedCopy] = [
        NamedCopy("files.filter.timeA11y", filterTimeRangeA11y),
        NamedCopy("files.filter.allKinds", filterAllKinds),
        NamedCopy("files.filter.kindFallback", filterKindFallback),
        NamedCopy("files.filter.kindsSummary", filterKindsSummary),
        NamedCopy("files.filter.kindsA11y", filterKindsA11y),
        NamedCopy("files.filter.allAgents", filterAllAgents),
        NamedCopy("files.filter.agentsSummary", filterAgentsSummary),
        NamedCopy("files.filter.agentsA11y", filterAgentsA11y),
        NamedCopy("files.filter.sensitiveOnly", filterSensitiveOnly),
        NamedCopy("files.filter.diffModeA11y", filterDiffModeA11y),
        NamedCopy("files.filter.searchPath", filterSearchPath),
        NamedCopy("files.filter.clearSearchA11y", filterClearSearchA11y),
        NamedCopy("files.filter.reset", filterReset),
    ]

    // MARK: hero 组文案（1 条，key 前缀 hero.*）
    static let heroCopy: [NamedCopy] = [
        NamedCopy("files.hero.subtitle", heroSubtitle),
    ]

    // MARK: misc 组文案（2 条，key 前缀 misc.*）
    static let miscCopy: [NamedCopy] = [
        NamedCopy("files.loadMore", loadMore),
        NamedCopy("files.reload", reload),
    ]

    // MARK: total 组文案（2 条，key 前缀 total.*）
    static let totalCopy: [NamedCopy] = [
        NamedCopy("files.total.added", linesAddedTotal),
        NamedCopy("files.total.removed", linesRemovedTotal),
    ]

    // MARK: tiles 组文案（9 条，key 前缀 tiles.*）
    static let tilesCopy: [NamedCopy] = [
        NamedCopy("files.tiles.dedupeNotice", dedupeNotice),
        NamedCopy("files.tiles.totalTitle", tileTotalTitle),
        NamedCopy("files.tiles.totalCaption", tileTotalCaption),
        NamedCopy("files.tiles.createdTitle", tileCreatedTitle),
        NamedCopy("files.tiles.createdCaption", tileCreatedCaption),
        NamedCopy("files.tiles.deletedTitle", tileDeletedTitle),
        NamedCopy("files.tiles.deletedCaption", tileDeletedCaption),
        NamedCopy("files.tiles.sensitiveTitle", tileSensitiveTitle),
        NamedCopy("files.tiles.sensitiveCaption", tileSensitiveCaption),
    ]

    // MARK: loading 组文案（3 条，key 前缀 loading.*）
    static let loadingCopy: [NamedCopy] = [
        NamedCopy("files.loading.more", loadingMore),
        NamedCopy("files.loading.initial", loadingInitial),
        NamedCopy("files.loading.hint", loadingHint),
    ]

    // MARK: empty2 组文案（1 条，key 前缀 empty.*）
    static let empty2Copy: [NamedCopy] = [
        NamedCopy("files.empty.rescanNow", rescanNow),
    ]

    // MARK: filtered 组文案（3 条，key 前缀 filtered.*）
    static let filteredCopy: [NamedCopy] = [
        NamedCopy("files.filtered.noSensitiveTitle", noSensitiveTitle),
        NamedCopy("files.filtered.noSensitiveMessage", noSensitiveMessage),
        NamedCopy("files.filtered.closeSensitiveFilter", closeSensitiveFilter),
    ]

    // MARK: error 组文案（2 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        NamedCopy("files.error.header", loadFailedHeader),
        NamedCopy("files.error.retry", retry),
    ]

    static let bilingualCopy: [NamedCopy] =
        rowCopy
        + viewModeCopy
        + diffMissingCopy
        + diffListCopy
        + baselineCopy
        + emptyLinesCopy
        + coverageCopy
        + emptyCopy
        + diffCopy
        + filterCopy
        + heroCopy
        + miscCopy
        + totalCopy
        + tilesCopy
        + loadingCopy
        + empty2Copy
        + filteredCopy
        + errorCopy

}
