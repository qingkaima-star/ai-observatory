# frames 工具命令行契约（WS-Frames 三条子车道共用）

> Owner: WS-Frames。编译产物统一落在 `tmp/uiprobe/`（gitignore），源码在 `Tools/UIProbe/`。
> 约定：**stdout 只打 `key=value` 行**（一行一个，可被 `grep '^key=' | cut -d= -f2` 取走），
> 人读的解释与报错一律走 stderr。这样驱动脚本不需要解析散文。
> 数值格式：毫秒保留 3 位小数；`n/a` 用于「量不到」，`0` 用于「量到且确为零」——两者含义不同。

| 工具（源码 = 同名的 `Tools/UIProbe/<name>.swift|.sh`） | 命令行 | 必打的 key |
|---|---|---|
| `frame-pacer` | `--seconds N [--out csv路径]` | `vsync_n` `vsync_p50_ms` `vsync_p95_ms` `vsync_p99_ms` `vsync_max_ms` `vsync_skipped` `instrument` |
| `probe-footprint` | `--pid P`（可多次，进程存续期内重复取） | `phys_footprint_mb` `rss_mb` `footprint_ratio` |
| `frame-window` | `--pid P --seconds N [--out csv路径]` | `presented_n` `presented_p50_ms` `presented_p95_ms` `presented_p99_ms` `presented_max_ms` `hitch_n` `hitch_gt2_n` `capture_permission` |
| `turn-trace` | `--pid P --seconds N` | `turn_n` `turn_p50_ms` `turn_p95_ms` `turn_p99_ms` `turn_max_ms` `turn_gt_100ms_n` `hang_events_n` `turn_instrument` `turn_note` （**本机只能出 `n/a`，见下方「取证轮口径」**） |
| `frame-baseline`（驱动，产出 TSV 行） | `--pages a,b,c [--seed 目录] [--scrolls N] [--append]` | 追加一行到 `Tools/UIProbe/frame-baseline.tsv`，并在 stdout 打 `run_id=` 与 `status=` |

**编译**（子代理只许编译自己那一个文件，绝不 `swift build`）：

```bash
xcrun swiftc -O Tools/UIProbe/frame-pacer.swift -o tmp/uiprobe/frame-pacer
```

**F5 口径**：`phys_footprint` 取 `task_vm_info.phys_footprint`（`task_info(TASK_VM_INFO)`），
本机实测 RSS ≈ 2× footprint，所以 `measure-idle.sh` 的 `ps rss` 只能当对照列。
被观测进程必须是**自己起的** pid（多条车道共用同一个二进制名）。

## 取证轮口径（2026-09-20 A3 实测 + 负责人复验修订）

A3 截断前的初判是「xctrace 类 trace 本机结构性不可得、F4 只能 n/a」，**这条已被推翻**
（负责人与 A3 各自独立复跑）：`xcrun xctrace record --template 'Animation Hitches'
--attach <pid> --time-limit Ns --no-prompt` 在非 root、无 Developer Mode 下 rc=0。
A3 那三条理由里只有「`spindump` 需 root」「`Xcode IO Mode` 目录不存在」站得住；
`xcrun devinit status` 这台机器上根本没有该命令（`unable to find utility "devinit"`），
`xctrace list devices --attach` 打的是 usage（`list` 不接受 `--attach`，命令从未生效）。

⇒ `turn-trace.sh` **有实现**（A3 的三档版：Animation Hitches → System Trace → 报错），口径：
  * `turn_*` = 主线程 `CFRunLoop individual_iteration` START→END 配对（真·单次 turn）。
    正对照 = `control-window --stall-every N --stall-ms 120`，实测 `turn_gt_100ms_n` 与注入次数逐条相等。
  * `hang_events_n` = **`potential-hangs`** 行数（threshold 33 ms）。**禁止**取 `hang-risks`
    （实测有 13 条真挂起的窗口里它是 0 行 = 静默假阴性）。`hang_risks_n` 只作附加列。
  * `--attach` 会先冻住目标再放开 ⇒ 开头一条 hang 是**仪器自造**（实测 12472 ms）；
    F4 判 `hang_events_ex_first5s_n`，不判含首条的那个数。
  * 录不下来/解析失败时打 `turn_instrument=none` + 全列 `n/a` + rc=4，**绝不打 0**。
  * 成本：20 s 窗 → 包 571 MB / 1.7 GB、墙钟 79 s / 294 s（3–15×）⇒ 只许取证轮，
    `--reuse <包.trace>` 可只重解析不再录。

`frame-window`（SCStream 按窗口）有一条**分辨率天花板 ≈60 内容帧/s**（呈现间隔 P50 下限 16.5 ms，
同窗整屏通道能看到 9.4 ms）⇒ 它能判「慢于 60 fps 的劣化」，**判不了 F1（≤8.333 ms）**。
120 Hz 那一段只能靠 `turn-trace` 的帧寿命/hitch 表，或产品侧插桩（= IFR）。

仍然可用但不属于 trace 类的一条：`sample` 非 root 可用，**必须给 `-file`**：

```bash
sample <pid> 3 -file tmp/frames/sample-<页>.txt   # 实测 rc=0；不给 -file 会写进 /tmp = AGENTS §0 越界
```

它给统计画像（叶帧分布判「忙 vs 等」，当年「P0 性能页自旋」靠 719/731 停在 `mach_msg` 结案），
不给逐回合 turn；且会 attach ⇒ 同样禁入帧判据窗口。

真要从 spindump 口径取证只剩：开 Developer Mode、给 root、
或读 `~/Library/Logs/DiagnosticReports/*.hang`（在授权根之外，**未实测，需总控批准**）。
