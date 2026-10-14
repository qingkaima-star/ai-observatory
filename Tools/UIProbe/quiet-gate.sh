#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/quiet-gate.sh — 静默前置闸（#92 装置第一格：闸在脚本里，也在流程里）
#
#  Owner: ws/rig（测量装置，不进产品 target）
#  ─────────────────────────────────────────────────────────
#  为什么单独有一颗闸，而不是让每个驱动器自己读 `uptime`：
#   1. 上一轮 A/B（`真机验收-逐页与开销基线.md` §13/§14）26 扇窗的 load 覆盖 5.3–16.4，
#      本仓默认 `LOAD_CEILING=4` **一次都没满足过**，而 `measure-pages.sh` 照跑不误——
#      闸写在 `quiet-verdict.sh` 的收尾汇总里，驱动器根本没经过它。
#      ⇒ 结论：那一整轮的"绝对读数"是事后作废的，不是事前拦下的。
#   2. 光有 load 不够。AGENTS §6 那句"本产品是观测器，开销按设计随机器活动量增长"意味着
#      **load 低但有一个 Agent 在敲命令**时，我们量的仍然是"别人的活动"，不是自己的地板。
#      ⇒ 本闸第二条：被观测 Agent 的进程**存在即不静默**（不看 CPU%，按名字判）。
#   3. 两条要一起判，就得只有一个出处。本文件是**唯一**实现，`measure-pages.sh` /
#      `quiet-verdict.sh` / `ab-sweep.sh` 都 source 它 ⇒ 三条车道不可能各自放宽一处。
#
#  口径（读结果前必须知道）：
#   - `load_1m` 取 `sysctl -n vm.loadavg` 的**首段**（1 分钟）。旧版 `quiet-verdict.sh` 靠
#     "去掉 {} 再按点切"从拼接串里凑这个数（`7.487.397.70` → `7.487`）——它**恰好**对，
#     但那是运气而不是设计；现在两处都换成同一个 `awk '{print $1}'`。
#   - Agent 名单**不写死在本文件里**：默认值取包内那份签名表（现读 `--print-agents`），
#     读不到才退回兜底常量。签名表改了字，闸的射程跟着改——不会再出现"装置比产品旧"。
#   - 本闸**只回答"能不能开窗"**，不给任何产品结论；判据④ 的达标与否仍由
#     `quiet-verdict.sh` 汇总判定（它是裁判，本文件只是门口的门禁）。
#
#  用法（独立跑）：
#    Tools/UIProbe/quiet-gate.sh                      # 用默认上限与默认名单
#    LOAD_CEILING=2 AGENT_PROCESSES="claude codex" Tools/UIProbe/quiet-gate.sh
#    Tools/UIProbe/quiet-gate.sh --print-agents       # 只看名单从哪来、是什么
#  用法（被 source，正式接法）：
#    . "$(dirname "$0")/quiet-gate.sh"
#    if ! quiet_gate_wait "第 $r 轮 $sec 页"; then … 不开这一行 … fi   # 带重试，驱动器用这颗
#    if ! quiet_gate_check "第 $r 轮 $sec 页"; then … 不开这一行 … fi  # 单次判定（自检用）
#  重试口径：GATE_TRIES（默认 3 次）× GATE_WAIT（默认 20 s）⇒ 最多等 40 s，仍不过就**不开这一对**。
#  ⚠️ 重试只放宽"等多久"，**绝不放宽判据**（load 上限与 Agent 名单一次都不打折）。
#
#  退出码：0 静默（可以开窗）；1 不静默（**不许**开窗）；2 参数/环境错（也按不许开窗处理）
#  stdout 只打 key=value（可 eval）；人读解释与报错一律走 stderr。
# ============================================================================
set -u

# ── 可注入的取数口（自检靠这两条 seam 在"机器其实很忙"的情况下测出闸真的会拦）──────
# ⚠️ 生产默认 = 现读真机。把它们指到别处 = 自检模式，输出的 `gate_mode=` 会写 `injected`，
#    任何带 injected 的产物都**不许**当验收读数引用（`rig-selfcheck.sh` 就是钉这件事的）。
# ⚠️ seam 的语义是"按空白分词后当命令执行"（`raw=$($LOAD_CMD)`，**不过 eval**）：
#    所以口里只能放不需要引号的命令（`echo 0.5 0.5 0.5` 对，`printf ' 0.5 …'` 会把 `'`
#    当字面量喂给 awk ⇒ 读出"不是个数"）。不 eval 是故意的：一个被环境变量喂进去的
#    字符串再经 eval，就等于把"任意 shell"塞进测量流程，那才是装置最不该有的入口。
LOAD_CMD="${LOAD_CMD:-sysctl -n vm.loadavg}"
LOAD_CMD_PRODUCTION="sysctl -n vm.loadavg"     # 与上面默认值逐字相同 ⇒ 用它反推"调用方有没有换掉取数口"
PROBE_CMD="${PROBE_CMD:-}"            # 覆盖整个 Agent 探测（自检用）
PROBE_PIDS_CMD="${PROBE_PIDS_CMD:-}"  # 只覆盖"取 pid 列表"这一步（自检用，名单仍现读）

# 兜底名单：仅在包内签名表读不到时使用（值来自 AgentSignatureDatabase 的 match_terms 列）。
FALLBACK_AGENT_PROCESSES="claude codex cursor"

gate_root() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd; }

# 名单**现读产品自己的签名表源码**（`AgentSignatureDatabase.swift` 里那些 `processNames: [...]`），
# 不是装置里抄的一份常量——理由写在文件头：签名表改了字，闸的射程必须跟着改。
# 读不到源文件才退回兜底常量，并且**把来源打进 stdout**，"用哪份名单"永远是可核对的一行。
# ⚠️ 射程是"名字精确相等"（`pgrep -x`）：`processNamePrefixes`（"Cursor Helper"…）不在闸内，
#    那些是宿主 App 的 helper 进程，主进程名（`cursor`）已在名单里 ⇒ 只会不放宽、不会漏判宿主在跑。
gate_agents_resolve() {
  local src="${AGENT_SIGNATURES_SOURCE:-$(gate_root)/Sources/AIObservatoryPlatform/AgentDetection/AgentSignatureDatabase.swift}"
  local names=""
  if [ -f "$src" ] && command -v grep >/dev/null 2>&1; then
    # `grep -v '\[String\]'`：文件里还有一行 `public let processNames: [String]`（类型声明，
    # 不是数据）。少这一道筛，名单里会混进字面量 `String`——**装置自己的假样本**就是这么来的。
    names=$(grep -o 'processNames: *\[[^]]*\]' "$src" | grep -v '\[String\]' \
      | sed 's/.*\[//; s/\]//; s/"//g' | tr ',' '\n' \
      | sed 's/^ *//; s/ *$//' | grep -v '^$' | grep -v '^String$' | sort -u | tr '\n' ' ' | sed 's/ *$//')
    if [ -n "$names" ]; then printf '%s\t%s\n' "$names" "$src（产品签名表现读）"; return 0; fi
  fi
  printf '%s\t%s\n' "$FALLBACK_AGENT_PROCESSES" "兜底常量（源文件读不到：${src}）"
}

# 主判定：成功（return 0）= 静默 = 可以开窗。会把读数写进全局变量供调用方入表。
quiet_gate_check() {
  local reason_prefix="${1:-quiet-gate}"
  GATE_LOAD1=""; GATE_AGENTS=""; GATE_AGENT_MATCHES=""; GATE_REASON=""; GATE_MODE="real"
  GATE_AGENTS_SOURCE=""
  # 只要有任何一条 seam 被换掉，这一场的读数就**不是真机读数**（`gate_mode=injected`）。
  # ⚠️ 三个 seam 都要算：早先只标了 PROBE_*，于是 `LOAD_CMD="echo 0.5"` 能在 load 12 的机器上
  #    造出一条 `gate_mode=real` 的假"静默"记录 —— 装自检的把戏反过来骗了装置自己。
  if [ "$LOAD_CMD" != "$LOAD_CMD_PRODUCTION" ]; then GATE_MODE="injected"; fi

  local ceiling="${LOAD_CEILING:-4}"
  if ! printf '%s' "$ceiling" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    GATE_REASON="$reason_prefix：LOAD_CEILING 不是个数（[$ceiling]）⇒ 按不静默处理，不用一个坏上限去放行"
    return 1
  fi
  local agents="${AGENT_PROCESSES:-}"
  local agents_source=""
  if [ -z "$agents" ]; then
    local resolved; resolved=$(gate_agents_resolve)
    agents="${resolved%%	*}"; agents_source="${resolved#*	}"
  else
    agents_source="调用方注入（AGENT_PROCESSES）"
  fi
  GATE_AGENTS="$agents"; GATE_AGENTS_SOURCE="$agents_source"

  # 1) load 首段。取不到数 / 数不是个数 = **失败**（不许把"读坏了"当成"负载为 0"放行进窗）。
  #    这条守卫是真踩出来的：早期自检里一条被引号切碎的命令让 `awk` 拿到 `'12.3`，
  #    `+0` 把它归零 ⇒ 闸在机器 load 12 的情况下回了 pass。**读不出个数比读到高值更危险。**
  local raw
  if ! raw=$($LOAD_CMD 2>/dev/null); then
    GATE_REASON="$reason_prefix：load 取数命令失败（$LOAD_CMD）"
    return 1
  fi
  GATE_LOAD1=$(printf '%s' "$raw" | tr '{}' ' ' | awk '{print $1}')
  if ! printf '%s' "${GATE_LOAD1:-}" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    GATE_REASON="$reason_prefix：load 读数不是个数（读到=[${GATE_LOAD1:-<空>}]，原文=[$raw]）⇒ 按不静默处理"
    return 1
  fi
  local busy=""
  if [ -n "$PROBE_CMD" ]; then
    GATE_MODE="injected"
    if ! busy=$($PROBE_CMD 2>/dev/null); then GATE_REASON="$reason_prefix：Agent 探测命令失败"; return 1; fi
  elif [ -n "$PROBE_PIDS_CMD" ]; then
    GATE_MODE="injected"
    for n in $agents; do
      local ps_
      if ! ps_=$($PROBE_PIDS_CMD "$n" 2>/dev/null); then
        GATE_REASON="$reason_prefix：Agent 探测命令失败（$n）"
        return 1
      fi
      [ -n "$ps_" ] && busy="$busy
$ps_"
    done
  else
    for n in $agents; do
      local ps_
      ps_=$(pgrep -x -- "$n" 2>/dev/null) || true
      [ -n "$ps_" ] && busy="$busy
$ps_"
    done
  fi
  GATE_AGENT_MATCHES=$(printf '%s' "$busy" | tr '\n' ' ' | sed 's/^ *//;s/ *$//')

  local over=""
  over=$(awk -v l="$GATE_LOAD1" -v c="$ceiling" 'BEGIN{ printf "%d", (l+0 > c+0) }')
  local parts=""
  [ "$over" = "1" ] && parts="load_1m ${GATE_LOAD1} > ${ceiling}"
  if [ -n "$GATE_AGENT_MATCHES" ]; then
    parts="${parts:+$parts; }被观测 Agent 在跑（名单 [${GATE_AGENTS}] ⇒ 命中 pid ${GATE_AGENT_MATCHES}）"
  fi
  if [ "$over" = "1" ] || [ -n "$GATE_AGENT_MATCHES" ]; then
    GATE_REASON="$reason_prefix：$parts"
    return 1
  fi
  return 0
}

# 带重试的主判定：驱动器在每个测量单元**开始之前**调它。
#   为什么要有重试、又为什么要"重试若干次就整轮退出"：
#     不重试 ⇒ 某个车道恰好在那一秒跑完一次编译，整场 9 页就被误判成"不静默"，白跑；
#     无限重试 ⇒ 装置变成"等一台永远不来的静默机器"，而且没人知道它在等（上一轮就是没人知道）。
#     ⇒ 有限次 + 每次都把"第几次、读到什么"打到 stderr：等得起，也看得见。
#   ⚠️ 重试**只放宽"等多久"，绝不放宽判据**：LOAD_CEILING 与 Agent 名单一次都不打折。
GATE_TRIES="${GATE_TRIES:-3}"
GATE_WAIT="${GATE_WAIT:-20}"
quiet_gate_wait() {   # $1 = 原因前缀；$2 = 重试次数（可选，默认 GATE_TRIES）
  local prefix="${1:-quiet-gate}" tries="${2:-$GATE_TRIES}" i
  GATE_TRIES_USED=0
  for (( i = 1; i <= tries; i++ )); do
    GATE_TRIES_USED=$i
    if quiet_gate_check "$prefix（第 $i/$tries 次）"; then
      [ "$i" -gt 1 ] && echo "✅ 静默闸在第 $i/$tries 次通过（前面 $((i-1)) 次不静默，已等过 $(( (i-1) * GATE_WAIT )) s）。" >&2
      return 0
    fi
    if [ "$i" -lt "$tries" ]; then
      echo "⏳ 静默闸未过（第 $i/$tries 次）：$GATE_REASON ⇒ 等 ${GATE_WAIT}s 再判一次；**这一窗还没开**。" >&2
      sleep "$GATE_WAIT"
    fi
  done
  GATE_REASON="${GATE_REASON}（已重试 ${tries} 次，每次间隔 ${GATE_WAIT}s）"
  return 1
}

gate_emit() {
  local ok="$1"
  printf 'QUIET_GATE=%s\n' "$ok"
  printf 'load_1m=%s\n' "${GATE_LOAD1:-}"
  printf 'agent_processes=%s\n' "${GATE_AGENTS:-}"
  printf 'agent_pids=%s\n' "${GATE_AGENT_MATCHES:-}"
  printf 'agent_processes_source=%s\n' "${GATE_AGENTS_SOURCE:-}"
  printf 'load_ceiling=%s\n' "${LOAD_CEILING:-4}"
  printf 'gate_mode=%s\n' "${GATE_MODE:-real}"
  printf 'gate_reason=%s\n' "${GATE_REASON:-（静默）}"
}

quiet_gate_main() {
  if [ "${1:-}" = "--print-agents" ]; then
    local r; r=$(gate_agents_resolve)
    printf 'agent_processes=%s\nagent_processes_source=%s\n' "${r%%	*}" "${r#*	}"
    return 0
  fi
  LOAD_CEILING="${LOAD_CEILING:-4}"
  if quiet_gate_check "quiet-gate 独立跑"; then gate_emit pass; return 0; fi
  gate_emit fail >&2
  echo "⛔ 静默前置闸未过 ⇒ 不许开测量窗：$GATE_REASON" >&2
  return 1
}

# 直接执行（不是被 source）时跑主流程。
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  quiet_gate_main "$@"
fi
