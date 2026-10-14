//
//  RiskNotifications.swift
//  AIObservatoryApp — 高危操作实时通知的 OS 接线（#59 / ICR-0011 ②）
//
//  Owner: WS-Platform（经总控批准编辑 App 外壳，见 ICR-0011 §一）
//  ─────────────────────────────────────────────────────────
//  这里是 `RiskNotificationPoster` 的**唯一 OS 实现**：Platform 侧那台判定内核不 import
//  `UserNotifications`、零网络，把「弹给用户 + 问系统要权限 + 点回来」这一层留在这里。
//
//  降级与不崩（#59 硬要求 3）：
//   · `UNUserNotificationCenter.current()` 在**没有 bundle** 的裸 SwiftPM 可执行上会直接 trap。
//     于是 `isAvailable` 先判 `Bundle.main.bundleIdentifier != nil`：不在 .app 里就整体按
//     「未授权」处理（poster 从不触达 UN API）⇒ 协调器返回 `.unauthorized`，界面写「未授权」，
//     **不静默、也不崩**。
//   · 授权被拒 / 投递被系统拒 ⇒ 如实经 `isAuthorized=false` / `post()->false` 回报，
//     由协调器映射成 `.unauthorized` / `.postingFailed`，绝不吞。
//
//  生效时机：`ObservatoryRuntime.settings` 是冻结的值快照、非可观察 ⇒ 开关 `notifyHighRisk`
//  与「主题 / 菜单栏」同档，**改后重启生效**（① 落地时在设置文案里如实写，不假装热生效）。
//

import AppKit
import UserNotifications
import AIObservatoryCore
import AIObservatoryPlatform
import AIObservatoryUI

/// 用 `UNUserNotificationCenter` 把判定内核造好的通知贴到系统上，并把点击回抛给界面。
@MainActor
final class UserNotificationsPoster: NSObject, RiskNotificationPoster, UNUserNotificationCenterDelegate {
    /// 点击某条通知（携带 `RiskEvent.id`）时回调；由装配处接到 `ShellModel` 的跳转上。
    var onEventClick: ((UUID) -> Void)?

    /// 裸可执行（无 bundle）时为 false ⇒ 全程不碰 UN API，按未授权降级。
    private let isAvailable: Bool

    override init() {
        isAvailable = Bundle.main.bundleIdentifier != nil
        super.init()
        if isAvailable {
            // 前台也弹横幅 + 点击回调走本对象（否则 App 在前台时通知被系统静默收纳）。
            UNUserNotificationCenter.current().delegate = self
        }
    }

    private var center: UNUserNotificationCenter? { isAvailable ? UNUserNotificationCenter.current() : nil }

    /// 请求授权。App 启动时调一次；结果只用于让后续 `isAuthorized` 反映真实状态。
    func requestAuthorization() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    var isAuthorized: Bool {
        get async {
            guard let center else { return false }
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized
        }
    }

    /// 投一条。**如实回报系统是否接收**：失败返回 false，由协调器记 `.postingFailed`（不静默）。
    func post(_ notification: RiskNotification) async -> Bool {
        guard let center else { return false }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        // identifier = 事件 id：系统侧也对同一 id 去重，双保险（判定内核已先去重一次）。
        content.userInfo = ["riskEventID": notification.id.uuidString]
        let request = UNNotificationRequest(identifier: notification.id.uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    // MARK: UNUserNotificationCenterDelegate
    //
    // 系统会在任意线程回调这两个方法 ⇒ 它们必须 `nonisolated`（否则 @MainActor 类的方法
    // 无法匹配协议的 nonisolated 要求）。需要动 MainActor 状态（`onEventClick`）的地方 hop 回主线程。

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 前台也显示横幅（否则只有后台才弹，而审计场景里 App 常在前台）。
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["riskEventID"] as? String
        let id = raw.flatMap { UUID(uuidString: $0) }
        // 系统的 reply 块在**当前非隔离上下文**立刻调用（不能塞进 @MainActor Task，否则跨隔离竞争）。
        completionHandler()
        // 跳转要动 `@MainActor` 的 `onEventClick`（→ ShellModel），单独 hop 回主线程。
        if let id {
            Task { @MainActor in self.onEventClick?(id) }
        }
    }
}

/// App 侧的接线根：造 poster + 判定内核，起一条订阅把 `.risk` 事件喂进去，并把点击接到外壳跳转。
///
/// 进程内只启动一次（`ObservatoryCoreScenes.mainWindow` 的 `.task` 求值可能重跑）。
@MainActor
enum RiskNotificationBootstrap {
    @MainActor private static var started = false

    /// - Parameter isEnabledProvider: 读「高危通知」开关的可注入闭包。① 落地前应传
    ///   `{ true }`（等价于默认开），① 落地后改传读 `runtime.settings.notifyHighRisk`（重启生效）。
    static func startIfNeeded(
        runtime: ObservatoryRuntime,
        shell: ShellModel,
        isEnabledProvider: @escaping @Sendable @MainActor () -> Bool
    ) {
        guard !started else { return }
        started = true

        let poster = UserNotificationsPoster()
        poster.onEventClick = { id in
            // #59 → #81(b)：点击那条高危通知 = 一次**带条件的跳转**（目的地 = 风险页，
            // 条件 = 「打开这一条风险事件」），走的是与界面上所有取证出口同一座桥
            // （`EvidenceJumpWiring`：seed 落条件 → 取数 → focus 定位那一行）。
            // 原来这里写的是 `shell.pendingRiskEventID = id` + `shell.select(.security)` 两句
            // —— 一个跨页动作被拆成「存一个 id」与「换一页」，中间那份状态就是第二个真相。
            // 现在 `jump(_:)` 一次把目的地、条件与「打开哪一行」全带走，`select` 由它自己做。
            shell.jump(.locating(target: .security, eventID: id))
        }
        let coordinator = RiskNotificationCoordinator(
            poster: poster,
            isEnabled: { await isEnabledProvider() }
        )

        Task {
            await poster.requestAuthorization()
            // 每次 makeUpdateStream 是一条独立订阅；本 App 只开这一条给通知用，
            // 不与 UI 各页的订阅互相影响（事件 id 去重在协调器里，重复订阅也不会叠发）。
            for await update in runtime.updates.makeUpdateStream() {
                if case .risk(let event) = update {
                    _ = await coordinator.handle(event)
                }
            }
        }
    }
}
