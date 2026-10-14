//
//  Page.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  页面骨架：每个板块的**唯一**外层容器。统一了四件以前各页自己凑的事：
//
//  1. 页面底色 `Surface.page`（旧版没有统一底，卡片直接坐在系统默认底上）；
//  2. 内容收口到 `Sizing.contentMaxWidth` 并居中（旧版宽窗口下把一行读数拉到两千多 pt）；
//  3. 统一的 32pt 安全边距与 32pt 板块间距（分隔靠留白，不靠线、不靠投影）；
//  4. 页面标题 28pt 一档，同时写进 `navigationTitle`——标题栏小字 + 内容大字
//     是 macOS 系统设置 / 邮件 的既有做法，不是重复。
//
//  【`Page.swift:53` 那一格：批 3 复核后**判不动**（#85 留案）】三条实测证据：
//    ① 两处读的是**同一个出处**（各页首参写死为 `SidebarSection.<x>.title`，
//       由 `SidebarNamingTests` 正向钉住、并反向禁掉页内任何字面量复述）——
//       #85 要杀的"同一句话两个写法"在这一格已经不成立，只剩"同一句话两个出口"。
//    ② `.navigationTitle` 是**窗口标题**的唯一来源，删掉它 UIProbe 的护栏当场失效：
//       `Tools/UIProbe/measure-pages.sh:90` 就靠窗口真显示的那串字判断实例落在哪一页
//       （曾经三页对不上就是缺陷）；用例 `SidebarNamingTests:203-206` 另钉着
//       "这一处之外，Page.swift 里不许有第二个窗口标题修饰符"。
//    ③ 反过来删页内 28pt 那一档，等于把 `Font.axPage`（"每个页面只允许一个"）
//       从层级里抽掉——那是 #79 首页信息架构的射程，不在本车道，也不该顺手做。
//  ⇒ 保留。真要让"两个出口"变成一个，前置条件是 `measure-pages.sh` 换判据，交总控排。
//
//
//  ⚠️ `.scrollContentBackground(.hidden)` 不是可选装饰：`ScrollView` 会自己铺一层背景，
//  它盖在 `.background(Surface.page)` 之上时页面底与面板底同为白色，
//  「靠一级背景差做分区」这条手法当场失效（2026-09-20 真机截图才看出来，用例全绿照样错）。
//

import SwiftUI

/// 板块页面骨架。
struct ObservatoryPage<Trailing, Content>: View where Trailing: View, Content: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing
    private let content: Content

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                PageHeader(title, subtitle: subtitle) { trailing }
                content
            }
            .frame(maxWidth: Sizing.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .background(Surface.page)
        .navigationTitle(title)
    }
}

/// 页面标题区：28pt 标题 + 13pt 说明 + 右侧操作。
struct PageHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.axPage)
                    .foregroundStyle(Surface.label)
                if let subtitle {
                    Text(subtitle)
                        .font(.axBody)
                        .foregroundStyle(Surface.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.md)
            if Trailing.self != EmptyView.self {
                trailing
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("ObservatoryPage 骨架") {
    ObservatoryPage("今日概览", subtitle: "2026-09-20 · 范围：今天") {
        Button("导出") {}
    } content: {
        Panel {
            MetricGrid(DemoRow.sample, columns: 4) { row in
                StatTile(title: row.title, value: row.value, emphasis: row.hero ? .hero : .metric)
            }
        }
        Panel {
            SectionHeader("一个板块")
                .padding(.bottom, Spacing.sm)
            Text("板块之间由 32pt 留白分隔，不画线、不加投影。")
                .font(.axBody)
                .foregroundStyle(Surface.secondaryLabel)
        }
    }
}

private struct DemoRow: Identifiable {
    let id: Int
    let title: String
    let value: String
    let hero: Bool

    static let sample: [DemoRow] = [
        .init(id: 0, title: "活跃总时长", value: "12h47m", hero: true),
        .init(id: 1, title: "今日文件变更", value: "26", hero: false),
        .init(id: 2, title: "执行命令", value: "2", hero: false),
        .init(id: 3, title: "高危事件", value: "0", hero: false),
    ]
}
