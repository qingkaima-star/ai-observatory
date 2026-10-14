//
//  SensitiveLocationRules.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk —— B 敏感位置族
//
//  9 条「敏感位置」规则（`risk.sensitive.*`）。三类证据源被统一折算为带读 / 写标记的路径证据：
//   · `window.fileChanges`（新建 / 修改 / 重命名 / 删除，含 `previousPath`）
//   · `window.readEvents`（`OperationKind.fileRead` 的 `filePath`）
//   · `window.commands` → `RiskCommandFacts.targetPaths`（结构化 argv，不重复 L1 文本正则）
//  路径归类全部复用 `RiskPathAnalyzer` + `SensitiveLocation` 的读写等级表，
//  判定一律使用注入的 `window.homeDirectory`：不访问文件系统、不读 `Date()`、不用随机数。
//  每条规则内部按 `suppressionKey`（同一归一化路径 / 同一命令标签）归并，
//  因此同一文件被读 5 次、同一条命令重复执行都只产出 1 条命中，两次评估结果逐字节相等。
//

import Foundation
import AIObservatoryCore

// MARK: - Shared evidence plumbing

/// B 族共用的一条路径证据。
struct SLCPathEvidence: Sendable, Hashable {

    /// 归一化后的绝对路径（`~` 已用注入的 home 展开）。
    var path: String
    /// `true` = 写入 / 删除证据；`false` = 读取证据。
    var isWrite: Bool
    /// 证据发生时间，取自事实本体（文件变更时间戳 / 命令开始时间）。
    var timestamp: Date
    /// 命令来源的原始文本；文件类证据为 nil。
    var command: String?
}

extension SLCPathEvidence {

    /// 该证据命中的全部敏感位置（按 `SensitiveLocation.allCases` 顺序，确定性）。
    func locations(in window: RiskFactWindow) -> [SensitiveLocation] {
        RiskPathAnalyzer.candidates(for: path, homeDirectory: window.homeDirectory)
    }

    /// 读 / 写的中文动作描述，用于理由文本。
    var actionText: String { isWrite ? "写入或删除了" : "读取了" }
}

/// B 族共用：把窗口内的三类证据源折算为路径证据集合。
enum SLCPathEvidenceCollector {

    /// 语义上会**写入或删除**其路径参数的命令，这些命令的 `targetPaths` 按写证据计；
    /// 其余命令（`cat`/`head`/`ls`/`grep`…）按读证据计。
    /// `RiskCommandClassifier.writeTargets` 只做结构性过滤、不回答"读还是写"，
    /// 故本族保留这张小意图表。
    static let writeIntentExecutables: Set<String> = [
        "rm", "rmdir", "unlink", "shred", "mv", "cp", "dd", "tee", "touch", "truncate",
        "install", "rsync", "tar", "unzip", "ditto", "ln", "chmod", "chown", "chgrp",
        "launchctl", "defaults", "security", "kextload", "pfctl", "tccutil", "nvram", "spctl"
    ]

    /// 汇总三类证据源，按 (时间, 路径, 写优先) 稳定排序后返回。
    static func collect(_ window: RiskFactWindow) -> [SLCPathEvidence] {
        let home = window.homeDirectory
        var out: [SLCPathEvidence] = []

        for change in window.sortedFileChanges {
            append(change.path, isWrite: true, at: change.timestamp, command: nil, home: home, to: &out)
            if let previous = change.previousPath {
                append(previous, isWrite: true, at: change.timestamp, command: nil, home: home, to: &out)
            }
        }
        for event in window.readEvents {
            guard let raw = event.filePath, !raw.isEmpty else { continue }
            append(raw, isWrite: false, at: event.timestamp, command: event.command, home: home, to: &out)
        }
        for record in window.sortedCommands {
            let facts = RiskCommandFacts(record, homeDirectory: home)
            let isWrite = writeIntentExecutables.contains(facts.effectiveExecutable)
            for path in facts.targetPaths {
                out.append(SLCPathEvidence(
                    path: path,
                    isWrite: isWrite,
                    timestamp: record.startedAt,
                    command: record.commandLine
                ))
            }
        }

        return out.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.isWrite && !rhs.isWrite
        }
    }

    private static func append(
        _ raw: String,
        isWrite: Bool,
        at timestamp: Date,
        command: String?,
        home: String,
        to out: inout [SLCPathEvidence]
    ) {
        let path = RiskPathAnalyzer.normalized(raw, homeDirectory: home)
        guard !path.isEmpty else { return }
        out.append(SLCPathEvidence(path: path, isWrite: isWrite, timestamp: timestamp, command: command))
    }
}

/// B 族单条候选命中（按 `suppressionKey` 归并之前）。
struct SLCHit: Sendable {

    /// 完整抑制键：`<短前缀>:<归一化路径或命令标签>`。
    var suppressionKey: String
    /// 该条证据推导出的等级。
    var level: RiskLevel
    /// 证据时间。
    var timestamp: Date
    /// 动作中文描述（"读取了" / "写入或删除了" / "执行了"）。
    var action: String
    /// 敏感位置中文名。
    var location: String
    /// 关联路径；命令级命中可为 nil。
    var path: String? = nil
    /// 关联命令文本。
    var command: String? = nil
    /// 覆盖规则身份的分类（nil 表示沿用）。
    var category: RiskCategory? = nil
    /// 追加到理由文本末尾的补充说明（累计次数、命令升级链等）。
    var note: String? = nil
    /// 置信度。
    var confidence: Double = 0.85
}

/// 按 `suppressionKey` 归并后的 B 族命中。
struct SLCMergedHit: Sendable {

    /// 抑制键。
    var suppressionKey: String
    /// 归并后的最高等级。
    var level: RiskLevel
    /// 最早证据时间。
    var timestamp: Date
    /// 最晚证据时间，用于计算跨度。
    var lastTimestamp: Date
    /// 证据条数。
    var evidenceCount: Int
    /// 涉及路径（按首次出现顺序，最多 12 条）。
    var paths: [String]
    /// 关联命令文本。
    var command: String?
    /// 命中的敏感位置中文名。
    var locations: [String]
    /// 最高等级对应的动作描述。
    var action: String
    /// 分类覆盖。
    var category: RiskCategory?
    /// 补充说明。
    var note: String?
    /// 置信度（取最高）。
    var confidence: Double

    /// 由单条候选命中起头。
    init(startingWith hit: SLCHit) {
        self.suppressionKey = hit.suppressionKey
        self.level = hit.level
        self.timestamp = hit.timestamp
        self.lastTimestamp = hit.timestamp
        self.evidenceCount = 1
        self.paths = hit.path.map { [$0] } ?? []
        self.command = hit.command
        self.locations = [hit.location]
        self.action = hit.action
        self.category = hit.category
        self.note = hit.note
        self.confidence = hit.confidence
    }

    /// 证据覆盖的时间跨度；单点证据返回 nil。
    var span: TimeInterval? {
        let value = lastTimestamp.timeIntervalSince(timestamp)
        return value > 0 ? value : nil
    }

    /// 归并另一条候选命中：等级只升不降、时间取最早、证据累加。
    mutating func absorb(_ other: SLCHit) {
        if other.level.rank > level.rank {
            level = other.level
            action = other.action
            category = other.category
        }
        if other.timestamp < timestamp { timestamp = other.timestamp }
        if other.timestamp > lastTimestamp { lastTimestamp = other.timestamp }
        evidenceCount += 1
        confidence = Swift.max(confidence, other.confidence)
        if let path = other.path, !paths.contains(path), paths.count < 12 { paths.append(path) }
        if !locations.contains(other.location) { locations.append(other.location) }
        if command == nil, let otherCommand = other.command { command = otherCommand }
        if note == nil, let otherNote = other.note { note = otherNote }
    }

    /// 路径摘要文本（超过 3 条时截断并标注总数）。
    var pathSummary: String {
        guard !paths.isEmpty else { return "（命令级证据，未捕获具体路径）" }
        if paths.count == 1 { return paths[0] }
        let head = paths.prefix(3).joined(separator: "、")
        if paths.count > 3 { return head + " 等 \(paths.count) 条路径" }
        return head
    }

    /// 用规则身份的理由模板渲染可读详情。
    func detail(using identity: RiskRuleIdentity) -> String {
        identity.rationale(filling: [
            "action": action,
            "location": locations.joined(separator: "、"),
            "path": pathSummary,
            "count": String(evidenceCount),
            "note": note.map { "，\($0)" } ?? ""
        ])
    }

    /// 折算为规则草稿（补上会话 / Agent 归属）。
    func draft(in window: RiskFactWindow, using identity: RiskRuleIdentity) -> RiskFindingDraft {
        RiskFindingDraft(
            level: level,
            detail: detail(using: identity),
            category: category,
            confidence: confidence,
            timestamp: timestamp,
            filePaths: paths,
            command: command,
            sessionID: window.sessionID,
            agentID: window.agentIDs.first,
            agentKind: window.agentKind,
            suppressionKey: suppressionKey,
            evidenceCount: evidenceCount,
            evidenceSpan: span
        )
    }
}

/// B 族共用的构造辅助。
enum SLCRuleSupport {

    /// 抑制键拼装。
    static func key(_ prefix: String, _ suffix: String) -> String { prefix + ":" + suffix }

    /// 依据证据是读还是写，取命中位置表里的最高等级。
    static func level(of locations: [SensitiveLocation], isWrite: Bool) -> RiskLevel {
        let levels = locations.map { isWrite ? $0.writeLevel : $0.readLevel }
        return levels.max() ?? (isWrite ? RiskLevel.high : RiskLevel.low)
    }

    /// 命中位置的中文名集合（保持 allCases 顺序）。
    static func names(of locations: [SensitiveLocation]) -> String {
        locations.map(\.displayName).joined(separator: "、")
    }

    /// `~/Library/Keychains` 与 `/Library/Keychains`（`~` 由注入的 home 展开）。
    static let keychainRoots: [String] = ["~/Library/Keychains", "/Library/Keychains"]

    /// macOS 钥匙串文件扩展名。
    static let keychainFileExtensions: Set<String> = ["keychain", "keychain-db"]

    /// 是否真的是钥匙串目录 / 钥匙串文件。
    /// `SensitiveLocation.keychain` 还包含"文件名含 keychain"的宽松匹配，
    /// 直接用它会把项目里的 `Keychain.swift` 之类源码判成敏感位置，故此处收紧一次。
    static func isKeychainBearing(_ path: String, homeDirectory: String) -> Bool {
        guard RiskPathAnalyzer.candidates(for: path, homeDirectory: homeDirectory).contains(.keychain) else {
            return false
        }
        return RiskPathAnalyzer.isPath(path, withinRoots: keychainRoots, homeDirectory: homeDirectory)
            || keychainFileExtensions.contains(RiskPathAnalyzer.fileExtension(of: path))
    }

    /// 凭据载体文件扩展名（对齐文档为 `risk.sensitive.cloud-or-gpg-credentials` 列举的形态）。
    /// TODO(contract-gap): `RiskPathAnalyzer` 未公开 `.credentialFile` 的命中原因
    /// （名字子串 `secret`/`token`/`password` 也算），本族只能用扩展名白名单避免源码文件误报。
    static let credentialFileExtensions: Set<String> = [
        "pem", "p12", "pfx", "kdbx", "key", "ppk", "asc", "jks", "keystore"
    ]

    /// 归并同抑制键的命中，并按 (时间, 抑制键) 稳定排序，保证确定性。
    static func merge(_ hits: [SLCHit]) -> [SLCMergedHit] {
        var order: [String] = []
        var buckets: [String: SLCMergedHit] = [:]
        for hit in hits {
            if var existing = buckets[hit.suppressionKey] {
                existing.absorb(hit)
                buckets[hit.suppressionKey] = existing
            } else {
                buckets[hit.suppressionKey] = SLCMergedHit(startingWith: hit)
                order.append(hit.suppressionKey)
            }
        }
        var merged = order.compactMap { buckets[$0] }
        merged.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.suppressionKey < rhs.suppressionKey
        }
        return merged
    }
}

// MARK: - 7. SSH 目录

/// `risk.sensitive.ssh-directory-access` —— `~/.ssh` 下的读取与写删。
///
/// 读私钥 / 凭据名文件（`id_rsa`、`id_ed25519`、`*.pem` 等）判 `.high`，其它读取判 `.medium`，
/// 写入或删除按 `SensitiveLocation.sshDirectory.writeLevel`（`.high`）。
public struct SLCSSHDirectoryAccessRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.ssh-directory-access",
        family: .sensitiveLocation,
        category: .credentialExposure,
        title: "触碰 SSH 目录",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "读取或改写 ~/.ssh 下的密钥与配置；读私钥、写删一律 HIGH。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var hits: [SLCHit] = []
        for evidence in SLCPathEvidenceCollector.collect(window) {
            let locations = evidence.locations(in: window)
            guard locations.contains(.sshDirectory) else { continue }
            // 私钥类文件由位置表的 .credentialFile 分支判定，不另建匹配表。
            let isKeyMaterial = locations.contains(.credentialFile)
            let level: RiskLevel
            if evidence.isWrite {
                level = SensitiveLocation.sshDirectory.writeLevel
            } else {
                level = isKeyMaterial ? SensitiveLocation.sshDirectory.readLevel : .medium
            }
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("ssh", evidence.path),
                level: level,
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: SLCRuleSupport.names(of: [SensitiveLocation.sshDirectory]),
                path: evidence.path,
                command: evidence.command,
                note: evidence.command.map { "来自命令 \($0)" },
                confidence: evidence.command == nil ? 0.9 : 0.8
            ))
        }
        return SLCRuleSupport.merge(hits).map { $0.draft(in: window, using: identity) }
            .map { makeFinding(from: $0) }
    }
}

// MARK: - 8. 钥匙串

/// `risk.sensitive.keychain-access` —— 钥匙串目录读写与 `security` 钥匙串子命令。
///
/// 覆盖 `~/Library/Keychains`、`/Library/Keychains`，以及 `security unlock-keychain` /
/// `delete-keychain` / `set-keychain-settings`（复用 `RiskCommandFacts` + `RiskCommandClassifier`）。
public struct SLCKeychainAccessRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.keychain-access",
        family: .sensitiveLocation,
        category: .credentialExposure,
        title: "访问钥匙串",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "读写钥匙串文件或执行 security 钥匙串子命令（解锁/删除/改设置）。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 等级不低于 `.medium`（文档标注下限）。
    public var preferences: RiskRulePreferences { RiskRulePreferences(levelFloor: .medium) }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let home = window.homeDirectory
        let classifier = RiskCommandClassifier()
        var hits: [SLCHit] = []

        for evidence in SLCPathEvidenceCollector.collect(window) {
            guard SLCRuleSupport.isKeychainBearing(evidence.path, homeDirectory: home) else { continue }
            let level = SLCRuleSupport.level(
                of: [SensitiveLocation.keychain],
                isWrite: evidence.isWrite
            )
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("keychain", evidence.path),
                level: level,
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: SensitiveLocation.keychain.displayName,
                path: evidence.path,
                command: evidence.command,
                note: evidence.command.map { "来自命令 \($0)" },
                confidence: evidence.command == nil ? 0.9 : 0.8
            ))
        }

        for record in window.sortedCommands {
            let facts = RiskCommandFacts(record, homeDirectory: home)
            guard facts.effectiveExecutable == "security", classifier.isSecuritySettingMutation(facts) else {
                continue
            }
            // 只认钥匙串类子命令，`authorizationdb` 等其它安全命令归 C 族规则 22。
            guard facts.operands.contains(where: { $0.contains("keychain") }) else { continue }
            // 命令参数里的钥匙串文件已被路径证据覆盖时不再重复出条目。
            let coveredByPath = facts.targetPaths.contains {
                SLCRuleSupport.isKeychainBearing($0, homeDirectory: home)
            }
            guard !coveredByPath else { continue }
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("keychain", "command:\(facts.subcommand ?? "security")"),
                level: .high,
                timestamp: record.startedAt,
                action: "执行了",
                location: "钥匙串管理命令",
                path: nil,
                command: record.commandLine,
                note: "命令 \(record.commandLine)",
                confidence: 0.8
            ))
        }

        return SLCRuleSupport.merge(hits).map { $0.draft(in: window, using: identity) }
            .map { makeFinding(from: $0) }
    }
}

// MARK: - 9. .env 文件

/// `risk.sensitive.dotenv-touch` —— `.env` / `.env.*` 环境变量文件。
///
/// 读取判 `.medium`，写入或删除判 `.high`（`SensitiveLocation.dotEnvFile.writeLevel`）。
public struct SLCDotEnvTouchRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.dotenv-touch",
        family: .sensitiveLocation,
        category: .credentialExposure,
        title: "触碰 .env 环境变量文件",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "读取或改写 .env / .env.* 之类含明文凭据的环境变量文件。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var hits: [SLCHit] = []
        for evidence in SLCPathEvidenceCollector.collect(window) {
            let locations = evidence.locations(in: window)
            guard locations.contains(.dotEnvFile) else { continue }
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("dotenv", evidence.path),
                level: SLCRuleSupport.level(of: [SensitiveLocation.dotEnvFile], isWrite: evidence.isWrite),
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: SensitiveLocation.dotEnvFile.displayName,
                path: evidence.path,
                command: evidence.command,
                note: evidence.command.map { "来自命令 \($0)" },
                confidence: evidence.command == nil ? 0.9 : 0.8
            ))
        }
        return SLCRuleSupport.merge(hits).map { $0.draft(in: window, using: identity) }
            .map { makeFinding(from: $0) }
    }
}

// MARK: - 10. 云 / GPG 凭据

/// `risk.sensitive.cloud-or-gpg-credentials` —— 云端凭据、GPG 密钥环与凭据载体文件。
///
/// 覆盖 `~/.aws`、`~/.gnupg`、`~/.config/gcloud`、`~/.docker/config.json`、
/// `credentials.json` 以及 `*.pem` / `*.p12` / `*.kdbx` 等凭据文件；
/// 等级不低于 `.medium`，凭据类位置读取即 `.high`。
public struct SLCCloudOrGPGCredentialsRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.cloud-or-gpg-credentials",
        family: .sensitiveLocation,
        category: .credentialExposure,
        title: "触碰云端 / GPG 凭据",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "访问云厂商凭据目录、GPG 密钥环或 pem/p12/kdbx 之类凭据载体文件。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 等级不低于 `.medium`。
    public var preferences: RiskRulePreferences { RiskRulePreferences(levelFloor: .medium) }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var hits: [SLCHit] = []
        for evidence in SLCPathEvidenceCollector.collect(window) {
            let locations = evidence.locations(in: window)
            // SSH 与钥匙串各有专用规则，避免同一根因重复刷屏。
            guard !locations.contains(.sshDirectory),
                  !SLCRuleSupport.isKeychainBearing(evidence.path, homeDirectory: window.homeDirectory) else {
                continue
            }
            let scoped = locations.filter { $0 == .cloudCredentials || $0 == .gpgKeyring }
            let extensionHit = SLCRuleSupport.credentialFileExtensions
                .contains(RiskPathAnalyzer.fileExtension(of: evidence.path))
            guard !scoped.isEmpty || extensionHit else { continue }
            let rated = locations.filter {
                $0.isCredentialBearing || $0 == .cloudCredentials || $0 == .gpgKeyring
            }
            let named = (rated.isEmpty ? locations : rated).map(\.displayName)
            let locationText = Set(named).sorted().joined(separator: "、")
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("credentials", evidence.path),
                level: SLCRuleSupport.level(of: rated.isEmpty ? locations : rated, isWrite: evidence.isWrite),
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: locationText,
                path: evidence.path,
                command: evidence.command,
                note: evidence.command.map { "来自命令 \($0)" },
                confidence: evidence.command == nil ? 0.9 : 0.8
            ))
        }
        return SLCRuleSupport.merge(hits).map { $0.draft(in: window, using: identity) }
            .map { makeFinding(from: $0) }
    }
}

// MARK: - 11. 系统目录写入

/// `risk.sensitive.system-directory-write` —— 系统目录的写入 / 删除。
///
/// `/etc`、`/usr`、`/bin`、`/sbin`、`/System`、`/Library`、`/private/*` 内的写删判 `.high`；
/// 纯读取系统目录不命中本条（避免把 `cat /etc/hosts` 之类误报）。
public struct SLCSystemDirectoryWriteRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.system-directory-write",
        family: .sensitiveLocation,
        category: .systemFileModification,
        title: "写入系统目录",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .high,
        requiresConfirmation: true,
        summary: "在 /etc、/usr、/bin、/System、/Library、/private 等系统目录内创建、修改或删除文件。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 只针对写类事实。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(requiresWriteEvidence: true)
    }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let home = window.homeDirectory
        var hits: [SLCHit] = []
        for evidence in SLCPathEvidenceCollector.collect(window) {
            guard evidence.isWrite else { continue }
            let locations = evidence.locations(in: window)
            let isSystem = RiskPathAnalyzer.isSystemPath(evidence.path, homeDirectory: home)
                || locations.contains(.systemDirectory)
            guard isSystem else { continue }
            // LaunchAgent 与 Time Machine 有同名分类的专用规则（同为 .systemFileModification），跳过以免重复。
            guard !locations.contains(.launchAgent), !locations.contains(.timeMachineBackup) else { continue }
            let named = locations.filter { $0 == .systemDirectory || $0 == .privilegedHelper }
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("system-write", evidence.path),
                level: SLCRuleSupport.level(
                    of: named.isEmpty ? [SensitiveLocation.systemDirectory] : named,
                    isWrite: true
                ),
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: SLCRuleSupport.names(of: named.isEmpty ? [SensitiveLocation.systemDirectory] : named),
                path: evidence.path,
                command: evidence.command,
                note: evidence.command.map { "来自命令 \($0)" },
                confidence: evidence.command == nil ? 0.9 : 0.85
            ))
        }
        return SLCRuleSupport.merge(hits).map { $0.draft(in: window, using: identity) }
            .map { makeFinding(from: $0) }
    }
}

// MARK: - 12. Time Machine 备份

/// `risk.sensitive.time-machine-backup-touch` —— Time Machine 备份载荷。
///
/// `.Backups.backupdb`、`*.backup.sparsebundle`、`/Volumes/…backup` 的读写一律 `.high`。
public struct SLCTimeMachineTouchRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.time-machine-backup-touch",
        family: .sensitiveLocation,
        category: .systemFileModification,
        title: "触碰 Time Machine 备份",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "读写 .Backups.backupdb 备份卷、备份稀疏镜像或 /Volumes 上的备份目标。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var hits: [SLCHit] = []
        for evidence in SLCPathEvidenceCollector.collect(window) {
            guard evidence.locations(in: window).contains(.timeMachineBackup) else { continue }
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("backup", evidence.path),
                level: SensitiveLocation.timeMachineBackup.writeLevel,
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: SensitiveLocation.timeMachineBackup.displayName,
                path: evidence.path,
                command: evidence.command,
                note: evidence.command.map { "来自命令 \($0)" },
                confidence: evidence.command == nil ? 0.9 : 0.8
            ))
        }
        return SLCRuleSupport.merge(hits).map { $0.draft(in: window, using: identity) }
            .map { makeFinding(from: $0) }
    }
}

// MARK: - 13. 他人主目录

/// `risk.sensitive.other-user-home-access` —— 访问其它用户的 home。
///
/// `RiskPathAnalyzer.isInsideOtherUserHome(_:homeDirectory:)` 为真（`/Users/<他人>`）时，
/// 无论读取还是写删都判 `.high`。
public struct SLCOtherUserHomeAccessRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.other-user-home-access",
        family: .sensitiveLocation,
        category: .sensitivePathAccess,
        title: "访问其他用户主目录",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "读取或改写不属于当前用户的 /Users/<他人> 目录内容。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let home = window.homeDirectory
        var hits: [SLCHit] = []
        for evidence in SLCPathEvidenceCollector.collect(window) {
            guard RiskPathAnalyzer.isInsideOtherUserHome(evidence.path, homeDirectory: home) else { continue }
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("other-user-home", evidence.path),
                level: SensitiveLocation.otherUserHome.writeLevel,
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: SensitiveLocation.otherUserHome.displayName,
                path: evidence.path,
                command: evidence.command,
                note: evidence.command.map { "来自命令 \($0)" },
                confidence: evidence.command == nil ? 0.9 : 0.85
            ))
        }
        return SLCRuleSupport.merge(hits).map { $0.draft(in: window, using: identity) }
            .map { makeFinding(from: $0) }
    }
}

// MARK: - 14. Shell / Agent 配置改写

/// `risk.sensitive.shell-or-agent-config-mutation` —— shell 与 Agent 配置被改写。
///
/// 写 `.zshrc`、`.bashrc`、`.profile`、`.gitconfig`（`SensitiveLocation.shellConfig`）与
/// `~/.claude`、`~/.codex`、`~/.cursor`、`mcp.json`（`SensitiveLocation.agentConfig`）判 `.medium`；
/// 同一窗口内写入次数 ≥ `thresholds.securityMutationCount` 升 `.high`。
/// 分类按位置覆盖：shell 配置 → `.systemFileModification`，Agent 配置 → `.sensitivePathAccess`。
public struct SLCShellOrAgentConfigMutationRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.shell-or-agent-config-mutation",
        family: .sensitiveLocation,
        category: .systemFileModification,
        title: "改写 Shell / Agent 配置",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .medium,
        requiresConfirmation: true,
        summary: "写入 shell 启动配置或 AI Agent 配置目录；窗口内多次写入升级为 HIGH。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 只针对写类事实。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(requiresWriteEvidence: true)
    }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var hits: [SLCHit] = []
        var writeCount = 0
        for evidence in SLCPathEvidenceCollector.collect(window) {
            guard evidence.isWrite else { continue }
            let locations = evidence.locations(in: window)
            let isShell = locations.contains(.shellConfig)
            let isAgent = locations.contains(.agentConfig)
            guard isShell || isAgent else { continue }
            writeCount += 1
            // shell 配置优先级更高（持久化注入），两者同时命中时取 shell 分类。
            let matched: [SensitiveLocation] = isShell ? [SensitiveLocation.shellConfig] : [SensitiveLocation.agentConfig]
            let location = matched[0]
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("config-mutation", evidence.path),
                level: location.writeLevel,
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: location.displayName,
                path: evidence.path,
                command: evidence.command,
                category: location.riskCategory,
                confidence: evidence.command == nil ? 0.85 : 0.8
            ))
        }
        var merged = SLCRuleSupport.merge(hits)
        let threshold = max(1, window.thresholds.securityMutationCount)
        if writeCount >= threshold {
            for index in merged.indices where merged[index].level.rank < RiskLevel.high.rank {
                merged[index].level = .high
                merged[index].note = "会话内配置写入累计 \(writeCount) 次，达到阈值 \(threshold) 次"
            }
        }
        return merged.map { $0.draft(in: window, using: identity) }.map { makeFinding(from: $0) }
    }
}

// MARK: - 15. LaunchAgent / LaunchDaemon 安装

/// `risk.sensitive.launch-agent-install` —— 开机自启项安装。
///
/// 写入 `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons` 下的 plist，
/// 或执行 `launchctl bootstrap|load` 判 `.high`。
public struct SLCLaunchAgentInstallRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.sensitive.launch-agent-install",
        family: .sensitiveLocation,
        category: .systemFileModification,
        title: "安装 LaunchAgent / LaunchDaemon",
        rationaleTemplate: "{action}{location}：{path}（证据 {count} 条）{note}",
        defaultLevel: .high,
        requiresConfirmation: true,
        summary: "向 LaunchAgents/LaunchDaemons 目录写入 plist，或用 launchctl bootstrap/load 装载服务。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 只针对写类事实。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(requiresWriteEvidence: true)
    }

    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let home = window.homeDirectory
        var hits: [SLCHit] = []

        for evidence in SLCPathEvidenceCollector.collect(window) {
            guard evidence.isWrite else { continue }
            guard evidence.locations(in: window).contains(.launchAgent) else { continue }
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("launch-agent", evidence.path),
                level: SensitiveLocation.launchAgent.writeLevel,
                timestamp: evidence.timestamp,
                action: evidence.actionText,
                location: SensitiveLocation.launchAgent.displayName,
                path: evidence.path,
                command: evidence.command,
                note: evidence.command.map { "来自命令 \($0)" },
                confidence: evidence.command == nil ? 0.9 : 0.85
            ))
        }

        for record in window.sortedCommands {
            let facts = RiskCommandFacts(record, homeDirectory: home)
            guard facts.effectiveExecutable == "launchctl" else { continue }
            let subcommand = facts.subcommand ?? ""
            guard subcommand == "bootstrap" || subcommand == "load" else { continue }
            // plist 目标已被路径证据覆盖时不再重复出条目；否则用首个非子命令参数作标签。
            let coveredByPath = facts.targetPaths.contains {
                RiskPathAnalyzer.candidates(for: $0, homeDirectory: home).contains(.launchAgent)
            }
            guard !coveredByPath else { continue }
            let label = facts.targetPaths.first
                ?? facts.operands.dropFirst().first
                ?? "service"
            hits.append(SLCHit(
                suppressionKey: SLCRuleSupport.key("launch-agent", "command:\(label)"),
                level: SensitiveLocation.launchAgent.writeLevel,
                timestamp: record.startedAt,
                action: "用 launchctl \(subcommand) 装载了",
                location: SensitiveLocation.launchAgent.displayName,
                path: facts.targetPaths.first,
                command: record.commandLine,
                note: "命令 \(record.commandLine)",
                confidence: 0.85
            ))
        }

        return SLCRuleSupport.merge(hits).map { $0.draft(in: window, using: identity) }
            .map { makeFinding(from: $0) }
    }
}

// MARK: - Family façade

/// B 敏感位置。规则 id 前缀 `risk.sensitive.*`。
public enum SensitiveLocationRules: Sendable {

    /// 本族全部规则，按声明顺序参与聚合（聚合层负责排序与去重）。
    public static let all: [any AgentRiskRule] = [
        SLCSSHDirectoryAccessRule(),
        SLCKeychainAccessRule(),
        SLCDotEnvTouchRule(),
        SLCCloudOrGPGCredentialsRule(),
        SLCSystemDirectoryWriteRule(),
        SLCTimeMachineTouchRule(),
        SLCOtherUserHomeAccessRule(),
        SLCShellOrAgentConfigMutationRule(),
        SLCLaunchAgentInstallRule()
    ]
}
