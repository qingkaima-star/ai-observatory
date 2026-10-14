//
//  AttributionGapWiring.swift
//  AIObservatoryUI / Files
//
//  Owner: WS-UI（uicopy · #54 / ICR-0009 界面那一半）
//  ─────────────────────────────────────────────────────────
//  把「未归属机制分布」这个读数取到界面手里。整个文件只做一件事，
//  因为这一条路是**临时桥**，将来要被删——留一个具名位置，换桥才是一行的事。
//
//  【为什么是桥而不是正门】正门的形状仓里有先例：`ObservatoryRuntime.monitoringScope`
//  （`Contracts/Runtime.swift:30`）由装配根 `AIObservatoryApp.swift:109` 把引擎递进来，
//  界面只读 `runtime.monitoringScope?.currentMonitoringScope()`（`FilesModel.swift:174`）。
//  ICR-0009 要的是同一个位置再挂一个 `attributionGap`——但 `Core/Contracts/**` 与
//  `Sources/AIObservatoryApp/**` 都是 §3 冻结区，本车道只能改 `Sources/AIObservatoryUI/**`。
//
//  【这座桥的失效模式，以及为什么它不会静默说谎】
//  `runtime.service as? AttributionGapReporting` 在今天的装配里必然成功
//  （`AIObservatoryApp.swift:102` 传的就是那个 `ObservatoryEngine` 实例本身，没有包装）。
//  它会在什么时候变成 nil？有人给 `service` 套一层装饰器、或换掉组合根。
//  那时那一格会说「本次运行尚无归属读数」——**那是一句假话**（读数其实有，只是没接上）。
//  ⇒ 所以本文件配两条用例：
//    · `bridgeFollowsARealEngine`：真引擎实例经这座桥必须取到读数（证明今天通）；
//    · `compositionRootStillHandsTheServiceToTheUI`：扫装配根，`service:` 那一项必须还是裸 `engine`
//      （一旦被包装，这条先红，而不是等界面说一句假话）。
//  桥被 `Runtime.attributionGap` 取代后，这两条用例一起删——**不要只删桥留用例**，
//  那会留下一个断言"装配根不许包装 service"的无主约束。
//

import Foundation
import AIObservatoryCore

/// 未归属读数的取用点。见文件头。
enum AttributionGapWiring {

    /// 从运行时取出「未归属机制分布」的提供方；`nil` = 这个宿主没有这个能力。
    static func reporter(_ runtime: ObservatoryRuntime) -> (any AttributionGapReporting)? {
        runtime.service as? (any AttributionGapReporting)
    }
}
