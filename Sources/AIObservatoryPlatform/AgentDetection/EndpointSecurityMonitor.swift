//
//  EndpointSecurityMonitor.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Agent
//  ─────────────────────────────────────────────────────────
//  EndpointSecurity（ES）实时监控骨架。
//
//  关键约束：
//   · ES 归属 `com.apple.endpointsecurity.client` 授权（entitlement）。
//     当前进程（含 `swift test` 产物）并无该授权，因此本实现**必定**
//     优雅降级为 `.processPolling`，绝不因 ES 不可用而构建失败或崩溃。
//   · 采用 `dlopen` / `dlsym` 弱链接方式探测，避免对未声明依赖的框架产生
//     链接需求（Package.swift 为冻结区，不可为其新增系统库依赖）。
//   · 任何异常路径都安全回退到轮询模式——这是「可选能力」的应有之义。
//
//  该类型仅做能力探测（骨架），并不真正订阅 ES 事件流；真正的事件订阅
//  属于后续里程碑，且需要配套的授权与后台常驻进程。
//

import Foundation
import Darwin
import AIObservatoryCore

/// `es_new_client` 的函数指针签名（弱链接，不引入链接依赖）。
typealias ESNewClient = @convention(c) (
    UnsafeMutablePointer<Optional<OpaquePointer>>,
    @convention(block) (OpaquePointer, OpaquePointer) -> Void
) -> Int32

/// `es_delete_client` 的函数指针签名。
typealias ESDeleteClient = @convention(c) (Optional<OpaquePointer>) -> Int32

/// EndpointSecurity 实时监控能力探测器（骨架）。
public enum EndpointSecurityMonitor {

    /// 探测当前进程是否具备 EndpointSecurity 实时能力。
    ///
    /// 通过 `dlopen` 动态加载 ES 框架并 `dlsym` 取出 `es_new_client`：
    ///   - 框架不可用 / 符号缺失 → `.processPolling`。
    ///   - `es_new_client` 调用成功（仅在有 entitlement 时发生）→ `.endPointSecurity`。
    ///   - 无授权 / 任何失败 → `.processPolling`（优雅降级，绝不抛错或崩溃）。
    ///
    /// 该调用在无授权的进程上会由内核**立即返回错误**，不会阻塞或挂起。
    public static func probeCapability() -> RealtimeCapability {
        guard let handle = dlopen(esFrameworkPath, RTLD_LAZY) else {
            return .processPolling
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "es_new_client") else {
            return .processPolling
        }
        let newClient = unsafeBitCast(sym, to: ESNewClient.self)

        var client: OpaquePointer?
        let handler: @convention(block) (OpaquePointer, OpaquePointer) -> Void = { _, _ in }
        let result = newClient(&client, handler)

        // ES_NEW_CLIENT_RESULT_SUCCESS == 0
        if result == 0 {
            if let c = client, let delSym = dlsym(handle, "es_delete_client") {
                let deleteClient = unsafeBitCast(delSym, to: ESDeleteClient.self)
                _ = deleteClient(c)
            }
            return .endPointSecurity
        }
        return .processPolling
    }

    /// ES 框架在 macOS SDK 中的标准路径。
    private static let esFrameworkPath =
        "/System/Library/Frameworks/EndpointSecurity.framework/EndpointSecurity"
}
