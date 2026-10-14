//
//  B3PluralRulerCalibrationTests.swift
//  AIObservatoryUITests
//
//  Owner: 总控（B3 三份门禁共用的复数尺子）
//  ─────────────────────────────────────────────────────────
//  `siUnitExemptions` 一放宽，三页门禁会同时变绿——所以豁免必须有一把**反向**的尺子钉住：
//  光看「页面绿了」证明不了还在抓真复数。这里用手推字面量把两个方向都写死。
//

import Testing

struct B3PluralRulerCalibrationTests {

    private func trapped(_ english: String) -> Bool {
        B3PageCopyGate.pluralTrapRanges(in: english) != nil
    }

    @Test("豁免之后仍然抓真复数（否则这把尺子等于没有）")
    func stillCatchesRealPlurals() {
        let copies = [
            "%1$d sessions",          // 会话数：一条会话时露馅
            "%d readings",            // 性能页的「读数」
            "at least %@ seconds",     // 拼全的单位 = 允许 "1 seconds"
            "Shows %d windows",       // 窗口数
            "averaging %@ minutes",   // 分钟是拼全的，不是缩写
        ]
        #expect(copies.count == 5, "校准清单被改动了")
        for copy in copies {
            #expect(trapped(copy), "这条该判成陷阱却放行了：\(copy)")
        }
    }

    @Test("单复数同形的单位缩写不算陷阱")
    func exemptsInvariableUnits() {
        let legal = [
            "readings are at least %@ s apart",
            "%d ms",
            "averaging %@ s per sample",
            "%@ µs per tick",
            "%d ns",
        ]
        #expect(legal.count == 5, "校准清单被改动了")
        for copy in legal {
            #expect(!trapped(copy), "合法写法被误伤：\(copy)")
        }
    }

    @Test("豁免表只有这四个缩写（加词要在牌上说明理由）")
    func exemptionListIsExactlyThese() {
        #expect(B3PageCopyGate.siUnitExemptions == ["s", "ms", "µs", "ns"])
    }

    @Test("三种免复数写法照常放行：名词前置 / 形容词后置 / 无说明符")
    func pluralFreeFormsStayGreen() {
        #expect(!trapped("Sessions: %1$d"))
        #expect(!trapped("%1$d active"))
        #expect(!trapped("100%% of samples"))
    }
}
