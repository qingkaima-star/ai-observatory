#!/usr/bin/env bash
# new-worktree.sh — 为并行工作流创建独立工作树。
# 用法：Scripts/new-worktree.sh <ws-name> [base-branch]
#   <ws-name> 例如 agent-detection / file-tracking / ui
set -euo pipefail

WS="${1:?用法: new-worktree.sh <ws-name> [base-branch]}"
BASE="${2:-main}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARENT="$(dirname "$REPO_ROOT")"
WORKTREE_DIR="$PARENT/.worktrees/$WS"
BRANCH="ws/$WS"

if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "❌ $REPO_ROOT 不是 git 仓库"
    exit 1
fi

mkdir -p "$PARENT/.worktrees"

if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "⚠️  分支 $BRANCH 已存在，直接复用"
else
    git -C "$REPO_ROOT" branch "$BRANCH" "$BASE"
fi

if [ -d "$WORKTREE_DIR" ]; then
    echo "ℹ️  工作树已存在: $WORKTREE_DIR"
else
    git -C "$REPO_ROOT" worktree add "$WORKTREE_DIR" "$BRANCH"
fi

echo
echo "✅ 工作树就绪"
echo "   路径: $WORKTREE_DIR"
echo "   分支: $BRANCH"
echo
echo "下一步："
echo "   cd $WORKTREE_DIR && Scripts/verify.sh"
