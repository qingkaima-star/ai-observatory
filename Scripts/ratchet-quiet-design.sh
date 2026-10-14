#!/usr/bin/env bash
#
# ============================================================================
#  Scripts/ratchet-quiet-design.sh — 把 quiet 设计门禁变成**只拦新增**的棘轮
#
#  Owner: 总控
#  ─────────────────────────────────────────────────────────
#  为什么要有这个包装：`gate-quiet-design.sh` 三条门禁里门禁 2 在 main 上实测就是红的
#  （6 个文件仍自绘 chartXAxis/chartYAxis），而它自己尾部也写着"这是车道交付线，
#  不是总控现在的拦截线"。结果就是**没有任何 CI 引用它** —— 一台没人跑的门禁等于没有门禁，
#  设计基座会一路悄悄退回去（ADR-0008 的三条禁令正是这么烂掉的）。
#
#  棘轮的做法：把**当前存量违规数**记进 `Scripts/quiet-design-baseline.txt`，
#  每次门禁只比数字：变多 ⇒ 失败（新代码不许再引入违规）；变少 ⇒ 提示收紧基线；
#  持平 ⇒ 通过。这样既不阻塞别人清旧账，又堵住了"再写一个新的"。
#
#  用法：Scripts/ratchet-quiet-design.sh [--update]   # --update 用当前值重写基线
#  退出码：0 未变差；1 变差了；2 基线缺失或门禁脚本跑不起来。
# ============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

BASELINE="Scripts/quiet-design-baseline.txt"
SRC="Sources/AIObservatoryUI"
[ -d "$SRC" ] || { echo "❌ 找不到 $SRC" >&2; exit 2; }

# 三项计数与 gate-quiet-design.sh 的判据一一对应（改那边要同步这里）。
count_pages() {
    local n=0 d
    for d in Dashboard Sessions Timeline Files Performance Security Settings Commands Projects; do
        [ -d "$SRC/$d" ] || continue
        grep -rlq "ObservatoryPage" "$SRC/$d" 2>/dev/null || n=$((n + 1))
    done
    echo "$n"
}

count_selfdrawn() {
    grep -rl 'chartXAxis\|chartYAxis' "$SRC" 2>/dev/null \
        | grep -v 'DesignSystem/ChartChrome.swift' | wc -l | tr -d ' '
}

count_forbidden() {
    local total=0 pat n
    for pat in '\.shadow(' 'ultraThinMaterial' 'textCase(\.uppercase)' 'tracking(' 'GridItem(\.adaptive'; do
        n="$(grep -rn "$pat" "$SRC" 2>/dev/null | grep -vc '///\|^\s*//' || true)"
        total=$((total + ${n:-0}))
    done
    echo "$total"
}

current=$(printf 'pages_without_observatorypage=%s\nself_drawn_axis_files=%s\nforbidden_construct_hits=%s\n' \
    "$(count_pages)" "$(count_selfdrawn)" "$(count_forbidden)")

if [ "${1:-}" = "--update" ]; then
    printf '%s\n' "$current" > "$BASELINE"
    echo "✅ 基线已按当前值重写：$BASELINE"
    printf '%s\n' "$current" | sed 's/^/     /'
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "❌ 缺基线文件 $BASELINE（先跑 Scripts/ratchet-quiet-design.sh --update）" >&2
    exit 2
fi

worse=0
better=0
while IFS='=' read -r key now; do
    [ -n "${key:-}" ] || continue
    was="$(grep -m1 "^$key=" "$BASELINE" | cut -d= -f2)"
    [ -n "${was:-}" ] || { echo "  ⚠️  基线里没有 $key，按 0 处理"; was=0; }
    if [ "$now" -gt "$was" ]; then
        echo "  ❌ $key：基线 $was → 现在 $now（**新增违规**）"
        worse=$((worse + 1))
    elif [ "$now" -lt "$was" ]; then
        echo "  ✅ $key：基线 $was → 现在 $now（清掉了 $((was - now)) 处，记得 --update 收紧）"
        better=$((better + 1))
    else
        echo "  ―  $key：$now（与基线持平）"
    fi
done <<< "$current"

if [ "$worse" -gt 0 ]; then
    echo "❌ quiet 设计棘轮变差：$worse 项出现新增违规。"
    echo "   存量违规由 ws/uiclose 在清（见认领板派单）；**新写的代码不许再加一类**。"
    exit 1
fi
echo "✅ quiet 设计棘轮未变差（收紧 $better 项待记基线）。"
