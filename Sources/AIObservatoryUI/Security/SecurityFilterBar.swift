//
//  SecurityFilterBar.swift
//  AIObservatoryUI / Security
//
//  Owner: WS-UI (subagent D) → WS-QUIET-3（本轮按 ADR-0007 重排到「quiet」语言）
//  职责：风险过滤条 —— 级别多选 / 类别多选 / 只看未确认 / 搜索 / 重置，（时间范围在顶栏，理由写在 categoryMenu 上方）
//        全部真实写回 RiskQuery。
//
//  等级多选以前是 `SecurityLevelChip`：自己画一层 `RoundedRectangle.stroke`，
//  未选中时用一档自造灰（深色模式下是一块死灰），
//  选中时又叠 `Color.accentColor.opacity(0.16)` 底色——一条过滤控件三层装饰，
//  四个等级并排就是四个小按钮，这正是「拥挤」。
//  现在交给系统的 `.bordered` 按钮，选中与否由**图标**（checkmark / circle）表达，
//  不依赖颜色，也不需要我们画边框。
//

import SwiftUI
import AIObservatoryCore

struct SecurityFilterBar: View {
    private var language: AppLanguage { UILanguage.current }
    @Bindable var model: SecurityModel

    var body: some View {
        // 四个等级的条数只算**一遍**再往下传。
        // 写成 `levelCounts[level, …]` 直接放在 ForEach 里的话，
        // 每个等级都会重新触发一次这个计算属性（四个等级 = 四趟数组）。
        let counts = levelCounts
        Panel(padding: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionHeader(
                    SecurityCopy.filterTitle.text(language),
                    subtitle: SecurityCopy.filterSubtitle.text(language)) {
                    if model.isFiltering {
                        Button(SecurityCopy.reset.text(language)) { model.resetFilters() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }

                HStack(spacing: Spacing.sm) {
                    searchField
                    categoryMenu
                    Spacer(minLength: Spacing.none)
                    Toggle(SecurityCopy.unacknowledgedOnly.text(language), isOn: $model.query.unacknowledgedOnly)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.axBody)
                }

                Hairline()

                HStack(spacing: Spacing.sm) {
                    Text(SecurityCopy.levelTitle.text(language))
                        .font(.axLabel)
                        .foregroundStyle(Surface.secondaryLabel)
                    ForEach(RiskLevel.allCases) { level in
                        SecurityLevelChip(
                            level: level,
                            isOn: model.query.levels.contains(level),
                            count: counts[level, default: 0]
                        ) {
                            model.toggle(level: level)
                        }
                    }
                    Spacer(minLength: Spacing.none)
                    Text(SecurityCopy.hitOfTotal.format(language, model.events.count, model.totalCount))
                        .font(.axMeta)
                        .monospacedDigit()
                        .axCaptionStyle()   // #99：承载口径，曾在最低档
                }
            }
        }
    }

    /// 四个等级的条数**一趟**算完。
    ///
    /// 以前是四个 `model.events.filter { $0.level == level }.count`，
    /// 每个等级各过一遍数组；这四个数加总还必须等于已加载条数，
    /// 分成四处算就没有任何一处能看出它们对不对得上。
    private var levelCounts: [RiskLevel: Int] {
        var counts: [RiskLevel: Int] = [:]
        for event in model.events { counts[event.level, default: 0] += 1 }
        return counts
    }

    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.axMeta)
                .foregroundStyle(Surface.tertiaryLabel)
            TextField(SecurityCopy.searchPrompt.text(language), text: $model.query.searchText)
                .textFieldStyle(.plain)
                .font(.axBody)
                .frame(minWidth: 140, maxWidth: 260)
            if !model.query.searchText.isEmpty {
                Button {
                    model.query.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.axMeta)
                        .foregroundStyle(Surface.tertiaryLabel)
                }
                .buttonStyle(.axPressable)   // #11：搜索框里那颗「清除」与全站同一份悬停/按下档
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Surface.recessed, in: RoundedRectangle(cornerRadius: ObservatoryRadius.control, style: .continuous))
    }

    /// 这里**没有**「时间范围」控件：顶栏 `ToolbarContent.timeRangeMenu` 已经是它的唯一入口。
    /// 同一页放两个范围选择器 = 同一个状态两个入口，而且过滤条这个只写 `model.range`、
    /// 不回写 `shell.timeRange` ⇒ 顶栏显示「今天」、列表却按「近 6 小时」查，谁也不报错。
    /// 范围现在单向由 shell 同步进来，见 `SecurityView` 的 `.onChange(of: shell?.timeRange)`。
    private var categoryMenu: some View {
        Menu {
            ForEach(RiskCategory.allCases) { category in
                Toggle(isOn: categoryBinding(category)) {
                    Label(category.displayName, systemImage: category.sfSymbolName)
                }
            }
            Divider()
            Button(SecurityCopy.clearCategories.text(language)) { model.query.categories = [] }
        } label: {
            Text(model.query.categories.isEmpty ? SecurityCopy.categoriesTitle.text(language)
                    : SecurityCopy.categoriesCount.format(language, model.query.categories.count))
                .font(.axBody)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func categoryBinding(_ category: RiskCategory) -> Binding<Bool> {
        Binding(
            get: { model.query.categories.contains(category) },
            set: { isOn in
                guard isOn != model.query.categories.contains(category) else { return }
                model.toggle(category: category)
            }
        )
    }
}

// MARK: - Level chip

/// 等级多选：系统 `.bordered` 按钮 + 状态图标，选中与否不靠颜色也不靠描边。
struct SecurityLevelChip: View {
    private var language: AppLanguage { UILanguage.current }
    let level: RiskLevel
    let isOn: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("\(level.displayName) \(count)", systemImage: isOn ? "checkmark.circle.fill" : "circle")
                .font(.axMeta)
                .monospacedDigit()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(SecurityCopy.levelCountA11y.format(language, level.displayName, count))
    }
}

#Preview("SecurityFilterBar") {
    SecurityFilterBarPreview()
        .frame(width: 760)
        .padding(Spacing.xl)
        .background(Surface.page)
}

/// 只为 Preview 服务：装载演示运行时后展示过滤条的真实形态。
private struct SecurityFilterBarPreview: View {
    @State private var model: SecurityModel

    init() {
        _model = State(initialValue: SecurityModel(runtime: ObservatoryPreview.runtime()))
    }

    var body: some View {
        SecurityFilterBar(model: model)
            .task { await model.load() }
    }
}
