# 参与贡献（CONTRIBUTING）

本仓库是 **AiX**（AI Agent 活动审计台）：一款 100% 本地运行、零上传的 macOS 26 原生应用，
用于审计本机 AI Agent（Codex / Claude Code / Cursor Agent 等）的执行记录、资源消耗、
文件变化、终端行为与系统影响。**它的卖点就是隐私**，所以贡献流程里的很多"麻烦"都服务于
一件事：不把任何人的机器足迹、个人地址或真实数据带进仓库。

> 本文里的每条命令与路径都可在仓库内核对（写它们的时候就是这么验的）。
> 若你发现某条与代码不一致，那算缺陷 —— 请开 issue，别迁就文档。

---

## 1. 动手前先读三样

| 文件 | 为什么 |
| --- | --- |
| `AGENTS.md`（仓库根） | **强制约束**：授权边界、工作树纪律、文件所有权（冻结区）、完成的定义、代码规范、性能预算、隐私与安全 |
| `Documentation/README.md` 第 1 节 | 当前**真实完成度**表。哪些模块已实现、哪些还没接线，都以它为准 |
| `Documentation/PRIVACY.md` §1 / §5 / §7 | 数据落在哪、正在采集什么、尚未实现什么。改采集面必须同步它 |

## 2. 环境

- macOS 26+、Apple Silicon。`Package.swift` 声明 `tools-version: 6.2` 与 `.macOS("26.0")`，
  Swift 语言模式为 `swiftLanguageModes: [.v6]`（严格并发）。
- 零外部依赖：`Package.swift` 里没有任何 `.package(url:)`。加依赖需要专门讨论
  （许可证审查、静态加密与"零上传"论证都会受影响，`.github/workflows/ci.yml` 的
  privacy-guard 作业会把"出现外部依赖"当成失败）。

## 3. 构建与测试：本地必须带 `--disable-sandbox`，公开 CI 上禁止

```bash
xcrun swift build --disable-sandbox            # 调试构建
xcrun swift test  --disable-sandbox            # 全量测试
Scripts/verify.sh                              # 上面两步的自检封装
```

**为什么本地要带**：常见的开发/自动化环境本身已经跑在 sandbox 里，SwiftPM 再嵌套一层
`sandbox-exec` 会直接失败并报 `sandbox_apply: Operation not permitted`。
**为什么 CI 上不能带**：托管 runner 没有外层 sandbox，加了它既多余，又会永久掩盖
「SwiftPM 沙箱兼容性回归」这一类真实问题。`.github/workflows/ci.yml` 有一步专门检查
非注释行里不得重新出现该 flag，出现即失败。

判据一句话：它是**环境补丁**，不是这个包的构建要求。在自己机器上（没套沙箱）直接
`xcrun swift build` 才是更接近真实用户的路径。

打包成 `.app` 只有一条入口：

```bash
Packaging/make-app.sh            # 六步：前置校验→构建→组装→元数据与资源→签名→验证
AIX_SPM_SANDBOX_FLAG="" Packaging/make-app.sh   # CI 形态（还原 SwiftPM 默认沙箱行为）
```

## 4. 工作方式（本仓库的规矩，都是踩过坑留下的）

1. **一条工作流一个独立工作树**：`Scripts/new-worktree.sh <name>` 建
   `.worktrees/<name>` + 分支 `ws/<name>`；合并用 `Scripts/merge-workstream.sh <name> [--keep]`。
   不要跨工作树改文件，也不要直接往主线分支提交。
2. **冻结区**（见 `AGENTS.md` 第 3 节的所有权表）不要改。需要别人目录配合时，
   先开 issue 说清接口诉求，由维护者落刀。
3. **每完成一个文件就提交一次**，一次提交只做一件事，提交信息写"为什么"。
   崩溃/中断时别人能从分支恢复你已完成的部分。
4. **禁止 `perl -pi` / `sed -i` 之类的批量替换**改代码。它会在"看起来一样"的地方
   悄悄改坏语法正确的 Swift/SwiftUI 代码，且极难在 diff 里发现。逐处显式编辑。
5. **跨文件引用不要用行号**。用符号名（`ObservatoryEngine.start`、`Scratch.directory`）
   或文档章节名。带行号的引用每次合并都会漂移——本项目为此返工过多次。

## 5. 测试规范（这几条会让"CI 全绿"变得可信或不可信）

- **不要把绝对个人路径写进测试**。需要落盘就用
  `Sources/AIObservatoryTestSupport/Scratch.swift`：
  `Scratch.root` / `Scratch.directory("purpose")` / `Scratch.path(...)`，
  默认根是当前检出自带的 `.scratch-tests/`，可用环境变量 `AIOBSERVATORY_TEST_SCRATCH` 覆盖。
  曾有十余处落盘用例硬编某台机器的绝对路径，结果托管 CI 只能对它们
  `continue-on-error`——"全绿"就永远是假的。
- **不要"顺手"改用 `FileManager.temporaryDirectory`**：macOS 的 `$TMPDIR` 是
  `/var/folders/…`，而 `ExportPathPolicy.forbiddenPrefixes` 含 `/var` 与 `/private`，
  导出层自己的隐私策略会拒掉那种根。`/var` 开头的路径只能用于**不真正落盘**的合成输入。
- **每个可能长时间跑的测试都要设 `.timeLimit`**（`@Suite(…, .timeLimit(.minutes(1)))`）。
  本项目大量用真实轮询、FSEvents、子进程，没有时限的挂起会把整条闸门拖死。
- 测试**不得联网**、不得写用户数据目录、不得改动工作树（CI 有断言：
  出现 `observatory-data/`、仓库内 `.scratch-tests/`、
  `~/Library/Application Support/com.aix.aiobservatory` 或 `git status` 变脏都算失败）。
- **真机验证用完的数据库必须删**。它里面是你真实的进程清单、路径与命令行：
  ```bash
  AIOBSERVATORY_DATA_DIR=/path/inside/repo/tmp/verify open dist/AIObservatory.app
  rm -rf /path/inside/repo/tmp/verify        # 验证完立刻删
  ```
  `AIOBSERVATORY_DATA_DIR` 由 `Sources/AIObservatoryApp/DataLocation.swift` 解析，
  优先级为：显式覆盖 → 打包运行（bundle id + `.app`）→ 仓库内 `observatory-data/` → 内存库。
  不带这个变量去跑验证，等于把观测结果写到仓库之外。

## 6. 性能预算（`AGENTS.md` 第 6 节）

空闲 CPU < 1%（上限 3%）、常驻内存 < 120 MB（上限 200 MB）、单次进程扫描 < 50 ms（上限 150 ms）。

**度量口径**：CPU 只能按「累计 CPU 时间差 / 墙钟时间差」算，窗口 ≥ 60 秒。
`ps -o %cpu` 是**衰减平均**，同一进程会在 0.0–17.1% 之间乱跳，用它验收会系统性误判。
而且必须在**没有其它编译任务**的静默机器上测——机器 load 5–12 时量出来的绝对值不是结论。
当前实测状态：空闲 CPU 达标，常驻内存超出 200 MB 上限（见 `Documentation/README.md` 第 3 节），
且仓库里**没有**自动化性能门禁。别在 PR 描述里声称"满足性能预算"。

## 7. 两条会咬人的签名/权限事实

- **`*.entitlements` 里不能写 XML 注释**。`codesign --entitlements` 用 AMFI 的严格解析器，
  带注释能通过 `plutil -lint` 却在签名时 `AMFIUnserializeXML: syntax error`。
  参数说明请写进 `Packaging/ENTITLEMENTS-NOTES.md`。（`Info.plist` 不受此限制。）
- **受控 entitlement 签进 ad-hoc 包会让 App 启动即 SIGKILL**。把
  `com.apple.developer.endpoint-security.client` 签进去，`codesign --verify --strict`
  照样通过，但进程起不来（实测退出码 137）。
  今天真正生效的采集路径是**非特权 libproc 轮询**；EndpointSecurity 只有一个能力探测器，
  不订阅事件流（见 `Packaging/ENTITLEMENTS-NOTES.md` 第 2 节）。
  ⇒ 不要因为"代码里有"就在文档里写"支持 ES 实时监控"。

## 8. 提 PR 前自查

```bash
xcrun swift build --disable-sandbox 2>&1 | grep -c "warning:"   # 期望 0
xcrun swift test  --disable-sandbox                             # 全绿
git grep -n "/[U]sers/$(id -un)" -- Sources Tests Scripts Documentation .github | wc -l   # 期望 0
git status --porcelain                                          # 期望空（测试没污染工作树）
```

最后一条不是洁癖：绝对个人路径一旦进公开仓库，就等于发布你的本机目录布局。

## 9. 发布

维护者用 `Scripts/make-public-release.sh` 生成公开副本：它把仓库压扁成**单一初始提交**并跑四道
自检（① 作者邮箱——历史与文档正文各查一次、② 绝对个人路径、③ 副本能否独立构建、
④ 图像资产）。④ 是**故意**要人签字的：`grep` 只能查到以文本形式存在的路径（EXIF/XMP 这类
chunk），查不到**渲染进像素**的那一行目录名；截图必须逐张用眼睛看过才算过。压扁的理由与不做的事写在该脚本头部与 `NOTICE`：
内部历史的每个提交都带作者的私人邮箱，而 git 历史一旦公开不可撤回。

**任何人都不应自行 `git push` 到公网。** 推送需要仓库所有者明确同意（见 `NOTICE`）。
