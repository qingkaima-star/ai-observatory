// swift-tools-version: 6.2
//
//  Package.swift
//  AI Agent Activity Observatory
//
//  Owner: master-controller — 任何工作流需要新增 target 时，必须通过总控修改本文件。
//

import PackageDescription

let package = Package(
    name: "AIObservatory",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "AIObservatoryCore", targets: ["AIObservatoryCore"]),
        .library(name: "AIObservatoryStore", targets: ["AIObservatoryStore"]),
        .library(name: "AIObservatoryPlatform", targets: ["AIObservatoryPlatform"]),
        .library(name: "AIObservatoryEngine", targets: ["AIObservatoryEngine"]),
        .library(name: "AIObservatoryUI", targets: ["AIObservatoryUI"]),
        .library(name: "AIObservatoryRiskRules", targets: ["AIObservatoryRiskRules"]),
        .library(name: "AIObservatoryExport", targets: ["AIObservatoryExport"]),
        .library(name: "AIObservatoryInsights", targets: ["AIObservatoryInsights"]),
        .library(name: "AIObservatorySwiftDataStore", targets: ["AIObservatorySwiftDataStore"]),
        .library(name: "AIObservatoryTestSupport", targets: ["AIObservatoryTestSupport"]),
        .executable(name: "AIObservatory", targets: ["AIObservatoryApp"]),
        // #65：只读命令行，给 AI 自己查本机活动用（ICR-0012）。
        .executable(name: "aix", targets: ["aix"])
    ],
    targets: [
        // 冻结契约层：Domain 模型 + 协议 + 工具。无内部依赖。
        .target(
            name: "AIObservatoryCore",
            path: "Sources/AIObservatoryCore"
        ),

        // 本地持久化（SQLite + WAL）。Owner: WS-Engine
        .target(
            name: "AIObservatoryStore",
            dependencies: ["AIObservatoryCore"],
            path: "Sources/AIObservatoryStore"
        ),

        // 系统采集层：进程识别 / FSEvents / 性能采样 / 命令审计。
        // Owner 拆分：WS-Agent / WS-Files / WS-Telemetry
        .target(
            name: "AIObservatoryPlatform",
            dependencies: ["AIObservatoryCore"],
            path: "Sources/AIObservatoryPlatform"
        ),

        // 编排层：Session 生命周期、时间线聚合、项目地图、风险引擎。Owner: WS-Engine
        .target(
            name: "AIObservatoryEngine",
            dependencies: [
                "AIObservatoryCore", "AIObservatoryStore", "AIObservatoryPlatform",
                "AIObservatoryInsights", "AIObservatoryRiskRules",
            ],
            path: "Sources/AIObservatoryEngine"
        ),

        // SwiftUI 表现层（Liquid Glass / 8pt 栅格 / Swift Charts）。Owner: WS-UI
        .target(
            name: "AIObservatoryUI",
            dependencies: ["AIObservatoryCore"],
            path: "Sources/AIObservatoryUI"
        ),

        // 风险规则库：纯函数规则集合，输入 Core 模型产出风险候选。Owner: WS-Risk
        // 只依赖 Core，因此可与 WS-Engine 完全并行；Engine 稍后通过总控接入。
        .target(
            name: "AIObservatoryRiskRules",
            dependencies: ["AIObservatoryCore"],
            path: "Sources/AIObservatoryRiskRules"
        ),

        // 导出层：Session / 时间线 / 报告的 JSON、CSV、Markdown 序列化。Owner: WS-Export
        .target(
            name: "AIObservatoryExport",
            dependencies: ["AIObservatoryCore"],
            path: "Sources/AIObservatoryExport"
        ),

        // 分析层：项目活动地图、文件热度、异常检测、Agent 效率对比。Owner: WS-Insights
        .target(
            name: "AIObservatoryInsights",
            dependencies: ["AIObservatoryCore"],
            path: "Sources/AIObservatoryInsights"
        ),

        // SwiftData 后端：与 SQLite 后端实现同一套读写语义，可切换。Owner: WS-SwiftData
        // 需求同时点名 SwiftData 与 SQLite；ADR-0001 把 SwiftData 排到第二阶段。
        .target(
            name: "AIObservatorySwiftDataStore",
            dependencies: ["AIObservatoryCore"],
            path: "Sources/AIObservatorySwiftDataStore"
        ),

        // 测试与预览支撑：内存实现、样本数据工厂。Owner: master-controller（冻结）
        .target(
            name: "AIObservatoryTestSupport",
            dependencies: ["AIObservatoryCore"],
            path: "Sources/AIObservatoryTestSupport"
        ),

        // 可执行 App。Owner: master-controller（冻结外壳）
        .executableTarget(
            name: "AIObservatoryApp",
            dependencies: [
                "AIObservatoryCore",
                "AIObservatoryStore",
                "AIObservatoryPlatform",
                "AIObservatoryEngine",
                "AIObservatoryUI",
                "AIObservatoryExport",
                "AIObservatoryTestSupport"
            ],
            path: "Sources/AIObservatoryApp"
        ),

        // 命令行查询面：只读，复用 ObservatoryService + AIObservatoryExport。Owner: ws/cli
        // （ICR-0012 批准文本逐字落地；逻辑与 @main 分两个 target 是为了用例能直调
        //  `AixCommand.run(arguments:output:)` 拿退出码 + 字节流，测的是真命令面。）
        .target(
            name: "AIObservatoryCLI",
            dependencies: ["AIObservatoryCore", "AIObservatoryStore", "AIObservatoryExport"],
            path: "Sources/AIObservatoryCLI"
        ),

        // 薄壳：只有 @main，全部逻辑在 AIObservatoryCLI（可测的那半边）。Owner: ws/cli
        .executableTarget(
            name: "aix",
            dependencies: ["AIObservatoryCLI"],
            path: "Sources/AixExecutable"
        ),

        .testTarget(
            name: "AIObservatoryCoreTests",
            dependencies: ["AIObservatoryCore", "AIObservatoryTestSupport"],
            path: "Tests/AIObservatoryCoreTests"
        ),
        .testTarget(
            name: "AIObservatoryEngineTests",
            dependencies: ["AIObservatoryEngine", "AIObservatoryStore", "AIObservatoryExport", "AIObservatoryTestSupport"],
            path: "Tests/AIObservatoryEngineTests"
        ),
        .testTarget(
            name: "AIObservatoryPlatformTests",
            dependencies: ["AIObservatoryPlatform", "AIObservatoryCore", "AIObservatoryTestSupport"],
            path: "Tests/AIObservatoryPlatformTests"
        ),
        .testTarget(
            name: "AIObservatoryRiskRulesTests",
            dependencies: ["AIObservatoryRiskRules", "AIObservatoryCore", "AIObservatoryTestSupport"],
            path: "Tests/AIObservatoryRiskRulesTests"
        ),
        .testTarget(
            name: "AIObservatoryExportTests",
            dependencies: ["AIObservatoryExport", "AIObservatoryCore", "AIObservatoryTestSupport"],
            path: "Tests/AIObservatoryExportTests"
        ),
        .testTarget(
            name: "AIObservatoryInsightsTests",
            dependencies: ["AIObservatoryInsights", "AIObservatoryCore", "AIObservatoryTestSupport"],
            path: "Tests/AIObservatoryInsightsTests"
        ),
        .testTarget(
            name: "AIObservatorySwiftDataStoreTests",
            dependencies: [
                "AIObservatorySwiftDataStore", "AIObservatoryStore",
                "AIObservatoryCore", "AIObservatoryTestSupport",
            ],
            path: "Tests/AIObservatorySwiftDataStoreTests"
        ),

        // 表现层的可测部分：从 View 里抽出来的纯逻辑（排序口径、时间范围、格式化决策）。
        // 没有这个 target 之前，UI 的 70 个文件一条用例都没有，「算了但没用」这类缺陷抓不住。
        .testTarget(
            name: "AIObservatoryUITests",
            dependencies: ["AIObservatoryUI", "AIObservatoryCore", "AIObservatoryTestSupport"],
            path: "Tests/AIObservatoryUITests"
        ),

        // 组合根的决策逻辑：数据落在哪里（ADR-0003）与导出格式映射。
        // 这是隐私敏感的：判错就会把 SQLite 写到授权目录之外。
        .testTarget(
            name: "AIObservatoryAppTests",
            dependencies: ["AIObservatoryApp", "AIObservatoryCore", "AIObservatoryTestSupport"],
            path: "Tests/AIObservatoryAppTests"
        ),

        // 命令行的用例直调 `AixCommand.run(...)`：拿退出码 + 字节流，不靠起子进程。
        .testTarget(
            name: "AIObservatoryCLITests",
            dependencies: ["AIObservatoryCLI", "AIObservatoryCore", "AIObservatoryStore",
                           "AIObservatoryExport", "AIObservatoryTestSupport", "AIObservatoryApp"],
            path: "Tests/AIObservatoryCLITests"
        )
    ],
    swiftLanguageModes: [.v6]
)
