//
//  CommandLineRedactionTests.swift
//  Tests/AIObservatoryPlatformTests — Telemetry
//
//  Owner: ws-engaudit
//
//  钉住 §7「禁采凭据」在命令这条链路上的三条不变式（AGENTS §7 + `CommandLineRedaction` 文件头）：
//   1. 掩值不掩事实：参数个数、顺序、命令名、键名、scheme 全在，只有值变成占位符；
//   2. 幂等：第二遍什么也不改；
//   3. 不过掩：`--filter auth`、`--author`、普通 URL、路径参数逐字符不动。
//
//  期望值全部**照着 fixture 手推**成字面量（不从实现里读回来当期望值）。
//

import Foundation
import Testing
@testable import AIObservatoryPlatform
import AIObservatoryCore

private let openAI = "‹redacted:openai_key›"
private let basic = "‹redacted:basic_auth›"
private let password = "‹redacted:password_assignment›"
private let envValue = "‹redacted:env_file_value›"

/// 真机自查（2026-09-21）里实际被采到的那四条命令行——不是编的样本。
private enum Live {
    /// `sh -c` 那一格里的完整脚本（采样侧真的会把它当成一个 argv 元素存进 arguments_json）。
    static let headerScript = "curl -sS -H 'Authorization: Bearer sk-TEST123' http://127.0.0.1:9/ ; sleep 4"
    static let basicAuthScript = "curl -sS -u audit:PASSWORD-here http://127.0.0.1:9/ ; sleep 4"
    static let passwordScript = "mysql --password=Sup3rSecret -h 127.0.0.1 -e 'select 1' ; sleep 4"
    static let envScript = "AWS_SECRET_ACCESS_KEY=wJalrEXAMPLEKEY curl -sS http://127.0.0.1:9/ ; sleep 4"
}

@Suite("命令行凭据脱敏：形态、结构与幂等")
struct CommandLineRedactionTests {

    // MARK: - 1. 四种凭据形态（真机自查逐字）

    @Test("头里的 Bearer key 被掩，头名与 scheme 留着")
    func authorizationHeader() {
        #expect(CommandLineRedaction.redact(Live.headerScript)
                == "curl -sS -H 'Authorization: Bearer \(openAI)' http://127.0.0.1:9/ ; sleep 4")
    }

    @Test("离散 argv：-H 那一格只掩值")
    func discreteHeaderArgument() {
        let redacted = CommandLineRedaction.redact(arguments: [
            "curl", "-H", "Authorization: Bearer sk-TEST123", "http://127.0.0.1:9/",
        ])
        #expect(redacted == ["curl", "-H", "Authorization: Bearer \(openAI)", "http://127.0.0.1:9/"])
    }

    @Test("-u user:pass 保留用户名，只掩口令")
    func basicAuthInlined() {
        #expect(CommandLineRedaction.redact(Live.basicAuthScript)
                == "curl -sS -u audit:\(basic) http://127.0.0.1:9/ ; sleep 4")
    }

    @Test("-u 与值分写：带冒号才掩口令，只有用户名时原样留着")
    func basicAuthSeparateArgument() {
        #expect(CommandLineRedaction.redact(arguments: ["curl", "-u", "audit:PASSWORD-here", "http://h/"])
                == ["curl", "-u", "audit:\(basic)", "http://h/"])
        #expect(CommandLineRedaction.redact(arguments: ["curl", "-u", "justuser"])
                == ["curl", "-u", "justuser"], "用户名是审计对象，这一格里没有凭据")
        #expect(CommandLineRedaction.redact(arguments: ["curl", "-u", ":PASSWORD-only"])
                == ["curl", "-u", basic], "冒号在前：没有可留的用户名，整格替换")
    }

    @Test("--password=x 掩值留键名；--password x 分写掩后面那一格")
    func passwordForms() {
        #expect(CommandLineRedaction.redact(Live.passwordScript)
                == "mysql --password=\(password) -h 127.0.0.1 -e 'select 1' ; sleep 4")
        #expect(CommandLineRedaction.redact(arguments: ["mysql", "--password", "Sup3rSecret", "-h", "127.0.0.1"])
                == ["mysql", "--password", password, "-h", "127.0.0.1"])
    }

    @Test("内联环境变量赋值：键名保留、值掩掉")
    func environmentAssignment() {
        #expect(CommandLineRedaction.redact(Live.envScript)
                == "AWS_SECRET_ACCESS_KEY=\(envValue) curl -sS http://127.0.0.1:9/ ; sleep 4")
    }

    @Test("URL 里的 userinfo 只掩口令；用户名与 host 留着")
    func urlUserInfo() {
        #expect(CommandLineRedaction.redact("curl https://ci-bot:s3cr3t-token@build.example.test/api")
                == "curl https://ci-bot:\(basic)@build.example.test/api")
    }

    // MARK: - 2. 具体形态优先于泛化赋值（重叠择优）

    @Test("KEY=sk-… 归 openai_key 而不是 env_file_value")
    func specificShapeWins() {
        #expect(CommandLineRedaction.redact("OPENAI_API_KEY=sk-ABCDEF012345")
                == "OPENAI_API_KEY=\(openAI)")
        #expect(CommandLineRedaction.markers(in: "OPENAI_API_KEY=sk-ABCDEF012345") == [.openAIKey])
    }

    @Test("AWS 键形态各归其类：AKIA… 是 access key，另一把走赋值")
    func awsShapes() {
        #expect(CommandLineRedaction.redact("aws --access-key-id AKIAIOSFODNN7EXAMPLE")
                == "aws --access-key-id ‹redacted:aws_access_key›")
        #expect(CommandLineRedaction.placeholder(for: .awsAccessKey) == "‹redacted:aws_access_key›")
    }

    // MARK: - 3. 不变式：参数个数与位置

    @Test("参数个数与顺序逐项保持，被掩的位置仍可数出来")
    func structurePreserved() {
        let original = ["curl", "-sS", "-H", "Authorization: Bearer sk-TEST123", "--max-time", "5", "http://h/"]
        let redacted = CommandLineRedaction.redact(arguments: original)
        #expect(redacted.count == original.count)
        for (index, pair) in zip(original, redacted).enumerated() {
            if pair.0 == pair.1 { continue }
            #expect(CommandLineRedaction.isRedacted(pair.1), "[\(index)] 只有该变的那格在变，且变成占位符")
            #expect(pair.1.hasPrefix("Authorization: Bearer "), "[\(index)] 键名与 scheme 必须在原位")
        }
        #expect(redacted[3] == "Authorization: Bearer \(openAI)")
        #expect(redacted[0] == "curl", "命令名是审计事实，一个字都不许动")
        #expect(!redacted.joined(separator: " ").contains("sk-TEST123"), "整条 argv 里不得残留凭据")
        #expect(CommandLineRedaction.redact(arguments: []) == [])
    }

    @Test("幂等：第二遍逐字符不变（四种形态各一次）")
    func idempotent() {
        for text in [Live.headerScript, Live.basicAuthScript, Live.passwordScript, Live.envScript] {
            let once = CommandLineRedaction.redact(text)
            #expect(CommandLineRedaction.redact(once) == once, "\(once)")
        }
        let arguments = ["curl", "-u", "audit:PASSWORD-here", "--password", "x1"]
        let once = CommandLineRedaction.redact(arguments: arguments)
        #expect(CommandLineRedaction.redact(arguments: once) == once)
    }

    @Test("含空元素时不外溢：--password 后面紧跟空串就什么都不掩")
    func emptyArgumentConsumesPending() {
        #expect(CommandLineRedaction.redact(arguments: ["mysql", "--password", "", "show", "databases"])
                == ["mysql", "--password", "", "show", "databases"])
    }

    // MARK: - 4. 不过掩（阴性）

    @Test("普通命令逐字符不动：flag 名里含 auth/key 子串也不算凭据")
    func doesNotOverMask() {
        for arguments in [
            ["swift", "test", "--filter", "auth"],
            ["git", "commit", "--author", "Jane <jane@example.test>"],
            ["git", "push", "origin", "ws/engaudit"],
            ["curl", "-sSL", "https://example.test/install.sh"],
            ["ssh", "-T", "git@github.com"],
            ["ls", "-la", "./DerivedData", "--time-style=long-iso"],
            ["python3", "-m", "pip", "install", "-r", "requirements.txt"],
        ] {
            #expect(CommandLineRedaction.redact(arguments: arguments) == arguments, "\(arguments)")
        }
    }

    @Test("`risk-level` / `task-id` 里的 sk- 与 k- 子串不算凭据")
    func substringPrefixNeedsBoundary() {
        #expect(CommandLineRedaction.redact("git log --grep=risk-framework --oneline")
                == "git log --grep=risk-framework --oneline")
        #expect(CommandLineRedaction.redact("task-identifier=abc") == "task-identifier=abc")
    }

    @Test("--key-path 与 --user=admin 不是凭据（名字与值都不掩）")
    func nameBoundaryCases() {
        #expect(CommandLineRedaction.redact("openssl enc --key-path ./keys/dev.pem")
                == "openssl enc --key-path ./keys/dev.pem")
        #expect(CommandLineRedaction.redact(arguments: ["curl", "--user", "admin", "http://h/"])
                == ["curl", "--user", "admin", "http://h/"])
    }

    // MARK: - 5. 中文 / emoji / 引号形状保持

    @Test("非 ASCII 参数不动；引号包住口令时掩引号内部、留引号本身")
    func unicodeAndQuotes() {
        #expect(CommandLineRedaction.redact(arguments: ["echo", "你好 — 🚀"]) == ["echo", "你好 — 🚀"])
        #expect(CommandLineRedaction.redact("--password=\"Sup 3rSec\"")
                == "--password=\"\(password)\"")
    }
}
