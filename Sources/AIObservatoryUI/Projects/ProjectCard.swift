//
//  ProjectCard.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-UI (subagent J)
//  ─────────────────────────────────────────────────────────
//  项目地图左栏的**一行**（不是卡片）：
//    · 第一行：项目名 +（有实时时）实时点 +（有风险时）风险标签 + 最近活动时间
//    · 第二行：FilePathText 路径 + 尾元信息（变更 / 命令 / 会话）
//    · 第三行：Agent 贡献条，4pt 高、圆角 `ObservatoryRadius.tag`
//  行间分隔由调用方（ProjectsView 的列表）插 `Hairline()`：本视图**无外框、无描边、无底色**，
//  选中态只有一层 `Surface.selectedRow`。旧版这里是「圆角卡 + 一层 accent 描边 + 六格计数网格」，
//  十几个这样的卡摞在左栏就是把整页读成「不规整、拥挤」的那只手。
//
//  Agent 身份用 `AgentChip` / 名字表达，**不按 Agent 上色**：贡献条只走有序灰阶。
//  卡片本身不查数据，只吃传入的 `ProjectActivity` 值，可独立 Preview。
//

import SwiftUI
import AIObservatoryCore

/// 一组项目路径的**行内标签**：末 N 段，N 从 2 起、只增到这一组里人人唯一为止。
///
/// 为什么必须有：真机截图上「项目活动地图」左列连着三行一模一样
/// （都显示 `work` + `AgentFixture/work`）。库里它们其实是三个不同项目，
/// 例如 `/Users/dev/Work/Audit/.worktrees/hang/Tools/AgentFixture/work` 与
/// `/Users/dev/Work/Audit/ai-observatory/Tools/AgentFixture/work`
/// ——末两段完全相同，区分段（`hang` / `ai-observatory`）被固定截掉了。
/// 固定截末两段是**按样本挑的深度**，换成"按这一组算深度"才能既短又可区分。
enum ProjectPathLabels {

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// - Returns: 路径 → 标签。同组内**互不相同**（除非两个项目路径本来就一样）。
    static func labels(for paths: [String]) -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        // 路径重复时保留第一条的切分（真实数据里 path 是项目身份，不该重复；
        // 用 uniquingKeysWith 而不是 uniqueKeysWithValues，避免这里反而崩掉）。
        let parts = Dictionary(
            paths.map { ($0, components(of: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        // 每条路径**各自**的段数上限，以及当前深度。
        var depth: [String: Int] = [:]
        for (path, components) in parts { depth[path] = min(2, max(1, components.count)) }
        // 只给「此刻仍然撞车」的那几条加深，别的停在原位。
        // 为什么不能整体抬：真机截图上加深后，本来末两段就唯一的
        // `.worktrees/mempeak` 也被拉成 `Documents/AiX/.worktrees/mempeak`——
        // 为一对撞车的路径把整列都写长，是把代价摊给了无关的行。
        while true {
            var labels: [String: String] = [:]
            for (path, components) in parts {
                labels[path] = components.isEmpty
                    ? path
                    : components.suffix(depth[path] ?? 2).joined(separator: "/")
            }
            let counts = labels.values.reduce(into: [:]) { tally, label in tally[label, default: 0] += 1 }
            let collided = labels.filter { (counts[$0.value] ?? 0) > 1 }.keys
            // 撞车者里还有能加深的就加深；全都到顶了就把当前结果交出去。
            let growable = collided.filter { path in
                guard let components = parts[path], let current = depth[path] else { return false }
                return current < components.count
            }
            guard !growable.isEmpty else { return labels }
            for path in growable { depth[path] = (depth[path] ?? 2) + 1 }
        }
    }
}

struct ProjectCard: View {

    let project: ProjectActivity
    /// #89：卡片正文的路径走 `FilePathText`（已掩），但**读屏那一句**是整句拼的，
    /// 里面躺着 `project.path` 的原文——耳朵是这条页面的另一张屏。
    @Environment(\.demoRedaction) private var demoRedaction
    /// 行内路径标签。由列表按**同组上下文**算好传进来（见 `ProjectPathLabels`）；
    /// `nil` 时退回旧的「末两段」——单独一张卡（预览、详情头）没有同组可分，退回是合理的。
    var pathLabel: String? = nil
    var isSelected: Bool = false
    var showsLiveActivity: Bool = false
    var onSelect: (() -> Void)?

    /// 几何常量（不是 padding）：贡献条高度。
    /// 4pt 足够读出比例；再高就和 11pt 的文字抢层级，一排卡片会变成一排色带。
    private static let barHeight: CGFloat = 4
    /// 贡献条最多画几段，剩下的折进「其他」，避免窄栏里碎成条纹。
    private static let barMaxSegments = 4

    init(project: ProjectActivity,
         pathLabel: String? = nil,
         isSelected: Bool = false,
         showsLiveActivity: Bool = false,
         onSelect: (() -> Void)? = nil) {
        self.project = project
        self.pathLabel = pathLabel
        self.isSelected = isSelected
        self.showsLiveActivity = showsLiveActivity
        self.onSelect = onSelect
    }

    private var language: AppLanguage { UILanguage.current }

    // MARK: - Body

    var body: some View {
        // 段与条宽在一次求值里算完：`segments` 是派生数组，读两次就是两个新身份。
        let segments = self.segments

        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(project.name)
                    .font(.axSection)
                    .foregroundStyle(Surface.label)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if showsLiveActivity {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .accessibilityLabel(ProjectsCopy.a11yLiveUpdate.text(language))
                }

                if project.sessionCount > 0 {
                    AgentChip(kind: dominantKind, compact: true)
                }

                Spacer(minLength: Spacing.sm)

                if project.riskEventCount > 0 {
                    // 风险是本页唯一保留彩色的地方（契约 §2）：一枚色点 + 计数，
                    // 回答的是「这个项目要不要现在点开」。
                    Tag(ProjectsCopy.riskCountTag.format(language, project.riskEventCount),
                        tone: ObservatoryTheme.tone(for: .high))
                }

                Text(ProjectTimeText.since(project.lastSeenAt))
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.tertiaryLabel)
                    .fixedSize()
                    .contentTransition(.opacity)
            }

            HStack(spacing: Spacing.sm) {
                FilePathText(path: project.path, label: pathLabel, mode: .lastTwoComponents)
                    .foregroundStyle(Surface.tertiaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(ProjectsCopy.cardMetrics.format(language, project.fileChangeCount,
                                                    project.commandCount, project.sessionCount))
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
                    .fixedSize()
            }

            contributionBar(segments)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Sizing.rowMinHeight)
        .background(
            isSelected ? Surface.selectedRow : Color.clear,
            in: RoundedRectangle(cornerRadius: ObservatoryRadius.control, style: .continuous)
        )
        .contentShape(Rectangle())
        // #11：与另外三张列表行同一份可点处理（原来是 `.onTapGesture`，无悬停、Tab 走不到）。
        .axPressable(when: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(segments))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - 贡献条

    /// 一条只编码比例：底色是 `Surface.recessed` 的下沉槽，填充段走有序灰阶。
    /// 没有任何贡献时也要把条画出来——否则有的项目两行、有的三行，左栏就歪了。
    private func contributionBar(_ segments: [ProjectShareSegment]) -> some View {
        GeometryReader { proxy in
            HStack(spacing: Spacing.none) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: segment.width(total: proxy.size.width))
                        .accessibilityHidden(true)
                }
                if segments.isEmpty {
                    Rectangle()
                        .fill(Surface.recessed)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: Self.barHeight)
        .clipShape(RoundedRectangle(cornerRadius: ObservatoryRadius.tag, style: .continuous))
        .accessibilityLabel(shareAccessibilityText(segments))
    }

    /// 贡献段：按事件数降序取前 3 位，其余合并成「其他」。
    ///
    /// 颜色取 `ObservatoryTheme.chartColor(rank: chartRank(for:))`——按 `AgentKind` 声明序，
    /// 所以同一个 Agent 在每一行里都是同一级灰，不随当前出现了哪几个 Agent 漂移。
    private var segments: [ProjectShareSegment] {
        let sorted = project.agentContributions.sorted { $0.eventCount > $1.eventCount }
        guard !sorted.isEmpty else { return [] }
        let total = max(0.0001, sorted.reduce(0) { $0 + $1.relativeShare })

        let head: [AgentContribution]
        let tail: [AgentContribution]
        if sorted.count > Self.barMaxSegments {
            head = Array(sorted.prefix(Self.barMaxSegments - 1))
            tail = Array(sorted.dropFirst(Self.barMaxSegments - 1))
        } else {
            head = sorted
            tail = []
        }

        var result: [ProjectShareSegment] = head.map { contribution in
            ProjectShareSegment(
                id: "kind:\(contribution.kind.rawValue)",
                color: ObservatoryTheme.chartColor(rank: ObservatoryTheme.chartRank(for: contribution.kind)),
                ratio: contribution.relativeShare / total
            )
        }
        if tail.isEmpty == false {
            let share = tail.reduce(0) { $0 + $1.relativeShare }
            result.append(ProjectShareSegment(
                // 合并段的 id 单独一档：`AgentContribution` 的身份由 kind 推导，
                // 真实存在 `unknown` 贡献时，借用它的 UUID 会让 `ForEach` 拿到两个相同 id。
                id: "merged",
                color: ObservatoryTheme.chartColor(rank: ObservatoryTheme.chartRank(for: .unknown)),
                ratio: share / total
            ))
        }
        return result
    }

    // MARK: - 文案

    private var dominantKind: AgentKind {
        project.agentContributions.max { $0.eventCount < $1.eventCount }?.kind ?? .unknown
    }

    private func shareAccessibilityText(_ segments: [ProjectShareSegment]) -> String {
        let language = UILanguage.current
        guard !segments.isEmpty else { return ProjectsCopy.shareNoData.text(language) }
        let total = max(0.0001, project.agentContributions.reduce(0) { $0 + $1.relativeShare })
        return ProjectsCopy.sharePrefix.text(language) + project.agentContributions
            .sorted { $0.eventCount > $1.eventCount }
            .prefix(Self.barMaxSegments)
            .map { "\(AgentNaming.name(kind: $0.kind, form: .compact, language)) \(PercentFormat.short($0.relativeShare / total * 100))" }
            .joined(separator: ProjectsCopy.a11yJoiner.text(language))
    }

    /// 无障碍摘要。**收 `segments` 入参而不是自己再算一遍**：`segments` 是派生数组，
    /// 一次渲染里读两遍就是两次数组构造 + 两次排序，而这一列的行数没有上限。
    private func accessibilitySummary(_ segments: [ProjectShareSegment]) -> String {
        demoRedaction.scrub(ProjectsCopy.cardA11ySummary.format(
            UILanguage.current,
            project.name,
            project.path,
            project.fileChangeCount,
            project.commandCount,
            project.sessionCount,
            project.riskEventCount,
            ProjectTimeText.since(project.lastSeenAt),
            shareAccessibilityText(segments)
        ))
    }
}

// MARK: - 贡献条的一段

/// 贡献条的一段。放在文件级而不是 `ProjectCard` 里面：
/// `View` 是 @MainActor 隔离的，嵌套类型会连带变成 main-actor 隔离，
/// 在派生属性里 `.map(Self.Segment.init)` 这类写法会吃到 #SendableMetatypes 警告。
private struct ProjectShareSegment: Identifiable {
    /// 身份用 kind 的 rawValue 而不是 `AgentContribution.id`：合并段与真实的 `unknown`
    /// 贡献会撞成同一个 UUID，`ForEach` 遇到重复 id 会直接丢一段条。
    let id: String
    let color: Color
    /// 0...1，相对本项目总占比。
    let ratio: Double

    /// 段宽：至少 1pt，否则极小的占比会画成看不见的 0 宽。
    func width(total: CGFloat) -> CGFloat {
        max(1, total * min(1, max(0, ratio)))
    }
}

// MARK: - Preview 样本

/// ProjectCard 独立预览用的样本值（不依赖 Shell / 服务，时间为固定值以便稳定复现）。
enum ProjectCardPreviewSamples {
    static let active = ProjectActivity(
        id: "/Users/demo/Projects/Mona",
        name: "Mona",
        path: "/Users/demo/Projects/Mona",
        fileChangeCount: 128,
        commandCount: 42,
        sessionCount: 9,
        riskEventCount: 2,
        codeGrowthLines: 3_420,
        codeShrinkLines: 980,
        agentContributions: [
            AgentContribution(kind: .claudeCode, relativeShare: 0.52, eventCount: 66),
            AgentContribution(kind: .openAICodex, relativeShare: 0.24, eventCount: 31),
            AgentContribution(kind: .cursorAgent, relativeShare: 0.14, eventCount: 18),
            AgentContribution(kind: .aiderCLI, relativeShare: 0.06, eventCount: 8),
            AgentContribution(kind: .windsurf, relativeShare: 0.04, eventCount: 5)
        ],
        firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_700_086_400)
    )

    static let idle = ProjectActivity(
        id: "/Users/demo/Projects/Aurora",
        name: "Aurora",
        path: "/Users/demo/Projects/Aurora",
        firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_060)
    )
}

#Preview("ProjectCard 状态") {
    VStack(alignment: .leading, spacing: Spacing.none) {
        ProjectCard(
            project: ProjectCardPreviewSamples.active,
            isSelected: true,
            showsLiveActivity: true
        )
        Hairline()
        ProjectCard(project: ProjectCardPreviewSamples.idle)
        Hairline()
        ProjectCard(project: ProjectCardPreviewSamples.active)
    }
    .padding(Spacing.sm)
    .frame(width: 360)
    .background(Surface.panel)
}
