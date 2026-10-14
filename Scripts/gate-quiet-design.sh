#!/usr/bin/env bash
#
#  gate-quiet-design.sh — QUIET 设计基座的「采用率」门禁
#
#  Owner: master-controller（workbuddy 侧）
#
#  为什么有这个文件：
#  2026-09-20 的实测发现（`04-决策记录/发现-quiet基座采用率与QUIET车道合流撞车点.md`）
#  指出「去玻璃」做完了，但「统一主次」只在 Dashboard 一页做完——基座里为「主次 / 收口 / 统一轴」
#  新增的组件在其余页上消费者是 0 或 1。用例全绿、编译零警告，界面照样没有主次。
#  ⇒ 「测试绿」不能证明这件事，必须数消费者。
#
#  本脚本是那个发现的**可执行版本**。它刻意与 `Scripts/merge-workstream.sh` 分开：
#  同一时刻有两个会话在动这棵仓（另一套跑性能车道），共用一个闸门文件必然撞车；
#  门禁逻辑放独立文件，谁都能跑、谁都不会覆盖谁。
#
#  用法：
#    Scripts/gate-quiet-design.sh                 # 检查当前检出
#    Scripts/gate-quiet-design.sh <目录>          # 检查某棵工作树，如 .worktrees/quiet2
#
#  退出码：0 = 全绿；1 = 有 FAIL（并逐条打印）
#
#  边界：只读，不写任何文件。
set -uo pipefail

ROOT="${1:-}"
if [ -n "$ROOT" ]; then
    SRC="$ROOT/Sources/AIObservatoryUI"
else
    SRC="Sources/AIObservatoryUI"
fi

if [ ! -d "$SRC" ]; then
    echo "❌ 找不到 UI 源码目录：$SRC"
    exit 1
fi

FAIL=0
PAGES=(Dashboard Sessions Timeline Files Performance Security Settings Commands Projects)

echo "==> 门禁 1：九个板块各自必须包在 ObservatoryPage 里（统一 1120pt 收口 + 页面留白）"
for d in "${PAGES[@]}"; do
    if [ ! -d "$SRC/$d" ]; then
        printf '  %-12s ⏭  目录不存在（跳过）\n' "$d"
        continue
    fi
    if grep -rlq "ObservatoryPage" "$SRC/$d" 2>/dev/null; then
        printf '  %-12s ✅\n' "$d"
    else
        printf '  %-12s ❌ 未使用 ObservatoryPage（宽窗口不收口、页面底不统一）\n' "$d"
        FAIL=1
    fi
done

echo
echo "==> 门禁 2：图表必须走共享轴/图例，不许自绘坐标轴"
# ChartChrome.swift 是共享实现本身，排除它自己。
SELF_DRAWN="$(grep -rl 'chartXAxis\|chartYAxis' "$SRC" 2>/dev/null \
    | grep -v 'DesignSystem/ChartChrome.swift' || true)"
if [ -z "$SELF_DRAWN" ]; then
    echo "  ✅ 零命中"
else
    echo "  ❌ 以下文件仍自绘坐标轴，未走 ObservatoryChart："
    printf '     %s\n' $SELF_DRAWN
    FAIL=1
fi

echo
echo "==> 门禁 3：风险等级名不许退回条件显示（medium 与 high 共用橙色，文字是唯一区分通道）"
ROW="$SRC/Security/RiskEventRow.swift"
if [ ! -f "$ROW" ]; then
    echo "  ⏭  文件不存在（跳过）：$ROW"
elif grep -q 'else if event\.level >= \.high' "$ROW"; then
    echo "  ❌ $ROW 里等级名又挂上了条件 —— medium 行屏幕上没有任何等级文字，与 high 只剩同样的橙。"
    echo "     见 ADR-0008 §2 与 b364ceb。"
    FAIL=1
else
    echo "  ✅ 不是条件显示"
fi

echo
echo "==> 附：设计语言禁令（应为 0，Preview/注释里的合法用法需人工判断）"
for pat in '\.shadow(' 'ultraThinMaterial' 'textCase(\.uppercase)' 'tracking(' 'GridItem(\.adaptive'; do
    n="$(grep -rn "$pat" "$SRC" 2>/dev/null | grep -vc '///\|^\s*//' || true)"
    printf '  %-24s %s\n' "$pat" "${n:-0}"
done

echo
echo "==> 附：基座采用率（只报数，不作判定）"
printf '  %-24s %s\n' 'ObservatoryPage   ' "$(grep -rn 'ObservatoryPage' "$SRC" 2>/dev/null | wc -l | tr -d ' ')"
printf '  %-24s %s\n' 'Panel(            ' "$(grep -rn 'Panel {' "$SRC" 2>/dev/null | wc -l | tr -d ' ')"
printf '  %-24s %s\n' 'Hairline(         ' "$(grep -rn 'Hairline()' "$SRC" 2>/dev/null | wc -l | tr -d ' ')"
printf '  %-24s %s\n' 'MetricGrid(       ' "$(grep -rn 'MetricGrid(' "$SRC" 2>/dev/null | wc -l | tr -d ' ')"
printf '  %-24s %s\n' 'Tag(              ' "$(grep -rn 'Tag(' "$SRC" 2>/dev/null | wc -l | tr -d ' ')"
printf '  %-24s %s\n' '.ax* 排版阶梯     ' "$(grep -rnE '\.ax[A-Z]' "$SRC" 2>/dev/null | wc -l | tr -d ' ')"
printf '  %-24s %s\n' '系统字面 .font(.  ' "$(grep -rnE '\.font\(\.(caption|callout|body|title|headline|subheadline)' "$SRC" 2>/dev/null | wc -l | tr -d ' ')"
printf '  %-24s %s\n' 'GlassCard         ' "$(grep -rn 'GlassCard' "$SRC" 2>/dev/null | wc -l | tr -d ' ')"

echo
if [ "$FAIL" = 0 ]; then
    echo "✅ 三条门禁全绿：$SRC"
else
    echo "❌ 有门禁未过（见上）。"
    echo "   注：门禁 1/2 在车道交付**之前**跑必然红——它们是**车道交付线**，不是总控现在的拦截线。"
fi
exit "$FAIL"
