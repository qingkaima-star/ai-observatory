//
//  PerformanceCopy.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-l10nb（B3 最后三页 · 性能）
//  ─────────────────────────────────────────────────────────
//  性能页全部**用户可见**文案（含 Swift Charts 的 `.value(...)` 轴标签、`series` 的
//  数据域取值、`.accessibilityLabel`、`.help`），按 IFR 裁定 3(a) 集中声明成一份
//  `bilingualCopy`，门禁见 `PerformanceBilingualCopyGateTests`。
//
//  迁移口径同 `ShellCopy`/`TimelineCopy`（只迁进眼睛/读屏的字、中文侧逐字不动、
//  多参数 `%1$@`/`%2$d`、英文数量中性）。语言在 `UILanguage.current` 一处解析。
//
//  【这一页最贵的一条：判据④ 的口径句只换字面来源，不改拼接结构】
//  `SelfProcessOverheadCopy` 的三段（达标结论、窗口说明、口径分隔）与四格副标题，
//  是这一格存在的唯一理由——它要在界面内自证「空闲 CPU < 3%、常驻 < 200 MB」，
//  而"不是 RSS"、"需窗口 ≥60 秒才判"、"峰值只报不判"三条一旦翻错，英文态的读者就会
//  拿一个下界当峰值、或把 6.7% 的临时样本读成结论。所以：
//   · 达标结论仍按「CPU 一句 + 内存一句 + 三个可选追加片段」的形状拼
//     （片段前面那个空格是原样保留的，`SelfProcessGaugeTests` 逐字对账）；
//   · `%%` 两语言都写成 `%%`（`specs` 把它当转义，不当参数）；
//   · 单位一律用单复数同形的缩写（`s`/`MB`/`GB`），拼 "%d seconds" 就是 "1 seconds"。
//
//  【图例与 series 取值同源】`ChartLegend(label:)` 与 `series: .value("CPU 构成", "用户")`
//  必须是**同一条**文案：图例靠人眼把那根线对上一个名字，两处各自翻译就会在英文态
//  出现「线叫 User、图例叫 user」这种对不上的第二出处（本仓头号缺陷族）。
//
//  【`metric:` 参数是要吃语言的】`MetricAvailability.caption(metric:)` 拼的是
//  「这台机器拿不到<指标名>」，所以传进去的名字本身也得是当处语言的（`metricThermal` 等）。
//  英文侧那三个词故意小写：它们嵌在句子中间，不是标题。
//
//  ⚠️ 英文态仍混排的位置：`ObservatoryTimeRange.displayName`（已于 #67 接上语言参数）
//  ⇒ `scopeTitle` 的「· 今天」那半截在英文态还是中文。同 `ShellCopy` 文件头那条交回。
//

import Foundation
import AIObservatoryCore

/// 性能页的用户可见文案表（B3）。
enum PerformanceCopy {

    // MARK: 量词（英文没有对应物，理由见 `TimelineCopy.measureWord`）

    static func measureWord(_ chinese: String, _ language: AppLanguage) -> String {
        language == .chineseSimplified ? chinese : ""
    }

    /// 「N 个」这种纯量词位：中文留量词，英文只留数字。
    static func countedItems(_ value: Int, _ language: AppLanguage) -> String {
        language == .chineseSimplified ? "\(value) \(measureWord("个", language))" : "\(value)"
    }

    // MARK: 页头与三态

    static let lastSampled = LocalizedString(zh: "最近采样 %@", en: "Last sample %@")
    static let samplePointCount = LocalizedString(zh: "%d 个采样点", en: "Sample points: %d")
    static let loadingReading = LocalizedString(zh: "正在读取性能采样…", en: "Reading performance samples…")
    static let loadingFirstHint = LocalizedString(
        zh: "首次进入会拉取本范围内的整机与会话采样。",
        en: "On first entry this pulls the whole-machine and session samples for the current range."
    )
    static let emptyTitle = LocalizedString(zh: "还没有性能数据", en: "No performance data yet")
    /// 这句同时说明「GPU 只有近似值」与「读不到显示空态而不是 0」，英文必须两句都保住。
    static let emptyMessage = LocalizedString(
        zh: "观测引擎运行后，整机的 CPU、内存、磁盘 IO 与网络速率会按采样间隔持续写入，"
            + "这里会实时成形。GPU 只有整机近似值，温度与功耗取决于本机传感器是否可读——"
            + "读不到的项显示为空态而不是 0。",
        en: "Once the observatory engine runs, whole-machine CPU, memory, disk IO and network rates "
            + "are written on every sampling interval and this takes shape live. GPU is only a "
            + "whole-machine estimate, and temperature and power depend on whether this machine's "
            + "sensors are readable — an unreadable metric shows an empty state, never 0."
    )
    static let readFailed = LocalizedString(zh: "性能采样读取失败", en: "Failed to read performance samples")
    static let retry = LocalizedString(zh: "重试", en: "Retry")

    // MARK: 观测对象

    static let observeTarget = LocalizedString(zh: "观测对象", en: "Observation target")
    static let scopeSystem = LocalizedString(zh: "整机", en: "Whole machine")
    static let scopeSelectedSession = LocalizedString(zh: "所选会话", en: "Selected session")
    static let scopeSystemTitle = LocalizedString(zh: "整机 · %@", en: "Whole machine · %@")
    static let statVisibleSessions = LocalizedString(zh: "可见会话", en: "Visible sessions")

    // MARK: 瓷贴标题（整机 8 格 / 会话 4 格）

    static let tileCurrentCPU = LocalizedString(zh: "当前 CPU", en: "Current CPU")
    /// 整机与会话是两把尺子，caption 就是那把尺子的名字，不许省成一句漂亮话。
    static let heroCaptionSystem = LocalizedString(
        zh: "整机瞬时占用 · 非本 App 单进程",
        en: "Instantaneous whole-machine usage · not this app's single process"
    )
    static let heroCaptionSession = LocalizedString(
        zh: "所选会话的瞬时占用 · 含其子进程同一时刻求和",
        en: "Instantaneous usage of the selected session, summed with its child processes at the same instant"
    )
    static let tileCPUPeak = LocalizedString(zh: "峰值 CPU", en: "Peak CPU")
    static let tileMemoryPeak = LocalizedString(zh: "峰值内存", en: "Peak memory")
    static let tileSessionCPUPeak = LocalizedString(zh: "CPU 峰值", en: "CPU peak")
    static let tileSessionMemoryPeak = LocalizedString(zh: "内存峰值", en: "Memory peak")
    static let tileLoadAverage = LocalizedString(zh: "平均负载 (1m)", en: "Average load (1m)")
    static let tileGPUActivity = LocalizedString(zh: "GPU 活动（整机近似）", en: "GPU activity (whole machine)")
    static let tileNetworkDown = LocalizedString(zh: "网络 ↓", en: "Network ↓")
    static let tileNetworkUp = LocalizedString(zh: "网络 ↑", en: "Network ↑")
    static let tileThermal = LocalizedString(zh: "温度", en: "Temperature")
    static let tilePower = LocalizedString(zh: "功耗", en: "Power")
    static let tileSampleCount = LocalizedString(zh: "采样点数", en: "Sample count")
    static let tileObservedTime = LocalizedString(zh: "观测时长", en: "Observed time")

    // MARK: 瓷贴副标题

    /// 「区间均值」在整机与会话两个口径里是同一句话 ⇒ 一个出处。
    static let captionIntervalAverage = LocalizedString(zh: "区间均值 %@", en: "Interval mean %@")
    static let captionPhysicalTotal = LocalizedString(zh: "整机物理 %@", en: "Whole-machine physical %@")
    static let captionMemoryUsedPeak = LocalizedString(zh: "整机已用内存峰值", en: "Peak used memory on this machine")
    static let captionAwaitSystem = LocalizedString(zh: "等待整机采样", en: "Awaiting a whole-machine sample")
    static let captionSampleCap = LocalizedString(zh: "上限 %1$d，超出从头部裁剪",
                                                  en: "Cap %1$d, trimmed from the head")
    static let thermalHigh = LocalizedString(zh: "接近高负载温区", en: "Nearing the high-load temperature band")
    static let thermalMedium = LocalizedString(zh: "中等负载温区", en: "Medium-load temperature band")
    static let thermalNormal = LocalizedString(zh: "温区正常", en: "Temperature band normal")
    static let powerInstantEstimate = LocalizedString(zh: "整机瞬时估算值", en: "Whole-machine instantaneous estimate")
    static let networkPeakBoth = LocalizedString(zh: "峰值 ↓%1$@ · ↑%2$@", en: "Peak ↓%1$@ · ↑%2$@")
    static let networkRatesCaption = LocalizedString(zh: "整机下行 / 上行速率",
                                                     en: "Whole-machine down / up rate")
    /// 采样节奏的成句单位（`intervalText`）：秒的缩写两语言同形，躲开 "1 seconds"。
    static let intervalWholeSeconds = LocalizedString(zh: "%.0f 秒", en: "%.0f s")
    static let intervalFractionSeconds = LocalizedString(zh: "%.1f 秒", en: "%.1f s")

    // MARK: 曲线卡标题（`PerformanceChartStack`）

    static let chartMemoryTitle = LocalizedString(zh: "内存", en: "Memory")
    static let chartDiskTitle = LocalizedString(zh: "磁盘 IO", en: "Disk IO")
    static let chartNetworkTitle = LocalizedString(zh: "网络", en: "Network")
    static let chartPeakValue = LocalizedString(zh: "峰值 %@", en: "Peak %@")
    static let chartPhysicalSuffix = LocalizedString(zh: " / 物理 %@", en: " / physical %@")

    // MARK: 四张曲线（空态、轴标签、图例与读屏）

    static let cpuEmptyTitle = LocalizedString(zh: "暂无 CPU 采样", en: "No CPU samples yet")
    static let cpuEmptyMessage = LocalizedString(
        zh: "观测引擎启动后，这里会实时绘制整机或会话的 CPU 曲线。",
        en: "Once the observatory engine starts, this plots the whole-machine or session CPU curve live."
    )
    static let cpuUser = LocalizedString(zh: "用户", en: "User")
    static let cpuSystem = LocalizedString(zh: "系统", en: "System")
    static let axisTime = LocalizedString(zh: "时间", en: "Time")
    static let axisCPUTotal = LocalizedString(zh: "CPU 总计", en: "CPU total")
    static let axisShare = LocalizedString(zh: "占比", en: "Share")
    static let seriesCPUComposition = LocalizedString(zh: "CPU 构成", en: "CPU composition")
    static let seriesName = LocalizedString(zh: "序列", en: "Series")
    static let axisPeak = LocalizedString(zh: "峰值", en: "Peak")
    static let cpuA11y = LocalizedString(zh: "CPU 曲线，峰值 %@", en: "CPU curve, peak %@")
    static let memoryEmptyTitle = LocalizedString(zh: "暂无内存采样", en: "No memory samples yet")
    static let memoryEmptyMessage = LocalizedString(
        zh: "引擎运行后此处显示整机 / 会话的常驻内存曲线。",
        en: "After the engine runs, this shows the resident memory curve for the machine or a session."
    )
    static let memoryUsed = LocalizedString(zh: "已用内存", en: "Used memory")
    static let seriesUsed = LocalizedString(zh: "已用", en: "Used")
    static let axisPhysicalMemory = LocalizedString(zh: "物理内存", en: "Physical memory")
    static let physicalAnnotation = LocalizedString(zh: "物理 %@", en: "Physical %@")
    static let memoryA11y = LocalizedString(zh: "内存曲线，峰值 %@", en: "Memory curve, peak %@")
    static let diskEmptyTitle = LocalizedString(zh: "暂无磁盘 IO 采样", en: "No disk IO samples yet")
    static let diskEmptyMessage = LocalizedString(
        zh: "引擎运行后此处显示每秒读取 / 写入速率。",
        en: "After the engine runs, this shows the per-second read / write rate."
    )
    static let diskRead = LocalizedString(zh: "读取", en: "Read")
    static let diskWrite = LocalizedString(zh: "写入", en: "Write")
    static let axisRate = LocalizedString(zh: "速率", en: "Rate")
    static let axisDirection = LocalizedString(zh: "方向", en: "Direction")
    static let diskA11y = LocalizedString(zh: "磁盘 IO 曲线，峰值 %@", en: "Disk IO curve, peak %@")
    static let networkEmptyTitle = LocalizedString(zh: "暂无网络速率采样", en: "No network rate samples yet")
    static let networkDown = LocalizedString(zh: "下行", en: "Down")
    static let networkUp = LocalizedString(zh: "上行", en: "Up")
    static let networkA11y = LocalizedString(
        zh: "整机网络速率曲线，下行与上行峰值 %@",
        en: "Whole-machine network rate curve, down and up peak %@"
    )

    // MARK: 读数口径空态（`MetricAvailability`）

    static let awaitingSample = LocalizedString(zh: "等待首次采样", en: "Awaiting the first sample")
    static let unavailableOnThisMachine = LocalizedString(
        zh: "这台机器拿不到%@", en: "This machine cannot provide %@"
    )
    /// 这三个是**嵌在句中间**的指标名（英文侧因此小写），与瓷贴标题是不同用途的两串字。
    static let metricThermal = LocalizedString(zh: "温度", en: "temperature")
    static let metricPower = LocalizedString(zh: "功耗", en: "power")
    static let metricNetworkRate = LocalizedString(zh: "网络速率", en: "network rate")
    static let metricGPUActivity = LocalizedString(zh: "GPU 活动", en: "GPU activity")

    // MARK: 网络与 GPU 的显示口径（`PerformanceDisplay`）

    /// 「真 0」与「采不到」是两句不同的话，英文也不许合并成一句 "no data"。
    static let networkNoTraffic = LocalizedString(zh: "本轮区间整机没有流量",
                                                  en: "No traffic on this machine in this interval")
    static let networkIntervalPeak = LocalizedString(zh: "区间峰值 %@", en: "Interval peak %@")
    static let networkNoElapsed = LocalizedString(
        zh: "两次采样没有间隔，本轮差分不可信",
        en: "The two samples share one instant, so this interval's delta is not trustworthy"
    )
    static let networkCounterWrap = LocalizedString(
        zh: "网卡计数器回绕，本轮不取信（下一轮恢复）",
        en: "The NIC counter wrapped, so this interval is not trusted (recovers next round)"
    )
    static let networkInterfaceChanged = LocalizedString(
        zh: "网卡接口发生变化（重连/休眠），本轮不取信",
        en: "The NIC interface changed (reconnect / sleep), so this interval is not trusted"
    )
    static let networkNoColumn = LocalizedString(zh: "该行未记录网络速率",
                                                 en: "This row recorded no network rate")
    static let gpuWholeMachineOnly = LocalizedString(
        zh: "整机近似值，不归属任何 Agent 进程",
        en: "A whole-machine estimate, not attributed to any agent process"
    )

    // MARK: 会话明细（`PerformanceSessionBreakdown`）

    static let breakdownTitle = LocalizedString(zh: "会话性能明细", en: "Session performance detail")
    static let breakdownPickHint = LocalizedString(zh: "选择会话后可叠加单会话曲线",
                                                   en: "Pick a session to overlay its own curve")
    static let breakdownNotInList = LocalizedString(
        zh: "所选会话不在当前时间范围的列表里",
        en: "The selected session is not in the list for the current time range"
    )
    static let breakdownSessionFacts = LocalizedString(
        zh: "会话 %1$@ · 文件改动 %2$d · 命令 %3$d",
        en: "Session %1$@ · file changes %2$d · commands %3$d"
    )
    static let breakdownNoSessionTitle = LocalizedString(zh: "未选择会话", en: "No session selected")
    static let breakdownNoSessionMessage = LocalizedString(
        zh: "在上方「观测对象」里选择某个会话，即可看到它自己的 CPU / 内存曲线读数。",
        en: "Choose a session under Observation target above to see its own CPU and memory readings."
    )
    static let breakdownNoSamplesTitle = LocalizedString(zh: "该会话尚无性能采样",
                                                         en: "This session has no performance samples yet")
    static let breakdownNoSamplesMessage = LocalizedString(
        zh: "引擎每 %@ 采样一次；会话结束后仍可按时间范围回看。",
        en: "The engine samples every %@; a closed session can still be reviewed by time range."
    )
    /// 这句划的是「按会话有什么、没什么」的界，英文五项一个都不许掉。
    static let breakdownScopeNote = LocalizedString(
        zh: "按会话采集的只有 CPU 与内存（含其子进程同一时刻求和）。"
            + "磁盘、网络、GPU、温度、功耗没有按会话的读取口，因此这里不列——"
            + "它们只在「整机」口径下出现。",
        en: "Per-session sampling covers only CPU and memory (summed with child processes at the same "
            + "instant). Disk, network, GPU, temperature and power have no per-session read path, so "
            + "they are not listed here — they only appear under the whole-machine scope."
    )
    static let columnTime = LocalizedString(zh: "时刻", en: "Time")
    static let columnMemory = LocalizedString(zh: "内存", en: "Memory")
    /// 三个数各管一件事：版面截断、总条数、取数层上限（ICR-0007），英文也保持三个数分明。
    static let recentRowsNote = LocalizedString(
        zh: "仅显示最近 %1$d 条，共 %2$d 条采样（上限 %3$d）。",
        en: "Showing the %1$d most recent of %2$d in total (cap %3$d)."
    )
    static let sampleRowA11y = LocalizedString(zh: "采样 %1$@，CPU %2$@", en: "Sample %1$@, CPU %2$@")

    // MARK: 本 App 自身开销（判据④ · `SelfProcessOverheadPanel`）

    static let selfPanelTitle = LocalizedString(zh: "本 App 自身开销", en: "This app's own overhead")
    static let selfPanelSubtitle = LocalizedString(
        zh: "判据④ · 本进程 task_info + getrusage",
        en: "Criterion ④ · this process's task_info + getrusage"
    )
    static let selfTileCPU = LocalizedString(zh: "CPU（窗口值）", en: "CPU (windowed)")
    static let selfCPUCaption = LocalizedString(
        zh: "Δcputime ÷ 墙钟 · 只含本进程，不含子进程 · 预算 %@",
        en: "Δcputime ÷ wall clock · this process only, children excluded · budget %@"
    )
    static let selfTileFootprint = LocalizedString(zh: "常驻 phys_footprint", en: "Resident phys_footprint")
    /// 「不是 RSS」这条不许翻成 "not resident size" 之类的含糊话：同刻实测 RSS 189.6 MB
    /// 而 footprint 88.8 MB，读者拿错尺子就是这一格要防的事。
    static let selfFootprintCaption = LocalizedString(
        zh: "不是 RSS · 上限 %1$d MB · 目标 %2$d MB",
        en: "Not RSS · cap %1$d MB · target %2$d MB"
    )
    static let selfTileHeadroom = LocalizedString(zh: "对上限的余量", en: "Headroom to the cap")
    static let selfHeadroomCaption = LocalizedString(
        zh: "按末值；按窗口峰值只剩 %@%%",
        en: "By last reading; by window peak only %@%% left"
    )
    static let selfTilePeak = LocalizedString(zh: "窗口内峰值", en: "In-window peak")
    /// 英文侧短到能在一格的两行夹断里说完：上一版（88 字符）在真机英文态被截成
    /// "…a lower bound; pea…"，丢的正好是「只报不判」那半句 ⇒ 缩到 69 字符，
    /// 「下界」与「只报不判」两个事实都还在（"In-window peak" 这个标题已经带了 peak 主语）。
    static let selfPeakCaption = LocalizedString(
        zh: "两次采样之间的瞬时峰值读不到，这是下界；峰值只报不判",
        en: "Between-read peaks are unreadable: a lower bound, reported not judged."
    )
    static let selfPendingCPU = LocalizedString(zh: "等待接入本进程读数",
                                                en: "Awaiting this process's readings")
    static let selfNotRSS = LocalizedString(zh: "不是 RSS", en: "Not RSS")
    static let selfPendingHeadroom = LocalizedString(zh: "没有实测就不算余量",
                                                     en: "No headroom without a measurement")
    static let selfPendingPeak = LocalizedString(zh: "峰值只报不判", en: "Peaks reported, not judged")
    static let selfWaitingFirstReading = LocalizedString(
        zh: "已接入本进程读数，等待首个采样（两次读数最快隔 %@ 秒）。",
        en: "This process's readings are wired in, awaiting the first sample "
            + "(readings are at least %@ s apart)."
    )

    /// 窗口说明句。保持原拼接形状：`cadence` 那段仍然是「有平均节拍才追加」的可选片段，
    /// 括号、间隔与「末次读数在 … 前」的顺序都不动。
    static let selfWindowNote = LocalizedString(
        zh: "测量窗口 %1$@ → %2$@（%3$@ · %4$d 个读数%5$@，末次读数在 %6$@ 前）",
        en: "Measurement window %1$@ → %2$@ (%3$@ · readings %4$d%5$@, last reading %6$@ ago)"
    )
    static let selfCadenceFragment = LocalizedString(zh: " · 平均 %@ 秒一采",
                                                     en: " · averaging %@ s per sample")

    /// 达标结论两半 + 三个可选追加片段。片段**开头那个空格**是原样保留的：
    /// `SelfProcessGaugeTests` 逐字对账对到「。 需窗口 ≥60 秒才判。」这一格空格。
    static let selfVerdictCPU = LocalizedString(
        zh: "空闲 CPU 预算 %1$@：实测 %2$@%% → %3$@。",
        en: "Idle CPU budget %1$@: measured %2$@%% → %3$@. "
    )
    static let selfVerdictMemory = LocalizedString(
        zh: "常驻上限 %1$d MB：末值 %2$@ MB → %3$@。",
        en: "Resident cap %1$d MB: last value %2$@ MB → %3$@."
    )
    static let selfVerdictNeedsWindow = LocalizedString(
        zh: " 需窗口 ≥%d 秒才判。",
        en: " Needs a window of at least %d s to judge."
    )
    static let selfVerdictNoSystemSample = LocalizedString(
        zh: " 还没有整机采样，无法确认是否静默窗——CPU 这个数只作临时样本。",
        en: " No whole-machine sample yet, so a quiet window cannot be confirmed — this CPU figure "
            + "stays a provisional sample."
    )
    static let selfVerdictBusyMachine = LocalizedString(
        zh: " 本机负载 %@，不是静默窗——CPU 这个数只作临时样本，不进判定列。",
        en: " Machine load %@, not a quiet window — this CPU figure stays a provisional sample "
            + "and does not enter the verdict column."
    )
    /// 口径分隔句：同一页两套数字，缺这句就会复现「5.11 GB 像单进程」那种误读。
    static let selfScopeNote = LocalizedString(
        zh: "口径：这里是本 App 单进程（getrusage RUSAGE_SELF，不含子进程）。"
            + "上面整机与会话读数里，被观测 Agent 是它与子孙进程同一时刻的合计——两边不可互相加减。",
        en: "Scope: this panel is this app's single process (getrusage RUSAGE_SELF, children excluded). "
            + "The whole-machine and session readings above attribute an observed agent to it plus its "
            + "descendants summed at the same instant — the two sides cannot be added or subtracted."
    )
    static let selfNotInstrumentedNote = LocalizedString(
        zh: "界面尚未接入本进程读数：目标值仍是硬指标（空闲 CPU < %1$@、常驻 < %2$d MB、"
            + "期望 < %3$d MB），但这一格现在没有实测——仪器在 AIObservatoryPlatform 已就绪，"
            + "缺的是把它交给界面的那一条装配（ICR-0003）。",
        en: "The interface is not wired to this process's readings yet: the targets are still hard "
            + "limits (idle CPU < %1$@, resident < %2$d MB, expected < %3$d MB), but this panel has no "
            + "measurement right now — the instrument is ready in AIObservatoryPlatform, and what is "
            + "missing is the one assembly that hands it to the interface (ICR-0003)."
    )

    // MARK: 达标结论标签（`SelfProcessVerdict`）

    static let verdictWindowForming = LocalizedString(zh: "窗口仅 %d 秒，暂不判定",
                                                      en: "Window only %d s — no verdict yet")
    static let verdictWithinBudget = LocalizedString(zh: "在预算内", en: "within budget")
    static let verdictOverBudget = LocalizedString(zh: "超预算", en: "over budget")

    // MARK: page 组文案（2 条，key 前缀 page.*）
    static let pageCopy: [NamedCopy] = [
        NamedCopy("performance.page.lastSampled", lastSampled),
        NamedCopy("performance.page.samplePointCount", samplePointCount),
    ]

    // MARK: state 组文案（2 条，key 前缀 state.*）
    static let stateCopy: [NamedCopy] = [
        NamedCopy("performance.state.loadingReading", loadingReading),
        NamedCopy("performance.state.loadingFirstHint", loadingFirstHint),
    ]

    // MARK: empty 组文案（2 条，key 前缀 empty.*）
    static let emptyCopy: [NamedCopy] = [
        NamedCopy("performance.empty.title", emptyTitle),
        NamedCopy("performance.empty.message", emptyMessage),
    ]

    // MARK: error 组文案（2 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        NamedCopy("performance.error.readFailed", readFailed),
        NamedCopy("performance.error.retry", retry),
    ]

    // MARK: scope 组文案（5 条，key 前缀 scope.*）
    static let scopeCopy: [NamedCopy] = [
        NamedCopy("performance.scope.observeTarget", observeTarget),
        NamedCopy("performance.scope.system", scopeSystem),
        NamedCopy("performance.scope.selectedSession", scopeSelectedSession),
        NamedCopy("performance.scope.systemTitle", scopeSystemTitle),
        NamedCopy("performance.scope.visibleSessions", statVisibleSessions),
    ]

    // MARK: tile 组文案（15 条，key 前缀 tile.*）
    static let tileCopy: [NamedCopy] = [
        NamedCopy("performance.tile.currentCPU", tileCurrentCPU),
        NamedCopy("performance.tile.heroCaptionSystem", heroCaptionSystem),
        NamedCopy("performance.tile.heroCaptionSession", heroCaptionSession),
        NamedCopy("performance.tile.cpuPeak", tileCPUPeak),
        NamedCopy("performance.tile.memoryPeak", tileMemoryPeak),
        NamedCopy("performance.tile.sessionCPUPeak", tileSessionCPUPeak),
        NamedCopy("performance.tile.sessionMemoryPeak", tileSessionMemoryPeak),
        NamedCopy("performance.tile.loadAverage", tileLoadAverage),
        NamedCopy("performance.tile.gpuActivity", tileGPUActivity),
        NamedCopy("performance.tile.networkDown", tileNetworkDown),
        NamedCopy("performance.tile.networkUp", tileNetworkUp),
        NamedCopy("performance.tile.thermal", tileThermal),
        NamedCopy("performance.tile.power", tilePower),
        NamedCopy("performance.tile.sampleCount", tileSampleCount),
        NamedCopy("performance.tile.observedTime", tileObservedTime),
    ]

    // MARK: caption 组文案（13 条，key 前缀 caption.*）
    static let captionCopy: [NamedCopy] = [
        NamedCopy("performance.caption.intervalAverage", captionIntervalAverage),
        NamedCopy("performance.caption.physicalTotal", captionPhysicalTotal),
        NamedCopy("performance.caption.memoryUsedPeak", captionMemoryUsedPeak),
        NamedCopy("performance.caption.awaitSystemSample", captionAwaitSystem),
        NamedCopy("performance.caption.sampleCap", captionSampleCap),
        NamedCopy("performance.caption.thermalHigh", thermalHigh),
        NamedCopy("performance.caption.thermalMedium", thermalMedium),
        NamedCopy("performance.caption.thermalNormal", thermalNormal),
        NamedCopy("performance.caption.powerInstant", powerInstantEstimate),
        NamedCopy("performance.caption.networkPeakBoth", networkPeakBoth),
        NamedCopy("performance.caption.networkRates", networkRatesCaption),
        NamedCopy("performance.caption.intervalWholeSeconds", intervalWholeSeconds),
        NamedCopy("performance.caption.intervalFractionSeconds", intervalFractionSeconds),
    ]

    // MARK: chart 组文案（5 条，key 前缀 chart.*）
    static let chartCopy: [NamedCopy] = [
        NamedCopy("performance.chart.memoryTitle", chartMemoryTitle),
        NamedCopy("performance.chart.diskTitle", chartDiskTitle),
        NamedCopy("performance.chart.networkTitle", chartNetworkTitle),
        NamedCopy("performance.chart.peakValue", chartPeakValue),
        NamedCopy("performance.chart.physicalSuffix", chartPhysicalSuffix),
    ]

    // MARK: cpu 组文案（4 条，key 前缀 cpu.*）
    static let cpuCopy: [NamedCopy] = [
        NamedCopy("performance.cpu.emptyTitle", cpuEmptyTitle),
        NamedCopy("performance.cpu.emptyMessage", cpuEmptyMessage),
        NamedCopy("performance.cpu.user", cpuUser),
        NamedCopy("performance.cpu.system", cpuSystem),
    ]

    // MARK: axis 组文案（8 条，key 前缀 axis.*）
    static let axisCopy: [NamedCopy] = [
        NamedCopy("performance.axis.time", axisTime),
        NamedCopy("performance.axis.cpuTotal", axisCPUTotal),
        NamedCopy("performance.axis.share", axisShare),
        NamedCopy("performance.axis.peak", axisPeak),
        NamedCopy("performance.axis.rate", axisRate),
        NamedCopy("performance.axis.direction", axisDirection),
        NamedCopy("performance.axis.physicalMemory", axisPhysicalMemory),
        NamedCopy("performance.axis.memoryUsed", memoryUsed),
    ]

    // MARK: series 组文案（3 条，key 前缀 series.*）
    static let seriesCopy: [NamedCopy] = [
        NamedCopy("performance.series.cpuComposition", seriesCPUComposition),
        NamedCopy("performance.series.name", seriesName),
        NamedCopy("performance.series.used", seriesUsed),
    ]

    // MARK: cpu2 组文案（1 条，key 前缀 cpu.*）
    static let cpu2Copy: [NamedCopy] = [
        NamedCopy("performance.cpu.a11y", cpuA11y),
    ]

    // MARK: memory 组文案（4 条，key 前缀 memory.*）
    static let memoryCopy: [NamedCopy] = [
        NamedCopy("performance.memory.emptyTitle", memoryEmptyTitle),
        NamedCopy("performance.memory.emptyMessage", memoryEmptyMessage),
        NamedCopy("performance.memory.physicalAnnotation", physicalAnnotation),
        NamedCopy("performance.memory.a11y", memoryA11y),
    ]

    // MARK: disk 组文案（5 条，key 前缀 disk.*）
    static let diskCopy: [NamedCopy] = [
        NamedCopy("performance.disk.emptyTitle", diskEmptyTitle),
        NamedCopy("performance.disk.emptyMessage", diskEmptyMessage),
        NamedCopy("performance.disk.read", diskRead),
        NamedCopy("performance.disk.write", diskWrite),
        NamedCopy("performance.disk.a11y", diskA11y),
    ]

    // MARK: network 组文案（4 条，key 前缀 network.*）
    static let networkCopy: [NamedCopy] = [
        NamedCopy("performance.network.emptyTitle", networkEmptyTitle),
        NamedCopy("performance.network.down", networkDown),
        NamedCopy("performance.network.up", networkUp),
        NamedCopy("performance.network.a11y", networkA11y),
    ]

    // MARK: availability 组文案（2 条，key 前缀 availability.*）
    static let availabilityCopy: [NamedCopy] = [
        NamedCopy("performance.availability.awaitingSample", awaitingSample),
        NamedCopy("performance.availability.unavailable", unavailableOnThisMachine),
    ]

    // MARK: metric 组文案（4 条，key 前缀 metric.*）
    static let metricCopy: [NamedCopy] = [
        NamedCopy("performance.metric.thermal", metricThermal),
        NamedCopy("performance.metric.power", metricPower),
        NamedCopy("performance.metric.networkRate", metricNetworkRate),
        NamedCopy("performance.metric.gpuActivity", metricGPUActivity),
    ]

    // MARK: network2 组文案（6 条，key 前缀 network.*）
    static let network2Copy: [NamedCopy] = [
        NamedCopy("performance.network.noTraffic", networkNoTraffic),
        NamedCopy("performance.network.intervalPeak", networkIntervalPeak),
        NamedCopy("performance.network.noElapsed", networkNoElapsed),
        NamedCopy("performance.network.counterWrap", networkCounterWrap),
        NamedCopy("performance.network.interfaceChanged", networkInterfaceChanged),
        NamedCopy("performance.network.noColumn", networkNoColumn),
    ]

    // MARK: gpu 组文案（1 条，key 前缀 gpu.*）
    static let gpuCopy: [NamedCopy] = [
        NamedCopy("performance.gpu.wholeMachineOnly", gpuWholeMachineOnly),
    ]

    // MARK: breakdown 组文案（13 条，key 前缀 breakdown.*）
    static let breakdownCopy: [NamedCopy] = [
        NamedCopy("performance.breakdown.title", breakdownTitle),
        NamedCopy("performance.breakdown.pickHint", breakdownPickHint),
        NamedCopy("performance.breakdown.notInList", breakdownNotInList),
        NamedCopy("performance.breakdown.sessionFacts", breakdownSessionFacts),
        NamedCopy("performance.breakdown.noSessionTitle", breakdownNoSessionTitle),
        NamedCopy("performance.breakdown.noSessionMessage", breakdownNoSessionMessage),
        NamedCopy("performance.breakdown.noSamplesTitle", breakdownNoSamplesTitle),
        NamedCopy("performance.breakdown.noSamplesMessage", breakdownNoSamplesMessage),
        NamedCopy("performance.breakdown.scopeNote", breakdownScopeNote),
        NamedCopy("performance.breakdown.columnTime", columnTime),
        NamedCopy("performance.breakdown.columnMemory", columnMemory),
        NamedCopy("performance.breakdown.recentRowsNote", recentRowsNote),
        NamedCopy("performance.breakdown.sampleRowA11y", sampleRowA11y),
    ]

    // MARK: self 组文案（24 条，key 前缀 self.*）
    static let selfCopy: [NamedCopy] = [
        NamedCopy("performance.self.panelTitle", selfPanelTitle),
        NamedCopy("performance.self.panelSubtitle", selfPanelSubtitle),
        NamedCopy("performance.self.tileCPU", selfTileCPU),
        NamedCopy("performance.self.cpuCaption", selfCPUCaption),
        NamedCopy("performance.self.tileFootprint", selfTileFootprint),
        NamedCopy("performance.self.footprintCaption", selfFootprintCaption),
        NamedCopy("performance.self.tileHeadroom", selfTileHeadroom),
        NamedCopy("performance.self.headroomCaption", selfHeadroomCaption),
        NamedCopy("performance.self.tilePeak", selfTilePeak),
        NamedCopy("performance.self.peakCaption", selfPeakCaption),
        NamedCopy("performance.self.pendingCPU", selfPendingCPU),
        NamedCopy("performance.self.notRSS", selfNotRSS),
        NamedCopy("performance.self.pendingHeadroom", selfPendingHeadroom),
        NamedCopy("performance.self.pendingPeak", selfPendingPeak),
        NamedCopy("performance.self.waitingFirstReading", selfWaitingFirstReading),
        NamedCopy("performance.self.windowNote", selfWindowNote),
        NamedCopy("performance.self.cadenceFragment", selfCadenceFragment),
        NamedCopy("performance.self.verdictCPU", selfVerdictCPU),
        NamedCopy("performance.self.verdictMemory", selfVerdictMemory),
        NamedCopy("performance.self.verdictNeedsWindow", selfVerdictNeedsWindow),
        NamedCopy("performance.self.verdictNoSystemSample", selfVerdictNoSystemSample),
        NamedCopy("performance.self.verdictBusyMachine", selfVerdictBusyMachine),
        NamedCopy("performance.self.scopeNote", selfScopeNote),
        NamedCopy("performance.self.notInstrumentedNote", selfNotInstrumentedNote),
    ]

    // MARK: verdict 组文案（3 条，key 前缀 verdict.*）
    static let verdictCopy: [NamedCopy] = [
        NamedCopy("performance.verdict.windowForming", verdictWindowForming),
        NamedCopy("performance.verdict.withinBudget", verdictWithinBudget),
        NamedCopy("performance.verdict.overBudget", verdictOverBudget),
    ]

    /// 本目录全部用户可见文案。**门禁用例遍历它断言 `copyProblems` 为空**。
    static let bilingualCopy: [NamedCopy] =
        pageCopy
        + stateCopy
        + emptyCopy
        + errorCopy
        + scopeCopy
        + tileCopy
        + captionCopy
        + chartCopy
        + cpuCopy
        + axisCopy
        + seriesCopy
        + cpu2Copy
        + memoryCopy
        + diskCopy
        + networkCopy
        + availabilityCopy
        + metricCopy
        + network2Copy
        + gpuCopy
        + breakdownCopy
        + selfCopy
        + verdictCopy

}
