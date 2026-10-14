//
//  StableID.swift
//  AIObservatoryCore
//
//  Owner: master-controller（冻结契约层）
//
//  由「语义身份字符串」推出稳定 UUID。
//
//  为什么需要：`FileHeat` / `AgentContribution` 这类**派生聚合值**过去用 `UUID()` 默认值，
//  每轮聚合都再生成一次。它们是以 JSON 整体存进 `projects` 行的，于是只要重算一次项目地图，
//  即使一个数字都没变，JSON 字节也变了——带来三个可见后果：
//   1. `projects` 行被无意义地重写（写放大，还绕过了 BatchWriter 想省的开销）；
//   2. 导出报告不再字节确定（同一库两次导出结果不同，「可复核」这一条就废了）；
//   3. SwiftUI `ForEach` 每次刷新都认为是新条目，动画与选中态抖动。
//  聚合值的身份必须来自它代表的那个东西（文件路径、Agent 种类），而不是「这次是谁算出来的」。
//

import Foundation
import CryptoKit

public enum StableID {

    /// `SHA256("<namespace>:<key>")` 的前 16 字节，按 RFC 4122 补齐 version/variant 位。
    ///
    /// 不是标准 UUIDv5（v5 用 SHA-1 且带命名空间 UUID），这里只要「同输入同输出」，
    /// 显式命名空间前缀是为了让 `path` 与 `kind` 这类不同口径不会撞到同一个 id。
    public static func uuid(namespace: String, key: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace):\(key)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return uuid(from: bytes)
    }

    private static func uuid(from bytes: [UInt8]) -> UUID {
        UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                   bytes[4], bytes[5], bytes[6], bytes[7],
                   bytes[8], bytes[9], bytes[10], bytes[11],
                   bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
