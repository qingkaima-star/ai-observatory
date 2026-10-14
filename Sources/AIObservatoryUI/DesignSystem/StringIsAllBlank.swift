//
//  StringIsAllBlank.swift
//  AIObservatoryUI / DesignSystem
//
//  Owner: WS-UI（uicopy · #46 / #49）
//  ─────────────────────────────────────────────────────────
//  「这个字符串值是不是等于没有」的唯一判法。
//
//  为什么要有这一条：上屏的每一个值都可能是空串**或一串空白**，而两者是同一件事——
//  #46 真机上那条空白监控根被原样铺出去，屏上留下两个空格，读起来像渲染坏了。
//  只判 `isEmpty` 拦不住空白；两处各自写一遍 trim 又会长成两把尺。
//

import Foundation

extension String {

    /// 空串，或只由空白字符组成。
    ///
    /// 用法是「**是**空白就要给占位／走空态」，不是「是空白就丢弃」——
    /// 丢弃会把一条真实存在的记录变成看不见，那比铺两个空格更糟。
    var isAllBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
