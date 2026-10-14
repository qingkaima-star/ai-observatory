//
//  AgentIdentity.swift
//  AIObservatoryPlatform
//
//  Owner: WS-Agent（总控维护）
//

import Foundation
import CryptoKit

/// 由进程身份确定性导出 `AgentInstance.id`。
///
/// `AgentInstance.id` 的默认值是随机 UUID，而检测器每 `processScanIntervalSeconds`
/// 就会重扫一轮。若每轮都生成新 id，`SessionLifecycleManager` 会把同一个存活进程
/// 误判成「pid 已被复用」（它的规则是 id 变了而 pid 没变），于是**每轮结算一条旧会话
/// 并新开一条**：实测启动 30 秒内，23 个真实进程被写成 205 条 agent 行与 205 条会话。
///
/// 因此 id 必须是进程身份的纯函数：`(pid, 启动时刻)`。同一进程跨扫描稳定，
/// 进程退出后 pid 被复用时会因启动时刻不同而得到新 id。
enum AgentIdentity {

    /// - Parameters:
    ///   - pid: 进程号。
    ///   - startedAt: 进程启动时刻；取不到时传 `nil`（退化为按 pid 派生，仍比随机稳定）。
    /// - Returns: 跨扫描稳定的 UUID。
    static func id(pid: Int32, startedAt: Date?) -> UUID {
        var material = Data()
        append(pid: pid, startedAt: startedAt, to: &material)

        let digest = Array(SHA256.hash(data: material).prefix(16))
        return uuid(from: digest)
    }

    /// 由「`.app` bundle 身份」导出稳定 id：一个 GUI Agent 会话 = 一个 bundle。
    ///
    /// 归并材料是 bundle 路径 + **该 bundle 最早启动的那个进程**。之所以不用「被检出的那个进程」：
    /// ChatGPT/Codex 桌面会话的运行时进程会被反复重拉，若身份随它变动，
    /// `SessionLifecycleManager` 每轮都会结算一条旧会话再开一条新的（虚高换个形式回来）。
    /// bundle 内最早启动的进程是 App 本体，活到整个会话结束，因此身份稳定。
    ///
    /// - Parameters:
    ///   - bundlePath: 最外层 `.app` 路径（`DetectionHygiene.enclosingAppBundle` 的返回值）。
    ///   - anchorPID: 该 bundle 最早启动进程的 pid。
    ///   - startedAt: 该进程的启动时刻，取不到传 `nil`。
    static func bundleID(bundlePath: String, anchorPID: Int32, startedAt: Date?) -> UUID {
        var material = Data()
        material.append(contentsOf: bundlePath.utf8)
        append(pid: anchorPID, startedAt: startedAt, to: &material)

        let digest = Array(SHA256.hash(data: material).prefix(16))
        return uuid(from: digest)
    }

    private static func append(pid: Int32, startedAt: Date?, to material: inout Data) {
        withUnsafeBytes(of: pid.bigEndian) { material.append(contentsOf: $0) }
        if let startedAt {
            // 截断到整秒（不是四舍五入）：四舍五入会让同一秒内的 .90 进位到下一秒，
            // 使「同一启动时刻的不同表示」得到不同身份，抖动问题原样复现。
            let seconds = UInt64(max(0, startedAt.timeIntervalSince1970))
            withUnsafeBytes(of: seconds.bigEndian) { material.append(contentsOf: $0) }
        } else {
            material.append(0xFF)
        }
    }

    private static func uuid(from bytes: [UInt8]) -> UUID {
        UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
