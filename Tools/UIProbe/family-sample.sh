#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/family-sample.sh — 把「引擎 tick」与「前台重算」分开的第 1 路（#92 第四格）
#
#  Owner: ws/rig（测量装置，不进产品 target）
#  ─────────────────────────────────────────────────────────
#  为什么需要它（§14 留下的那格）：
#    `measure-pages.sh` 的 `ps -o time=` 取的是**整进程**累计 CPU，却记在"当前显示页"那一格。
#    落页核验是可信的（`AIOBSERVATORY_SECTION` + 窗口标题逐行核过，26 行全对上），
#    **但账记错了对象**：一扇窗里的 CPU 是「引擎每拍的固定活」+「前台为这一页重算的活」+
#    「别人在机器上干的活」三样之和，光看一个总数永远分不出"这 300 ms 是跟着页走的还是跟着引擎走的"。
#    本脚本把**叶子帧**按族分堆，于是"这一窗里 CPU 落在哪一族"第一次成为**表里的一列**。
#
#  口径（读这两列之前必须知道，缺一条就是把代理读数当成归因）：
#   1. 数的是 `sample` 调用图里的**叶子帧**（一条路径上最深的那一行 = 采样时刻真正在跑的那一帧），
#      不是"出现过"的帧数 —— 后者会把整条调用链重复计数，父帧永远等于子树之和，全是重复。
#      每帧的**列号**（`sample` 输出行首的采样数）就是这一族的权重，本脚本按列号累加。
#   2. ⚠️ **遮挡法不是分离器**：把窗口遮住只判得了"有没有在合成"，判不了"有没有在重算"
#      （合成停了 ≠ body 不再执行；本仓在 §13.7 已吃过一次）。所以这里走的是**帧族归因**，
#      与遮挡无关，两臂同规则。
#   3. 引擎族 / UI 族的**边界来自源码里的模块名**（`AIObservatoryEngine` / `ObservatoryStore`
#      / `SQLiteDatabase` 对 `SwiftUI` / `Charts` / `AppKit`），不是猜的符号前缀：
#      下面 ENGINE_RE / UI_RE 旁边各写一行"这个模块在 Sources/ 里存在"的核对，
#      `--self-check` 会顺带确认这两个正则都没写空。
#   4. 分不了的那部分进 `other_leaf_n`（App 外壳、系统库、Swift 运行时）——
#      **绝不塞进任一族**。宁可报"这一窗有 40% 的叶子帧归不了族"，也不给一个虚高的族计数。
#   5. `sample` 本身会打断被采进程若干毫秒 ⇒ 与 `footprint` 同族仪器偏差（两臂同受，只稀释差值）。
#      采样窗口只占测量窗的一小段 ⇒ 这两列是**代理**，与 `ms_per_tick` 不同尺，
#      不许拿它的绝对值去对 3% 判据。
#
#  用法：
#    Tools/UIProbe/family-sample.sh --pid 12345                    # 现场采 10 s 并分族
#    Tools/UIProbe/family-sample.sh --parse tmp/family-sample/sample-12345.txt   # 只重解析
#    Tools/UIProbe/family-sample.sh --self-check                   # 内嵌合成样本验解析器（不碰任何实例）
#  退出码：0 取到并解析；1 采到但调用图解析不出叶子（当场报 0 计数是假样本 ⇒ 交 na）；
#          2 参数/环境错；3 采样失败（进程不在了 / 权限）；4 自检不通过
#  stdout 只打 key=value（可 eval）；人读解释与报错一律走 stderr。
# ============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PID=""
SECONDS_=10
INTERVAL_MS=10
OUT_DIR="$ROOT/tmp/family-sample"
PARSE=""
SELFCHECK=0
# 族边界（**现读源码里的模块名 / 类型名**，不是抄来的符号前缀）：
#   引擎族 = `AIObservatoryEngine` 模块 + `AIObservatoryStore` 模块里的 `ObservatoryStore`
#            与 `SQLiteDatabase`（`sample` 打的是解链后的 `模块.类型.方法`，所以模块名与类型名都出现）
#   UI 族  = `SwiftUI` / `Charts` / `AppKit` 三个系统框架（二进制列 + 模块前缀两种写法都认）
# 改产品模块名 / 类型名 ⇒ 下面的 `--self-check` 会当场红，而不是等到真采出一个 0 才发现。
ENGINE_RE='AIObservatoryEngine|AIObservatoryStore|ObservatoryStore|SQLiteDatabase'
UI_RE='\(in (SwiftUI|Charts|AppKit)\)|(^|[ .])(SwiftUI|Charts|AppKit)[. ]'
ENGINE_MODULES="AIObservatoryEngine AIObservatoryStore"      # 必须是 Sources/ 下真实存在的模块
ENGINE_TYPES="ObservatoryStore SQLiteDatabase"               # 必须在 Sources/ 里有定义处

while [ $# -gt 0 ]; do
  case "$1" in
    --pid)       PID="${2:-}"; shift 2 ;;
    --seconds)   SECONDS_="${2:-}"; shift 2 ;;
    --interval)  INTERVAL_MS="${2:-}"; shift 2 ;;
    --outdir)    OUT_DIR="${2:-}"; shift 2 ;;
    --parse)     PARSE="${2:-}"; shift 2 ;;
    --self-check) SELFCHECK=1; shift ;;
    -h|--help)   sed -n '1,45p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

# ── 解析器（同一支 awk 服务三档：现场采样 / 只重解析 / 自检）──────────────────
# 两件事要同时对：
#   ① **一条采样路径只数一次**：`sample` 的父帧计数 = 整棵子树之和，父子一起数会把同一笔 CPU
#      数两遍。⇒ 只认"这条路径上最深的那一帧"（叶子），它的列号就是这一笔的权重。
#   ② **归族看的是"这笔活是经由哪个族跑下去的"**，不是叶子的二进制名。
#      引擎的活最终停在 `sqlite3_step` / `libsystem_kernel` 里，UI 的活最终停在 `mach_msg` 里——
#      只看叶子会把**两族都算成"其它"**，那一列就白加了。
#      ⇒ 取路径上**最深的族帧**赢（`Engine.tick → Store.fetch → sqlite3_step` 记引擎；
#         `SwiftUI.body → Charts. → mach_msg` 记 UI）。两族同现时更深的赢，因为时间就花在那儿。
#      路径上一个族帧都没有 ⇒ 老老实实进 `other_leaf_n`，**不塞进任一族**。
PARSER='
BEGIN { ing = 0; top = 0; have_prev = 0 }
/^Call graph:/ { ing = 1; next }
ing == 0 { next }
/^[A-Za-z]/ { ing = 0; next }                    # 下一个顶层小节开始 ⇒ 调用图结束
{
  line = $0
  if (line ~ /^[ \t]*$/) next
  match(line, /[^ \t]/); ind = RSTART - 1        # 缩进 = 树深度（sample 用空格画树）
  match(line, /^[ \t]*[0-9]+/); cnt = substr(line, 1, RLENGTH) + 0
  # 上一行不比本行浅 ⇒ 上一行没有子节点 = 那条路径的叶子（此时栈里正好是它的整条路径）
  if (have_prev && ind <= prev_ind) flush_leaf()
  while (top > 0 && stk_ind[top] >= ind) top--   # 出栈到父层
  top++; stk_ind[top] = ind; stk_line[top] = line
  prev_ind = ind; prev_cnt = cnt; have_prev = 1
}
END { if (have_prev) flush_leaf() }
function flush_leaf(   i, c, fam) {
  c = prev_cnt
  if (c <= 0) return
  fam = ""
  for (i = top; i >= 1; i--) {                   # 从最深往上找：最深的族帧赢
    if (stk_line[i] ~ /'"$ENGINE_RE"'/) { fam = "engine"; break }
    if (stk_line[i] ~ /'"$UI_RE"'/)      { fam = "ui"; break }
  }
  if      (fam == "engine") { eng += c }
  else if (fam == "ui")     { ui   += c }
  else                      { other += c }
  leaf_lines++
}
'

parse_file() {   # $1 = sample 文本 → 打印 key=value
  local txt="$1" eng ui other total leaf_lines
  read -r eng ui other leaf_lines <<EOF2
$(awk "$PARSER"'
END { printf "%d %d %d %d\n", eng+0, ui+0, other+0, leaf_lines+0 }' "$txt")
EOF2
  total=$(( ${eng:-0} + ${ui:-0} + ${other:-0} ))
  printf 'engine_leaf_n=%s\nui_leaf_n=%s\nother_leaf_n=%s\nleaf_total_n=%s\nleaf_lines=%s\n' \
    "$eng" "$ui" "$other" "$total" "$leaf_lines"
  printf 'engine_pct=%s\nui_pct=%s\nother_pct=%s\n' \
    "$(awk -v e="$eng" -v u="$ui" -v o="$other" 'BEGIN{t=e+u+o; if(t<=0){print "na na na"; exit} \
        printf "%.1f %.1f %.1f", e*100/t, u*100/t, o*100/t}')"
  [ "$total" -gt 0 ] && printf 'sample_ok=1\n' || printf 'sample_ok=0\n'
}

# ── 自检：内嵌一份合成样本，钉住"叶子不重复计数"与"族边界不写空"──────────────
# 合成数据一律用 `/Users/dev/…` 风格（AGENTS §0：仓内文件里不许出现宿主真实路径）。
self_check() {
  local f="$OUT_DIR/selfcheck-sample.txt" got fails=0
  mkdir -p "$OUT_DIR"
  cat > "$f" <<'EOF'
Analysis of sampling AIObservatory (pid 4242) every 10 milliseconds
Process:         AIObservatory [4242]
Path:            /Users/dev/ai-observatory/dist/AIObservatory.app/Contents/MacOS/AIObservatory
Date/Time:       2026-09-23 00:00:00.000 +0800

Call graph:
    100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
      100 start  (in dyld) + 1  [0x100]
        60 main  (in AIObservatory) + 2  [0x101]
          30 static AIObservatoryEngine.ObservatoryEngine.tick()  (in AIObservatory) + 3  [0x102]
            30 static ObservatoryStore.ObservatoryStore.fetch()  (in AIObservatory) + 4  [0x103]
              30 sqlite3_step  (in libsqlite3.dylib) + 5  [0x104]
          20 static SwiftUI.ViewBody.body.getter  (in SwiftUI) + 6  [0x105]
            20 specialized Charts.  (in Charts) + 7  [0x106]
        40 static AIObservatoryEngine.ObservatoryEngine.scan()  (in AIObservatory) + 8  [0x107]
          40 ???  (in libsystem_kernel.dylib)  load address 0x100 + 0x9  [0x108]
    20 Thread_2   com.apple.secondary
      20 _pthread_start  (in libsystem_pthread.dylib) + 10  [0x109]
        20 ???  (in Foundation)  + 11  [0x10A]
EOF
  got=$(parse_file "$f")
  # 期望值是按**上面那份树**手算的，写清每一笔从哪来（改 fixture 必须同时改这里，别调数字凑通过）：
  #   engine = 30（tick→fetch→sqlite3_step，路径上最深的族帧是 ObservatoryStore）
  #          + 40（scan→libsystem_kernel，族帧是 AIObservatoryEngine.scan）          = 70
  #   ui     = 20（body→Charts，族帧 SwiftUI/Charts）
  #   other  = 20（Thread_2 → _pthread_start → Foundation，路径上没有任何族帧）
  # 父帧（start/main/Thread_1）一律不数：它们的计数是子树之和，父子一起数 = 同一笔 CPU 数两遍。
  local want_engine=70 want_ui=20 want_other=20 want_leaf_lines=4
  printf 'selfcheck_engine=%s\nselfcheck_ui=%s\nselfcheck_other=%s\nselfcheck_total=%s\n' \
    "$(printf '%s' "$got" | awk -F= '/^engine_leaf_n=/{print $2}')" \
    "$(printf '%s' "$got" | awk -F= '/^ui_leaf_n=/{print $2}')" \
    "$(printf '%s' "$got" | awk -F= '/^other_leaf_n=/{print $2}')" \
    "$(printf '%s' "$got" | awk -F= '/^leaf_total_n=/{print $2}')" >&2
  chk() { if [ "$2" != "$3" ]; then echo "❌ 自检：$1 应为 $3，实得 $2" >&2; fails=$((fails+1)); fi; }
  chk engine_leaf_n "$(printf '%s' "$got" | awk -F= '/^engine_leaf_n=/{print $2}')" "$want_engine"
  chk ui_leaf_n     "$(printf '%s' "$got" | awk -F= '/^ui_leaf_n=/{print $2}')" "$want_ui"
  chk other_leaf_n  "$(printf '%s' "$got" | awk -F= '/^other_leaf_n=/{print $2}')" "$want_other"
  chk leaf_total_n  "$(printf '%s' "$got" | awk -F= '/^leaf_total_n=/{print $2}')" "$((want_engine+want_ui+want_other))"
  chk leaf_lines    "$(printf '%s' "$got" | awk -F= '/^leaf_lines=/{print $2}')" "$want_leaf_lines"
  # 族边界不许写空：正则改了字 / 产品模块或类型改名 ⇒ 这里当场红，而不是等到真采出一个 0 才发现。
  local src="$ROOT/Sources"
  for m in $ENGINE_MODULES; do
    [ -d "$src/$m" ] || { echo "❌ 自检：引擎族里的模块 Sources/$m 不存在 ⇒ ENGINE_RE 已过时" >&2; fails=$((fails+1)); }
  done
  for t in $ENGINE_TYPES; do
    grep -rqE "(actor|class|struct|final class) $t\\b" "$src" \
      || { echo "❌ 自检：引擎族里的类型 $t 在 Sources/ 里没有定义处 ⇒ ENGINE_RE 已过时" >&2; fails=$((fails+1)); }
    printf '%s' "$ENGINE_RE" | grep -q "$t" \
      || { echo "❌ 自检：类型 $t 没写进 ENGINE_RE ⇒ 它的帧会被记成 other（分族漏了一族）" >&2; fails=$((fails+1)); }
  done
  if [ "$fails" = "0" ]; then echo "✅ family-sample 自检通过（叶子不重复计数、族边界仍与源码同源）" >&2; return 0; fi
  echo "SELF_CHECK=fail" >&2
  return 4
}

if [ "$SELFCHECK" = "1" ]; then self_check; exit $?; fi

TXT="$PARSE"
if [ -z "$TXT" ]; then
  [ -n "$PID" ] || { echo "用法：--pid N | --parse FILE | --self-check" >&2; exit 2; }
  if ! kill -0 "$PID" 2>/dev/null; then
    printf 'engine_leaf_n=na\nui_leaf_n=na\nother_leaf_n=na\nsample_reason=进程不在了（pid=%s）⇒ 交 na 不交 0\n' "$PID"
    exit 3
  fi
  mkdir -p "$OUT_DIR"
  TXT="$OUT_DIR/sample-$PID-$(date +%H%M%S).txt"
  if ! sample "$PID" "$SECONDS_" "$INTERVAL_MS" -file "$TXT" >/dev/null 2>&1; then
    echo "sample_leaf_engine=na"
    echo "sample_leaf_ui=na"
    echo "sample_leaf_other=na"
    echo "sample_reason=sample 失败（权限 / 进程退出）"
    echo "❌ sample 采集失败：pid=$PID 文本=$TXT" >&2
    exit 3
  fi
  echo "样本原文：$TXT（${SECONDS_}s × ${INTERVAL_MS}ms）" >&2
fi
[ -f "$TXT" ] || { echo "❌ 要解析的文件不存在：$TXT" >&2; exit 2; }

# `tee /dev/stdout` 让"看到的"与"参与判定的"是同一份文本（不是先判再印的第二份）。
# ⚠️ PIPESTATUS 里 **awk 是第 3 个元素**（数错一位 = 解析失败也会被当成功返回 0，这种错只会悄悄发生）。
parse_file "$TXT" | tee /dev/stdout | awk -F= '
/^engine_leaf_n=/ { e=$2 } /^ui_leaf_n=/ { u=$2 }
END { if (e+0 == 0 && u+0 == 0) { print "sample_ok=0"; print "❌ 一个叶子都没归上族 ⇒ 交 na，不许交 0" > "/dev/stderr"; exit 1 } exit 0 }'
rc=${PIPESTATUS[2]}
[ "$rc" = "0" ] || exit 1
exit 0
