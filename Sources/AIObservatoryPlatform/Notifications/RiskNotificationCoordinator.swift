//
//  RiskNotificationCoordinator.swift
//  AIObservatoryPlatform — Notifications 子模块
//
//  Owner: WS-Platform（#59 高危操作实时通知）
//  ─────────────────────────────────────────────────────────
//  「一条风险事件到来了，要不要发系统通知、发什么」的全部判定，纯逻辑、可脱机测。
//
//  四条硬要求落点：
//   · #1 隐私：正文只由 等级/类别/Agent 名/命令摘要/时间 组成。
//        - 命令摘要先 **去绝对路径**（每个含 "/" 的 token 只留末段，前缀 `…/`），
//          再过 #34 的 `CommandLineRedaction.redact`（凭据）——两道都在 `notificationContent` 里，
//          用例逐字钉住「不含 /、不含 ‹redacted› 之外的凭据」。
//        - 绝不用 `event.filePaths` / `event.detail`（那两个字段带完整路径，是泄漏面）。
//        - 本模块不 import 任何网络/OS 框架；投递经 `RiskNotificationPoster` 接缝，实现方（App）才碰 OS。
//   · #2 去重：`去重键 = event.id`，`notified` 有界集合；同一 id 第二次到达 → `.duplicate`。
//   · #2 只发 HIGH/CRITICAL：`event.level < .high` → `.belowThreshold`。
//   · #2 开关有真消费者：每次判定现读 `isEnabled()`；关 → `.disabledBySetting`（且**不**入去重集，
//        这样中途打开也不会把关掉期间漏掉的历史事件补发——只对打开后新到达的生效）。
//   · #3 未授权如实降级、不静默：`poster.isAuthorized == false` → `.unauthorized`（**不**入去重集，
//        授权后若同事件再来仍可发；上层据 `.unauthorized`/最近态在菜单栏计数 + 设置页写「未授权」）。
//        投递失败 → `.postingFailed`（同样不静默、不入集）。
//   · #4 不改节奏：本类只在「事件到达」时被调用，绝不自己起定时器或提高采样频率。
//

import Foundation
import AIObservatoryCore

/// 高危风险事件的系统通知协调器。线程安全由 `actor` 提供；被 `recordRisks` 的广播或
/// UI 侧订阅流按事件调用 `handle(_:)`。
public actor RiskNotificationCoordinator {

    /// 一条事件走完判定的去向。`posted` 之外都不投递，且各自的语义要在界面上如实表达。
    public enum Disposition: Sendable, Equatable {
        case posted                 // 已交给 poster 且系统接收
        case duplicate              // 同一 event.id 之前已通知过 ⇒ 静默是正确的（去重）
        case belowThreshold         // LOW / MEDIUM ⇒ 设计上不发
        case disabledBySetting      // 用户关了开关 ⇒ 不发（开关的真消费者就是这里）
        case unauthorized           // 系统未授权 ⇒ 上层须显示「未授权」，不得静默
        case postingFailed          // 授权了但系统拒收 ⇒ 上层须可见，不得静默
    }

    /// 去重历史的容量上限。风险事件的 id 由 `窗口键 + 规则id` 稳定散列而来，同一发现跨轮/跨重启
    /// 恒等；4096 条足够覆盖一台机器正常运行期内的并发高危事件。超限时按最早进入者淘汰
    /// （被淘汰者若极久之后重新出现会被再发一次——可接受，且比无界增长安全，AGENTS §6 内存预算）。
    public static let defaultHistoryCapacity = 4_096

    private let poster: any RiskNotificationPoster
    private let isEnabled: @Sendable () async -> Bool
    private let formatTime: @Sendable (Date) -> String
    private let historyCapacity: Int

    private var notified: Set<UUID> = []
    private var insertionOrder: [UUID] = []

    /// - Parameters:
    ///   - poster: 投递层（App 注入 `UNUserNotificationCenter` 实现；测试注入记录桩）。
    ///   - isEnabled: 读当前设置的 `notifyOnHighRisk` 开关（真消费者；关掉即 `.disabledBySetting`）。
    ///   - formatTime: 时间格式化（默认 `.dateTime` 本地风格；测试注入固定串以逐字断言正文）。
    public init(
        poster: any RiskNotificationPoster,
        isEnabled: @escaping @Sendable () async -> Bool,
        formatTime: @escaping @Sendable (Date) -> String = RiskNotificationCoordinator.defaultTimeFormat,
        historyCapacity: Int = RiskNotificationCoordinator.defaultHistoryCapacity
    ) {
        self.poster = poster
        self.isEnabled = isEnabled
        self.formatTime = formatTime
        self.historyCapacity = max(1, historyCapacity)
    }

    /// 处理一条风险事件，返回它的去向。**这是唯一的外部入口**；调用方（App 订阅 / 引擎广播）
    /// 不得在此之外另发通知，否则绕过 `#1` 的脱敏与 `#2` 的去重。
    public func handle(_ event: RiskEvent) async -> Disposition {
        guard event.level >= .high else { return .belowThreshold }
        guard await isEnabled() else { return .disabledBySetting }
        guard !notified.contains(event.id) else { return .duplicate }
        // 未授权时**先于**投递就返回，避免向系统提交一条注定失败的通知；且不入去重集。
        guard await poster.isAuthorized else { return .unauthorized }

        let delivered = await poster.post(notificationContent(for: event))
        guard delivered else { return .postingFailed }
        remember(event.id)
        return .posted
    }

    /// 构造脱敏后的通知内容。与 `handle` 分开，是为让「正文不含完整路径 / 不含凭据」这条隐私判据
    /// 能被**独立、直接**地用例钉住（不依赖 poster 是否授权）。
    public func notificationContent(for event: RiskEvent) -> RiskNotification {
        // 标题：等级 + 类别。二者都是枚举 displayName，天然无路径无凭据。
        let title = "\(event.level.displayName) · \(event.category.displayName)"
        // 正文：Agent 名 + 命令摘要（去路径 + 脱敏）+ 时间。绝不含 filePaths / detail。
        let agent = event.agentKind.displayName
        let summary = Self.summarize(command: event.command)
        let time = formatTime(event.timestamp)
        let body = summary.isEmpty
            ? "\(agent) · \(time)"
            : "\(agent) · \(summary) · \(time)"
        return RiskNotification(id: event.id, title: title, body: body)
    }

    /// 命令摘要：先按 token 去绝对路径（只留末段），再过 #34 凭据脱敏。
    ///
    /// 去路径规则：含 `/` 的 token 折成 `…/<最后一个非空段>`；空段（连续斜杠/结尾斜杠）退化为 `…/`。
    /// 这样 `rm -rf /Users/x/secrets` → `rm -rf …/secrets`：保住「对什么动手」的语义，
    /// 但不泄漏用户目录结构（北极星）。已脱敏的凭据占位 `‹redacted:kind›` 不含 `/`，不受影响。
    static func summarize(command: String?) -> String {
        guard let command, !command.isEmpty else { return "" }
        // #64：**不再在这里自己分词**。"哪一段算绝对路径"的判定只有 `PathPrivacy` 一处，
        // 界面/导出/通知三面共用它——原来这一份按空格切，于是
        // `--out=/Users/x/a`、`>/Users/x/b` 这类"路径粘在别的字符后面"的写法整串被折，
        // 连前面的字符一起丢；现在只折路径那一段（方向更严，不是更松）。
        return CommandLineRedaction.redact(PathPrivacy.deabsolutized(command))
    }

    private func remember(_ id: UUID) {
        guard !notified.contains(id) else { return }
        notified.insert(id)
        insertionOrder.append(id)
        if insertionOrder.count > historyCapacity {
            let evicted = insertionOrder.removeFirst()
            notified.remove(evicted)
        }
    }

    /// 默认时间格式：本地、简短。用 `Date.FormatStyle`（内部走 `Calendar`/locale，不做手写时间戳算术，AGENTS §5）。
    public static let defaultTimeFormat: @Sendable (Date) -> String = { date in
        date.formatted(date: .numeric, time: .shortened)
    }
}
