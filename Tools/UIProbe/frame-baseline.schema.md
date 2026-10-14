# frame-baseline.tsv 列契约（WS-Frames · 唯一真值源）

> Owner: WS-Frames。**这个文件定义了逐页帧基线表的列名、单位与判定口径。**
> B/C 车道与 workbuddy 的 quiet1/quiet2/quiet3 都消费它：改列 = 契约变更，须走总控。
> 数据文件是同目录的 `frame-baseline.tsv`（UTF-8、TAB 分隔、首行表头、**一个页面一行**、
> 一次运行 = 一行；同一页多次运行用 `run_id` 区分）。
> 任何列都不许留空：量不到就写 `n/a`，并在 `notes` 里说明为什么量不到（`n/a` 与 `0` 是不同的结论）。
>
> **出处绑定（2026-09-20 总控要求，硬性）**：`notes` 必须以 `bin=<UUID 前 8 位>` 开头，
> `commit` 列填**被测二进制对应源码**的 sha（不是脚本所在树），
> 每个被测实例的 UUID/sha256/钉住副本记在 `frame-baseline.provenance.md` §2。
> 理由：`dist/` 会被下一次构建原地覆盖，重建同一个 commit 也会得到**新 UUID**——
> 上一轮就因此发生过「拿 spindump 里的 UUID 去对现存两个包全部不匹配，再也没法判断那份证据
> 属于修前还是修后」。没有出处绑定的读数不可引用。

## 一、机器可读列（顺序固定，不许插入后挪动）

> **待落列（2026-09-20，A3 提议、负责人已批准，尚未改进表头）**：`developer_mode`（`on|off|unknown`，
> 判据 = `/Library/Application Support/Xcode IO Mode/Apple .github.io` 存在与否）、
> `turn_instrument`（`turn_*` 九列实际由谁贡献，无可信来源时 `none`）、
> `trace_available`（`yes|no`，判据 = `xcrun xctrace list devices --attach` 主机分区有无目标）。
> 理由：F4 在本机**结构性不可判**，不把这三件事记成列，读表人无法区分「0 个 hang」与「测不了 hang」。
> 这三列**只许追加到第 38 列之后**（表头与既有行同步由负责人归一），
> 因为 A2 正在往表里写行——中途挪动既有列位会让它的行错位。

| # | 列名 | 单位/取值 | 含义与口径 |
|---|---|---|---|
| 1 | `run_id` | `YYYYMMDD-HHMMSS-<page>-<n>` | 一次采集的稳定 id |
| 2 | `page` | 9 枚举之一：`dashboard` `timeline` `files` `commands` `sessions` `performance` `projects` `security` `settings` | 被测页面 |
| 3 | `section_env` | 字符串 | 实际传给进程的 `AIOBSERVATORY_SECTION` 原值（两者可以不同，不同就要解释） |
| 4 | `commit` | git short sha | **被测二进制**对应的源码提交，不是脚本的 |
| 5 | `build` | `release` `debug` | 判据只认 `release`（debug 有运行时检查，混用是历史事故） |
| 6 | `data_dir_kind` | `fresh` `seeded` | 绝对判据必须 `fresh`（攒着历史行的目录会把聚合成本算进读数） |
| 7 | `seed_events` | 行 | 播种后库内 events 行数；`fresh` 或未播种写 `0` |
| 8 | `interaction` | `idle` `scroll200` `switch` `combined` | 判据窗口内做了什么，见驱动脚本 |
| 9 | `window_s` | 秒 | 判据窗口长度，**≥ 20 s**（短于此，P99 没有样本支撑） |
| 10 | `vsync_ms` | ms，3 位小数 | **必须取 `frame-pacer` 里 `instrument=cvdisplaylink` 那一块**的实测间隔 P50。不许直接写 8.333 当已证事实；也不许用 `cadisplaylink` 那一块当分母（它走主 runloop，同窗实测 `skipped` 40 vs 0、max 26.893 ms，会把「消费者跟不上」混进「显示端周期」） |
| 11 | `frames_expected` | 帧 | `window_s / vsync_ms × 1000`，向下取整 |
| 12 | `frames_presented` | 帧 | 仪器二（按窗口呈现帧到达）计数。**静止页面本来就 0 帧，0 不等于卡住** |
| 13 | `hitch_n` | 次 | 呈现间隔 > `1.5 × vsync_ms` 的次数（= 至少跳过一个 vsync） |
| 14 | `hitch_gt2_n` | 次 | 呈现间隔 > `2.5 × vsync_ms` 的次数（= 掉到 60Hz 等效以下） |
| 15 | `p50_presented_ms` | ms | 呈现间隔 P50 |
| 16 | `p95_presented_ms` | ms | 呈现间隔 P95 —— **F1 的判定值** |
| 17 | `p99_presented_ms` | ms | 呈现间隔 P99 |
| 18 | `max_presented_ms` | ms | 呈现间隔最大值 |
| 19 | `turn_p50_ms` | ms | 仪器三（主线程 turn）P50 |
| 20 | `turn_p95_ms` | ms | 主线程 turn P95 |
| 21 | `turn_p99_ms` | ms | 主线程 turn P99 |
| 22 | `turn_max_ms` | ms | 主线程 turn 最大值 |
| 23 | `turn_gt_100ms_n` | 次 | 单次 turn > 100 ms 的个数 —— **F4 的判定值** |
| 24 | `hang_events_n` | 次 | 判据窗口内 spindump/取证轮里 `Event: hang` 的条数；没跑取证轮写 `n/a` |
| 25 | `footprint_mb_start` | MB | 窗口起点 `phys_footprint`（**不是 `ps` 的 RSS**，本机 RSS ≈ 2× footprint） |
| 26 | `footprint_mb_end` | MB | 窗口终点 `phys_footprint` |
| 27 | `footprint_delta_mb` | MB | 26 − 25，带符号 |
| 28 | `cpu_pct` | % | `Δcputime / Δwall × 100`（`ps -o %cpu` 是衰减平均，不许当判据） |
| 29 | `load1_before` | 浮点 | 窗口起点 `uptime` 1 分钟负载 |
| 30 | `load1_after` | 浮点 | 窗口终点 1 分钟负载 |
| 31 | `swiftfrontend_n` | 个 | 窗口内观测到的 `swift-frontend` 进程数峰值 |
| 32 | `instruments` | `+` 连接 | 本行用到几把**独立**仪器：`cvdisplaylink` `screencapturekit` `xctrace` `spindump` `taskinfo` |
| 33 | `basis` | `absolute` `saturated-upper-bound` `relative` `n/a` | **`absolute` 仅当 `load1_before` 与 `load1_after` 都 < 15**（本机 15 核）；load ≥ 15 时：帧时长只会因争抢被**拉长**，故填 `saturated-upper-bound`（= 保守上界，可用来证「不更差」，**不可**用来打勾 F1–F4）；跨窗比较才用 `relative`。见 `frame-baseline.provenance.md` §4 |
| 34 | `f1_verdict` | `pass` `fail` `n/a` | `p95_presented_ms ≤ vsync_ms × 1.05` 且 `basis=absolute` |
| 35 | `f2_verdict` | `pass` `fail` `n/a` | `interaction` 含滚动/切页时 `hitch_n == 0` 且 `basis=absolute` |
| 36 | `f3_verdict` | `pass` `fail` `n/a` | `max_presented_ms ≤ 16.7` 且 `basis=absolute` |
| 37 | `f4_verdict` | `pass` `fail` `n/a` | `turn_gt_100ms_n == 0` 且 `hang_events_n == 0` 且 `basis=absolute` |
| 38 | `notes` | 文本，**不得含 TAB/换行** | 异常、未覆盖条件、对照条件。写「没量到」必须同时写为什么 |

## 二、为什么是这些列（给后来人，别退回反例）

1. **`frames_presented` 与 `hitch_n` 分成两列**：合成器只在内容变化时出帧，所以「帧数少」可能是
   页面本来就没动，也可能是卡住。二者混成一列就会把「静止」误报成「掉帧」——这是本项目犯过的
   「把没测到写成不存在」同一类错误。
2. **`basis` 是硬列不是脚注**：本机 load 长期 5–12（宿主 Qoder + 并行编译车道），load 高时
   任何绝对值都不是结论。把判定和 load 放在同一行，脏数据无法被误引用。
3. **`instruments` 是硬列**：一条构成类结论必须 ≥ 2 把独立仪器；只有 1 把时 `f*_verdict` 只能填 `n/a`。
4. **`vsync_ms` 每行重测**：ProMotion 会降频，静止时可能掉到 60Hz 甚至更低；上一行的周期不能当这一行的分母。

## 三、和验收判据的对应

| 判据 | 判定列 | 分母/来源 |
|---|---|---|
| F1 P95 帧耗时 ≤ 8.33 ms | `p95_presented_ms` vs `vsync_ms × 1.05` | 仪器二按窗口呈现帧，仪器一定分母 |
| F2 200 滚轮 + 逐页切换 0 掉帧 | `hitch_n == 0`（`interaction=scroll200/switch/combined`） | 同上 |
| F3 单帧 ≤ 16.7 ms | `max_presented_ms` | 同上 |
| F4 turn ≤ 100 ms 且无 `Event: hang` | `turn_gt_100ms_n == 0` + `hang_events_n == 0` | 仪器三（`xctrace`/`spindump`，不许用 `sample` 进判据窗口） |
| F5 内存口径 `phys_footprint` | `footprint_mb_*` | `task_vm_info.phys_footprint`（`task_info` 系统调用） |
