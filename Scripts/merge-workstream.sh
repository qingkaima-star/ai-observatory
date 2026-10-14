#!/usr/bin/env bash
# merge-workstream.sh — 把工作流分支合入主线，并删除工作树与分支。
# 用法：Scripts/merge-workstream.sh <ws-name> [--keep]
#
# 为什么门禁放在这里而不是靠人记得查：本仓至少三次险情都出自「把工作树里没提交的东西
# 一起卷进合并」——其中一次是一条 `// TEMP-PROBE` 探针改在 29 个文件共用的
# DesignSystem/SectionHeader.swift 上。脚本原先会自动 `git add -A` 把这些扫进合并，
# 并把构建输出整条丢弃（`>/dev/null 2>&1`），于是「✅ 通过」永远看不见警告，
# 而验收判据写的是**零警告**。所以下面三处都改成拒绝即失败、输出必须留档。
set -euo pipefail

# 门禁不过时**打印**回退命令而不是自动执行：主线上可能已经有别的车道随后合入的提交，
# 自动 `reset --hard` 会把别人的成果一起丢掉——这正是本项目禁止的破坏性操作。
rollback_hint() {
    local branch="$1" target="$2"
    echo
    echo "⛑  主线已含失败合并。确认 $branch 顶端就是这次合并（git log --oneline -3）后再回退："
    echo "      git -C '$REPO_ROOT' reset --hard $target"
    echo "   若期间有别的车道合入，改用 git revert $target..HEAD（逐条撤销，不吞别人成果）。"
    exit 1
}

WS="${1:?用法: merge-workstream.sh <ws-name> [--keep]}"
KEEP="${2:-}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARENT="$(dirname "$REPO_ROOT")"
WORKTREE_DIR="$PARENT/.worktrees/$WS"
BRANCH="ws/$WS"

cd "$REPO_ROOT"
CURRENT="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT" != "main" ]; then
    echo "⚠️  当前分支为 $CURRENT，切换到 main"
    git checkout main
fi

if ! git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "❌ 分支 $BRANCH 不存在"
    exit 1
fi

echo "==> 预检：工作树必须干净（不许把未提交的改动卷进合并）"
if [ -d "$WORKTREE_DIR" ]; then
    DIRT="$(git -C "$WORKTREE_DIR" status --porcelain)"
    if [ -n "$DIRT" ]; then
        echo "❌ $WORKTREE_DIR 有未提交改动，先由车道负责人逐条审过再提交（或还原）："
        printf '%s\n' "$DIRT"
        echo "   重点看有没有临时探针：git -C $WORKTREE_DIR grep -n 'TEMP-PROBE\|FIXME-TEMP' -- Sources/"
        exit 1
    fi
fi

echo "==> 预检：分支里不得残留临时探针"
if git -C "$WORKTREE_DIR" grep -n 'TEMP-PROBE\|FIXME-TEMP' -- Sources/ 2>/dev/null; then
    echo "❌ 上面这些行是给某次测量临时加的，合入前必须还原"
    exit 1
fi

echo "==> 合并 $BRANCH → main (--no-ff)"
PRE_MAIN="$(git rev-parse HEAD)"
git merge --no-ff "$BRANCH" -m "merge($WS): 合入并行工作流" || {
    echo "❌ 合并冲突，请手工解决后重试"
    exit 1
}

echo "==> 主线自检：构建（零错误零警告）+ 全量测试"
LOG_DIR="tmp/merge-$WS"
mkdir -p "$LOG_DIR"
BUILD_LOG="$LOG_DIR/build.txt"
# 退出码必须显式接住：pipefail 下 `swift build | tee` 失败会让脚本在打印诊断前就退出，
# 而 `|| true` 又会把失败伪装成成功。两边都不对，所以直接收码。
BUILD_STATUS=0
# 判据① 说的是**双构建**零警告，而 `swift build` 只编产品目标：测试目标里的警告它根本看不见。
# 这个洞今天就咬过一次——合入 #89 之后脚本报「0 警告」，手工 `swift build --build-tests`
# 才报出 `PageEnumerationTests.swift:50` 一条未使用的 `let`（`verify.sh` 有这一道，
# 但本脚本从不叫 verify.sh，所以"合入门禁"和"自检门禁"射程不一样）。
xcrun swift build --disable-sandbox >"$BUILD_LOG" 2>&1 || BUILD_STATUS=$?
xcrun swift build --build-tests --disable-sandbox >>"$BUILD_LOG" 2>&1 || BUILD_STATUS=$?
WARN_N="$(grep -c 'warning:' "$BUILD_LOG" || true)"
ERR_N="$(grep -c ': error:' "$BUILD_LOG" || true)"
if [ "$BUILD_STATUS" != "0" ] || [ "${ERR_N:-0}" != "0" ] || [ "${WARN_N:-0}" != "0" ]; then
    echo "❌ main 构建不干净（含 --build-tests）：exit=$BUILD_STATUS error=$ERR_N warning=$WARN_N，详见 $BUILD_LOG"
    grep -m 20 'warning:\|: error:' "$BUILD_LOG" || true
    rollback_hint main "$PRE_MAIN"
fi
echo "✅ main 双构建通过（产品目标 + 测试目标：exit 0 / 0 error / 0 warning）"

TEST_LOG="$LOG_DIR/test.txt"
TEST_STATUS=0
xcrun swift test --disable-sandbox >"$TEST_LOG" 2>&1 || TEST_STATUS=$?
tail -5 "$TEST_LOG"
# 不能用「输出里有没有 `Test run with`」当判据：Swift Testing 通过和失败都打这一句，
# 只有末尾的 passed/failed 和退出码有区别——那是会放走红测试的假绿灯。
if [ "$TEST_STATUS" != "0" ]; then
    echo "❌ 测试未通过（exit $TEST_STATUS），详见 $TEST_LOG"
    rollback_hint main "$PRE_MAIN"
fi

if [ "$KEEP" != "--keep" ]; then
    echo "==> 清理工作树与分支"
    # 不用 `rm -rf` 兜底、不用 `branch -D`：合并失败或被人为回退时，这两者会把唯一一份
    # 车道成果连带删掉。删不掉就停下来让人看，而不是把证据清走。
    git worktree remove "$WORKTREE_DIR" || { echo "❌ 工作树删不掉，手工看它为什么脏"; exit 1; }
    git worktree prune
    git branch -d "$BRANCH" || { echo "❌ 分支 $BRANCH 未完全合入，拒绝删除"; exit 1; }
    echo "✅ 已删除工作树 $WORKTREE_DIR 与分支 $BRANCH"
else
    echo "ℹ️  --keep 指定，保留工作树"
fi

echo
echo "🎉 $WS 已合入主线"
