//
//  RiskAssessorTests.swift
//  AIObservatoryRiskRulesTests
//
//  Owner: WS-Risk —— E 层（聚合策略 + 规则目录 + 契约符合性 + 端到端验收）
//
//  本文件**不**重复单条规则的内部行为（那部分在
//  `Rules/DestructiveAndSensitiveRuleTests.swift` 与 `Rules/CommandAndPatternRuleTests.swift`），
//  只测三件事：
//   1. `RiskRuleCatalog` 的清单完整性（33 条 / 无撞号 / 查询与描述符）；
//   2. `RiskAggregationPolicy` 的五步管线（地板抬升 → 抑制键折叠 → 同根因抑制 →
//      排序 → 排序后截断）与其**顺序无关性**；
//   3. `RiskAssessor` 的端到端验收场景（60 秒 42 条删除只出 1 条批量删除命中、
//      跨簇不折叠、跨窗口折叠、纯函数确定性、契约 `RiskEvaluating` 符合性、
//      `RiskFinding → RiskEvent` 降级映射）。
//
//  设计约束（AGENTS.md 第 5/7 条 + 风险规则库接口.md §5）：
//   · 全部为同步纯函数调用：不 `sleep`、不轮询、不 `Task.detached`、不碰文件系统，
//     因此每条测试都可终止。
//   · 时间与路径全部注入：固定基准 `eAnchor`（epoch 1_700_000_000 = 2023-11-14 22:13:20 UTC）、
//     固定 home `/Users/tester`、固定项目根 `/Users/tester/proj`、固定日历
//     `RiskFactWindow.gregorianUTC`，显式传 `start:` / `end:`。严禁 `Date()` / `Date.now`。
//   · 断言按 `AiX-Vault/01-架构/风险规则库接口.md` §4 + §6 的**规格**写，
//     不按实现的临时行为放宽；达不到规格的条目在交付报告里登记为"实现不符合规格"。
//   · helper 名一律带 `e` 前缀（E 层），与另两个测试文件的
//     `home / project / base / change / read / command / window / home2 / …` 完全错开。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryRiskRules

// MARK: - 测试骨架（文件私有）

/// 注入的宿主主目录（绝不读真实 `NSHomeDirectory()`）。
private let eHome = "/Users/tester"

/// 注入的会话项目根 = 本文件唯一的允许写入根。
private let eProject = "/Users/tester/proj"

/// 固定基准时刻（epoch 秒 1_700_000_000），所有事实相对它偏移。
private let eAnchor = Date(timeIntervalSince1970: 1_700_000_000)

/// 基准时刻 + 秒偏移。
private func eAt(_ offset: TimeInterval) -> Date {
    eAnchor.addingTimeInterval(offset)
}

/// 基准时刻的 epoch 秒（用于断言 `mass-deletion:<簇起点>` 这类抑制键）。
private func eEpoch(_ offset: TimeInterval) -> Int {
    Int(1_700_000_000 + offset)
}

/// 一条删除类文件变更。
private func eDeletion(_ path: String, at offset: TimeInterval) -> FileChange {
    FileChange(
        path: path,
        kind: .deleted,
        timestamp: eAt(offset),
        sizeBytes: 2_048,
        projectPath: eProject
    )
}

/// 一条写类文件变更。
private func eWrite(
    _ path: String,
    _ kind: FileChangeKind = .modified,
    at offset: TimeInterval = 0,
    added: Int = 0,
    removed: Int = 0,
    size: UInt64 = 1_024
) -> FileChange {
    FileChange(
        path: path,
        kind: kind,
        timestamp: eAt(offset),
        sizeBytes: size,
        linesAdded: added,
        linesRemoved: removed,
        projectPath: eProject
    )
}

/// 一条读取类时间线事件。
private func eRead(_ path: String, at offset: TimeInterval = 0) -> TimelineEvent {
    TimelineEvent(
        timestamp: eAt(offset),
        kind: .fileRead,
        title: "读取文件",
        summary: "E 层聚合测试注入的读取事实",
        filePath: path,
        projectPath: eProject
    )
}

/// 一条命令事实。
///
/// `id` 只用作 `telemetryClassifications` 的键与个别规则的抑制键；需要固定值的场景
/// 显式传 `id:`（见 `dangerousDeleteCommandAloneIsAssessed`）。未传时 ID 不参与任何
/// 跨窗口 / 跨构造的比较断言——每个测试内的窗口实例都被整体复用。
private func eCommand(
    _ executable: String,
    _ arguments: [String],
    at offset: TimeInterval = 0,
    id: UUID? = nil,
    destructive: Bool = false,
    level: RiskLevel = .low,
    confirmation: Bool = false,
    endsAfter extra: TimeInterval? = nil
) -> CommandRecord {
    CommandRecord(
        id: id ?? UUID(),
        executable: executable,
        arguments: arguments,
        workingDirectory: eProject,
        startedAt: eAt(offset),
        endedAt: extra.map { eAt($0) },
        exitCode: 0,
        outcome: .success,
        isDestructive: destructive,
        requiresConfirmation: confirmation,
        riskLevel: level,
        projectPath: eProject
    )
}

/// 同一父目录下连续 `count` 条删除事实，每条间隔 1 秒（默认落在 60 秒一簇内）。
private func eBurst(parent: String, count: Int, firstOffset: TimeInterval = 0) -> [FileChange] {
    (0..<count).map { index in
        eDeletion("\(parent)/\(index).swift", at: firstOffset + Double(index))
    }
}

/// 构造规则评估窗口：home / 日历 / 允许写入根 / 窗口起止全部注入。
private func eWindow(
    events: [TimelineEvent] = [],
    changes: [FileChange] = [],
    commands: [CommandRecord] = [],
    samples: [PerformanceSample] = [],
    start: Date = eAnchor,
    end: Date = eAt(7_200),
    roots: [String] = [eProject],
    trusted: [String] = [],
    thresholds: RiskThresholds = .standard,
    classifications: [UUID: CommandClassification] = [:],
    otherProjects: [String] = []
) -> RiskFactWindow {
    RiskFactWindow(
        events: events,
        fileChanges: changes,
        commands: commands,
        samples: samples,
        start: start,
        end: end,
        homeDirectory: eHome,
        allowedWriteRoots: roots,
        trustedWriteRoots: trusted,
        calendar: RiskFactWindow.gregorianUTC,
        thresholds: thresholds,
        telemetryClassifications: classifications,
        otherProjectRoots: otherProjects
    )
}

/// 手工构造一条命中（只用于聚合策略的白盒断言，不经过任何规则）。
private func eFinding(
    key: String,
    level: RiskLevel,
    family: RiskRuleFamily = .destructiveFileOperation,
    rule: String = "risk.test.synthetic",
    category: RiskCategory = .massDeletion,
    paths: [String] = [],
    at offset: TimeInterval = 0,
    evidence: Int = 1,
    confidence: Double = 0.8,
    confirmation: Bool = false,
    command: String? = nil
) -> RiskFinding {
    RiskFinding(
        ruleID: rule,
        family: family,
        category: category,
        level: level,
        title: "测试命中 \(key)",
        detail: "由 E 层聚合测试构造的合成命中：\(key)",
        confidence: confidence,
        requiresConfirmation: confirmation,
        timestamp: eAt(offset),
        sessionID: nil,
        agentID: nil,
        agentKind: .unknown,
        command: command,
        filePaths: paths,
        suppressionKey: key,
        evidenceCount: evidence,
        evidenceSpan: nil
    )
}

/// 命中集合的简要指纹，用于失败时定位。
private func eFingerprint(_ findings: [RiskFinding]) -> String {
    findings.map { "\($0.ruleID)/\($0.suppressionKey)/\($0.level.displayName)" }.joined(separator: " | ")
}

// MARK: - 规则目录

@Suite("WS-Risk E：规则目录 RiskRuleCatalog")
struct RiskRuleCatalogTests {

    @Test("标准目录 33 条（验收下限 25）、四族数量符合清单、无撞号")
    func standardCatalogMatchesRuleList() {
        let catalog = RiskRuleCatalog.standard
        #expect(catalog.count >= 25)
        #expect(catalog.count == 33)
        #expect(catalog.rules.count == catalog.count)
        #expect(
            catalog.duplicateRuleIDs.isEmpty,
            "目录里出现重复 rule id：\(catalog.duplicateRuleIDs)"
        )
        #expect(catalog.rules(in: .destructiveFileOperation).count == 6)
        #expect(catalog.rules(in: .sensitiveLocation).count == 9)
        #expect(catalog.rules(in: .commandBehavior).count == 11)
        #expect(catalog.rules(in: .activityPattern).count == 7)
        #expect(
            catalog.rules(in: .activityPattern).allSatisfy { $0.identity.family == .activityPattern }
        )
        #expect(catalog.rules(in: .commandBehavior).count
            + catalog.rules(in: .sensitiveLocation).count
            + catalog.rules(in: .destructiveFileOperation).count
            + catalog.rules(in: .activityPattern).count == catalog.count)
    }

    @Test("rule(withID:) 精确命中 / 未命中；descriptors 与 rules 同源且按 id 字典序")
    func lookupAndDescriptors() {
        let catalog = RiskRuleCatalog.standard
        #expect(
            catalog.rule(withID: "risk.destructive.mass-deletion-window")?.identity.family
                == .destructiveFileOperation
        )
        #expect(catalog.rule(withID: "risk.sensitive.dotenv-touch")?.identity.defaultLevel == .medium)
        #expect(catalog.rule(withID: "risk.does-not-exist") == nil)

        let descriptors = catalog.descriptors
        #expect(descriptors.count == catalog.count)
        let ids = descriptors.map(\.id)
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { !$0.isEmpty })
        #expect(descriptors.allSatisfy { !$0.name.isEmpty && !$0.summary.isEmpty })
        #expect(Set(ids) == Set(catalog.rules.map { $0.identity.id }))
    }

    @Test("自定义目录只装一条规则时，assess 只用该规则（目录即装配边界）")
    func customCatalogLimitsAssessment() {
        let catalog = RiskRuleCatalog(rules: [DFOMassDeletionWindowRule()])
        #expect(catalog.count == 1)
        #expect(catalog.duplicateRuleIDs.isEmpty)
        #expect(catalog.descriptors.map(\.id) == ["risk.destructive.mass-deletion-window"])
        #expect(catalog.rules(in: .sensitiveLocation).isEmpty)

        let burst = eBurst(parent: "\(eHome)/other-project/a", count: 42)
        let findings = RiskAssessor(catalog: catalog).assess(eWindow(changes: burst))
        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "risk.destructive.mass-deletion-window")
        #expect(findings.first?.level == .high)
        #expect(RiskAssessor(catalog: catalog).loadedRules().count == 1)
    }

    @Test("评估器属性回显注入的目录与策略")
    func assessorExposesInjectedDependencies() {
        let policy = RiskAggregationPolicy(maxFindings: 5)
        let assessor = RiskAssessor(catalog: .standard, policy: policy)
        #expect(assessor.policy == policy)
        #expect(assessor.policy.maxFindings == 5)
        #expect(assessor.catalog.count == RiskRuleCatalog.standard.count)
        #expect(RiskAssessor().policy == RiskAggregationPolicy.standard)
        #expect(RiskAssessor().catalog.count == 33)
    }
}

// MARK: - 聚合策略

@Suite("WS-Risk E：聚合策略 RiskAggregationPolicy")
struct RiskAggregationPolicyTests {

    @Test("标准策略参数符合规格 §6")
    func standardPolicyParameters() {
        let policy = RiskAggregationPolicy.standard
        #expect(policy.maxFindings == 24)
        #expect(policy.deduplicateBySuppressionKey)
        #expect(policy.suppressContainedFindings)
        #expect(policy.floorLevels.isEmpty)
        #expect(policy == RiskAggregationPolicy())
    }

    @Test("空批次与单条批次：apply 不凭空增减命中")
    func emptyAndSingletonBatches() {
        #expect(RiskAggregationPolicy.standard.apply([]).isEmpty)
        let only = eFinding(key: "mass-deletion:1", level: .medium, evidence: 9)
        let applied = RiskAggregationPolicy.standard.apply([only])
        #expect(applied == [only])
        #expect(applied.first?.suppressionCount == 1)
    }

    @Test("顺序无关性：同一批命中的任意排列都得到逐元素相同的输出")
    func applicationIsOrderIndependent() {
        let batch: [RiskFinding] = [
            eFinding(
                key: "mass-deletion:1700000000",
                level: .medium,
                rule: "risk.destructive.mass-deletion-window",
                paths: ["\(eHome)/other-project/a/0.swift", "\(eHome)/other-project/a/1.swift"],
                at: 0,
                evidence: 12
            ),
            eFinding(
                key: "ssh:/Users/tester/.ssh/id_rsa",
                level: .high,
                family: .sensitiveLocation,
                rule: "risk.sensitive.ssh-directory-access",
                category: .credentialExposure,
                paths: ["\(eHome)/.ssh/id_rsa"],
                at: 10,
                confidence: 0.9,
                confirmation: true
            ),
            eFinding(
                key: "long-running:x",
                level: .low,
                family: .activityPattern,
                rule: "risk.pattern.long-running-command",
                category: .resourceAbuse,
                at: 20,
                command: "make all"
            ),
            eFinding(
                key: "file-thrashing:/Users/tester/proj/a.swift",
                level: .medium,
                family: .activityPattern,
                rule: "risk.pattern.repeated-file-thrashing",
                category: .unknown,
                paths: ["\(eHome)/other-project/a/0.swift"],
                at: 30
            ),
            eFinding(
                key: "git-irreversible:push",
                level: .critical,
                family: .commandBehavior,
                rule: "risk.command.irreversible-git-operation",
                category: .dangerousCommand,
                at: 40,
                confirmation: true
            ),
        ]
        let policy = RiskAggregationPolicy.standard
        let forward = policy.apply(batch)
        #expect(forward == policy.apply(Array(batch.reversed())))
        #expect(forward == policy.apply(Array(batch.dropFirst(2) + batch.prefix(2))))
        #expect(forward == policy.apply(Array(batch.dropFirst(4) + batch.prefix(4))))
        #expect(forward.count == batch.count)
        // 呈现序首键是 level.rank 降序（同级不再互相抑制，故 5 条全部保留）。
        #expect(forward.first?.level == .critical)
        #expect(forward.map(\.level) == [.critical, .high, .medium, .medium, .low])
    }

    @Test("端到端命中的顺序无关性：同一窗口的命中逆序再喂一次策略结果相同")
    func applicationIsOrderIndependentForRealFindings() {
        let window = eWindow(changes: eBurst(parent: "\(eHome)/other-project/a", count: 42))
        let findings = RiskAssessor().assess(window)
        #expect(!findings.isEmpty)
        let policy = RiskAggregationPolicy.standard
        #expect(
            policy.apply(findings) == policy.apply(Array(findings.reversed())),
            "聚合层输出与输入排列有关：\(eFingerprint(findings))"
        )
    }

    @Test("折叠只升不降：同抑制键的 MEDIUM + HIGH 合成一条 HIGH，证据与计数累加")
    func foldingNeverDowngradesSeverity() {
        let medium = eFinding(
            key: "shared:key",
            level: .medium,
            rule: "risk.destructive.overwrite-rewrite",
            at: 0,
            evidence: 3,
            confidence: 0.7
        )
        let high = eFinding(
            key: "shared:key",
            level: .high,
            rule: "risk.destructive.mass-deletion-window",
            at: 10,
            evidence: 2,
            confidence: 0.85,
            confirmation: true
        )
        for batch in [[medium, high], [high, medium]] {
            let folded = RiskAggregationPolicy.standard.apply(batch)
            #expect(folded.count == 1, "折叠后应剩 1 条，实际：\(eFingerprint(folded))")
            #expect(folded.first?.level == .high)
            #expect(folded.first?.suppressionCount == 2)
            #expect(folded.first?.evidenceCount == 5)
            #expect(folded.first?.requiresConfirmation == true)
            #expect(folded.first?.confidence == 0.85)
            #expect(folded.first?.ruleID == "risk.destructive.mass-deletion-window")
            #expect(folded.first?.timestamp == eAt(0))   // 证据时间取最早
        }
    }

    @Test("折叠开关关闭时同抑制键各报一条")
    func foldingCanBeDisabled() {
        let batch = [
            eFinding(key: "shared:key", level: .medium, at: 0),
            eFinding(key: "shared:key", level: .high, at: 5, confirmation: true),
        ]
        let kept = RiskAggregationPolicy(deduplicateBySuppressionKey: false).apply(batch)
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { $0.suppressionKey == "shared:key" })
        #expect(kept.first?.level == .high)   // 排序仍把更高等级放在最前
    }

    @Test("同根因抑制：路径被更高等级命中真包含时低等级去掉，开关与时间邻近度可放行")
    func sameRootCauseSuppression() {
        let higher = eFinding(
            key: "mass-deletion:1700000000",
            level: .high,
            rule: "risk.destructive.mass-deletion-window",
            paths: ["\(eHome)/.aws/credentials", "\(eHome)/.aws/config", "\(eHome)/.aws/sts.json"],
            at: 0,
            evidence: 3,
            confirmation: true
        )
        let lower = eFinding(
            key: "credentials:/Users/tester/.aws/credentials",
            level: .medium,
            family: .sensitiveLocation,
            rule: "risk.sensitive.cloud-or-gpg-credentials",
            paths: ["\(eHome)/.aws/credentials"],
            at: 5
        )
        let suppressed = RiskAggregationPolicy.standard.apply([higher, lower])
        #expect(suppressed.count == 1)
        #expect(suppressed.first?.suppressionKey == "mass-deletion:1700000000")
        #expect(RiskAggregationPolicy.standard.apply([lower, higher]) == suppressed)

        // 关掉开关：两条都保留。
        let both = RiskAggregationPolicy(suppressContainedFindings: false).apply([higher, lower])
        #expect(both.count == 2)

        // 路径集合相等（非真子集）：不抑制。
        let equalPaths = eFinding(
            key: "credentials:/Users/tester/.aws/other",
            level: .medium,
            family: .sensitiveLocation,
            rule: "risk.sensitive.cloud-or-gpg-credentials",
            paths: higher.filePaths,
            at: 5
        )
        #expect(RiskAggregationPolicy.standard.apply([higher, equalPaths]).count == 2)

        // 时间不邻近（远超 60 秒根因窗口）：不抑制。
        let far = eFinding(
            key: "credentials:/Users/tester/.aws/credentials",
            level: .medium,
            family: .sensitiveLocation,
            rule: "risk.sensitive.cloud-or-gpg-credentials",
            paths: ["\(eHome)/.aws/credentials"],
            at: 6_000
        )
        #expect(RiskAggregationPolicy.standard.apply([higher, far]).count == 2)

        // 同等级永不互相抑制。
        let sameLevel = eFinding(
            key: "credentials:/Users/tester/.aws/credentials",
            level: .high,
            family: .sensitiveLocation,
            rule: "risk.sensitive.cloud-or-gpg-credentials",
            paths: ["\(eHome)/.aws/credentials"],
            at: 5,
            confirmation: true
        )
        #expect(RiskAggregationPolicy.standard.apply([higher, sameLevel]).count == 2)
    }

    @Test("maxFindings 在排序之后截断：保留的始终是等级最高的前 N 条")
    func truncationHappensAfterSorting() {
        let batch: [RiskFinding] = [
            eFinding(key: "k-low-1", level: .low, at: 1),
            eFinding(key: "k-medium", level: .medium, family: .sensitiveLocation, at: 2),
            eFinding(key: "k-high-1", level: .high, family: .commandBehavior, at: 3),
            eFinding(key: "k-low-2", level: .low, family: .activityPattern, at: 4),
            eFinding(key: "k-critical", level: .critical, family: .activityPattern, at: 5),
            eFinding(key: "k-high-2", level: .high, family: .sensitiveLocation, at: 6),
        ]
        #expect(RiskAggregationPolicy.standard.apply(batch).count == batch.count)

        let trimmed = RiskAggregationPolicy(maxFindings: 3).apply(batch)
        #expect(trimmed.count == 3)
        #expect(Set(trimmed.map(\.suppressionKey)) == ["k-critical", "k-high-1", "k-high-2"])
        #expect(trimmed.map(\.level) == [.critical, .high, .high])
        // 截断与输入排列无关。
        #expect(trimmed == RiskAggregationPolicy(maxFindings: 3).apply(Array(batch.reversed())))
        #expect(RiskAggregationPolicy(maxFindings: 0).apply(batch).isEmpty)

        // 被截掉的是"更低的"，不是"后来的"：把最高等级放到数组末尾也一样保留。
        let rotated = Array(batch.dropFirst(4) + batch.prefix(4))
        #expect(RiskAggregationPolicy(maxFindings: 3).apply(rotated) == trimmed)
    }

    @Test("族级地板只抬不降，抬到 HIGH 时同步要求确认")
    func familyFloorsLiftOnly() {
        let policy = RiskAggregationPolicy(floorLevels: [.activityPattern: .high])
        let lifted = policy.apply([
            eFinding(
                key: "off-hours:1700000000",
                level: .low,
                family: .activityPattern,
                rule: "risk.pattern.off-hours-high-frequency",
                category: .unknown
            ),
        ])
        #expect(lifted.count == 1)
        #expect(lifted.first?.level == .high)
        #expect(lifted.first?.requiresConfirmation == true)

        // 高于地板的命中不被下调；其它族不受影响。
        let untouched = policy.apply([
            eFinding(key: "cpu", level: .critical, family: .activityPattern, confirmation: true),
            eFinding(key: "ssh", level: .low, family: .sensitiveLocation),
        ])
        #expect(untouched.count == 2)
        #expect(untouched.first?.level == .critical)
        #expect(untouched.last?.level == .low)

        // 地板为 MEDIUM 时不自动要求确认。
        let mediumFloor = RiskAggregationPolicy(floorLevels: [.sensitiveLocation: .medium])
            .apply([eFinding(key: "ssh", level: .low, family: .sensitiveLocation)])
        #expect(mediumFloor.first?.level == .medium)
        #expect(mediumFloor.first?.requiresConfirmation == false)
    }

    @Test("呈现顺序：等级↓ → family.presentationWeight↓ → 时间↑ → ruleID↑")
    func presentationOrderFollowsSpec() {
        let batch: [RiskFinding] = [
            eFinding(key: "k-activity", level: .medium, family: .activityPattern, rule: "risk.c"),
            eFinding(key: "k-sensitive", level: .medium, family: .sensitiveLocation, rule: "risk.b"),
            eFinding(key: "k-destructive-early", level: .medium, rule: "risk.a", at: 0),
            eFinding(key: "k-tie-z", level: .medium, rule: "risk.z", at: 5),
            eFinding(key: "k-tie-a", level: .medium, rule: "risk.a", at: 5),
            eFinding(key: "k-command-high", level: .high, family: .commandBehavior, rule: "risk.d"),
        ]
        // 权重自洽：破坏性文件操作 > 敏感位置 > 命令行为 > 行为模式。
        #expect(RiskRuleFamily.destructiveFileOperation.presentationWeight
            > RiskRuleFamily.sensitiveLocation.presentationWeight)
        #expect(RiskRuleFamily.sensitiveLocation.presentationWeight
            > RiskRuleFamily.commandBehavior.presentationWeight)
        #expect(RiskRuleFamily.commandBehavior.presentationWeight
            > RiskRuleFamily.activityPattern.presentationWeight)

        let applied = RiskAggregationPolicy.standard.apply(batch)
        #expect(applied.map(\.suppressionKey) == [
            "k-command-high",       // 等级最高
            "k-destructive-early",  // 同 MEDIUM：A 族权重最大 + 时间最早
            "k-tie-a",              // 同族同级同时间：ruleID 字典序
            "k-tie-z",
            "k-sensitive",          // B 族
            "k-activity",           // D 族
        ], "实际呈现序：\(eFingerprint(applied))")
    }

    @Test("注入自定义策略的评估器按该策略裁剪输出")
    func assessorUsesInjectedPolicy() {
        let window = eWindow(changes: eBurst(parent: "\(eHome)/other-project/a", count: 42))
        let full = RiskAssessor().assess(window)
        #expect(full.count > 1)
        let trimmed = RiskAssessor(policy: RiskAggregationPolicy(maxFindings: 1)).assess(window)
        #expect(trimmed.count == 1)
        #expect((trimmed.first?.level.rank ?? -1) >= RiskLevel.high.rank)
        #expect(trimmed.first?.family == .destructiveFileOperation)
        #expect(RiskAssessor(policy: RiskAggregationPolicy(maxFindings: 1)).policy.maxFindings == 1)
    }
}

// MARK: - 契约符合性

@Suite("WS-Risk E：契约符合性 RiskEvaluating")
struct RiskAssessorContractTests {

    @Test("以 any RiskEvaluating 装配：loadedRules ≥ 25 且 id 非空无重复")
    func conformsToRiskEvaluating() {
        let evaluator: any RiskEvaluating = RiskAssessor()
        let rules = evaluator.loadedRules()
        #expect(rules.count >= 25)
        #expect(rules.allSatisfy { !$0.id.isEmpty })
        #expect(Set(rules.map(\.id)).count == rules.count)
        #expect(rules.map(\.id) == rules.map(\.id).sorted())
        #expect(rules.allSatisfy { $0.id.hasPrefix("risk.") })
        #expect(rules.allSatisfy { !$0.summary.isEmpty })
    }

    @Test("三事实皆 nil 的 RiskContext 直接返回空（不做无意义评估）")
    func emptyContextYieldsNoEvents() {
        let evaluator: any RiskEvaluating = RiskAssessor()
        #expect(evaluator.evaluate(RiskContext()).isEmpty)
        // `recentFileChangeCount` 无法映射到窗口（契约缺口），因此也不会凭空产出事件。
        #expect(evaluator.evaluate(RiskContext(recentFileChangeCount: 42)).isEmpty)
        #expect(RiskAssessor().riskEvents(in: RiskFactWindow(homeDirectory: eHome)).isEmpty)
    }

    @Test("单事件契约路径：一条越界删除事实也能降级为 RiskEvent")
    func singleFactContextProducesEvents() {
        let change = FileChange(
            path: "\(eHome)/Documents/notes.txt",
            kind: .deleted,
            timestamp: eAt(0),
            sizeBytes: 1_024,
            projectPath: eProject
        )
        let events = RiskAssessor().evaluate(RiskContext(fileChange: change))
        // 注：`evaluate` 按实现约定用 `NSHomeDirectory()` 作为 home，
        // 因此这里只断言"契约入口可用 + 字段自洽"，不断言具体等级。
        #expect(!events.isEmpty)
        let ids = events.compactMap(\.matchedRuleID)
        #expect(ids.count == events.count)
        let knownRuleIDs = Set(RiskRuleCatalog.standard.rules.map { $0.identity.id })
        #expect(ids.allSatisfy { knownRuleIDs.contains($0) })
        #expect(events.allSatisfy { $0.timestamp == eAt(0) })
        #expect(events.allSatisfy { !$0.detail.isEmpty })
    }

    @Test("riskEvent() 降级：逐字段对齐，detail 带置信度、时间戳不变")
    func findingMapsOntoRiskEvent() {
        let window = eWindow(
            changes: [eDeletion("\(eHome)/Documents/notes.txt", at: 2)],
            commands: [eCommand("rm", ["-rf", "~/Documents"], at: 0)],
            end: eAt(600)
        )
        let findings = RiskAssessor().assess(window)
        #expect(!findings.isEmpty)
        let events = RiskAssessor().riskEvents(in: window)
        #expect(events.count == findings.count)
        for (finding, event) in zip(findings, events) {
            #expect(event.matchedRuleID == finding.ruleID)
            #expect(event.level == finding.level)
            #expect(event.category == finding.category)
            #expect(event.title == finding.title)
            #expect(event.requiresConfirmation == finding.requiresConfirmation)
            #expect(event.timestamp == finding.timestamp)
            #expect(event.filePaths == finding.filePaths)
            #expect(event.command == finding.command)
            #expect(event.sessionID == finding.sessionID)
            #expect(event.agentID == finding.agentID)
            #expect(event.agentKind == finding.agentKind)
            #expect(event.isAcknowledged == false)
            #expect(event.detail.contains("confidence"))
            #expect(event.detail.hasPrefix(finding.detail))
        }

        let subtree = findings.first { $0.ruleID == "risk.destructive.home-subtree-deletion" }
        #expect(subtree?.level == .high)
        #expect(subtree?.requiresConfirmation == true)
        #expect(subtree?.category == .massDeletion)
        let mapped = subtree?.riskEvent()
        #expect(mapped?.matchedRuleID == "risk.destructive.home-subtree-deletion")
        #expect(mapped?.level == .high)
        #expect(mapped?.requiresConfirmation == true)
        #expect(mapped?.filePaths.contains("\(eHome)/Documents") == true)
    }
}

// MARK: - 端到端验收

@Suite("WS-Risk E：端到端验收场景")
struct RiskAssessorEndToEndTests {

    @Test("60 秒 42 条越界删除 → 批量删除命中恰好 1 条、HIGH、要求确认")
    func fortyTwoDeletionsInSixtySecondsCollapseToOneMassDeletion() {
        let burst = eBurst(parent: "\(eHome)/other-project/a", count: 42)
        let window = eWindow(changes: burst, end: eAt(600))
        let findings = RiskAssessor().assess(window)

        let mass = findings.filter { $0.ruleID == "risk.destructive.mass-deletion-window" }
        #expect(mass.count == 1, "批量删除规则应只出 1 条，实际：\(eFingerprint(mass))")
        #expect(mass.first?.suppressionKey == "mass-deletion:\(eEpoch(0))")
        #expect((mass.first?.evidenceCount ?? 0) >= 42)
        #expect(mass.first?.evidenceCount == 42)
        #expect(mass.first?.level == .high)          // 42 ≥ massDeletionHighCount(25)，< critical(200)
        #expect(mass.first?.requiresConfirmation == true)
        #expect(mass.first?.category == .massDeletion)
        #expect((mass.first?.evidenceSpan ?? 0) >= 41)

        // 聚合后不得残留重复抑制键 / 重复 id，也不得同一规则刷屏。
        // 说明：规格 §4 里 A 族 4 条规则（mass-deletion-window / directory-wipe /
        // outside-project-write / home-subtree-deletion）都登记为 `.massDeletion` 分类，
        // 因此"category == .massDeletion 恰好 1 条"在 33 条清单下不成立，
        // 这里按规格的可执行不变量断言：同一规则最多 1 行。
        #expect(Set(findings.map(\.suppressionKey)).count == findings.count)
        #expect(Set(findings.map(\.id)).count == findings.count)
        #expect(Set(findings.map(\.ruleID)).count == findings.count)
        #expect(findings.allSatisfy { $0.family == .destructiveFileOperation })
        #expect(findings.allSatisfy { $0.requiresConfirmation })
    }

    @Test("跨时间簇不折叠：21 + 21（间隔 10 分钟）→ 2 条批量删除命中")
    func temporallySeparatedClustersStayApart() {
        var burst = eBurst(parent: "\(eHome)/other-project/a", count: 21, firstOffset: 0)
        burst += eBurst(parent: "\(eHome)/other-project/b", count: 21, firstOffset: 600)
        let window = eWindow(changes: burst, end: eAt(1_800))
        let findings = RiskAssessor().assess(window)

        let mass = findings.filter { $0.ruleID == "risk.destructive.mass-deletion-window" }
        #expect(mass.count == 2, "期望 2 个时间簇各 1 条，实际：\(eFingerprint(mass))")
        #expect(mass.map(\.suppressionKey) == [
            "mass-deletion:\(eEpoch(0))",
            "mass-deletion:\(eEpoch(600))",
        ])
        #expect(mass.allSatisfy { $0.evidenceCount == 21 })
        #expect(mass.allSatisfy { $0.level == .medium })   // 21 < massDeletionHighCount(25)
        #expect(mass.allSatisfy { $0.requiresConfirmation })
    }

    @Test("多窗口合并：跨窗口的同一根因折成一条，且不做逐窗口预截断")
    func multipleWindowsFoldAcrossBoundaries() {
        let first = eWindow(changes: eBurst(parent: "\(eHome)/other-project/a", count: 21))
        let second = eWindow(changes: eBurst(parent: "\(eHome)/other-project/b", count: 21))
        let single = RiskAssessor().assess(first)
        let merged = RiskAssessor().assess([first, second])

        let singleMass = single.filter { $0.ruleID == "risk.destructive.mass-deletion-window" }
        let mergedMass = merged.filter { $0.ruleID == "risk.destructive.mass-deletion-window" }
        #expect(singleMass.count == 1)
        #expect(singleMass.first?.evidenceCount == 21)
        #expect(mergedMass.count == 1, "跨窗口同簇应折叠：\(eFingerprint(merged))")
        #expect(mergedMass.first?.evidenceCount == 42)
        #expect((mergedMass.first?.level ?? .low).rank >= RiskLevel.medium.rank)
        #expect(mergedMass.first?.suppressionCount == 2)
        #expect(merged.count <= single.count + RiskAssessor().assess(second).count)
        // 空集合与单元素集合的退化行为。
        #expect(RiskAssessor().assess([]).isEmpty)
        #expect(RiskAssessor().assess([first]) == single)
    }

    @Test("规格硬断言：只有 `rm -rf ~/Documents` 命令（无文件事实）也必须报 HIGH + 确认")
    func dangerousDeleteCommandAloneIsAssessed() throws {
        let commandID = try #require(UUID(uuidString: "6F6F0000-1111-2222-3333-444455556666"))
        let rm = eCommand(
            "rm",
            ["-rf", "~/Documents"],
            at: 0,
            id: commandID,
            destructive: true,
            level: .high,
            confirmation: true,
            endsAfter: 1
        )
        let window = eWindow(
            commands: [rm],
            end: eAt(600),
            // 注入的是 L1（Telemetry DestructiveCommandRules）那一层结论；
            // ADR-0010 之后分级结论不带文本，原来那句标注改放在这里。
            classifications: [commandID: CommandClassification(
                isDestructive: true,
                requiresConfirmation: true,
                level: .high,
                category: .dangerousCommand
            )]
        )
        let findings = RiskAssessor().assess(window)

        // 规格 §4 第 3 / 5 条：越界删除与 home 子树删除都要"文件事实 + rm/rmdir 命令目标
        // 双重取证"。`RiskAssessor.rawFindings` 的 `requiresWriteEvidence` 预筛把 A 族 6 条
        // 规则在"只有命令、没有文件事实"的窗口里全部跳过，导致本场景 0 命中。
        #expect(
            !findings.isEmpty,
            "命令型删除（rm -rf ~/Documents）被 assess 的写证据预筛全部跳过：A 族 6 条规则均声明 requiresWriteEvidence，而 hasWriteEvidence 只看 fileChanges、不看 commands"
        )
        let categories: [RiskCategory] = [.massDeletion, .dangerousCommand, .sensitivePathAccess]
        let hitsRequirement = findings.contains { finding in
            finding.level.rank >= RiskLevel.high.rank
                && finding.requiresConfirmation
                && categories.contains(finding.category)
        }
        #expect(hitsRequirement, "实际命中：\(eFingerprint(findings))")
    }

    @Test("`rm -rf ~/Documents` + 一条删除事实 → home 子树删除 HIGH 且要求确认")
    func deleteCommandWithFileEvidenceIsAssessed() {
        let rm = eCommand("rm", ["-rf", "~/Documents"], at: 0, destructive: true, level: .high, confirmation: true)
        let window = eWindow(
            changes: [eDeletion("\(eHome)/Documents/notes.txt", at: 2)],
            commands: [rm],
            end: eAt(600)
        )
        let findings = RiskAssessor().assess(window)
        #expect(!findings.isEmpty)

        let subtree = findings.filter { $0.ruleID == "risk.destructive.home-subtree-deletion" }
        #expect(subtree.count == 1)
        #expect(subtree.first?.level == .high)
        #expect(subtree.first?.requiresConfirmation == true)
        #expect(subtree.first?.category == .massDeletion)
        #expect(subtree.first?.suppressionKey == "home-subtree-deletion:Documents")
        #expect(subtree.first?.filePaths.contains("\(eHome)/Documents") == true)
        #expect(subtree.first?.evidenceCount == 2)   // 命令目标 + 删除事实
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
    }

    @Test("端到端敏感位置：读 `~/.ssh/id_rsa` 的命中等级不低于 MEDIUM")
    func readingSSHKeyEndToEnd() {
        let window = eWindow(events: [eRead("\(eHome)/.ssh/id_rsa", at: 0)], end: eAt(600))
        let findings = RiskAssessor().assess(window)
        #expect(!findings.isEmpty)
        #expect((findings.map(\.level).max() ?? .low).rank >= RiskLevel.medium.rank)

        let ssh = findings.filter { $0.ruleID == "risk.sensitive.ssh-directory-access" }
        #expect(ssh.count == 1)
        #expect((ssh.first?.level.rank ?? -1) >= RiskLevel.medium.rank)
        #expect(ssh.first?.level == .high)   // 私钥文件名 → readLevel HIGH
        #expect(ssh.first?.category == .credentialExposure)
        #expect(ssh.first?.filePaths.contains("\(eHome)/.ssh/id_rsa") == true)
        #expect(ssh.first?.suppressionKey == "ssh:/Users/tester/.ssh/id_rsa")
    }

    @Test("端到端敏感位置：写 `<project>/.env` 的命中等级不低于 MEDIUM 且要求确认")
    func writingDotEnvEndToEnd() {
        let window = eWindow(changes: [eWrite("\(eProject)/.env", .created, at: 3)], end: eAt(600))
        let findings = RiskAssessor().assess(window)
        #expect(!findings.isEmpty)
        #expect((findings.map(\.level).max() ?? .low).rank >= RiskLevel.medium.rank)

        let dotenv = findings.filter { $0.ruleID == "risk.sensitive.dotenv-touch" }
        #expect(dotenv.count == 1)
        #expect(dotenv.first?.level == .high)   // 写证据 → writeLevel HIGH
        #expect(dotenv.first?.requiresConfirmation == true)
        #expect(dotenv.first?.filePaths.contains("\(eProject)/.env") == true)
    }

    @Test("纯函数与排序稳定性：重复评估相等，打乱事实顺序结果不变")
    func assessmentIsPureAndOrderStable() {
        let changes = eBurst(parent: "\(eProject)/Sources", count: 12)
            + [eWrite("\(eProject)/Legacy.swift", .modified, at: 30, added: 5, removed: 400)]
        let events = [eRead("\(eHome)/.ssh/id_rsa", at: 40), eRead("\(eHome)/.aws/credentials", at: 41)]

        let first = eWindow(events: events, changes: changes, end: eAt(600))
        let repeated = RiskAssessor().assess(first)
        let again = RiskAssessor().assess(first)
        #expect(repeated == again)
        #expect(!repeated.isEmpty)

        // 同一批事实（时间戳不变）换一种数组顺序进入窗口：命中集合必须逐元素相同。
        let reversed = eWindow(
            events: Array(events.reversed()),
            changes: Array(changes.reversed()),
            end: eAt(600)
        )
        let rotated = eWindow(
            events: events,
            changes: Array(changes.dropFirst(7) + changes.prefix(7)),
            end: eAt(600)
        )
        #expect(RiskAssessor().assess(reversed) == repeated)
        #expect(RiskAssessor().assess(rotated) == repeated)

        // 策略层同样纯净：同一批命中的两次 apply 结果相等。
        let policy = RiskAggregationPolicy.standard
        #expect(policy.apply(repeated) == policy.apply(repeated))
    }

    @Test("空窗口：assess / riskEvents / 多窗口都是空")
    func emptyWindowYieldsNothing() {
        let assessor = RiskAssessor()
        #expect(assessor.assess(RiskFactWindow()).isEmpty)
        #expect(assessor.assess(RiskFactWindow(homeDirectory: eHome)).isEmpty)
        #expect(assessor.assess([RiskFactWindow(homeDirectory: eHome)]).isEmpty)
        #expect(assessor.riskEvents(in: RiskFactWindow(homeDirectory: eHome)).isEmpty)
        #expect(assessor.assess(RiskFactWindow(
            events: [],
            fileChanges: [],
            commands: [],
            samples: [],
            start: eAnchor,
            end: eAt(600),
            homeDirectory: eHome,
            calendar: RiskFactWindow.gregorianUTC
        )).isEmpty)
    }

    @Test("族级地板经评估器生效：只含 D 族命中的窗口被抬到 HIGH 并要求确认")
    func familyFloorAppliesThroughAssessor() {
        // 一条跑满 900 秒的普通前台命令：D 族 `long-running-command` 命中 LOW，其余族无事实。
        let slow = eCommand("sleep", ["900"], at: 0, endsAfter: 900)
        let window = eWindow(commands: [slow], end: eAt(1_200))
        let dCatalog = RiskRuleCatalog(rules: BehaviorPatternRules.all)

        let baseline = RiskAssessor(catalog: dCatalog).assess(window)
        #expect(baseline.count == 1)
        #expect(baseline.first?.ruleID == "risk.pattern.long-running-command")
        #expect(baseline.first?.family == .activityPattern)
        #expect(baseline.first?.level == .low)
        #expect(baseline.first?.requiresConfirmation == false)

        let floored = RiskAssessor(
            catalog: dCatalog,
            policy: RiskAggregationPolicy(floorLevels: [.activityPattern: .high])
        ).assess(window)
        #expect(floored.count == 1)
        #expect(floored.first?.level == .high)
        #expect(floored.first?.requiresConfirmation == true)
        #expect(floored.first?.ruleID == "risk.pattern.long-running-command")
        #expect(floored.first?.suppressionCount == 1)
    }

    @Test("证据不足时不命中：8 条阈值下的删除 / 纯读取会话不产出批量删除命中")
    func belowThresholdFactsYieldNothing() {
        let seven = eBurst(parent: "\(eProject)/Sources", count: 7)
        #expect(RiskAssessor().assess(eWindow(changes: seven))
            .filter { $0.ruleID == "risk.destructive.mass-deletion-window" }.isEmpty)

        let eight = eBurst(parent: "\(eProject)/Sources", count: 8)
        let hit = RiskAssessor().assess(eWindow(changes: eight))
            .filter { $0.ruleID == "risk.destructive.mass-deletion-window" }
        #expect(hit.count == 1)
        #expect(hit.first?.level == .medium)   // 8 ≥ massDeletionCount(8)，< highCount(25)

        // 纯读取会话里 A 族（requiresWriteEvidence）被预筛跳过。
        let readOnly = RiskAssessor().assess(eWindow(events: [eRead("\(eProject)/Sources/a.swift", at: 1)]))
        #expect(readOnly.allSatisfy { $0.family != .destructiveFileOperation })
    }
}

// MARK: - 根为 "/" 时不得变成万能白名单（真机 projects 表里出现过 "/" 一行，故钉死）

@Suite("RiskPathAnalyzer：根路径的边界语义", .timeLimit(.minutes(1)))
struct RootPathContainmentTests {

    @Test("`/` 作为写根必须**匹配不到任何东西**，而不是把整块盘算成允许写入")
    func rootSlashIsInert() {
        let home = "/Users/testhost"
        // normalized("/") 去掉尾斜杠后为空串 ⇒ isPath 的 guard 直接返回 false。
        // 若哪天有人"顺手"把根目录当白名单用，这一条会立刻红。
        #expect(RiskPathAnalyzer.isPath("/Users/testhost/secrets/id_rsa",
                                       withinRoots: ["/"], homeDirectory: home) == false)
        // 路径 `/` 落在根 `/` 内是**正确的集合语义**（只有根自己），不是漏洞；
        // 关键是它不外溢：任何其它绝对路径都判不进来（前后两条断言才是重点）。
        #expect(RiskPathAnalyzer.isPath("/", withinRoots: ["/"], homeDirectory: home))
        #expect(RiskPathAnalyzer.isPath("/etc/passwd",
                                       withinRoots: ["/"], homeDirectory: home) == false)
        // 正常根仍然生效，排除"断言写成恒 false"的可能。
        #expect(RiskPathAnalyzer.isPath("/Users/testhost/proj/a.swift",
                                       withinRoots: ["/Users/testhost/proj"], homeDirectory: home))
    }
}
