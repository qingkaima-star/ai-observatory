//
//  ExportRedactorTests.swift
//  AIObservatoryExportTests
//
//  Owner: WS-Export（子代理 F）
//
//  `ExportRedactor` 的验收测试，逐条对应《导出层接口》§2 D（另参照实现文件头的设计约束）。
//  纯字符串测试：不写盘、不碰网络、不读墙钟（无 `Date()` / `ProcessInfo.systemUptime`），
//  无 sleep / 定时器 / 循环等待，全部用例必然终止。
//  占位符一律经 `ExportRedactor.placeholder(for:)` 与 `ExportConstants` 拼装，
//  断言里不硬编码猜想的 kind 拼写（kind 只从 `RedactionKind` 取）。
//  `ExportRedactor` / `RedactionKind` / `ExportConstants` 的全部用到的 API 都是 public，
//  因此用普通 `import AIObservatoryExport`，不需要 `@testable`，也不 import AIObservatoryTestSupport。
//

import Foundation
import Testing
import AIObservatoryExport

// MARK: - 样本

/// 凭据形态样本：全部是编译期字面量，与运行时刻无关。
private enum SecretSamples {
    // MARK: 五种硬性验收形态（§2 D「验收必测」）

    static let openAIKey = "sk-ABCDEFGHIJKLMNOP1234"
    static let githubToken = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
    static let awsAccessKey = "AKIAABCDEFGHIJKLMNOP"
    static let passwordValue = "hunter2secret"
    static let passwordAssignment = "password=hunter2secret"

    /// 同族第二个 OpenAI 形态值（用于 `detectedKinds` 的去重断言）。
    static let openAIKeyAgain = "sk-ZXCVBNM1234567890123456"

    /// 带 END 行的完整 RSA 私钥块。正文里刻意不含 `=` / `sk-` / `AKIA` 等其它规则的触发字面量。
    static let rsaPrivateKeyBlock = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowpAAQKCZ3qExAMPLEBODY0123456789abcdefghijklmnopqrstuvwx
    yz0123456789ABCDEF+/GHIJKLMNopqrstuv0123456789
    -----END RSA PRIVATE KEY-----
    """

    /// 被截断、缺 END 行的 RSA 块（§2 D 硬性验收形态给的就是 `-----BEGIN …\nMIIEow…` 这种半截）。
    static let rsaPrivateKeyTruncated = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowpAAQKCZ3qExAMPLEBODY0123456789abcdefghijklmnopqrstuvwx
    """

    /// 完整 OPENSSH 私钥块：BEGIN → base64 正文 → END。
    static let opensshPrivateKeyBlock = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAA
    AAtzZWNoLmV4YW1wbGUvc3NoLXdlYi1yc2EtY29tbWVudAAAAAdzMgtjcnNh
    AAAB+gEXAMPLEBODY0123456789abcdefghijklmnopqrstuvwx01234567
    89ABCDEF+/zzyxwvutsrqponmlkjihg
    -----END OPENSSH PRIVATE KEY-----
    """

    // MARK: 其它形态

    static let authorizationBearerOpenAI = "Authorization: Bearer " + SecretSamples.openAIKey
    static let authorizationBearerGitHubLowerKey = "authorization: Bearer " + SecretSamples.githubToken
    static let upperPasswordAssignment = "PASSWORD=hunter2secret"
    static let tokenAssignment = "TOKEN=MyPreciousValue1234"
    static let envFileBlock = """
    APP_NAME=observatory
    MY_SECRET=hunter2value
    export GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345
    DB_URL=postgres://localhost:5432/db
    """
    // 夹具形状刻意避开 GitHub push protection 的报送形状（stripe 要求 `sk_live_` 后 ≥24 位连续
    // 字母数字、slack 要求「数字段-数字段-小写段」结构），同时仍被产品正则命中
    // （stripe 体字符类含 `_`、slack 尾部仅要求 ≥6 位）——否则公开仓库推不上去。
    static let stripeSecret = "sk_live_51HxAMPLE_EXAMPLE_EXAMP1234"
    static let slackToken = "xoxb-EXAMPLE_TOKEN_ABC123"
    static let bareBearerValue = "abcdefghijklmnop1234"

    /// 组合实战：模拟真实 `CommandRecord.commandLine`（一行三种凭据形态 + 大量良性文本）。
    static let combinedCommandLine = """
    curl -H "Authorization: Bearer sk-ABCDEFGHIJKLMNOP1234" https://api.example.com -d "password=hunter2secret"
    """

    /// 跨行样本：同一段自由文本里三种形态各在一行。
    static let multilineCommand = """
    curl \(SecretSamples.openAIKey)
    password=hunter2secret
    github \(SecretSamples.githubToken)
    """

    /// 紧邻 emoji / 组合字素簇的秘钥：专测 UTF-16 区间 → `String` 区间的转换。
    static let emojiAdjacentCommand = "👨‍👩‍👧 团队 \(SecretSamples.openAIKey) ✅ 备注 🧑🏽‍🎨"
}

/// 必须**逐字符原样**返回的良性文本（含 §2 D 点名的中文、emoji、`|`、逗号、引号、路径、`sk-short`）。
private enum BenignSamples {
    static let all: [String] = [
        "会话「Mona」在 13 号读取了 3 个文件，风险等级：中",
        "👨‍👩‍👧 全家福 👩🏽‍💻 开发者 🏳️‍🌈 旗帜 🇨🇳 ✅",
        "path|with,commas \"quotes\" 与反斜杠 \\ 结尾 /Users/demo/Projects/Mona/API.swift",
        "sk-short",
        "SK-SHORT-ABCDEFGHIJ",
        "monkey=banana",
        "KEYRING=unset",
        "DB_URL=postgres://localhost:5432/db",
        "",
        "   ",
        "a,b|c\"d\\e/f g.swift",
    ]
}

// MARK: - 断言工具

/// `secret` 的全部长度为 `length` 的滑动窗口（不足长度时返回整串）。纯有限循环，必然终止。
private func slidingWindows(of secret: String, length: Int) -> [String] {
    guard length > 0, secret.count > length else { return [secret] }
    var windows: [String] = []
    var index = secret.startIndex
    while index < secret.endIndex {
        guard let end = secret.index(index, offsetBy: length, limitedBy: secret.endIndex) else { break }
        windows.append(String(secret[index..<end]))
        if end == secret.endIndex { break }
        index = secret.index(after: index)
    }
    return windows
}

/// 原值残留体检：整串、以及原值每一个 8 字符片段，都不得出现在结果里（§2 D「原始值不得残留任何片段」）。
private func expectNoSecretResidue(_ secret: String, in output: String) {
    #expect(output.contains(secret) == false, "结果里仍能看到完整原值：\(secret)")
    #expect(secret.count >= 8, "样本太短，滑窗检查无意义：\(secret)")
    for window in slidingWindows(of: secret, length: 8) {
        #expect(window.count == 8, "滑窗样本异常：\(window)")
        #expect(output.contains(window) == false, "原值片段残留：\(window)")
    }
}

/// 硬验收形态的四元组：输入、必须消失的值、期望 kind、期望整串输出。
private struct HardCase: Sendable {
    var label: String
    var input: String
    var secret: String
    var kind: RedactionKind
    var expected: String
}

private func hardAcceptanceCases() -> [HardCase] {
    [
        HardCase(label: "openai_key",
                 input: SecretSamples.openAIKey,
                 secret: SecretSamples.openAIKey,
                 kind: .openAIKey,
                 expected: ExportRedactor.placeholder(for: .openAIKey)),
        HardCase(label: "github_token",
                 input: SecretSamples.githubToken,
                 secret: SecretSamples.githubToken,
                 kind: .githubToken,
                 expected: ExportRedactor.placeholder(for: .githubToken)),
        HardCase(label: "aws_access_key",
                 input: SecretSamples.awsAccessKey,
                 secret: SecretSamples.awsAccessKey,
                 kind: .awsAccessKey,
                 expected: ExportRedactor.placeholder(for: .awsAccessKey)),
        HardCase(label: "private_key",
                 input: SecretSamples.rsaPrivateKeyBlock,
                 secret: SecretSamples.rsaPrivateKeyBlock,
                 kind: .privateKey,
                 expected: ExportRedactor.placeholder(for: .privateKey)),
        HardCase(label: "password_assignment",
                 input: SecretSamples.passwordAssignment,
                 secret: SecretSamples.passwordValue,
                 kind: .passwordAssignment,
                 expected: "password=" + ExportRedactor.placeholder(for: .passwordAssignment)),
    ]
}

/// 幂等回路的输入全集（每条都要跑 `redact(redact(x)) == redact(x)`）。
private func idempotencyCorpus() -> [String] {
    [
        SecretSamples.openAIKey,
        SecretSamples.githubToken,
        SecretSamples.awsAccessKey,
        SecretSamples.rsaPrivateKeyBlock,
        SecretSamples.rsaPrivateKeyTruncated,
        SecretSamples.opensshPrivateKeyBlock,
        SecretSamples.passwordAssignment,
        SecretSamples.upperPasswordAssignment,
        SecretSamples.tokenAssignment,
        SecretSamples.authorizationBearerOpenAI,
        SecretSamples.authorizationBearerGitHubLowerKey,
        SecretSamples.envFileBlock,
        SecretSamples.stripeSecret,
        SecretSamples.slackToken,
        "raw http request bearer " + SecretSamples.bareBearerValue + " done",
        SecretSamples.multilineCommand,
        SecretSamples.emojiAdjacentCommand,
        SecretSamples.combinedCommandLine,
        "OPENAI_API_KEY=" + SecretSamples.openAIKey,
    ]
}

// MARK: - 测试

@Suite("ExportRedactor · 凭据形态脱敏（§2 D）")
struct ExportRedactorTests {
    private let redactor = ExportRedactor.standard

    // 1 · 五种硬性验收形态

    @Test("硬性验收五形态：逐个掩码、含 ‹redacted:kind›、原值零残留")
    func hardAcceptanceFormsAreMasked() {
        for testCase in hardAcceptanceCases() {
            let output = self.redactor.redact(testCase.input)

            #expect(output.contains(testCase.input) == false, "\(testCase.label)：完整原值仍在")
            #expect(output.contains(ExportConstants.redactionPrefix),
                    "\(testCase.label)：缺占位符前缀")
            #expect(output.contains(testCase.kind.rawValue),
                    "\(testCase.label)：缺 kind rawValue \(testCase.kind.rawValue)")
            #expect(output.contains(ExportRedactor.placeholder(for: testCase.kind)),
                    "\(testCase.label)：占位符形态不对")
            #expect(output == testCase.expected, "\(testCase.label)：整串输出不符")
            expectNoSecretResidue(testCase.secret, in: output)
        }
    }

    // 2 · 幂等

    @Test("幂等：redact(redact(x)) == redact(x)，对语料库逐条跑")
    func redactionIsIdempotent() {
        for input in idempotencyCorpus() {
            let once = self.redactor.redact(input)
            let twice = self.redactor.redact(once)

            #expect(twice == once, "不幂等：\(input)")
            // 已成型占位符不得被二次包裹
            #expect(once.contains(ExportConstants.redactionPrefix + ExportConstants.redactionPrefix) == false,
                    "占位符被二次包裹：\(once)")
            #expect(self.redactor.redact(self.redactor.redact(twice)) == once)
        }
    }

    // 3 · 良性文本逐字符原样

    @Test("良性文本逐字符原样：中文 / 组合 emoji / 竖线 / 逗号 / 引号 / 路径 / sk-short")
    func benignTextIsReturnedVerbatim() {
        for text in BenignSamples.all {
            let output = self.redactor.redact(text)

            #expect(output == text, "良性文本被改写：[\(text)] → [\(output)]")
            #expect(output.utf16.count == text.utf16.count)
            #expect(output.unicodeScalars.count == text.unicodeScalars.count)
            #expect(self.redactor.detectedKinds(in: text).isEmpty,
                    "良性文本误报形态：\(text) → \(self.redactor.detectedKinds(in: text))")
        }

        // 长度阈值：`sk-short` 不足 16 位必须原样，同族加长版必须被掩
        #expect(self.redactor.redact("sk-short") == "sk-short")
        #expect(self.redactor.redact(SecretSamples.openAIKey)
                == ExportRedactor.placeholder(for: .openAIKey))
        // 组合字素簇 + 秘钥：区间端点仍要落在字素边界上
        let emojiLine = self.redactor.redact(SecretSamples.emojiAdjacentCommand)
        #expect(emojiLine.hasPrefix("👨‍👩‍👧 团队 "))
        #expect(emojiLine.hasSuffix(" ✅ 备注 🧑🏽‍🎨"))
        #expect(emojiLine.contains(ExportRedactor.placeholder(for: .openAIKey)))
        expectNoSecretResidue(SecretSamples.openAIKey, in: emojiLine)
    }

    // 4 · 只掩值不掩键

    @Test("只掩值不掩键：password= 与 OPENAI_API_KEY= 的键名保留")
    func keysSurviveWhileOnlyValuesAreMasked() {
        let password = self.redactor.redact(SecretSamples.passwordAssignment)
        #expect(password.hasPrefix("password="))
        #expect(password == "password=" + ExportRedactor.placeholder(for: .passwordAssignment))
        expectNoSecretResidue(SecretSamples.passwordValue, in: password)

        let envStyle = self.redactor.redact("OPENAI_API_KEY=" + SecretSamples.openAIKey)
        #expect(envStyle.hasPrefix("OPENAI_API_KEY="))
        #expect(envStyle.utf16.count > "OPENAI_API_KEY=".utf16.count)
        #expect(envStyle == "OPENAI_API_KEY=" + ExportRedactor.placeholder(for: .openAIKey))
        // 重叠择优：更具体的 openai_key 赢，泛化的 env_file_value 不出现
        #expect(envStyle.contains(ExportRedactor.placeholder(for: .envFileValue)) == false)
        expectNoSecretResidue(SecretSamples.openAIKey, in: envStyle)

        // 键名保留 + 值掩掉：.env 整块里只有敏感键的值被替换，非敏感行原样
        let envBlock = self.redactor.redact(SecretSamples.envFileBlock)
        #expect(envBlock.hasPrefix("APP_NAME=observatory\nMY_SECRET="))
        #expect(envBlock.contains("export GITHUB_TOKEN=" + ExportRedactor.placeholder(for: .githubToken)))
        #expect(envBlock.contains("DB_URL=postgres://localhost:5432/db"))
        expectNoSecretResidue("hunter2value", in: envBlock)
        expectNoSecretResidue(SecretSamples.githubToken, in: envBlock)
    }

    // 5 · Authorization 头

    @Test("Authorization: Bearer <token>：整段值消失，无任何 ≥8 字符残片")
    func authorizationHeaderValueIsFullyMasked() {
        let cases: [(String, String)] = [
            (SecretSamples.authorizationBearerOpenAI, SecretSamples.openAIKey),
            ("Authorization: Bearer " + SecretSamples.githubToken, SecretSamples.githubToken),
            ("Authorization: Basic ZGVtbyToaHVudGVyMg==", "ZGVtbyToaHVudGVyMg=="),
            (SecretSamples.authorizationBearerGitHubLowerKey, SecretSamples.githubToken),
        ]
        for (input, token) in cases {
            let output = self.redactor.redact(input)

            #expect(output.hasPrefix("Authorization:") || output.hasPrefix("authorization:"),
                    "键名 Authorization 丢了：\(output)")
            #expect(output.contains(ExportRedactor.placeholder(for: .authorizationHeader)),
                    "未按 authorization_header 掩码：\(output)")
            expectNoSecretResidue(token, in: output)
            // §2 D：`Authorization: Bearer xyz` → `Authorization:‹redacted:authorization_header›`
            if input == "Authorization: Bearer " + SecretSamples.githubToken {
                #expect(output == "Authorization:" + ExportRedactor.placeholder(for: .authorizationHeader))
            }
        }
    }

    // 6 · 大小写无关

    @Test("大小写无关：PASSWORD= / authorization: / TOKEN= / Bearer 都命中")
    func matchingIsCaseInsensitive() {
        let upperPassword = self.redactor.redact(SecretSamples.upperPasswordAssignment)
        let expectedUpperPassword = "PASSWORD=" + ExportRedactor.placeholder(for: .passwordAssignment)
        #expect(upperPassword == expectedUpperPassword)
        expectNoSecretResidue(SecretSamples.passwordValue, in: upperPassword)
        let detectedPassword = self.redactor.detectedKinds(in: "Password=hunter2secret")
        #expect(detectedPassword.contains(.passwordAssignment))

        let lowerAuth = self.redactor.redact(SecretSamples.authorizationBearerGitHubLowerKey)
        let expectedLowerAuth = "authorization:" + ExportRedactor.placeholder(for: .authorizationHeader)
        #expect(lowerAuth.hasPrefix("authorization:"))
        #expect(lowerAuth == expectedLowerAuth)
        expectNoSecretResidue(SecretSamples.githubToken, in: lowerAuth)

        let token = self.redactor.redact(SecretSamples.tokenAssignment)
        let expectedToken = "TOKEN=" + ExportRedactor.placeholder(for: .tokenAssignment)
        #expect(token.hasPrefix("TOKEN="))
        #expect(token == expectedToken)
        expectNoSecretResidue("MyPreciousValue1234", in: token)

        let mixedToken = self.redactor.redact("Access_Token=hunter2TokenValue")
        let expectedMixedToken = "Access_Token=" + ExportRedactor.placeholder(for: .tokenAssignment)
        #expect(mixedToken.hasPrefix("Access_Token="))
        #expect(mixedToken == expectedMixedToken)

        // 秘钥本体前缀仍按形态区分大小写（`sk-` 是小写形态，大写视为良性）
        #expect(self.redactor.redact("SK-ABCDEFGHIJKLMNOP1234") == "SK-ABCDEFGHIJKLMNOP1234")
    }

    // 7 · nil / 空串 / disabled

    @Test("redact(nil) == nil、redact(\"\") == \"\"、disabled 恒等返回")
    func emptyOptionalAndDisabledAreIdentities() {
        let missing: String? = nil
        #expect(self.redactor.redact(missing) == nil)
        #expect(self.redactor.redact("") == "")
        #expect(self.redactor.redact("").isEmpty)

        let present: String? = SecretSamples.openAIKey
        let optionalOutput = self.redactor.redact(present)
        #expect(optionalOutput != nil)
        let unwrappedOutput = optionalOutput ?? "‹意外的 nil›"
        #expect(unwrappedOutput == ExportRedactor.placeholder(for: .openAIKey))

        #expect(self.redactor.isEnabled)
        #expect(ExportRedactor.disabled.isEnabled == false)
        for input in idempotencyCorpus() {
            #expect(ExportRedactor.disabled.redact(input) == input, "disabled 改写了文本：\(input)")
        }
        // 关闭脱敏只影响 redact，不影响预检 reporting
        #expect(ExportRedactor.disabled.detectedKinds(in: SecretSamples.openAIKey) == [.openAIKey])
        #expect(ExportRedactor.disabled.redact(SecretSamples.combinedCommandLine)
                == SecretSamples.combinedCommandLine)
        // 占位符由 ExportConstants 前后缀拼装
        #expect(ExportRedactor.placeholder(for: .slackToken)
                == ExportConstants.redactionPrefix + RedactionKind.slackToken.rawValue + ExportConstants.redactionSuffix)
    }

    // 8 · detectedKinds

    @Test("detectedKinds：首次出现顺序 + 去重；良性文本与空串返回空数组")
    func detectedKindsAreOrderedByFirstAppearanceAndDeduplicated() {
        // 多形态混排的一行：openAI → aws → github → openAI（重复）
        let mixedBase = "retry " + SecretSamples.openAIKey + " then " + SecretSamples.awsAccessKey
        let mixedTail = " then " + SecretSamples.githubToken + " again " + SecretSamples.openAIKeyAgain
        let mixed = mixedBase + mixedTail
        #expect(self.redactor.detectedKinds(in: mixed)
                == [.openAIKey, .awsAccessKey, .githubToken])
        // 顺序颠倒 → 报告顺序随之改变（证明确实是「首次出现」而不是枚举顺序）
        let flippedBase = "then " + SecretSamples.githubToken + " then " + SecretSamples.awsAccessKey
        let flipped = flippedBase + " then " + SecretSamples.openAIKey
        #expect(self.redactor.detectedKinds(in: flipped)
                == [.githubToken, .awsAccessKey, .openAIKey])

        // 重叠计报：§2 D 设计说明里 `Authorization: Bearer sk-…` 同时报告三种形态
        #expect(self.redactor.detectedKinds(in: SecretSamples.authorizationBearerOpenAI)
                == [.authorizationHeader, .bearerToken, .openAIKey])
        #expect(self.redactor.detectedKinds(in: SecretSamples.combinedCommandLine)
                == [.authorizationHeader, .bearerToken, .openAIKey, .passwordAssignment])
        #expect(self.redactor.detectedKinds(in: SecretSamples.rsaPrivateKeyBlock) == [.privateKey])
        #expect(self.redactor.detectedKinds(in: SecretSamples.envFileBlock)
                == [.envFileValue, .githubToken])

        for text in BenignSamples.all {
            #expect(self.redactor.detectedKinds(in: text).isEmpty)
        }
        #expect(self.redactor.detectedKinds(in: "").isEmpty)
    }

    // 9 · 整段私钥

    @Test("整段私钥（RSA 完整 / RSA 截断 / OPENSSH）：BEGIN、base64 体、END 全部不残留")
    func wholePrivateKeyBlocksLeaveNoBase64Residue() {
        let placeholder = ExportRedactor.placeholder(for: .privateKey)
        for block in [SecretSamples.rsaPrivateKeyBlock,
                      SecretSamples.rsaPrivateKeyTruncated,
                      SecretSamples.opensshPrivateKeyBlock] {
            let output = self.redactor.redact(block)

            #expect(output == placeholder, "整块私钥应折叠成单个占位符：\(output)")
            #expect(output.split(separator: "\n", omittingEmptySubsequences: false).count == 1)
            #expect(output.contains("-----BEGIN") == false)
            #expect(output.contains("PRIVATE KEY-----") == false)
            #expect(output.contains("MIIEowpAAQKCZ3qEx") == false)
            #expect(output.contains("b3BlbnNzaC1rZXktdjEAAAAA") == false)
            #expect(output.utf16.count < block.utf16.count)
            expectNoSecretResidue(block, in: output)
        }

        // 私钥块嵌在自由文本中间时，两侧文本保留、块体消失
        let wrapped = "id_ed25519 内容：" + SecretSamples.rsaPrivateKeyBlock + "（已入库）"
        let wrappedOutput = self.redactor.redact(wrapped)
        #expect(wrappedOutput.hasPrefix("id_ed25519 内容："))
        #expect(wrappedOutput.hasSuffix("（已入库）"))
        #expect(wrappedOutput == "id_ed25519 内容：" + placeholder + "（已入库）")
        expectNoSecretResidue(SecretSamples.rsaPrivateKeyBlock, in: wrappedOutput)
    }

    // 10 · 组合实战

    @Test("组合实战 curl 命令行：多形态重叠整行干净、非凭据文本原样")
    func combinedCommandLineMasksEveryCredential() {
        let output = self.redactor.redact(SecretSamples.combinedCommandLine)

        // 整行无原值片段
        expectNoSecretResidue(SecretSamples.openAIKey, in: output)
        expectNoSecretResidue(SecretSamples.passwordValue, in: output)
        #expect(output.contains("Bearer ") == false)
        #expect(output.contains("sk-") == false)

        // 三种秘钥各自的处置：`Authorization: Bearer sk-…` 按 §2 D 整段归 authorization_header，
        // `password=` 值归 password_assignment；两者各自留下一个占位符。
        #expect(output.contains(ExportRedactor.placeholder(for: .authorizationHeader)))
        #expect(output.contains(ExportRedactor.placeholder(for: .passwordAssignment)))
        #expect(output.components(separatedBy: ExportConstants.redactionPrefix).count - 1 == 2)

        // 良性部分逐字保留
        #expect(output.hasPrefix("curl -H \"Authorization:"))
        #expect(output.contains("\" https://api.example.com -d \"password="))
        #expect(output.hasSuffix("\""))
        let authPart = "curl -H \"Authorization:" + ExportRedactor.placeholder(for: .authorizationHeader)
        let passwordPart = "\" https://api.example.com -d \"password=" + ExportRedactor.placeholder(for: .passwordAssignment) + "\""
        #expect(output == authPart + passwordPart)

        // 幂等 + 跨行 / 重叠语料的整行体检
        #expect(self.redactor.redact(output) == output)
        let multiline = self.redactor.redact(SecretSamples.multilineCommand)
        expectNoSecretResidue(SecretSamples.openAIKey, in: multiline)
        expectNoSecretResidue(SecretSamples.githubToken, in: multiline)
        expectNoSecretResidue(SecretSamples.passwordValue, in: multiline)
        #expect(multiline.split(separator: "\n").count == 3)
    }

    // 11 · 其余受支持形态

    @Test("其余形态：stripe / slack / 裸 Bearer / token= / .env 值各自归位")
    func otherSupportedFormsAreMasked() {
        let stripe = self.redactor.redact("pay with " + SecretSamples.stripeSecret + " now")
        #expect(stripe == "pay with " + ExportRedactor.placeholder(for: .stripeSecret) + " now")
        expectNoSecretResidue(SecretSamples.stripeSecret, in: stripe)

        let slack = self.redactor.redact("notify me " + SecretSamples.slackToken + " please")
        #expect(slack == "notify me " + ExportRedactor.placeholder(for: .slackToken) + " please")
        expectNoSecretResidue(SecretSamples.slackToken, in: slack)

        let bearer = self.redactor.redact("raw http request bearer " + SecretSamples.bareBearerValue + " done")
        #expect(bearer.hasPrefix("raw http request bearer "))
        #expect(bearer == "raw http request bearer " + ExportRedactor.placeholder(for: .bearerToken) + " done")
        expectNoSecretResidue(SecretSamples.bareBearerValue, in: bearer)

        let envValue = self.redactor.redact("MY_SECRET=hunter2value")
        #expect(envValue == "MY_SECRET=" + ExportRedactor.placeholder(for: .envFileValue))
        expectNoSecretResidue("hunter2value", in: envValue)

        let testStripe = self.redactor.redact(SecretSamples.stripeSecret.replacingOccurrences(of: "sk_live_", with: "sk_test_"))
        #expect(testStripe == ExportRedactor.placeholder(for: .stripeSecret))
    }
}

// MARK: - 主代理补：过度脱敏即证据损毁（真实导出文件里发现过）

@Suite("ExportRedactor · 掩码范围不得吞掉相邻审计证据")
struct ExportRedactorOverMaskingTests {
    @Test("Authorization 值只延伸到结构分隔符，不得吞掉同一字符串里后续的 password= 字段")
    func authorizationDoesNotSwallowNeighbouringArguments() {
        let redactor = ExportRedactor.standard
        // 这是 CSV「参数列」用 "; " 拼接后的真实形态。
        let joined = "-H; Authorization: Bearer sk-ABCDEFGHIJKLMNOP1234567890; -d; password=hunter2secret"
        let masked = redactor.redact(joined)

        // 证据必须留下：相邻参数不能被一并抹掉。
        #expect(masked.contains("-d"), "相邻参数 -d 被过度掩码吞掉了：\(masked)")
        #expect(masked.contains("password=‹redacted:password_assignment›"),
                "password 键名要保留、值要掩掉：\(masked)")
        #expect(masked.contains("; -d;"), "分号分隔的相邻参数结构必须完整：\(masked)")
        // 凭据仍然一个都不许剩。
        #expect(masked.contains("ABCDEFGHIJKLMNOP1234567890") == false)
        #expect(masked.contains("hunter2secret") == false)
        #expect(masked.contains("sk-") == false)
        #expect(masked.filter { $0 == "‹" }.count == 2, "两个凭据 → 两个占位符：\(masked)")
    }

    @Test("引号内的 Authorization 值在引号处收口")
    func quotedAuthorizationStopsAtQuote() {
        let masked = ExportRedactor.standard
            .redact("curl -H \"Authorization: Bearer ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345\" --url https://api.example.com")
        #expect(masked.contains("--url https://api.example.com"), "URL 参数不得被吞掉：\(masked)")
        #expect(masked.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") == false)
    }
}
