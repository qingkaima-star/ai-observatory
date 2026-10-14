//
//  AgentSignatureDatabase.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Agent
//  ─────────────────────────────────────────────────────────
//  Agent 特征库：各 AI Agent（Claude Code / Codex / Cursor / Windsurf /
//  VS Code Copilot / Gemini CLI / Aider 等）的可识别特征。
//
//  这些特征均为「静态已知事实」，不是运行时测量值，因此不构成伪造数据。
//  单条特征不足以定性的情况由各 DetectionStrategy 综合判定（含置信度）。
//

import Foundation
import AIObservatoryCore

/// 某个 Agent 种类的一组识别特征。
public struct AgentSignature: Sendable, Hashable {
    /// 对应的 Agent 种类。
    public let kind: AgentKind
    /// 可执行路径签名。匹配按**路径分量**，不是裸子串；锚定语义见 `DetectionHygiene.matches`：
    ///  · `"/claude"`（结尾无斜杠）= 可执行文件名必须是 `claude`（`~/.claude/bin/claude`、
    ///    `/usr/local/bin/claude` 命中；`~/projects/claude/notes.md` 不命中）；
    ///  · `"/claude-code/"`（结尾带斜杠）= 路径经过该目录即可（`@anthropic-ai/claude-code` 的 npm 布局）；
    ///  · `"Cursor.app/Contents/MacOS/Cursor"` = bundle 内的既定布局，整段连续命中。
    /// 反面教训：`"/codex"` 若按裸子串匹配，会把 ChatGPT.app 里
    /// `Codex Framework.framework/…/browser_crashpad_handler` 这类辅助进程也算成 Agent。
    public let pathFragments: [String]
    /// Bundle Identifier（仅 macOS GUI 应用）。按反向域名**分段**匹配：
    /// `com.windsurf` 命中 `com.windsurf.ai`，不命中 `com.example.windsurf`。
    public let bundleIdentifiers: [String]
    /// `.app` 包名（用于从路径识别 GUI 应用）。必须是完整的一个路径分量。
    public let appBundleNames: [String]
    /// 进程名（comm，≤16 字符）精确匹配。
    public let processNames: [String]
    /// 进程名前缀匹配（用于 `Cursor Helper` 等被截断的辅助进程）。
    public let processNamePrefixes: [String]
    /// 命令行特征字符串。匹配按 **argv token 边界**（token 整体相等，或以签名开头且
    /// 后接 `.` / `_` / `[`）：`"cursor"` 认 token `cursor`，不认 `CursorUIViewService`。
    /// 只放**该 Agent 专属**的字符串——通用开关（`--verbose` 之类）一律不得入表，
    /// 否则每个带该开关的普通进程都会被判成 Agent。
    public let argumentSignatures: [String]

    public init(
        kind: AgentKind,
        pathFragments: [String] = [],
        bundleIdentifiers: [String] = [],
        appBundleNames: [String] = [],
        processNames: [String] = [],
        processNamePrefixes: [String] = [],
        argumentSignatures: [String] = []
    ) {
        self.kind = kind
        self.pathFragments = pathFragments
        self.bundleIdentifiers = bundleIdentifiers
        self.appBundleNames = appBundleNames
        self.processNames = processNames
        self.processNamePrefixes = processNamePrefixes
        self.argumentSignatures = argumentSignatures
    }
}

/// 各 Agent 的特征库。集中管理，便于策略层与测试复用。
public struct AgentSignatureDatabase: Sendable {

    /// 单例（值类型，线程安全）。
    public static let shared = AgentSignatureDatabase()

    /// 全部已知签名（覆盖契约要求的 ≥ 6 种 Agent 类型）。
    public let entries: [AgentSignature]

    public init() {
        // WS-Detect 逐条复核（2026-09-20）：这些条目过去被 `containsCI(整条路径 / 拼起来的 argv, 签名)`
        // 使用，等于「签名出现在任何位置的任意子串都算命中」。现在统一按分量 / token 边界命中，
        // 因此表内只允许留「该 Agent 专属」的特征串——通用词在这里就是误报源。
        self.entries = [
            AgentSignature(
                kind: .claudeCode,
                // "/claude"：路径末尾的 claude（`/usr/local/bin/claude`、真机夹具）命中；
                // "@anthropic-ai/claude-code"：npm 全局安装的目录布局（多段签名可在路径中段命中）。
                pathFragments: ["/claude-code/", "@anthropic-ai/claude-code", "/.claude/bin", "/claude"],
                processNames: ["claude", "claude-code"],
                // 删掉 "--verbose"：它是几十个 CLI 共用的开关，任何带它的进程都会被判成
                // Claude Code（0.72）。签名必须是该 Agent 专属串。
                argumentSignatures: [
                    "claude-code", "@anthropic-ai/claude-code", "claude",
                    "--dangerously-skip-permissions", "claude-internal"
                ]
            ),
            AgentSignature(
                kind: .openAICodex,
                // "/codex" 现在是「可执行文件名就是 codex」：命中 `/Applications/ChatGPT.app/Contents/Resources/codex`
                // 与 `~/.codex/bin/codex`；不再命中 `…/Codex Framework.framework/…/browser_crashpad_handler`、
                // `…/Codex (Renderer).app/…`、`/Applications/Codex Account Switcher.app/…`
                // ——那批裸子串命中就是真机 22 倍虚高的全部来源。
                pathFragments: ["/codex", "openai-codex", "@openai/codex"],
                processNames: ["codex"],
                argumentSignatures: ["codex", "openai-codex", "@openai/codex"]
            ),
            AgentSignature(
                kind: .cursorAgent,
                pathFragments: ["Cursor.app/Contents/MacOS/Cursor"],
                bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
                appBundleNames: ["Cursor.app"],
                processNames: ["cursor"],
                processNamePrefixes: ["Cursor Helper"],
                // "cursor" 曾以裸子串命中 macOS 输入候选窗服务 CursorUIViewService（判成 Cursor Agent）。
                // 现在它必须是完整 token：`cursor`、`cursor.app` 命中，`CursorUIViewService` 不命中。
                argumentSignatures: ["cursor-agent", "cursor", "com.todesktop"]
            ),
            AgentSignature(
                kind: .windsurf,
                pathFragments: ["Windsurf.app/Contents/MacOS/Windsurf"],
                bundleIdentifiers: ["com.windsurf", "com.exafunction.windsurf"],
                appBundleNames: ["Windsurf.app"],
                processNames: ["windsurf"],
                processNamePrefixes: ["Windsurf Helper"],
                argumentSignatures: ["windsurf"]
            ),
            AgentSignature(
                kind: .vscodeCopilot,
                // "Visual Studio Code.app" 是 bundle 名（容器），可在路径中段命中；
                // "Code.app/Contents/MacOS/Code" 是完整布局签名。曾经的裸子串 "Code.app"
                // 命中过 "Xcode.app"，把每个 Xcode 编译进程判成 Copilot。
                pathFragments: ["Visual Studio Code.app", "Code.app/Contents/MacOS/Code", "/VSCode"],
                bundleIdentifiers: ["com.microsoft.VSCode"],
                appBundleNames: ["Visual Studio Code.app", "Code.app"],
                // 删掉 "electron"：Electron 开发态构建的进程名就叫 electron，与 VS Code 无必然关系，
                // 且一次运行会拉起多个同名进程（不在任何 .app 内 → 归并不了，只能各成一行）。
                // 真实 VS Code 由 pathFragments / bundleIdentifiers 识别，不靠这个通用名。
                processNames: ["code"],
                processNamePrefixes: ["Code Helper"],
                argumentSignatures: ["github.copilot", "copilot", "vscode"]
            ),
            AgentSignature(
                kind: .geminiCLI,
                pathFragments: ["gemini-cli", "@google/gemini", "/gemini"],
                processNames: ["gemini"],
                argumentSignatures: ["gemini-cli", "@google/gemini", "gemini"]
            ),
            AgentSignature(
                kind: .aiderCLI,
                pathFragments: ["/aider", "aider-chat"],
                processNames: ["aider"],
                argumentSignatures: ["aider", "aider-chat"]
            ),
            AgentSignature(
                kind: .genericCLIAgent,
                argumentSignatures: ["--agent-mode", "AGENTIC=1", "ai-agent"]
            )
        ]
    }

    /// 按种类取签名。
    public func signature(for kind: AgentKind) -> AgentSignature? {
        entries.first { $0.kind == kind }
    }
}
