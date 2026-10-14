# 安全模型（SECURITY）

> 本文与代码同步于 2026-09-19，所有「已实现」断言均附代码位置（相对仓库根）。

本文描述这个工具**能证明什么、不能证明什么、以及它自己带来什么风险**。
一个审计工具如果把自己的能力说得比实际更强，它就成了风险源而不是风控项。

---

## 1. 信任模型：谁在读谁的数据，读到的能证明什么

**读方**：以当前登录用户身份运行的本应用进程。
**被读方**：同一台机器上、同一用户（及内核愿意暴露的部分系统进程）的进程元数据。
**读的介质**：只读系统调用（libproc / sysctl / host_statistics / IOKit / getifaddrs），
不注入其他进程、不挂钩、不读他人内存。

读到的数据能证明什么：

| 能证明（在本机当时确实成立） | 不能证明 |
| --- | --- |
| 某 pid 在某时刻存在，其 comm / 可执行路径 / cwd / argv / tty / uid / 启动时间（`LibprocProcessInspector.swift:112-190`） | 该进程**做了**什么：没有 syscall 级事件流，argv 只是「它被以什么参数启动」 |
| 父子关系（`pbi_ppid` `:128`）与派生出的子孙集合（`ProcessTreeBuilder`，`AgentDetectionPipeline.swift:77`） | 「这条命令是这个 Agent 决定的」——这是**归因推断**，见 `CommandInferenceEngine.swift:69-81`（沿父链找最近的 Agent pid） |
| 资源占用：累计 CPU 时间差、RSS（`:160-163`），整机 CPU/内存/磁盘/load（`HostMetricsSampler.swift:37-58`）。**网络速率与整机 GPU 活动已采集**（2026-09-20 接线）：整机聚合量，接口名只在内存里用于差分、不落盘；**会话级** `networkBytesIn/Out` 与 `gpu_percent` 仍恒 0 / NULL ——没有按进程的非 root API，也不许拿整机值冒充（`PRIVACY.md` §2.3） | 瞬时值精度：CPU 是**两次采样求差**，首次必为 0（`:196-214`，尤其 `:202`） |
| 命令的危险等级分类（`DestructiveCommandRules.swift:176-208`） | 命令是否成功、退出码是什么：轮询模式下**一律记 `.running`**（`CommandInferenceEngine.swift:56`） |

**这些都不是密码学证据。** 没有签名、没有审计链（tamper-evident log）、没有可信时间源，
数据库文件（未来实现后）被本机任意进程改写后无从分辨。
本工具的输出可用于**自我审计与事后回溯**，不可作为对第三方追责的司法级证据。

「它是 Agent」这件事同样是推断：由 6 条策略按置信度首命中决定
（`AgentDetectionPipeline.swift:18,44-51,112-119`；例：命令行特征匹配 0.72
`DetectionStrategies.swift:146`，父进程树归属 0.45 `:177`），
命中的信号类型随记录一起保留（`AgentDetectionPipeline.swift:95` → `detectedVia`），
以便 UI 上说明「凭什么认定」。

---

## 2. 两条采集路径

| 维度 | libproc 轮询（当前唯一有实现的路径） | EndpointSecurity |
| --- | --- | --- |
| 权限 | 无需 root、无需 entitlement；普通用户进程即可（`LibprocProcessInspector.swift:89-107`） | 需 root **且** 需 Apple 特批 entitlement `com.apple.developer.endpoint-security.client`；实践中常还需 SIP 例外 / 特殊授权 |
| 粒度 | 快照：只知道「这一瞬间谁在」 | 事件流：exec / open / … 逐个事件 |
| 是否漏采 | **会**：两次扫描之间启动并退出的进程永不可见；退出码不可得（`CommandInferenceEngine.swift:56`） | 不丢事件（同步订阅） |
| 竞态 | 有：pid 复用、扫描期间的进程表变化（快照非原子） | 无此问题 |
| 可分发性 | 任何用户可自行构建运行 | 个人/开源项目基本拿不到该 entitlement |
| 代码现状 | **已实现并已装配进 App，正在写库**（装配点 `ObservatoryEngine.swift:98,104,106` 经 `.live(settings:)` `:188-189`，由 `AIObservatoryApp.swift:28` 启动）；测试 `AgentDetectionTests.swift:26,33,64` | **未实现**：只有能力探测器，调一次 `es_new_client` 立刻 `es_delete_client`（`EndpointSecurityMonitor.swift:54-67`），文件头自述「并不真正订阅 ES 事件流」（`:17-18`） |

**当前实际启用的是哪条？严格说：两条都没有启用。**

- `Sources/AIObservatoryEngine/ObservatoryEngine.swift` 虽 import 了 Platform（`:24`），
  但**没有实例化任何采集器**：`activeAgents()` 直接返回 `[]`（`:91`），
  `rescanNow()` 是空函数体（`:56`），`start()` 只把状态置为 running 并打一行
  `"…(skeleton)"` 日志（`:44-48`）。
- 全仓检索 `AgentDetectionPipeline` / `LibprocProcessInspector` / `HostMetricsSampler`
  的构造点，命中仅出现在 `Sources/AIObservatoryPlatform/` 内部与 `Tests/` 中。
- `ObservatorySettings.enableEndpointSecurity` 默认 `false`（`ServiceProtocols.swift:104`）
  且**无任何读取方**；`AgentDetectionPipeline.realtimeCapability()`（`:105-107`）
  在生产路径上无人调用。测试断言本环境（无 entitlement）必然降级为 `.processPolling`
  （`AgentDetectionTests.swift:254`）。

因此本工具目前是「**以非特权轮询方式实际在观测、并正在把结果写进本机库的应用**」：
不需要 root、不需要 entitlement，代价是只能看到快照（会漏采瞬时进程、拿不到退出码）。

---

## 3. 签名与分发信任

唯一打包入口 `Packaging/make-app.sh` 只做 ad-hoc 签名（BASE 档 entitlements 是**有意空 dict**）：

```bash
codesign --force --sign - --identifier com.aix.aiobservatory \
    --entitlements Packaging/Observatory-App.entitlements --timestamp=none "$APP"
                    # Packaging/make-app.sh:248-275；不用已弃用的 --deep，内层→外层逐个签
```

事实与后果：

1. **ad-hoc（`-s -`）没有开发者身份**：任何人重新签名即可得到一个「看起来一样」的包，
   接收方无法通过签名辨别作者。
2. **Gatekeeper 不放行，无 notarization**：`spctl -a` 预期失败，
   首次打开会被「无法验证开发者」拦截（处理办法见 `Documentation/INSTALL.md` 第 7 节）。
3. **签名与签名校验失败都是硬失败**（`:275` 与第 5/6 步），不会出现「未签名却打印 ✅ 产出」。
   这一条以前确实是缺陷（吞 stderr + `|| echo` + `--deep` 三处叠加），
   随打包路径合一已**消失**，并写成入口脚本头部的**不变量 #7** 禁止回归。
   但**别人转给你的包**不经过这个脚本 —— 收到包仍要自己 `codesign --verify --strict --verbose=2`。
4. **「签名有效」≠「系统授予了 entitlement」**：把受控权限（如
   `com.apple.developer.endpoint-security.client`）签进 ad-hoc 包，
   `codesign --verify --strict` 照样通过、`-d --entitlements -` 也能看到那个 Key，
   而进程在 exec 时被 AMFI **SIGKILL**（实测退出码 137，无用户态输出）。
   ⇒ `codesign`、`spctl`、启动结果这三层判断互不替代，别拿前一层给后一层背书。

**结论（直白）**：本项目的分发**依赖接收方主动信任**——你自己构建、或你信任把包递给你的人。
不得声称存在供应链保护：没有签名身份、没有公证、没有源码透明度日志；
`dist/build-info.txt` 里的 SHA-256 只能让**同一个人**核对"这是我刚构建的那个包"，
它不是发布渠道，因此不构成完整性保护。

---

## 4. 无 App Sandbox 的取舍

「审计本机所有 AI Agent 行为」与「App Sandbox」在能力上互斥：
沙箱内的进程看不到全机进程表与 vnode 路径，`LibprocProcessInspector.swift`
的 `proc_listpids(PROC_ALL_PIDS)`（`:95`）与 `PROC_PIDVNODEPATHINFO`（`:243`）
在沙箱下会退化到几乎无信息量。

- 取舍：**放弃沙箱隔离，换取采集能力**；用「不联网」（见 `Documentation/PRIVACY.md` 第 2 节）
  与「数据只落在本机一个可整体删掉的 SQLite 目录里」（同文档第 1、3 节）来限制爆炸半径。
  ⚠️ **「不落盘」已不再是事实**（本文此前这么写过，2026-09-19 更正）：采集结果确实写库，
  因此真实爆炸半径 = 当前用户可读的**明文**数据库文件（无静态加密）
  + 系统统一日志的残留（不受本应用控制）。
- entitlements 基线已交付：`Packaging/Observatory-App.entitlements`（BASE 档，
  **有意为空 dict** —— 不给任何提权权限，也不给 EndpointSecurity）与
  `Packaging/Observatory-App-Optional-EndpointSecurity.entitlements`
  （可选档，仅 `com.apple.developer.endpoint-security.client`）。
  完整取舍论证在 `Packaging/ENTITLEMENTS-NOTES.md`
  （**必须**放在那里：`codesign --entitlements` 走 AMFI 严格解析器，不接受 XML 注释，
  带注释的 entitlements 会让签名硬失败）。
- entitlements **总是被签进包**（`Packaging/make-app.sh` 第 4/6 步必传 `--entitlements`），
  且第 5/6 步会打印**实际嵌入的内容** —— 唯一可信证据是 `codesign -d --entitlements -`，
  不是磁盘上那份 plist。两个档位都实测过 `codesign --verify --strict` 通过
  （BASE → `[Dict]`；ES → 多出那一个 Key，但见下面的 SIGKILL）。
- ⚠️ **可选 ES 档实测会把 App 打死**：把 `com.apple.developer.endpoint-security.client`
  签进 ad-hoc 包后，进程启动即被 AMFI SIGKILL（退出码 137），而不是「静默降级为轮询」；
  同机同分钟仅切换 entitlements 的对照实验里 BASE 档常驻 47 s 正常写库。
  ⇒ 任何文档都不得把 ES 档描述为「可以先签上试试」的开关。详见
  `Packaging/ENTITLEMENTS-NOTES.md` 第 2.2 节。
- 后果（不变）：本进程一旦被攻破（例如未来导入被观测者可控的数据），
  攻击者获得的是**当前用户完整的文件与进程访问权**，没有沙箱兜底。

---

## 5. 破坏性命令检测的真实边界：告警，不是阻断

`DestructiveCommandRules` 是一个**纯函数分类器**：
输入一个字符串，输出一个 `CommandClassification`（`:176-208`）。
规则库 33 条（`:50-173`，`grep -c 'Rule(id:' = 33`），覆盖递归删除、原始设备写入、
`mkfs`、`curl | sh`、`chmod -R 777`、`sudo`、`csrutil disable`、`git push --force`、
fork 炸弹等。

边界必须说清：

1. **不拦截、不延迟、不撤销任何执行**。`requiresConfirmation`（`:193` 等）只是
   **打在记录上的一个标记位**，供 UI 与引擎后续消费；没有任何代码路径能阻止一个命令运行。
   本应用不是 endpoint 防护产品，也不参与进程执行链。
2. **匹配方式是子串 / 正则 + 小写化**（`:212-219`），因此绕过很容易：
   `r\m -rf`、变量拼接、`$(command -v rm) -rf`、别名、直接 `unlink` 系统调用等
   一律不会命中；同时 `contains("sudo")`（`:110`）这类子串也会带来误报。
   规则命中「最高风险的一条」（`:179-187`），不报告全部命中项。
3. 敏感路径升级仅对**以写类动词开头**的命令生效（`:226-227`），
   且按空格切词（`:223`）——引号内含空格的参数会被错切。
4. 风险事件的确认回路已接通：`acknowledgeRiskEvent(id:)` 委托到
   `readyStore().acknowledgeRisk(id:)`（`ObservatoryEngine.swift:299-301`），
   `riskEvents(matching:)` 直接查库（`:399-401`），风险写入走 `store.recordRisks(risks)`（`:776`）。
   2026-09-20 更正：**独立规则库已实现并接入**（`Sources/AIObservatoryRiskRules/` 7 个文件
   + `Rules/` 4 族，实测 33 条唯一 `risk.*` 标识，经 `RiskPipeline.swift:29,63,109` 消费）。
   仍然成立的一点：真机窗口内 `risk_events` 命中 **0 行** —— 即规则「已加载」有证据、
   「会命中」没有证据，不要声称具备可用的告警能力。

---

## 6. 威胁模型清单

| # | 威胁 | 状态 | 依据 / 缺口 |
| --- | --- | --- | --- |
| T1 | 本机已获取 root 的攻击者伪装、隐藏或篡改进程记录 | **未缓解** | 非特权 libproc 无法对抗 root；ES 亦未实现（第 2 节） |
| T2 | 被篡改的数据库 / 归档文件（改写历史、插入伪造事件） | **未缓解 —— 且从「不适用」变成适用**（2026-09-20 更正：此前写「无落盘故当前不适用」，`StorePlaceholder.swift` 已被真实 Store 取代） | 现在确实有 `observatory.sqlite` + WAL（`PRIVACY.md` 第 1 节），任何能以当前用户身份写文件的人都能改历史、插伪造事件；无完整性校验、无审计链、无静态加密 ⇒ 本工具的结论**不能**当作法务证据 |
| T3 | 导出的报告本身泄密（含用户名、绝对路径、命令参数） | **部分缓解**（2026-09-20 更正，此前写「未缓解／导出为占位」） | 已实现：`ExportRedactor` 掩掉 11 类凭据形态（默认开）+ `ExportWriter.validate` 的 `allowedRoots`/符号链接/`forbiddenPrefixes` 约束。仍未缓解：路径、用户名、argv 与 diff 片段**必然随导出物走**（它们是审计对象），且导出后落进同步盘即失控；规则说明文本仍会把完整敏感路径抄入人读文本（`DestructiveCommandRules.swift:232`）。见 `PRIVACY.md` §5.4 |
| T4 | Agent 改名 / 剥特征以规避识别 | **未缓解** | 识别靠字符串签名库（`AgentSignatureDatabase.swift:62-123`），必然可绕 |
| T5 | 采样窗口漏采与归因误判（把无关子进程算给 Agent，或反之） | **部分缓解** | 保留 `detectedVia` 信号与置信度供人工复核（`AgentDetectionPipeline.swift:95`、`DetectionStrategies.swift:146,177`）；无法补回漏采事件 |
| T6 | 分发链上的包被替换 | **未缓解** | ad-hoc、无公证、无制品哈希（第 3 节） |
| T7 | 本应用自身被攻破后的横向访问 | **未缓解** | 无 App Sandbox（第 4 节）；仅靠「不联网」限制外泄 |
| T8 | 凭据经环境变量被采集 | **不成立（2026-09-20 结案）** | 逐项复核：`KERN_PROCARGS2` 的读取循环受 `argc` 约束，envp 区根本不会被遍历，因此"读到 argv 之外的区域"从未成立。当时真正存在的缺陷是另一件事——解析从 `argc` 位置直接读串，把 `exec_path` 当成 `argv[0]`，导致整体后移一位、末位参数丢失（已修 `41aec4e`，回归用例 `ProcessArgumentsTests.swift` 起真进程验证，改前必红）。⇒ 本行原写的"潜在未缓解"是误判，但暴露的教训成立：**没有真进程用例的解析器，绿灯不代表正确** |
| T9 | 伪造 hook JSONL 以篡改命令审计 | **部分缓解（新路径带来的新边界）** | hook 来源在重叠时**取代**采样记录（它有退出码），因此能以当前用户身份写 `<数据目录>/agent-hooks/` 的人可以：伪造额外记录、或为**确实执行过的同一条命令**编造退出码/耗时。**不能**抹掉另一条命令——重叠判定要求整条命令行文本逐字相等（`CompositeCommandAuditing.isCovered`），前缀/截断匹配被明确禁止（那会吞掉真实命令）。与 T2 同源：无完整性校验、无签名 ⇒ 本工具结论不作法务证据 |
| T9 | 采集器把用户数据带上网络 | **已缓解（当前）** | `Sources/` 无网络 API 命中，import 全集可枚举（`Documentation/PRIVACY.md` 第 2 节） |
| T10 | 静默删除用户文件（工具自身行为） | **未实现该能力，故无此风险** | 无任何删除/清理实现；`AGENTS.md` 第 7 节要求删除类实现必须走确认流程 |

---

## 7. 漏洞报告渠道

**当前仓库尚未公开**，因此不公布邮箱、不承诺响应时限（写了就是假的）。

- 现阶段：通过内部渠道上报——在本工作流仓库的 `AiX-Vault/04-决策记录/` 下新增一条
  安全发现记录，并直接告知 master-controller。
- 开源后：启用 GitHub 的 **private vulnerability reporting**（仓库 Security 设置项），
  并在仓库根新增 `SECURITY.md` 指明上报方式与响应约定。届时更新本节。

## 8. 硬前置条件与不变量

- `Package.swift:138` 强制 Swift 6 语言模式（严格并发）；共享可变状态用
  `OSAllocatedUnfairLock`（`LibprocProcessInspector.swift:63`、`ObservatoryEngine.swift:35`）
  或 `actor`，降低数据竞争导致的安全缺陷。
- 不 `fork` 外部命令做采集：全程系统调用（`LibprocProcessInspector.swift:11`、
  `HostMetricsSampler.swift:9`、`NetworkCounters.swift:9`）——既为性能，也避免
  「审计工具自己起子进程」引入的注入面与噪声。
- 任何新增网络依赖都视为**破坏产品前提的变更**，须在 `04-决策记录/` 单独论证并更新
  `Documentation/PRIVACY.md` 第 2 节的检索面。
