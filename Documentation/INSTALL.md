# 安装与运行（INSTALL）

> 本文与代码同步于 **2026-09-20**（工作树 `ws/packaging` @ `f21ce7d`）。
> 维护者：WS-Packaging/D。所有「已实现」断言均附代码位置（`文件:行`，相对仓库根）。
> 凡我没有实机验证的内容，明确标注 **未验证**，不当作现状。

配套阅读：`Documentation/README.md`（完成度表）、`Documentation/PRIVACY.md`（数据足迹）、
`Documentation/SECURITY.md`（信任模型与签名现状）。四者不一致时**以代码为准**。

---

## 0. 三条安装路径，先选一条

| 路径 | 你要有什么 | 产出 | 适合谁 |
| --- | --- | --- | --- |
| **A. 源码直接跑** | Xcode 26.2+ / macOS 26 | `.build/debug/AIObservatory`（裸可执行文件） | 想最快看到东西、开发者 |
| **B. 本机构建 .app** | 同上 | `dist/AIObservatory.app` | 想长期用、要 Dock/菜单栏身份 |
| **C. 取 CI 产物** | 一个 GitHub Actions 构件（artifact） | `AIObservatory.app`（ad-hoc 签名） | 不想装 Xcode；但仍需你自己信任该构件 |

**没有的路径**：App Store、Homebrew、Developer ID 签名、Apple 公证（notarization）。
当前发行链路上没有任何供应链保护（`SECURITY.md:86`），别把「能装上」当成「被验证过」。

---

## 1. 前置条件

| 项 | 要求 | 依据 |
| --- | --- | --- |
| 操作系统 | macOS **26.0+**。低于 26.0 时打包版会被系统直接拒绝启动 | `Package.swift:14` `.macOS("26.0")`；`Packaging/Info.plist` 的 `LSMinimumSystemVersion 26.0` |
| 工具链 | Swift **6.2+**。〔「Xcode 26.2 = Swift 6.2」这一映射我**未验证**，只是矩阵下界取它的理由见 `.github/workflows/ci.yml` 文件头第 3 节〕CI 镜像 `macos-26` 默认 Xcode 26.6 | `Package.swift:1` `swift-tools-version: 6.2`；镜像事实取自 [macos-26-arm64-Readme](https://raw.githubusercontent.com/actions/runner-images/main/images/macos/macos-26-arm64-Readme.md)（核对 2026-09-20） |
| 架构 | 目标 Apple Silicon（arm64）。**打包脚本不带 `-arch`**，所以产物架构 = 构建主机架构，不是通用二进制 | `Packaging/make-app.sh:163-166`（`swift build` 无 `-arch`），实测产物 `Mach-O thin (arm64)` |
| 依赖下载 | **无需联网取依赖**：`Package.swift` 未声明任何外部 target 依赖，10 个构建 target（另有 6 个测试 target）全在仓库内 | `Package.swift:11-139`；CI 有门禁（`.github/workflows/ci.yml` privacy-guard 第 2 步） |
| 特权 | 不需要 root、不需要关闭 SIP、不需要 entitlement。生效的采集路径是非特权 libproc 轮询；EndpointSecurity 开关默认 `false` 且未接入 | `Sources/AIObservatoryCore/Contracts/ServiceProtocols.swift:104`；`SECURITY.md` 第 2 节 |
| 磁盘 | release 构建 + `.build` 中间产物；本项目自述本机环境为 macOS 26.5.2 / Swift 6.3.3 / arm64（未在本机复测） | 简报 `AiX-Vault/02-子代理简报/WS-Packaging.md:71` |
| 测试规模 | `Tests/` 下 grep 到 **358** 个 `@Test` 标注、26 个测试文件。这是静态计数，**不是通过数** | `grep -ro '@Test' Tests \| wc -l` |

---

## 2. 路径 A：从源码跑起来

```bash
git clone <你的仓库地址> ai-observatory
cd ai-observatory

# 调试构建 + 全量测试（本地必须带 --disable-sandbox，原因见第 3 节）
xcrun swift build --disable-sandbox
xcrun swift test  --disable-sandbox

# 一条命令做完整自检（内部就是上面两条，Scripts/verify.sh:15,19,24）
Scripts/verify.sh

# 启动（`--show-bin-path` 给出 .build/debug 的确切位置，同 Packaging/make-app.sh:166 的取法）
"$(xcrun swift build --disable-sandbox --show-bin-path)/AIObservatory" &
```

裸可执行文件会被 `AppDelegate` 显式提升为前台应用（`Sources/AIObservatoryApp/AIObservatoryApp.swift:88-96`），
所以你**会**在 Dock 看到它，尽管它不是 bundle。窗口关闭不会退出进程（同文件 `:94-96`），
退出用 ⌘Q。

**这条路径的数据不会写进 `~/Library`。** 见第 6 节。

---

## 3. 关于 `--disable-sandbox`：本地必需，公开 CI 上禁止

这是本项目最容易踩错的一条，单独写一节。

**本地为什么必需。** 开发执行环境**本身**就跑在 sandbox 里；SwiftPM 默认还会为构建/测试
再起一层 `sandbox-exec`，嵌套失败时报：

```
sandbox_apply: Operation not permitted
```

所以本地必须显式关掉 SwiftPM 那一层。出处：`AiX-Vault/05-失忆防护/必读.md:93-103`。
仓库里两个脚本硬编码了它：`Scripts/verify.sh:15,19,24`、`Scripts/merge-workstream.sh:41`；
唯一打包入口 `Packaging/make-app.sh` 把它参数化成 `AIX_SPM_SANDBOX_FLAG`（见第 3 节末与第 4 节）。

**公开 CI 上为什么禁止。** GitHub 托管 runner 没有外层 sandbox，嵌套问题不存在，
因此在那里加这个 flag：

1. 不起任何作用（多余）；
2. 会**永久掩盖**「SwiftPM 沙箱兼容性回归」这一类真实问题——本项目大量用真实系统调用
   （libproc / FSEvents / SQLite），沙箱兼容性本身就是需要被 CI 照到的面。

所以 `.github/workflows/ci.yml` 的所有构建/测试命令一律不带该 flag，并且 workflow 里有一步
自检：一旦有人在非注释行重新引入它，CI 直接失败。

**判据一句话**：`--disable-sandbox` 是「**宿主已在沙箱内**」的环境补丁，
不是这个包的构建要求。换一台普通 Mac（你自己的机器、没套沙箱）就用
`xcrun swift build`，不带 flag——那才是更接近真实用户的构建路径。

**CI 为什么不调用 `Scripts/verify.sh`**：它内部硬编码了该 flag，在托管 runner 上属于
「多余且会掩盖真实回归」那一类。
打包入口 `Packaging/make-app.sh:141-152` 读 `AIX_SPM_SANDBOX_FLAG` —— 未设置时保留本地默认
`--disable-sandbox`，**显式设为空串时不带任何 flag**（注释里明说这是 CI 形态）。
CI 因此按 `AIX_SPM_SANDBOX_FLAG="" ./Packaging/make-app.sh` 调用它，
并且**只有这一条路径**：workflow 里不再内联第二份组装逻辑（那样 CI 验的包就不是你出货的那个）。

---

## 4. 路径 B：打包成 `dist/AIObservatory.app`

```bash
Packaging/make-app.sh                # 唯一打包入口
open dist/AIObservatory.app
```

脚本按六步走，每步都在运行时打印 `==> n/6`（位置 = `Packaging/make-app.sh` 的行号）：

| 步 | 内容 | 位置 |
| --- | --- | --- |
| 0/6 | 前置校验：plist 与 entitlements 合法；`CFBundleExecutable`/`CFBundleIdentifier` 与脚本常量一致（挡住改名后数据库**静默**退回仓库内，ADR-0003）；`AIX_DIST_DIR` 必须落在仓库内 | `:83-131` |
| 1/6 | `xcrun swift build --disable-sandbox -c release --product AIObservatory`，再用 `--show-bin-path` 定位可执行文件；该 flag 已参数化 | `:136-170` |
| 2/6 | 造 `Contents/MacOS` + `Contents/Resources`、拷可执行文件、写 `Contents/PkgInfo`（`APPL????`） | `:174-190` |
| 3/6 | `Info.plist` 从 `Packaging/Info.plist` **原样拷入**（唯一真值源）；`Resources/PrivacyInfo.xcprivacy` 装进 `Contents/Resources/`；`CFBundleIconFile` 只在仓库里真有 `.icns` 时才写 | `:193-237` |
| 4/6 | ad-hoc 签名**带 `--entitlements`**；不用已弃用的 `--deep`，改为内层→外层逐个签；**签名失败 = 非零退出 + 报错行** | `:239-276` |
| 5/6 | 打印验证：`codesign --verify --strict`、`-dvvv`（身份/flags）、**实际嵌入的 entitlements**、`spctl -a`、`plutil -p` | `:280-319` |
| 6/6 | 写 `dist/build-info.txt`：版本、最低系统、签名身份、entitlements 档位、清单/图标有无、exe 与 plist 的 SHA-256 | `:322-341` |

签名与校验都是门禁（`die` 在 `:275`，第 5/6 步的 `--verify --strict` 也硬失败），
所以**不需要**「怀疑脚本的 ✅」。仍建议自己复查这三条（括号里是本轮实测输出）：

```bash
codesign --verify --strict --verbose=2 dist/AIObservatory.app
    # valid on disk / satisfies its Designated Requirement
codesign -d --entitlements - dist/AIObservatory.app
    # [Dict]  ← BASE 档是**有意空 dict**，理由见 Packaging/ENTITLEMENTS-NOTES.md 第 1 节
spctl -a -vv -t exec dist/AIObservatory.app
    # rejected —— ad-hoc 无 Developer ID、未公证，属预期，不是缺陷
```

CI 形态（还原 SwiftPM 默认沙箱行为）：

```bash
AIX_SPM_SANDBOX_FLAG="" Packaging/make-app.sh
```

可选档（EndpointSecurity entitlement）**默认不签**；`AIX_ES_ENTITLEMENTS=1` 会签上，
而实测那样出的 ad-hoc 包**启动即被 SIGKILL** —— 见 `Packaging/ENTITLEMENTS-NOTES.md` 第 2.2 节。

打包版与裸可执行文件的**行为差别不止是图标**：只有打包版会命中「正式运行」判据，
从而把数据库写到 `~/Library/Application Support/`。见第 6 节。

---

## 5. 路径 C：使用 CI 产物

1. 打开仓库的 Actions 页 → 选一次 `CI` 运行（`build-test` 通过后 `package` 作业才有产物）。
2. 下载 `AIObservatory-macos26-arm64-xcode<版本>` 构件（保留 14 天，见 `.github/workflows/ci.yml` 上传步骤）。
3. 解压后按第 7 节处理 Gatekeeper。

关于这个产物要知道的事实：

- 它由 `macos-26`（arm64）构建，**不是通用二进制**；
- 它是 **ad-hoc 签名**、无 Developer ID、未公证 → `spctl -a` 预期失败；
- CI 与本地用的是**同一个入口**：`AIX_SPM_SANDBOX_FLAG="" ./Packaging/make-app.sh`
  （唯一差别就是那个 flag）。workflow 里不再有第二份内联组装逻辑 —— 以前那份自己写的
  最小 `Info.plist` 连 `NSHumanReadableCopyright` 都和 `Packaging/Info.plist` 不一致，
  等于「CI 验的包不是你出货的包」；现在入口脚本缺失会**硬失败**（`::error::` + 退出），
  不会静默退回另一条路径。
- 产物**含**隐私清单与 BASE entitlements（这两样都在版本控制里，由入口脚本拷入 / 签入）。
- CI **从不启动**这个 app：工作流里没有 `open` 步骤，并有断言保证 CI 上没生成过数据目录。
  也就是说构件没有经过任何运行期冒烟测试。

---

## 6. 第一次启动：数据到底落在哪里

判据是「**谁在运行这个二进制**」（`AiX-Vault/04-决策记录/ADR-0003-数据库落盘位置.md`），
实现在组合根：`Sources/AIObservatoryApp/DataLocation.swift:23-31`，
被 `Sources/AIObservatoryApp/AIObservatoryApp.swift:24-27` 消费。

| 序 | 条件 | 数据库目录 | 代码位置 |
| --- | --- | --- | --- |
| 1 | 环境变量 `AIOBSERVATORY_DATA_DIR` 存在且**非空** | 该目录（自定义部署 / 测试注入） | `DataLocation.swift:24-26` |
| 2 | **正式运行**：`Bundle.main.bundleIdentifier == com.aix.aiobservatory` **且** `bundleURL.pathExtension == "app"` | `~/Library/Application Support/com.aix.aiobservatory/` | `DataLocation.swift:27-29`，判据 `:34-38` |
| 3 | 其他（SwiftPM 裸可执行文件、Agent/CI 驱动的运行） | **仓库内** `observatory-data/`：从当前目录向上最多 6 层找 `Package.swift` | `DataLocation.swift:30`，实现 `:42-53` |
| 3′ | 规则 3 找不到仓库根 | 系统临时目录 `AIObservatoryDev/` | `DataLocation.swift:52` |
| 4 | 目录创建失败 | 返回**空串** → Engine 退化为 **内存库**，不崩溃、也不偷偷改写别处 | `DataLocation.swift:55-64` → `ObservatoryEngine.swift:122-125` |

双条件判据（bundle id **加** `.app` 后缀）是为了避免 SwiftPM 产物因继承了某些 bundle 信息
而被误判成正式安装（`ADR-0003` §决策）。

落盘的文件长什么样：

```
<上表目录>/observatory.sqlite        # ObservatoryEngine.swift:125
<上表目录>/observatory.sqlite-wal    # WAL 模式开启：SQLiteDatabase.swift:589-591
<上表目录>/observatory.sqlite-shm    #   （内存库不支持 WAL，会跳过：:184）
```

表结构含 `agents / sessions / events / file_changes / diffs / commands /
perf_samples / system_perf / risk_events / projects / file_snapshots`
（`Sources/AIObservatoryStore/StoreSchema.swift:116-370`）。

自查（只读命令）：

```bash
ls -la ~/Library/Application\ Support/com.aix.aiobservatory/ 2>/dev/null || echo "（打包版数据目录尚未创建）"
ls -la observatory-data/ 2>/dev/null || echo "（开发期数据目录尚未创建）"
sqlite3 observatory-data/observatory.sqlite '.tables'          # 若你装了 sqlite3 CLI
```

**四条容易被读错的边界，如实说明：**

1. **设置不持久化。** 全仓库没有任何 `UserDefaults` 调用点（`Sources/` 内该词只出现在注释
   `Sources/AIObservatoryUI/Settings/SettingsModel.swift:14`：「不写 UserDefaults、不写文件」），
   `SettingsStoring` 协议也没有实现 → 你改的开关重启后回到默认值。
2. **自动保留 30 天。** 默认 `retentionDays: 30`（`ServiceProtocols.swift:103`），
   清理节奏 24 小时一次（`ObservatoryEngine.swift:163`，执行点 `:830-832`）。
   「卸载即无痕」只对**数据库文件**成立，见第 9 节第 5 条（统一日志不受本应用控制）。
3. **同用户可读。** 数据库里含路径与命令行参数这类敏感字段（`PRIVACY.md` 第 5.1 节），
   文件按你的用户权限存放、**无静态加密**（`PRIVACY.md` 第 8 节）。
   同一账户下的任意进程都能读它；把观测数据放在多用户机器上时要按这个前提考虑。
4. **可能触发系统授权弹窗（未验证）。** 当被监控目录落在 `~/Desktop`、`~/Documents`、
   `~/Downloads` 等 TCC 保护目录下时，首次做文件快照/diff 读取**预期**会弹权限窗。
   这条是从 macOS 的 TCC 行为推断的，作者受工作流约束未实机运行打包产物，**未验证**。
   现象会是「弹窗 + 该目录下读不到内容」，不是崩溃。

---

## 7. Gatekeeper 与「无法打开」

事实基线：产物只有 ad-hoc 签名（`Packaging/make-app.sh` 第 4/6 步），没有开发者身份、没有公证
→ `spctl -a` **预期失败**，这是设计现状而不是 bug（`SECURITY.md:66-86`）。

| 来源 | 会带 quarantine 扩展属性吗 | 怎么打开 |
| --- | --- | --- |
| 你本机 `Packaging/make-app.sh` 产出（路径 B） | **不会**（quarantine 是浏览器/邮件等下载工具打的） | 直接 `open dist/AIObservatory.app` |
| Actions 构件（路径 C），用浏览器下载并解压 | **会** | 右键 → 打开，或在**系统设置 → 隐私与安全性**点「仍要打开」 |

明确知情后才考虑（会**降低**一层系统保护，别做成日常习惯）：

```bash
xattr -l dist/AIObservatory.app                          # 先看有没有 com.apple.quarantine
xattr -dr com.apple.quarantine dist/AIObservatory.app    # 只清你信任的那一个包；不要用 xattr -cr 批量清
```

按症状定位：

- **「应用已损坏，无法打开」**：先查系统版本与架构（低于 macOS 26.0 直接不满足
  `Packaging/Info.plist` 的 `LSMinimumSystemVersion`），再用第 4 节那三条 `codesign` 命令
  复查签名是否真的存在（入口脚本在签名与校验两处都会硬失败，所以「看起来签好了却没签」
  这条路已经堵死；但仍然值得复查，因为**别人转给你的包**不经过这个脚本），
  最后才怀疑别的。
- **打开后 Dock 有图标但没有窗口**：主窗口是 `Window(id: "main")`
  （`AIObservatoryApp.swift:49-52`），菜单栏常驻另有一个 `MenuBarExtra`（`:79-84`）。
  若窗口在别的 Space，用 Mission Control 找；⌘Q 退出后重开。
- **提示需要更新 Xcode / 构建期 tools-version 报错**：见第 10 节第 2 行。

---

## 8. 性能预期（照抄预算，不声称达标）

以下是 `AGENTS.md` **第 6 节**的硬指标表，逐格照录：

| 指标 | 目标 | 上限 |
| --- | --- | --- |
| 空闲 CPU | < 1% | 3% |
| 内存常驻 | < 120 MB | 200 MB |
| 进程扫描开销 | < 50 ms/次 | 150 ms/次 |
| 磁盘写入 | 批量提交 | 单次 ≥ 32 行 |

**本文不声称当前产物达到这些数字。** 必须同时知道的四件事：

0. **真机实测**（macOS 26.5.2 / arm64）：空闲 CPU **0.0–0.4% ⇒ 达标**，
   但常驻内存 **209–211 MB ⇒ 超出 200 MB 上限**（该超限项记为 N5，尚未修）。
   另一轮独立采样：启动前 8 秒 `%CPU 23.5%`、RSS ≈180 MB；运行 45 秒后
   `top` 二次采样 `%CPU 2.4%` / `MEM 113M`、`ps` 累计 RSS ≈208 MB。
   ⇒ 引用性能结论时**必须两半一起引用**，不得只挑达标的那一半。
   出处：`AiX-Vault/01-架构/真机验证-命令审计与检出.md` 与 `Documentation/README.md` 第 3 节。
1. CI **不做**性能门禁：`.github/workflows/ci.yml` 只有构建、测试、打包与隐私不变量，
   没有任何基准测量。
2. 现有自动化里唯一沾边的断言是「单次进程扫描 < 300 ms（宽松阈值，防抖动）」
   （`Tests/AIObservatoryPlatformTests/AgentDetection/AgentDetectionTests.swift:32-42`）——
   它的门槛是 §6 上限（150 ms）的**两倍**，所以测试通过**不能**当作达标证据。
3. 默认采集节奏（决定你的空闲开销基线）：
   `sampleIntervalSeconds = 2`、`processScanIntervalSeconds = 3`
   （`ServiceProtocols.swift:101-102`；引擎下限 `max(…, 0.05)`，
   `ObservatoryEngine.swift:196`），项目地图同步 60 s、保留清理 24 h
   （`ObservatoryEngine.swift:162-163`）。

自己测：

```bash
# 空闲 5 分钟后的常驻内存（RSS，单位 KB）与 CPU
ps -axo pid,rss,%cpu,comm | grep -i AIObservatory | grep -v grep
# 观测器自己在系统日志里留的行（subsystem 定义：Sources/AIObservatoryCore/Contracts/ObservatoryLog.swift:12）
log show --predicate 'subsystem == "com.aix.aiobservatory"' --last 1h
```

---

## 9. 卸载

按你实际用过的方式，只删对应的行。**每条命令都只作用于本工具自己的产物/数据。**

```bash
# 1) 打包版数据库（第 6 节规则 2）
rm -rf ~/Library/Application\ Support/com.aix.aiobservatory

# 2) 开发期 / CI 期数据库（规则 3，在仓库根执行）
rm -rf observatory-data/

# 3) 你自己用 AIOBSERVATORY_DATA_DIR 指过的目录（规则 1）—— 变量没设过就跳过
rm -rf "${AIOBSERVATORY_DATA_DIR:?未设置该变量，跳过此条}"

# 4) App 本体与构建中间产物
rm -rf dist/AIObservatory.app .build

# 5) 确认没有遗留偏好域（预期输出：域不存在——代码里根本没有 UserDefaults 调用点）
defaults read com.aix.aiobservatory
```

**唯一无法承诺「零残留」的一处**：统一日志（`log show`）里 subsystem
`com.aix.aiobservatory` 的行，保留与淘汰由 macOS 决定，不由本应用控制
（同 `PRIVACY.md` 第 3 节第 4 条）。

> 关于 `AGENTS.md` 第 7 节「删除类操作必须走确认流程」：那是对**应用内删除功能**的要求
> （不许自实现静默删除）。本节是给人看的手工清单，不构成对产品行为的豁免或引申。

---

## 10. 故障排查

| 现象 | 真因 | 处理 |
| --- | --- | --- |
| `sandbox_apply: Operation not permitted` | 宿主已在沙箱内，SwiftPM 又起了一层 | 本地加 `--disable-sandbox`（第 3 节）。CI 上出现则是配置错误 |
| `Package.swift ... is required tools version 6.2` / `package at '...' is required by a newer SwiftPM` | Xcode 太旧（`Package.swift:1`） | 装 Xcode 26.2+；多版本共存时用 `export DEVELOPER_DIR=/Applications/Xcode_26.x.app/Contents/Developer` |
| 构建报 SDK 相关 / `unsupported platform` | 目标平台是 macOS 26（`Package.swift:14`），旧 SDK 没有该平台 | 升级到 macOS 26 SDK |
| CI 上 `swift test: Unknown option '--skip'` | 该 flag 需要较新 SwiftPM（ci.yml 里这一步是显式失败，不静默放行） | 升级 runner 的 Xcode 入口，或删掉 `--skip`/`--filter` 两步、恢复成单条 `xcrun swift test` |
| CI 上 4 个 WS-Files 套件（`SnapshotterTests` / `FileTrackingTests` / `EventPipelineTests` / `ChangePipelineTests`）失败 | 它们的 scratch 目录写死成本机绝对路径并会在其上建目录，托管 runner 上创建不了 | 属**已知问题**，CI 里已摘出为不门禁步骤（`.github/workflows/ci.yml` 文件头第 4 节）。要根治见附录 A5 |
| `spctl -a` 拒绝 | ad-hoc、无公证（`SECURITY.md:76-79`） | 第 7 节。要真正放行需要 Developer ID + notarization，那是 owner 决策 |
| 数据目录是空的 / 没有 `observatory.sqlite` | 命中第 6 节规则 4（目录不可写 → 退内存库），或你用的是裸可执行文件（数据在 `observatory-data/` 而不是 `~/Library`） | 检查目录权限；确认你按哪条路径装的；`AIOBSERVATORY_DATA_DIR=` 空串等同未设置（`DataLocation.swift:24`） |
| 列表里一个 Agent 都没有 | 识别依赖进程特征签名库（`Sources/AIObservatoryPlatform/AgentDetection/AgentSignatureDatabase.swift`），改名/换分发形态必然漏检；且只覆盖 macOS 进程 | 用「观测 → 立即重新扫描」（⌘⇧R，`AIObservatoryApp.swift:57-62`）后复核；这是产品级限制，见 `SECURITY.md` 威胁表 T4 |
| 界面没有历史数据 | 引擎的「内存库」退化路径，或库被 30 天保留策略清理 | 第 6 节 + 第 8 节；当前版本真实渲染状态见 `Documentation/README.md` 第 1 节 |

---

## 11. 当前版本装完能用到什么程度

本文只负责「装起来」。**产品完成度以 `Documentation/README.md` 第 1 节的表为准**；
该表已在 2026-09-20 与代码对齐（Store / Engine / UI / Insights / RiskRules / Export 均已实现，
`DataLocation.swift` 决定落盘位置），此前「Store 为占位」等滞后行已更正，附录 A2 的告警可以撤销。

负责人已实机跑过打包产物（`Packaging/make-app.sh` → ad-hoc → 直接 exec bundle 内二进制，
数据目录用 `AIOBSERVATORY_DATA_DIR` 指到仓库外，验证后删除），实测到的事实是：
进程常驻、`lsappinfo` 报 `type="Foreground"`、库被建起来并写入
`agents / sessions / events / commands / perf_samples` 等表（一轮 47 s：23/45/52/5/400 行）。
**但未做视觉验证**：本工作流禁止全屏截图（会拍到其它窗口），窗口级截图需要先枚举窗口 ID
而本机取不到 ⇒ 「Dashboard 具体显示成什么样」**没有被证明**，下面的核对表就是留给使用者自己完成的。

| 核对项 | 期望 | 若不符 |
| --- | --- | --- |
| 进程能起、有窗口 | Dock 有图标 + 主窗口 | 第 7 节 |
| 数据目录出现 | 规则 2/3 对应路径下有 `observatory.sqlite` | 第 6 节规则 4 |
| 同用户 Agent 被列出 | 至少列出你正在跑的那个 CLI | 第 10 节倒数第 2 行 |

---

## 附录 A：提案（我无权修改的文件，集中在此，交总控/负责人裁定）

### A1 `Documentation/README.md:84` 的引用出处错了
该行写「（见 `AGENTS.md` 第 6 节）」来为 `--disable-sandbox` 背书，但 `AGENTS.md` 第 6 节是
**性能预算**（`AGENTS.md:98-108`），不含任何 sandbox workaround；真正记载它的是
`AiX-Vault/05-失忆防护/必读.md:93-103`。建议把引用改指后者，或把 workaround 正式写进
`AGENTS.md` 的构建章节。**（README 不在我的可写清单内，未改。）**

### A2 `Documentation/PRIVACY.md` 第 1 节已与代码相反
该文断言「当前版本**没有任何持久化落盘**、不产生数据库文件」
（`Documentation/PRIVACY.md:10-13`），但主线现在已有：
`Sources/AIObservatoryStore/SQLiteDatabase.swift`（WAL、`:589-591`）、`BatchWriter.swift`、
`SchemaMigrator.swift`、`RetentionPruner.swift`，且 `ObservatoryEngine.Components.live`
已装配真实采集器（`ObservatoryEngine.swift:97-117`），`DataLocation.materialize`
在启动时就会 `createDirectory`（`DataLocation.swift:55-64`）。
这条属于**声明比事实更保守**的不一致，但对审计工具来说同样是错误声明。
建议由文档负责人复核后重写第 1、3、7 节。（**PRIVACY.md 明令不得修改，未动。**）

### A3 `.gitignore` 追加建议（只追加，不改动现有行）
`.gitignore` 不是冻结区，但本工作流的规则要求我不动它，故以提案交付。
CI 的 privacy-guard 已经把「这些文件不得被跟踪」写成**门禁**（`.github/workflows/ci.yml`
privacy-guard 第 3 步），先把规则写进 `.gitignore` 才能在提交前就拦住误操作：

```gitignore
# 签名与公证材料（WS-Packaging/D 提案）
*.p12
*.cer
*.key
*.mobileprovision
*.provisionprofile
AuthKey_*.p8

# 构建旁生品
*.dSYM/

# 本地签名/CI 配置，含机密
.env
.env.*
!.env.example
Packaging/signing.env
```

另一条与签名无关但同属该文件的判断：`Package.resolved` 目前被忽略（`.gitignore:8`）。
**现状无影响**（`Package.swift` 零外部依赖），一旦引入外部依赖，App 类项目应改为
**提交** `Package.resolved` 以获得可复现构建。届时需要显式反忽略这一行。

### A4 `Scripts/` 与打包入口（路径合一后的剩余项）
1. ~~签名失败被 `|| echo` 吞掉~~ —— 随旧脚本退役而**消失**：唯一入口 `Packaging/make-app.sh`
   在签名（`:275`）与校验（第 5/6 步）两处都硬失败，且这条已写成脚本头部的
   **「不变量 #7」**，防止以后有人为了"容忍失败"把它退回静默。
2. **仍然成立**：`Scripts/verify.sh:15,19,24` 硬编码 `--disable-sandbox`，CI 无法复用它
   （今天 CI 直接写 `xcrun swift build` / `swift test`，与 verify.sh 是**重复的两套**）。
   要收编就给它同一个 `AIX_SPM_SANDBOX_FLAG` 开关；顺带它的构建日志现在写到 `/tmp/.aix-build.log`，
   按 `AGENTS.md` 第 0 节应改到仓库内 `.build/` 或 `.worktrees/.scratch/`。
3. **不要删掉的守卫**：入口脚本会在 `Info.plist` 的 `CFBundleIdentifier` 与脚本常量
   `com.aix.aiobservatory` 不一致时直接失败（`Packaging/make-app.sh:106-111`），
   理由正是「该值被 `DataLocation.swift:36` 用来判定正式运行，漂移会让数据库静默落到
   仓库内 `observatory-data/`」。这是 ADR-0003 的唯一自动化防线。

### A5 测试里的绝对路径（**已解决**，保留结论供参考）
原先 3 个文件（`SnapshotterTests`、`FileTrackingTests` 含 `ChangePipelineTests`、
`EventPipelineTests`）把 scratch 写成个人机器上的绝对路径并 `createDirectory`，
在别的机器上必然失败。现在由 `Sources/AIObservatoryTestSupport/Scratch.swift`
（`Scratch.root` / `Scratch.directory(_:)` / `Scratch.path(...)`，默认根 = 当前检出自带的
`.scratch-tests/`，可用 `AIOBSERVATORY_TEST_SCRATCH` 覆盖）取代，
`ci.yml` 也已把这 4 个套件放回全量门禁。
⚠️ 别把它"顺手改成" `FileManager.temporaryDirectory`：macOS 的 `$TMPDIR` 是
`/var/folders/…`，而 `ExportPathPolicy.forbiddenPrefixes` 含 `/var` 与 `/private`，
导出层的隐私策略会拒掉那种根。
剩余命中（`Tests/` 里 97 行，其中非注释 52 处）是**字符串夹具**（不碰磁盘、可移植），
走 `ci.yml` 的 G4 棘轮（只降不升）。清理进度见 `Documentation/OPEN-SOURCE.md` 第 9、10 节。

### A6 交叉引用
`SECURITY.md` 指向 INSTALL 的 Gatekeeper 章节此前写成「第 3 节」，实际是**第 7 节** —— 已改正。
本轮的连带处理：文档之间尽量改用**章节名**而不是行号互指
（`SECURITY.md:NN` 这类引用在本轮至少烂了三次）。
