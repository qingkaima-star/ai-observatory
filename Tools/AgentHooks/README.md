# AgentHooks — 让观测站拿到「命令 + 执行结果 + 耗时」的精确来源

> Owner: WS-CmdSrc · 对应决策记录 `AiX-Vault/04-决策记录/IFR-command-precision.md`

## 为什么需要它

观测站的命令审计原本只有一条路：轮询进程表，反推哪些进程是 Agent 的子进程。实测
（`AiX-Vault/01-架构/真机验证-命令审计与检出.md`）结论是这条路结构性撑不起来：

- 3 秒间隔对 30–50 ms 的短命命令捕获率约 **1–2%**；
- 轮询**永远看不到退出码**——`outcome` 恒为「运行中」、`exit_code` 恒空。

需求原文要的是「记录的命令、**执行结果**、**持续时间**」。后两格不是调参能补的，是机制缺失。
所以加第二条来源：**Agent 自己在工具调用结束时落一行 JSONL，观测站读它**。
命令文本、退出码、起止时间全部来自当事进程本身——零采样损失、零猜测。

轮询来源保留为兜底（没装 hook 的 Agent 仍能看到长命令），两条来源重叠时**以 hook 为准**。

## 默认不生效

这个目录里的脚本不会被自动执行、不会被自动安装。**只有你自己把它写进 Agent 的 hooks 配置，
它才开始工作。** 没装 hook 的机器上，观测站的行为和以前完全一样。

## 隐私：装之前先看完这段

- **命令文本会明文落盘。** 包括参数里的路径、`--token=…`、内联的 SQL——凡是那条命令行里有的都会
  进那个 jsonl 文件。文件在你自己的机器上（观测站数据目录），不上传、不进 git，但它确实是明文。
- 落盘位置：`<观测站数据目录>/agent-hooks/<kind>.jsonl`。
  打包运行 = `~/Library/Application Support/com.aix.aiobservatory/agent-hooks/`；
  开发期 = `AIOBSERVATORY_DATA_DIR` 指定的目录。
- 观测站**只读**这个 `agent-hooks/` 目录里的 `*.jsonl`。**不会**去读 `~/.claude`、`~/.codex`、
  shell history（`.zsh_history` 等）或任何 AiX 数据目录之外的路径。
  目录里若有人放一个指向外部的符号链接，读取器按边界规则直接跳过（见 `HookJSONLReader.hookFiles`）。
- 不想再采：把 hooks 配置那一行删掉即可；想连历史一起清掉，删 `agent-hooks/` 目录。

## 安装（Claude Code）

写进 `~/.claude/settings.json`（或项目里的 `.claude/settings.json`）：

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/Tools/AgentHooks/ai-observatory-hook.sh"
          }
        ]
      }
    ]
  }
}
```

`chmod +x Tools/AgentHooks/ai-observatory-hook.sh`，脚本只依赖 `/usr/bin/jq`。
缺 jq 时它往 stderr 写一行提示然后退出，**不会**打断 Agent 干活。

**只挂 `PostToolUse`。** `PreToolUse` 也挂的话，同一条命令会落成两条记录（一条没有退出码）。

### 让 hook 写对地方

数据目录默认取打包 App 的位置。开发期用 `.build/debug/AIObservatory` 跑时，两边都要指到同一个目录：

```sh
AIOBSERVATORY_DATA_DIR="$PWD/tmp/verify" .build/debug/AIObservatory &
AI_OBSERVATORY_HOOK_DIR="$PWD/tmp/verify/agent-hooks" \
AI_OBSERVATORY_AGENT_KIND=claude \
  Tools/AgentHooks/ai-observatory-hook.sh < /dev/null   # 手动喂 payload 自测
```

`AI_OBSERVATORY_AGENT_KIND` 决定这一行归到哪个 Agent 类型（认 `claude` / `codex` / `cursor` /
`gemini` / `aider` 等别名；认不出来落 `unknown`，不做猜测归因）。

## JSONL schema

一行一条 JSON，**未知字段忽略**。观测站不猜、不补默认值：

| 字段 | 类型 | 必填 | 缺了会怎样 |
|---|---|---|---|
| `command` | string | ✅ | **整行丢弃并计数**（`missingCommandCount`） |
| `startedAt` | ISO8601 字符串或 Unix 秒 | ✅ | **整行丢弃并计数**（`missingTimestampCount`） |
| `agentKind` | string | 建议 | 落 `unknown` |
| `sessionId` | string(UUID) | | 原样忽略（不编） |
| `arguments` | string[] | | 由 `command` 按 shell 引号规则切分 |
| `workingDirectory` | string | | 留空 |
| `endedAt` | ISO8601/Unix 秒 | | 有 `durationMs` 则据此推出，否则无结束时间 |
| `durationMs` | number | | 同上 |
| `exitCode` | number | | 记为「运行中/未知」，不伪造成功 |
| `eventId` | string | | 幂等键改用内容自然键 |
| `source` | string | | 建议固定 `"hook"`；其它值不拒 |

示例（一次失败的 `rm -rf`）：

```json
{"source":"hook","agentKind":"claude","sessionId":"8F1C…","command":"rm -rf ./junk",
 "workingDirectory":"/tmp/demo","startedAt":"2026-09-20T03:41:02.412Z",
 "endedAt":"2026-09-20T03:41:02.455Z","exitCode":2,"eventId":"toolu_01AbC"}
```

## 观测站侧的行为（排查用）

- 按**字节偏移**增量读，偏移与已见过的事件键写在同目录的 `.offsets.json`（不是 `.jsonl`，不会被当成来源）。
  重启从偏移续读：不漏、也不重。观测站停机期间落的命令，下次启动照样补采。
- 结尾没有换行的半行**不消耗偏移**——半条命令既不入库，也不会被永久跳过。
- 同一行内容重复追加（hook 重试）→ 事件键已见过 → 记 `duplicateLineCount`，只入库一次。
- 超过 256 KB 的单行按丢弃计数并跳过，不会把采集循环卡死。
- 丢弃原因全部有计数，暴露为 `HookCommandAuditing.stats`；坏行悄悄丢掉等于说谎。

## 验证装好了

```sh
tail -n 3 "<观测站数据目录>/agent-hooks/claude.jsonl"
sqlite3 -readonly "<观测站数据目录>/observatory.sqlite" \
  "select executable,exit_code,round(strftime('%s',ended_at)-strftime('%s',started_at),3) as secs \
     from commands where exit_code is not null order by started_at desc limit 5;"
```

有 `exit_code` 非空的行，就说明精确来源接通了；风险层拿到带退出码的破坏性命令后会照常产出
`risk_events`。

## 别的 Agent

Codex CLI / Cursor / 自建 Agent 只要能执行一条 shell 命令，就能用同一份 schema：
把工具调用的命令文本、起止时间、退出码拼成一行 JSON 追加到 `agent-hooks/<kind>.jsonl`。
不需要额外注册、不需要重启观测站（每轮采集都会重新枚举该目录）。
