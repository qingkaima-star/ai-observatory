#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/db-activity.sh — 只读取"这一扇窗里被观测对象动了多少"（#92 第二格）
#
#  Owner: ws/rig（测量装置，不进产品 target）
#  ─────────────────────────────────────────────────────────
#  为什么活动量必须**入表**，而不是"跑完再看一眼监控"：
#   上一轮 A/B（`真机验收-逐页与开销基线.md` §13→§14）把首页读成"本波让首页变贵 +3~+12 pt"，
#   总控用同一批原始件重算，得到的主项是**窗口内被观测到的 agent 命令数**：
#   `Δcpu_s = −0.10 + 0.353 × events`、r = 0.822，四对同号（含被丢掉的那一对）。
#   ⇒ 活动量不在表里，配对报告就没有自变量可用，只能拿"总量"当"成本"比——那是把
#     **别人的活动**记成**被测构建的开销**。本脚本把自变量随每扇窗一起钉住。
#
#   还有一个更阴的口径坑：**读不到数不等于 0**。
#   `sqlite3` 报错时 stdout 是空的，`awk` 会把它当 0 ⇒ 表里出现一条"窗口内零活动"的假读数，
#   回归的自变量被污染成 0，斜率与截距都跟着作废。⇒ 本脚本对任何取不到的量打 **`na`**，
#   并在 `ab-report.py` 里"有 na ⇒ 这一行不许参与计算"。**宁可少一行，不可多一行假的。**
#
#  铁律：**只读**。走 `sqlite3 "file:<绝对路径>?mode=ro"`，与 `controls.sh` 那条已验的口径一致
#   （实测活库 sha 全程不变；见 §13.2）。装置对任何库都不该有写权限。
#
#  用法：
#    Tools/UIProbe/db-activity.sh --db "$DIR/observatory.sqlite"                 # 现读一份计数
#    Tools/UIProbe/db-activity.sh --db … --prefix t0_                            # 可 eval，前后各一次
#    Tools/UIProbe/db-activity.sh --db … --window <t0>:<t1>                      # 按墙钟窗口回溯数
#                                                                                # （t0/t1 = Unix epoch 秒；
#                                                                                #  库里是 ReferenceDate 秒，
#                                                                                #  换算见下面那段注释）
#    Tools/UIProbe/db-activity.sh --db … --format kv|tsv
#  退出码：0 全部取到；1 至少一个 `na`（含库不存在）；2 参数错
#  列（`na` 也算取到与否，不算 0）：
#    events commands file_changes risk_events perf_samples system_perf sessions agents
#    tick_cadence_s（近 20 拍 system_perf 的实测节奏：把 Δcpu 换成 ms/tick 用的就是它，不是名义 3 s）
#    给了 --window 再加一组 `win_*`（落在该窗内的行数；左闭右开）
# ============================================================================
set -u

DB=""
PREFIX=""
FORMAT="kv"
WINDOW_RANGE="${WINDOW_RANGE:-}"
TABLES="events commands file_changes risk_events perf_samples system_perf sessions agents"

while [ $# -gt 0 ]; do
  case "$1" in
    --db)      DB="${2:-}"; shift 2 ;;
    --prefix)  PREFIX="${2:-}"; shift 2 ;;
    --format)  FORMAT="${2:-kv}"; shift 2 ;;
    --window)  WINDOW_RANGE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[ -n "$DB" ] || { echo "❌ 缺 --db <库路径>" >&2; exit 2; }
command -v sqlite3 >/dev/null 2>&1 || { echo "❌ 没有 sqlite3，装置无法取活动量" >&2; exit 2; }

# 相对路径在 `file:` URI 里不是相对当前目录那么直观 ⇒ 一律先转绝对路径。
case "$DB" in
  /*) ABS="$DB" ;;
  *)  ABS="$(cd "$(dirname "$DB")" 2>/dev/null && pwd)/$(basename "$DB")" ;;
esac

SQLITE_URI="file:$ABS?mode=ro"
MISSING=0

q() {   # $1 = SQL；成功打印单值，失败打印 na 并把 MISSING 置 1
  local out
  if ! out=$(sqlite3 "$SQLITE_URI" "$1" 2>/dev/null); then
    MISSING=1; printf 'na'; return 1
  fi
  if [ -z "$out" ]; then MISSING=1; printf 'na'; return 1; fi
  printf '%s' "$out"
}

emit() {  # $1=key $2=value —— 带前缀，供 eval
  printf '%s%s=%s\n' "$PREFIX" "$1" "$2"
}

if [ ! -f "$ABS" ]; then
  echo "❌ 库不存在：$ABS（装置绝不写库，也不猜活动量为 0）" >&2
  MISSING=1
fi
for t in $TABLES; do
  v="na"
  [ -f "$ABS" ] && v=$(q "select count(*) from $t;")
  emit "db_$t" "$v"
done

# 实测 tick 节奏：近 20 拍 system_perf 的首尾差 ÷ 间隔数。不足两拍 ⇒ na（不能拿名义 3 s 冒充实测）。
CAD="na"
if [ -f "$ABS" ]; then
  CAD=$(q "select case when count(*)<2 then 'na' else round((max(t)-min(t))/(count(*)-1),3) end \
           from (select timestamp as t from system_perf order by timestamp desc limit 20);")
  # round() 出来的可能是 "3.16"；`q` 允许小数，这里再挡一次非数字。
  case "$CAD" in
    ''|*[!0-9.]*) CAD="na"; MISSING=1 ;;
  esac
fi
emit tick_cadence_s "$CAD"

# ── 按**墙钟窗口**数（`--window <t0>:<t1>`，两个 Unix epoch 秒）────────────────
# 为什么单独有这一档：`measure-pages.sh` 走的是"窗前后各数一次、取增量"，那是**新**测量用的；
# 但要复算**已经跑完**的那 26 扇窗（§13 的原始件里只有 t0/t1 和 Δcpu，没有活动量列），
# 就得能从库里的行时间戳把"这一窗里被观测对象动了多少笔"**回溯**出来。
# §14 那次翻案靠的就是这一个数（`Δcpu_s = −0.10 + 0.353 × events`，r=0.822）。
#
# ⚠️ 库里的时间戳是 **ReferenceDate 秒**（`Date.timeIntervalSinceReferenceDate`，
#    基准 2001-01-01 00:00:00 UTC ⇒ Unix 秒减 978307200）。这是一个**绝对时间差**，
#    不涉及本地时区：本机 epoch 与库内秒只隔一个常量。搞错基准就是差 31 年，
#    结果永远是"窗口内 0 笔"——**看起来像"这窗没活动"**，是装置能造出的最坏假样本。
#    所以：偏移量写成变量、边界一律 `>= 起 < 止`（左闭右开，两臂同一规则）。
REF_UNIX_EPOCH="${REF_UNIX_EPOCH:-978307200}"
if [ -n "${WINDOW_RANGE:-}" ]; then
  case "$WINDOW_RANGE" in
    *:*) ;;
    *) echo "❌ --window 要的是 <t0>:<t1>（Unix epoch 秒），收到 [$WINDOW_RANGE]" >&2; exit 2 ;;
  esac
  WT0="${WINDOW_RANGE%%:*}"; WT1="${WINDOW_RANGE##*:}"
  case "$WT0$WT1" in
    *[!0-9]*|"") echo "❌ --window 的两端必须是正的 epoch 秒：[$WINDOW_RANGE]" >&2; exit 2 ;;
  esac
  [ "$WT1" -gt "$WT0" ] || { echo "❌ --window 终点不晚于起点：[$WINDOW_RANGE]" >&2; exit 2; }
  ST0=$((WT0 - REF_UNIX_EPOCH)); ST1=$((WT1 - REF_UNIX_EPOCH))
  # 时间列名不统一：events/file_changes/risk_events/perf_samples/system_perf 是 `timestamp`，
  # commands 只有 `started_at/ended_at`（会话内一条命令可能跨窗 ⇒ 以"开始时刻"归窗，两臂同规则）。
  emit win_t0_epoch "$WT0"; emit win_t1_epoch "$WT1"
  emit win_t0_refdate "$ST0"; emit win_t1_refdate "$ST1"
  for spec in "events:timestamp" "commands:started_at" "file_changes:timestamp" \
              "risk_events:timestamp" "perf_samples:timestamp" "system_perf:timestamp"; do
    t="${spec%%:*}"; col="${spec##*:}"
    v="na"
    [ -f "$ABS" ] && v=$(q "select count(*) from $t where $col >= $ST0 and $col < $ST1;")
    case "$v" in ''|*[!0-9]*) v="na"; MISSING=1 ;; esac
    emit "win_$t" "$v"
  done
fi

emit db_path "$ABS"
emit db_readonly 1
emit db_missing "$MISSING"

[ "$MISSING" -eq 0 ] && exit 0
echo "⚠️  有量为 na ⇒ 这一行不许参与配对报告（见 ab-report.py 的守卫）。" >&2
exit 1
