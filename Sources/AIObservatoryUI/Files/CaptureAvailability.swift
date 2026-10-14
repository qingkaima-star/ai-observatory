//
//  CaptureAvailability.swift
//  AIObservatoryUI / Files
//
//  Owner: WS-UI（uicopy · P1 界面不许替未实现的功能编理由）
//  ─────────────────────────────────────────────────────────
//  「这一页为什么是空的」的口径。形状照 `Performance/MetricAvailability.swift`——
//  那把尺子是对的：温度拿不到就显「—」并写「这台机器拿不到」，而不是显 0。
//
//  要治的病：一个监控根只要被采集侧判为不可用（`/`、家目录这类太浅的根，或命中忽略规则），
//  原来只是 `os_log` 一句然后 `continue`——**这条事实不出引擎**。于是把一个项目放在家目录
//  本身的 Agent，它的文件改动一条也不会出现，而界面原来只说
//  「还没有文件变更 · 引擎捕获到 AI Agent 写入…后会在这里列出」，
//  用户读到的是「这个 Agent 没动过文件」。那是界面在撒谎：它把「我看不到」说成了「没有」。
//
//  实况从 `ObservatoryRuntime.monitoringScope` 拿（ICR-0006 方案 A，`d1139af`）：
//  引擎每解析一轮就把手里的 kept/dropped 交出来，界面**不再自己猜**，也不再从
//  `runtime.settings` 那份启动快照拼数字（拼出来的是"配置里写着什么"，不是"在监控什么"，
//  两把尺）。三条硬约束都落在这里：
//    ① 读数为 `nil` 只能说「尚无采集面读数」，不许写成「用户没配监控根」——那是两件事；
//    ② 不为 `shadowedByShallowerRoot` 写专门文案（总控核过排序，当前算法下不可达），
//       所有原因一律走契约自己的 `Reason.displayName`，界面不做 per-case 分叉；
//    ③ 不复刻 `isProtected`：判定只有引擎那一处出处。
//

import Foundation
import AIObservatoryCore

// MARK: - 引擎的「在采集」判定

extension EngineState {

    /// 引擎此刻**是不是在采集**。口径必须只有一份：侧栏那颗状态点、启停按钮文案、
    /// 以及文件页空态说的「没有在采集」，得是同一个判断，否则会出现
    /// 「侧栏写着降级运行、那一页却说引擎没在跑」这种同屏矛盾。
    ///
    /// `degraded` 算在采集：降级是某条采集链没起来，不是停下来了。
    /// `starting` 算在采集：引擎已经在看，只是还没到第一轮。
    var isCollecting: Bool {
        self == .running || self == .starting || self == .degraded
    }
}

// MARK: - 采集面实况

/// 采集面**实况**：引擎这一轮到底在监控哪些根、剔除了哪几条、为什么。
///
/// 只有一个出处：`ObservatoryRuntime.monitoringScope`（ICR-0006 方案 A）。
/// 这一格原来报的是 `runtime.settings.monitoredRoots.count`——那是**启动快照里配置的条数**，
/// 既不等于在监控什么（引擎还要并上按被检出 Agent 的 cwd 推导的那些），也不随 apply 更新，
/// 拿它当实况就是第二把尺。现在彻底不读它。
struct CaptureScope: Hashable {

    /// 引擎最近一轮解析出的范围。`nil` = 还没有读数（宿主没装配，或引擎还没跑过任何一轮）。
    /// ⚠️ 这一档只说明「没有读数」，**不许**写成「用户没配监控根」——那是两件不同的事。
    var live: MonitoringScope?
    /// 本页时间范围显示名。少了它，「没有记录」会被读成「这台机器上从来没有过文件改动」。
    var rangeName: String

    /// 一行里最多点名几条剔除。剔除清单长度随配置增长，全铺会把这行元信息撑成正文；
    /// 超出的用「另 N 条」收口——**总数仍然报全**，藏起来就等于没说。
    static let droppedInlineLimit = 3

    /// #64：这一行的**每一个**路径（被剔除的根、命中的忽略规则）都是绝对路径，而整句是
    /// 拼进本地化文案的，根本不经过 `FilePathText` ⇒ 开关开着照样把家目录铺上屏
    /// （实拍 `tmp/shots/redact-on-files.png` 那句「剔除 2 条：… /Users/dev」就是这一处）。
    ///
    /// 映射**跟着值走**，不跟着调用方走：谁造出这份读数，谁就得带着映射来。
    /// 默认 `.off`（恒等）只对用例开放——生产侧唯一出处是 `FilesModel.captureScope`，
    /// 它必须把启动设置解析出的映射带进来，`RedactionSurfaceTests` 逐字钉着那一句。
    var mask: PathPrivacy.Mask

    init(live: MonitoringScope?, rangeName: String, mask: PathPrivacy.Mask = .off) {
        self.live = live
        self.rangeName = rangeName
        self.mask = mask
    }

    /// 常驻那一行（这一页有记录时也在）：实况 + 本页范围 + 读数有多新。
    ///
    /// 从计算属性改成**显式收语言**的函数：这一行被十几条用例逐字钉着，
    /// 挂在 `.resolved()` 上等于把"测试进程恰好是中文"当成前提（本仓犯过多次）。
    func coverageLine(language: AppLanguage = .resolved()) -> String {
        guard let live else {
            return FilesCopy.coverageNoReading.format(language, rangeName)
        }
        let parts = [
            FilesCopy.coverageRoots.format(language, live.keptRoots.count),
            live.dropped.isEmpty
                ? FilesCopy.coverageDroppedNone.text(language)
                : droppedText(live.dropped, language: language),
            FilesCopy.coverageRange.format(language, rangeName),
            FilesCopy.coverageResolved.format(language, DateFormat.time(live.resolvedAt)),
        ]
        return parts.joined(separator: " · ")
    }

    /// 剔除清单那一段。原因一律走契约自己的 `Reason.displayName`，界面**不做 per-case 分叉**
    /// （约束②：`shadowedByShallowerRoot` 在当前排序下不可达，为它写一句就是给死代码背书；
    /// 将来真产出这句话也照样对）。
    private func droppedText(_ dropped: [MonitoringScope.Dropped],
                             language: AppLanguage) -> String {
        let shown = Array(dropped.prefix(Self.droppedInlineLimit))
        let named = shown
            .map { droppedEntryText($0, language: language) }
            .joined(separator: FilesCopy.droppedNameJoiner.text(language))
        let rest = dropped.count - shown.count
        return rest > 0
            ? FilesCopy.droppedListWithMore.format(language, dropped.count, named, rest)
            : FilesCopy.droppedList.format(language, dropped.count, named)
    }

    /// 一条剔除的显示形式：`路径（原因[: 命中的规则]）`。
    ///
    /// ⚠️ **#46**：路径是空白时原来把空白**原样铺出去**，屏上那条空路径就成了两个空格
    /// （`… 、  （空路径）、/ …`），读起来像渲染坏了。现在给一个字面量占位 `""`——
    /// 它说的就是「这条配置的值等于空字符串」这件事本身，而且**不含中文词**，
    /// B3 双语迁移时不需要为它加词条。
    /// 同一条规则也管 `matchedRule`：规则本身是空白时不拼那个冒号（否则又是一处「看着像坏了」）。
    ///
    /// 判的是「这个值是不是空白」，不是「原因是哪一档」⇒ 仍然零 per-case 分叉（约束②③都不破）。
    private func droppedEntryText(_ entry: MonitoringScope.Dropped,
                                  language: AppLanguage) -> String {
        // #64：路径与命中的规则名都是**这台机器上的真实路径**（忽略规则按前缀匹配，
        // 规则本身往往就写成 `/Users/dev/…`）。走 `scrub` 而不是 `apply`：
        // 这里的串是"路径在句中"的形状，`apply` 只认整串前缀，正是上一轮的漏因。
        let path = entry.path.isAllBlank ? Self.blankValuePlaceholder : mask.scrub(entry.path)
        // #67 已接上：`reason.displayName(_:)` 现在按语言出词（此前它是 §3 契约里的裸中文，
        // 英文态这一行会夹进中文原因词——那条说明到此作废，别照抄）。
        // 不在界面这边复刻一份映射（那是第二把尺子），已作为 ICR 交回总控。
        var detail = entry.reason.displayName(UILanguage.current)
        if let rule = entry.matchedRule, !rule.isAllBlank {
            detail += FilesCopy.droppedRuleColon.text(language) + mask.scrub(rule)
        }
        return FilesCopy.droppedEntry.format(language, path, detail)
    }

    /// 空白值的可见占位。语言中立，双语两边都用它。
    static let blankValuePlaceholder = "\"\""
}

// MARK: - 空态口径

/// 文件页空态的两种含义。`ObservatoryPage` 那一层不拼句子，只读这两个属性。
enum CaptureAvailability: Hashable {

    /// 引擎没在采集（停止 / 失败）：这一页的空是「没人在看」，不是「没发生」。
    case notCollecting(EngineState)
    /// 引擎在采集，本页范围内一条记录都没有。
    case nothingInScope(CaptureScope)

    /// 由「引擎状态 + 本页已加载条数」推出。**有条数就返回 nil**：
    /// 那时该显示的是数据，不是一句免责话。
    static func resolve(engineState: EngineState, rowCount: Int, scope: CaptureScope) -> CaptureAvailability? {
        if rowCount > 0 { return nil }
        return engineState.isCollecting ? .nothingInScope(scope) : .notCollecting(engineState)
    }

    /// 空态大一行。
    func headline(language: AppLanguage = .resolved()) -> String {
        switch self {
        case .notCollecting: FilesCopy.headlineNotCollecting.text(language)
        case .nothingInScope: FilesCopy.headlineNothingInScope.text(language)
        }
    }

    /// 空态说明：先报此刻状态或范围事实，再报盲区，最后一句把「看不到 ≠ 没有」说明白。
    func explanation(language: AppLanguage = .resolved()) -> String {
        switch self {
        case .notCollecting(let state):
            // `state.displayName(UILanguage.current)` 同样是契约侧的裸中文，同上那条 ICR。
            FilesCopy.explanationNotCollecting.format(language, state.displayName(UILanguage.current))
        case .nothingInScope(let scope):
            scope.coverageLine(language: language) + FilesCopy.blindSpotSuffix.text(language)
        }
    }
}
