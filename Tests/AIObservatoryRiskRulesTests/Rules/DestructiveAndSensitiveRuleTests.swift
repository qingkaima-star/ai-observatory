//
//  DestructiveAndSensitiveRuleTests.swift
//  AIObservatoryRiskRulesTests
//
//  Owner: WS-Risk —— A 族（破坏性文件操作）/ B 族（敏感位置）规则单元测试
//
//  设计约束：
//   · 被测规则全部是**纯函数**，因此这里同步直接调用 `findings(in:)`，
//     不 `sleep`、不 `Task.detached`、不 AsyncSemaphore、不依赖任何真实时序。
//   · 时间与路径全部注入：固定基准 `base`、固定 home `/Users/tester`、
//     固定项目根 `/Users/tester/Projects/App`，保证跨机器可重现。
//   · 断言以**真实实现**为准（阈值取自 `RiskThresholds.standard`：
//     massDeletionCount=8 / massDeletionHighCount=25 / massDeletionSpan=60 /
//     directoryWipeCount=30 / overwriteRemovedLines=300 / 截断 burst 常量 3）。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryRiskRules

// MARK: - 测试骨架（文件私有，避免与其他测试文件符号冲突）

/// 注入的宿主主目录（绝不读真实 `NSHomeDirectory()`）。
private let home = "/Users/tester"

/// 注入的会话项目根，也是本测试唯一的允许写入根。
private let project = "/Users/tester/Projects/App"

/// 固定基准时刻，所有事实相对它偏移。
private let base = Date(timeIntervalSince1970: 1_700_000_000)

/// 构造一条文件变更事实。
private func change(
    _ path: String,
    _ kind: FileChangeKind,
    at offset: TimeInterval = 0,
    added: Int = 0,
    removed: Int = 0,
    size: UInt64 = 1024,
    previous: UInt64? = nil
) -> FileChange {
    FileChange(
        path: path,
        kind: kind,
        timestamp: base.addingTimeInterval(offset),
        sizeBytes: size,
        previousSizeBytes: previous,
        linesAdded: added,
        linesRemoved: removed,
        projectPath: project
    )
}

/// 构造一条读取类时间线事件（B 族的读证据来源）。
private func read(_ path: String, at offset: TimeInterval = 0, command text: String? = nil) -> TimelineEvent {
    TimelineEvent(
        timestamp: base.addingTimeInterval(offset),
        kind: .fileRead,
        title: "读取文件",
        summary: "单元测试构造的读取事实",
        filePath: path,
        command: text,
        projectPath: project
    )
}

/// 构造一条命令事实。
private func command(
    _ executable: String,
    _ arguments: [String],
    at offset: TimeInterval = 0,
    destructive: Bool = false
) -> CommandRecord {
    CommandRecord(
        executable: executable,
        arguments: arguments,
        workingDirectory: project,
        startedAt: base.addingTimeInterval(offset),
        isDestructive: destructive,
        projectPath: project
    )
}

/// 同一目录下的批量删除事实，每条间隔 1 秒。
private func deletions(inDirectory directory: String, count: Int, from startOffset: TimeInterval = 0) -> [FileChange] {
    (0..<count).map { index in
        change("\(directory)/file-\(String(format: "%03d", index)).txt", .deleted, at: startOffset + Double(index))
    }
}

/// 构造规则评估窗口。
private func window(
    changes: [FileChange] = [],
    commands: [CommandRecord] = [],
    events: [TimelineEvent] = [],
    thresholds: RiskThresholds = .standard,
    endOffset: TimeInterval = 600
) -> RiskFactWindow {
    RiskFactWindow(
        events: events,
        fileChanges: changes,
        commands: commands,
        start: base,
        end: base.addingTimeInterval(endOffset),
        homeDirectory: home,
        allowedWriteRoots: [project],
        calendar: RiskFactWindow.gregorianUTC,
        thresholds: thresholds
    )
}

// MARK: - A 族

@Suite("WS-Risk A 族：破坏性文件操作")
struct DestructiveFileOperationRuleTests {

    // —— 验收硬指标 1 ——

    @Test("验收硬指标 1：`rm -rf ~/Documents` 命中 HIGH 且要求确认")
    func homeSubtreeDeletionFromTildeCommand() {
        let rm = command("rm", ["-rf", "~/Documents"])
        let findings = DFOHomeSubtreeDeletionRule().findings(in: window(commands: [rm]))

        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "risk.destructive.home-subtree-deletion")
        #expect(findings.first?.level == .high)
        #expect(findings.first?.requiresConfirmation == true)
        #expect(findings.first?.suppressionKey == "home-subtree-deletion:Documents")
        #expect(findings.first?.command == "rm -rf ~/Documents")

        // 族级视角：A 族全部规则里至少一条 HIGH + 要求确认。
        let family = DestructiveFileOperationRules.all
            .flatMap { $0.findings(in: window(commands: [rm])) }
        #expect(family.contains { $0.level.rank >= RiskLevel.high.rank && $0.requiresConfirmation })
    }

    @Test("`rm -rf ~/Documents` 与等价绝对路径给出同一条命中（说明 `~` 用的是注入 home）")
    func homeSubtreeDeletionTildeMatchesAbsolutePath() {
        let tilde = DFOHomeSubtreeDeletionRule()
            .findings(in: window(commands: [command("rm", ["-rf", "~/Documents"])]))
        let absolute = DFOHomeSubtreeDeletionRule()
            .findings(in: window(commands: [command("rm", ["-rf", "/Users/tester/Documents"])]))

        #expect(!tilde.isEmpty)
        #expect(absolute.count == 1)
        #expect(tilde.first?.suppressionKey == absolute.first?.suppressionKey)
        #expect(tilde.first?.level == absolute.first?.level)
        #expect(absolute.first?.filePaths == ["/Users/tester/Documents"])
    }

    @Test("`rm -rf ~` 命中 home 根：升级为 CRITICAL 且要求确认")
    func homeRootDeletionIsCritical() {
        let findings = DFOHomeSubtreeDeletionRule()
            .findings(in: window(commands: [command("rm", ["-rf", "~"])]))
        #expect(findings.count == 1)
        #expect(findings.first?.level == .critical)
        #expect(findings.first?.requiresConfirmation == true)
    }

    // —— 验收硬指标 2（规则层折叠）——

    @Test("验收硬指标 2：同一 60 秒窗口内 42 条删除只产出 1 条命中")
    func massDeletionWithinOneClusterCollapsesToSingleFinding() {
        let burst = deletions(inDirectory: "\(project)/Sources", count: 42)
        let findings = DFOMassDeletionWindowRule().findings(in: window(changes: burst))

        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "risk.destructive.mass-deletion-window")
        #expect((findings.first?.evidenceCount ?? 0) >= 42)
        #expect(findings.first?.level.rank ?? -1 >= RiskLevel.high.rank)
        #expect(findings.first?.requiresConfirmation == true)
    }

    @Test("跨簇不折叠：相隔 20 分钟的两个 60 秒删除突发各出 1 条命中")
    func massDeletionKeepsSeparateClustersApart() {
        var burst = deletions(inDirectory: "\(project)/Sources", count: 21, from: 0)
        burst += deletions(inDirectory: "\(home)/Downloads", count: 21, from: 1200)
        let findings = DFOMassDeletionWindowRule().findings(
            in: window(changes: burst, endOffset: 2000)
        )

        #expect(findings.count == 2)
        #expect(Set(findings.map(\.suppressionKey)).count == 2)
        #expect(findings.allSatisfy { $0.ruleID == "risk.destructive.mass-deletion-window" })
        #expect(findings.allSatisfy { $0.evidenceCount == 21 })
        #expect(findings.allSatisfy { $0.suppressionKey.hasPrefix("mass-deletion:") })
    }

    // —— 规则 2：目录清空 ——

    @Test("directory-wipe：同一父目录下 30 条删除 → 命中且抑制键含该父目录")
    func directoryWipeGroupsByParent() {
        let findings = DFODirectoryWipeRule()
            .findings(in: window(changes: deletions(inDirectory: "\(project)/Logs", count: 30)))

        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "risk.destructive.directory-wipe")
        #expect(findings.first?.suppressionKey.contains("\(project)/Logs") == true)
        #expect(findings.first?.level == .high)
        #expect(findings.first?.requiresConfirmation == true)
        #expect((findings.first?.evidenceCount ?? 0) >= 30)
    }

    @Test("directory-wipe 负例：删除分散在 29 个不同父目录（未达 30）→ 无命中")
    func directoryWipeBelowThreshold() {
        let scattered = (0..<29).map { index in
            change("\(project)/Dir\(index)/only.txt", .deleted, at: Double(index))
        }
        #expect(DFODirectoryWipeRule().findings(in: window(changes: scattered)).isEmpty)
    }

    // —— 规则 3：越界删除 ——

    @Test("outside-project-write 正例：删除主目录文档 → 命中")
    func outsideProjectWriteHitsDeletionOutsideRoots() {
        let findings = DFOOutsideProjectWriteRule().findings(
            in: window(changes: [change("\(home)/Documents/notes.txt", .deleted)])
        )
        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "risk.destructive.outside-project-write")
        #expect(findings.first?.level.rank ?? -1 >= RiskLevel.medium.rank)
        #expect(findings.first?.requiresConfirmation == true)
        #expect(findings.first?.suppressionKey.hasPrefix("outside-project-deletion:") == true)
    }

    @Test("outside-project-write 负例：删除项目内路径 → 无命中")
    func outsideProjectWriteIgnoresInsideProject() {
        let findings = DFOOutsideProjectWriteRule().findings(
            in: window(changes: [change("\(project)/Sources/App.swift", .deleted)])
        )
        #expect(findings.isEmpty)
    }

    @Test("outside-project-write：`rm` 命令目标越界（含 `~` 展开）也算证据")
    func outsideProjectWriteUsesCommandTargets() {
        let tilde = DFOOutsideProjectWriteRule().findings(
            in: window(commands: [command("rm", ["-f", "~/Downloads/payload.zip"])])
        )
        #expect(tilde.count == 1)
        #expect(tilde.first?.filePaths.contains("/Users/tester/Downloads/payload.zip") == true)

        let inside = DFOOutsideProjectWriteRule().findings(
            in: window(commands: [command("rm", ["-f", "\(project)/DerivedData/stale.o"])])
        )
        #expect(inside.isEmpty)
    }

    // —— 规则 4：覆盖式重写 ——

    @Test("overwrite-rewrite 正例：单条 modified 移除 500 行（阈值 300）→ 命中")
    func overwriteRewriteHitsHeavyRemoval() {
        let findings = DFOOverwriteRewriteRule().findings(
            in: window(changes: [change("\(project)/Sources/Legacy.swift", .modified, added: 10, removed: 500)])
        )
        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "risk.destructive.overwrite-rewrite")
        #expect(findings.first?.level.rank ?? -1 >= RiskLevel.medium.rank)
        #expect(findings.first?.suppressionKey.contains("Legacy.swift") == true)
    }

    @Test("overwrite-rewrite 负例：只加不删 → 无命中")
    func overwriteRewriteIgnoresAddOnly() {
        let findings = DFOOverwriteRewriteRule().findings(
            in: window(changes: [change("\(project)/Sources/Fresh.swift", .modified, added: 400, removed: 0)])
        )
        #expect(findings.isEmpty)
    }

    // —— 规则 5（体积收缩支路）——

    @Test("overwrite-rewrite 支路：体积大幅收缩也能命中")
    func overwriteRewriteHitsSizeShrink() {
        let findings = DFOOverwriteRewriteRule().findings(
            in: window(changes: [
                change("\(project)/Sources/Blob.swift", .modified, added: 1, removed: 2, size: 1_000, previous: 90_000),
            ])
        )
        #expect(findings.count == 1)
    }

    // —— 规则 6：批量截断 ——

    @Test("file-truncation-burst 正例：3 个路径被截断为 0 字节 → 恰好 1 条命中")
    func fileTruncationBurstHits() {
        let logs = ["a.log", "b.log", "c.log"].map { name in
            change("\(project)/Logs/\(name)", .modified, at: 1, size: 0)
        }
        let findings = DFOFileTruncationBurstRule().findings(in: window(changes: logs))
        #expect(findings.count == 1)
        #expect(findings.first?.ruleID == "risk.destructive.file-truncation-burst")
        #expect(findings.first?.suppressionKey == "file-truncation")
        #expect(findings.first?.evidenceCount == 3)
    }

    @Test("file-truncation-burst 负例：只有 2 个截断路径 → 无命中")
    func fileTruncationBurstBelowThreshold() {
        let logs = ["a.log", "b.log"].map { name in
            change("\(project)/Logs/\(name)", .modified, at: 1, size: 0)
        }
        #expect(DFOFileTruncationBurstRule().findings(in: window(changes: logs)).isEmpty)
    }

    // —— 空输入 / 确定性 ——

    @Test("空窗口：A 族 6 条规则均无命中")
    func emptyWindowProducesNoFindings() {
        let empty = RiskFactWindow(homeDirectory: home)
        #expect(DFOMassDeletionWindowRule().findings(in: empty).isEmpty)
        #expect(DFODirectoryWipeRule().findings(in: empty).isEmpty)
        #expect(DFOOutsideProjectWriteRule().findings(in: empty).isEmpty)
        #expect(DFOOverwriteRewriteRule().findings(in: empty).isEmpty)
        #expect(DFOHomeSubtreeDeletionRule().findings(in: empty).isEmpty)
        #expect(DFOFileTruncationBurstRule().findings(in: empty).isEmpty)
        #expect(DestructiveFileOperationRules.all.flatMap { $0.findings(in: empty) }.isEmpty)
    }

    @Test("同一窗口重复评估结果逐字节相同（纯函数契约）")
    func evaluationIsDeterministic() {
        let mixed = window(
            changes: deletions(inDirectory: "\(home)/Desktop", count: 12)
                + [change("\(home)/Documents/notes.txt", .deleted, at: 45),
                   change("\(project)/Sources/Legacy.swift", .modified, at: 20, removed: 800)],
            commands: [command("rm", ["-rf", "~/Documents"], at: 30, destructive: true)],
            events: [read("\(project)/Sources/App.swift", at: 5)]
        )
        for rule in DestructiveFileOperationRules.all {
            #expect(rule.findings(in: mixed) == rule.findings(in: mixed))
        }
    }
}

// MARK: - B 族

@Suite("WS-Risk B 族：敏感位置")
struct SensitiveLocationRuleTests {

    // —— 验收硬指标 3 ——

    @Test("验收硬指标 3a：读 `~/.ssh/id_rsa` → 命中且等级不低于 MEDIUM")
    func readingSSHPrivateKeyIsSensitive() {
        let findings = SLCSSHDirectoryAccessRule()
            .findings(in: window(events: [read("\(home)/.ssh/id_rsa")]))

        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.ruleID == "risk.sensitive.ssh-directory-access" })
        #expect(findings.allSatisfy { $0.category == .credentialExposure })
        if let finding = findings.first {
            #expect(finding.level.rank >= RiskLevel.medium.rank)
        } else {
            #expect(findings.count == 0)
        }
        #expect(findings.first?.suppressionKey == "ssh:/Users/tester/.ssh/id_rsa")
    }

    @Test("验收硬指标 3b：读 `<project>/.env` → 命中且等级不低于 MEDIUM")
    func readingDotEnvIsSensitive() {
        let findings = SLCDotEnvTouchRule()
            .findings(in: window(events: [read("\(project)/.env")]))

        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.ruleID == "risk.sensitive.dotenv-touch" })
        if let finding = findings.first {
            #expect(finding.level.rank >= RiskLevel.medium.rank)
        } else {
            #expect(findings.count == 0)
        }
    }

    // —— 规则 7：SSH ——

    @Test("写/删 `~/.ssh/authorized_keys` 的等级不低于读取同一文件")
    func sshWriteNeverLowerThanRead() {
        let path = "\(home)/.ssh/authorized_keys"
        let reading = SLCSSHDirectoryAccessRule().findings(in: window(events: [read(path)]))
        let writing = SLCSSHDirectoryAccessRule().findings(in: window(changes: [change(path, .deleted)]))

        #expect(!reading.isEmpty)
        #expect(!writing.isEmpty)
        #expect(writing.first?.requiresConfirmation == true)
        if let readLevel = reading.first?.level, let writeLevel = writing.first?.level {
            #expect(writeLevel.rank >= readLevel.rank)
        } else {
            #expect(reading.isEmpty && writing.isEmpty)
        }
    }

    @Test("同一 SSH 文件被读 5 次只出 1 条命中（按抑制键归并）")
    func repeatedSSHReadsCollapseToOneFinding() {
        let events = (0..<5).map { read("\(home)/.ssh/id_ed25519", at: Double($0)) }
        let findings = SLCSSHDirectoryAccessRule().findings(in: window(events: events))
        #expect(findings.count == 1)
        #expect(findings.first?.evidenceCount == 5)
    }

    // —— 规则 8：钥匙串 ——

    @Test("钥匙串目录访问命中")
    func keychainDirectoryAccessHits() {
        let findings = SLCKeychainAccessRule().findings(
            in: window(events: [read("\(home)/Library/Keychains/login.keychain-db")])
        )
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.ruleID == "risk.sensitive.keychain-access" })
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
        #expect(findings.first?.filePaths.contains("\(home)/Library/Keychains/login.keychain-db") == true)
    }

    @Test("`security unlock-keychain` 命令也命中钥匙串规则")
    func keychainCommandHits() {
        let findings = SLCKeychainAccessRule().findings(
            in: window(commands: [command("security", ["unlock-keychain", "-p", "hunter2"])])
        )
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
    }

    // —— 规则 9：.env ——

    @Test("写入 `.env.production` 判为写证据，等级不低于读取")
    func dotenvWriteIsAtLeastRead() {
        let path = "\(project)/.env.production"
        let reading = SLCDotEnvTouchRule().findings(in: window(events: [read(path)]))
        let writing = SLCDotEnvTouchRule().findings(in: window(changes: [change(path, .modified)]))
        #expect(!reading.isEmpty)
        #expect(!writing.isEmpty)
        if let readLevel = reading.first?.level, let writeLevel = writing.first?.level {
            #expect(writeLevel.rank >= readLevel.rank)
            #expect(writeLevel.rank >= RiskLevel.high.rank)
        } else {
            #expect(reading.isEmpty && writing.isEmpty)
        }
    }

    // —— 规则 10：云 / GPG / 凭据载体 ——

    @Test("`~/.aws/credentials` 命中")
    func awsCredentialsHit() {
        let findings = SLCCloudOrGPGCredentialsRule()
            .findings(in: window(events: [read("\(home)/.aws/credentials")]))
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.ruleID == "risk.sensitive.cloud-or-gpg-credentials" })
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
    }

    @Test("`~/.gnupg` 密钥环命中")
    func gnupgKeyringHits() {
        let findings = SLCCloudOrGPGCredentialsRule()
            .findings(in: window(events: [read("\(home)/.gnupg/private-keys-v1.d/key.key")]))
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
    }

    @Test("`.pem` 与 `.p12` 凭据载体文件各命中一条")
    func credentialFileExtensionsHit() {
        let pem = SLCCloudOrGPGCredentialsRule()
            .findings(in: window(events: [read("\(home)/Certs/server.pem")]))
        let p12 = SLCCloudOrGPGCredentialsRule()
            .findings(in: window(changes: [change("\(home)/Certs/client.p12", .created)]))

        #expect(!pem.isEmpty)
        #expect(!p12.isEmpty)
        #expect(pem.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
        #expect(p12.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
    }

    // —— 规则 11：系统目录写入 ——

    @Test("/etc 与 /usr 下写入 → 命中、分类为系统文件修改、等级不低于 HIGH")
    func systemDirectoryWritesHit() {
        let rule = SLCSystemDirectoryWriteRule()
        let etcHosts = rule.findings(in: window(changes: [change("/etc/hosts", .modified)]))
        let localBin = rule.findings(in: window(changes: [change("/usr/local/bin/x", .created)]))

        #expect(!etcHosts.isEmpty)
        #expect(!localBin.isEmpty)
        #expect(etcHosts.allSatisfy { $0.category == .systemFileModification })
        #expect(etcHosts.allSatisfy { $0.level.rank >= RiskLevel.high.rank })
        #expect(localBin.allSatisfy { $0.category == .systemFileModification })
        #expect(localBin.allSatisfy { $0.level.rank >= RiskLevel.high.rank })
        #expect(etcHosts.first?.requiresConfirmation == true)
    }

    @Test("纯读取系统目录不触发系统写入规则")
    func systemDirectoryReadsAreIgnored() {
        let findings = SLCSystemDirectoryWriteRule()
            .findings(in: window(events: [read("/etc/hosts")]))
        #expect(findings.isEmpty)
    }

    @Test("/Library/LaunchDaemons 的 plist → B 族至少一条系统文件修改 HIGH")
    func launchDaemonPlistHits() {
        let findings = SensitiveLocationRules.all.flatMap {
            $0.findings(in: window(changes: [change("/Library/LaunchDaemons/com.evil.plist", .created)]))
        }
        #expect(findings.contains { $0.category == .systemFileModification && $0.level.rank >= RiskLevel.high.rank })
        #expect(findings.contains { $0.ruleID == "risk.sensitive.launch-agent-install" })
    }

    // —— 规则 12：Time Machine ——

    @Test("Time Machine 备份载荷命中")
    func timeMachineBackupHits() {
        let findings = SLCTimeMachineTouchRule().findings(
            in: window(changes: [change("/Volumes/Backup/.Backups.backupdb/Mac/2024-01-01-000000", .deleted)])
        )
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.ruleID == "risk.sensitive.time-machine-backup-touch" })
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
        #expect(findings.first?.category == .systemFileModification)
    }

    // —— 规则 13：他人主目录 ——

    @Test("其他用户 home 访问命中")
    func otherUserHomeHits() {
        let findings = SLCOtherUserHomeAccessRule()
            .findings(in: window(events: [read("/Users/victim/Desktop/secrets.txt")]))
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.ruleID == "risk.sensitive.other-user-home-access" })
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
        #expect(findings.first?.filePaths == ["/Users/victim/Desktop/secrets.txt"])
    }

    @Test("自己的 home 不算他人主目录")
    func ownHomeIsNotAnotherUserHome() {
        let findings = SLCOtherUserHomeAccessRule()
            .findings(in: window(events: [read("\(home)/Desktop/notes.txt")]))
        #expect(findings.isEmpty)
    }

    // —— 规则 14：Shell / Agent 配置 ——

    @Test("写入 `~/.zshrc` 命中 Shell 配置改写")
    func shellConfigMutationHits() {
        let findings = SLCShellOrAgentConfigMutationRule()
            .findings(in: window(changes: [change("\(home)/.zshrc", .modified)]))
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.ruleID == "risk.sensitive.shell-or-agent-config-mutation" })
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
        #expect(findings.first?.requiresConfirmation == true)
    }

    @Test("写入 `~/.claude/settings.json` 命中 Agent 配置改写")
    func agentConfigMutationHits() {
        let findings = SLCShellOrAgentConfigMutationRule()
            .findings(in: window(changes: [change("\(home)/.claude/settings.json", .created)]))
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
    }

    // —— 规则 15：LaunchAgent ——

    @Test("LaunchAgents 下写入 plist 命中开机自启规则")
    func launchAgentInstallHits() {
        let findings = SLCLaunchAgentInstallRule().findings(
            in: window(changes: [change("\(home)/Library/LaunchAgents/com.example.agent.plist", .created)])
        )
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.ruleID == "risk.sensitive.launch-agent-install" })
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.high.rank })
    }

    @Test("`launchctl bootstrap` 装载 plist 命中 LaunchAgent 规则")
    func launchctlBootstrapHits() {
        let findings = SLCLaunchAgentInstallRule().findings(in: window(commands: [
            command("launchctl", ["bootstrap", "gui/501", "\(home)/Library/LaunchAgents/com.example.agent.plist"]),
        ]))
        #expect(!findings.isEmpty)
        #expect(findings.allSatisfy { $0.level.rank >= RiskLevel.medium.rank })
    }

    // —— 负例 / 空输入 / 确定性 ——

    @Test("负例：普通项目源码读写 → B 族 9 条规则合计 0 命中")
    func ordinaryProjectSourcesAreClean() {
        let path = "\(project)/Sources/Main.swift"
        let w = window(
            changes: [change(path, .modified, added: 40, removed: 5)],
            events: [read(path), read("\(project)/Tests/MainTests.swift", at: 3)]
        )
        let findings = SensitiveLocationRules.all.flatMap { $0.findings(in: w) }
        #expect(findings.isEmpty)
    }

    @Test("空窗口：B 族各规则均无命中")
    func emptyWindowProducesNoFindings() {
        let empty = RiskFactWindow(homeDirectory: home)
        for rule in SensitiveLocationRules.all {
            #expect(rule.findings(in: empty).isEmpty)
        }
    }

    @Test("同一窗口重复评估结果逐字节相同（纯函数契约）")
    func evaluationIsDeterministic() {
        let mixed = window(
            changes: [
                change("\(home)/.ssh/authorized_keys", .modified),
                change("\(home)/Library/LaunchAgents/com.example.agent.plist", .created, at: 2),
                change("/etc/hosts", .modified, at: 3),
                change("\(project)/.env", .deleted, at: 4),
            ],
            commands: [command("security", ["unlock-keychain"], at: 5)],
            events: [read("\(home)/.aws/credentials", at: 1), read("\(home)/.gnupg/pubring.kbx", at: 6)]
        )
        for rule in SensitiveLocationRules.all {
            #expect(rule.findings(in: mixed) == rule.findings(in: mixed))
        }
    }
}
