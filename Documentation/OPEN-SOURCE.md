# 开源准备与许可证建议（OPEN-SOURCE）

> 本文与代码同步于 **2026-09-20**（工作树 `ws/packaging` @ `f21ce7d`）。维护者：WS-Packaging/D。
>
> **2026-09-20 第 2 次核对（WS-PublicFace，工作树 `ws/publicface`）**：第 6 节清单
> **逐条实跑重判**（每项附命令与输出），并结掉第 7 节的「GitHub 是否识别根目录
> `SECURITY.md`」与第 9 节第 2 项的 SHA-256 复测。三处结论有实质变化，别按旧版本行动：
> **① B1 从「已做」回退成红**（个人路径 52 → 96，privacy-guard 必红）；
> **② C1/A5 两个门面缺口已补**（根 `README.md`、根 `SECURITY.md`）；
> **③ 本文 §5 原先把那个个人邮箱逐字写在正文里**——一处待泄漏点，已去标识化
> （讽刺的是它就在「不要重复抄写它」那条规矩的同一份文件里）。
>
> **2026-09-20 更新：owner 决策已下，`LICENSE` 已创建（提交 `f3f1c70`），选 Apache-2.0，
> 版权主体 = `Copyright 2026 AiX Project Authors`。** 本文第 1、5 节里「没有 LICENSE /
> 主体待定」的表述是**决策前的事实快照**，保留以显示依据；现状与后续待办见第 9 节。
>
> 本文原先做三件事：① 摆出影响选择的本项目事实；② 做 MIT / Apache-2.0 的逐项对比并给出推荐；
> ③ 给出一份公开前必须逐项打勾的清单（含机器可验的命令）。第 5 节那个「必须先解决的阻塞项」
> 已由 owner 拍定，不再是工程侧的悬置项。
>
> 法律文本不是法律意见。第 5、7 节涉及的具体条款，凡我没有核对原文的，一律标 **未验证**。

---

## 1. 现状（可核对的事实）

| 事实 | 依据 |
| --- | --- |
| ~~**仓库里没有 `LICENSE`**~~ → **已解决**：`LICENSE`（Apache-2.0）已于 2026-09-20 创建（`f3f1c70`）。决策前的默认状态确实是「保留所有权利」 | `git ls-files \| grep -v ^Sources` 现在含 `LICENSE`；非源码文件全集也已从 10 个增长到 21 个（新增 `Documentation/{INSTALL,PRIVACY-EVIDENCE,OPEN-SOURCE}.md`、`Packaging/*`、`Resources/PrivacyInfo.xcprivacy`、`.github/workflows/ci.yml`） |
| ~~**仓库根没有 `README.md`**~~ → **已解决**（2026-09-20，WS-PublicFace）：根 `README.md` 已创建（242 行），工程说明仍在 `Documentation/README.md`，两者分工是「首页 vs 完成度台账」 | `ls -l README.md` → 存在；`grep -c '/[U]sers/one' README.md` → 0 |
| **git 身份是个人邮箱** —— LICENSE 已经不含邮箱，但**历史里全是**（阻塞项，见第 9 节）。**2026-09-20 复测：规模从 117 涨到 263** | `git config --get user.name` → `one`；`user.email` → 一个 QQ 号邮箱（本文件刻意不再抄全它，重复一次就是再泄漏一次）。实测 `git log --all --format='%ae' \| sort \| uniq -c` → **263 个提交全部是该邮箱，作者名全为 `one`**（`--all` 覆盖全部 refs；`git log --oneline \| wc -l` 单看主线是 256）⇒ 直接把仓库推出去会把这个地址公开 263 次，与「LICENSE 不写个人邮箱」的意图相反。**处置方案已定**（§9 方案 B：公网只推压扁后的单一初始提交），未执行前不要 push |
| **没有 git remote** | `git remote -v` 输出为空 → 目前完全本地，尚未公开 |
| **零外部依赖** → 不存在第三方许可兼容性审查负担 | `Package.swift:11-139` 无一条 `.package(url:)`；10 个 target 全在仓库内（CI 已把这条做成门禁：`.github/workflows/ci.yml` privacy-guard 第 2 步） |
| 代码里出现的**第三方运行时**只有系统组件：SQLite（公有领域）、Foundation/SwiftUI/AppKit/IOKit/os（Apple SDK） | `Sources/AIObservatoryStore/SQLiteDatabase.swift` 直接封装 `sqlite3_*`；`Sources/` 的 import 全集见 `Documentation/PRIVACY.md` 第 2.2 节 |
| 源码头部注释是**中文工作流署名**（`// Owner: WS-Engine` 等），无 SPDX 头 | 例：`Sources/AIObservatoryApp/DataLocation.swift:1-15` |
| 仓库内有**个人绝对路径**残留 | 2026-09-20 复测：`grep -rl "/[U]sers/one" Sources Tests` 命中 **22 个文件**（本行原记 10 个，明细与归因见第 6 节 B1）。检索用 `[U]` 方括号形式，是为了让这条命令本身不被它自己检索的字符串命中 |
| ~~打包素材尚未纳入版本控制~~ → **已解决**（2026-09-20）：`Packaging/`、`Resources/`、`Documentation/PRIVACY-EVIDENCE.md`、`.github/`、`LICENSE` 全部已提交 | 决策前的事实快照，保留以显示依据；复核命令 `git ls-files -- Packaging Resources .github` |
| 文档承诺「100% 本地、零上传」 | `Documentation/PRIVACY.md`；`Packaging/Info.plist` 的 `NSHumanReadableCopyright`（唯一真值源，随 bundle 进「关于」面板） |

**结论**：这个仓库现在处于「**已具备工程可构建性，但不具备公开性**」的状态。
可构建性看 `Documentation/INSTALL.md`；公开性缺的第 0 步就是本文要 owner 拍板的许可证。

---

## 2. 影响选择的五个项目特征

1. **它是审计工具，输出被当作「谁做了什么」的叙述。**
   `SECURITY.md:26-28` 已明确：这些不是密码学证据、没有审计链、不能作为对第三方追责的
   司法级证据。许可证管不到这一层——**免责声明必须写在 README 和 LICENSE 之外的
   AS-IS 条款里**。MIT 与 Apache-2.0 都自带 warranty disclaimer，够用；
   但「不要把本工具的输出当法庭证据」这句产品自己的话，两者都不会替你写。
2. **它会读同机其他进程的 argv。**
   `LibprocProcessInspector` 采集可执行路径 / cwd / argv（`Documentation/PRIVACY.md` 第 5.1 节）。
   开源后这个能力会被 fork 成采集他人机器的恶意版本——这是**双用途**软件。
   许可证无法阻止，能阻止的是你的责任暴露：需要清晰的用途声明 + 明确的许可条款。
   这条特征偏向**专利授权更强**的许可证（见第 3 节「专利」维度）。
3. **多人并行贡献已经是既成事实。**
   本分支历史里已能看到 8 类工作流提交的痕迹（`git log --oneline` 中出现
   `ui` / `insights` / `engine` / `files` / `platform` / `agent` / `telemetry` / `packaging`），
   另有 `ws/risk-rules`、`ws/export` 两条分支待合（`git branch -a`）。
   一旦公开，需要**贡献者授权机制**（DCO 或 CLA），否则你不知道自己有权以何许可证分发别人的代码。
   Apache-2.0 §3 由**每个贡献者**向接收者授予专利许可，MIT 完全没有专利条款。
4. **零依赖 = 今天没有任何 NOTICE 义务。**
   选 Apache-2.0 会**新增**一个 `NOTICE` 维护负担（当前唯一值得写进去的是 SQLite 公有域声明，
   以及未来的依赖）；选 MIT 则零负担。这条特征**中性偏 MIT**。
5. **目标用户是企业内部/个人开发者自用。**
   最强的采用阻力是「我不能在公司内部闭源部署它」。因此任何带强制开源义务的许可证
   （GPL-3.0 / AGPL-3.0）都会**直接砍掉**你的目标场景 —— 见第 4 节明确排除。

---

## 3. MIT vs Apache-2.0 逐项对比

| 维度 | MIT | Apache-2.0 | 对本项目的含义 |
| --- | --- | --- | --- |
| 文本长度 | 约 170 词，1 页 | 约 5,600 词，含「如何应用」附录 | 个人项目：MIT 读者门槛更低 |
| **专利授权** | **无**任何专利条款 | §3 授予「perpetual, worldwide, non-exclusive, no-charge, royalty-free, **irrevocable**（除被下游起诉则终止）」的专利许可 | 关键差异。审计/遥测类算法容易撞上他人专利；Apache 让每个贡献者自动授予专利许可，并带**专利报复条款**（§3 终止段） |
| 版权/许可声明义务 | 保留「版权声明与许可声明」（单一条件） | §4 要求保留声明、标注修改、并**随分发附带 `NOTICE`** | 零依赖现状下 Apache 的 NOTICE 成本≈0；引入依赖后才变重 |
| 与 GPL 家族兼容 | 兼容（可并入 GPL 项目） | 兼容（Apache-2.0 → GPLv3 单向） | 若担心被 GPLv3 生态吞并，两者都挡不住；能挡住的是许可证本身选 copyleft（第 4 节） |
| 商标 | 两者都不授予商标权 | 两者都不授予商标权 | 「AiX」这个名字的权利要靠名字本身，不靠许可证（未做检索，见第 7 节） |
| 衍生分发形式 | 可以闭源发行衍生版 | 可以闭源发行衍生版 | 若 owner 未来想商业闭源，两者都不排斥；MIT/Apache 都允许别人不回馈 |
| 对「读别人进程数据」的额外限制 | 无 | 无 | 两者都**不会**替你加使用伦理条款。若要「不得用于未经机器所有者许可的监控」，需要显式加一条附加声明（会让它不再是纯 OSI 许可证）或另发一份使用政策 |
| 采用生态熟悉度 | 最高 | 高（Kubernetes / Android / Swift 工具链本身都用 Apache-2.0） | Swift/LLVM 生态就是 Apache-2.0 + LLVM exception（未逐条核对，见第 7 节）——对本项目这种 Swift 项目不算陌生 |
| 需要新增的文件 | `LICENSE` | `LICENSE`（+ 建议 `NOTICE`） | 都只影响仓库根，不影响构建 |

---

## 4. 推荐与明确排除项

**推荐：Apache-2.0**（作为 owner 未表态时的工程默认建议）。理由按权重排：

1. **专利授权与专利报复条款**——对一个可能被企业内部门署、且落在 AI/遥测这类专利密集地带的
   审计工具，这是唯一有实质区别的差别（第 3 节维度 2）。
2. **贡献者授权自带**——本项目已是八条工作流共同产出的结果，Apache-2.0 §3 的定义与授权
   结构对「贡献者 ↔ 分发者」关系比 MIT 更明确；再配 DCO 签名即可。
3. **NOTICE 机制给了未来留位置**——一旦引入外部依赖或有第三方素材（图标、字体、样例数据），
   有一个规定动作可放，不必改许可证。
4. 与 Swift 生态的主流选择一致（Swift 工具链本身即 Apache-2.0 系），对 Swift 贡献者无认知摩擦。

**次选：MIT**——如果 owner 的优先级是「最短、最好读、个人项目别像法务文件」。
那么请**同时**接受代价：没有任何专利授权，且贡献者授权只能靠 DCO + 你的自律。

**明确排除（并记录理由，避免以后重议）**：

- **GPL-3.0 / AGPL-3.0**：强制衍生开源，直接否定「企业内部闭源部署观测器」这一核心场景；
  AGPL 的网络条款对一个 100% 本地应用毫无意义（它根本不联网，`PRIVACY.md` 第 2 节）。
- **BSD-3-Clause**：与 MIT 实质等价但文本更啰嗦，只多一条「不得用作者名义推广」的背书条款；
  若选它，理由应当是品牌背书考量而非工程理由。
- **MPL-2.0**：文件级 copyleft 适合「担心被闭源吞并但不想全传染性」的场景；
  对本项目这种体量小、纯内部 target 的包，边际收益低于其复杂度。
- **CC 系列 / 「Do whatever you want」**：CC 不适合软件代码，且不处理专利。

---

## 5. 版权主体：这是**必须先解决的阻塞项**，不是文书细节

**当前配置的署名身份是一个个人 QQ 邮箱**（`git config --get user.email` → 一个 QQ 号码形式的
`…@qq.com` 地址，**本文刻意不抄全它**；`user.name` → `one`）。仓库一旦 `git push` 到公开主机：

> ✏️ **2026-09-20 去标识化（WS-PublicFace）**：本行原先**把这个邮箱逐字写了出来**，
> 与本文第 1 节自己立的规矩（「本文件刻意不再抄全它，重复一次就是再泄漏一次」）直接矛盾。
> 这份文档会随公开副本一起出去，所以它当时是一处**真实的待泄漏点**，已改为中性表述。
> 需要真值的人在本机执行 `git config --get user.email` 即可，不必靠文档保管它。
> 同类风险请一并检查其它文档：`grep -rn '<该地址>' --include='*.md' .`

1. **提交历史全部公开**，包括每条 commit 的作者邮箱与时间线——这不取决于 LICENSE 写什么。
   本项目现有 **256** 条提交（`git log --oneline | wc -l`，2026-09-20 复测；本文更早的版本写的是
   **58**，`--all` 口径则是 **263**），其中大量含工作流细节、
   验收判据与失败复盘的中文信息。
2. 许可证的版权行会把该身份**固化为法律意义上的权利人**，事后更换版权主体需要重新获得授权。

因此需要 owner 显式回答三问（本文只提问，不代答）：

| 问题 | 选项 | 影响 |
| --- | --- | --- |
| 权利人写谁？ | ① 真名 ② 长期稳定的化名/handle ③ 组织（公司/基金会） | ③ 需要该实体确实存在并愿意承担；个人项目常选 ②，但化名要**可长期持有**（邮箱会公开） |
| 用哪个邮箱？ | 个人邮箱 / 平台提供的 noreply 转发邮箱 / 专用邮箱 | 公开邮箱会收到垃圾邮件；建议用可关闭的转发地址 |
| 历史要不要脱敏？ | ① 干净重导出（squash / `git filter-repo`）② 原样公开 | 选 ① 才能改变既有 commit 的作者信息；**注意这会重写全部 hash**，与 `AGENTS.md` 第 2 节的工作流分支策略冲突，必须由总控执行并广播 |

**在 owner 回答之前，正确的做法是：不 push、不加 LICENSE。** 保持现状（私有、可构建、文档齐）
比「先公开再脱敏」安全得多。

若选 Apache-2.0，版权行放法示例（**照 Apache 附录的写法，不要把许可证正文用 `/* */` 注释进源文件**）：

```
Copyright <年份> <权利人>

Licensed under the Apache License, Version 2.0 (the "License");
...
```

若选 MIT，`LICENSE` 放许可证全文，其中版权行为 `Copyright (c) <年份> <权利人>`
〔正文的逐字格式（含首行标题写法）我**未**逐字核对，请以 SPDX 页面文本为准照抄，不要手打〕。
文本应从官方来源原样取：

- MIT：SPDX 标识符 `MIT`，许可证文本页 `https://spdx.org/licenses/MIT.html`
  （取自 choosealicense 的 MIT 页 `https://choosealicense.com/licenses/mit/`，
  其列出的唯一「Required」条件是 *License and copyright notice*；核对时间 2026-09-20）
- Apache-2.0：全文下载链接 `https://www.apache.org/licenses/LICENSE-2.0.txt`，
  含「如何应用本许可证」附录；NOTICE 义务在 §4，专利授权在 §3
  （取自 `https://www.apache.org/licenses/LICENSE-2.0`，核对时间 2026-09-20）

> `https://opensource.org/license/mit` 我尝试读取但页面只返回样式表，未能核对，
> 故**不作为出处引用**。

**关于 SPDX 头**：本项目源码注释头已经是统一的中文工作流署名格式（如
`DataLocation.swift:1-15`）。改造成 `// SPDX-FileCopyrightText: ...` + `// SPDX-License-Identifier: ...`
是一次**触及全部源文件**的风格变更，落在冻结区（`Sources/AIObservatoryCore/Contracts/**`）与
各工作流独占目录上，必须由总控统一执行，不能由文档工作流顺手做。
建议：先只在 `LICENSE`/`NOTICE` 层面合规，SPDX 头作为后续独立变更（REUSE 风格）另议。

---

## 6. 公开前清单（按顺序；标 ☑ 的是可以机器验的）

> **2026-09-20 由 WS-PublicFace 逐条实跑复核。** 下面每一项的「证据」列都是
> **在本工作树根目录真实执行过的命令与其输出**，不是推断。状态口径三选一：
> **已做** / **未做** / **不阻塞**（+ 少数标 **回退**：曾经达标、现在不达标）。
>
> **本轮复核的两条总结论**：
> 1. **A5 / C1 两个门面缺口已补**（根 `SECURITY.md`、根 `README.md`），
>    且「GitHub 是否识别根目录 `SECURITY.md`」这条**已核对为「识别」**，第 7 节相应结案。
> 2. ⚠️ **B1 从「已做」回退成红。** 个人路径棘轮上限 52，实测 **96**
>    ⇒ `.github/workflows/ci.yml` 的 **privacy-guard 作业在当前这棵树上必然失败**，
>    「CI 全绿」今天拿不到。增量全部可归因到三条车道新增的测试文件（见 B1）。

### A 组：法律与署名（owner 动作，工程不代劳）

| 项 | 状态 | 实跑命令 → 输出 |
| --- | --- | --- |
| **A1** 决定许可证 | **已做** | `head -1 LICENSE` → `                                 Apache License`；`wc -l LICENSE` → `201` |
| **A2** 决定版权主体与公开邮箱 | **已做** | `grep -n 'Copyright' LICENSE` → `189:   Copyright 2026 AiX Project Authors`；许可证正文 `grep -c '@' LICENSE` → **0**（不含任何邮箱） |
| **A3** 决定 git 历史脱敏方式 | **已做（方案已定并落地成脚本），但脚本头部的数字已过期** | `git log --all --format='%ae' \| sort \| uniq -c` → **263 个提交、100% 同一个个人邮箱**（作者名 `one`）；`git log --oneline \| wc -l` → 256。<br>⇒ `Scripts/make-public-release.sh` 头部与本文 §9.1 写的是 **117**，那是当时快照，现在应为 263。**不阻塞**：方案 B（公网只推压扁后的单一初始提交）会让这些提交根本不出现在公开副本里，数字失真只影响注释可信度 |
| **A4** 新增 `LICENSE`（+ `NOTICE`） | **已做**（`LICENSE`）／**不阻塞**（`NOTICE`） | `git ls-files LICENSE` → `LICENSE`。<br>`NOTICE` 按 §9.3 决定**不创建**，依据实测成立：`grep -c '\.package(url:' Package.swift` → **0**（零外部依赖 ⇒ 今天没有需要向下家转达的第三方 attribution） |
| **A5** `SECURITY.md` 的公开披露入口 | **已做（本轮）** | 根目录新增 `SECURITY.md`（118 行），做成**报告入口**并指向 `Documentation/SECURITY.md` 详细版；两文件不复制全文以免漂移。<br>**「GitHub 是否识别根目录 SECURITY.md」这条已核对：识别**。官方文档写明策略文件可放仓库根、`.github/` 或 `docs/` 三处，因此**不需要**再复制一份到 `.github/`（见 §7 结案行） |
| **A6** 决定支持承诺（issue/PR、DCO、CLA） | **未做** | `grep -rniE 'DCO\|Signed-off-by\|CLA\|contributor license' CONTRIBUTING.md CODE_OF_CONDUCT.md .github/` → **0 条命中**（只有无关词被匹配）。<br>⇒ 贡献者授权机制**至今没有任何书面规定**。本文 §2 特征 3 说过「八条工作流共同产出 ⇒ 这不是形式问题」。**公开前需 owner 拍**，但不硬阻塞门面工作 |


### B 组：从仓库里清出去的东西（**这些不做，公开后就是事故**）

| 项 | 状态 | 实跑命令 → 输出 |
| --- | --- | --- |
| **B1** 个人绝对路径 | ⚠️ **回退（红）** | `grep -rl "/[U]sers/one" Sources Tests \| wc -l` → **22 个文件**（本节原版记的是 10）。<br>按 CI 的真实尺子（剥掉注释）跑：`grep -rn "/[U]sers/one" Tests/ \| grep -vE ':[[:space:]]*(//\|///\|\*\|/\*)' \| wc -l` → **96**，而 `ci.yml` 的棘轮上限是 `ceiling=52` ⇒ **privacy-guard 作业在当前树上必然 `exit 1`**。<br>**生产代码侧仍然干净**：`Sources/` 同尺计数 → **0**（4 处命中全在注释里：`SQLiteDatabase.swift`、`DataLocation.swift`、`ExportWriter.swift`、`Scratch.swift`，均为「说明授权边界」的文字）；G2 写死 `.worktrees/.scratch` → **0**；G3 以个人路径字面量 `createDirectory` → **0**。<br>**增量 44 处可完全归因**（基线 52 → 96）：WS-SwiftData 六个新测试文件 **38**（`SwiftDataStoreRoundTripTests` 19、`SwiftDataMigrationTests` 10、`SwiftDataQueryParityTests` 4、`SwiftDataPredicateCapabilityTests` 2、`SwiftDataBackendDifferentialTests` 2、`SwiftDataScaleAndFormatTests` 1）+ `DetectionHygieneTests` **4** + `ResourceAbuseRiskTests` **2**。<br>⇒ 修法就是本节原版说的：合成夹具改用不含真实用户名的假根（`/Users/example/…`），落盘一律 `Scratch.directory(...)`。**这是公开前的第一阻塞项**，且它同时让「CI 全绿」变成假话。<br>**但本项原版列出的最危险子类已经清掉了**：那三个「真的会在个人路径下建目录、换机器必红」的文件现在计数均为 **0**（`grep -c '/[U]sers/one'` → `SnapshotterTests.swift` 0、`FileTrackingTests.swift` 0、`EventPipelineTests.swift` 0），且 `Scratch.` 已被 **17** 个测试文件采用。⇒ 剩下的 96 处**全是合成字符串夹具**（不落盘），是卫生问题而不是 CI 必红问题；真正让它变成 CI 红的，是「超过棘轮上限」这一条 |
| **B2** 个人笔记不进公开仓库 | **已做** | `git ls-files \| grep -c 'AiX-Vault'` → **0**（`AiX-Vault/` 是独立仓库，从未被代码仓库跟踪） |
| **B3** `AGENTS.md` 要不要一并公开 | **未做（且它本身正被 B1 打穿）** | `grep -c '/[U]sers/one' AGENTS.md` → **10 处**。<br>⇒ 根 `AGENTS.md` 的第 0 节把「唯一被授权的工作目录」写成了某个人机器上的绝对路径，直接公开等于发布本机目录布局（与本文 §8 第 1 条「不改变隐私事实」自相矛盾）。<br>本轮的处置：**README 链到 `AGENTS.md` 但不复制其内容**；要公开它，得先把那 10 处改成中性表述（例如「项目授权目录 `<authorized-workspace-root>`」）。**这是 owner 决定，不是门面能代劳的** |
| **B4** 确认没有秘密被跟踪 | **已做，但本清单原来的命令有缺陷** | 原命令 `git ls-files \| grep -Ei '\.(p12\|cer\|key\|mobileprovision\|provisionprofile\|p8)$\|\.env\|sqlite'` 实测**命中 1 行**：`Sources/AIObservatoryStore/SQLiteDatabase.swift` —— 这是**假阳性**（`sqlite` 那段没有锚点也没有 `$`，匹配到了源码文件名）。<br>修正后的命令（扩展名全部锚定行尾）：`git ls-files \| grep -Ei '\.(p12\|cer\|key\|mobileprovision\|provisionprofile\|p8\|env\|sqlite\|sqlite-wal\|sqlite-shm)$'` → **命中数 0** ✅<br>⇒ 结论不变（确实没有秘密与观测库被跟踪），但**命令要按修正版抄**，否则每次复核都会被一个源码文件名绊倒并误报「有 sqlite 文件入库」 |
| **B5** 二进制分发合规（CI 公开 `.app` 构件） | **未验证 / 不阻塞（只要走路径 A/B）** | 本轮未联网核对 Apple SDK 条款原文，维持 §7 的「未验证」定性。<br>**不阻塞**的可执行依据：只提供源码 + 使用者自构建（`Documentation/INSTALL.md` 路径 A/B）完全不触发该条款；只有走路径 C（公开 CI 构件）才需要 owner 先确认。当前仓库**无 remote、无已发布构件**（`git remote -v` → 空） |

### C 组：文档与门面（决定别人怎么理解这个仓库）

| 项 | 状态 | 实跑命令 → 输出 |
| --- | --- | --- |
| **C1** 根目录 `README.md` | **已做（本轮）** | `ls -l README.md` → 存在，**242 行 / 19,965 字节**。<br>本节原版要求的六项都在：一句话定位、**当前完成度真相**（八模块表，状态口径与验收对账单一致，④⑤ 明写「部分」）、30 秒上手、隐私承诺、**醒目免责**（「本工具的输出不可作为对第三方追责的司法级证据」单独成段）、许可证指 `LICENSE`。<br> 卫生自查：`grep -c '/[U]sers/one' README.md` → **0** |
| **C2** 截图 / GIF | **部分（有意只做两张）** | `ls -l Documentation/screenshots/` → `dashboard.png`（1,225,619 B）、`performance-whole-machine.png`（1,167,965 B），均 2560×1640 真机窗口图。<br>**为什么不是越多越好**：逐张目视核验时发现 `commands.png` 里就印着一条 `cd /Users/…` 的**真实检出路径**，Timeline / Files / Sessions 同理（那些页面渲染的就是绝对路径）。⇒ 只入库不含个人路径的两张，并在 README 里**明写为什么只放这两张**。<br>选中的第二张反而是最有价值的一张：它的 GPU 瓷贴副标题就是「整机近似值，不归属任何 Agent 进程」，温度/功耗两格显示「这台机器拿不到」——**截图本身在替我们陈述边界**。<br>原要求「放真实截图并标注阶段」已满足：两张都标了拍摄方式、日期与数据来源性质 |
| **C3** 路线图与「不要当作现状引用」的隔离 | **已做** | `Documentation/README.md` 第 5 节标题即为「路线图（尚未实现，不要当作现状引用）」，且分「已完成（勿再列为待办）」/「仍未完成」两半。根 README 复制了这条纪律（「还没做的防护」独立成表） |
| **C4** CI 公开可得 + badge | **已做（文件）／有意不放 badge** | `git ls-files .github/workflows/ci.yml` → 存在；三个 job：`privacy-guard`（隐私与仓库卫生不变量）、`build-test`（Xcode 矩阵）、`package`。<br>⚠️ **但见 B1**：privacy-guard 的 G4 棘轮今天实测 96 > 52，**这个工作流在当前树上会红**。放一个绿色 badge 会是假话，放红色 badge 是如实——所以根 README **不放任何 badge**（另有一条独立理由：`git remote -v` 为空，badge 链接无处可指） |
| **C5** 代码署名一致性（`// Owner: WS-*`） | **未做（本轮只做了一半）** | `grep -rl 'Owner: WS-' Sources/ \| wc -l` → **156 个源文件**带内部工作流署名，共 **13** 个不同代号（`WS-Agent` `WS-CmdSrc` `WS-Detect` `WS-Engine` `WS-Export` `WS-Files` `WS-Insights` `WS-InsightsMount` `WS-Perf` `WS-Risk` `WS-SwiftData` `WS-Telemetry` `WS-UI`）。<br>本节原建议「保留 Owner 行但在根 README 解释工作流含义」——README 已链到 `AGENTS.md`（所有权表在它第 3 节），但**没有逐个解释这 13 个代号**，外部读者仍会困惑。**不阻塞**门面合入，属后续文档打磨（156 个文件不在本车道可改范围） |


---

## 7. 未验证清单（不要当成已确认）

| 项 | 状态 |
| --- | --- |
| Xcode 版本 ↔ Swift 版本映射（第 1 节矩阵下界 26.2 的依据） | **未验证**，见 `.github/workflows/ci.yml` 文件头第 3 节 |
| `actions/checkout@v7` / `actions/upload-artifact@v7` 对应的 commit SHA | **未验证**（只核对了各仓库 README 展示的 tag）；建议公开后改成 SHA 固定 |
| ~~GitHub 是否识别根目录 `SECURITY.md`（还是必须 `.github/SECURITY.md`）~~ | ✅ **已核对（2026-09-20，WS-PublicFace）**：根目录即可。官方文档写明策略文件可放**仓库根、`.github/` 或 `docs/`** 三处之一，未规定优先级。⇒ 根 `SECURITY.md` 已按此建立，**不需要**再复制一份到 `.github/`。出处：[将安全策略添加到存储库](https://docs.github.com/zh/enterprise-server@3.13/code-security/getting-started/adding-a-security-policy-to-your-repository) |
| Apple SDK / 开发者协议对「公开分发 CI 构建的 .app 构件」的约束 | **未验证**，未读条款原文 |
| EndpointSecurity 相关分发限制（若未来实现 `EndpointSecurityMonitor` 的真实订阅） | **未验证**。现状无害：那条路径只做一次性能力探测且默认关闭（`Documentation/PRIVACY.md` 第 1 节、`ServiceProtocols.swift:104`） |
| 「AiX」名称是否与第三方商标冲突 | **未检索**。⚠️ 且**改名之后这一条比改名之前更需要做**：2026-09-20 名称从描述性短语 `AI Agent Activity Observatory` 换成短名 `AiX`，风险形态变了——旧名由通用描述词组成，显著性弱（因而难以主张），但几乎不会与他人的注册标志相撞；短名显著性强、可主张，可撞面却宽得多。特别注意大小写不敏感的检索会把 `AIX` 一并命中，而那是 IBM 既有的 Unix 操作系统名称（**是否构成冲突未检索，不下结论**）。 |
| SQLite 的公有领域地位 | 常识级事实，但我**未**在本次工作中核对 sqlite.org 原文 |
| Swift 工具链 / LLVM 的许可证细节（第 3 节最后一行的类比） | **未核对原文** |

引用来源（本次只读查询，未下载任何文件、未安装任何东西）：

- `https://docs.github.com/en/actions/reference/runners/github-hosted-runners`（runner 标签）
- `https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-26-arm64-Readme.md`（镜像与 Xcode 清单）
- `https://choosealicense.com/licenses/mit/`、`https://spdx.org/licenses/MIT.html`（MIT）
- `https://www.apache.org/licenses/LICENSE-2.0`、`https://www.apache.org/licenses/LICENSE-2.0.txt`（Apache-2.0）
- `https://github.com/actions/checkout`、`https://github.com/actions/upload-artifact`（action 版本）

---

## 8. 开源**不改变**的三件事（防止误读）

1. **不改变隐私事实。** 零上传是代码性质（`PRIVACY.md` 第 2 节的 import 全集论证 +
   ci.yml 的可执行门禁），与选哪个许可证无关。反过来，选了 Apache 也不会让
   「数据库里有你的命令行参数」这件事变得不那么重要。
2. **不改变信任模型。** ad-hoc 签名、无公证、无制品哈希（`SECURITY.md:86`）不会因为源码公开
   就变成供应链保护。公开源码只是让**可复现构建**成为可能——要走到那一步还需要
   制品哈希发布与（可选）SLSA 式证明，本文不声称其存在。
3. **不改变完成度。** 本文第 6 节 C2 的理由同样适用于许可证：一个骨架阶段的仓库
   最适合的声明是「阶段 0.x、许可证 X、按现状提供、无支持承诺」，
   而不是用宽松许可证营造成熟度错觉。

---

## 9. 已下的决定与仍待办（2026-09-20，owner 拍定）

**决定**

- 许可证：**Apache-2.0**；`LICENSE` 已创建于仓库根（提交 `f3f1c70`）。
- 版权主体：**`Copyright 2026 AiX Project Authors`**，不写任何个人邮箱；
  后续可换成正式组织名（见下面的改动面）。
- 口径归一：`Packaging/Info.plist` 的 `NSHumanReadableCopyright` 已与 LICENSE 对齐为
  `© 2026 AiX Project Authors · Apache-2.0 · 数据仅存本机，不上传 · Local-only…`。

**换组织名时的改动面（2026-09-20 重测）**：`grep -rli "copyright\|SPDX-License" Sources Tests Scripts Packaging`
→ 命中 **1** 个文件（`Packaging/Info.plist`；另一处命中来自已退役的旧打包脚本 heredoc，
随打包路径合一一起消失了）。
所以换名只有两处：`LICENSE` 第 189 行 + `Packaging/Info.plist` 的 `NSHumanReadableCopyright`（`:99`）。
源文件头没有逐文件版权头 / SPDX 标识，无需批量改；如果将来要加 SPDX 头，那是一次
**独立决策**（会牵动所有源文件），别顺手做。

**待办（公开前必须清）**

1. ⚠️ **git 历史里的个人邮箱 —— 这是新的公开前阻塞项。**
   实测 `git log --all --format='%ae' | sort | uniq -c` →
   **263 个提交、100% 同一个个人邮箱，作者名 `one`**（`--all` 覆盖全部 refs；
   2026-09-20 WS-PublicFace 复测，本条原写 **117** —— 规模在六天内翻了一倍多，
   这本身说明「等历史稳定再处理」不是会自愈的问题）。
   ⇒ LICENSE 不写邮箱并**不**等于不泄漏：推公网会把该地址公开 263 次。三条路让 owner 选：
   (a) 用 `git filter-repo --mail-map` 重写历史（需先安装该工具，本工作流受「不得装东西」约束**未执行**）；
   (b) 公开前压成单个初始提交（0.x 阶段最省事，代价是丢历史）——**已由 `Scripts/make-public-release.sh` 落地**；
   (c) 明确接受公开该地址。
   **未处理前不要推公网**，哪怕许可证文件是干净的。
   另注：`AiX-Vault/.git` 是另一个仓库、同样带该身份；若只公开代码仓库则不受影响。
   ⚠️ **本轮新发现的同源泄漏**：本文 §5 原先把这个邮箱**逐字写在了文档里**（已去标识化）。
   发布前自检请**两道都跑**，因为它们互相不覆盖：
   `git log --all --format='%ae' | sort -u`（历史里的作者邮箱）
   与 `grep -rn '<该地址>' --include='*.md' --include='*.yml' .`（**文档正文里抄写的**邮箱）。
   `Scripts/make-public-release.sh` 现在**两道都覆盖**：自检① 除了查历史邮箱，还会 grep 副本正文里有没有抄写过那个地址（①-b）。
2. **LICENSE 逐字节核对**：正文取自 apache.org，结构自查已过（201 行、9 条款、
   `END OF TERMS` 在 176、`APPENDIX` 在 178、无 `@`），但换行位置无法离线证明逐字节相同。
   有网络者执行：`curl -s https://www.apache.org/licenses/LICENSE-2.0.txt | diff - LICENSE`
   （唯一预期差异应是附录里被替换掉的那行版权声明）。当前 SHA-256：
   `a8a4db98130ef93a57170ab1ce403d2b2924afcc330bc6dfa5878850df40a998`。
   ✅ **2026-09-20 WS-PublicFace 复测：`shasum -a 256 LICENSE` 与上面这串逐字符一致**，
   四项结构自查各自复现（`wc -l` → 201；`grep -n 'END OF TERMS'` → 176；
   `grep -n 'APPENDIX: How to apply'` → 178；`grep -c '@'` → **0**）。
   ⚠️ **抄命令的人注意**：条款标题行**带三个前导空格**，所以数条款要用
   `grep -cE '^ +[0-9]+\. [A-Z]' LICENSE` → **9**；用 `grep -cE '^[0-9]+\.$'` 会得到 **0**
   并误判成「许可证正文缺条款」。
3. **`NOTICE` 暂不创建**：当前零外部依赖，没有需要向下家转达的第三方 attribution；
   引入依赖时按 §4(d) 随附，届时别把项目自己的版权声明塞进 NOTICE（那是两个东西）。
4. `.gitignore` 仍缺签名材料模式（`*.p12 *.cer *.key *.mobileprovision *.provisionprofile
   AuthKey_*.p8`、`*.dSYM/`、`.env*`）；`.scratch-tests/` 总控已补（`:35`）。
   `ci.yml` 的 privacy-guard 已在守「这些文件不得被跟踪」。
   ⚠️ **2026-09-20 WS-PublicFace 复测：本条仍然成立（未做）**——
   `grep -nE '\.p12|\.cer|\.key|mobileprovision|provisionprofile|AuthKey|dSYM|\.env' .gitignore`
   → **无任何命中**。现状是「ci.yml 在守，但 .gitignore 没拦」：
   门禁能防止它们被**提交**，防不住它们在本地被 `git add -A` 时先进暂存区再报错这一步摩擦。
   标 **不阻塞**（有 ci 兜底），但补它是纯收益。
5. **G4 棘轮往下清 —— ⚠️ 本条已失效，棘轮被冲破。** 原写「`Tests/` 里 52 处合成个人路径
   按 owner 批准只降不升」；2026-09-20 实跑 `ci.yml` 的同一把尺子
   （`grep -rn "/[U]sers/one" Tests/ | strip_comments | wc -l`）→ **96**，
   上限 `ceiling=52` 已被**超出 44 处** ⇒ **privacy-guard 在当前树上必红**，
   「CI 全绿」这句话今天不成立。增量归因见 §6 B1（WS-SwiftData 38 + `DetectionHygieneTests` 4
   + `ResourceAbuseRiskTests` 2）。
   替换目标用与个人无关的假根（`/Users/example/…`；`/var/…` 仅可用于**不落盘**的输入，
   因为 `ExportPathPolicy.forbiddenPrefixes` 含 `/var`、`/private`），落盘一律 `Scratch.directory(...)`。
   **两条路选一**：把这 44 处清到 ≤52（推荐，且 `Sources/` 侧已经是 0），
   或由 owner 显式把上限抬到新的真实值并在 ci.yml 注释里写清是谁批准的——
   **不要**为了让 CI 变绿而直接抬高 ceiling 却不删路径，那只是把卫生问题改成谎言。
