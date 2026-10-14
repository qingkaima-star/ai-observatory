//
//  BoundedPerformanceReadContractTests.swift
//  Tests/AIObservatorySwiftDataStoreTests
//
//  Owner: ws/engaudit（ICR-0007 落地，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  ICR-0007 把两个带 `limit:` 的取数从"具体类型上的额外能力"升成 **契约成员**，
//  并给了一份默认实现（转调无界版再截断），好让既有的内存参考实现、界面预览桩、
//  测试替身不改一行也能满足新契约。
//
//  这里判三件事，一件都不能少：
//   1. **默认实现本身能用**（否则它就是又一条"有定义没生产者"的成员）；
//   2. **两个真后端都重写了它**——这是总控点名的那条。默认实现的行为与重写版
//      在**结果上完全相同**（同一批行、同一个序），所以语义断言抓不到"忘了重写"；
//      能抓到的只有**成本**：重写版把截断推进查询，默认版先把整段解出来。
//      于是这条用例用进程 CPU 时间做比值，并先钉住"仪器必须有读数"
//      （无界版每次调用必须明显花到某个量级以上，否则比值是噪声算出来的）。
//   3. **通过协议存在类型调用时，走的就是重写版**（否则界面换了调用点也没用）。
//
//  阈值来源：先实测比值，再按实测余量的**保守一侧**定（不是反过来先定阈值再凑数据）。
//

import Foundation
import Testing
import Darwin
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport
@testable import AIObservatorySwiftDataStore

// MARK: - 夹具

private let contractBase = Date(timeIntervalSinceReferenceDate: 800_012_000)
private let contractRows = 4_000
private let contractLimit = 20
/// 比值测量的重复次数（单次太短，读数会落到噪声里）。
private let contractRepeats = 20

private enum ContractSeed {
    static let session = UUID()
    static let agent = UUID()

    static func sample(_ index: Int) -> PerformanceSample {
        PerformanceSample(
            id: StableID.uuid(namespace: "boundedcontract", key: "session-\(index)"),
            timestamp: contractBase.addingTimeInterval(Double(index)),
            sessionID: session,
            agentID: agent,
            cpuPercent: Double(index % 90),
            memoryBytes: UInt64(2_048 * (index + 1))
        )
    }
}

/// 进程累计 CPU 时间（纳秒）。用 `CLOCK_PROCESS_CPUTIME_ID` 而不是墙钟：
/// 这条要证的是"少做了一半的解码"，墙钟会被调度与 I/O 噪声带走（AGENTS §6 的口径）。
private func processCPUSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}

// MARK: - 1. 默认实现

@Suite("带上限取数：契约的默认实现")
struct BoundedReadDefaultImplementationTests {

    @Test("没重写的 conformer：默认实现转调无界版并取尾部 limit 条，非正数返回空")
    func fallbackForwardsAndTruncates() async throws {
        // InMemoryObservatoryService 只实现了无界那两条 ⇒ 走的就是协议默认实现。
        let samples = (0..<10).map(ContractSeed.sample)
        let service = InMemoryObservatoryService()
        service.seed(performance: samples)
        let bounded = try await service.performanceSamples(sessionID: ContractSeed.session, limit: 4)
        #expect(bounded.count == 4)
        // 手推：10 条升序、取最后 4 条 ⇒ index 6,7,8,9。
        #expect(bounded.map(\.cpuPercent) == [6, 7, 8, 9])
        #expect(try await service.performanceSamples(sessionID: ContractSeed.session, limit: 0).isEmpty)
        #expect(try await service.performanceSamples(sessionID: ContractSeed.session, limit: -5).isEmpty)
    }
}

// MARK: - 2/3. 两个真后端都重写了它

@Suite("带上限取数：两个真后端都把默认实现重写成了查询级截断")
struct BoundedReadOverrideTests {

    private func makeSeededPair() async throws -> (ObservatoryStore, SwiftDataObservatoryStore) {
        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        for index in 0..<contractRows {
            await sqlite.append(ContractSeed.sample(index))
            await swiftData.append(ContractSeed.sample(index))
        }
        await sqlite.flush()
        await swiftData.flush()
        return (sqlite, swiftData)
    }

    @Test("SQLite：带上限的读法不是默认实现（成本比值），且经协议调用时走的就是它")
    func sqliteOverridesTheDefault() async throws {
        let (sqlite, _) = try await makeSeededPair()
        try await assertOverride(store: sqlite, label: "SQLite")
    }

    @Test("SwiftData：带上限的读法不是默认实现（成本比值），且经协议调用时走的就是它")
    func swiftDataOverridesTheDefault() async throws {
        let (_, swiftData) = try await makeSeededPair()
        try await assertOverride(store: swiftData, label: "SwiftData")
    }

    /// 三件事一起判：结果对、经协议存在类型也对、且**成本上明显不是"先整段捞回"**。
    private func assertOverride(store: some ObservatoryService, label: String) async throws {
        // ① 结果口径（与无界版的尾部逐元素相等，这条默认实现也能过——它不是用来区分重写的）
        let all = try await store.performanceSamples(sessionID: ContractSeed.session)
        #expect(all.count == contractRows, "\(label) 侧夹具没塞够：\(all.count)")
        let bounded = try await store.performanceSamples(sessionID: ContractSeed.session, limit: contractLimit)
        #expect(bounded.count == contractLimit)
        #expect(bounded.map(\.id) == Array(all.suffix(contractLimit)).map(\.id), "\(label) 侧取的不是最新的 \(contractLimit) 条")

        // ② 仪器闸门：无界版每次调用必须真的贵到可测。测不出来就说"测不出来"，
        //    不许把比值断言在噪声上跑绿（那是把这条用例变成装饰）。
        let unboundedStart = processCPUSeconds()
        for _ in 0..<contractRepeats {
            _ = try await store.performanceSamples(sessionID: ContractSeed.session)
        }
        let unboundedPerCall = (processCPUSeconds() - unboundedStart) / Double(contractRepeats)
        #expect(
            unboundedPerCall > 0.000_2,
            "\(label)：无界版每次只花 \(unboundedPerCall * 1_000) ms，仪器读不出差别——这条断言不该在噪声上判绿"
        )

        // ③ 比值：重写版必须把整段解码省掉。默认实现会先解 contractRows 行再丢掉绝大部分，
        //    所以它的成本与无界版同量级（比值 ≈ 1）；查询级 LIMIT 只解 contractLimit 行。
        //    本机实测（4 000 行、limit 20、20 次重复）：SQLite 37.66 ms → 0.226 ms（**166 倍**），
        //    SwiftData 81.78 ms → 1.189 ms（**69 倍**）；变异（把 SQLite 的重写改名让它落回默认实现）
        //    实测比值 1.0035 ⇒ 那条断言真的会红。阈值定在 8 倍是**保守一侧**，不是先定阈值再凑数。
        let boundedStart = processCPUSeconds()
        for _ in 0..<contractRepeats {
            _ = try await store.performanceSamples(sessionID: ContractSeed.session, limit: contractLimit)
        }
        let boundedPerCall = (processCPUSeconds() - boundedStart) / Double(contractRepeats)
        let ratio = unboundedPerCall / boundedPerCall
        #expect(
            ratio > 8,
            "\(label)：带上限版每次 \(boundedPerCall * 1_000) ms、无界版 \(unboundedPerCall * 1_000) ms，比值 \(ratio) ⇒ 截断没有落到查询里，走的还是契约默认实现（整段捞回再丢）"
        )
    }
}
