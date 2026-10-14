//
//  PlatformHotPathCachesTests.swift
//  AIObservatoryPlatformTests — AgentDetection 子模块
//
//  Owner: WS-Platform
//  ─────────────────────────────────────────────────────────
//  热路径上两处「按整机的属性记忆化」的基座，以及它们真的被接进检出链的证据。
//
//  钉的两个缺陷（都是 release 实测 + 1 ms 采样定位的，不是推测）：
//   1. `BundleIdentifierStrategy` 原先对**每条**进程记录各调一次 `Bundle(url:)`
//      （`-[NSBundle initWithPath:]` 做 symlink 解析 + Info.plist 读取，实测叶帧
//      落在 `_NSResolveSymlinksInPathUsingC` / `lstat`），而真机一个 tick 的
//      **1082 条记录里只有 75 个不同的 `.app`** —— 同一个应用的十几个 helper 各自把
//      同一份 Info.plist 读一遍。
//   2. `LibprocProcessInspector` 原先对**每条**带 tty 的记录各调一次 `devname`
//      （`devname_r` 遍历设备表并解析符号链接，实测叶帧是 `lstat`），占全进程在算时间的
//      约 9%（90 / 1034 条采样）—— 而「设备号 → 名字」是**整机的属性**，不是进程的属性。
//
//  三组口径，逐条可核对：
//   · 去重键是「包路径 / 设备号」而不是「进程」⇒ 计数只等于不同键的个数；
//   · **读不到也记一笔**（负缓存）：少了它，无 Info.plist 的包每轮都要重读，
//     「把 `读不到` 当成 `没查过`」正是这类缓存最常见的漏法；
//   · 容量上限可算：超出 `capacity` 个不同路径时整表作废重新学（代价上界有界，不无界增长）。
//
//  最后一条接线用例证明「生产真的走到」：前几组用的是注入的假 reader，把策略里的
//  memo 换掉它们照样绿。
//
//  期望值全部是旁算出来的字面量（算式写在断言旁边）。
//

import Testing
import Foundation
import os
@testable import AIObservatoryPlatform
import AIObservatoryCore

// MARK: - 测试用替身

/// 只回一份固定快照的桩采集器（不碰真进程表）。
private struct FixedSnapshotInspector: ProcessInspecting {
    let records: [ProcessRecord]
    func scanProcesses() async -> [ProcessRecord] { records }
}

/// 只记录「自己被咨询了几次」的策略：判定恒为 nil，计数就是链真的走到过这里的证据。
private final class CountingStrategy: AgentDetectionStrategy, Sendable {
    let name = "ConsultationCounter"

    private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)

    func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        counter.withLock { $0 += 1 }
        return nil
    }

    /// 被 `detect` 命中的次数。
    var consultations: Int { counter.withLock { $0 } }
}

// MARK: - 1. Bundle Identifier 读取按包路径去重

@Suite("WS-Platform：Bundle Identifier 读取按包路径去重", .timeLimit(.minutes(1)))
struct AppBundleIdentifierMemoTests {

    /// 钉的是「按包路径去重」这条键口径：`diskReads` 必须等于**不同包路径的个数**，
    /// 而不是查询次数。绑的口径：同一个 `.app` 一轮只向磁盘问一次；命中缓存不再碰磁盘。
    @Test("1000 次查询 / 40 个不同包 ⇒ 只读 40 次，且值没有串台")
    func deduplicatesByBundlePath() {
        // reader：返回值里带上包名，这样「值串台」会被下面的 App7 断言抓到。
        let readBundleID: @Sendable (String) -> String? = { path in
            path.split(separator: "/").last.map { "id:\($0)" }
        }
        let memo = AppBundleIdentifierMemo(reader: readBundleID)     // capacity 默认 256 > 40

        let paths = (0..<40).map { "/Applications/App\($0).app" }
        for _ in 0..<25 {                    // 25 轮，模拟 25 个 tick 的重复扫描
            for path in paths { _ = memo.identifier(forAppBundle: path) }
        }

        // 期望值旁算：不同包路径 40 个 ⇒ 真实读取 40 次；查询 40 × 25 = 1000 次。
        // 改前（无 memo 的形状）这里是 1000 次磁盘读取。
        #expect(memo.diskReads == 40, "1000 次查询里只有 40 个不同包路径 ⇒ 磁盘只该被问 40 次，实测 \(memo.diskReads)")
        #expect(memo.lookups == 1000, "查询计数 = 40 × 25 = 1000（它才是「走到这条策略的记录数」那一侧的数）")

        // 值必须与键对应（缓存写串了键就会在这里暴露）。
        #expect(
            memo.identifier(forAppBundle: "/Applications/App7.app") == "id:App7.app",
            "第 7 个包拿回了别的包的 Identifier ⇒ 记忆化的键写错了"
        )
        // 上面那次是命中，不许再去读磁盘。
        #expect(memo.diskReads == 40, "命中缓存的那次查询又去读了磁盘")
    }

    /// 钉的是负缓存：reader 恒返回 nil 时，一个路径只能被问一次。
    /// 少了这一笔，「无 Info.plist 的包」在每个 tick 都要重读一遍磁盘仍然什么也读不到——
    /// 那正是「把 `读不到` 当成 `没查过`」的缺陷形状。
    @Test("读不到也记一笔：同一个读不出的包 5 次查询只问 1 次")
    func negativeCacheForUnreadableBundles() {
        let readNothing: @Sendable (String) -> String? = { _ in nil }
        let memo = AppBundleIdentifierMemo(capacity: 8, reader: readNothing)

        var results: [String?] = []
        for _ in 0..<5 { results.append(memo.identifier(forAppBundle: "/Applications/NoInfoPlist.app")) }

        let allNil: [String?] = Array(repeating: nil, count: 5)
        #expect(results == allNil, "5 次查询结果必须全是 nil（读不到就是读不到，不许编一个 ID 出来）")
        #expect(memo.diskReads == 1, "负缓存缺失 ⇒ 读不到的包每轮重读：期望 1 次，实测 \(memo.diskReads)")
        #expect(memo.lookups == 5, "被查询 5 次都要记进计数（它对应「走到这条策略的记录数」）")
    }

    /// 钉的是容量上限这条口径：**超出 capacity 个不同路径时整表作废重新学**。
    /// 期望值 6 的推导（判据是 `已记条目数 > capacity`，且发生在**读之前**）：
    ///   查 A → 读 1 次（表内 0 条 ⇒ 0 > 3 不成立）
    ///   查 B → 读 1 次（累计 2；判据 1 > 3 不成立）
    ///   查 C → 读 1 次（累计 3；判据 2 > 3 不成立）
    ///   查 D → 读 1 次（累计 4；判据 3 > 3 不成立 —— 严格大于，所以第 capacity+1 个仍先读）
    ///   查 E → 判据 4 > 3 成立 ⇒ 整表作废后重读 E（累计 5）
    ///   查 A → 已被作废 ⇒ 重读（累计 6）
    /// 绑的口径：不无界增长，且作废之后仍能重新学到（不是「作废即永久读不到」）。
    @Test("超出 capacity 整表作废：diskReads 恰好 6，且作废后 A 重新学到")
    func evictsWholeTableBeyondCapacity() {
        let readAnything: @Sendable (String) -> String? = { path in "id:\(path)" }
        let memo = AppBundleIdentifierMemo(capacity: 3, reader: readAnything)

        for path in ["A", "B", "C", "D"] { _ = memo.identifier(forAppBundle: path) }
        #expect(memo.diskReads == 4, "前 4 个不同路径都该各读一次（判据是严格大于 capacity=3）")

        #expect(memo.identifier(forAppBundle: "E") == "id:E", "E 自己也要读")
        #expect(memo.diskReads == 5, "读 E 之前表里已有 4 条 ⇒ 4 > 3 成立 ⇒ 整表作废后重读 E，累计 5")

        // A 已随整表作废而去：必须重新读、重新学到，而不是永久返回 nil。
        #expect(
            memo.identifier(forAppBundle: "A") == "id:A",
            "整表作废后 A 必须能重新学到（作废 ≠ 拉黑）"
        )
        #expect(memo.diskReads == 6, "按上面的推导总读取次数恰好 6（既不是 5「作废后不再读」，也不是无界增长）")
    }
}

// MARK: - 2. 终端设备名按设备号去重

@Suite("WS-Platform：终端设备名解析按设备号去重", .timeLimit(.minutes(1)))
struct DeviceNameMemoTests {

    /// 钉的是「按设备号去重」：`resolutions` 必须等于**不同设备号个数**。
    /// 绑的口径：设备号→名字是整机属性，一个 tick 里同一个号最多付一次真解析
    /// （`devname` 的叶帧实测是 `lstat`）。
    @Test("200 次查询 / 5 个设备号 ⇒ 只解析 5 次，且值没有串台")
    func deduplicatesByDeviceNumber() {
        let resolve: @Sendable (UInt32) -> String? = { dev in "ttys\(dev % 100)" }
        let memo = DeviceNameMemo(resolver: resolve)

        for _ in 0..<40 {                    // 40 轮
            for dev in UInt32(1)...UInt32(5) { _ = memo.name(forDeviceNumber: dev) }
        }

        // 期望值旁算：不同设备号 5 个 ⇒ 真解析 5 次；查询 5 × 40 = 200 次。
        #expect(memo.resolutionCount == 5, "一轮里同一个设备号最多解析一次：期望 5，实测 \(memo.resolutionCount)")
        #expect(memo.lookupCount == 200, "查询计数 = 5 × 40 = 200")

        #expect(memo.name(forDeviceNumber: 3) == "ttys3", "返回值必须挂在它自己的设备号上")
        #expect(memo.resolutionCount == 5, "命中缓存的那次不许再解析")
    }

    /// 钉的是「0 是值，不是哨兵」：`e_tdev == 0` 表示**没有控制终端**，
    /// 它压根不该进记忆化（实现里的 guard 在加锁之前）⇒ 一次计数都不该有。
    /// 少了这条 guard，全机几十个无 tty 的守护进程会把 0 当成一个待解析的号，
    /// 每轮白问一次注定没有答案的问题。
    @Test("dev 0 = 没有控制终端：直接 nil，一次查询都不记")
    func zeroMeansNoControllingTerminal() {
        let resolve: @Sendable (UInt32) -> String? = { dev in "ttys\(dev % 100)" }
        let memo = DeviceNameMemo(resolver: resolve)

        #expect(memo.name(forDeviceNumber: 0) == nil, "0 必须解析成「没有控制终端」= nil，而不是 \"ttys0\"")
        #expect(memo.lookupCount == 0, "0 根本不该走到记忆化（guard 在加锁之前）⇒ 查询计数期望 0")
        #expect(memo.resolutionCount == 0, "同上，真解析次数期望 0")
    }

    /// 钉的是设备号侧的负缓存：`devname` 认不出的号也要记一笔，否则每轮重问。
    @Test("解析失败也负缓存：同一个解析不出的号 4 次查询只问 1 次")
    func negativeCacheForUnresolvedDevices() {
        let resolve: @Sendable (UInt32) -> String? = { dev in dev == 7 ? nil : "ttys\(dev % 100)" }
        let memo = DeviceNameMemo(resolver: resolve)

        var results: [String?] = []
        for _ in 0..<4 { results.append(memo.name(forDeviceNumber: 7)) }

        let allNil: [String?] = Array(repeating: nil, count: 4)
        #expect(results == allNil, "解析不出名字就返回 nil，不许拿设备号拼个假名字顶上")
        #expect(memo.resolutionCount == 1, "解析失败的号也要记一笔：期望只问 1 次，实测 \(memo.resolutionCount)")
        #expect(memo.lookupCount == 4, "4 次查询都记在查询计数里")
    }
}

// MARK: - 3. 接线证据：基座真的在热路径上被走到

@Suite("WS-Platform：两处基座与整链闸门真的接在热路径上", .timeLimit(.minutes(1)))
struct HotPathWiringTests {

    /// 被提到策略链**外面**的那道闸门：命中系统路径的记录一次都不该被咨询。
    /// 原始形状：六条策略各自第一行都是同一句闸门，于是每条系统进程记录要付六次同样的判定
    /// （真机 1082 条里大部分是系统进程）。现在 pipeline 先算一次、命中即 `continue`。
    ///
    /// ⚠️ 两半必须在同一条用例里：只有 0 是可以被「桩压根没生效」伪造的，
    /// 只有 ≥1 是可以被「闸门没生效」伪造的。
    @Test("系统闸门整链只算一次：系统记录咨询 0 次，非系统记录仍被咨询")
    func systemGateLiftedOutOfStrategyChain() async {
        // 真机 N4 那条记录的原始路径：macOS 文本输入候选窗服务（`.xpc` 内部 + /System 前缀）。
        let systemRecord = ProcessRecord(
            pid: 1342,
            name: "CursorUIViewService",
            executablePath: "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/"
                + "Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService",
            arguments: ["CursorUIViewService", "-service-type", "cursor"]
        )
        let gateBlocked = CountingStrategy()
        let blockedAgents = await AgentDetectionPipeline(strategies: [gateBlocked])
            .detectAgents(using: FixedSnapshotInspector(records: [systemRecord]))
        #expect(
            gateBlocked.consultations == 0,
            "命中系统闸门的记录又被咨询了 \(gateBlocked.consultations) 次 ⇒ 闸门没被提到链外（或干脆没了）"
        )
        #expect(blockedAgents.isEmpty, "系统 XPC 服务绝不该产出 Agent 实例")

        // 对照组：同一套桩、同一条链，只把记录换成非系统路径 ⇒ 必须被咨询。
        // 这一步证明上面那个 0 不是「桩没生效 / 链没跑起来」造成的假绿。
        let userRecord = ProcessRecord(
            pid: 2001,
            name: "claude",
            executablePath: "/usr/local/bin/claude",
            arguments: ["claude", "--version"]
        )
        let control = CountingStrategy()
        _ = await AgentDetectionPipeline(strategies: [control])
            .detectAgents(using: FixedSnapshotInspector(records: [userRecord]))
        #expect(control.consultations >= 1, "非系统路径一次都没被咨询 ⇒ 上面那个 0 是桩没生效，不是闸门在起作用")
    }

    /// 钉的是「memo 真的在 `BundleIdentifierStrategy` 里被用到」，两半：
    ///  · 12 条同包记录只读 1 次磁盘（键 = 最外层 `.app`，与归并口径同一个键集）；
    ///  · 每条都拿到非 nil 且 kind == .windsurf —— 本桩里唯一的证据来源就是 memo 返回值，
    ///    所以这条同时证明「memo 的值真的进了匹配器」，而不是只被缓存了没人用。
    /// （若策略退回用 `Bundle(url:)` 自己读，或读了不用于匹配，这两处都会失败。）
    @Test("BundleIdentifierStrategy 走 memo：12 条同包记录只读 1 次，且值进了匹配器")
    func bundleIdentifierStrategyReadsThroughMemo() {
        let readWindsurf: @Sendable (String) -> String? = { _ in "com.windsurf" }
        let memo = AppBundleIdentifierMemo(capacity: 256, reader: readWindsurf)
        let strategy = BundleIdentifierStrategy(bundleIDs: memo)

        let path = "/Applications/Windsurf.app/Contents/MacOS/Windsurf"
        for index in 0..<12 {
            let record = ProcessRecord(
                pid: Int32(7_000 + index),
                name: "Windsurf",
                executablePath: path,
                arguments: ["Windsurf"]
            )
            let result = strategy.detect(record, context: DetectionContext())
            #expect(result != nil, "第 \(index) 条：memo 供上了 com.windsurf 却没检出 ⇒ 值没进匹配器")
            #expect(result?.kind == .windsurf, "第 \(index) 条：期望 .windsurf，拿到 \(String(describing: result?.kind))")
        }

        #expect(memo.diskReads == 1, "12 条记录同属一个 `.app` ⇒ 磁盘只该读 1 次，实测 \(memo.diskReads)")
        #expect(memo.lookups == 12, "每条记录各问一次 memo ⇒ 期望 12，实测 \(memo.lookups)")
    }

    /// 钉的是「真实采集器**确实**在用 `DeviceNameMemo`」——只测 memo 本身会留下
    /// 「测试绿、生产没接到」的假绿灯（本仓在 `ProcessMetricsReading` 上栽过一次）。
    ///
    /// 期望值是旁算的：一次全表扫描对每条「有控制终端」的记录最多问 memo 一次，
    /// 所以**第二轮的查询次数必然再涨**；而真解析次数只取决于**不同设备号**的个数，
    /// 第二轮没有任何新设备号 ⇒ 一次都不许再涨。改前没有这条通路（每条记录现解析），
    /// 把接线换成直接 `devname` 就会让 resolutions 随扫描轮数线性增长 ⇒ 本用例变红。
    @Test("真实采集器两轮扫描：查询次数再涨，解析次数一次都不许多")
    func realInspectorResolvesDeviceNamesOnceAcrossScans() async {
        let inspector = LibprocProcessInspector()
        let first = await inspector.scanProcesses()
        let lookupsAfter1 = inspector.deviceNames.lookupCount
        let resolutionsAfter1 = inspector.deviceNames.resolutionCount
        // 环境里一个带 tty 的进程都没有 ⇒ 这条通路根本没被走到，判红而不是静默通过。
        #expect(lookupsAfter1 > 0, "两轮快照里没有任何带控制终端的进程，本用例失去意义")

        let second = await inspector.scanProcesses()
        #expect(second.count >= first.count / 2, "第二轮快照几乎空了 ⇒ 后面的计数没有可比性")
        let lookupsAfter2 = inspector.deviceNames.lookupCount
        #expect(lookupsAfter2 > lookupsAfter1, "第二轮一次都没再查终端名 ⇒ memo 接线又没了")
        #expect(
            inspector.deviceNames.resolutionCount == resolutionsAfter1,
            "第二轮又多解析了 \(inspector.deviceNames.resolutionCount - resolutionsAfter1) 次终端名 ⇒ memo 没接上"
        )
    }
}
