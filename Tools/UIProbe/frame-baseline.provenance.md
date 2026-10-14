# frame-baseline 读数的出处绑定（可归因性契约）

> Owner: WS-Frames。**没有这一页的读数不可引用。**
> 起因：`dist/` 会被下一次构建**原地覆盖**，上一轮就因此发生过
> 「拿 spindump 里的 UUID 去对现存两个包全部不匹配，再也没法判断那份证据属于修前还是修后」。
> 帧读数的对象是**一个具体的二进制实例**，不是一个 commit——重建同一个 commit 也会得到新 UUID。

## 1. 每份读数的页眉（硬性，四行）

```
bin-uuid : <dwarfdump --uuid 的 arm64 UUID>      ← 实例身份，重建即变
tree     : <被测二进制对应源码的 git rev-parse HEAD>  ← 内容身份
exe-sha  : <shasum -a 256 .../MacOS/AIObservatory>    ← 覆盖自检
window   : load1=<起>/<止>  swift-frontend=<峰值>  口径=<饱和上界|静默窗绝对判据|同窗相对对照>
```

TSV 行内则要求 `notes` 列以 `bin=<UUID 前 8 位>` 开头，这样任何一行都能回溯到 §2 的表。

## 2. 当前被测实例

| 键 | 值 |
|---|---|
| `bin-uuid` | **`E67C96AE-D83C-30B7-BA3D-A7D4F20BC38E`** (arm64) |
| `exe-sha256` | `e7c016d1d18c48a07c2b8f5eb0d86ba7b181cdfe3176433915587f0d2712bc6c` |
| exe mtime | 2026-09-20 17:00:30 +0800 |
| `tree` | **`7473697`**（`merge(quietui): 合入并行工作流`） |
| 构建入口 | `Packaging/make-app.sh`（release，ad-hoc 签名，`dist/build-info.txt`） |
| 钉住的副本 | `tmp/frames/pin-7473697/AIObservatory.app`（与 `dist/` 同 sha256，已核；**gitignore，只在本机活**） |

**内容身份的证明（不是断言，是可复跑的 diff）**：

```bash
git diff --stat 7473697 HEAD -- Sources/ Tests/ Package.swift Resources/ Packaging/   # 空
```

空 ⇒ 17:00:30 之后本车道的提交（全在 `Tools/UIProbe/**`）没有一个进包，
所以这个二进制就是 `7473697` 的产物。**换机或换人复跑，必须先跑这一条再引用读数。**

## 3. 「修前」这个词在这张表上不成立（实测，2026-09-20 17:4x）

总控要求绑定 commit 的原因是 main 在动。实测到这里时已经不止在动，是**已经动过了**：

- `main` 已从 `7473697` 前进到 **`85c04fe` `merge(theme-global)`**，
  差量 250 行进包代码（`Sources/AIObservatoryApp/AIObservatoryApp.swift` +11、
  `DesignSystem/ThemeApplication.swift` +39、`AppThemeColorSchemeTests.swift` +48）
  —— **正是影响渲染的那类改动**，而本表测的是它**之前**的包。
- **`ws/hang` 已在 main 里** ⇒ 那条「P0 根因：外层 `LazyVStack` 反复物化」的修复
  **早就包含在基线树 `7473697` 中**。所以本表量到的不是「没有任何帧修复的原始态」，
  而是「已知最大的一处帧病已经修掉的中间态」。引用本表时不许说成前者。
- 仍未合入、且都会改帧数的：`ws/quiet1`（Sessions 合计口径）、`ws/quiet2`（Files/Diff 页重排）、
  `ws/quiet3`（性能页与过滤条去重复时间范围）；另有 `ws/engperf`、`ws/platperf` 改采集侧。

⇒ **本表的定位**：车道内工具自检用的**中间态参照**，不是「最终修前基线」。
终局修前/修后要由总控在静默窗对**合入后的同一个 tree 重建的两个包**成对取，
每份都带 §1 页眉，且两份的 `tree` 差集里只许有被测改动。

## 4. 饱和机器上的读数怎么标（帧口径与 CPU% 不同）

总控裁定 + 本车道实测：CPU 争抢只会把**帧时长拉长**，不会让它变好看，
所以在 load 18–57 的机器上量到的帧时间是**保守上界**——
用它证明「慢」无效，用它证明「不慢」有效（上界都过了，静默窗只会更好）。
这与「同窗相对对照」是两种不同的东西，不许混用：

| 口径 | 能得出的结论 | 不能得出的结论 |
|---|---|---|
| `饱和上界` | 「修后不比修前更差」（同窗两侧都要有） | 任何「达标 F1–F4」 |
| `静默窗绝对判据` | 达标与否 | 跨窗比较（分母每行重测） |
| `同窗相对对照` | 谁比谁快多少 | 绝对达标 |

**前提**：上表第一行的推理只在 `vsync_ms` **每行重测**时成立。
本车道实测 load 9.4 → 27.9 期间，`CVDisplayLink` 的 `videoTime` 间隔始终 min=max=8.333 ms
（见 `01-架构/逐页帧基线表.md` §2），所以分母在饱和窗内没漂；分母一旦漂，「保守上界」的推理就断。

## 5. 这轮读数的两条待修（负责人复盘，总控引用前先读）

1. **双驱动污染过一次，且症状不可见**：A2 在子代理轮次上限处中止时，它 18:41 起的驱动变成
   PPID=1 的孤儿继续跑，与我 18:43 起的第二个驱动同时抢焦点 9 分钟。
   被污染的 7 行**形状完全正常**（`presented_n=157`、`hitch_n=155`，没有任何一列变 `n/a`），
   只有 `ps -o pid,ppid,command` 能发现。整份留在 `tmp/frames/baseline-contaminated-doubledriver.tsv`，
   现已由驱动开头的单实例锁堵住（第二实例直接 rc=5 退出）。
2. **页面身份未证成**：`post_check` 9 行里 4 行 `differs/unknown`；窗口内点侧栏切页会打偏。
   ⇒ 现在这些行**不能标成"某一页"的基线**，只能当合成交互下的粗读。修法见逐页帧基线表 §4.1。
