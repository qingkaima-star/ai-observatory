//
//  SharedChartAxisAdoptionTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/axes（quiet 设计基座 · 门禁 2 的收口）
//  ─────────────────────────────────────────────────────────
//  `Scripts/gate-quiet-design.sh` 门禁 2 的判据是一行 grep：
//  「`Sources/AIObservatoryUI` 里出现挂轴动作的文件，去掉 `DesignSystem/ChartChrome.swift`
//   自己，命中数必须为零」。它在基点 `50df497` 上实测数到 **6**（台账裁定 12 因此把
//  EXIT=0 从批 1 的验收里挪走）。六处收完之后，这条判据第一次能绿——
//  而**没有任何 CI 引用那个脚本**（脚本自己就写着"没人跑的门禁等于没有门禁"）。
//  本文件把它变成跑在 `swift test` 里的用例，红绿由测试总线保证。
//
//  五条用例各钉一个方向，缺一个就会有一种"绿着退回去"的路：
//    ① 存量不许回来：共享件之外零挂轴动作（含注释——门禁就是纯 grep，注释也算命中）。
//    ② 采用率不许掉：六张图各自都从共享挂载点取轴。
//       只有①的话，"把轴整条删掉"也算过（gate 只数违规、不数采用），那正是
//       `04-决策记录/发现-quiet基座采用率…` 记着的那次教训：全绿却什么也没统一。
//    ③ 单位与轴种类不许漂：每张图挂的是哪一档、带哪个单位后缀，逐张钉
//       （实拍判据"刻度/单位读起来与改前一致"的代码侧对应物）。
//    ④ 共享实现本身不许被掏空：门禁 2 刻意不数 `ChartChrome.swift`，
//       于是"某一档分支不再挂轴"会让①绿得更彻底、屏上却少了轴。
//    ⑤ 小时轴的刻度白名单必须是常量：`axisHours` 是 `static let`，
//       改成每次 body 现造数组就会喂给 Charts 一个新身份（本仓实测 RSS 只涨不跌的反例）。
//
//  变异检查（每条都做过，改坏→恰好该红的红→Edit 精确改回）：
//    ①②③ 一起红：把 `ProjectContributionChart` 换回自己挂纵轴（offenders 列出该文件）。
//    只有③红：CPU 图 `x: .time` → `.category`（轴种类漂掉）。
//    只有④红：`ChartChrome` 无后缀那条分支不再挂轴。
//    只有⑤红：`axisHours` 从 `static let` 改成 `static var { … }`。
//

import Foundation
import Testing

private let sharedImplementation = "Sources/AIObservatoryUI/DesignSystem/ChartChrome.swift"

/// 六张走 Swift Charts 坐标轴的图（`ws/axes` 收口的名单）。
private let chartsWithAxes: [String] = [
    "Sources/AIObservatoryUI/Dashboard/DashboardHourlyActivityChart.swift",
    "Sources/AIObservatoryUI/Performance/PerformanceCPUGraph.swift",
    "Sources/AIObservatoryUI/Performance/PerformanceMemoryGraph.swift",
    "Sources/AIObservatoryUI/Performance/PerformanceDiskIOGraph.swift",
    "Sources/AIObservatoryUI/Performance/PerformanceNetworkGraph.swift",
    "Sources/AIObservatoryUI/Projects/ProjectContributionChart.swift",
]

@Suite("UI: 图表坐标轴只由共享件挂载", .timeLimit(.minutes(1)))
struct SharedChartAxisAdoptionTests {

    @Test("共享件之外零处挂轴动作（门禁 2 的可执行镜像）")
    func noAxesMountedOutsideChartChrome() throws {
        // 与 `Scripts/gate-quiet-design.sh` 同一把尺子：**整份文件**扫，不剥注释。
        // 剥注释会放行一种真实的退回路径——有人把挂轴写进注释旁边再"临时"打开。
        var offenders: [String] = []
        for file in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = try relativePath(of: file)
            guard relative != sharedImplementation else { continue }
            let text = try String(contentsOf: BilingualCopyGate.repoRoot().appending(path: relative),
                                  encoding: .utf8)
            let hits = ["chartXAxis", "chartYAxis"].filter { text.contains($0) }
            if hits.isEmpty == false {
                offenders.append("\(relative)：\(hits.joined(separator: "、"))")
            }
        }
        #expect(offenders.isEmpty, """
        这 \(offenders.count) 处又在自己文件里挂坐标轴了（门禁 2 会红）：
        \(offenders.joined(separator: "\n"))
        共享挂载点是 `View.observatoryAxes(x:ySuffix:)`；现有助手表达不了这根轴，
        就把表达加进 ChartChrome（它就是那份共享实现），不要把动作留在调用点。
        """)
    }

    @Test("六张图各自都从共享挂载点取轴（采用率不许掉）")
    func everyChartTakesTheSharedAxes() throws {
        var consumers = 0
        for chart in chartsWithAxes {
            let code = try BilingualCopyGate.codeOnlyString(chart)
            // 只认调用（`observatoryAxes(`），不认 `ObservatoryChart.valueAxis` 这类
            // "拿到轴但自己挂"的写法——那种正是本波收掉的东西。
            let calls = code.components(separatedBy: "observatoryAxes(").count - 1
            consumers += calls
            #expect(calls == 1, "\(chart) 从共享挂载点取轴的次数是 \(calls)，应为 1（0 = 又自己挂、或不挂）")
        }

        var total = 0
        for file in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = try relativePath(of: file)
            // 共享实现自己那条 `func observatoryAxes(…)` 是**声明**，不是消费者。
            if relative == sharedImplementation { continue }
            let code = try BilingualCopyGate.codeOnlyString(relative)
            total += code.components(separatedBy: "observatoryAxes(").count - 1
        }
        #expect(total == chartsWithAxes.count,
                """
                全 UI 的共享挂载点调用数是 \(total)，与名单里的 \(chartsWithAxes.count) 张不符 \
                ⇒ 有新图接上来了（把它加进本文件名单），或者有图掉出去了
                """)
        #expect(consumers == chartsWithAxes.count)
    }

    @Test("每张图挂的是哪一档轴、带哪个单位后缀（刻度不许在重构里漂掉）")
    func eachChartStillMountsTheAxisKindItHad() throws {
        // 期望值 = `ws/axes` 改前那六处 `.chart*Axis { … }` 的语义，逐张抄下来。
        // 判据用"挤掉全部空白后的包含"：换行与缩进不算漂移，档位与单位才算。
        let expectations: [String: [String]] = [
            "Sources/AIObservatoryUI/Performance/PerformanceCPUGraph.swift":
                ["x:.time,ySuffix:\"%\""],
            "Sources/AIObservatoryUI/Performance/PerformanceMemoryGraph.swift":
                ["x:.time,ySuffix:\"GB\""],
            "Sources/AIObservatoryUI/Performance/PerformanceDiskIOGraph.swift":
                ["x:.time,ySuffix:scale.suffix"],
            "Sources/AIObservatoryUI/Performance/PerformanceNetworkGraph.swift":
                ["x:.time,ySuffix:scale.suffix"],
            "Sources/AIObservatoryUI/Projects/ProjectContributionChart.swift":
                ["x:.category,ySuffix:\"%\""],
            // 首页柱图：横轴随桶档换（小时档白名单 / 日档整根收起），纵轴是不带单位的计数。
            "Sources/AIObservatoryUI/Dashboard/DashboardHourlyActivityChart.swift":
                ["x:usesDayBuckets?.hidden:.hours(Self.axisHours))"],
        ]
        for (file, wanted) in expectations.sorted(by: { $0.key < $1.key }) {
            let squeezed = try squeezedCode(of: file)
            for fragment in wanted {
                #expect(squeezed.contains(fragment),
                        "\(file) 的轴不再是这一档：找不到 \(fragment)\n\(squeezed)")
            }
        }
        // 首页柱图的纵轴必须**没有**单位后缀（那一列是事件计数，加个 "%" 就是假读数）。
        let hourly = try squeezedCode(
            of: "Sources/AIObservatoryUI/Dashboard/DashboardHourlyActivityChart.swift")
        #expect(!hourly.contains("hours(Self.axisHours),ySuffix:"),
                "首页柱图的计数轴被加上了单位后缀")
    }

    @Test("共享件真的把每一条轴挂上去（四档横轴 + 两档纵轴，一种不缺）")
    func sharedSurfaceStillAppliesEveryAxis() throws {
        // 门禁 2 刻意把 `ChartChrome.swift` 排除在计数之外 ⇒ 全仓**没有**别的东西看着这份
        // 共享实现本身。它一旦被掏空（只挂横轴、或者某一档分支不再挂），
        // ①那条"零命中"会绿得更彻底，而屏上的轴全掉了 —— 这条用例堵的就是这个洞。
        let chrome = try squeezedCode(of: sharedImplementation)
        let required = [
            "content.chartXAxis{ObservatoryChart.timeAxis}",
            "content.chartXAxis{ObservatoryChart.categoryAxis}",
            "content.chartXAxis{ObservatoryChart.hourAxis(hours:hours)}",
            "content.chartXAxis(.hidden)",
            "content.chartYAxis{ObservatoryChart.valueAxis(suffix:suffix)}",
            "content.chartYAxis{ObservatoryChart.valueAxis}",
        ]
        for application in required {
            #expect(chrome.contains(application), "共享件里少了这一条挂载：\(application)")
        }
        for kind in ["casetime", "casecategory", "casehours", "casehidden"] {
            #expect(chrome.contains(kind), "横轴少了一档：\(kind)")
        }
    }

    @Test("小时轴的刻度白名单还是那份常量（新数组会喂出 RSS 只涨不跌）")
    func hourTicksStayASharedConstant() throws {
        let hourly = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Dashboard/DashboardHourlyActivityChart.swift")
        #expect(hourly.contains("static let axisHours: [Int] = [0, 6, 12, 18, 23]"),
                """
                axisHours 不再是常量：每次 body 现造一个数组喂给 Charts，\
                会让它按身份重建内部状态（本仓实测 RSS 只涨不跌）
                """)
        let squeezed = try squeezedCode(
            of: "Sources/AIObservatoryUI/Dashboard/DashboardHourlyActivityChart.swift")
        #expect(squeezed.contains(".hours(Self.axisHours)"),
                "小时轴不再取那份常量，而是拿到别处现造的数组")
    }

    // MARK: - 小工具

    private func relativePath(of url: URL) throws -> String {
        let root = try BilingualCopyGate.repoRoot().path
        guard url.path.hasPrefix(root) else { throw AdoptionError.outsideRepo(url.path) }
        return String(url.path.dropFirst(root.count + 1))
    }

    /// 剥注释、跳预览块，再挤掉全部空白：只比"代码写了什么"，不比排版。
    private func squeezedCode(of relativeFile: String) throws -> String {
        try BilingualCopyGate.codeOnlyString(relativeFile)
            .split(whereSeparator: \.isWhitespace)
            .joined()
    }

    private enum AdoptionError: Error { case outsideRepo(String) }
}
