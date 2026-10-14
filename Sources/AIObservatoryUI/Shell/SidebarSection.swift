//
//  SidebarSection.swift
//  AIObservatoryUI
//
//  Owner: WS-UI
//  ─────────────────────────────────────────────────────────
//  侧边栏的 9 个板块，同时充当 ObservatoryRootView 的路由枚举，
//  并且是板块名字的**唯一**出处（侧栏行 / 页内 hero / 窗口标题栏三处都读 `title`）。
//

import SwiftUI
import AIObservatoryCore

/// 主界面侧边栏的 9 个板块。
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case dashboard
    case sessions
    case timeline
    case commands
    case files
    case performance
    case security
    case projects
    case settings

    public var id: String { rawValue }

    /// 板块的**唯一**名字：侧栏行标题、页内 hero 大字、窗口标题栏三处都读这一个属性。
    ///
    /// 原来这里有两个属性：`title` 是英文（Dashboard / Sessions / …），`boardTitle` 是中文，
    /// 而中文那一套又和各页 `ObservatoryPage(...)` 里手写的字面量第三度分叉
    /// （侧栏「操作时间线」/ 窗口「行为时间线」、「终端命令审计」/「命令审计」、
    /// 「文件行为」/「文件变更」）⇒ 同一目的地三个名字，而逐页资源尺子
    /// `Tools/UIProbe/measure-pages.sh` 绑的正是窗口真显示的那串字，对不上就判废该行数据。
    ///
    /// 只留一个、不留两个再对齐：侧栏条目写的就是它指向的目的地之名（系统设置 / 访达 的既有
    /// 约定），并存必然再次分叉——这次就是没有任何东西强制它们同步。取窗口那一套中文，
    /// 因为三个分歧词里它在语义上都更准，且它是真机护栏已认下的那一套 ⇒ 护栏不受影响。
    ///
    /// ⚠️ 改任何一个字都要同步 `Tools/UIProbe/measure-pages.sh` 的 `board_title()`；
    /// 两处一致性由 `SidebarNamingTests` 逐行比对那张表来保证（表里中文、英文各一行）。
    ///
    /// 【双语】名字取自 `ShellCopy.sectionTitleCopy(_:)`（唯一出处），按**当前语言**渲染。
    /// 要断言某一语言那一套，用下面的显式展口 `title(_:)`——用例不许读宿主系统语言。
    public var title: String { title(UILanguage.current) }

    public func title(_ language: AppLanguage) -> String {
        ShellCopy.sectionTitle(self, language)
    }

    /// 一句话说明，用于侧边栏副标题与菜单栏提示（`SidebarRow` 的 `.help(...)`）。
    ///
    /// ⚠️ 这一句只能列**这一页真给得出的东西**。改过两处说谎：
    /// · 总览页写「实时曲线」，而那一页是 24 小时柱状图 + 占比环图，没有任何曲线；
    /// · 性能页写「与温度」，而 Apple Silicon 上 SMC 拿不到温度，页面自己那一格
    ///   就明写着「这台机器拿不到温度」——侧栏承诺、正文否认，是同一条账的两把尺。
    /// 两条口径在英文侧同样成立，译文在 `ShellCopy` 里逐条对着中文复核过才写的。
    var subtitle: String { subtitle(UILanguage.current) }

    func subtitle(_ language: AppLanguage) -> String {
        ShellCopy.sectionSubtitle(self, language)
    }

    /// 板块图标。
    var symbol: String {
        switch self {
        case .dashboard:   return "gauge.with.dots.needle.67percent"
        case .sessions:    return "list.bullet.rectangle"
        case .timeline:    return "timeline.selection"
        case .commands:    return "terminal"
        case .files:       return "doc.on.doc"
        case .performance: return "chart.xyaxis.line"
        case .security:    return "shield.lefthalf.filled"
        case .projects:    return "folder.badge.gearshape"
        case .settings:    return "gearshape"
        }
    }

    /// ⌘数字直达的键位；`nil` = 这一项**不给** ⌘数字。
    ///
    /// 编号按**侧栏看到的顺序**（`SidebarGroup.sections` 展平后）而不是 `allCases` 声明顺序，
    /// 因为用户是拿手指在栏上一格一格数的；两者今天恰好一致，
    /// 所以一致性由 `SidebarNavigationTests.键位等于侧栏里的可见顺序` 钉住。
    ///
    /// 【Settings 的口径：故意不给 ⌘9】
    /// 设置在这一版里有两条入口：侧栏第 9 项，以及 macOS 标准的 ⌘, （`Settings` scene，
    /// `AIObservatoryApp.swift:219`）。本条派单要的是「一个目的地一条快捷键」，
    /// 而 ⌘, 是平台约定、删不掉也不该删 ⇒ 侧栏那一格不再另发 ⌘9。
    /// 换句话说 ⌘1–⌘8 是**内容板块**的直达键，设置走 ⌘,。
    /// ⚠️ 顺带一条已判定缺陷交回总控（不在本车道权限内）：`Settings` scene 与侧栏那格渲染的是
    /// 同一个 `SettingsView`，但两边各持一份 `@State SettingsModel` ⇒ 两处同开时草稿互不同步。
    public var navigationKey: Character? {
        switch self {
        case .dashboard:   return "1"
        case .sessions:    return "2"
        case .timeline:    return "3"
        case .commands:    return "4"
        case .files:       return "5"
        case .performance: return "6"
        case .security:    return "7"
        case .projects:    return "8"
        case .settings:    return nil
        }
    }

    /// 侧栏 tooltip 后缀：快捷键得看得见，否则等于没有
    /// （HIG：keyboard shortcuts must be discoverable）。
    ///
    /// 括号本身是文案：中文全角不带前导空格、英文半角带一个，见 `ShellCopy.shortcutHintTemplate`。
    var shortcutHint: String { shortcutHint(UILanguage.current) }

    func shortcutHint(_ language: AppLanguage) -> String {
        guard let key = navigationKey else { return "" }
        return ShellCopy.shortcutHintTemplate.format(language, String(key))
    }
}

// MARK: - Grouping

/// 侧边栏分组：把 8 个板块按“看什么”归类，避免一长串平铺。
enum SidebarGroup: String, CaseIterable, Identifiable, Hashable {
    case overview
    case forensics
    case resources
    case workspace

    var id: String { rawValue }

    /// 分组标题。
    var title: String { title(UILanguage.current) }

    func title(_ language: AppLanguage) -> String {
        ShellCopy.groupTitle(self, language)
    }

    /// 分组内的板块（顺序即展示顺序）。
    var sections: [SidebarSection] {
        switch self {
        case .overview:   return [.dashboard, .sessions]
        case .forensics:  return [.timeline, .commands, .files]
        case .resources:  return [.performance, .security]
        case .workspace:  return [.projects, .settings]
        }
    }
}
