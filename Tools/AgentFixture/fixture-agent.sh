#!/bin/bash
#
#  fixture-agent.sh — 编译并启动合成 Agent，可选地与真机验收一起跑。
#
#  Owner: master-controller
#
#  用法：fixture-agent.sh [持续秒数=45] [--foreground]
#  约束：只在 AiX 目录内读写；到点自杀；退出时删除 work/ 里的临时二进制与文件。
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"
REPO="$(cd "$HERE/../.." && pwd)"
DURATION="${1:-45}"
case "$DURATION" in --*) DURATION=45 ;; esac

rm -rf "$WORK"
mkdir -p "$WORK/junk"
printf 'line-1\n' > "$WORK/notes.md"

if ! cc -o "$WORK/claude" "$HERE/fixture-agent.c" 2>"$WORK/cc.log"; then
  echo "编译 fixture 失败：" >&2
  cat "$WORK/cc.log" >&2
  exit 1
fi

echo "fixture agent starting duration=${DURATION}s"
if [ "${2:-}" = "--foreground" ]; then
  "$WORK/claude" "$DURATION" "$WORK" "$REPO"
  rm -rf "$WORK"
else
  "$WORK/claude" "$DURATION" "$WORK" "$REPO" &
  AGENT_PID=$!
  cleanup() { kill "$AGENT_PID" 2>/dev/null; wait "$AGENT_PID" 2>/dev/null; rm -rf "$WORK"; }
  trap cleanup EXIT INT TERM
  echo "fixture agent pid=$AGENT_PID duration=${DURATION}s"
  sleep "$DURATION"
fi
