//
//  NotificationPathEnumerationTests.swift
//  AIObservatoryPlatformTests / Notifications
//
//  Owner: WS-finisher（#64 · 通知正文与 #59 合并成一把尺）
//  ─────────────────────────────────────────────────────────
//  #59 在 Platform 里自己写了一份"按空格切 token、含 `/` 就折末段"；#61 在 UI 里
//  另写了一份"前缀换占位符"。两份互不相认 ⇒ 采集面那行谁都没管（#64 的实拍）。
//  现在识别"哪一段是绝对路径"的判定只有 `PathPrivacy.pathRuns` 一处，
//  通知（折末段）与界面/导出（换占位符）是挂在同一把尺子上的两种策略。
//
//  这一支钉三件事：
//   ① 通知正文整串不含合成家目录——**枚举的是拼出来的那一句**，不是某个字段；
//   ② #59 的既有语义没被顺手改掉：末段仍然留着（"对什么动手"这条审计信息不许丢）；
//   ③ 反向自证：`PathPrivacy.deabsolutized("")` 之外，不带路径的正文逐字不变。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
@testable import AIObservatoryCore
import AIObservatoryTestSupport

private struct RecordingPoster: RiskNotificationPoster {
    var isAuthorized: Bool { true }
    func post(_ notification: RiskNotification) async -> Bool { true }
}

@Suite("Platform: #64 通知正文整串不含绝对路径（与 #59 同一把尺）")
struct NotificationPathEnumerationTests {

    private static let home = FixturePaths.home
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private static func coordinator() -> RiskNotificationCoordinator {
        RiskNotificationCoordinator(poster: RecordingPoster(), isEnabled: { true },
                                    formatTime: { _ in "00:00" })
    }

    private static func event(command: String?, detail: String = "依据句") -> RiskEvent {
        RiskEvent(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001") ?? UUID(),
                  timestamp: base, level: .high, category: .resourceAbuse,
                  title: "标题", detail: detail,
                  agentID: nil, agentKind: .claudeCode, sessionID: nil,
                  command: command, filePaths: ["\(home)/secrets/id_ed25519"])
    }

    @Test("正文整串：绝对路径折成末段，家目录一个字都不留")
    func bodyCarriesNoAbsolutePath() async {
        let content = await Self.coordinator().notificationContent(
            for: Self.event(command: "rm -rf \(Self.home)/secrets"))
        #expect(!content.body.contains(Self.home), "通知正文里还有家目录：\(content.body)")
        // #59 的语义：保住"对什么动手"。
        #expect(content.body.contains("…/secrets"), "折掉了末段 ⇒ 改了 #59 的口径：\(content.body)")
        #expect(!content.title.contains(Self.home))
    }

    @Test("路径粘在别的字符后面时也只折路径段（原来按空格切会把整串吞掉）")
    func gluedPathsFoldOnlyThePath() async {
        let body = await Self.coordinator().notificationContent(
            for: Self.event(command: "tar --exclude=\(Self.home)/a -cf out.tar")).body
        #expect(!body.contains(Self.home), "仍带家目录：\(body)")
        #expect(body.contains("--exclude=…/a"), "把 `--exclude=` 一起折掉了：\(body)")
    }

    @Test("反向自证：不带路径的正文逐字不变；空命令退化成 Agent · 时间")
    func plainBodiesAreUntouched() async {
        let withPath = await Self.coordinator().notificationContent(
            for: Self.event(command: "ls \(Self.home)")).body
        #expect(withPath.contains("…"), "这条本来该折路径：\(withPath)")
        let noCommand = await Self.coordinator().notificationContent(for: Self.event(command: nil)).body
        #expect(noCommand.hasSuffix("· 00:00"), "空命令那一支变了：\(noCommand)")
        let plain = await Self.coordinator().notificationContent(for: Self.event(command: "echo hi")).body
        #expect(plain.contains("echo hi"), "无路径命令被改写了：\(plain)")
    }
}
