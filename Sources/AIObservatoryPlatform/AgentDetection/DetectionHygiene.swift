//
//  DetectionHygiene.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Detect / WS-Platform
//  ─────────────────────────────────────────────────────────
//  检出层「卫生规则」——所有策略共用的三条判定基座：
//
//    1. 系统进程闸门：macOS 自带位置（/System、/usr/libexec、/usr/sbin、`*.xpc`）
//       下的可执行文件永不参与 Agent 匹配。
//    2. 按边界匹配：签名只在「路径分量 / argv token 边界」上命中，不做裸子串。
//    3. 身份归组：一个 `.app` bundle 的 helper / XPC / crashpad 记成一个 Agent。
//
//  为什么必须有这三条（真机实测，见 AiX-Vault/01-架构/真机验证-命令审计与检出.md）：
//   · `argumentSignatures: ["cursor"]` 以裸子串命中
//     `/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/…/CursorUIViewService.xpc`，
//     于是 macOS 的文本输入候选窗服务被记成一个 Cursor Agent。
//   · `pathFragments: ["/codex"]` 以裸子串命中 ChatGPT.app 内部一切含 "Codex" 的路径
//     （`Codex (Service).app`、`Codex (Renderer).app`、`Codex Framework.framework/…/browser_crashpad_handler`），
//     一个 Codex 桌面会话被拆成 22 行 —— Session 列表与导出报告按 22 倍虚高。
//   · 同一类错误此前已发生过一次：`"Code.app"` ⊂ `"Xcode.app"`，把每个 Xcode 编译进程
//     判成 Copilot（实测 30 秒多出 25 个假 Agent）。
//
//  性能口径（WS-Platform 2026-09-20，release 实测）：这三条基座跑在
//  「每条进程记录 × 每条策略」上，一个 tick 的 1082 条记录里光「卫生匹配」占 10 ms。
//  于是做了三件事，**判定结果逐字不变**：
//   · 切分与大小写折叠换成 UTF-8 字节扫描——`components(separatedBy: CharacterSet)`
//     每个字符都要问一次 `CFCharacterSetIsLongCharacterMember`，它是当时的 TOP 叶帧；
//   · 常量签名（表里那 8 条 `AgentSignature`、终端 `.app` 名）编译成 `CompiledSignature`
//     一次，之后整进程复用，见 `AgentSignaturePlan`；
//   · 匹配起点不再物化成 `[Int]`（旧写法每次调用分配一个候选下标数组）。
//
//  非 ASCII 输入一律退回旧口径（`lowercased()` + `CharacterSet`），字节快路径只在
//  `String.isASCII` 时启用——`lowercased()` 的 Unicode 折叠行为因此原样保住。
//

import Foundation
import AIObservatoryCore

/// 检出层卫生规则。全部为纯函数，无副作用，便于逐条单测。
enum DetectionHygiene {

    // MARK: - 0. 切分口径与字节扫描基座

    /// 一套「切分口径」：字节形态给 ASCII 快路径用，`CharacterSet` 形态是非 ASCII 的退路。
    ///
    /// 两者由同一组字节派生，快慢两条路径的边界定义不可能漂移。
    struct ComponentSplitter: Sendable {
        /// ASCII 分隔符字节集（UTF-8 里 `< 0x80` 的字节只可能是单个 ASCII 标量）。
        let bytes: [UInt8]
        /// 由 `bytes` 派生的 `CharacterSet`：仅在非 ASCII 输入退回旧口径时使用。
        let characterSet: CharacterSet

        init(bytes: [UInt8]) {
            self.bytes = bytes
            self.characterSet = CharacterSet(charactersIn: String(decoding: bytes, as: UTF8.self))
        }
    }

    /// 路径 / argv 分量的切分符：只有真正的分隔语义才算边界。
    ///
    /// 刻意不含空格与 `-`：`Visual Studio Code.app` 与 `codex-switcher-cc-core`
    /// 都是一个完整分量，把它们切碎会让「分量」失去意义。
    static let pathSplitter = ComponentSplitter(bytes: [0x2F, 0x3D, 0x3A])                 // "/=:"
    /// 同上，但**只认 `/`**：`isPureHelperProcess` 与 `enclosingAppBundle` 的旧口径
    /// 用的是 `components(separatedBy: "/")`，切分符集合与 `pathSplitter` 不同，
    /// 这里必须各留一套，否则带 `=` / `:` 的分量会被切碎、判定随之改变。
    static let forwardSlashSplitter = ComponentSplitter(bytes: [0x2F])                  // "/"

    /// Bundle Identifier 的切分符是点号（反向域名各段）。
    static let bundleIDSplitter = ComponentSplitter(bytes: [0x2E])                         // "."
    /// 进程名（comm）的 token 边界：空格与 `. _ - ( ) [ ]`。
    static let nameTokenSplitter = ComponentSplitter(bytes: [0x20, 0x2E, 0x5F, 0x2D, 0x28, 0x29, 0x5B, 0x5D])

    /// 被视为「容器」的分量后缀——它们标识一个 bundle/框架目录，天然出现在路径中间。
    private static let containerSuffixes: [String] = [".app", ".framework", ".xpc", ".bundle"]

    /// 签名分量的「右边界」字符：签名以这些字符收尾的更长分量仍算同一 token。
    ///
    /// 例如签名 `"codex"` 可以命中分量 `"codex.app"` / `"codex_code"`，
    /// 但**不能**命中 `"codex-switcher-cc-core"`（连字符是产品名的一部分，是另一个可执行文件）
    /// 或 `"CursorUIViewService"`（大小写折叠后 "cursor" 只是它的前缀，属于裸子串误报）。
    /// 三个字符都是 ASCII，故用字节形态 `.` `_` `[`。
    private static let rightBoundaryDelimiterBytes: [UInt8] = [0x2E, 0x5F, 0x5B]

    /// 把一个「来源值」按 `splitter` 切成**小写**分量，空段丢弃。
    ///
    /// 纯 ASCII（真机进程路径与 argv 的常态）一趟字节扫描，只在真正的分量上分配；
    /// 含非 ASCII 时退回旧口径：`value.lowercased().components(separatedBy:…)`。
    static func scanComponents(of value: String, by splitter: ComponentSplitter) -> [String] {
        guard !value.isEmpty else { return [] }
        // `String` 没有 `isASCII`（只有 `Unicode.Scalar` 有），按 UTF-8 字节判：
        // 首个非 ASCII 字节就短路，比整串遍历便宜，且与下面的快路径同一份编码。
        guard value.utf8.allSatisfy({ $0 < 0x80 }) else {
            return value.lowercased()
                .components(separatedBy: splitter.characterSet)
                .filter { !$0.isEmpty }
        }

        var result: [String] = []
        let bytes = value.utf8
        var runStart = bytes.startIndex
        var index = runStart
        while index < bytes.endIndex {
            if splitter.bytes.contains(bytes[index]) {
                if index != runStart { result.append(lowercasedString(of: value, in: bytes, from: runStart, to: index)) }
                index = bytes.index(after: index)
                runStart = index
            } else {
                index = bytes.index(after: index)
            }
        }
        if index != runStart { result.append(lowercasedString(of: value, in: bytes, from: runStart, to: index)) }
        return result
    }

    /// `[from, to)` 这段**纯 ASCII** 的 UTF-8 → 小写 `String`（一次分配；短分量落在内联存储里）。
    ///
    /// 快路径：这段字节里没有 `A-Z` 时，小写形式就是它本身——直接切原串的子串，
    /// 省掉「拷进 `[UInt8]` 再 decode 回来」那次中间分配。真机路径分量的绝大多数（`usr`、
    /// `local`、`bin`、`node_modules`…）本就全小写，这条分支是主路径。
    /// 含大写时才退回逐字节折叠（`String(substring)` 与 `String(decoding:)` 对纯 ASCII 同值，
    /// 故两条路径产出的分量字符串逐字相等）。
    private static func lowercasedString(
        of value: String,
        in bytes: String.UTF8View,
        from: String.Index,
        to: String.Index
    ) -> String {
        var probe = from
        var hasUpper = false
        while probe < to {
            let byte = bytes[probe]
            if byte >= 0x41 && byte <= 0x5A { hasUpper = true; break }
            probe = bytes.index(after: probe)
        }
        if !hasUpper { return String(value[from..<to]) }

        var result: [UInt8] = []
        result.reserveCapacity(bytes.distance(from: from, to: to))
        var index = from
        while index < to {
            result.append(lowerByte(bytes[index]))
            index = bytes.index(after: index)
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// ASCII 大小写折叠（只处理 `A-Z`；`>= 0x80` 的多字节序列首字节不受影响）。
    private static func lowerByte(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    /// `bytes[from...]` 是否以 `prefix`（全小写 ASCII 字节）开头；是则把 `from` 推到前缀之后。
    private static func consumeASCIIPrefix(
        _ prefix: [UInt8],
        in bytes: String.UTF8View,
        from index: inout String.Index
    ) -> Bool {
        var probe = index
        for expected in prefix {
            guard probe < bytes.endIndex else { return false }
            guard lowerByte(bytes[probe]) == expected else { return false }
            probe = bytes.index(after: probe)
        }
        index = probe
        return true
    }

    /// `[runStart, runEnd)` 这段字节是否以 `suffix`（全小写 ASCII 字节）收尾，大小写不敏感。
    ///
    /// needle 全为 ASCII，而 UTF-8 的多字节序列里每个字节都 `>= 0x80`，
    /// 所以「按字节找后缀」不会在半个标量上误命中。
    private static func hasASCIISuffix(
        _ suffix: [UInt8],
        in bytes: String.UTF8View,
        runStart: String.Index,
        runEnd: String.Index
    ) -> Bool {
        let length = bytes.distance(from: runStart, to: runEnd)
        guard length >= suffix.count else { return false }
        var probe = bytes.index(runStart, offsetBy: length - suffix.count)
        for expected in suffix {
            guard lowerByte(bytes[probe]) == expected else { return false }
            probe = bytes.index(after: probe)
        }
        return true
    }

    // MARK: - 1. 系统进程闸门

    /// 系统组件路径前缀：这些位置下的一切都是 macOS 自带进程，不可能是第三方 Agent。
    ///
    /// 只列「Apple 系统组件必然所在」的位置。`/usr/bin`、`/bin` 不在其内——
    /// 用户安装的 CLI 常落在这里（`/usr/local/bin/claude`、`/opt/homebrew/bin/…`），
    /// 排除它们会漏检真 Agent。
    private static let systemPathPrefixes: [String] = [
        "/system/", "/usr/libexec/", "/usr/sbin/", "/usr/lib/"
    ]

    /// 同上，字节形态（大小写不敏感比较时的全小写基准；表里写的本来就是小写）。
    private static let systemPathPrefixBytes: [[UInt8]] = DetectionHygiene.systemPathPrefixes.map { Array($0.utf8) }

    /// firmlink 前缀：`/System/Volumes/Data/...` 其实是用户数据卷，不是系统区。
    ///
    /// 小写形态，比较时对候选做 ASCII 折叠（见 `isSystemProcessPath` 的等价性说明）。
    private static let dataVolumePrefixBytes = Array("/system/volumes/data".utf8)

    /// `*.xpc` bundle 名后缀（字节形态）。
    private static let xpcSuffixBytes: [UInt8] = [0x2E, 0x78, 0x70, 0x63]

    /// 该可执行路径是否属于「一律不参与 Agent 匹配」的系统位置。
    ///
    /// 判定形状与旧实现逐字一致，只是不再 `lowercased()` 整条路径、也不再
    /// `components(separatedBy: "/")` 造一个数组：前缀比对与 `.xpc` 分量查找都在
    /// UTF-8 字节上原地做（ASCII 大小写不敏感）。
    ///
    /// 这些 needle 全是 ASCII，而「非 ASCII 标量小写后落到 ASCII」的已知唯一情形是
    /// U+212A KELVIN SIGN → `k`，它不出现在上面任何 needle 里，所以按字节比与
    /// 先整串 `lowercased()` 再比等价。
    ///
    /// - Parameter path: `proc_pidpath` 得到的可执行路径（空串返回 false，交由各策略的取不到路径规则处理）。
    /// - Returns: true 表示排除（调用方必须返回 nil，不得给出任何置信度）。
    static func isSystemProcessPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let bytes = path.utf8

        // firmlink 还原后再判：/System/Volumes/Data/Users/x/.local/bin/codex 是真 Agent。
        var cursor = bytes.startIndex
        if consumeASCIIPrefix(dataVolumePrefixBytes, in: bytes, from: &cursor) {
            // 旧口径：整串恰好等于前缀，或前缀后紧跟 "/" 才算 firmlink 命中。
            if cursor == bytes.endIndex { return true }
            if bytes[cursor] == 0x2F {
                // 剩下的部分只剩一个 "/" → 仍是系统区根。
                if bytes.index(after: cursor) == bytes.endIndex { return true }
                // 否则按用户数据卷路径处理：候选串就是「前缀之后的剩余」，cursor 已停在 "/"。
            } else {
                cursor = bytes.startIndex   // 例如 /System/Volumes/Databoot：不是 firmlink，整串照旧
            }
        }

        for prefix in systemPathPrefixBytes {
            var probe = cursor
            if consumeASCIIPrefix(prefix, in: bytes, from: &probe) { return true }
        }

        // 任何 `.xpc` bundle 内部：XPC 服务由宿主进程负责身份，自身不成 Agent。
        return hasXPCComponent(in: bytes, from: cursor)
    }

    /// 从 `from` 起是否存在「以 `.xpc` 收尾的 `/` 分量」（空分量自然不算）。
    private static func hasXPCComponent(in bytes: String.UTF8View, from: String.Index) -> Bool {
        var runStart = from
        var index = from
        while true {
            let atEnd = index == bytes.endIndex
            if atEnd || bytes[index] == 0x2F {   // '/'
                if hasASCIISuffix(xpcSuffixBytes, in: bytes, runStart: runStart, runEnd: index) { return true }
                if atEnd { return false }
                runStart = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
    }

    // MARK: - 2. 按边界匹配

    /// 一个「来源值」= 一条可执行路径或一个 argv token；各自的成分量序列。
    ///
    /// 逐值切分而不是拼成一条扁平序列，是为了让「末尾」有意义：
    /// `python /Users/x/cursor/main.py` 里的 `cursor` 是个中间目录，
    /// 不是任何值的最后一个分量，因此单分量签名 `"cursor"` 不会命中它。
    static func componentValues(of rawValues: [String]) -> [[String]] {
        rawValues.map { scanComponents(of: $0, by: pathSplitter) }
    }

    /// 单个来源值的成分量序列。
    static func componentValues(of rawValue: String) -> [[String]] {
        [scanComponents(of: rawValue, by: pathSplitter)]
    }

    /// Bundle Identifier 的分量序列（整体作为一个值）。
    static func bundleIdentifierComponents(of value: String) -> [[String]] {
        [scanComponents(of: value, by: bundleIDSplitter)]
    }

    /// 进程名（comm）的 token 切分结果（已小写）。
    ///
    /// comm 可含空格（`Code Helper`）与下划线（`browser_crashpad_handler`），
    /// 这些位置就是它的 token 边界；签名因此仍按整段命中，不会退化成裸子串。
    static func nameTokens(of value: String) -> [String] {
        scanComponents(of: value, by: nameTokenSplitter)
    }

    /// 签名的形态：决定它必须落在值的哪个位置。
    private enum SignatureShape {
        /// 单个分量、且不像容器名 → 它是**文件 / 命令名**，必须是某个值的最后一个分量。
        case executableName
        /// 多分量（结构性布局）、以 `/` 结尾（目录）或末段是 bundle 名 → 连续出现在值的任意位置。
        case container
    }

    private static func shape(of parts: [String], spelledWithTrailingSlash: Bool) -> SignatureShape {
        if spelledWithTrailingSlash { return .container }
        if parts.count > 1 { return .container }
        guard let last = parts.last else { return .container }
        return containerSuffixes.contains(where: { last.hasSuffix($0) }) ? .container : .executableName
    }

    /// 一条签名**编译后**的形态：已小写、已切段、已定锚位。
    ///
    /// 签名是静态表里的常量串（`AgentSignatureDatabase` 的 8 条 `AgentSignature`、
    /// 终端 `.app` 名列表……），旧实现每次匹配都重新 `lowercased()` + 切段 + 判形态，
    /// 于是「每条记录 × 每条签名」各付一次同样的活。编译成值类型后整进程算一次即可，
    /// 见 `AgentSignaturePlan`。
    struct CompiledSignature: Sendable, Hashable {
        /// 切好并小写后的签名段；空数组表示「永不命中」（空签名 / 只由分隔符组成的签名）。
        let parts: [String]
        /// 是否为 `executableName` 形态：必须命中某个值的**最后一个**分量。
        let anchoredToLastComponent: Bool

        /// 永不命中的签名。
        static let neverMatches = CompiledSignature(parts: [], anchoredToLastComponent: false)
    }

    /// 编译一条「路径 / argv / bundle 包名」签名——与 `matches(_:in:)` 的口径同源。
    static func compileSignature(_ signature: String) -> CompiledSignature {
        let parts = scanComponents(of: signature, by: pathSplitter)
        guard !parts.isEmpty else { return .neverMatches }
        // '/' 在小写映射下不变，故 `hasSuffix("/")` 与旧写法 `raw.hasSuffix("/")` 同值。
        let suffixOnly = shape(of: parts, spelledWithTrailingSlash: signature.hasSuffix("/")) == .executableName
        return CompiledSignature(parts: parts, anchoredToLastComponent: suffixOnly)
    }

    /// 编译一条 Bundle Identifier 签名（点号分段，锚位固定在任意连续位置）。
    static func compileBundleIdentifierSignature(_ signature: String) -> CompiledSignature {
        let parts = scanComponents(of: signature, by: bundleIDSplitter)
        guard !parts.isEmpty else { return .neverMatches }
        return CompiledSignature(parts: parts, anchoredToLastComponent: false)
    }

    // MARK: - 快速否证：签名词干集

    /// 一组签名各自的**首段**（小写 ASCII 字节）去重后的集合，用于热路径的「一条都不沾」早退。
    ///
    /// 为什么首段是安全的必要条件：`matches(parts, in: components)` 里
    ///  · 单段签名（`parts.count == 1`，即 `executableName` 或唯一的末段）用 `tokenHasPrefix`
    ///   ——命中分量要么整段等于该段，要么以它开头，两种都 ⟹ 该段是原始值的一个**子串**；
    ///  · 多段签名的首段是「中间段」，用整段相等 `haystackPart == part` ⟹ 同样是子串。
    /// 所以「某签名命中」⟹「命中它的原始值含有它的首段」。于是**所有**原始值都不含**任何**词干
    /// ⇒ 七条匹配分支必然全部落空，可整段跳过「切分 + 匹配」。它只需是必要条件，不必充分，
    /// 因此只会「放行不该跳的」，绝不「跳掉该匹配的」——检出面逐字不变。
    ///
    /// 保守边界：含非 ASCII 字节的原始值一律判「可能命中」，退回完整判定
    /// （Unicode 小写折叠的口径与按字节折叠不同，不在这里复刻）。
    struct SignatureStems: Sendable {
        private let needles: [[UInt8]]

        init(_ signatures: [CompiledSignature]) {
            var seen = Set<[UInt8]>()
            var out: [[UInt8]] = []
            for sig in signatures {
                guard let first = sig.parts.first else { continue }  // neverMatches 无段
                let bytes = Array(first.utf8)
                guard !bytes.isEmpty, bytes.allSatisfy({ $0 < 0x80 }) else { continue }
                if seen.insert(bytes).inserted { out.append(bytes) }
            }
            needles = out
        }

        /// 空集（本策略没有任何可匹配签名）⇒ 恒 false，调用方可直接判无命中。
        var isEmpty: Bool { needles.isEmpty }

        /// 任一原始值是否**可能**含有词干（ASCII 大小写不敏感子串）。非 ASCII 值一律 true。
        func couldMatch(in rawValues: [String]) -> Bool {
            if needles.isEmpty { return false }
            for value in rawValues {
                let bytes = value.utf8
                // 首个非 ASCII 字节即短路：真机路径与 argv 几乎都是纯 ASCII。
                if !bytes.allSatisfy({ $0 < 0x80 }) { return true }
                for needle in needles where SignatureStems.contains(needle, in: bytes) { return true }
            }
            return false
        }

        /// 朴素滑动窗口：needle 短（≤ ~24 字节），且绝大多数起点在 `needle[0]` 一次比较就出局，
        /// 故每 needle 实际 O(len)，对未命中记录是一次线性扫。`String.UTF8View` 下标 O(1)。
        private static func contains(_ needle: [UInt8], in bytes: String.UTF8View) -> Bool {
            guard !needle.isEmpty, bytes.count >= needle.count else { return false }
            let first = needle[0]
            var i = bytes.startIndex
            while i < bytes.endIndex {
                if lowerByte(bytes[i]) == first {
                    var probe = bytes.index(after: i)
                    var j = 1
                    while j < needle.count, probe < bytes.endIndex, lowerByte(bytes[probe]) == needle[j] {
                        probe = bytes.index(after: probe)
                        j += 1
                    }
                    if j == needle.count { return true }
                }
                i = bytes.index(after: i)
            }
            return false
        }

        private static func lowerByte(_ byte: UInt8) -> UInt8 {
            byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
        }
    }

    /// 签名是否以「整段边界」命中某个值的分量序列。
    ///
    /// 规则：
    ///  · 签名按同一分隔符切段（支持 `"@anthropic-ai/claude-code"`、
    ///    `"Cursor.app/Contents/MacOS/Cursor"` 这类多段签名），要求这些段**连续**出现；
    ///  · 每段都从分量边界开始（前一字符必为分隔符或串首）——这一条就排除了
    ///    `"Code.app"` ⊂ `"Xcode.app"`；
    ///  · 末段允许右边界分隔符（见 `rightBoundaryDelimiterBytes`），中间段要求整段相等；
    ///  · 形态为 `executableName` 的签名必须命中该值的**最后一个**分量——
    ///    `"/codex"` 因此只认 `…/Resources/codex`，不认 `…/codex/browser_crashpad_handler`，
    ///    也不认 `~/projects/codex/notes.md`。
    ///
    /// - Parameters:
    ///   - signature: 签名条目（`pathFragments` / `argumentSignatures` / `appBundleNames` / `bundleIdentifiers` 之一）。
    ///   - values: 由 `componentValues(of:)` / `bundleIdentifierComponents(of:)` 得到的分量序列组。
    static func matches(_ signature: String, in values: [[String]]) -> Bool {
        matches(compileSignature(signature), in: values)
    }

    /// 预编译签名版：热路径走这一条，匹配本身不再碰字符串处理。
    static func matches(_ signature: CompiledSignature, in values: [[String]]) -> Bool {
        guard !signature.parts.isEmpty else { return false }
        return values.contains {
            matches(signature.parts, in: $0, suffixOnly: signature.anchoredToLastComponent)
        }
    }

    private static func matches(_ parts: [String], in components: [String], suffixOnly: Bool) -> Bool {
        guard !parts.isEmpty, components.count >= parts.count else { return false }
        let last = parts.count - 1
        let upperBound = components.count - parts.count
        // 锚定型签名的起点被钉死在最后一个可能位置；其余从 0 起滑动。
        // 旧写法 `suffixOnly ? [upperBound] : Array(0...upperBound)` 每次调用都要物化一个 [Int]。
        var start = suffixOnly ? upperBound : 0

        while start <= upperBound {
            var hit = true
            for (offset, part) in parts.enumerated() {
                let haystackPart = components[start + offset]
                // 末段：允许右边界分隔符；中间段：整段相等。
                let ok = offset == last ? tokenHasPrefix(haystackPart, part) : haystackPart == part
                if !ok { hit = false; break }
            }
            if hit { return true }
            start += 1
        }
        return false
    }

    /// `haystack` 是否等于 `needle`，或以 `needle` 开头且其后紧跟右边界分隔符。
    private static func tokenHasPrefix(_ haystack: String, _ needle: String) -> Bool {
        if haystack == needle { return true }
        guard haystack.hasPrefix(needle) else { return false }
        // `hasPrefix` 成立 ⇒ needle 的 UTF-8 是 haystack 的字节前缀，故 needle.utf8.count
        // 处的字节正落在下一个标量的开头；多字节标量的首字节 >= 0xC0，不会误命中分隔符。
        let bytes = haystack.utf8
        let probe = bytes.index(bytes.startIndex, offsetBy: needle.utf8.count)
        guard probe < bytes.endIndex else { return false }
        return rightBoundaryDelimiterBytes.contains(bytes[probe])
    }

    /// 按反向域名分段匹配 Bundle Identifier（`com.windsurf` 命中 `com.windsurf.ai`，
    /// 不命中 `com.example.windsurf`）。
    static func matchesBundleIdentifier(_ signature: String, bundleID: String) -> Bool {
        matchesBundleIdentifier(compileBundleIdentifierSignature(signature), bundleID: bundleID)
    }

    /// 预编译签名版。
    static func matchesBundleIdentifier(_ signature: CompiledSignature, bundleID: String) -> Bool {
        guard !signature.parts.isEmpty else { return false }
        return matches(signature.parts, in: scanComponents(of: bundleID, by: bundleIDSplitter), suffixOnly: false)
    }

    // MARK: - 3. bundle 归组与纯辅助进程

    /// 可执行文件所属的**最外层** `.app` bundle 路径；不在任何 `.app` 内时返回 nil。
    ///
    /// 取最外层而不是最内层：`Codex (Renderer).app`、`SkyComputerUseClient.app` 这类
    /// 内嵌 helper bundle 是宿主 App 的一部分，归到宿主才算「一个 Agent」。
    /// 反之，终端里跑的 `/usr/local/bin/claude` 不在任何 bundle 内 → 返回 nil，
    /// 每次调用保持各自独立身份，不会被归并吞掉。
    ///
    /// 返回值保留路径的原始大小写（它是归并键，也是 `Bundle(url:)` 的入参），
    /// 只在判断 `.app` 收尾时做 ASCII 大小写折叠。
    static func enclosingAppBundle(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let bytes = path.utf8
        let appSuffix: [UInt8] = [0x2E, 0x61, 0x70, 0x70]   // ".app"

        var runStart = bytes.index(after: bytes.startIndex)   // 跳过开头的 '/'
        var index = runStart
        while index < bytes.endIndex {
            if bytes[index] == 0x2F {   // '/'：一个分量到此结束
                if hasASCIISuffix(appSuffix, in: bytes, runStart: runStart, runEnd: index) {
                    return String(path[path.startIndex..<index])
                }
                // 空分量（连续斜杠或结尾斜杠）会让旧实现归一化掉它——这种病态路径退回去，
                // 保证归并键与旧实现逐字相同。
                guard index > runStart else { return legacyEnclosingAppBundle(path) }
                runStart = bytes.index(after: index)
            }
            index = bytes.index(after: index)
        }
        // 最后一个分量（路径通常以文件名收尾，不带斜杠）
        if runStart < bytes.endIndex
            , hasASCIISuffix(appSuffix, in: bytes, runStart: runStart, runEnd: bytes.endIndex) {
            return String(path[path.startIndex..<bytes.endIndex])
        }
        return nil
    }

    /// `enclosingAppBundle` 的旧口径实现（含空分量归一化），只在病态路径上退到这里。
    private static func legacyEnclosingAppBundle(_ path: String) -> String? {
        var accumulated = ""
        for component in path.components(separatedBy: "/") where !component.isEmpty {
            accumulated += "/" + component
            if component.lowercased().hasSuffix(".app") { return accumulated }
        }
        return nil
    }

    /// 是否为「纯辅助进程」——自身绝不可能是 Agent，只能作为所属 bundle 的一部分被计入。
    ///
    /// 三类证据都是 macOS 的既定打包布局，不是猜测：
    ///  · `*_crashpad_handler`：Chromium/Electron 的崩溃转储守护进程；
    ///  · `*.xpc` / `XPCServices/`：XPC 服务对象进程；
    ///  · 内嵌在另一个 `.app` 里的 `.app`（`Code Helper.app`、`Codex (Service).app`）：helper bundle。
    static func isPureHelperProcess(_ record: ProcessRecord) -> Bool {
        let name = record.name.lowercased()
        if name == "crashpad_handler" || name.hasSuffix("_crashpad_handler") { return true }

        // 一次切分供三条证据共用（旧写法先 components、再 map lowercased、再 filter，三趟）。
        // 切分符只用 "/"：与旧实现的 `components(separatedBy: "/")` 同口径，
        // 不是 `pathSplitter`（那套还把 "=" 与 ":" 当边界，会改变内嵌 bundle 的计数）。
        let components = scanComponents(of: record.executablePath, by: forwardSlashSplitter)
        if components.contains(where: { $0.hasSuffix(".xpc") }) { return true }
        if components.contains("xpcservices") { return true }

        // 路径里出现不止一个 `.app` 分量 → 当前进程跑在某个内嵌 bundle 中
        // （`Code Helper.app`、`Codex (Service).app`、`SkyComputerUseClient.app`）。
        var appComponents = 0
        for component in components where component.hasSuffix(".app") {
            appComponents += 1
            if appComponents >= 2 { return true }
        }
        return false
    }
}

// MARK: - 签名字典的预编译视图

/// 一条 `AgentSignature` 的预编译形态：kind 与表内顺序原样保留。
///
/// 策略原先逐记录做三件「每次结果都一样」的事：把常量签名切段、把常量进程名
/// `lowercased()`、按 kind 在表里线性扫签名。这些都挪到这里，在策略 `init` 里做一次。
struct AgentSignaturePlan: Sendable {

    /// 与 `AgentSignatureDatabase.entries` 一一对齐、顺序一致的预编译条目。
    struct Entry: Sendable {
        /// 对应的 Agent 种类（= `signature.kind`）。
        let kind: AgentKind
        /// `pathFragments` 的预编译结果。
        let pathFragments: [DetectionHygiene.CompiledSignature]
        /// `appBundleNames` 的预编译结果。
        let appBundleNames: [DetectionHygiene.CompiledSignature]
        /// `bundleIdentifiers` 的预编译结果（点号分段）。
        let bundleIdentifiers: [DetectionHygiene.CompiledSignature]
        /// `argumentSignatures` 的预编译结果。
        let argumentSignatures: [DetectionHygiene.CompiledSignature]
        /// `processNames`，已小写。
        let processNames: [String]
        /// `processNamePrefixes`，已小写。
        let processNamePrefixes: [String]

        init(signature: AgentSignature) {
            self.kind = signature.kind
            self.pathFragments = signature.pathFragments.map(DetectionHygiene.compileSignature)
            self.appBundleNames = signature.appBundleNames.map(DetectionHygiene.compileSignature)
            self.bundleIdentifiers = signature.bundleIdentifiers.map(DetectionHygiene.compileBundleIdentifierSignature)
            self.argumentSignatures = signature.argumentSignatures.map(DetectionHygiene.compileSignature)
            self.processNames = signature.processNames.map { $0.lowercased() }
            self.processNamePrefixes = signature.processNamePrefixes.map { $0.lowercased() }
        }
    }

    /// 预编译后的全部条目（顺序 = 特征库顺序 = 置信度优先级）。
    let entries: [Entry]

    init(_ database: AgentSignatureDatabase) {
        self.entries = database.entries.map(Entry.init)
    }

    /// 按 Agent 种类取预编译条目。
    ///
    /// 取代 `AgentSignatureDatabase.signature(for:)` 放在逐记录循环里做的事
    /// （那是一条线性扫描，旧写法每条记录要跑 9 次）。语义相同：取第一个 kind 匹配的条目。
    func entry(for kind: AgentKind) -> Entry? {
        entries.first { $0.kind == kind }
    }
}
