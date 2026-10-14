//
//  InteractiveFeedback.swift
//  AIObservatoryUI / DesignSystem
//
//  Owner: ws/feedback（批 3 最后一格 · #11 交互反馈一致性）
//  ─────────────────────────────────────────────────────────
//  **界面上"能点"这件事的唯一一份表达方式**（与 `Spacing`、`Column`、`Sizing` 同族）。
//
//  【治的病：可点与不可点只靠"有没有包 Button"区分】
//  改前实测（台账 `整改波次-2026-09-22` 第八节"明写未交付"第 1 条），
//  `Sources/AIObservatoryUI/` 里表达"可点"的写法有**四种**，反馈各有三种缺项：
//    · `.onTapGesture`        —— 会话行 / 文件行 / 命令行 / 项目卡（4 处）。
//      悬停无变化、按下无变化、**Tab 走不到**（不是控件）、光标始终是箭头。
//    · `.buttonStyle(.plain)` —— 首页带 action 的 `StatTile`、五页搜索框的"清除"、
//      风险行、时间线行（10 处）。有按下，**没有悬停**。
//    · `.hoverEffect` / `.onHover` —— **0 处**（全仓没人写过悬停档）。
//    · `.focusable` —— 1 处（会话列表容器，为了让 ↑/↓ 有落点）。
//  同一屏里四种写法并存的结果就是：读起来"这个能点、那个不能点"只能靠猜，
//  而猜错的成本是一次白点。
//
//  【口径（本格的需求原文："统一工具名称、表格对齐和交互反馈"的前三样已由 #82/#83/#84 交掉）】
//  **同样的可点样子、同样的一致反馈**——不是新增跳转出口（#81 已把六页跳转打通，那是既成事实），
//  也不改任何取数（台账裁定 5）。落成的样子只有两条：
//  ① 整块可点的那一族（读数格 / 列表行 / 卡片 / 搜索框里那颗"清除"）
//     一律走 `axPressable`：悬停抬一档、按下再抬一档、圆角取 `ObservatoryRadius.control`。
//  ② **不可点的读数块拿不到这一族**：`axPressable(when: nil)` 走的是"什么都不加"那一条分支，
//     于是"看起来不可点"不再是一句感觉，而是"这一族根本没接上"。
//
//  【为什么焦点环不在这里画】
//  focus-visible 这一档的做法是**让可点的东西成为真的 `Button`**——macOS 上只有真控件
//  才会拿到系统焦点环与"指针变成手型"这两件事，`.onTapGesture` 那两样一律拿不到
//  （这就是上面那四行里最差的一行：它连"我是个控件"都没说）。
//  在共用处理里再自绘一圈 = 造第二套焦点样式，与 quiet 基座（无新阴影、层级靠系统）相反。
//
//  【为什么系统样式那一大族不在这里】
//  `.bordered` / `.borderedProminent` / `.link` / `.borderless` / `Menu` / 分段 `Picker`
//  的悬停、按下、焦点三态**由 OS 画**，它们本来就共用同一份处理（同一套 AppKit 控件）。
//  把它们换成这里的自绘底，才是本格唯一能犯的"新造视觉语言"。
//  这一族只有一处需要动手：`EvidenceJumpChip` 那颗"清除"原先没写样式（= `.automatic`），
//  而 `.automatic` 在窗口 / 工具栏 / sheet 三种容器里会长成三种样子 —— 已在那一处显式写成 `.bordered`。
//
//  ⚠️ 两个档位的**相对关系**（按下必须严格比悬停深）由用例 `InteractionFeedbackTests` 数值闸钉住：
//  把它们调成同一个数 = 按下这一通道没有信息 = 退化回"点了不知道有没有反应"。
//

import SwiftUI

// MARK: - 反馈档位

/// 交互反馈的档位源。命名与 `Spacing` / `Column` 同族：只有语义，没有页名。
enum Feedback {
    /// 悬停底：指针停在可点块上时抬的那一级。
    ///
    /// 与 `Surface.page` / `Surface.recessed` 同一手法——**不写死灰值**：
    /// `Color.primary.opacity(...)` 在浅色下是黑、深色下自动是白，
    /// "抬一级"的方向在两套外观里都成立（写死的灰在深色下会方向反掉，
    /// 见 `ObservatoryTokens.swift:26-34` 那条实测）。
    /// 0.06 这一档是算出来的：它必须明显低于选中底
    /// （`Surface.selectedRow` 是系统语义色）才不抢"这一行被选中"这件事，
    /// 又必须高于 0 才看得见"指针确实停住了"。数值闸量的是这个次序。
    static let hoverTint = Color.primary.opacity(0.06)

    /// 按下底：比悬停再深一档。深多少不算审美——**按下必须严格深于悬停**，
    /// 相等就等于"按下去什么也没发生"，那正是这一族要治的病。
    static let pressTint = Color.primary.opacity(0.12)

    /// 反馈底 Shape 的圆角：直接取控件档，不另起一档。
    static let cornerRadius = ObservatoryRadius.control

    /// 悬停进出的时长。
    ///
    /// 不复用 `ObservatoryMotion.value`（0.25 s 是给**数值变化**的，读者要跟着数走）：
    /// 悬停是"指针停住了没有"这种即时确认，慢了读起来就是界面卡半拍。
    static let motion: Animation = .easeOut(duration: 0.12)
}

// MARK: - 共用处理

/// 整块可点的唯一按钮样式：悬停抬一档、按下再抬一档、焦点环交给系统。
///
/// 调用方只有一种写法：`Button { … } label: { … }.buttonStyle(.axPressable)`，
/// 或者连"有没有 action"都交给同一处判断的 `View.axPressable(when:)`。
struct AXPressableStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        AXPressableBody(configuration: configuration)
    }
}

/// 样式真正渲染的那一层。
///
/// `@State` 必须住在这里而不是 `ButtonStyle` 本体：`ButtonStyle` 不是 `DynamicProperty`，
/// 挂在它身上的状态会随样式重建而丢。
private struct AXPressableBody: View {

    let configuration: ButtonStyleConfiguration

    @State private var isHovered = false

    var body: some View {
        configuration.label
            // 命中区 = 整块矩形：没有这一句时"点得中"取决于这一行里哪几个字形停在指针下，
            // 于是同一张卡上有的区域能点、有的区域白点（`StatTile` 原先在**外面**补了这一句，
            // 现在收进来，五种落点共用同一份命中形状）。
            .contentShape(Rectangle())
            .background(tint, in: RoundedRectangle(cornerRadius: Feedback.cornerRadius,
                                                   style: .continuous))
            .onHover { isHovered = $0 }
            .animation(Feedback.motion, value: isHovered)
            .animation(Feedback.motion, value: configuration.isPressed)
            // 这里**不**管禁用态：本 SDK 的 `ButtonStyleConfiguration` 没有 `isDisabled`
            // （只有 `isPressed`），而现有 12 处消费者里没有一处是可禁用的整块可点元素。
            // 等真出现"禁用的行"那天再补这一档，而不是现在写一条读不到输入的死分支。
    }

    /// 三态里只有一层底：按下 > 悬停 > 无。选中底由调用方自己在**外面**再铺一层
    /// （`Surface.selectedRow` 在更下面，两者不互相顶掉）。
    private var tint: Color {
        if configuration.isPressed { return Feedback.pressTint }
        if isHovered { return Feedback.hoverTint }
        return Color.clear
    }
}

extension ButtonStyle where Self == AXPressableStyle {
    /// 「整块可点」的共用反馈（命名同 `.plain` / `.bordered` 那一批）。
    static var axPressable: AXPressableStyle { AXPressableStyle() }
}

// MARK: - 可点性判断收在调用点

extension View {
    /// 有 action 才排 `Button`，没有 action 就**什么都不加**。
    ///
    /// 这一条是 #11 的另一半：不可点的读数块要看起来不可点。
    /// 区分不是靠"给它一个更淡的颜色"，而是它拿不到悬停档、拿不到手型光标、
    /// 拿不到焦点环、也不会被 VoiceOver 念成"按钮"——四样一起缺，才是真的不可点。
    ///
    /// 原来这个形状只在 `StatTile` 内部有一份私有 `OptionalTap`，
    /// 于是四张列表行各写各的 `.onTapGesture`（永远可点，哪怕 action 是 nil）。
    ///
    /// - Important: `action` 为 nil 时这一格仍然保留调用方给它的 `contentShape`，
    ///   只是不再包控件——选中态、行高、列宽那些**外观以外**的东西一律不受影响。
    @ViewBuilder
    func axPressable(when action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) { self }
                .buttonStyle(.axPressable)
        } else {
            self
        }
    }
}

#Preview("整块可点 / 不可点 两份对照") {
    HStack(alignment: .top, spacing: Sizing.metricGutter) {
        StatTile(title: "可点：执行命令", value: "2", caption: "失败 0 次",
                 action: {})
        StatTile(title: "不可点：峰值内存", value: "267.8", unit: "MB")
    }
    .padding(Spacing.lg)
    .background(Surface.panel)
}
