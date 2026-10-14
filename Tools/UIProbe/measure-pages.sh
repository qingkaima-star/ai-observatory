#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/measure-pages.sh — 逐页资源扫描（判据④ 的页面级尺子）
#
#  Owner: 总控（开发工具，不进产品 target）
#  ─────────────────────────────────────────────────────────
#  为什么要有这个脚本，而不是"打开 App 看一眼活动监视器"：
#   1. 判据④ 写的是「空闲 CPU < 3% 且内存 < 200 MB」，而这两个数**按页面差很多**。
#      只测默认页会得到一个真实但没覆盖问题的结论（AGENTS.md §6 的口径陷阱）。
#   2. 内存的尺子必须是 `phys_footprint`，**不是** `ps -o rss`：
#      RSS 把多进程共享的只读框架页全记在本进程头上
#      （实测同一时刻 RSS 189.6 MB vs phys_footprint 88.8 MB；见 ADR-0009 裁定 1）。
#   3. `footprint` 自己会抖（实测 1 分钟内 91→78 MB，一个 MALLOC_LARGE 16 MB arena 的来去），
#      所以**单点取数不算测量**：本脚本每页采 `SAMPLES` 次、判定用最大值，
#      并同时报 `phys_footprint_peak`——峰值发生在采样间隙，只报 `max(样本)` 会漏。
#
#  口径与限制（读数前必须知道）：
#   - CPU 按「Δcputime / Δ墙钟」算（`ps -o time=`），不是 `ps -o %cpu`（那是衰减平均，会乱跳）。
#     窗口不是真静默时，CPU 列**只能当参考**：别的负载只会让我们少被调度 ⇒ 系统性**低估**，
#     所以"超标"是可信的、"达标"不可信。正式判定请配合 `measure-idle.sh` 在静默窗跑。
#   - 每页起一个**新实例**（fresh process），所以这组数刻画的是"进入该页并停留 3 分钟"，
#     不是"从启动就在该页"的累计成本。两者不同，别混用。
#   - 数据目录里必须**已有真实数据**，否则列表页没东西可渲染，测的是空载。
#     本脚本不造数据：由调用方导出 `AIOBSERVATORY_DATA_DIR` 指向一份有内容的库。
#   - 采样工具（`footprint`）会让被采进程短暂停顿 ⇒ 停顿不产生 CPU 时间，
#     但会拉长墙钟，所以 CPU 列会被**轻微低估**。要严格时用 `measure-idle.sh`。
#
#   - **每行必须真的落在对应板块上**。曾经出过一个 P0 自伤：脚本按 `SECTIONS` 起实例
#     却**没有导出 `AIOBSERVATORY_SECTION`**（`ShellModel.swift:54` 才是唯一认这个变量的地方），
#     于是"九个板块"的九行全是**同一个默认 Dashboard 页**，跨页差异其实是噪声——
#     据此写过"Sessions 页是离群值"的结论，已作废（见 AiX-Vault/00-总控台/车道认领-…-性能.md）。
#     现在每行起完都会用窗口标题核验（标题即 `SidebarSection.title`，见下面的表），
#     核验不过**直接记为该轮失败并丢弃该行数据**，不再给一个"看着像数"的假读数。
#     标题读不到（无辅助功能权限 / 窗口没起）同样算失败，不静默放行。
#
#  ── #92 装置补的五件事（2026-09-23，车道 `ws/rig`；改的都是尺子，没有一行产品代码）──
#   ① **静默前置闸在开窗之前**（`quiet-gate.sh`）。这一版之前，闸只存在于 `quiet-verdict.sh`
#      的收尾汇总里：上一轮 26 扇窗（load 5.3–16.4）全部**先跑完再说"不作判定"**，
#      白等 26 × 142 s，还把三页读数留在了表里当"参考"。⇒ 现在两道闸：
#      **整场一道**（在找 release 包**之前**，不过就退出码 4，连包都不看、实例都不起）+
#      **每行一道**（机器中途变忙 ⇒ 后面几页不开，CSV 里那一行写 `静默闸未过·未开这一行`）。
#   ② **窗口内活动量入表**（`db-activity.sh`，只读）。§14 那次翻案说明：不记活动量，
#      配对报告就没有自变量，只能拿总量当成本比 ⇒ 把"别人的活动"记成"被测构建的开销"。
#      现在每行带 `events/commands/file_changes/risk_events/perf_samples` 的**窗内增量**，
#      以及**实测 tick 节奏**（`tick_cadence_s`，近 20 拍 system_perf 首尾差 ÷ 间隔数）。
#   ③ **ms/tick 用实测节奏**，不再默认名义 3 s（缺读数时退回名义并在 `cadence_source` 里
#      写明 `nominal` —— 冒充实测就是假样本）。`ps -o time=` 的口径没动（AGENTS §6）。
#   ④ **「引擎 tick」与「前台重算」各占一列**（#92 第四格）：
#      · `engine_leaf_n / ui_leaf_n / other_leaf_n / sample_ok` ← `family-sample.sh` 在窗内采一段
#        `sample`，按**路径上最深的族帧**归族（引擎族 = `AIObservatoryEngine`/`AIObservatoryStore`
#        的 `ObservatoryStore`/`SQLiteDatabase`；UI 族 = `SwiftUI`/`Charts`/`AppKit`）。
#        只看叶子会把两族都算成"其它"（引擎的活最终停在 `sqlite3_step`），所以归的是"这笔活经由哪个族跑下去"。
#      · `turn_p50_ms / turn_gt_100ms_n / turn_instrument` ← `turn-trace.sh`（主线程单次 CFRunLoop
#        turn 墙钟）。**默认关**（`TURN_TRACE=1` 才开）：它 `xctrace --attach` 会把目标冻住再放开、
#        墙钟 3–15×，开在窗内就是污染自己正要量的 Δcpu ⇒ 只在 t1 取完之后跑，描述"同页刚测完时"。
#      ⚠️ 遮挡法不当分离器：它只判"有没有在合成"，判不了"有没有在重算"（§13.7 已吃过一次）。
#   ⑤ 表头与行装配抽到 `row-format.sh`（列清单唯一出处 + 可离线验"值带空格/逗号不破表"）。
#   ⚠️ `load_before/load_after` 两列**原样保留**（`quiet-verdict.sh` 的老解析还指着它们），
#      新加的 `load1_before/load1_after` 是干净浮点，两处共用同一个取数口。
#   ⚠️ `board_title()` 那张表被 `Tests/AIObservatoryUITests/SidebarNamingTests` **逐行读**，
#      改任何一行标题都会红；本文件其它改动都不碰它。
#
#  用法：
#    Tools/UIProbe/measure-pages.sh                          # 九个板块各一轮
#    Tools/UIProbe/measure-pages.sh sessions timeline commands   # 只测指定板块
#    WINDOW=240 SAMPLES=16 Tools/UIProbe/measure-pages.sh    # 加长窗口
#    LOAD_CEILING=4 Tools/UIProbe/measure-pages.sh           # 闸的上限（默认 4，与 quiet-verdict 同源）
#    GATE_TRIES=3 GATE_WAIT=20 …                             # 整场闸的重试口径（只放宽等待，不放宽判据）
#    RIG_ALLOW_INJECTED=1 …                                  # 自检专用：允许注入的闸读数（产物会标 gate_mode）
#    FAMILY_SAMPLE_SECONDS=10 …                              # 窗内 sample 那一段多长（0 = 关，列里是 na）
#    TURN_TRACE=1 TURN_SECONDS=20 …                          # 开窗后加一轮 turn-trace（默认关，理由见 ④）
#  输出：CSV 到 stdout 与 tmp/page-sweep.csv（tmp/ 已 gitignore）。
#  退出码：0 全部测完；2 缺 release 包或进程起不来；3 至少有一行没落到指定板块；
#          4 **全部行被静默前置闸拦下 ⇒ 不作判定**（读数一张都没有，不是"达标"也不是"超标"）。
# ============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

# 静默前置闸：唯一实现在 quiet-gate.sh（本脚本、quiet-verdict.sh、ab-sweep.sh 共用一颗）。
# 放不进 quiet-verdict.sh 是因为**逐页扫描本身也是驱动器**——上一轮就是"驱动器绕过裁判"。
. "$ROOT/Tools/UIProbe/quiet-gate.sh"
LOAD_CEILING="${LOAD_CEILING:-4}"          # 与 quiet-verdict.sh 同一个默认值，两处不许各自放宽
NOMINAL_TICK_SECONDS="${NOMINAL_TICK_SECONDS:-3}"   # 只在实测节奏取不到时退回它，并标 cadence_source=nominal

# ── 整场前置闸：放在**找包之前**。理由（§14 装置问题第三条）：
#    "闸在脚本里但不在驱动流程里" ⇒ 上一轮把 26 扇窗（≈62 分钟）全跑完，才发现它们**全部**不满足
#    本仓自带的静默闸（load 5.3–16.4 vs LOAD_CEILING=4）——成本已经付掉了，读数还留在表里被引用。
#    现在闸不过 ⇒ 连包都不去看、一颗实例都不起、零张读数，直接以退出码 4 结束。
#    这也是"判据④ 本轮未判定"与"本轮跑废了"能一眼分开的唯一办法。
if ! quiet_gate_wait "整场开测之前"; then
  echo "⛔ 静默前置闸未过 ⇒ **一场都不开**：$GATE_REASON" >&2
  echo "   需要的是机器静默（load_1m < ${LOAD_CEILING} 且被观测 Agent 不在跑），不是更长的窗口或更多的轮数。" >&2
  echo "   名单来源：${GATE_AGENTS_SOURCE:-（注入）}" >&2
  printf 'QUIET_GATE=fail\nload_1m=%s\ngate_mode=%s\ngate_tries=%s\ngate_reason=%s\n' \
    "${GATE_LOAD1:-na}" "${GATE_MODE:-real}" "${GATE_TRIES_USED:-?}" "$GATE_REASON" >&2   # 走 stderr：stdout 只能是 CSV
  echo "未开任何窗：读数 0 张 ⇒ **不作判定**（既不是达标也不是超标）。退出码 4。" >&2
  exit 4
fi

# 臂开关：A/B 驱动器在同一棵树上要指向**两颗不同的包**（`APP_OVERRIDE`），
# 并在每一行里带上**这是哪一臂**（`ARM`）——上一轮的臂身份只存在于驱动器的 manifest 里，
# 单看一行读数无法知道它是哪棵树打的包（"表里没有臂 ⇒ 报告只能靠行的先后顺序猜"）。
ARM="${ARM:-}"
APP="${APP_OVERRIDE:-}"
if [ -n "$APP" ]; then
  [ -d "$APP" ] || { echo "APP_OVERRIDE 指向的包不存在：$APP" >&2; exit 2; }
else
  APP_DIR="$ROOT/dist"
  APP=$(ls -d "$APP_DIR"/*.app 2>/dev/null | head -1)
fi
if [ -z "${APP:-}" ]; then
  echo "缺 release 包：先跑 Packaging/make-app.sh（或给 A/B 驱动器传 APP_OVERRIDE）" >&2
  exit 2
fi
EXE="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info" CFBundleExecutable)"
[ -x "$EXE" ] || { echo "可执行文件不存在：$EXE" >&2; exit 2; }

SECTIONS="${*:-dashboard sessions timeline commands files performance security projects settings}"
WINDOW="${WINDOW:-180}"          # 每页测量窗口（秒），不含预热
SAMPLES="${SAMPLES:-12}"          # 窗口内采样次数 ⇒ 间隔 = WINDOW / SAMPLES
SETTLE="${SETTLE:-45}"            # 预热：建库、首帧、订阅，不能算进均值
INTERVAL=$((WINDOW / SAMPLES))
OUT="${OUT:-$ROOT/tmp/page-sweep.csv}"
mkdir -p "$ROOT/tmp"

# 数据目录**必须由本脚本兜住**，不能指望调用方记得 export：
# 漏设时 App 会按 ADR-0003 的第 3 条落到 `~/Library/Application Support/com.aix.aiobservatory/`，
# 那既越过 AGENTS.md §0 的授权边界，也是隐私事故（本项目实测发生过一次，
# 事后是靠 lsof 才发现的）。这里显式落到仓内 tmp，并且**每次扫用同一份**，
# 这样九行读的是同一份数据，页面之间的差才是页面的差。
if [ -z "${AIOBSERVATORY_DATA_DIR:-}" ]; then
  export AIOBSERVATORY_DATA_DIR="$ROOT/tmp/pagesweep-data"
  mkdir -p "$AIOBSERVATORY_DATA_DIR"
  echo "ℹ️  未指定 AIOBSERVATORY_DATA_DIR ⇒ 落到 $AIOBSERVATORY_DATA_DIR（不会写 ~/Library）。" >&2
  echo "   注意：新目录里数据要跑几分钟才有内容，列表页前几轮可能测的是空载。" >&2
fi

if [ "$WINDOW" -lt 180 ]; then
  echo "⚠️  窗口 ${WINDOW}s < 180s：Δcputime 的量化误差与 footprint 的抖动都够推翻一条 <3% / <200MB 的结论。" >&2
fi

MEASURE_DB="$AIOBSERVATORY_DATA_DIR/observatory.sqlite"

# ── 表头与每一行都由 `row-format.sh` 那一处列清单生成（列名绝不在这类文件里抄第二遍：
#    上一轮的驱动器与尺子各写一份列序，加列全靠手抄逗号，抄错一位就是整列错位且**不报错**）。
. "$ROOT/Tools/UIProbe/row-format.sh"

emit_row() { row_line | tee -a "$OUT"; }
# 没开成窗的行（闸拦下 / 起不来 / 落错页）：只填语义字段，读数列一律留空 = "没测"，不是 0。
# ⚠️ "留空"是刻意的：写成 0 会让报告把"没测"当成"零活动 / 零开销"，那正好是 §14 翻案的那类错。
unmeasured_row() {  # $1=section $2=window_title $3=gate $4=gate_mode $5=gate_agents $6=load1_before
  row_reset
  row_set section "$1"; row_set window_title "$2"
  row_set arm "${ARM:-}"; row_set round "${ROUND:-}"
  row_set load1_before "$6"; row_set gate "$3"; row_set gate_mode "$4"; row_set gate_agents "$5"
  emit_row
}

row_header | tee "$OUT"

# 板块 → **窗口标题**。这里绑的是**窗口真正显示的那串字**，
# 因为护栏要回答的问题是"这个实例停在哪一页"，不是"侧栏写了什么"。
#
# 曾经九页里有三页对不上（侧栏「操作时间线」/ 窗口「行为时间线」、「终端命令审计」/「命令审计」、
# 「文件行为」/「文件变更」）——那是已派出去的 UI 缺陷（同一目的地两个名字）。
# `ws/uicopy` 已把三处收成**一个**出处：`SidebarSection.title` 同时供侧栏行、页内 hero、
# `.navigationTitle` ⇒ 表里这九组现在应当与 `SidebarSection.allCases` 的两语标题逐字相等。
#
# 【每个板块两行：中文 + 英文】B3 起窗口标题跟系统语言走，护栏问的仍是"落在哪一页"，
# 所以判据从 `got == want` 改成 **got ∈ 这两条之一**。这不是放松：
# 表仍然是**按板块**列的，落错页照样红；而用例
# `SidebarNamingTests.measurePagesTableMatchesTitles` 现在要求每个板块**恰好两条**、
# 且逐字等于 `title(.chineseSimplified)` / `title(.english)`，18 条跨语言互不相同
# ⇒ 两条里少任何一条、或英文跟枚举不一致，都当场红。
# 这条一致性由 `Tests/AIObservatoryUITests/SidebarNamingTests.swift` 逐行读本函数保证。
# ⇒ 改任何一侧的标题，请同步这里（用例是兜底，不是让你省掉知会）。
board_title() {
  case "$1" in
    dashboard)   echo "今日概览"
                 echo "Today" ;;
    sessions)    echo "AI 会话"
                 echo "AI sessions" ;;
    timeline)    echo "行为时间线"
                 echo "Activity timeline" ;;
    commands)    echo "命令审计"
                 echo "Command audit" ;;
    files)       echo "文件变更"
                 echo "File changes" ;;
    performance) echo "系统性能"
                 echo "Performance" ;;
    security)    echo "安全风险"
                 echo "Security risks" ;;
    projects)    echo "项目活动地图"
                 echo "Project activity map" ;;
    settings)    echo "设置"
                 echo "Settings" ;;
    *)           echo "" ;;
  esac
}

# 实测可用的一条（需要辅助功能权限；拿不到就报错，不猜）：
#   osascript -e 'tell application "System Events" to tell (first process whose unix id is PID) to get name of every window'
window_title_of() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1) to get name of window 1" 2>/dev/null
}

nav_failed=0
gate_blocked=0
measured=0

# 只读快照：把 db-activity.sh 的 key=value 装进 `<前缀><key>`。
# 走逐行 read + `eval "var=\"\$v\""` 而不是 `eval "$out"`：**值里带空格也不会被分裂**
# （路径带空格是迟早会踩的，装置自己不产出假样本是底线）。取不到的量原样是 `na`。
snapshot_db() {   # $1 = 前缀（a0_ / a1_）
  local out rc k v
  out=$(bash "$ROOT/Tools/UIProbe/db-activity.sh" --db "$MEASURE_DB" --prefix "$1" 2>/dev/null)
  rc=$?
  while IFS='=' read -r k v; do
    case "$k" in
      "${1}"db_*|"${1}"tick_cadence_s) eval "${k}=\"\$v\"" ;;
    esac
  done <<EOF
$out
EOF
  return $rc
}
delta_of() {      # $1 = 表名 ⇒ a1 − a0；任一侧取不到（na）就返回 na，绝不"当作没活动"
  local a b
  a=$(eval "printf '%s' \"\${a0_db_$1:-na}\"")
  b=$(eval "printf '%s' \"\${a1_db_$1:-na}\"")
  case "$a$b" in
    *na*) printf 'na' ;;
    *) printf '%s' "$(awk -v x="$a" -v y="$b" 'BEGIN{printf "%d", y-x}')" ;;
  esac
}
load1_now() { printf '%s' "$(sysctl -n vm.loadavg 2>/dev/null | tr '{}' ' ' | awk '{print $1}')"; }

# 实例卫生（需求方 2026-09-23 直接指令）：每个测量单元跑完立刻收自己那颗，
# 等它真没了再进下一个单元——绝不留到"收尾统一清理"（车道被硬中断时走不到那一步）。
stop_instance() {   # $1 = pid
  kill "$1" 2>/dev/null
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "$1" 2>/dev/null
  sleep 1
  return 0
}

for sec in $SECTIONS; do
  # ── ① 静默前置闸：**开窗之前**判，不满足就不起实例（上一轮是跑完 26 窗才说"不作判定"）
  #    整场开头已经判过一次，这里是**每行再判一次**——机器是共享的，
  #    一条并行车道在第三页开始编译，前两页的读数就不该和后面几页混在一张表里。
  if ! quiet_gate_wait "开 $sec 页之前" "${GATE_TRIES_ROW:-2}"; then
    gate_blocked=$((gate_blocked + 1))
    unmeasured_row "$sec" "静默闸未过·未开这一行(原因=${GATE_REASON})" \
      fail "${GATE_MODE:-real}" "${GATE_AGENT_MATCHES:-}" "${GATE_LOAD1:-na}"
    continue
  fi
  if [ "${GATE_MODE:-real}" = "injected" ] && [ "${RIG_ALLOW_INJECTED:-0}" != "1" ]; then
    unmeasured_row "$sec" "闸读数被注入(RIG_ALLOW_INJECTED 未设⇒此行不作数)" \
      fail injected "${GATE_AGENT_MATCHES:-}" "${GATE_LOAD1:-na}"
    gate_blocked=$((gate_blocked + 1))
    continue
  fi
  GATE_LOAD_BEFORE="$GATE_LOAD1"

  want=$(board_title "$sec")
  AIOBSERVATORY_SECTION="$sec" "$EXE" > "$ROOT/tmp/pagesweep-$sec.log" 2>&1 &
  P=$!
  echo "$P" > "$ROOT/tmp/pagesweep-$sec.pid"          # 只记自己起的 pid，绝不按名字杀
  sleep 5
  if ! kill -0 "$P" 2>/dev/null; then
    unmeasured_row "$sec" "启动失败" pass "$GATE_MODE" "${GATE_AGENT_MATCHES:-}" "$GATE_LOAD_BEFORE"
    continue
  fi
  # 落页核验放在取数之前：一轮 180 s，测错页面不只是白等，而是产出一条**看起来正常**的假数据。
  got=""
  for _ in 1 2 3; do
    got=$(window_title_of "$P")
    [ -n "$got" ] && break
    sleep 2
  done
  # `want` 是该板块**允许出现的标题集合**（中文一行、英文一行），逐行整串比对。
  # 用 grep -Fxq 而不是 `[ "$got" = "$want" ]`：后者在双语后必然把英文实例判成落错页。
  # -F 当字面量（标题里有「/」和空格）、-x 整行、-q 只要成立与否。
  if [ -z "$got" ] || ! printf '%s\n' "$want" | grep -Fxq -- "$got"; then
    unmeasured_row "$sec" "未落到指定板块(读到='${got:-<空>}')·本轮作废" \
      pass "$GATE_MODE" "${GATE_AGENT_MATCHES:-}" "$GATE_LOAD_BEFORE"
    nav_failed=1
    stop_instance "$P"
    continue
  fi
  LOAD_BEFORE=$(sysctl -n vm.loadavg | tr -d '{} ')
  sleep "$SETTLE"
  t0=$(ps -o time= -p "$P" | tr -d ' ')
  wall0=$(date +%s)
  snapshot_db a0_          # ② 窗口起点：活动量快照（只读，跑不动就是 na，不当 0）
  # ④ 第 1 路：`sample` 叶子按族分堆（引擎族 vs UI 族）。**在窗口之内**采一段，
  #    这样它描述的就是这一窗；`FAMILY_SAMPLE_SECONDS=0` 可整个关掉（关掉时列里是 na，不是 0）。
  FAM_FILE="$ROOT/tmp/family-$sec.txt"; : > "$FAM_FILE"; FAM_BG=""
  if [ "${FAMILY_SAMPLE_SECONDS:-10}" != "0" ]; then
    bash Tools/UIProbe/family-sample.sh --pid "$P" --seconds "${FAMILY_SAMPLE_SECONDS:-10}" \
      --outdir "$ROOT/tmp/family-sample" > "$FAM_FILE" 2>/dev/null &
    FAM_BG=$!
  fi
  vals=""
  peak=""
  for _ in $(seq 1 "$SAMPLES"); do
    sleep "$INTERVAL"
    line=$(footprint -p "$P" 2>/dev/null | grep -E "^ +phys_footprint(_peak)?:")
    # ⚠️ 值在 $2：`    phys_footprint: 236 MB` 的 $3 是单位。取错列会静默产出空值。
    v=$(printf '%s' "$line" | awk '/phys_footprint:/{gsub(/[^0-9.]/,"",$2);print $2}')
    peak=$(printf '%s' "$line" | awk '/phys_footprint_peak:/{gsub(/[^0-9.]/,"",$2);print $2}')
    vals="$vals ${v:-0}"
  done
  t1=$(ps -o time= -p "$P" | tr -d ' ')
  wall1=$(date +%s)
  snapshot_db a1_
  # ④ 收第 1 路（族分堆）。等它跑完再收尾：不等就是拿半份文件当读数。
  [ -n "$FAM_BG" ] && wait "$FAM_BG" 2>/dev/null
  famv() { awk -F= -v k="$1" '$1==k{print $2}' "$FAM_FILE" 2>/dev/null; }
  ENG=$(famv engine_leaf_n); UI=$(famv ui_leaf_n); OTH=$(famv other_leaf_n); SOK=$(famv sample_ok)
  [ -n "$ENG" ] || ENG=na; [ -n "$UI" ] || UI=na; [ -n "$OTH" ] || OTH=na; [ -n "$SOK" ] || SOK=na
  # ④ 第 2 路：**默认关**。`turn-trace.sh` 走 `xctrace --attach`，实测会把目标冻住再放开、
  #    墙钟 3–15×、20 s 包体 571 MB–1.7 GB，而且它文件头自己写着"禁入帧判据窗口"。
  #    ⇒ 放在 Δcpu 已经取完（t1 之后）**且实例还活着**的时候跑：它描述"同一页刚测完时的
  #      单次 turn 墙钟"，不参与这一窗的分母。开法 `TURN_TRACE=1`（正式静默窗里再开）。
  TURN_P50=na; TURN_HANG=na; TURN_INS="off(默认关：attach 会污染被测窗)"
  if [ "${TURN_TRACE:-0}" = "1" ]; then
    TURN_FILE="$ROOT/tmp/turn-$sec.txt"
    bash Tools/UIProbe/turn-trace.sh --pid "$P" --seconds "${TURN_SECONDS:-20}" \
      --outdir "$ROOT/tmp/frames" > "$TURN_FILE" 2>/dev/null
    tv() { awk -F= -v k="$1" '$1==k{print $2}' "$TURN_FILE" 2>/dev/null; }
    TURN_P50=$(tv turn_p50_ms); TURN_HANG=$(tv turn_gt_100ms_n); TURN_INS=$(tv turn_instrument)
    [ -n "$TURN_P50" ] || TURN_P50=na; [ -n "$TURN_HANG" ] || TURN_HANG=na
    [ -n "$TURN_INS" ] || TURN_INS="解析不出"
  fi
  LOAD_AFTER=$(sysctl -n vm.loadavg | tr -d '{} ')
  maxv=$(printf '%s\n' $vals | sort -g | tail -1)
  lastv=$(printf '%s\n' $vals | tail -1)
  sec0=$(printf '%s' "$t0" | awk -F: '{printf "%.2f", ($1*60+$2)}')
  sec1=$(printf '%s' "$t1" | awk -F: '{printf "%.2f", ($1*60+$2)}')
  dt=$(echo "$sec0 $sec1" | awk '{d=$2-$1; if (d<0) d=0; printf "%.2f", d}')
  # ⚠️ `cpu_pct` 的分母**仍然是标称 WINDOW**，不是 `measured_wall_s`。这不是遗漏：
  #    footprint 探针会让被采进程停顿 ⇒ 实测墙钟总比标称长一点 ⇒ 换成实测分母会**系统性把 CPU%
  #    读小**，而 3% 判据是棘轮——装置不许用"换个更松的分母"的方式给自己让路（AGENTS §6 禁止的
  #    达标路径）。两列都在表里，配对报告要哪个自己挑，但**判据④ 的达标口径只认标称**（与上一轮逐字同尺）。
  pct=$(echo "$dt $WINDOW" | awk '{printf "%.2f", $1/$2*100}')

  # ③ ms/tick：**实测节奏优先**。名义 3 s 只在 system_perf 取不到时用，且当场写明。
  CAD="${a1_tick_cadence_s:-na}"
  if [ "$CAD" = "na" ] || [ -z "$CAD" ]; then
    CAD="$NOMINAL_TICK_SECONDS"; CAD_SRC="nominal(实测节奏取不到)"
  else
    CAD_SRC="measured"
  fi
  MMS=$(printf '%s %s %s' "$dt" "$wall1" "$wall0" | awk -v c="$CAD" '{w=$3-$2; if (w<=0) w='"$WINDOW"'; printf "%.1f", ($1*1000)/(w/c)}')

  ev=$(delta_of events); cm=$(delta_of commands); fc=$(delta_of file_changes)
  rk=$(delta_of risk_events); pss=$(delta_of perf_samples)

  row_reset
  row_set section "$sec"; row_set window_title "$got"; row_set arm "${ARM:-}"; row_set round "${ROUND:-}"
  row_set footprint_max_MB "$maxv"; row_set footprint_last_MB "$lastv"; row_set footprint_peak_MB "$peak"
  row_set samples "$SAMPLES"; row_set window_s "$WINDOW"; row_set cpu_pct "$pct"; row_set cputime_delta_s "$dt"
  row_set t0_epoch "$wall0"; row_set t1_epoch "$wall1"; row_set measured_wall_s "$((wall1 - wall0))"
  row_set load_before "$LOAD_BEFORE"; row_set load_after "$LOAD_AFTER"
  row_set load1_before "$GATE_LOAD_BEFORE"; row_set load1_after "$(load1_now)"
  row_set ms_per_tick "$MMS"; row_set tick_cadence_s "$CAD"; row_set cadence_source "$CAD_SRC"
  row_set events_delta "$ev"; row_set commands_delta "$cm"; row_set file_changes_delta "$fc"
  row_set risk_events_delta "$rk"; row_set perf_samples_delta "$pss"; row_set events_total_last "${a1_db_events:-na}"
  row_set engine_leaf_n "$ENG"; row_set ui_leaf_n "$UI"; row_set other_leaf_n "$OTH"; row_set sample_ok "$SOK"
  row_set turn_p50_ms "$TURN_P50"; row_set turn_gt_100ms_n "$TURN_HANG"; row_set turn_instrument "$TURN_INS"
  row_set gate "pass"; row_set gate_mode "$GATE_MODE"; row_set gate_agents "${GATE_AGENT_MATCHES:-}"
  emit_row
  measured=$((measured + 1))
  stop_instance "$P"
done

# 收尾：只杀自己记下的 pid 文件里的那个进程（多车道共用同一个二进制名）。
LEFT=$(pgrep -f "$APP/Contents/MacOS" | wc -l | tr -d ' ')
echo "残留（按本树路径查）：$LEFT" >&2
echo "本车道遗留实例数 = $LEFT" >&2
[ "$LEFT" != "0" ] && echo "⚠️  还有本树起的实例没退——按 §实例卫生，这轮不算收口。" >&2
echo "闸拦下的行数 = $gate_blocked / 计划 $(echo "$SECTIONS" | wc -w | tr -d ' ')；实际测量行数 = $measured" >&2

if [ "$measured" -eq 0 ] && [ "$gate_blocked" -gt 0 ]; then
  echo "⛔ 一行都没开：静默前置闸全程未过 ⇒ **不作判定**（既不是达标也不是超标）。" >&2
  echo "   判据④ 要出结论，需要一台真静默的机器（load_1m < ${LOAD_CEILING} 且被观测 Agent 不在跑）。" >&2
  exit 4
fi

if [ "$gate_blocked" -gt 0 ]; then
  echo "⚠️  有 $gate_blocked 行被静默闸在开窗前拦下（CSV 里 gate=fail）⇒ 那些页**没有**读数，" >&2
  echo "   配对驱动器必须把涉及它们的对**整对丢掉**（两臂同规则，不许只丢一臂）。" >&2
fi

if [ "$nav_failed" -ne 0 ]; then
  echo "⚠️  至少一行的窗口标题不等于该板块的 boardTitle ⇒ 那几行是作废数据，不要拿去下结论。" >&2
  exit 3
fi
exit 0
