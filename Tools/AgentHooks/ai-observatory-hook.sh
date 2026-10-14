#!/bin/sh
#
#  ai-observatory-hook.sh
#  Tools/AgentHooks
#
#  Owner: WS-CmdSrc
#  ─────────────────────────────────────────────────────────
#  极小的示例 hook：把 Agent 的一次 Bash 工具调用落成一行 JSONL，
#  让观测站拿到「命令文本 + 退出码 + 起止时间」这三格采样给不了的事实。
#
#  默认不生效：只有用户主动把它注册进 Agent 的 hooks 才会写盘（见同目录 README.md）。
#  原则：payload 里没有的字段就留空/不写，绝不为凑齐 schema 编一个值出来。
#

set -eu

# 观测站的数据目录。打包运行的是 ~/Library/Application Support/com.aix.aiobservatory，
# 开发期跑 .build/debug/AIObservatory 时用 AIOBSERVATORY_DATA_DIR 指定，
# 两者都可用 AI_OBSERVATORY_HOOK_DIR 显式覆盖（见 README 的「让 hook 写对地方」）。
agent_kind="${AI_OBSERVATORY_AGENT_KIND:-claude}"
hook_dir="${AI_OBSERVATORY_HOOK_DIR:-"$HOME/Library/Application Support/com.aix.aiobservatory/agent-hooks"}"

if ! command -v jq >/dev/null 2>&1; then
    # 不静默：让装 hook 的人看见为什么没落盘；但退出码 0，不因此打断 Agent 干活。
    echo "ai-observatory-hook: 需要 jq（/usr/bin/jq），本次跳过" >&2
    exit 0
fi

payload=$(cat)

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty')
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')

# 只认命令类工具；其它工具（读文件、检索）不是「执行了一条命令」。
case "$tool" in
    Bash|bash|Shell|shell|terminal) ;;
    *) exit 0 ;;
esac
# 只在 PostToolUse 落一行——那时才有退出码。PreToolUse 也写会变成两条记录。
[ "$event" = "PostToolUse" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty')
work_dir=$(printf '%s' "$payload" | jq -r '.cwd // empty')
event_id=$(printf '%s' "$payload" | jq -r '.tool_use_id // empty')

# 各 Agent 版本把起止信息放在不同字段上；有哪个用哪个，都没有就只记退出码。
started=$(printf '%s' "$payload" | jq -r '
    .tool_response.started_at // .tool_response.start_time // .tool_response.startedAt // empty')
ended=$(printf '%s' "$payload" | jq -r '
    .tool_response.ended_at // .tool_response.end_time // .tool_response.endedAt // empty')
duration=$(printf '%s' "$payload" | jq -r '
    .tool_response.duration_ms // .tool_response.durationMs // empty')
exit_code=$(printf '%s' "$payload" | jq -r '
    .tool_response.exit_code // .tool_response.returnCode // .tool_response.exitCode // empty')

[ -n "$started" ] || started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$hook_dir"
line=$(jq -c -n \
    --arg source "hook" \
    --arg agentKind "$agent_kind" \
    --arg sessionId "$session_id" \
    --arg command "$cmd" \
    --arg workingDirectory "$work_dir" \
    --arg startedAt "$started" \
    --arg endedAt "$ended" \
    --arg eventId "$event_id" \
    --arg exitCode "$exit_code" \
    --arg durationMs "$duration" \
    '{
        source: $source,
        agentKind: $agentKind,
        command: $command,
        startedAt: $startedAt
    }
    + (if $sessionId == "" then {} else {sessionId: $sessionId} end)
    + (if $workingDirectory == "" then {} else {workingDirectory: $workingDirectory} end)
    + (if $endedAt == "" then {} else {endedAt: $endedAt} end)
    + (if $eventId == "" then {} else {eventId: $eventId} end)
    + (if $exitCode == "" then {} else {exitCode: ($exitCode | tonumber)} end)
    + (if $durationMs == "" then {} else {durationMs: ($durationMs | tonumber)} end)')

printf '%s\n' "$line" >> "$hook_dir/$agent_kind.jsonl"
