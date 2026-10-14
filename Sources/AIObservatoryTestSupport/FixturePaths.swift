//
//  FixturePaths.swift
//  AIObservatoryTestSupport
//
//  合成宿主目录布局的唯一出处。
//
//  为什么需要它：大量用例要写「某个项目路径」「家目录下的某个文件」这类字面量，
//  它们从头到尾只参与字符串比较、从不落盘。此前这些值被写成真实开发机的
//  `/Users/<用户名>/…`，于是本机目录布局被固化进公开产物——`make-public-release.sh`
//  自检② 就是为拦这个而存在（它数一切命中，**包括注释**）。
//
//  三条路径来源不可互换，选错会让用例静默失去意义：
//   1. 只参与比较/归属推导的路径 → 本文件的合成值；
//   2. 需要真的在这台机器上创建目录或文件的路径 → `Scratch.directory(...)` / `Scratch.path(...)`
//      （它落在当前检出自带的 `.scratch-tests/`，CI runner 上同样成立）；
//   3. 断言对象就是「当前用户的家目录」本身的路径（例如「直接落在家目录根 ⇒ 禁写」
//      这类依赖 `NSHomeDirectory()` / `homeDirectoryForCurrentUser` 的策略判定）
//      → 继续用 `NSHomeDirectory()`，换成合成值会让该分支不再被覆盖。
//
//  改夹具时的硬约束：只换**宿主前缀**，尾巴上的语义原样保留——中文、空格、引号、
//  emoji、大小写往往正是被测对象。同一文件内同一逻辑路径的所有书写形态
//  （混合大小写原值、为全文检索准备的小写副本、SQL 字面量里的转义形态）必须同步换，
//  否则比较两侧不再相等，用例会假通过。
//

import Foundation

/// 合成宿主目录布局。所有「不落盘」夹具路径一律从这些常量派生。
public enum FixturePaths {

    /// 合成家目录。断言里需要 `/Users/…` 形态时用它的派生值，不要写真实用户名。
    public static let home = "/Users/dev"

    /// 合成工作区父目录：前缀匹配类用例需要一个「能圈住两个兄弟项目」的前缀。
    public static let work = "/Users/dev/Work"

    /// 合成项目 A：工作区下的第一个兄弟项目。
    public static let projectAlpha = "/Users/dev/Work/Alpha"

    /// 合成项目 B：与 A 同前缀但互不包含，用于「命中 A 不应连带命中 B」。
    public static let projectBeta = "/Users/dev/Work/Beta"

    /// 合成「被观察的项目根」：项目归属推导、按项目分组、报表标题这类用例的根。
    public static let projectRoot = "/Users/dev/Projects/AiX"

    /// 合成「写入根之外」的路径：形状上像只读知识库，语义上只要求不在 allowedRoots 内。
    public static let outsideAllowedRoot = "/Users/dev/ReadOnlyVault/console"

    /// 合成 app 支持目录：自激抑制用例要「库目录本身被忽略，同前缀兄弟路径不被误杀」。
    public static let appSupport = "/Users/dev/Library/Application Support/com.aix.aiobservatory"

    /// 家目录下的相对路径。分隔符由本函数负责，调用方不要再拼 `/`。
    public static func inHome(_ relative: String) -> String {
        "\(home)/\(relative)"
    }

    /// 被观察项目根下的相对路径。
    public static func inProjectRoot(_ relative: String) -> String {
        "\(projectRoot)/\(relative)"
    }
}
