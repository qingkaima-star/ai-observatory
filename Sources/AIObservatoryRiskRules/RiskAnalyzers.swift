//
//  RiskAnalyzers.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk
//
//  规则族共用的两个纯函数分析器：
//   · `RiskPathAnalyzer`     —— 路径归一化与敏感位置归类（不访问文件系统）
//   · `RiskCommandClassifier`—— 基于 **结构化 argv** 的行为谓词
//
//  与 `Platform/Telemetry/DestructiveCommandRules` 的分工：
//  Telemetry 负责单条命令**文本**的即时分级（正则/子串）；本文件只按 argv 结构
//  判断"这条命令在会话里做了什么类别的事"，供 C/D 族做跨命令的聚合判定。
//  两层结论通过 `RiskFactWindow.classification(for:)` 合流，本文件不重复文本正则库。
//

import Foundation
import AIObservatoryCore

// MARK: - Sensitive Location

/// 敏感位置类别。每一项自带契约分类与最低风险等级。
public enum SensitiveLocation: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case sshDirectory
    case keychain
    case cloudCredentials
    case gpgKeyring
    case dotEnvFile
    case credentialFile
    case shellConfig
    case agentConfig
    case browserProfile
    case systemDirectory
    case privilegedHelper
    case launchAgent
    case timeMachineBackup
    case otherUserHome
    case applicationSupport
    case dotConfig

    public var id: String { rawValue }

    /// 该位置命中后应归入的契约风险分类。
    public var riskCategory: RiskCategory {
        switch self {
        case .sshDirectory, .keychain, .cloudCredentials, .gpgKeyring, .dotEnvFile, .credentialFile:
            return .credentialExposure
        case .systemDirectory, .privilegedHelper, .launchAgent, .timeMachineBackup:
            return .systemFileModification
        case .otherUserHome, .browserProfile, .applicationSupport, .dotConfig, .shellConfig, .agentConfig:
            return .sensitivePathAccess
        }
    }

    /// 读取该位置的最低风险等级（写操作由规则在此之上叠加）。
    public var readLevel: RiskLevel {
        switch self {
        case .sshDirectory, .keychain, .cloudCredentials, .gpgKeyring, .credentialFile:
            return .high
        case .dotEnvFile, .browserProfile, .otherUserHome, .timeMachineBackup, .privilegedHelper:
            return .medium
        case .systemDirectory, .launchAgent, .applicationSupport, .dotConfig, .shellConfig, .agentConfig:
            return .low
        }
    }

    /// 写/删该位置的最低风险等级。
    public var writeLevel: RiskLevel {
        switch self {
        case .sshDirectory, .keychain, .cloudCredentials, .gpgKeyring, .credentialFile, .dotEnvFile, .timeMachineBackup, .privilegedHelper:
            return .high
        case .systemDirectory, .launchAgent, .otherUserHome:
            return .high
        case .browserProfile, .applicationSupport, .dotConfig, .shellConfig, .agentConfig:
            return .medium
        }
    }

    /// 中文说明，用于理由文本。
    public var displayName: String {
        switch self {
        case .sshDirectory:      return "SSH 目录"
        case .keychain:          return "钥匙串"
        case .cloudCredentials:  return "云端凭据"
        case .gpgKeyring:        return "GPG 密钥环"
        case .dotEnvFile:        return ".env 环境变量文件"
        case .credentialFile:    return "凭据文件"
        case .shellConfig:       return "Shell 配置文件"
        case .agentConfig:       return "Agent 配置文件"
        case .browserProfile:    return "浏览器用户数据"
        case .systemDirectory:   return "系统目录"
        case .privilegedHelper:  return "特权辅助程序目录"
        case .launchAgent:       return "LaunchAgent/LaunchDaemon"
        case .timeMachineBackup: return "Time Machine 备份"
        case .otherUserHome:     return "其他用户主目录"
        case .applicationSupport: return "Application Support"
        case .dotConfig:         return "用户配置目录"
        }
    }

    /// 是否属于凭据类位置（供 B/C 族跨层升级等级）。
    public var isCredentialBearing: Bool {
        switch self {
        case .sshDirectory, .keychain, .cloudCredentials, .gpgKeyring, .dotEnvFile, .credentialFile, .browserProfile:
            return true
        case .shellConfig, .agentConfig, .systemDirectory, .privilegedHelper, .launchAgent,
             .timeMachineBackup, .otherUserHome, .applicationSupport, .dotConfig:
            return false
        }
    }
}

// MARK: - Path Analyzer

/// 纯字符串路径分析器。**不做任何 IO**：不 stat、不解析符号链接、不探测 git 仓库。
public enum RiskPathAnalyzer {

    /// 归一化路径：展开 `~`/`$HOME`、去除重复分隔符与 `.` 段、去掉结尾斜杠。
    public static func normalized(_ path: String, homeDirectory: String) -> String {
        let expanded = expandTilde(path, homeDirectory: homeDirectory)
        guard !expanded.isEmpty else { return "" }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return trimmed(standardized)
    }

    /// 目录形式归一化（与 `normalized` 相同，仅语义区分）。
    public static func normalizedDirectory(_ path: String) -> String {
        normalized(path, homeDirectory: NSHomeDirectory())
    }

    /// 目录形式归一化，使用注入的 home。
    public static func normalizedDirectory(_ path: String, homeDirectory: String) -> String {
        normalized(path, homeDirectory: homeDirectory)
    }

    /// 路径是否落在任一根目录之内（根目录本身也算在内）。
    public static func isPath(_ path: String, withinRoots roots: [String], homeDirectory: String) -> Bool {
        let candidate = normalized(path, homeDirectory: homeDirectory)
        guard !candidate.isEmpty else { return false }
        return roots.contains { root in
            let base = normalized(root, homeDirectory: homeDirectory)
            guard !base.isEmpty else { return false }
            return candidate == base || candidate.hasPrefix(base + "/")
        }
    }

    /// 路径的父目录。
    public static func parent(of path: String, homeDirectory: String) -> String {
        let full = normalized(path, homeDirectory: homeDirectory)
        let url = URL(fileURLWithPath: full)
        return trimmed(url.deletingLastPathComponent().path)
    }

    /// 最后一段文件名。
    public static func fileName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// 小写化的文件扩展名（无扩展名时为空串）。
    public static func fileExtension(of path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }

    /// 归一化路径（无 home 注入的版本，用于纯绝对路径）。
    public static func normalized(_ path: String) -> String {
        normalized(path, homeDirectory: NSHomeDirectory())
    }

    /// 注入 home 的根判定。
    public static func isPath(_ path: String, withinRoots roots: [String]) -> Bool {
        isPath(path, withinRoots: roots, homeDirectory: NSHomeDirectory())
    }

    /// 归类路径命中的敏感位置；多个命中时返回最严重的一个。
    public static func classify(_ path: String, homeDirectory: String) -> SensitiveLocation? {
        candidates(for: path, homeDirectory: homeDirectory).max { lhs, rhs in
            lhs.writeLevel.rank < rhs.writeLevel.rank
        }
    }

    /// 路径命中的全部敏感位置（按 `SensitiveLocation.allCases` 顺序）。
    public static func candidates(for path: String, homeDirectory: String) -> [SensitiveLocation] {
        let full = normalized(path, homeDirectory: homeDirectory)
        guard !full.isEmpty else { return [] }
        let lowered = full.lowercased()
        let home = normalized(homeDirectory, homeDirectory: homeDirectory)
        let name = fileName(of: full).lowercased()
        let ext = fileExtension(of: full)

        var hits: [SensitiveLocation] = []
        for location in SensitiveLocation.allCases where matches(location, lowered: lowered, name: name, ext: ext, full: full, home: home) {
            hits.append(location)
        }
        return hits
    }

    /// 是否属于任一"凭据类"位置。
    public static func isCredentialBearing(_ path: String, homeDirectory: String) -> Bool {
        candidates(for: path, homeDirectory: homeDirectory).contains { $0.isCredentialBearing }
    }

    /// 是否为系统级路径（`/etc`、`/usr`、`/bin`、`/sbin`、`/System`、`/private/*`、`/Library`）。
    public static func isSystemPath(_ path: String, homeDirectory: String) -> Bool {
        matches(.systemDirectory, lowered: normalized(path, homeDirectory: homeDirectory).lowercased(),
                name: "", ext: "", full: normalized(path, homeDirectory: homeDirectory),
                home: normalized(homeDirectory, homeDirectory: homeDirectory))
    }

    /// 是否位于 `/Users/<other>` 之类的其他用户主目录。
    public static func isInsideOtherUserHome(_ path: String, homeDirectory: String) -> Bool {
        let full = normalized(path, homeDirectory: homeDirectory)
        let home = normalized(homeDirectory, homeDirectory: homeDirectory)
        let usersRoot = "/Users/"
        guard full.hasPrefix(usersRoot) else { return false }
        let remainder = String(full.dropFirst(usersRoot.count))
        guard let victim = remainder.firstSeparatorSegment else { return false }
        guard let owner = home.firstSeparatorSegmentAfter(usersRoot) else { return true }
        return victim.caseInsensitiveCompare(owner) != .orderedSame
    }

    /// 把路径列表按父目录分组，用于"清空整个目录"判定。
    public static func groupByParent(_ paths: [String], homeDirectory: String) -> [String: [String]] {
        paths.reduce(into: [:]) { buckets, path in
            let parent = parent(of: path, homeDirectory: homeDirectory)
            buckets[parent, default: []].append(path)
        }
    }

    /// 列表中最共同的父目录；并列时按字典序取第一个，保证确定性。
    public static func dominantParent(of paths: [String], homeDirectory: String) -> String? {
        let buckets = groupByParent(paths, homeDirectory: homeDirectory)
        return buckets.max { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return lhs.key > rhs.key
        }?.key
    }

    // MARK: 匹配实现

    private static func matches(
        _ location: SensitiveLocation,
        lowered: String,
        name: String,
        ext: String,
        full: String,
        home: String
    ) -> Bool {
        switch location {
        case .sshDirectory:
            return isWithin(lowered, directory: home + "/.ssh")
        case .keychain:
            return isWithin(lowered, directory: home + "/library/keychains")
                || isWithin(lowered, directory: "/library/keychains")
                || name.contains("keychain")
        case .cloudCredentials:
            return isWithin(lowered, directory: home + "/.aws")
                || isWithin(lowered, directory: home + "/.azure")
                || isWithin(lowered, directory: home + "/.config/gcloud")
                || isWithin(lowered, directory: home + "/.docker/config.json")
                || name == "credentials.json"
                || name == "ghs_credentials"
                || name.hasPrefix("google-services-info")
        case .gpgKeyring:
            return isWithin(lowered, directory: home + "/.gnupg")
        case .dotEnvFile:
            return name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env")
                || name == ".env.local" || name == "env.production"
        case .credentialFile:
            return credentialExtensions.contains(ext)
                || credentialNames.contains(name)
                || name.contains("secret") || name.contains("token") || name.contains("apikey")
                || name.contains("api_key") || name.contains("password")
        case .shellConfig:
            return shellConfigNames.contains(name)
        case .agentConfig:
            return isWithin(lowered, directory: home + "/.claude")
                || isWithin(lowered, directory: home + "/.codex")
                || isWithin(lowered, directory: home + "/.cursor")
                || isWithin(lowered, directory: home + "/.config/cursor")
                || isWithin(lowered, directory: home + "/.aider")
                || name == "mcp.json" || name == "claude_desktop_config.json"
        case .browserProfile:
            return lowered.contains("/library/application support/google/chrome")
                || lowered.contains("/library/application support/com.microsoft.edge")
                || lowered.contains("/library/application support/firefox/profiles")
                || lowered.contains("/library/application support/brave-software")
                || name == "cookies" || name == "login data"
        case .systemDirectory:
            return systemRoots.contains { isWithin(lowered, directory: $0) }
        case .privilegedHelper:
            return isWithin(lowered, directory: "/library privileged helpers")
                || isWithin(lowered, directory: "/private/var/db/sudo")
                || lowered.hasSuffix(".privilegedhelper")
        case .launchAgent:
            return isWithin(lowered, directory: home + "/library/launchagents")
                || isWithin(lowered, directory: "/library/launchagents")
                || isWithin(lowered, directory: "/library/launchdaemons")
                || (ext == "plist" && (lowered.contains("launchagents") || lowered.contains("launchdaemons")))
        case .timeMachineBackup:
            return lowered.contains(".backups.backupdb") || lowered.hasSuffix("backup.sparsebundle")
                || lowered.contains("/volumes/") && lowered.contains("backup")
        case .otherUserHome:
            return isInsideOtherUserHome(full, homeDirectory: home)
        case .applicationSupport:
            return isWithin(lowered, directory: home + "/library/application support")
                || isWithin(lowered, directory: "/library/application support")
        case .dotConfig:
            return isWithin(lowered, directory: home + "/.config")
        }
    }

    private static func isWithin(_ loweredPath: String, directory: String) -> Bool {
        let base = trimmed(directory.lowercased())
        guard !base.isEmpty else { return false }
        return loweredPath == base || loweredPath.hasPrefix(base + "/")
    }

    private static func trimmed(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private static func expandTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            return homeDirectory + "/" + path.dropFirst(2)
        }
        if path.hasPrefix("$HOME/") { return homeDirectory + "/" + path.dropFirst(6) }
        if path.hasPrefix("$HOME") { return homeDirectory + path.dropFirst(5) }
        return path
    }

    private static let systemRoots: [String] = [
        "/etc", "/var", "/usr", "/bin", "/sbin", "/system", "/private/etc", "/private/var",
        "/library", "/applications", "/opt/homebrew/etc"
    ]

    private static let credentialExtensions: [String] = [
        "pem", "key", "p12", "pfx", "kdbx", "ppk", "asc", "jks", "keystore"
    ]

    private static let credentialNames: [String] = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "authorized_keys", "known_hosts",
        ".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials",
        "shadow", "sudoers", "wp-config.php", "secrets.plist"
    ]

    private static let shellConfigNames: [String] = [
        ".zshrc", ".bashrc", ".bash_profile", ".profile", ".zprofile", ".zshenv",
        ".zlogin", ".bash_logout", ".inputrc", ".gitconfig", ".gitignore_global",
        ".vimrc", ".emacs", ".config/fish/config.fish"
    ]
}

private extension String {
    /// 第一段路径分量（`/Users/alice/x` → `Users`）。
    var firstSeparatorSegment: String? {
        let parts = split(separator: "/", omittingEmptySubsequences: true)
        return parts.first.map(String.init)
    }

    /// 去掉指定前缀后的第一段。
    func firstSeparatorSegmentAfter(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
    }
}

// MARK: - Command Facts

/// 一条命令的结构化事实。从 `CommandRecord` 的 argv 解析，必要时回退到 `commandLine` 空白切分。
public struct RiskCommandFacts: Sendable, Hashable {

    /// 小写化的可执行文件名（不含目录）。
    public var executable: String
    /// 可执行文件的完整路径（若 argv 提供了绝对路径）。
    public var executablePath: String
    /// 参数列表（已去掉可执行文件本身）。
    public var arguments: [String]
    /// 提权包装器（`sudo`/`doas`/`pkexec`/`su`），无则为 nil。
    public var privilegeWrapper: String?
    /// 剥掉包装器（提权、`env`、`time`、`nice`、`xargs`）之后的真实可执行名。
    public var effectiveExecutable: String
    /// 剥掉包装器之后的真实参数。
    public var effectiveArguments: [String]
    /// 第一个非选项参数，通常是子命令。
    public var subcommand: String?
    /// 短选项展开后的字母集合（`-rf` → `r`、`f`）。
    public var shortFlags: Set<Character>
    /// 长选项名（去掉前导 `--`，小写）。
    public var longFlags: Set<String>
    /// 全部非选项参数（原样、小写）。
    public var operands: [String]
    /// 从命令行文本识别出的重定向与管道片段。
    public var pipelines: [String]
    /// 管道到了解释器。
    public var pipesToInterpreter: Bool
    /// argv 中看起来像路径的参数（已展开 `~`）。
    public var targetPaths: [String]
    /// 是否存在指向 home 根或其直接子目录整体（`~`、`~/Documents`）的目标。
    public var targetsHomeRoot: Bool
    /// 工作目录。
    public var workingDirectory: String?
    /// 原始记录 ID，便于理由文本回链。
    public var commandID: UUID?
    /// 命令文本。
    public var commandLine: String

    /// - Parameter homeDirectory: 用于展开 argv 中的 `~`；规则实现应传入 `RiskFactWindow.homeDirectory`
    ///   以保证跨机器可重现。
    public init(_ record: CommandRecord, homeDirectory: String = NSHomeDirectory()) {
        let argv: [String] = record.arguments.isEmpty
            ? Self.tokenize(record.commandLine)
            : [record.executable] + record.arguments

        self.commandLine = record.commandLine
        self.commandID = record.id
        self.arguments = record.arguments
        self.workingDirectory = record.workingDirectory

        var cursor = 0
        var wrapper: String?
        while cursor < argv.count {
            let name = RiskPathAnalyzer.fileName(of: argv[cursor]).lowercased()
            if Self.wrappers.contains(name) {
                wrapper = name
                cursor += 1
                cursor = Self.skippingValueOptions(in: argv, from: cursor)
                continue
            }
            if name == "env" || name == "time" || name == "nice" || name == "nohup" || name == "stdbuf" {
                cursor += 1
                while cursor < argv.count, argv[cursor].hasPrefix("-") || argv[cursor].contains("=") { cursor += 1 }
                continue
            }
            break
        }

        let head = cursor < argv.count ? argv[cursor] : (argv.first ?? record.executable)
        self.executablePath = head
        self.executable = RiskPathAnalyzer.fileName(of: argv.first ?? head).lowercased()
        self.privilegeWrapper = wrapper
        self.effectiveExecutable = RiskPathAnalyzer.fileName(of: head).lowercased()
        self.effectiveArguments = Array(argv.dropFirst(min(cursor + 1, argv.count)))

        var shorts: Set<Character> = []
        var longs: Set<String> = []
        var operands: [String] = []
        for argument in effectiveArguments {
            if argument.hasPrefix("--") {
                longs.insert(String(argument.dropFirst(2)).lowercased())
            } else if argument.hasPrefix("-") && argument.count > 1 {
                for character in argument.dropFirst() { shorts.insert(character) }
            } else {
                operands.append(argument.lowercased())
            }
        }
        self.shortFlags = shorts
        self.longFlags = longs
        self.operands = operands
        self.subcommand = operands.first

        let text = record.commandLine.lowercased()
        self.pipelines = Self.pipeSegments(in: text)
        self.pipesToInterpreter = Self.hasPipeToInterpreter(in: text)
        self.targetPaths = Self.extractPaths(from: Array(argv.dropFirst()), homeDirectory: homeDirectory)
        self.targetsHomeRoot = Self.detectsHomeRootTarget(operands: operands, homeDirectory: homeDirectory)
    }

    /// 是否带有指定短选项。
    public func hasShortFlag(_ flag: Character) -> Bool { shortFlags.contains(flag) }

    /// 是否带有指定长选项。
    public func hasLongFlag(_ flag: String) -> Bool { longFlags.contains(flag.lowercased()) }

    /// 任一参数以给定前缀开头（大小写不敏感）。
    public func hasOperandBeginning(with prefix: String) -> Bool {
        operands.contains { $0.hasPrefix(prefix.lowercased()) }
    }

    /// 是否包含给定的子命令序列（如 `["push"]`、`["reset", "--hard"]` 的首元素）。
    public func hasSubcommand(_ names: String...) -> Bool {
        names.contains { $0.lowercased() == subcommand }
    }

    /// 参数序列里是否出现某个 token（选项也算）。
    public func containsToken(_ token: String) -> Bool {
        ([effectiveExecutable] + effectiveArguments).contains { $0.lowercased() == token.lowercased() }
    }

    private static let wrappers: Set<String> = ["sudo", "doas", "pkexec", "su"]

    /// `sudo` 的取值为下一 token 的选项（`-u user`、`-g group`、`-C fd`、`-p prompt`、`-h host`）。
    private static let sudoValueOptions: Set<String> = ["-u", "-g", "-C", "-p", "-h", "-r", "-t"]

    /// 跳过一个选项 token 及其取值，返回新的游标。
    private static func skippingValueOptions(in argv: [String], from index: Int) -> Int {
        var cursor = index
        while cursor < argv.count, argv[cursor].hasPrefix("-") {
            let option = argv[cursor]
            cursor += 1
            if sudoValueOptions.contains(option), cursor < argv.count { cursor += 1 }
        }
        return cursor
    }

    static func tokenize(_ line: String) -> [String] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }.map(String.init)
    }

    static func pipeSegments(in text: String) -> [String] {
        text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func hasPipeToInterpreter(in text: String) -> Bool {
        let segments = pipeSegments(in: text)
        guard segments.count > 1 else { return false }
        let interpreters: Set<String> = ["sh", "bash", "zsh", "fish", "python", "python3", "ruby", "node", "perl"]
        return segments.dropFirst().contains { segment in
            guard let head = segment.split(separator: " ").first else { return false }
            return interpreters.contains(RiskPathAnalyzer.fileName(of: String(head)).lowercased())
        }
    }

    static func extractPaths(from tokens: [String], homeDirectory: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;,"))
            guard cleaned.count > 1 else { continue }
            guard cleaned.hasPrefix("/") || cleaned.hasPrefix("~") || cleaned.hasPrefix("./")
                || cleaned.hasPrefix("../") || cleaned.hasPrefix("$HOME") else { continue }
            let normalized = RiskPathAnalyzer.normalized(cleaned, homeDirectory: homeDirectory)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            out.append(normalized)
        }
        return out
    }

    static func detectsHomeRootTarget(operands: [String], homeDirectory: String) -> Bool {
        let home = RiskPathAnalyzer.normalized(homeDirectory, homeDirectory: homeDirectory)
        for operand in operands {
            let cleaned = operand.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;,"))
            guard !cleaned.isEmpty else { continue }
            let expanded = RiskPathAnalyzer.normalized(cleaned, homeDirectory: homeDirectory)
            if expanded == home { return true }
        }
        return false
    }
}

// MARK: - Command Classifier

/// 基于 `RiskCommandFacts` 的结构性行为谓词。所有方法均为纯函数。
public struct RiskCommandClassifier: Sendable {

    public init() {}

    // —— 提权 ——

    /// 是否通过提权包装器执行。
    public func isPrivilegeEscalated(_ facts: RiskCommandFacts) -> Bool {
        facts.privilegeWrapper != nil
    }

    // —— Git 不可逆 ——

    /// 会重写/丢弃历史或工作区的 git 命令。
    public func isGitHistoryRewrite(_ facts: RiskCommandFacts) -> Bool {
        guard facts.effectiveExecutable == "git" else { return false }
        switch facts.subcommand {
        case "push":
            return facts.hasLongFlag("force") || facts.hasShortFlag("f") || facts.hasLongFlag("force-with-lease")
        case "reset":
            return facts.hasLongFlag("hard") || facts.hasShortFlag("h")
        case "clean":
            return facts.hasShortFlag("f")
        case "rebase":
            return true
        case "checkout", "restore", "switch":
            return facts.hasLongFlag("force") || facts.operands.contains(".")
        case "stash":
            return facts.hasShortFlag("a") || facts.operands.contains("drop") || facts.operands.contains("clear")
        case "branch", "tag", "filter-branch":
            return facts.operands.contains("-d") || facts.operands.contains("-D")
                || facts.hasShortFlag("f") || facts.subcommand == "filter-branch"
        case "gc":
            return facts.hasLongFlag("prune")
        default:
            return false
        }
    }

    /// 会抹掉未提交工作区内容的 git 命令（`reset --hard`、`clean -fd`、`checkout .`）。
    public func isGitWorkingTreeDiscard(_ facts: RiskCommandFacts) -> Bool {
        guard facts.effectiveExecutable == "git" else { return false }
        switch facts.subcommand {
        case "reset": return facts.hasLongFlag("hard")
        case "clean": return facts.hasShortFlag("f")
        case "checkout", "restore": return facts.operands.contains(".") || facts.operands.contains("--")
        default: return false
        }
    }

    /// 删除远端引用/分支的 git 命令。
    public func isGitRemoteDestruction(_ facts: RiskCommandFacts) -> Bool {
        guard facts.effectiveExecutable == "git", facts.subcommand == "push" else { return false }
        return facts.containsToken("--delete") || facts.hasShortFlag("d")
            || facts.operands.contains { $0.hasPrefix(":") }
    }

    // —— 包源与工具链篡改 ——

    /// 修改包管理器源/全局配置（`npm config set registry`、`pip install --index-url`、`brew tap`）。
    public func isPackageSourceTamper(_ facts: RiskCommandFacts) -> Bool {
        switch facts.effectiveExecutable {
        case "npm", "pnpm", "yarn", "tnpm":
            return facts.operands.contains("registry") || facts.operands.contains("//registry")
                || (facts.subcommand == "config" && facts.containsToken("set"))
                || facts.subcommand == "publish"
                || facts.hasLongFlag("force")
        case "pip", "pip3", "uv":
            return facts.containsToken("--index-url") || facts.containsToken("-i")
                || facts.containsToken("--extra-index-url") || facts.containsToken("--trusted-host")
                || facts.operands.contains("--break-system-packages")
        case "brew":
            return facts.subcommand == "tap" || facts.subcommand == "unpack"
        case "cargo":
            return facts.subcommand == "login" || facts.subcommand == "publish"
        case "gem":
            return facts.subcommand == "push" || facts.containsToken("--source")
        default:
            return false
        }
    }

    /// 修改包管理器或 shell 的持久化配置。
    public func isToolchainConfigMutation(_ facts: RiskCommandFacts) -> Bool {
        (facts.subcommand == "config" || facts.subcommand == "setup")
            && (facts.containsToken("set") || facts.containsToken("--global") || facts.containsToken("--system"))
    }

    // —— 服务 / 内核 ——

    /// 装卸系统服务、加载内核扩展、修改启动项。
    public func isServiceOrKernelOperation(_ facts: RiskCommandFacts) -> Bool {
        switch facts.effectiveExecutable {
        case "launchctl":
            return ["load", "unload", "bootout", "bootstrap", "enable", "disable", "kill"].contains(facts.subcommand ?? "")
        case "systemctl", "service":
            return ["start", "stop", "restart", "disable", "enable", "mask"].contains(facts.subcommand ?? "")
        case "kextload", "kextunload", "kextutil", "sysctl", "nvram":
            return true
        case "softwareupdate":
            return facts.hasShortFlag("f") || facts.hasLongFlag("force")
        default:
            return false
        }
    }

    /// 修改防火墙、代理、安全策略、SIP、Gatekeeper、全盘访问权限。
    ///
    /// **只读探测不算变更**：`pfctl -s info`、`socketfilterfw --getglobalstate`、
    /// `csrutil status`、`spctl --assess`、`iptables -L`、`defaults read …` 都只读取状态，
    /// 若一并判为 CRITICAL 会让审计面板满是假阳性。
    public func isSecuritySettingMutation(_ facts: RiskCommandFacts) -> Bool {
        guard !Self.isReadOnlySecurityProbe(facts) else { return false }
        switch facts.effectiveExecutable {
        case "pfctl", "iptables", "socketfilterfw", "ufw":
            return true
        case "csrutil":
            return ["enable", "disable"].contains(facts.subcommand ?? "")
        case "spctl":
            return ["disable", "enable"].contains(facts.subcommand ?? "")
                || facts.hasLongFlag("block") || facts.hasLongFlag("unblock")
        case "tccutil":
            return ["reset", "set-approved"].contains(facts.subcommand ?? "")
        case "networksetup":
            return Self.hasMutatingSecurityVerb(facts)
        case "security":
            return ["unlock-keychain", "delete-keychain", "set-keychain-settings"].contains(facts.subcommand ?? "")
                || (facts.subcommand == "authorizationdb" && ["write", "create", "destroy"].contains(facts.operands.dropFirst().first ?? ""))
        case "defaults":
            return ["write", "delete"].contains(facts.subcommand ?? "")
                && facts.operands.contains { $0.contains("firewall") || $0.contains("gatekeeper")
                    || $0.contains("assessments") || $0.contains("contentfilter") }
        default:
            return false
        }
    }

    /// 是否为只读安全状态探测（查询防火墙状态、列出规则、评估签名、读偏好）。
    ///
    /// macOS 的网络工具习惯用**单破折号长选项**（`-getfirewallstate` / `-setfirewallstate`），
    /// 所以这里按 token 的字母尾巴前缀判断，而不是按短选项集合判断——
    /// 否则 `-setfirewallstate` 会因为含字母 `s` 被误判成"只读"。
    static func isReadOnlySecurityProbe(_ facts: RiskCommandFacts) -> Bool {
        for argument in facts.effectiveArguments {
            let token = argument.lowercased()
            guard token.hasPrefix("-") else { continue }
            let isLongStyle = token.hasPrefix("--")
            let tail = String(token.drop(while: { $0 == "-" }))
            if tail.hasPrefix("get") || tail.hasPrefix("list") || tail.hasPrefix("show")
                || tail.hasPrefix("print") || tail.hasPrefix("assess") || tail.hasPrefix("stat") { return true }
            if isLongStyle || tail.count > 3 { continue }
            // 真正的短选项簇：`pfctl -s`（查状态）、`iptables -L`（列规则）、`-n`（dry-run）。
            // token 已小写化，所以这里比较 `"l"` 而不是 `"L"`。
            if tail.contains("s") || tail.contains("l") || tail.contains("n") { return true }
        }
        return facts.operands.contains { operand in
            operand.hasPrefix("get") || operand.hasPrefix("list") || operand.hasPrefix("show")
                || operand == "status" || operand == "info" || operand == "print" || operand == "read"
        }
    }

    /// 参数里是否出现明确的写动词（`-setfirewallstate`、`delete-keychain`、`add rule`…）。
    static func hasMutatingSecurityVerb(_ facts: RiskCommandFacts) -> Bool {
        let tokens = facts.effectiveArguments + facts.operands
        return tokens.contains { token in
            let tail = token.lowercased().drop(while: { $0 == "-" })
            return tail.hasPrefix("set") || tail.hasPrefix("add") || tail.hasPrefix("remove")
                || tail.hasPrefix("create") || tail.hasPrefix("delete") || tail.hasPrefix("flush")
                || tail.hasPrefix("enable") || tail.hasPrefix("disable")
        }
    }

    /// 从网络取脚本并管道执行。
    public func isPipeToInterpreter(_ facts: RiskCommandFacts) -> Bool {
        facts.pipesToInterpreter
    }

    /// 文件权限/属主变更。
    public func isPermissionMutation(_ facts: RiskCommandFacts) -> Bool {
        ["chmod", "chown", "chgrp"].contains(facts.effectiveExecutable)
    }

    /// 权限变更是否递归。
    public func isRecursivePermissionMutation(_ facts: RiskCommandFacts) -> Bool {
        isPermissionMutation(facts) && (facts.hasShortFlag("R") || facts.hasShortFlag("r") || facts.hasLongFlag("recursive"))
    }

    /// 会清空或抹掉存储的命令（`diskutil erase`、`mkfs`、`dd of=/dev/`）。
    public func isVolumeErasure(_ facts: RiskCommandFacts) -> Bool {
        switch facts.effectiveExecutable {
        case "diskutil":
            return ["erase", "erasedisk", "zerodisk", "partitiondisk", "reformattdisk"].contains(facts.subcommand ?? "")
        case "mkfs", "newfs":
            return true
        case "dd":
            return facts.operands.contains { $0.hasPrefix("of=/dev/") }
        default:
            return false
        }
    }

    /// 看起来不可恢复的命令（结构性判断，作为 Telemetry 文本规则缺失时的兜底）。
    public func looksIrreversible(_ facts: RiskCommandFacts) -> Bool {
        if facts.effectiveExecutable == "rm" { return true }
        if isGitHistoryRewrite(facts) { return true }
        if isVolumeErasure(facts) { return true }
        if isServiceOrKernelOperation(facts) { return true }
        if facts.effectiveExecutable == "find", facts.containsToken("-delete") { return true }
        if facts.effectiveExecutable == "history", facts.containsToken("-c") { return true }
        return false
    }

    /// 会写入/删除 `targetPaths` 之外位置的命令（重定向与 `tee`/`dd`）。
    public func writeTargets(_ facts: RiskCommandFacts) -> [String] {
        let writers: Set<String> = ["tee", "dd", "cp", "mv", "rsync", "tar", "unzip", "install", "touch", "truncate"]
        if writers.contains(facts.effectiveExecutable) { return facts.targetPaths }
        if facts.effectiveExecutable == "rm" || facts.effectiveExecutable == "rmdir" { return facts.targetPaths }
        return facts.targetPaths.filter { path in
            !path.hasPrefix("-")
        }
    }
}
