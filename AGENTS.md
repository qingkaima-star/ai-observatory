# AGENTS.md — AiX（AI Agent 活动审计台）开发铁律

> 本文件是**强制约束**。任何进入本仓库工作的 Agent / 子代理 / 人类协作者，
> 在写下第一行代码之前必须先读完本文件与 Obsidian 库中的总控台。

---

## 0. 授权边界（最高优先级，不可协商）

> 本文一律用占位符书写宿主路径：`<授权工作目录>` = 总控在启动简报里交给你的**那一个**工作区根目录
> （本机具体值见简报，不写进仓库）；`<知识库目录>` = `<授权工作目录>/AiX-Vault`；
> `<工作树根>` = `<授权工作目录>/.worktrees`。占位符代表的是**同一个具体目录**，不是一个可选范围。

**唯一被授权的工作目录：`<授权工作目录>/`——有且只有一个，路径由简报给出**

- 允许：在 `<授权工作目录>/` 内的任何读写。
- 禁止：在该目录之外创建、修改、删除任何文件。
  - **禁止读取 `<授权工作目录>/` 之外的任何无关文件。**
  - 禁止向 `~/Documents`、`~/Desktop`、`/tmp`、`/etc` 等目录写入产出物。
  - 临时文件放仓库内 `.scratch-tests/`（测试用 `AIObservatoryTestSupport.Scratch.directory(...)`，
    **不要把宿主绝对路径写进测试代码**——曾有 13 处落盘用例硬编当次运行机器的家目录路径
    （形如 `<授权工作目录>/…/.worktrees/.scratch`），
    导致托管 CI 只能对它们 `continue-on-error`，"CI 全绿"永远拿不到）。
    手工排查用的临时产物放 `tmp/`（已 gitignore）。
- 系统临时目录仅可用于编译过程本身（SwiftPM 自动行为），不得手工投放文件。

违反此条 = 立即停止工作并报告。

---

## 1. 失忆防护：先读，再写

**每次开始工作前，必须先读 Obsidian 库**（防失忆）：

```
<知识库目录>/00-总控台/总控台.md      ← 当前状态、下一步
<知识库目录>/05-失忆防护/必读.md       ← 高效上下文摘要
<知识库目录>/02-子代理简报/<你的代号>.md ← 你的目标与验收标准
```

**每次结束工作前，必须写回 Obsidian**：

- 追加到 `<知识库目录>/03-进度日志/YYYY-MM-DD.md`
- 更新 `<知识库目录>/00-总控台/总控台.md` 中你的那块进度

---

## 2. 并行开发规则（工作树隔离）

- 每个工作流（workstream）拥有**独立的 git worktree**，位于
  `<工作树根>/<ws-name>/`（`<工作树根>` 在 `<授权工作目录>` 之内——工作树**必须**建在授权工作目录内，
  建到它外面即违反 §0），分支名 `ws/<ws-name>`。
- **禁止跨工作树修改文件**。你只能改你自己工作树里的文件。
- **禁止直接向 `main` 提交**。完成后由总控 merge，并删除工作树。
- 分支生命周期：`git worktree add` → 开发 → 自测通过 → 交由总控合并 → `git worktree remove`。

---

## 3. 文件所有权（防止合并冲突）

`Sources/AIObservatoryCore/Contracts/**` 与 `Sources/AIObservatoryApp/**`、
`Sources/AIObservatoryTestSupport/**`、`Package.swift` 是**总控冻结区**。
除总控外的任何工作流**不得修改**这些文件。

各工作流只允许修改自己的目录子树：

| 工作流      | 独占目录                                                                |
| ----------- | ----------------------------------------------------------------------- |
| WS-Agent    | `Sources/AIObservatoryPlatform/AgentDetection/`、`Tests/AIObservatoryPlatformTests/AgentDetection/` |
| WS-Files    | `Sources/AIObservatoryPlatform/FileSystem/`、`Tests/AIObservatoryPlatformTests/FileSystem/` |
| WS-Telemetry| `Sources/AIObservatoryPlatform/Telemetry/`、`Tests/AIObservatoryPlatformTests/Telemetry/` |
| WS-Engine   | `Sources/AIObservatoryStore/`、`Sources/AIObservatoryEngine/`、`Tests/AIObservatoryEngineTests/` |
| WS-UI       | `Sources/AIObservatoryUI/`                                              |

需要修改他人目录时：**不要直接改**，在 `04-决策记录/` 写一条接口变更请求，交给总控。

---

## 4. 完成的定义（Definition of Done）

一个工作流只有同时满足以下全部条件才算完成：

1. `swift build` 在**自己的工作树**内零错误、零警告。✅
2. `swift test` 全绿（新增测试数 ≥ 交付模块数）。
3. 新增公共 API 都有 `///` 文档注释。
4. Swift 6 严格并发模式下无 `@unchecked Sendable` 滥用（除有注释说明的合理场景）。
5. 已写回 Obsidian 进度日志与本工作流的简报页。
6. 未修改冻结区文件。

**未通过 `swift build` 的代码一律视为未完成。** 不要提交"稍后修"的编译错误。

---

## 5. 代码规范（Apple 官方最佳实践）

- Swift 6 语言模式，严格并发检查。共享可变状态用 `actor` 或 `OSAllocatedUnfairLock`。
- SwiftUI 视图全部 `@MainActor`，数据流用 `@Observable` + `async/await`，不用 Combine 处理新代码。
- 命名遵循 [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)。
- 错误处理：可恢复错误用 `throws`，不吞异常；不 `try!`，不强制解包外部数据。
- 禁止在主线程做 IO（磁盘扫描、哈希、diff 必须在后台）。
- 时间处理用 `Date` + `Calendar`，禁止手写时间戳算术。
- 依赖注入：协议优先，便于测试。禁止单例隐式依赖（`shared` 仅限 App 层装配）。
- 每个文件顶部注释标明 Owner 工作流代号。

---

## 6. 性能预算（硬指标）

| 指标            | 目标        | 上限        |
| --------------- | ----------- | ----------- |
| 空闲 CPU        | < 1%        | 3%          |
| 内存常驻        | < 120 MB    | 200 MB      |
| 进程扫描开销    | < 50 ms/次  | 150 ms/次   |
| 磁盘写入        | 批量提交    | 单次 ≥ 32 行 |

任何轮询都必须可配置频率，且默认值应偏向保守。

> **度量口径（2026-09-20 补，之前用错过）**：CPU 达标与否**只能按「累计 CPU 时间差 / 墙钟时间差」算**，
> 采样窗口 ≥ 60 秒。`ps -o %cpu` 是衰减平均，同一进程会在 0.0–17.1% 之间乱跳，
> 用它验收会系统性低估（实测同一窗口两种口径给出 0.4% 与 7.4% 两个数）。
> 且必须在**没有其它编译任务**的静默机器上测：机器 load 5–12 时量出来的绝对值不是结论。

### 把「空闲 CPU < 3%」换算成能动手的数（2026-09-20 总控补）

聚合百分比本身不可攻击。乘一下采样周期才有目标：**每 tick ≤ 周期 × 3%**；
当前周期 3 s ⇒ **每个 tick 的 CPU 时间必须 ≤ 90 ms**。于是一条采集链的成本是否超标变成可核对的加总
（五个阶段各花多少 ms，**加起来必须等于实测每 tick**；对不上就是漏了项）。
同理，`ΔRSS ÷ tick 数` 给「每轮留下多少不释放」，比「长跑会涨」可查得多。

两个口径不要混：**判据4 管的是本 App 这个进程**，而性能页显示的是整机 / 被观测 Agent 的读数——
那是另一个对象的尺子（见 #9 与 ADR-0006）。用整机读数去对 3% 是错的，反过来用 3% 给整机下结论也是错的。

**禁止的达标路径**：延长采样周期、"没有 agent 在跑就不扫"（新 Agent 本身要靠扫描才被发现）、
减少图表数据点、关掉某一页的刷新。这些是把判据绕过而不是把开销降下来。
合法的杠杆长这样：少做 syscall、少做分配、把 `O(N × 深度)` 的遍历换成内存图上的 `O(N)`（见 #21）。

---

## 7. 隐私与安全

- 全部数据本地存储，**禁止任何网络上传**。
- 禁止采集：文件内容明文（除 diff 所需的最小片段，且需可关闭）、密钥、环境变量中的凭据。
- **环境变量当前根本不采集**（2026-09-20 更正）：`KERN_PROCARGS2` 的读取受 `argc` 约束，
  不会遍历到 envp 区，因此"白名单过滤 env"这条是**尚未需要的能力**而不是已实现功能；
  将来若真去读环境，必须先实现白名单再谈采集。（此前把它写成"必须过滤"容易让人误以为已经在读。）
- 数据库位置由 ADR-0003 决定，四条按优先级：`AIOBSERVATORY_DATA_DIR` → 打包运行（bundle id + `.app`）
  → `~/Library/Application Support/com.aix.aiobservatory/` → 仓库内 `observatory-data/`；
  都拿不到就退到内存库（**不崩、不偷偷写到别处**）。开发/验证时一律显式设 `AIOBSERVATORY_DATA_DIR`，
  否则会把 SQLite 写到 `~/Library` 之外授权边界内——那既是越界也是隐私事故。
- 任何 `rm` / 删除类命令的实现必须走确认流程，禁止自实现静默删除。

---

## 8. 沟通格式

子代理向总控交付时，必须用如下格式回复（简洁、可机器解析）：

```
WS: <代号>
STATUS: done | blocked | partial
BUILD: pass | fail
TESTS: <通过数>/<总数>
FILES: <新增/修改的主要文件列表>
CONTRACT-CHANGE: none | <需要的契约变更>
NEXT: <下一步建议>
BLOCKERS: <阻塞项，无则 none>
```
