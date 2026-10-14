---
owner: WS-Packaging
status: delivered
updated: 2026-09-19
---

# Packaging entitlements 设计说明

> 本文件承载两份 entitlements 的完整论证。
> **为什么论证不在 plist 里**：`codesign --entitlements` 用 AMFI 的严格解析器读这个
> 文件，它**不接受 XML 注释**。负责人 2026-09-19 实测：带注释的
> `Observatory-App.entitlements` 通过 `plutil -lint`，但签名时报
> `Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 13`，
> 导致打包直接失败。⇒ `.entitlements` 必须是纯 dict，理由只能写在这里。
> 这是 `Info.plist`（允许注释，LaunchServices 走 CFPreferences）与
> `*.entitlements`（禁止注释）的一个真实差异，任何后续改动都要遵守。

## 1. BASE 档：`Observatory-App.entitlements`

**结论：这个文件是空的，而且它本来就该是空的。** 当前发布的 ad-hoc 包不需要任何 entitlement。

### 1.1 为什么一个 entitlement 都不放

本 App **故意不进 App Sandbox** —— 这是产品前提，不是技术欠账：
「审计本机所有 AI Agent 行为」与沙箱在能力上互斥，沙箱内的进程看不到全机进程表与
vnode 路径。`Sources/AIObservatoryPlatform/AgentDetection/LibprocProcessInspector.swift:95`
的 `proc_listpids(PROC_ALL_PIDS)` 与 `:243` 的 `PROC_PIDVNODEPATHINFO` 在沙箱下会退化到
几乎无信息量。取舍与爆炸半径控制见 `Documentation/SECURITY.md` 第 4 节。

于是 `com.apple.security.app-sandbox` 不能出现；也**不要**写成 `<false/>` ——
Apple 对布尔 entitlement 的约定是「值为 false 就不要写进去」
（[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)：
*"Don't include an entitlement if the value is false."*）。
写 `app-sandbox=false` 不授予任何能力，只会让审阅者误以为这里有沙箱配置。

当前实际用到的采集面（`Sources/AIObservatoryPlatform/**` 逐文件核对）：

| 采集面 | 调用点 | 是否需要 entitlement |
| --- | --- | --- |
| libproc：`proc_listpids` / `proc_pidinfo` / `proc_pidpath` / `proc_name` | `LibprocProcessInspector.swift:95,125,160,222,232,243` | 否 |
| `sysctl(KERN_PROCARGS2)` 读 argv | 同上 `:251-263` | 否 |
| `host_statistics` / `host_statistics64` | `Telemetry/HostMetricsSampler.swift:73,127` | 否 |
| IOKit 读电源／磁盘计数 | `Telemetry/DiskIOCounters.swift`、`ThermalPowerReader.swift` | 否 |
| FSEvents 监听用户可见路径 | `FileSystem/FSEventsWatcher.swift` | 否 |

这些全部是**同一用户身份下的只读系统调用**，非沙箱进程默认可用。
权限模型见 `Documentation/SECURITY.md` 第 1 节：不注入其他进程、不挂钩、
不 `task_for_pid`、不 `ptrace` —— 所以也不需要 `com.apple.security.cs.debugger`。

### 1.2 逐条排除其他候选键（避免「模板里常见所以抄一份」）

- 网络类／推送类：`Sources/` 里 `URLSession`、`import Network`、`socket()` 命中数为 0。
- `com.apple.security.device.*`、`personal-information.*`：不采摄像头、麦克风、位置、通讯录、照片。
- `com.apple.security.automation.apple-events`：不发 Apple 事件。
- `com.apple.security.application-groups`：无 group 容器；且沙箱容器的 Application Support
  重定向会**直接破坏 ADR-0003 的落盘判定** —— `DataLocation.swift:27` 走
  `.applicationSupportDirectory` + `.userDomainMask`，沙箱下会解析到
  `~/Library/Containers/com.aix.aiobservatory/Data/...` 而不是 ADR 规定的
  `~/Library/Application Support/com.aix.aiobservatory/`。
  ⇒ 任何引入容器重定向的键都是与 ADR-0003 冲突的变更，必须先走决策记录。
- `com.apple.security.get-task-allow`：只为调试器放行，不该进发布包。
- `temporary-exception.*`（mmap+PROT_EXEC、iokit-user-client 等）：当前无对应被拒行为；
  真出现运行时拒绝再按需加，并在 commit message 里指名是哪一次调用。

### 1.3 Hardened Runtime：本文件不声明它，也不要误以为声明了

HR 是 codesign 的**签名标志位**（`--options runtime`），不是一条 entitlement。
「本包启用了 HR」这个断言只能来自 `codesign -dvvv` 输出 flags 里的 `runtime`，
永远不能来自这个文件。`Packaging/make-app.sh`（唯一打包入口）默认 `HARDENED_RUNTIME=0`，理由：未签
Developer ID 的本地链路里任何人可重签去掉 HR，它不构成信任信号，却会削减运行时能力，
需要真机单独验证一轮后再固化。

若总控决定启用（`HARDENED_RUNTIME=1 Packaging/make-app.sh`），逐项对照 Apple 的 HR
例外清单：**libproc 观测面与 HR 全量兼容，六条例外一条都不用开。**

- `cs.allow-jit` / `cs.allow-unsigned-executable-memory`：不需要，无 JIT。
- `cs.allow-dyld-environment-variables`：不需要，App 不 fork 外部命令（`SECURITY.md` 第 8 节）。
- `cs.disable-library-validation`：**默认不需要且默认不要加**。
  `EndpointSecurityMonitor.swift:46` 的 `dlopen` 加载的是
  `/System/Library/Frameworks/EndpointSecurity.framework` —— Apple 自家签名，Library Validation 可通过。
- `cs.disable-executable-page-protection`、`cs.debugger`：不需要。

唯一的 HR 风险点（本地才可能出现）：若链接器把可执行文件指向**工具链自带**的 Swift
运行时 dylib 而非系统内那份，启用 HR 后可能启动失败。`Package.swift` 零外部包依赖
（无任何 `.package(url:`），不存在三方 dylib；真出问题按 `dyld` 报错指名补例外，
并把判断写回 commit message。**此路径尚未在真机验证。**

### 1.4 空文件仍然要传 `--entitlements` 的两个理由

- **可审计的「负答案」**：`codesign -d --entitlements :- AIObservatory.app` 打印出空 dict，
  审阅者据此正面确认「本包没有任何提权 entitlement」，而不是靠读打包脚本推断。
- **合并点**：将来真要加 entitlement 时，diff 落在这个文件里，而不是散落在 shell heredoc 里。

## 2. OPT-IN 档：`Observatory-App-Optional-EndpointSecurity.entitlements`

**默认不启用，不在默认构建路径上。** 使用本文件前先读四条事实：

1. **这个 entitlement 要向 Apple 申请，不是自己写就能生效。**
   Apple 原文：*"The entitlement required to monitor system events for potentially malicious
   activity. … You must request this entitlement from Apple."*
   （[com.apple.developer.endpoint-security.client](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client)、
   [System Extensions](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.system-extension.install)）
   缺它时 `es_new_client` 返回 `ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED`。
2. **ad-hoc 签名（`codesign -s -`）不会授予它。** `com.apple.developer.*` 是受控 entitlement，
   需要绑定了相应 profile 的 Apple 签发身份。嵌进 ad-hoc 包得到的是「签了但内核不认」的签名，
   运行时行为与完全不签一样（照样降级为轮询）。个人／开源项目基本拿不到（`SECURITY.md` 第 2 节表格）。
3. **即使拿到授权，ES 客户端还需 root，且不能再进 App Sandbox**；macOS 11+ 的正式分发形态是把
   ES 客户端做成 **system extension** 由用户显式安装批准。另注意 Apple 的硬约束：
   *"macOS refuses to load system extensions that use Hardened Runtime exception entitlements"*
   ⇒ 走 system extension 形态时本文件里**不得**出现任何 `com.apple.security.cs.*` 例外键。
   本仓库当前没有 extension target（`Package.swift` 无该 product），也没有
   `com.apple.developer.system-extension.install` —— 那是真要做 ES 分发时由总控连同 extension
   装配一起新增的东西，不该先抄在这里。
4. **最重要：今天签了它，产品行为零变化。**
   `Sources/AIObservatoryPlatform/AgentDetection/EndpointSecurityMonitor.swift` 只是能力探测器，
   不是事件流订阅者：
   - `:45-69` `probeCapability()` 里 `dlopen` → `es_new_client` → **立刻** `es_delete_client`（`:62-64`）
     → 返回 `.endPointSecurity` / `.processPolling`；
   - 文件头 `:17-18` 自述「该类型仅做能力探测（骨架），并不真正订阅 ES 事件流」；
   - 唯一调用点是 `AgentDetectionPipeline.realtimeCapability()`（`:106-108`），而后者在**生产路径上
     无任何调用者**（全仓检索命中仅 `Tests/AIObservatoryPlatformTests/AgentDetection/AgentDetectionTests.swift:254`
     与契约声明 `AIObservatoryCore/Contracts/CollectorContracts.swift:126`）；
   - `ObservatorySettings.enableEndpointSecurity`（`ServiceProtocols.swift:91,104` 默认 false）同样
     **无任何读取方** —— 只有 `SettingsPrivacyPane.swift:87` 的开关与 `SettingsAboutPane.swift:121`
     的状态文本在读写这个 UI 草稿值。

   当前真正在跑的采集路径是 libproc 轮询：`AIObservatoryApp.swift:28` `ObservatoryEngine(settings:)`
   → `ObservatoryEngine.swift:188-189` `.live(settings:)` → `:98` `LibprocProcessInspector()`
   + `:102` `AgentDetectionPipeline()` + `:108` `FSEventsWatcher`，由 `startScanLoop()`
   （`:448-449` `scanProcesses`/`detectAgents`）按间隔驱动。
   ⇒ 本文件描述的是一个**尚未实现的里程碑的前置条件**，不是给现有构建「打开一个已存在功能」的开关。

### 2.1 与 libproc 轮询的取舍（为什么默认档不该走 ES）

| 维度 | libproc 轮询（默认，已实现） | EndpointSecurity（本文件，未实现） |
| --- | --- | --- |
| 权限 | 当前登录用户即可，无 entitlement、无 root | Apple 特批 entitlement + root + 通常还要系统扩展形态 |
| 粒度 | 快照：只知道「这一瞬间谁在」 | 事件流：exec / open / … 逐个事件，不丢 |
| 已知缺陷 | 两次扫描之间启动并退出的进程**永不可见**；退出码不可得（`CommandInferenceEngine.swift:56`） | 无上述漏采；但订阅者自己成为高权限常驻进程 |
| 分发 | 任何人可自行构建运行 | 个人／开源项目基本拿不到 |
| 性能预算 | 靠可调扫描间隔守 `< 50 ms/次`（AGENTS.md 第 6 节） | 事件驱动，无轮询开销 |
| 爆炸半径 | 只读同用户进程元数据 | 全机事件流 + root，本工具从「被审计面」变成高价值攻击目标 |

### 2.2 用法（明确写了才生效）

```bash
AIX_ES_ENTITLEMENTS=1 Packaging/make-app.sh
```

⚠️ **实测结论（负责人 2026-09-19，推翻本文件初稿的预测）：这条路会让 App 启动即死。**

控制实验（同一台机器、同一分钟内，唯一变量是签进去的 entitlements，
`AIX_SKIP_BUILD=1` 复用同一个二进制）：

| 档位 | 签名验证 | 启动结果 |
| --- | --- | --- |
| BASE（空 dict） | `valid on disk` / `satisfies its Designated Requirement` | 常驻 ✅（47 s 观测，写库正常） |
| ES 档（`com.apple.developer.endpoint-security.client = true`） | 同样通过（`signed app bundle ... [com.aix.aiobservatory]`，`codesign -d --entitlements -` 能看到该 Key） | **退出码 137 = SIGKILL，无任何用户态输出** |

机理：`com.apple.developer.*` 是**受控 entitlement**。AMFI 在 exec 时发现二进制声明了
它拿不到的受控权限（ad-hoc 签名没有绑定的 profile），直接 SIGKILL ——
即事实 (2) 说的「签了但内核不认」，其真实后果不是「降级为轮询」，而是**进程根本起不来**。
`codesign --verify` 通过只说明签名自洽，**不**说明 entitlement 被系统授予。

⇒ 本文件的定位因此是：**一份「申请到授权之前绝不能签进产物」的清单**，
而不是一个可以先开着看效果的功能开关。真正启用 ES 的顺序必须是：
向 Apple 申请 → Developer ID 签名（+ 必要的 provision/profile）→ root 或系统扩展装配 →
把真正订阅事件流的实现补进 `AIObservatoryPlatform`。
在那之前请勿分发、也不要用本档位做本地冒烟测试（否则会被误判成 Engine 崩溃）。

初稿里「预期结果：签名里多了这个 entitlement，运行时仍然降级为 `.processPolling`」这句话
是**基于文档的推断，已被实测推翻**，保留在此以显示结论来源；以本表为准。
另：`spctl -a -t exec` 两档都返回 `rejected` —— ad-hoc 无 Developer ID / 无公证，属预期，
与上面的 SIGKILL 是两回事（前者是 Gatekeeper 策略层，后者是 AMFI exec 层）。
