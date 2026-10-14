//
//  ObservatoryStore+ObservatoryWriting.swift
//  AIObservatoryStore
//
//  Owner: master-controller
//
//  SQLite 后端对写侧契约的 conformance——只有声明，没有任何实现改动：
//  API 名字与签名本来就是按这套写的，缺的只是把它写成协议。
//  有了这一行，「切换后端」这件事才可能在 Core 层表达（见 Core/Contracts/StoreProtocols.swift）。
//

import AIObservatoryCore

extension ObservatoryStore: ObservatoryWriting {}
