# AgentFixture — 合成 Agent 真机验证夹具

本机可能没有安装任何受支持的 CLI Agent（`claude` / `codex` / `aider` 都不在），
此时「命令审计」「风险检测」两项**无法**靠日常使用拿到真机证据。
本夹具用真实的 `fork/exec` 复现它们，走的是生产代码同一条路径
（libproc 快照 → `KERN_PROCARGS2` 取 argv → 父链归因 → FSEvents → 风险层）。

被合成的只有「这个进程叫 `claude`」这一层身份；没有任何记录是伪造写入的。

```sh
Tools/AgentFixture/fixture-agent.sh 30        # 后台跑 30 秒，到点自杀并清理 work/
```

## 验证配方（命令审计 / 文件追踪 / 风险检测真机复验）

```sh
mkdir -p tmp/verify && AIOBSERVATORY_DATA_DIR="$PWD/tmp/verify" .build/debug/AIObservatory &
APP_PID=$!                                # 只记这个 pid；收尾只 kill 它，绝不按名字杀（多车道同名）
Tools/AgentFixture/fixture-agent.sh 40 &
sleep 50
sqlite3 -readonly tmp/verify/observatory.sqlite \
  "select kind,detected_via,count(*) from agents group by kind;
   select count(*) from file_changes where path like '%AgentFixture%';
   select kind,baseline_source,count(*) from diffs group by 1,2;
   select executable,arguments_json from commands;"
kill "$APP_PID"
```

## 需求③ 的判据是什么（06:42 实测校准过一次，别再写错）

**判据不是「diff 里必须有 `removed` 行」。** 我一度把这条写进静默窗手册，
结果它会把一个**工作正常的功能判成失败**：夹具的 C 部分原先只 `fopen(..., "a")` 追加，
纯追加的改动**本来就没有删除行**，`removed` 为 0 是正确答案。
⇒ 又是「代理指标冒充需求」那类毛病：判据要指着需求写，不是指着一个好数的数字写。

正确的两层判据：

1. **改前内容是真的**：`kind=modified` 且 `baseline_source='lastObserved'` 的 diff ≥ 1 条，
   且 hunk 头形如 `@@ -N,M +…` 且 `N ≥ 1`（⇒ 确实有一个更早的版本参与了比较）。
2. **删除方向也要有真机证据**：夹具现在每 4 轮**整体重写**一次 `notes.md` 让文件变短，
   所以 `lines_json like '%"removed"%'` 也应 ≥ 1 条。
   这条是被 06:42 那次实测**逼出来的**——加重写步骤之前，`removed` 渲染路径在真机上零证据。

06:42 用 release 交付包实测：`created/unavailableFirstSighting=2`、`modified/lastObserved=13`、
含 `removed` 行的 diff = 3。样例：

```
@@ -1,5 +1,2 @@
  context | old#1 | 'line-1'      ← 由下面的 sh 在 Agent 启动之前写入
 removed  | old#2 | 'reset-4'
 removed  | old#3 | 'entry-5'
   added  | new#2 | 'reset-8'
```

`line-1` 能一路活着出现在改前侧，是「改前内容确实来自上一轮观测的留底、而不是当场读盘凑出来的」
最硬的证据：它写于 Agent 进程存在之前，任何现编的 baseline 都不可能知道它。

改完后同一配方必须能复现，才算该项通过。`tmp/verify` 与 `work/` 都不入库。

`work/`、`tmp/`、`observatory-data/` 已在 `.gitignore` 中排除：夹具产物绝不入库。
