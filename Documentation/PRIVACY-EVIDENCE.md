# PRIVACY-EVIDENCE · `Resources/PrivacyInfo.xcprivacy` 的代码证据

- **Owner**：WS-Packaging / 子代理 B
- **清单文件**：`Resources/PrivacyInfo.xcprivacy`（50 行，`plutil -lint` = OK）
- **取证范围**：`Sources/` 全树，127 个 `.swift` 文件（含 `AIObservatoryTestSupport/`）
- **本文所有 `Sources/...` 路径**相对于**工作树根**（你检出的那个目录本身，不写绝对路径）
- **一致性基准**：`AGENTS.md` §7（全本地存储、禁止网络上传、环境变量白名单）、
  `ADR-0003`（数据库落盘位置）、`Documentation/PRIVACY.md` §2/§5/§6

> 本文件的编写纪律：**没有真实调用点的类别一律不写**；**无法向 Apple 文档核实理由码的
> 一律不写**，改为在 §4 列为待办。因此本清单声明项很少，但每一条都可核。

---

## 0. 结论摘要

| 项 | 结论 |
| --- | --- |
| 已声明的 required-reason 类别 | **1 个**：`NSPrivacyAccessedAPICategorySystemBootTime` → `35F9.1`（码串有旁证、码的**官方语义原文未取到**，见 §1.1 坦白框与 §4-3） |
| 有真实调用点、但因理由码无法核实而**故意未声明** | 2 类：进程信息族（libproc / `sysctl(KERN_PROCARGS2)`）、动态 API 族（`dlopen`/`dlsym`） |
| 检查过且**代码里根本不存在**调用点 | 文件时间戳族、磁盘空间族、活动键盘族 |
| `NSPrivacyTracking` | `false`（全树 0 个网络调用点，见 §1.2） |
| `NSPrivacyTrackingDomains` | 空数组（同上，无可声明域名） |
| `NSPrivacyCollectedDataTypes` | 空数组 —— 理由见 §1.3，**不是**漏写 |
| 清单能否进入 `.app` | **能**，但只经一条路径：唯一打包入口 `Packaging/make-app.sh` 第 3/6 步把它拷进 `Contents/Resources/`（实测包内 lint 通过）。`Package.swift` 仍无 `resources:` ⇒ **不走该脚本的产物没有清单**（裸可执行、Xcode 直接 Build）。见 §5-A |

---

## 1. 已声明项 → 调用点 → 理由码

### 1.1 `NSPrivacyAccessedAPICategorySystemBootTime` → `35F9.1`

| # | 调用点 | 表达式 |
| --- | --- | --- |
| 1 | `Sources/AIObservatoryPlatform/AgentDetection/LibprocProcessInspector.swift:76` | `let wallNow = DispatchTime.now().uptimeNanoseconds` |
| 1b | 同上 `:173-175` → `:196-214` | `wallNow` 作为 `computeCPUPercent(pid:cumulativeNanos:wallNow:)` 的入参，与缓存的上一次采样时刻相减得 `dWall` |

**一句话理由**：本应用只用单调计时的**差值**（`dWall = wallNow - prev.wallNanos`，
`LibprocProcessInspector.swift:207`）来计算「自上次进程采样以来经过了多少时间」，
进而得出进程 CPU 占用率；这是「用系统启动时刻计算某个事件以来的时间间隔」这一
`35F9.1` 语义的直接命中，绝对启动时刻本身不被记录、不被上报、也不用于跨启动关联设备。

**声明的保守性说明**：`uptimeNanoseconds` 的语义是「自开机起的纳秒数」，
因此它按构造就会泄露系统启动时刻——这正是 Apple 把 uptime 族归入本类别的原因。

> **核实程度的坦白**：本清单采用 `35F9.1` 的依据是「该码串被两个独立二级来源
> 归到 System boot time 类别下，且它们链向 Apple 本页锚点 `#4278394`」（见 §6 Tier B）。
> **`35F9.1` 对应的官方措辞原文我并没有取到**，因此上面那句
> 「计算自某事件以来经过的时间」是**我对该码语义的推断**，不是逐字引用。
> 该推断与代码事实自洽（我们确实只在算时间差），但打包前应由人打开
> Apple 页面确认该码的原文确实涵盖「计时/求差」用途，而不是某种更窄的场景；
> 若原文比这更窄或语义不符，**删掉本条声明**，见 §4-3。

本条属**宁可多报**（over-declaration）方向：风险是「声明了一类其实没这么用的 API」，
不会造成误用被隐瞒。若复核认定 `DispatchTime` 不属于该族、或 `35F9.1` 语义不符，
删除本条即可，不影响清单其余部分的正确性。

### 1.2 为什么 `NSPrivacyTracking = false` 且 `NSPrivacyTrackingDomains` 为空

对 `Sources/` 全树搜索网络出口符号：
`URLSession`、`NSURLConnection`、`Socket`、`Network.`、`NWConnection`、`CFStream`、
`CFHost`、`getaddrinfo`、`socket(`、`connect(`、`request(` —— **命中数 0**。

唯一带「Network」字样的实现是
`Sources/AIObservatoryPlatform/Telemetry/NetworkCounters.swift:115` 的
`getifaddrs(&ifa)` + `:127-128` 读 `if_data.ifi_ibytes/ifi_obytes` + `:116` `freeifaddrs(ifa)`，
这是**读本机网卡累计计器的纯本地 syscall 遍历，不产生任何报文**。
（与 `Documentation/PRIVACY.md` §2.1、§2.3 的结论一致。）
⚠️ 2026-09-20 更正：这段自本日起**确实会被执行**（`HostMetricsSampler.swift:28,46` 已接线），
但「不联网」的结论不变——它没有 `socket(` / `connect(` / 任何出口符号，行号也全部漂移过。

没有网络出口 ⇒ 不可能存在 tracking 域名 ⇒ 两个字段按事实留空。

### 1.3 为什么 `NSPrivacyCollectedDataTypes` 是空数组（而不是「忘了写」）

Apple 的「collected」语义指数据离开用户设备、被开发者或其方可读取。本应用：

- 无任何网络出口（§1.2）；
- 无任何遥测/崩溃上报 SDK；`Package.swift:30-105` 的 target 依赖全是本仓库内 target，
  第三方依赖为零，因此也不存在「藏在依赖里的上传」；
- 数据只写本机 SQLite：`Sources/AIObservatoryStore/SQLiteDatabase.swift:756`
  仅做 `createDirectory(atPath:)`；落盘位置由 `Sources/AIObservatoryApp/DataLocation.swift:24-28`
  按 `ADR-0003` 解析 —— 正式运行的 app（bundle id `com.aix.aiobservatory` 且 `.app` 后缀）
  写 `~/Library/Application Support/com.aix.aiobservatory/`（`AGENTS.md` §7），
  Agent/开发期运行写仓库内 `observatory-data/`，目录创建失败则退 `:memory:`（`ADR-0003` 第 4 条）。

**所以「零数据上传」这件事在本清单里的正确表达方式就是空数组**；把它写成
「采集了 Device ID / Other Data」之类条目反而是虚假申报。此判断的行为事实描述放在
`Documentation/PRIVACY.md`，本文件只放代码依据。

---

## 2. 有真实调用点、但**未声明**的族（及为何未声明）

这两族是本应用最敏感的能力，**未声明的原因是理由码没能核实，不是因为代码里没有**——
这个区分对审计很关键，因此单列一节，而不是混进 §3。

### 2.1 进程信息族（全系统进程枚举 + argv + cwd + 可执行路径）

| # | 调用点 | 表达式 / 取到的字段 |
| --- | --- | --- |
| P1 | `Sources/AIObservatoryPlatform/AgentDetection/LibprocProcessInspector.swift:95` | `proc_listpids(UInt32(PROC_ALL_PIDS), 0, …)` — 全机 pid 列表 |
| P2 | 同上 `:125` | `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` — ppid / uid / `pbi_start_tvsec` / `e_tdev`(tty) / `pbi_comm` |
| P3 | 同上 `:160` | `proc_pidinfo(pid, PROC_PIDTASKINFO, …)` — `pti_resident_size`、`pti_total_user+system` |
| P4 | 同上 `:222` | `proc_pidpath(pid, …)` — 可执行文件完整路径 |
| P5 | 同上 `:232` | `proc_name(pid, …)` — 进程名 comm |
| P6 | 同上 `:243` | `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, …)` — 进程 cwd |
| P7 | 同上 `:254` + `:257` + `:263` | `mib = [CTL_KERN, KERN_PROCARGS2, pid]`；两次 `sysctl(&mib, 3, …)` 读 argv |
| P8 | `Sources/AIObservatoryPlatform/Telemetry/CommandInferenceEngine.swift:91` | `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, …)` — 工作目录补充 |

**未声明的原因（诚实说明）**：

1. 我无法确认 `NSPrivacyAccessedAPICategoryProcessInfo` 这个常量真实存在。
   针对它的定向检索只回到第三方博客，且摘要明确写出该来源**不含**此类别（§6 表行 6）。
   任务允许我用的示例名里有它，但「示例里出现」不等于「Apple 文档里有」，
   而我不能凭这个写进清单。
2. 即使类别存在，我也**一个理由码都没核实到**。
3. 反过来，Apple 自己的两个页面都把 required-reason API 的申报义务限定在
   **iOS / iPadOS / tvOS / visionOS / watchOS**，平台列表里**没有 macOS**
   （`privacy-manifest-files`：「You need to provide this information for your app or third-party
   SDK on iOS, iPadOS, tvOS, visionOS, and watchOS.」；`describing-use-of-required-reason-api` 同）。
   本项目是 macOS-only SwiftPM 应用（`Package.swift`），这可能正是「进程信息族没有对应类别」的原因。
   这条推断本身也要复核，见 §4-1。

**敏感度事实（不做淡化）**：P1–P8 会为**本机每一个进程**产出一条含用户名与目录结构的记录，
`PRIVACY.md` §5.1 已把这五项（可执行路径 / cwd / argv / tty / uid）逐条列出并标了敏感度。
清单里没有对应条目，**不等于**这项能力不存在或不需要审。

### 2.2 动态 API 族（`dlopen` / `dlsym`）

| # | 调用点 | 表达式 |
| --- | --- | --- |
| D1 | `Sources/AIObservatoryPlatform/AgentDetection/EndpointSecurityMonitor.swift:46` | `dlopen(esFrameworkPath, RTLD_LAZY)` |
| D2 | 同上 `:49` | `dlclose(handle)` |
| D3 | 同上 `:51` | `dlsym(handle, "es_new_client")` |
| D4 | 同上 `:62` | `dlsym(handle, "es_delete_client")` |
| D5 | 同上 `:72-73` | 目标路径常量：`/System/Library/Frameworks/EndpointSecurity.framework/EndpointSecurity` |

用途事实：这**只是能力探测骨架**——加载 Apple 自己位于固定 `/System/Library` 路径的系统框架，
试一次 `es_new_client`，失败即优雅降级为 `.processPolling`（`:43-68`）；不加载任何第三方库、
不 hook、不改行为，且该文件顶部注释（`:11-14`）说明用 `dlopen` 是因为
`Package.swift` 是冻结区、不能为它新增系统库链接依赖。

**未声明的原因**：`NSPrivacyAccessedAPICategoryDynamicAPIs` 这个名字合理，
但我拿到的候选理由码全部来自我自己构造的检索词（循环论证），
**没有任何一个来源独立确认过**。写进去就是编造码。列为 §4-2。

---

## 3. 未声明但检查过的 API（存在性核查结果）

本节是「本清单不是抄模板」的正面证据：每一项都跑了定向搜索，
**命中与未命中都如实记录**。搜索范围为 `Sources/` 全树 127 个 `.swift`。

### 3.1 文件时间戳族 —— `NSPrivacyAccessedAPICategoryFileTimestamp`：**零命中，未声明**

搜索词：`modificationDate`、`creationDate`、`contentModificationDate`、`contentAccessDate`、
`attributeModificationDate`、`NSFileModificationDate`、`NSFileCreationDate`、`fileModificationDate`、
`resourceValues`、`URLResourceValues`、`URLResourceKey.`、`getattrlist`、`fstat`、`st_mtime`、
`st_atim`、`st_ctim`、`timespec` → **全部 0 命中**。

命中的是「文件属性 API 本身，但只取非时间字段」，逐条如下：

| 调用点 | 实际读取的键 |
| --- | --- |
| `Sources/AIObservatoryPlatform/FileSystem/FileSnapshotter.swift:109` `attributesOfItem(atPath:)` | 只用 `:112 attrs[.size]` 与 `:217 attrs[.type]`（判目录） |
| 同上 `:187` | 只用 `:189 attrs[.size]` |
| `Sources/AIObservatoryPlatform/FileSystem/FSEventsWatcher.swift:448` `lstat` | 只用 `st_mode & S_IFMT`（判目录） |
| 同上 `:503` `lstat`（`FileFact.init`） | 只用 `:510 st_size`、`:511 st_mode` |
| `Sources/AIObservatoryPlatform/FileSystem/RenamedFileMatcher.swift:319` `lstat` | 只用 `:320 st_ino`（改名配对，不读时间） |

即：全树没有任何一处把文件的 mtime/ctime/atime 读进变量、写进 DB 或送去显示。
`FSEvents` 事件本身按 `eventId`（序列号）处理，也不带时间戳读数
（`Sources/AIObservatoryPlatform/FileSystem/FSEventsWatcher.swift:200` `FSEventStreamCreate`，
flags 见 `:194-197`：`FileEvents \| NoDefer \| UseCFTypes`）。

> ⚠ 但这不代表 Xcode 的隐私报告会同意。Xcode 做的是**符号级**静态匹配，
> `attributesOfItem` / `lstat` 很可能被直接归进文件时间戳族而不管读没读时间字段。
> 处置预案见 §4-4。

### 3.2 磁盘空间族 —— `NSPrivacyAccessedAPICategoryDiskSpace`：**零命中，未声明**

搜索词：`statfs`、`f_statfs`、`getmntinfo`、`volumeAvailableCapacity`、
`volumeAvailableCapacityForImportantUsage`、`dfVolumeAvailableCapacity`、`volumeTotalCapacity`、
`availableCapacity`、`totalFilesystemCapacity`、`statVFS`、`fileSystemFreeSize`、`fileSystemSize`、
`f_bavail`、`f_bfree`、`f_blocks`、`st_blocks`、`f_fsid`、`df -`、`diskutil`
→ **API 侧 0 命中**。（`diskutil` 的 5 处命中全是**字符串匹配规则**，不是调用：
`Sources/AIObservatoryEngine/RiskPipeline.swift:457,464,737` 与
`Sources/AIObservatoryPlatform/Telemetry/DestructiveCommandRules.swift:145,148,151`，
用于把用户 Agent 跑过的 `diskutil erasedisk` 判为危险命令。）

磁盘 I/O 量走 IOKit 计数字典而非 statfs：
`Sources/AIObservatoryPlatform/Telemetry/DiskIOCounters.swift:39`（`IOServiceMatching("IOBlockStorageDriver")`）、
`:41`、`:48`（`IORegistryEntryCreateCFProperties`）、`:53-54`（`Bytes (Read)` / `Bytes (Write)`）。
这是**累计字节计数器**，与「卷可用容量」不同族，不在磁盘空间申报范围内。

### 3.3 活动键盘族 —— `NSPrivacyAccessedAPICategoryActiveKeyboards`：**零命中，未声明**

搜索词：`TISCopyCurrentKeyboardLayoutName`、`TISCopyCurrentKeyboardLayout`、
`TISCreateInputSourceList`、`TISCopyCurrentKeyboardInputSource`、`UCGetKeyboardLayoutName`、
`keyboardLayout`、`KCGI`、`NSTextInputContext`、键盘监听 / `addLocalMonitorForEvents` /
`NSEvent` 键事件 → **0 命中**。本应用不观测任何键入内容，符合 `AGENTS.md` §7。

### 3.4 系统启动时刻族 —— 除 §1.1 那一处之外的核查

**0 命中**：`sysctl` + `KERN_BOOTTIME`（全树 `sysctl` 只出现在 §2.1 的 P7，用于 `KERN_PROCARGS2`）、
`KERN_BOOTTIME`、`ProcessInfo.systemUptime`、`systemBootTime`、`mach_absolute_time`、
`mach_continuous_time`、`clock_gettime`、`clock_gettime_nsec_np`、`gettimeofday`、`host_info`、
`DispatchWallTime`、`dispatch_time`。
代码里的时间戳一律走 `Date()`（墙钟）与 `host_statistics` tick 差值，不反推开机时刻。

### 3.5 其它按任务要求核查过的项目

| 符号 | 结果 | 位置 / 说明 |
| --- | --- | --- |
| `MTLCreateSystemDefaultDevice` | 未使用 | 全树 0 命中（不链接 Metal） |
| `CGWindowListCopyWindowInfo` | 未使用 | 0 命中（不枚举窗口标题 / 不截屏） |
| `CCCrypt` / `CommonCrypto` | 未使用 | 0 命中（哈希只有 Swift 实现的 SHA-256，见 `FileSnapshotter.swift:126,173-177`） |
| `SecItem` / `SecKey` / Keychain | 未使用 | 0 命中（不碰钥匙串） |
| `task_for_pid` | 未使用 | 0 命中 |
| `thread_info` | 未使用 | 0 命中 |
| `host_processor_info` | 未使用 | 0 命中 |
| `host_statistics` / `host_statistics64` | **使用中，但非 required-reason** | `Sources/AIObservatoryPlatform/Telemetry/HostMetricsSampler.swift:73`（`HOST_CPU_LOAD_INFO`）、`:127`（`HOST_VM_INFO64`）；只取聚合 tick / 页计数，不返回 per-process 或可识别信息 |
| `es_new_client` / `es_subscribe` | 见 §2.2 | 只经 `dlsym` 探测，未订阅事件流（`EndpointSecurityMonitor.swift:17-18`） |
| `proc_pid_rusage` / `proc_listpidspath` / `proc_pidfdinfo` / `allprocs` | 未使用 | 0 命中 |
| `getenv` / `environ`（直接 C 访问） | 未使用 | 0 命中 |
| `ProcessInfo.processInfo.environment[...]` | 使用中，非 required-reason | `Sources/AIObservatoryApp/DataLocation.swift:24` 只取自己进程的 `AIOBSERVATORY_DATA_DIR` 一个键；**不读任何其它进程的进程环境**（`LibprocProcessInspector.swift:16` 明确「不读取环境变量（需要特权）」；`AgentDetectionPipeline.swift:71` 传 `environment: [:]`） |
| `ProcessInfo` 其余用法 | 使用中，非 required-reason | `HostMetricsSampler.swift:106` `processorCount`、`:121` `physicalMemory`、`LibprocProcessInspector.swift:210` `activeProcessorCount` —— 均为硬件容量常数 |
| `NSHomeDirectory()` | 使用中，非 required-reason | `Sources/AIObservatoryUI/Settings/SettingsStoragePane.swift:254`（探测文件）、`Sources/AIObservatoryEngine/ObservatoryEngine.swift:873`（用 `FileManager.homeDirectoryForCurrentUser` 拒绝监控家目录）；`ObservatoryPreviewSupport.swift:326`、`AIObservatoryTestSupport/SampleData.swift:289` 属预览/测试假数据 |
| `FileManager` 目录解析 | 使用中，非 required-reason | `DataLocation.swift:27,43,58`、`PathFilter.swift:48`、`SQLiteDatabase.swift:756` |
| `FSEventStreamCreate` | 使用中，非 required-reason | `FSEventsWatcher.swift:200`；FSEvents 不在 Apple 的 required-reason 列表内 |
| `getifaddrs` / `freeifaddrs` | **已接线，每次整机采样都会执行**，非 required-reason | `NetworkCounters.swift:115,116`；读的是接口名与字节计数。**2026-09-20 二次更正**：原「零调用者所以根本没读」已失效——`grep -rn NetworkCounters Sources/ \| grep -v 'Telemetry/NetworkCounters.swift' \| wc -l` → **2**（`HostMetricsSampler.swift:28` 与 `:84`）。落库的只有**差分后的速率**（`system_perf` v3 四列），**接口名不落盘**（只在内存里用于配对两轮快照）。仍不在 required-reason 列表内（Apple 无对应类别），属隐私相邻读数，见 §4-6 |
| IOKit 温度 | 使用中，非 required-reason | `ThermalPowerReader.swift:36`（`IOServiceGetMatchingService("AppleSMC")`）、`:49`（`IORegistryEntryCreateCFProperty`）；聚合传感器值 |
| `dlopen` 目标为第三方库 | 否 | `EndpointSecurityMonitor.swift:72-73` 路径硬编码在 `/System/Library/Frameworks/` 下，唯一目标 |

---

## 4. 需要人工复核（按优先级）

1. **【最高】进程信息族到底该不该申报、以及有没有合法类别可用。**
   本文按「没核实到就不写」把它整族留空了。请有浏览器的人打开
   <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>
   （需 JavaScript 渲染），确认是否存在进程信息类别常量与其理由码；
   同时确认 macOS 上的 app 是否真的被要求申报 required-reason API
   （Apple 页面平台的列表不含 macOS，但 Xcode 隐私报告仍可能报缺失）。
   若确认存在类别 → 补 §2.1 的 P1–P8 八条证据；若确认 macOS 不适用 →
   把这条结论写进 `PRIVACY.md` §6，本清单可维持现状。
   > **负责人旁证（2026-09-19，仍非定论）**：第三方对 Apple required-reason 清单的
   > 枚举给的是**五类**——文件时间戳 / 系统启动时间 / 磁盘空间 / 活动键盘 / 用户默认，
   > 其中**没有**「进程信息」类（Kaamel 博客转述 Apple 政策，检索于 2026-09-19）。
   > 这与「`NSPrivacyAccessedAPICategoryProcessInfo` 不存在」方向一致，
   > 但二级来源不构成权威；Apple 原页为 JS 渲染，本工作流无浏览器可用。
   > 结论维持 B 的判断：**宁可不声明也不编造类别与码**，本清单在这一项上是「有意少报」，
   > 且少报的方向不会隐瞒任何已发生的采集行为（libproc 扫描在 `PRIVACY.md` §5.1 里如实列表）。
2. **`dlopen`/`dlsym` 的理由码。** 同 §2.2：类别名合理、码未核实。
   核实后请一并确认「加载 Apple 系统框架做能力探测」这一具体形态落在哪个码上，
   不要挑一个语义最宽的码了事。
3. **两个必须人工确认的点，都指向 `Resources/PrivacyInfo.xcprivacy` 里唯一那条声明：**
   (a) `DispatchTime.now()` 是否真被 Apple 归入 System boot time 族；
   (b) `35F9.1` 的**官方措辞原文**是否涵盖「只求时间差、不取绝对启动时刻」这一用法
   （见 §1.1 的坦白框：码串→类别的映射有旁证，码串→语义的映射**没有**取到原文）。
   本条整体属**多报**方向：风险是声明了一类没用足用途的 API，不会导致误用被隐瞒。
   任一 (a)(b) 判定不成立 → 删除 `PrivacyInfo.xcprivacy` 里唯一的 `dict`（数组留空仍合法）。
4. **Xcode 隐私报告的静态匹配可能把 `attributesOfItem` / `lstat` 判进文件时间戳族。**
   若报告要求申报，**先核实** `C617.1` 的官方措辞是否覆盖「只取 size/type/inode、从不读日期」
   这一事实，再决定是否写入；核实不过就保持不写，并在 `PRIVACY.md` §6 记录分歧理由。
   现状事实（本文 §3.1 表）已备好，可直接引用。
5. **`sysctl(KERN_PROCARGS2)` 的 argv 解析 = 正确性缺陷确证，隐私越界未证实。**
   （负责人 2026-09-19 复核后改写本条；原文把布局写成
   `argc → exec_path → 环境变量区 → 填充 → argv…`，据此推断「可能把含凭据的环境变量
   当成命令行读进来」。该推断有两处站不住：）
   - 按 xnu 的 `sysctl_procargs2` 实现，缓冲区顺序是 `argc` → `exec_path` → `argv[argc]` → `envv`，
     环境块在 argv **之后**；而 `LibprocProcessInspector.swift:269-286` 的循环严格读 `argc` 个
     字符串，读不到 `envv`。
   - 实测签名相反：用 `dist/AIObservatory.app` 跑 47 s 落库的 5 条 `commands` 行，
     `arguments_json` 与 `search_text` 中 `=` 出现次数 **0/5**（无 `KEY=value` 形态条目）；
     且 `json_array_length(arguments_json)` 全为 1、唯一元素与 `executable` 同名 —— 与
     「第一个字符串其实是 `exec_path`」一致。
   **确证的缺陷**：argv 整体后移一位（`exec_path` 被当成 `argv[0]`，末位真实参数被丢弃），
   命令行归因不可信；**未证实的风险**：环境变量泄露。
   `PRIVACY.md` §5.3 第 1 条已同步为这个口径。修复与定性属于 WS-Agent 地盘
   （`Sources/`、`Tests/` 均非本工作流可写区），已提
   `AiX-Vault/04-决策记录/IFR-platform-kern-procargs2.md`。
   另：本条原句「当前该采集器尚未接入 App，故不构成实际泄露」已失效 ——
   采集器**正在**写库（`ObservatoryEngine.swift:98,104,106` 经 `.live(settings:)`）。
   > **2026-09-20 结案**：上述后移缺陷由 `41aec4e` 修复（解析先跳过 `exec_path` 与填充 NUL），
   > 并由 `Tests/AIObservatoryPlatformTests/AgentDetection/ProcessArgumentsTests.swift`
   > 用真起的 `sh -c` 子进程钉住「不后移、不丢末位、不掺入 exec_path」。
   > 本条对 privacy-manifest 申报口径**没有影响**（当年就没声明进程信息族）；
   > 保留这段是记录「子代理断言 → 负责人复核降级 → 另一车道修复」的完整链路。
6. **`getifaddrs` 与 IOKit 读数**：不在 required-reason 列表内，
   但 `NetworkCounters.swift:124` 会读**网卡名**（含过滤 `lo0`，`:106`）。
   > **2026-09-20 二次更正（WS-Perf 接线完成）**：原「这一项当前不会发生 / 零调用者」
   > 已失效。现在 `HostMetricsSampler.sampleSystem()`（`:39-67`）每轮都读网卡计数器并差分，
   > `GPUActivityReader.swift:33-53` 每轮读 `IOAccelerator` 的
   > `PerformanceStatistics["Device Utilization %"]`。落盘范围核实如下：
   > - **网络**：只落**速率**与不可得原因（`system_perf.network_in_bytes_per_second`、
   >   `network_out_bytes_per_second`、`network_availability`）；
   > - **接口名不出内存**：`NetworkTotals.perInterface` 只存在于采样器的 `SamplerState`
   >   （`HostMetricsSampler.swift:84-87`），`grep -rn "perInterface\|if_name" Sources/AIObservatoryStore/`
   >   → 无落点，所以 §5.1 字段表**不需要**为接口名补行；网卡名可识别环境这一风险因此
   >   只停留在内存与 CPU 侧，不进入数据库；
   > - **GPU**：落 `system_perf.gpu_percent` 一个 0…100 标量，越界值在 Platform 侧即判不可得
   >   （`GPUActivityReader.swift:59-67`）。
   > 三项都是**整机聚合量**，macOS 无公开的非 root 按进程 API ⇒ 无法归因到某个 Agent，
   > 界面也因此只在「整机」口径下显示它们（`PerformanceSeriesPoint` 的会话初始化写死 `nil`，
   > 有测试钉住）。本轮**没有**用户开关，理由与影响见 `PRIVACY.md` §2.3。
7. **`Documentation/PRIVACY.md` §1 与 §7 的口径**：~~该文称「当前版本没有任何持久化落盘」~~
   **已由负责人于 2026-09-19 更正**：持久化确实已落地，§1 现列出四种数据目录去向
   （`DataLocation.swift:26-55`）+ 实测行数，§5.1 现列出**正在落盘**的字段（含
   `diffs.lines_json` 这类明文片段），§7 现列出真正尚未实现的项。
   本清单的 `NSPrivacyCollectedDataTypes = []` 建立在「不上传」而非「不落盘」上，
   两者不冲突，因此**清单本身无需因持久化落地而改动**（落盘在本地不改变 collected 判定）。
   请总控在合并时确认这条分工被理解。

---

## 5. 交付给打包负责人的接线事项（本文不代做，也不改 `Package.swift`）

> **负责人处理状态（2026-09-20 更新）**：A 项**已闭环**，而且现在**只有一条路径**——
> 清单由唯一打包入口 `Packaging/make-app.sh` 第 3/6 步拷进 `Contents/Resources/`
> （实测包内那一份 `plutil -lint` 通过、`build-info.txt` 记 `privacy manifest: yes`）。
> `Package.swift` 未改（仍然没有任何 `resources:`）。

- **A. 清单只经打包脚本进 bundle。** `Package.swift` 的 target 没有任何 `resources:` 声明，
  所以 SwiftPM 本身不会把本文件放进任何产物；当前唯一落点就是入口脚本里那次 `cp`
  （脚本不变量 #3：文件缺失时如实警告，**不伪造**一个空的来让报告好看）。
  ⇒ 推论（仍然成立的事实）：**不走这个脚本的产物就没有隐私清单** ——
  包括 `.build/release/AIObservatory` 裸可执行文件、以及用 Xcode 工程直接 Build 出来的 `.app`
  （除非把本文件以 App Privacy File 类型引用进去）。
  若将来要支持那两种形态，需要总控在 `Package.swift` 加 `resources:`，
  并保证 bundle 里那份与仓库里这份不会分叉成两个真值源。
- **B. 校验命令**（只读，安全）：`plutil -lint Resources/PrivacyInfo.xcprivacy`。
  本次输出：`Resources/PrivacyInfo.xcprivacy: OK`。
  打包后请对 bundle 内的那一份再 lint 一次。
- **C. 不要**为了「让隐私报告好看」而把 §3 里 0 命中的类别补成模板常见的三件套
  （FileTimestamp + DiskSpace + SystemBootTime）。§3 的空结果是有意的、可复核的事实，
  加进来就是假申报。

---

## 6. 用于核实键名与理由码的来源（逐条记债）

本次只做了只读检索，未下载/保存任何产物。Apple 页面的 JS 渲染限制导致
**理由码表未能从 developer.apple.com 直接取回**，这一点必须写清楚而不是含糊带过。

**Tier A — Apple 官方，已逐字取回（`fetch as .md`）**

| URL | 取回了什么 |
| --- | --- |
| <https://developer.apple.com/documentation/bundleresources/privacy-manifest-files.md> | 文件名必须是 `PrivacyInfo.xcprivacy`；顶层四个键 `NSPrivacyTracking`(Bool)、`NSPrivacyTrackingDomains`(String 数组)、`NSPrivacyCollectedDataTypes`(字典数组)、`NSPrivacyAccessedAPITypes`(字典数组)；并明确 required-reason 申报平台为 iOS/iPadOS/tvOS/visionOS/watchOS（**无 macOS**） |
| <https://developer.apple.com/documentation/bundleresources/app-privacy-configuration.md> | 同一组顶层键的 Property List 结构定义 |
| <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api.md> | 子键 `NSPrivacyAccessedAPIType`、`NSPrivacyAccessedAPITypeReasons`；以及「申报值必须取自 Apple 列出的值，不得自行编造；未申报将被 App Store Connect 拒收」的强制性表述 |
| <https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes.md> 及其 `/nsprivacyaccessedapitype.md`、`/nsprivacyaccessedapitypereasons.md` | 只有键的语义说明；**类别常量与理由码在这些页面的非 JS 渲染里不再枚举** —— 这正是 §2 两族留空的直接原因 |

**Tier B — 二级镜像，用于取回具体码串（不是 Apple 直出）**

| URL | 提供了什么 | 可信度备注 |
| --- | --- | --- |
| <https://learn.microsoft.com/en-us/dotnet/maui/ios/privacy-manifest?view=net-maui-9.0> | `FileTimestamp→C617.1`、`SystemBootTime→35F9.1`、`DiskSpace→E174.1`、UserDefaults 族 `CA92.1/1C8F.1/C56D.1/AC6B.1`，并逐条链到 Apple 页的锚点 `#4278393`(File timestamp) / `#4278394`(System boot time) / `#4278397`(Disk space) | 锚点 ID 归 Apple 所有，是 §1.1 采用 `35F9.1` 的依据；但表格文字本身由微软转述，**未经 Apple 原文逐字比对** |
| <https://docs.unity.cn/cn/2022.3/Manual/apple-privacy-manifest-policy.html> | 独立佐证 `SystemBootTime→35F9.1`、`DiskSpace→E174.1`、`FileTimestamp→0A2A.1/C617.1` | 只覆盖 3 族，且按 Unity 自己的 API 列表组织 |
| <https://www.jianshu.com/p/7b32d02ef362> | 独立佐证 `FileTimestamp→C617.1/3B52.1/DDA9.1`、`SystemBootTime→35F9.1`、`DiskSpace→E174.1/85F4.1`、`ActiveKeyboards→3EC4.1/54BD.1`、`UserDefaults→CA92.1`；**未列 Dynamic APIs，也未列进程信息类别** | 2024-05 的社区转载，时效性存疑，只作为「`NSPrivacyAccessedAPICategoryProcessInfo` 可能不存在」的旁证 |

**未采信的东西**：`D723.1` 等 Dynamic APIs 候选码全部来自我自己构造的检索词，
没有任何来源独立确认过 → 按「never invent a code」直接弃用（§2.2）。
本清单里出现的唯一码串 `35F9.1` 有 Tier B 两个独立来源 + Apple 锚点 #4278394 支撑。
