//
//  RiskNotificationCoordinatorTests.swift
//  AIObservatoryPlatformTests — Notifications
//
//  Owner: WS-Platform（#59）
//  ─────────────────────────────────────────────────────────
//  钉住 #59 的四条硬要求里能在 Platform 纯逻辑层测的三件：
//   · 去重：同一 event.id 重复到达只发一次；被「未授权 / 关掉 / 投递失败」挡下的**不进**去重集
//     （否则状态恢复后该事件会被永久吞掉——那是静默失败的另一种形态）。
//   · 过滤：LOW/MEDIUM 一律不发，HIGH/CRITICAL 才发。
//   · 开关有真消费者：关掉 ⇒ `.disabledBySetting` 且零投递。
//   · 未授权如实降级、不静默：⇒ `.unauthorized`（返回值本身就是"没静默"的证据）。
//   · 隐私：正文不含完整路径、凭据被 #34 脱敏，且绝不引用 filePaths / detail。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

/// 记录桩：把协调器的判定全部显式化，无一处 OS/网络依赖。
private actor RecordingPoster: RiskNotificationPoster {
    private(set) var posted: [RiskNotification] = []
    var authorized: Bool
    var accepts: Bool
    init(authorized: Bool = true, accepts: Bool = true) {
        self.authorized = authorized
        self.accepts = accepts
    }
    var isAuthorized: Bool { get async { authorized } }
    func setAuthorized(_ v: Bool) { authorized = v }
    func post(_ notification: RiskNotification) async -> Bool {
        if accepts { posted.append(notification) }
        return accepts
    }
    var count: Int { get async { posted.count } }
    var last: RiskNotification? { get async { posted.last } }
}

/// 开关盒：让 `isEnabled()` 可读可改，测「关掉 ⇒ 不发、开了之后同事件仍可发」。
private actor SettingBox {
    private var value: Bool
    init(_ v: Bool) { value = v }
    func get() -> Bool { value }
    func set(_ v: Bool) { value = v }
}

private func highEvent(
    id: UUID = UUID(),
    level: RiskLevel = .high,
    command: String? = "rm -rf /Users/dev/secrets",
    agent: AgentKind = .claudeCode
) -> RiskEvent {
    RiskEvent(
        id: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000), level: level,
        category: .dangerousCommand, title: "递归删除", detail: "detail 里有 /full/path/x",
        agentKind: agent, command: command, filePaths: ["/Users/dev/secrets/a", "/etc/passwd"]
    )
}

@Suite("WS-Platform：#59 高危通知协调器（去重/过滤/开关/降级/隐私）", .timeLimit(.minutes(1)))
struct RiskNotificationCoordinatorTests {

    private func makeCoordinator(
        poster: RecordingPoster, enabled: Bool = true
    ) -> RiskNotificationCoordinator {
        let box = SettingBox(enabled)
        return RiskNotificationCoordinator(
            poster: poster,
            isEnabled: { await box.get() },
            formatTime: { _ in "TIME" }
        )
    }

    @Test("HIGH 事件发出一次；同一 id 再来判 duplicate 且系统只收到一条")
    func dedupByID() async {
        let poster = RecordingPoster()
        let c = makeCoordinator(poster: poster)
        let e = highEvent()
        #expect(await c.handle(e) == .posted)
        #expect(await c.handle(e) == .duplicate)
        #expect(await c.handle(e) == .duplicate)
        #expect(await poster.count == 1)
    }

    @Test("LOW 与 MEDIUM 一律不发")
    func belowThresholdNotPosted() async {
        let poster = RecordingPoster()
        let c = makeCoordinator(poster: poster)
        #expect(await c.handle(highEvent(level: .low)) == .belowThreshold)
        #expect(await c.handle(highEvent(level: .medium)) == .belowThreshold)
        #expect(await poster.count == 0)
    }

    @Test("CRITICAL 也发（阈值是 >= high）")
    func criticalPosted() async {
        let poster = RecordingPoster()
        let c = makeCoordinator(poster: poster)
        #expect(await c.handle(highEvent(level: .critical)) == .posted)
        #expect(await poster.count == 1)
    }

    @Test("开关关掉 ⇒ 零投递且判 disabledBySetting；期间到达的事件在开关重开后仍可发（不入去重集）")
    func disabledToggleIsRealConsumer() async {
        let poster = RecordingPoster()
        let box = SettingBox(false)
        let c = RiskNotificationCoordinator(
            poster: poster, isEnabled: { await box.get() }, formatTime: { _ in "TIME" }
        )
        let e = highEvent()
        #expect(await c.handle(e) == .disabledBySetting)
        #expect(await poster.count == 0)
        // 打开后同一事件再来：应发（证明 disabled 期间没把它误记进"已通知"）
        await box.set(true)
        #expect(await c.handle(e) == .posted)
        #expect(await poster.count == 1)
    }

    @Test("系统未授权 ⇒ 判 unauthorized（不静默）且不投递；授权后同事件仍可发")
    func unauthorizedDegradesNotSilently() async {
        let poster = RecordingPoster(authorized: false)
        let c = makeCoordinator(poster: poster)
        let e = highEvent()
        #expect(await c.handle(e) == .unauthorized)
        #expect(await poster.count == 0)
        // 授权后同事件再来：应发（证明未授权也没污染去重集）
        await poster.setAuthorized(true)
        #expect(await c.handle(e) == .posted)
    }

    @Test("授权但系统拒收 ⇒ postingFailed，不记为已通知")
    func postingFailureNotDeduped() async {
        let poster = RecordingPoster(authorized: true, accepts: false)
        let c = makeCoordinator(poster: poster)
        let e = highEvent()
        #expect(await c.handle(e) == .postingFailed)
        #expect(await poster.count == 0)
    }

    @Test("正文不含完整路径、凭据被脱敏，且绝不引用 filePaths / detail")
    func bodyIsPrivate() async {
        let poster = RecordingPoster()
        let c = makeCoordinator(poster: poster)
        // 命令带绝对路径 + 一个 GitHub token 形态的凭据（ghp_ + 24 位，稳超 minLength）
        let e = highEvent(command: "rm -rf /Users/dev/secrets ghp_ABCDEFGHIJKLMNOPQRSTUVWX")
        let content = await c.notificationContent(for: e)
        let body = content.body
        // 「不含完整路径」的正确判据：绝对路径前缀与中段目录都不许出现。
        // 去路径后允许 `…/<末段>` 这种省略标记（保住"对什么动手"的语义），它不是路径。
        #expect(!body.contains("/Users"), "正文含绝对路径：\(body)")
        #expect(!body.contains("/dev/"), "正文含路径中段目录：\(body)")
        #expect(!body.contains("ghp_ABCDEFGHIJKLMNOP"), "正文含未脱敏凭据：\(body)")
        // 保住了语义（末段目录名 + 脱敏占位），且带上了 Agent 名与时间
        #expect(body.contains("…/secrets"), "去路径应保留末段语义：\(body)")
        #expect(body.contains("‹redacted"), "凭据应留脱敏占位：\(body)")
        #expect(body.contains(AgentKind.claudeCode.displayName), "正文应含 Agent 名：\(body)")
        #expect(body.contains("TIME"), "正文应含时间：\(body)")
        // filePaths / detail 的完整路径绝不得出现在标题或正文任一处
        #expect(!content.title.contains("/") && !content.title.contains("passwd"))
        #expect(!body.contains("passwd") && !body.contains("detail"))
    }

    @Test("空命令时正文退化为 Agent 名 + 时间，不崩不泄漏")
    func emptyCommandSafe() async {
        let poster = RecordingPoster()
        let c = makeCoordinator(poster: poster)
        let content = await c.notificationContent(for: highEvent(command: nil))
        #expect(content.body.contains("TIME"))
        #expect(!content.body.contains("/"))
    }
}
