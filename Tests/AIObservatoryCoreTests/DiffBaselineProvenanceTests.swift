//
//  DiffBaselineProvenanceTests.swift
//  AIObservatoryCoreTests
//
//  Owner: WS-Diff
//  ─────────────────────────────────────────────────────────
//  守的是「给已落库的结构加字段会不会静默清掉老数据」这条升级路径，
//  以及「Before 从哪来」这个信息在序列化后还认不认得出来。
//
//  为什么单独一个文件：`FileDiff` 是**已经写在用户磁盘上**的行内 JSON 与 `diffs` 表
//  共同承载的类型。Swift 合成的 `Decodable` 不会拿属性默认值补缺失的键
//  （同一族的事故见 `SettingsDecodingCompatibilityTests`），所以这里逐键删、逐个值验。
//  期望值全部手写字面量，不拿 `FileDiff` 的默认值当期望（那是自我对账）。
//

import Foundation
import Testing
@testable import AIObservatoryCore

// MARK: - 夹具

private let capturedAt = Date(timeIntervalSinceReferenceDate: 750_000_456.789)
private let baselineAt = Date(timeIntervalSinceReferenceDate: 750_000_123.456)

/// 一份**每个字段都互不相同、且都不等于默认值**的 diff。
/// 默认值全等于期望值时，「读到了」与「悄悄回落」是区分不出来的。
private func distinctiveDiff(source: DiffBaselineSource, baseline: Date?) -> FileDiff {
    FileDiff(
        path: "/repo/Sources/Auth.swift",
        previousPath: "/repo/Sources/AuthToken.swift",
        kind: .modified,
        lines: [
            DiffLine(style: .hunkHeader, text: "@@ -1,3 +1,3 @@", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(style: .removed, text: "let token = \"old\"", oldLineNumber: 2),
            DiffLine(style: .added, text: "let token = config.apiToken", newLineNumber: 2),
            DiffLine(style: .context, text: "}", oldLineNumber: 3, newLineNumber: 3),
        ],
        linesAdded: 1,
        linesRemoved: 1,
        isBinary: false,
        isTruncated: true,
        capturedAt: capturedAt,
        baselineSource: source,
        baselineCapturedAt: baseline
    )
}

private func jsonObject(from diff: FileDiff) throws -> [String: Any] {
    let data = try JSONEncoder().encode(diff)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProvenanceError.notAnObject
    }
    return object
}

private func decode(_ object: [String: Any]) throws -> FileDiff {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(FileDiff.self, from: data)
}

private enum ProvenanceError: Error {
    case notAnObject
}

/// 除溯源两列之外的字段必须一个都不动 —— 「加一个字段把别的老数据一起重置」就是这么被漏掉的。
private func expectBusinessFields(_ diff: FileDiff, matches original: FileDiff) {
    #expect(diff.id == original.id)
    #expect(diff.path == "/repo/Sources/Auth.swift")
    #expect(diff.previousPath == "/repo/Sources/AuthToken.swift")
    #expect(diff.kind == .modified)
    #expect(diff.lines.count == 4)
    #expect(diff.lines.map(\.style) == [.hunkHeader, .removed, .added, .context])
    #expect(diff.lines.map(\.text) == [
        "@@ -1,3 +1,3 @@", "let token = \"old\"", "let token = config.apiToken", "}",
    ])
    #expect(diff.linesAdded == 1)
    #expect(diff.linesRemoved == 1)
    #expect(diff.isBinary == false)
    #expect(diff.isTruncated == true, "缺键时不得把真量到的标志位重置掉")
    #expect(diff.capturedAt == capturedAt)
}

// MARK: - 溯源字段本身

@Suite("Core: DiffBaselineSource 与 FileDiff 溯源字段", .timeLimit(.minutes(1)))
struct DiffBaselineProvenanceTests {

    @Test("rawValue 是落库字符串：改名等于把历史行重新分类")
    func rawValuesArePinned() {
        #expect(DiffBaselineSource.lastObserved.rawValue == "lastObserved")
        #expect(DiffBaselineSource.unavailableFirstSighting.rawValue == "unavailableFirstSighting")
        #expect(DiffBaselineSource.notApplicable.rawValue == "notApplicable")
    }

    /// 既有构造点（`MyersDiffEngine`、UI 预览工厂、各测试夹具）都没传溯源参数，
    /// 默认值必须是**不声称自己有过 Before** 的那一个。
    @Test("不带溯源参数的构造点默认 notApplicable")
    func legacyInitializerDefaultsToNotApplicable() {
        let diff = FileDiff(path: "/repo/a.txt", kind: .created)
        #expect(diff.baselineSource == .notApplicable)
        #expect(diff.baselineCapturedAt == nil)
    }

    @Test("显式 lastObserved + 时刻：编码写出键名与 rawValue 字面量")
    func encodesPinnedKeys() throws {
        let object = try jsonObject(from: distinctiveDiff(source: .lastObserved, baseline: baselineAt))
        #expect(object["baselineSource"] as? String == "lastObserved")
        // `Date` 走 `.deferredToDate` ⇒ JSON 里是 `timeIntervalSinceReferenceDate` 数值。
        // 时刻带小数是必需的：整数值会被归一化成整型，测不出编码口径（库内教训 M11 同族）。
        #expect(object["baselineCapturedAt"] as? Double == baselineAt.timeIntervalSinceReferenceDate)
    }
}

// MARK: - 老数据 + 新代码

@Suite("Core: 老 diff JSON 缺溯源键时必须还解得开")
struct LegacyDiffDecodingTests {

    /// 本任务最核心的兼容性用例：缺键 ≠ 解码失败。
    /// 解码失败会让整条 diff 消失（`lines_json` 那侧是「解不开就丢行」的严格策略），
    /// 而「丢弃历史 diff」对用户就是「升级之后以前的 diff 全没了」。
    @Test("两个溯源键都缺 ⇒ 回落单边 diff，其余字段一个不动")
    func missingBothProvenanceKeysFallsBack() throws {
        let original = distinctiveDiff(source: .lastObserved, baseline: baselineAt)
        var object = try jsonObject(from: original)
        object.removeValue(forKey: "baselineSource")
        object.removeValue(forKey: "baselineCapturedAt")

        let restored = try decode(object)
        // 回落值不是「什么都不说」的 notApplicable：写这份 JSON 的旧代码 `oldText` 恒为 nil，
        // 它产出的每一条 diff 客观上都是单边 diff。说 notApplicable 会把「可比」与
        // 「不适用」混为一谈，而 UI 恰恰要按这个字段决定措辞。
        #expect(restored.baselineSource == .unavailableFirstSighting)
        #expect(restored.baselineCapturedAt == nil)
        expectBusinessFields(restored, matches: original)
    }

    @Test("只缺 baselineSource ⇒ 回落单边 diff，但已记录的时刻仍要读回来")
    func missingSourceOnlyKeepsTimestamp() throws {
        let original = distinctiveDiff(source: .lastObserved, baseline: baselineAt)
        var object = try jsonObject(from: original)
        object.removeValue(forKey: "baselineSource")

        let restored = try decode(object)
        #expect(restored.baselineSource == .unavailableFirstSighting)
        #expect(restored.baselineCapturedAt == baselineAt)
        expectBusinessFields(restored, matches: original)
    }

    @Test("只缺 baselineCapturedAt ⇒ 溯源结论仍要读回来，时刻为 nil")
    func missingTimestampOnlyKeepsSource() throws {
        let original = distinctiveDiff(source: .lastObserved, baseline: baselineAt)
        var object = try jsonObject(from: original)
        object.removeValue(forKey: "baselineCapturedAt")

        let restored = try decode(object)
        #expect(restored.baselineSource == .lastObserved)
        #expect(restored.baselineCapturedAt == nil, "缺时刻不许造一个时刻出来")
        expectBusinessFields(restored, matches: original)
    }

    /// 「缺键」与「显式写了 notApplicable」必须是两件事，否则上面的回落值毫无信息量。
    @Test("显式 notApplicable 原样读回，不被回落成单边 diff")
    func explicitNotApplicableIsNotRewritten() throws {
        let original = distinctiveDiff(source: .notApplicable, baseline: nil)
        let restored = try decode(try jsonObject(from: original))
        #expect(restored.baselineSource == .notApplicable)
        #expect(restored.baselineCapturedAt == nil)
    }

    @Test("三个枚举值都无损往返")
    func everyCaseRoundTrips() throws {
        for source in [DiffBaselineSource.lastObserved, .unavailableFirstSighting, .notApplicable] {
            let original = distinctiveDiff(source: source, baseline: baselineAt)
            let restored = try decode(try jsonObject(from: original))
            #expect(restored.baselineSource == source)
            #expect(restored.baselineCapturedAt == baselineAt)
        }
    }

    /// 读不认识的 rawValue 时，最危险的失败模式是抛错 ⇒ 整条 diff 消失。
    /// 回落成「不可比」既不撒谎也不丢数据。
    @Test("未登记的 rawValue ⇒ 按不可比处理，不抛错也不丢 diff")
    func unknownRawValueDegradesWithoutThrowing() throws {
        let original = distinctiveDiff(source: .lastObserved, baseline: baselineAt)
        var object = try jsonObject(from: original)
        object["baselineSource"] = "gitHead"

        let restored = try decode(object)
        #expect(restored.baselineSource == .unavailableFirstSighting)
        expectBusinessFields(restored, matches: original)
    }
}
