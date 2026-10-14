//
//  RiskNotificationPoster.swift
//  AIObservatoryPlatform — Notifications 子模块
//
//  Owner: WS-Platform（#59 高危操作实时通知）
//  ─────────────────────────────────────────────────────────
//  「把一条通知贴到操作系统」这一层的**接缝协议**。本模块**不 import UserNotifications**：
//  与 OS 打交道的具体实现（`UNUserNotificationCenter`）住在 App 外壳，测试里注入记录桩，
//  于是 #59 的四条硬要求中「去重 / 只发 HIGH|CRITICAL / 开关关掉不发 / 未授权如实降级」
//  全部能在不启动真 GUI、不联网、不依赖 .app bundle 的前提下被用例钉住。
//
//  隐私（北极星）：`RiskNotification` 是要显示给用户看的文本，其构造一律过
//  `RiskNotificationCoordinator`，那里保证「不含完整路径、命令再过 #34 凭据脱敏」。
//  这一层只负责投递已经构造好的内容，拿不到原始 `RiskEvent`，也就无从泄漏。
//

import Foundation

/// 一条准备投递给用户的通知内容。**到这一步文本必须已经脱敏完毕**（见协调器）。
public struct RiskNotification: Sendable, Hashable {
    /// = `RiskEvent.id`。OS 侧也用它做 identifier / threadIdentifier，
    /// 保证「同一事件重复到达」在系统那一端同样不会叠出第二条。
    public let id: UUID
    /// 标题：等级 + 类别（`"高危 · 递归放权"`），不含任何路径。
    public let title: String
    /// 正文：Agent 名 + 命令摘要（去路径 + #34 脱敏）+ 时间。
    public let body: String

    public init(id: UUID, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// 投递层。App 用 `UNUserNotificationCenter` 实现；测试注入桩。
public protocol RiskNotificationPoster: Sendable {
    /// 系统是否已授予通知权限。false ⇒ 协调器返回 `.unauthorized`，由上层如实显示「未授权」，
    /// 绝不静默（#59 硬要求 3）。
    var isAuthorized: Bool { get async }

    /// 投一条。**返回 true 仅当系统确实接收了**；返回 false（被拒/异常）⇒ 协调器记 `.postingFailed`，
    /// 同样不得静默。实现方不得在此内部再查权限来决定成不成的静默丢弃——把失败如实报回来。
    func post(_ notification: RiskNotification) async -> Bool
}
