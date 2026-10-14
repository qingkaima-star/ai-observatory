//
//  PathFilterTests.swift
//  AIObservatoryPlatformTests — FileSystem
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  PathFilter 单测：默认忽略规则、追加规则不重复累积默认规则、自身数据库目录（自激抑制）、
//  以及**不误伤**——本工作流的测试 scratch 根目录必须可被观测，否则端到端测试全是假阴性。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryTestSupport

@Suite("WS-Files: 路径忽略过滤")
struct PathFilterTests {

    /// 测试一律显式注入 databasePaths，避免依赖真实家目录（`defaultDatabasePaths` 会读盘）。
    private func filter(_ additional: [String] = [], db: [String] = ["/var/db/obs"]) -> PathFilter {
        PathFilter(additionalPatterns: additional, databasePaths: db)
    }

    @Test("默认规则：目录型与文件名型规则都命中")
    func defaultRulesMatch() {
        let f = filter()
        #expect(f.shouldIgnore("/proj/node_modules/foo/index.js"))
        #expect(f.shouldIgnore("/proj/.build/debug/out.swift"))
        #expect(f.shouldIgnore("/proj/DerivedData/ModuleCache/x.module"))
        #expect(f.shouldIgnore("/proj/notes.tmp"))
        #expect(f.shouldIgnore("/proj/.git/objects/pack/abc"))
        #expect(!f.shouldIgnore("/proj/Sources/main.swift"))
    }

    @Test("默认规则：目录内部任意深层级都命中")
    func deepDescendantsMatch() {
        let f = filter()
        #expect(f.shouldIgnore("/a/b/node_modules/p/q/r/s.js"))
        #expect(f.shouldIgnore("/a/b/.build/arm64-apple-macosx/debug/Derived/Sources/x.swift"))
        #expect(f.shouldIgnore("/home/u/proj/.git/objects/6a/6f70c2"))
        #expect(f.ignoredPatterns == PathFilter.defaultIgnoredPatterns, "未追加规则时不应改变模式集合")
    }

    @Test("追加规则生效且 ignoredPatterns 不重复累积默认规则")
    func additionalPatternsDoNotDuplicateDefaults() {
        let f = filter(["vendor/"])
        #expect(f.shouldIgnore("/proj/vendor/acme/lib.js"))
        #expect(f.ignoredPatterns.count == PathFilter.defaultIgnoredPatterns.count + 1)

        // appending 只追加「追加规则」，默认规则不翻倍（这是 FSEventsWatcher 里重复叠加的根因）。
        let grown = f.appending(["tmp-local/"])
        #expect(grown.additionalPatterns == ["vendor/", "tmp-local/"])
        #expect(grown.ignoredPatterns.count == PathFilter.defaultIgnoredPatterns.count + 2)
        #expect(grown.shouldIgnore("/proj/tmp-local/cache.bin"))
        #expect(grown.databasePaths == ["/var/db/obs"], "appending 必须保留 databasePaths")
    }

    @Test("自激抑制：自身数据库目录内被忽略，兄弟路径不受影响")
    func selfDatabaseSuppression() {
        let f = filter(db: ["/var/db/obs", FixturePaths.appSupport])
        #expect(f.shouldIgnore("/var/db/obs/store.db"))
        #expect(f.shouldIgnore("\(FixturePaths.appSupport)/wal/x.log"))
        #expect(f.shouldIgnore("/var/db/obs"))          // 目录本身
        // 前缀必须是完整路径分量边界：同前缀的兄弟目录不能被误杀。
        #expect(!f.shouldIgnore("/var/db/observed/app.txt"))
        #expect(!f.shouldIgnore("/var/db/obsx/store.db"))
    }

    @Test("不误伤：本工作流测试 scratch 根目录必须可被观测")
    func testScratchRootIsNotIgnored() {
        let f = filter()
        let root = Scratch.path()
        #expect(!f.shouldIgnore(root))
        #expect(!f.shouldIgnore("\(root)/files-e2e-ABC/note.txt"))
        #expect(!f.shouldIgnore("\(root)/files-created-UUID/sub/deep/file.swift"))
        #expect(!f.shouldIgnore(Scratch.path("store.db")))
    }

    @Test("不误伤：相似但不同的名字不得命中规则")
    func lookalikesAreNotIgnored() {
        let f = filter()
        #expect(!f.shouldIgnore("/proj/BuildTool/output.swift"))       // ≠ DerivedData / .build
        #expect(!f.shouldIgnore("/proj/sub.build/x.swift"))            // ≠ .build
        #expect(!f.shouldIgnore("/proj/a.git/objectsX/f"))             // ≠ .git/objects
        #expect(!f.shouldIgnore("/proj/src/tmpfile"))                  // ≠ *.tmp
        #expect(!f.shouldIgnore("/proj/node_modules_backup/x.js"))    // ≠ node_modules
        #expect(!f.shouldIgnore("/proj/.buildkit/config.yaml"))       // ≠ .build
    }

    @Test("规则归一化：尾部斜杠与缺失斜杠等价，`pattern/*` 覆盖子树")
    func patternNormalization() {
        #expect(PathFilter.defaultIgnoredPatterns.contains(".build/"))
        let withSlash = filter(["cache/"], db: [])
        let withoutSlash = filter(["cache"], db: [])
        for path in ["/p/cache", "/p/cache/a", "/p/cache/a/b/c"] {
            #expect(withSlash.shouldIgnore(path) == withoutSlash.shouldIgnore(path), "路径 \(path) 行为不一致")
        }
        #expect(withSlash.shouldIgnore("/p/cache/a/b/c"))
    }

    @Test("通配符规则：*.tmp 只匹配后缀形态，且规则里的 `?` 可用")
    func wildcardSemantics() {
        let f = filter(["*.log", "a?c"], db: [])
        #expect(f.shouldIgnore("/p/access.log"))
        #expect(f.shouldIgnore("/p/deep/dir/other.log"))
        #expect(!f.shouldIgnore("/p/log/access.txt"))
        #expect(f.shouldIgnore("/p/abc"))
        #expect(!f.shouldIgnore("/p/ac"))
    }

    @Test("空路径与畸形路径不崩溃且默认不忽略")
    func degeneratePaths() {
        let f = filter()
        #expect(!f.shouldIgnore(""))
        #expect(!f.shouldIgnore("///"))
        #expect(!f.shouldIgnore("relative/path/main.swift"))
        #expect(f.shouldIgnore("node_modules/x.js"), "相对路径同样按分量匹配")
    }

    @Test("`~` 形态路径能匹配到展开后的数据库前缀")
    func tildeExpansion() {
        let f = filter(db: ["~/Library/Application Support/com.aix.aiobservatory"])
        #expect(f.shouldIgnore("~/Library/Application Support/com.aix.aiobservatory/store.db"))
        let expanded = NSString(string: "~/Library/Application Support/com.aix.aiobservatory").expandingTildeInPath
        #expect(f.shouldIgnore(expanded + "/store.db"))
    }
}
