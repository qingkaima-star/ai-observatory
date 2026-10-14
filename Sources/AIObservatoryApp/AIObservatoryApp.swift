//
//  AIObservatoryApp.swift
//  AIObservatoryApp
//
//  Owner: master-controller（冻结外壳）；ADR-0006 #14 由 WS-Honesty 改为按启动值分派 Scene
//  ─────────────────────────────────────────────────────────
//  组合根：在这里把 Engine 装配成 ObservatoryRuntime 并交给 UI。
//  外壳由总控冻结，避免与 WS-UI 产生合并冲突；WS-UI 只改 UI target。
//
//  为什么这里有两个 App 类型（ADR-0006 #14）：
//  SwiftUI 的 `Scene` 只在进程启动时构建一次，而 `@SceneBuilder` **没有** `buildIf` /
//  `buildEither`——实测 Swift 6.3.3 / SDK 26.5：
//    · 运行时 `if cond { MenuBarExtra… }`            → `failed to produce diagnostic for expression`
//    · 运行时 `if cond { … } else { … }`             → `closure containing control flow statement
//                                                       cannot be used with result builder 'SceneBuilder'`
//    · 编译期 `if #available(macOS 13, *) { … }`      → 通过（说明不是我的写法问题，是 builder 真没有分支能力）
//  SwiftUI 也没有公开的 `AnyScene` / `EmptyScene` 可以做类型擦除，所以「按设置决定有没有菜单栏」
//  只剩一条合法出路：**按启动值挑一个具体 App 类型**。菜单栏版多一个 `MenuBarExtra` 场景，
//  无菜单栏版只留窗口。两版共用同一个 `ObservatoryCoreScenes`，Scene 树不复制第二份。
//
//  代价（如实写在这里，也如实写在设置页里）：改这个开关要**重启**才生效。
//  「要重启」是如实的限制，「拨了没反应还不说」是缺陷——两害相权取前者。
//

import SwiftUI
import AppKit
import AIObservatoryCore
import AIObservatoryEngine
import AIObservatoryUI

// MARK: - 启动装配

/// 本次启动的生效设置。
///
/// 用 `static let`：整个进程只读一次 `settings.json`，`main()` 选 Scene 与 App 的 `init()`
/// 造 runtime 取到的是同一个值（两处各自读盘就可能读到不同结果，那是新的说谎面）。
enum ObservatoryLaunch {

    /// 启动生效值：落盘值优先，读不到退宿主基线。
    ///
    /// 读盘是**同步**的，且发生在主线程——这是刻意的：Scene 集合在 `main()` 里就定死了，
    /// 等不到 `Task` 完成。一个几百字节的 JSON 与引擎启动本来要做的迁移相比可以忽略，
    /// 而且引擎的 `init` 走的是同一套 `SettingsPersistence.restore`（AGENTS.md 第 5 节
    /// 禁止的是磁盘扫描/哈希/diff 这类主线程 IO）。
    static let startupSettings: ObservatorySettings = readStartupSettings(
        storeDirectory: DataLocation.storeDirectory
    )

    /// 读盘一次并解析。`storeDirectory` 只解析一次：`DataLocation` 会建目录，读两遍等于 mkdir 两遍。
    static func readStartupSettings(storeDirectory: String) -> ObservatorySettings {
        resolvedStartupSettings(
            persisted: SettingsPersistence.restore(ifPresentIn: storeDirectory),
            baseline: ObservatorySettings(storeDirectory: storeDirectory)
        )
    }

    /// 纯函数版解析（不碰磁盘），供 `AIObservatoryAppTests` 钉住接线。
    ///
    /// 为什么要拆出来：会挑 Scene 的不是 `MenuBarScenePolicy` 那条规则，而是**这里有没有把
    /// 落盘值喂进去**。喂错成 `baseline`（或干脆喂 `nil`）时规则本身依然自洽，
    /// 只有这条接线能抓住「开关又被读错了地方」。
    static func resolvedStartupSettings(
        persisted: ObservatorySettings?,
        baseline: ObservatorySettings
    ) -> ObservatorySettings {
        var startup = persisted ?? baseline
        // 把「Scene 声明与否」写回这个字段，界面读它就等于读到本次真正声明的结果：
        // 否则用户在 About 看到的「开」可能对应一个根本没声明菜单栏的进程。
        startup.enableMenuBarExtra = MenuBarScenePolicy.declaresMenuBar(
            persistedValue: persisted?.enableMenuBarExtra,
            fallbackValue: baseline.enableMenuBarExtra
        )
        return startup
    }

    /// 本次启动是否声明 `MenuBarExtra`。
    static var declaresMenuBar: Bool { startupSettings.enableMenuBarExtra }
}

/// 装配入口：按启动值挑一套具体 Scene。
@MainActor
@main
enum AIObservatoryMain {
    static func main() {
        if ObservatoryLaunch.declaresMenuBar {
            AIObservatoryMenuBarApp.main()
        } else {
            AIObservatoryWindowedApp.main()
        }
    }
}

/// 两个 App 类型共用的装配，避免第二份「造引擎 + 起轮询」的代码。
enum ObservatoryAssembly {

    /// 造 runtime 并拉起引擎（每个进程只会构造一次）。
    @MainActor
    static func makeRuntime() -> ObservatoryRuntime {
        let settings = ObservatoryLaunch.startupSettings
        let engine = ObservatoryEngine(settings: settings)
        let runtime = ObservatoryRuntime(
            service: engine,
            controller: engine,
            updates: engine,
            settings: settings,
            exporter: AppActivityExporter(
                service: engine,
                // #64：与渲染层**同一个** settings 快照、同一个解析工厂 ⇒
                // 屏上脱了什么敏，导出件里就是什么。各解一次迟早分叉。
                pathMask: PathPrivacy.Mask.configured(from: settings)
            ),
            analysis: ObservatoryAnalysisProvider(service: engine),
            capability: engine,
            monitoringScope: engine
        )
        Task {
            await engine.start()
        }
        // 装配根把 runtime 交给退出结算的回调（见 `AppDelegate.applicationShouldTerminate`）。
        AppDelegate.settlementRuntime = runtime
        return runtime
    }
}

// MARK: - 具体 Scene

/// 菜单栏版：`enableMenuBarExtra` 为真时由 `AIObservatoryMain` 选中。
struct AIObservatoryMenuBarApp: App {
    @State private var runtime: ObservatoryRuntime

    init() {
        self._runtime = State(initialValue: ObservatoryAssembly.makeRuntime())
    }

    var body: some Scene {
        ObservatoryCoreScenes(runtime: runtime)
        MenuBarExtra("AiX", systemImage: "scope") {
            MenuBarContentView(runtime: runtime)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 无菜单栏版：本进程**没有**声明 `MenuBarExtra`，主窗口与设置窗口照常。
struct AIObservatoryWindowedApp: App {
    @State private var runtime: ObservatoryRuntime

    init() {
        self._runtime = State(initialValue: ObservatoryAssembly.makeRuntime())
    }

    var body: some Scene {
        ObservatoryCoreScenes(runtime: runtime)
    }
}

/// 主窗口 + 设置窗口 + AppKit 锚点。两个 App 类型共用，Scene 树只有一份。
///
/// `@NSApplicationDelegateAdaptor` 放在这里而不是每个 App 类型里：放 App 层就要写两遍，
/// 而两遍意味着其中一处漏掉时 `setActivationPolicy(.regular)` 不执行——裸 SwiftPM 可执行文件
/// 会以 accessory 形态起来，没有 Dock 图块也没有主菜单（`Packaging/Info.plist` 的 NSPrincipalClass
/// 一节记录过这个前提）。实测（本工作流的编译探针 P7）放在自定义 `Scene` 里时
/// `applicationDidFinishLaunching` 两条分支都会触发。
struct ObservatoryCoreScenes: Scene {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let runtime: ObservatoryRuntime
    /// 侧栏与「⌘1–⌘8」菜单项**必须驱动同一个**外壳状态，否则菜单切了页而侧栏高亮不动。
    /// 放在 Scene 而不是视图里，是因为 `.commands` 只能挂在 Scene 上（ICR-0005）。
    @State private var shell: ShellModel

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        _shell = State(initialValue: ShellModel(runtime: runtime))
    }

    var body: some Scene {
        mainWindow
        settingsWindow
    }

    /// 拆成独立属性：整个 `body` 里堆叠 Window + commands + Settings + 条件 Scene
    /// 会让类型检查器放弃给出有用诊断（`failed to produce diagnostic for expression`）。
    private var mainWindow: some Scene {
        Window("AiX", id: "main") {
            // `selfProcessSource` 是 ICR-0003 的装配：性能页那一格「本 App 自身开销」
            // 靠它读自己的 phys_footprint / 本进程 CPU。用 `shared` 而不是在这里新建——
            // `mainWindow` 每次 body 求值都会重跑，新建实例会把测量窗口清零（见该文件头）。
            ObservatoryRootView(
                runtime: runtime,
                selfProcessSource: SelfProcessInstrument.shared,
                shell: shell
            )
                .frame(minWidth: 1_080, minHeight: 720)
                // 「外观 / 主题」在**整个 App** 生效（ADR-0006：设置项必须有真实消费者）。
                //
                // 读的是 `ObservatoryLaunch.startupSettings`（进程内只读一次 settings.json 的那个值），
                // 不是 `runtime.settings`：`ObservatoryRuntime` 是 `Sendable` 值快照、**不是**可观察对象，
                // 所以运行时改主题推不到这里。⇒ **全局主题「重启生效」**，与 `enableMenuBarExtra`
                // 同一个取舍（依据也是同一条：`Scene` 只在启动时构建一次）。
                // 「本窗口即时预览」由设置页自己那份 `preferredColorScheme` 承担。
                //
                // 2026-09-20 之前这里什么都没有，于是设置页的文案「应用到全局由宿主读取
                // settings.theme 完成」是一句空话——宿主根本没读。
                .preferredColorScheme(ObservatoryLaunch.startupSettings.theme.preferredColorScheme)
                // #59 高危通知接线（ICR-0011 ②）：进程内只起一次（bootstrap 内部有守卫）。
                // isEnabledProvider 读契约字段 `notifyHighRisk`（① 已落）。注意 `runtime.settings`
                // 是启动快照 ⇒ 关掉后**重启生效**（与 theme/菜单栏同档），非热切换。
                .task {
                    RiskNotificationBootstrap.startIfNeeded(
                        runtime: runtime,
                        shell: shell,
                        isEnabledProvider: { runtime.settings.notifyHighRisk }
                    )
                }
        }
        .defaultSize(width: 1_280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // ⌘1–⌘8 直达八个板块（ICR-0005）。键位表唯一出处仍是 `SidebarSection.navigationKey`，
            // 这里只是把它渲染成菜单项；`.settings` 没有 navigationKey ⇒ 不给键，走 macOS 标准的 ⌘,。
            //
            // 为什么搬进菜单而不是留在侧栏行上：视图级 `keyboardShortcut` 有一条改不掉的性质——
            // **它不出现在菜单栏里**，用户只能靠 tooltip 猜有这些键。菜单项属于主菜单，
            // 焦点不在侧栏时照样有效，因此比原来那份更对。
            // 代价：视图那八份必须同时删掉，否则同一个键两个 owner——由
            // `SidebarNavigationTests` 的键位归堆闸当场拦红。
            CommandGroup(after: .sidebar) {
                ForEach(SidebarSection.allCases) { section in
                    if let key = section.navigationKey {
                        Button(section.title) { shell.select(section) }
                            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                    }
                }
            }

            CommandMenu(AppShellCopy.observeMenu.text(AppShellCopy.language)) {
                Button(AppShellCopy.rescanNow.text(AppShellCopy.language)) {
                    Task { await runtime.controller.rescanNow() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button(AppShellCopy.exportActivityReport.text(AppShellCopy.language)) {
                    let now = Date()
                    Task {
                        await runtime.exporter?.export(
                            ActivityExportRequest(
                                dateRange: DateRangeFilter(
                                    start: now.addingTimeInterval(-7 * 24 * 3600),
                                    end: now
                                )
                            )
                        )
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }

    private var settingsWindow: some Scene {
        Settings {
            SettingsView(runtime: runtime)
                .frame(width: 640, height: 460)
        }
    }
}

/// SPM 可执行文件默认不是 regular app，需要显式提升为前台应用。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 退出前用来结算采集链的 runtime。由 `ObservatoryAssembly.makeRuntime()` 这一个装配点写入
    /// ——AGENTS.md §5 禁止的是"隐式单例依赖"，装配根显式注入是允许的场景，
    /// 而 `@NSApplicationDelegateAdaptor` 本身没有注入通道（系统用 `init()` 造它）。
    ///
    /// 隔离说明：AppKit 保证 `NSApplicationDelegate` 的回调都在主线程上调用，
    /// 所以这里标 `@MainActor` 并在回调里 `MainActor.assumeIsolated`——
    /// 它把前提写死了，比 `nonisolated(unsafe)` 诚实。
    @MainActor static var settlementRuntime: ObservatoryRuntime?

    /// 只结算一次：`reply(...)` 之后系统会重新走一遍终止流程，别让它再进这个回调。
    @MainActor private var hasStartedSettlement = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// ⌘Q / 退出菜单项之前先把引擎停下来。
    ///
    /// 为什么必须占这个回调：`ObservatoryEngine.stop()` 里挂着需求④ 的收口
    /// （`terminateOpenCommands`，把仍为 running 的命令落成 `.terminated` + 结束时间）
    /// 与 WAL checkpoint。以前 `stop()` 只有两个 UI 按钮会调（设置页开关、侧栏启停），
    /// **直接退出不走任何一条** ⇒ 库里留下一批永远 running 的命令，审计事实不完整。
    ///
    /// 用 `.terminateLater` + `reply(...)` 而不是在 `applicationWillTerminate` 里同步等：
    /// 后者已经没有机会跑 async 收尾。同时给 2 s 上限——收尾绝不能把退出卡住。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let runtime = Self.settlementRuntime, !hasStartedSettlement else {
                return .terminateNow
            }
            hasStartedSettlement = true
            Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await runtime.controller.stop() }
                    group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                    _ = await group.next()
                    group.cancelAll()
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
