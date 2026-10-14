#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/frame-baseline.sh — 逐页帧基线的驱动（WS-Frames A2）
#
#  Owner: WS-Frames（子车道 A2）。开发/验收工具，不进产品 target。
#  产出：向 `Tools/UIProbe/frame-baseline.tsv` 追加**一行一个页面**的实测基线，
#        列契约见同目录 `frame-baseline.schema.md`（38 列，顺序固定）。
#
#  一条命令跑完的完整链路（每页一次）：
#    新建观测目录（fresh 空目录 / seeded = cp -R 播种副本）
#    → 起 release 包（显式 AIOBSERVATORY_DATA_DIR + AIOBSERVATORY_SECTION）
#    → 静置（首帧 / 订阅 / 首轮采样跑完，不把启动成本算进判据窗）
#    → 同一个窗口里：frame-window（呈现帧）+ frame-pacer（vsync 分母）+ turn-trace（主线程 turn）
#      同时下发 200 次滚轮 click 事件 + 逐页切换（侧栏点击，按 pid 定向）
#    → 收尾只 kill 自己起的 pid，按 38 列追加一行。
#
#  口径（照抄 measure-idle.sh 的三条纪律，都是踩过的坑）：
#   1. CPU **只能**按「累计 CPU 时间差 / 墙钟差」算；`ps -o %cpu` 是衰减平均，不许当判据。
#   2. `ps -o time=` 只到百分秒 ⇒ 窗口默认 45 s，并把 Δcputime 原始秒数打进 notes 供复算。
#   3. 观测目录**每次新建、绝不复用**：攒着历史行的目录会把聚合与渲染成本算进读数。
#      所以 seeded 口径用的是「播种目录的一份新副本」，而不是原地复用。
#   4. 被观测进程必须是**自己起的** pid（多条车道共用同一个二进制名，绝不 pkill）。
#   5. 判据窗口内不跑 sample/heap/leaks/vmmap/spindump（会 attach 或停线程，污染读数）。
#   6. vsync 每行重测（ProMotion 会降频，上一行的周期不能当这一行的分母）。
#
#  用法：
#    Tools/UIProbe/frame-baseline.sh --pages dashboard,files --mode seeded --append
#    Tools/UIProbe/frame-baseline.sh                          # 9 页 × seeded，dry-run 只打印
#    Tools/UIProbe/frame-baseline.sh --mode fresh --append    # 9 页 × 空目录（绝对判据口径）
#    Tools/UIProbe/frame-baseline.sh --seed tmp/frames/seed-20260920-172357 --scrolls 200
#
#  退出码：0 全部跑完；2 缺 release 包 / 目录 / 参数错；3 某页进程起不来或窗口内消失。
# ============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

TSV="Tools/UIProbe/frame-baseline.tsv"
BIN="$ROOT/dist/AIObservatory.app/Contents/MacOS/AIObservatory"
COMMIT_ENV="${COMMIT:-}"
PROBE="$ROOT/tmp/uiprobe"
WORK="$ROOT/tmp/frames"

PAGES_ALL="dashboard sessions timeline commands files performance security projects settings"
PAGES="$PAGES_ALL"
MODE="seeded"                 # seeded | fresh
SEED=""                       # 播种目录（mode=seeded 必填）
SCROLLS=200                   # F2 要求 200 次滚轮 click 事件
WINDOW=60                     # 判据窗口秒数（要铺得下 200 次滚轮 + 8 轮切页 + 每批抬窗自检；schema 下限 20 s）
SETTLE=18                     # 静置秒数（首帧/订阅/首轮采样跑完再开窗）
BATCHES=8                     # 滚轮分批发，保证铺满整个窗口
APPEND=0
TURN="auto"                 # auto=先探一次再定 | on=每页都同窗跑 | off=不跑(turn_* 记 n/a)
TOOL_WAIT="${TOOL_WAIT:-360}" # 仪器未就绪时最多等这么多秒

while [ $# -gt 0 ]; do
  case "$1" in
    --pages)    PAGES=$(echo "$2" | tr ',' ' '); shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --seed)     SEED="$2"; shift 2 ;;
    --scrolls)  SCROLLS="$2"; shift 2 ;;
    --window)   WINDOW="$2"; shift 2 ;;
    --settle)   SETTLE="$2"; shift 2 ;;
    --append)   APPEND=1; shift ;;
    --turn)     TURN="$2"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

[ -x "$BIN" ] || { echo "❌ 找不到 release 包：$BIN（先跑 Packaging/make-app.sh）" >&2; exit 2; }
[ -f "$TSV" ] || { echo "❌ 缺列契约数据文件 $TSV" >&2; exit 2; }
[ "$MODE" = seeded ] || [ "$MODE" = fresh ] || { echo "❌ --mode 只能 seeded|fresh" >&2; exit 2; }
mkdir -p "$WORK" "$PROBE"

# ── 单实例锁 ────────────────────────────────────────────────────────────────
# 本脚本会 activate + 挪窗口 + 按全局坐标发滚轮，**两个并发驱动会把彼此的读数全部作废**：
# 2026-09-20 实测过一起事故——A2 在子代理轮次上限处中止，它起的驱动变成 PPID=1 的孤儿
# 继续跑了 9 分钟，与我后起的驱动同时抢焦点，产出的 presented_n / hitch_n 形状完全正常
# （非零、看起来可信），只有去查 `ps -o ppid` 才发现是两台驱动在互踩。
# 形状正常恰恰是最危险的地方：这类污染不会让任何一列变成 n/a。
LOCK="$WORK/.frame-baseline.lock"
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null || echo 0)" 2>/dev/null; then
  echo "❌ 已有 frame-baseline.sh 在跑（pid $(cat "$LOCK")）⇒ 拒绝起第二个。" >&2
  echo "   要先清场：kill 那个 pid，再删 $LOCK（它是 $WORK 下的锁，不是仓库文件）。" >&2
  exit 5
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# ── 被测二进制的源码提交（不是脚本的）──────────────────────────────────────
if [ -n "$COMMIT_ENV" ]; then COMMIT="$COMMIT_ENV"; else
  COMMIT="$(grep -m1 '^commit' dist/build-info.txt 2>/dev/null | cut -d= -f2 | tr -d ' ')"
fi
# dist/build-info.txt 里没有 commit 字段（只有 sha256），所以按主会话给的口径写死：
# 该包源码 = main 7473697；已核对 `shasum -a 256` 与 build-info 的 sha256 exe 一致，
# 且 `git diff 7473697..HEAD -- Sources Tests Package.swift` 为空 ⇒ 产品代码同一份。
[ -n "$COMMIT" ] || COMMIT="7473697"
BUILD="release"

# ── 侧栏几何（2026-09-20 真机标定）─────────────────────────────────────────
# 行中心记成**离窗口顶部的点(pt)偏移**而不是窗口高度比例：侧栏是固定行高的 List，
# 改窗口高度时行的 pt 偏移不变（1280x820 与 1080x772 两种尺寸下同一套数都验过），
# 比例反而会在改尺寸后偏掉。点击时再按当前窗口高度换算成 fx/fy。
ROW_Y="dashboard:135 sessions:176 timeline:245 commands:285 files:325 performance:397 security:437 projects:510 settings:551"
SIDEBAR_X_PT=110        # 侧栏行的水平落点（胶囊横跨 12…162 pt）
CONTENT_X_PT=300        # 滚轮落点：内容区里、且 x < 486 ⇒ 落在别的车道默认窗口矩形之外
CONTENT_FY=0.55
WIN_W_PT=1280; WIN_H_PT=820     # 起不来时的兜底值；实际每轮从截图尺寸反读
WIN_X=20; WIN_Y=60; WIN_W=1080; WIN_H=772   # 每轮把窗口挪到这里（见 run_page 里的理由）

row_y_pt() { local r; for r in $ROW_Y; do [ "${r%%:*}" = "$1" ] && { echo "${r##*:}"; return; }; done; echo 135; }
fy_of() { python3 -c "print(f'{$(row_y_pt "$1")/$WIN_H_PT:.4f}')"; }
# 当前窗口边界（frame-window 的 stderr 会打 "1080x772@20,60"）；只读一次 1 s，不进判据窗
win_bounds() { "$PROBE/frame-window" --pid "$1" --seconds 1 2>&1 | grep -o '[0-9]*x[0-9]*@[0-9-]*,[0-9-]*' | head -1; }
# 从截图重读窗口点尺寸（PNG 是 Retina 2x）并刷新换算分母：点击打的是**全局屏幕坐标**，
# 窗口被别的车道挪走/改高时，用启动时缓存的分母会把行打偏（实测点 files 打到 commands）
refresh_geom() {  # $1=pid
  [ -x "$PROBE/capture" ] || return 0
  "$PROBE/capture" --pid "$1" --out "$WORK/geom-$1.png" >/dev/null 2>&1 || return 0
  local wpx hpx; wpx=""; hpx=""
  wpx="$(png_size "$WORK/geom-$1.png" 0)"; hpx="$(png_size "$WORK/geom-$1.png" 1)"
  case "${wpx}${hpx}" in *[^0-9]*|"") return 0 ;; esac
  # 窗口最小 1080x772 pt ⇒ 2x 截图不可能小于 800 px；小于就当读坏了，不刷分母
  if [ "$wpx" -lt 800 ] || [ "$hpx" -lt 600 ]; then GEOM_REJECT="${wpx}x${hpx}px"; return 0; fi
  WIN_W_PT=$((wpx/2)); WIN_H_PT=$((hpx/2))
}
fx_of() { python3 -c "print(f'{$1/$WIN_W_PT:.4f}')"; }

# ── 仪器：缺二进制就从 Tools/UIProbe 现成探针单文件编译；源码也没就轮询等待 ──
# 绝不 swift build（.build 有锁，全车道共享机器）。
ensure_tool() {  # $1=产物名 $2=源码名(swift|sh)
  local out="$1" src="$2" waited=0
  while :; do
    if [ -x "$PROBE/$out" ]; then return 0; fi
    if [ -f "Tools/UIProbe/$src" ]; then
      case "$src" in
        *.swift) xcrun swiftc -O "Tools/UIProbe/$src" -o "$PROBE/$out" 2>"$WORK/cc-$out.log" \
                   && { [ -x "$PROBE/$out" ] && return 0; } ;;
        *.sh)    ln -sf "$ROOT/Tools/UIProbe/$src" "$PROBE/$out" 2>/dev/null && return 0 ;;
      esac
    fi
    [ "$waited" -ge "$TOOL_WAIT" ] && return 1
    sleep 20; waited=$((waited + 20))
  done
}

have_pacer=0;   ensure_tool frame-pacer frame-pacer.swift   && have_pacer=1
have_window=0;  ensure_tool frame-window frame-window.swift && have_window=1
have_foot=0;    ensure_tool probe-footprint probe-footprint.swift && have_foot=1
have_turn=0;    ensure_tool turn-trace turn-trace.sh        && have_turn=1
echo "仪器就绪：frame-pacer=$have_pacer frame-window=$have_window probe-footprint=$have_foot turn-trace=$have_turn" >&2

# turn-trace 的 xctrace 起停是分钟级开销，且它一坏就把每一页的判据窗都拖长 ⇒ 只探一次：
# 起一个自己的临时实例、跑 12 s、看它是否真给出 turn_instrument；不行就整轮关掉并在 notes 里写原因。
probe_turn() {
  local d tp out rc
  d="$WORK/probe-turn-$(date +%H%M%S)"; mkdir -p "$d"
  AIOBSERVATORY_DATA_DIR="$ROOT/$d" AIOBSERVATORY_SECTION=dashboard nohup "$BIN" > "$d/app.log" 2>&1 &
  tp=$!; echo "$tp" > "$WORK/pid-probe-turn.txt"; sleep 12
  out="$WORK/probe-turn.out"
  "$PROBE/turn-trace" --pid "$tp" --seconds 12 > "$out" 2>"$WORK/probe-turn.err"; rc=$?
  kill "$tp" 2>/dev/null; sleep 1.5; kill -9 "$tp" 2>/dev/null
  [ "$(keyval "$out" turn_instrument)" = "none" ] && return 1
  [ -z "$(keyval "$out" turn_instrument)" ] && return 1
  return 0
}
if [ "$have_turn" = 1 ] && [ "$TURN" != on ]; then
  if probe_turn; then echo "turn-trace 探测：可用" >&2
  else echo "turn-trace 探测：不可用（turn_instrument=none），本轮 turn_*/hang_events_n 记 n/a" >&2; have_turn=0; TURN_NOTE="turn-trace 探测失败(xctrace 解析器 rc=1)，turn_*/hang_events_n 记 n/a"; fi
fi

load1() { uptime | sed 's/.*load averages*://;s/^ *//' | awk '{print $1}'; }
sf_n()  { pgrep -x 'swift-frontend' 2>/dev/null | wc -l | tr -d ' '; }
foreign_instances() {  # 同名二进制的**别人**的实例数（不能杀，只能记账）
  ps -eo pid,command 2>/dev/null | awk -v me="$1" '$1 != me && tolower($0) ~ /aiobservatory/ {n++} END {print n+0}'
}
keyval() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]'; }

# ── 落点自检：当前选中的是哪一行侧栏 ────────────────────────────────────────
# 为什么不用窗口标题：真机实测只有 3 个板块把 boardTitle 写进了标题栏，
# 其余 6 个板块标题恒为「AiX」（ShellModel.boardTitle 的 ?? "AiX" 分支），拿它当判据会误判。
# 这里用「选中行的蓝色胶囊」：把每行所在的横条压成 1x1 取平均色，B−R 明显偏大的那行就是选中行。
# 与浅色/深色外观无关（两种外观下选中色都是蓝）。只在判据窗口**外**跑（screencapture 不进窗）。
png_size() { python3 -c "import struct,sys;d=open(sys.argv[1],'rb').read(33);print(struct.unpack('>II',d[16:24])[$2])" "$1" "$2"; }
avg_color() {  # $1=png $2=offsetY $3=offsetH $4=offsetX $5=width  → "R G B"
  local tmp="$WORK/_band-$$.png"
  sips -c "$3" "$5" --cropOffset "$2" "$4" "$1" --out "$tmp" >/dev/null 2>&1 || { echo "n/a"; return; }
  sips --resampleHeightWidth 1 1 "$tmp" --out "$tmp" >/dev/null 2>&1 || { echo "n/a"; return; }
  python3 - "$tmp" <<'PY'
import sys, struct, zlib
try:
    d = open(sys.argv[1], 'rb').read()
    i, idat, ct = 8, b'', None
    while i < len(d):
        ln = struct.unpack('>I', d[i:i+4])[0]; typ = d[i+4:i+8]; body = d[i+8:i+8+ln]
        if typ == b'IHDR': ct = struct.unpack('>IIBB', body[:10])[3]
        elif typ == b'IDAT': idat += body
        i += 12 + ln
    raw = zlib.decompress(idat)
    n = 3 if ct == 2 else 4
    px = list(raw[1:1+n])
    print(px[0], px[1], px[2])
except Exception:
    print('n/a n/a n/a')
PY
}
fy_of_all() { echo "$ROW_Y"; }

# 侧栏选中胶囊在**窗口不是 key** 时是灰的（macOS 原生行为）。这条恰好是最好用的**落点证明**：
# 截图里出现蓝胶囊 ⇒ 我的窗口是 key ⇒ 刚才那一下点击/滚轮确实打在我窗口上。
# 为什么要专门抬窗口：多条车道跑同一个 bundle id（com.aix.aiobservatory），
# 系统按 bundle id 存窗口 frame ⇒ 大家的实例都开在同一个坐标上，叠得严丝合缝；
# 而 `screencapture -l<windowid>` 只合成我自己那个窗口，被压在下面也看不出来。
# 抬窗用 pid 定向的 AXRaise（不按键、不 cliclick、不碰别人的 pid）。
raise_own() {  # $1=pid → 0 抬成功
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1) to set frontmost to true" \
            -e "tell application \"System Events\" to tell (first process whose unix id is $1) to perform action \"AXRaise\" of window 1" \
            >/dev/null 2>&1
}
# 我的窗口前面有没有压着别的同名窗口（owner 打包运行时是 CFBundleName=AiX，swift run 时是 AIObservatory）
occluded_by_twin() {  # $1=pid → 打印压在我前面的同名窗口数
  "$PROBE/capture" --list 2>/dev/null | awk -F'\t' -v p="$1" '
    $1 == p { mine = NR; next }
    mine == "" && ($2 ~ /AiX|AIObservatory/) { n++ }
    END { print n + 0 }'
}
# 抬窗 + 遮挡自检，最多三次；返回非 0 = 这一批的点击可能被别人的窗口接走（如实记进 notes）
assert_front() {  # $1=pid
  local t
  for t in 1 2 3; do
    raise_own "$1"; sleep 0.5
    [ "$(occluded_by_twin "$1")" = "0" ] && return 0
  done
  return 1
}
activate_own() {
  assert_front "$1"; sleep 0.4
}

detect_selected_page() {  # $1=pid → 打印选中页名，或 unknown
  # 两路信号，缺一不可：
  #   ① 蓝胶囊（窗口是 key 时才有）：B−R 明显偏大；
  #   ② 灰胶囊（窗口不是 key 时选中行只是变灰，实测 files 行 204/204/204 vs 其余 229~231）：
  #      取「与 9 行中位数差得最远」的那一行。
  # 只有 ① 会把「窗口没拿到焦点」误判成「页面不对」——真机上就是这么翻过一次车的。
  local pid="$1" img best="" bestscore=-999 r name ypt offy rgb sums=""
  img="$WORK/detect-$pid.png"
  activate_own "$pid"
  "$PROBE/capture" --pid "$pid" --out "$img" >/dev/null 2>&1 || { echo "unknown"; return; }
  [ -f "$img" ] || { echo "unknown"; return; }
  for r in $(fy_of_all); do
    name="${r%%:*}"; ypt="${r##*:}"
    offy=$(( ypt * 2 - 22 ))          # PNG 是 Retina 2x ⇒ 点偏移 ×2
    rgb="$(avg_color "$img" "$offy" 44 40 300)"
    case "$rgb" in *n/a*|"") continue ;; esac
    sums="$sums ${name}:$(echo "$rgb" | tr " " ":")"
  done
  [ -n "$sums" ] || { echo "unknown"; return; }
  python3 - "$sums" <<'PY'
import sys, statistics
rows = []
for tok in sys.argv[1].split():
    parts = tok.split(':')
    if len(parts) != 4:
        continue
    rows.append((parts[0], int(parts[1]), int(parts[2]), int(parts[3])))
if not rows:
    print('unknown'); sys.exit(0)
blue = [(n, bl - rr) for (n, rr, gg, bl) in rows if (bl - rr) > 40]
if blue:
    print('%s key' % max(blue, key=lambda t: t[1])[0]); sys.exit(0)
tot = [rr + gg + bl for (n, rr, gg, bl) in rows]
med = statistics.median(tot)
dev, name = max((abs(t - med), rows[i][0]) for i, t in enumerate(tot))
print(('%s grey' % name) if dev >= 12 else 'unknown')
PY
}

switch_probe() {  # $1=pid $2=target page → 验证「点侧栏能换页」这条通道本跑可用
  local pid="$1" target="$2" other detected_a detected_b
  local other_name
  other_name="sessions"; [ "$target" = sessions ] && other_name="settings"
  "$PROBE/click" --pid "$pid" --fx "$(fx_of $SIDEBAR_X_PT)" --fy "$(fy_of "$other_name")" >/dev/null 2>&1; sleep 1.2
  detected_a="$(detect_selected_page "$pid")"   # 期望 = other_name（含再次激活，不影响选中）
  "$PROBE/click" --pid "$pid" --fx "$(fx_of $SIDEBAR_X_PT)" --fy "$(fy_of "$target")" >/dev/null 2>&1; sleep 1.2
  detected_b="$(detect_selected_page "$pid")"   # 期望 = target
  echo "${other_name}>${detected_a},${target}>${detected_b}"
}

# ── 一页一轮 ────────────────────────────────────────────────────────────────
run_page() {
  local page="$1"
  local ts run_id dir pid instrument_timeout=0
  GEOM_REJECT=""
  ts="$(date +%Y%m%d-%H%M%S)"
  run_id="${ts}-$(echo "$page" | cut -c1-4)-1"
  dir="$WORK/data-$page-$ts"
  rm -rf "$dir"; mkdir -p "$dir"

  local seed_events=0
  if [ "$MODE" = seeded ]; then
    [ -d "$SEED" ] || { echo "❌ seeded 模式需要 --seed 目录，给的是 '$SEED'" >&2; return 3; }
    cp -R "$SEED"/. "$dir"/ 2>/dev/null
    rm -f "$dir/app.log"
    seed_events="$(sqlite3 -readonly "$dir/observatory.sqlite" 'select count(*) from events;' 2>/dev/null | tr -d '[:space:]')"
    [ -n "$seed_events" ] || seed_events="n/a"
  fi

  echo "── [$page] 观测目录（新建）${dir#$ROOT/}  mode=$MODE seed_events=$seed_events" >&2

  AIOBSERVATORY_DATA_DIR="$ROOT/$dir" AIOBSERVATORY_SECTION="$page" \
    nohup "$BIN" > "$dir/app.log" 2>&1 &
  pid=$!
  echo "$pid" > "$WORK/pid-$page.txt"
  sleep 1.5
  kill -0 "$pid" 2>/dev/null || { echo "❌ [$page] 进程起不来，见 $dir/app.log" >&2; return 3; }

  sleep "$SETTLE"
  kill -0 "$pid" 2>/dev/null || { echo "❌ [$page] 静置后进程消失（崩了？）" >&2; return 3; }

  # 每轮先把窗口挪到 (20,60) 并固定尺寸。理由：click/scroll 打的是**全局屏幕坐标**
  # （同机多条车道跑同一个二进制，别人的实例默认开在 (486,102) 1280x820），
  # 窗口叠在一起时点击会被最上面那个接走，而 `capture -l<id>` 只合成我自己的窗口 ⇒ 看不出来。
  # 挪开之后侧栏落点 x≈110pt、滚轮落点 x≈300pt 都在 486pt 之外，没有别人的窗口压在上面。
  local geom_note="默认几何(挪窗不可用)"
  if [ -x "$PROBE/resize" ]; then
    if "$PROBE/resize" --pid "$pid" --width "$WIN_W" --height "$WIN_H" --x "$WIN_X" --y "$WIN_Y" >/dev/null 2>&1; then
      sleep 1; geom_note="${WIN_W}x${WIN_H}@${WIN_X},${WIN_Y}"
    else
      geom_note="挪窗失败(沿用默认几何)"
    fi
  fi
  refresh_geom "$pid"                     # 真实窗口尺寸：点 = PNG 像素 ÷ 2（Retina 2x）
  local geom_before="n/a" geom_after="n/a" wins_before wins_after
  [ "$have_window" = 1 ] && geom_before="$(win_bounds "$pid")"
  wins_before="$("$PROBE/capture" --list 2>/dev/null | awk -F'\t' -v p="$pid" '$1==p' | wc -l | tr -d ' ')"

  # 落点自检（窗口**外**做，screencapture 不进判据窗）：
  #   ① env 真的把界面开在请求的页；② 「点侧栏换页」这条通道本轮可用。
  local page_check="n/a" detected switch_probe="n/a"
  if [ -x "$PROBE/capture" ] && [ -x "$PROBE/click" ]; then
    detected="$(detect_selected_page "$pid")"
    [ "${detected%% *}" = "unknown" ] && { raise_own "$pid"; sleep 1; detected="$(detect_selected_page "$pid")"; }
    [ "$detected" = "$page key" ] && page_check="match(key)"
    [ "${detected%% *}" = "$page" ] && [ "$page_check" != "match(key)" ] && page_check="match(grey)"
    [ "${detected%% *}" != "$page" ] && page_check="differs:$detected"
    switch_probe="$(switch_probe "$pid" "$page")"
  fi

  local l0 fp0 ct0 t0 sfmax=0
  l0="$(load1)"; ct0="$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ')"
  t0="$(python3 -c 'import time;print(f"{time.time():.4f}")')"
  fp0="n/a"
  if [ "$have_foot" = 1 ]; then
    "$PROBE/probe-footprint" --pid "$pid" > "$WORK/foot0-$page.txt" 2>/dev/null
    fp0="$(keyval "$WORK/foot0-$page.txt" phys_footprint_mb)"; [ -n "$fp0" ] || fp0="n/a"
  fi
  sfmax="$(sf_n)"

  # ── 判据窗口：仪器 + 交互同窗起、同窗止 ──────────────────────────────────
  # 仪器 pid 单独记，收尾只等这三个；被测实例是长命子进程，裸 `wait` 会挂死。
  local w0 win_start_epoch fw_pid="" fp_pid="" tt_pid=""
  w0="$(python3 -c 'import time;print(f"{time.time():.3f}")')"
  win_start_epoch="$(date +%s)"
  if [ "$have_window" = 1 ]; then
    "$PROBE/frame-window" --pid "$pid" --seconds "$WINDOW" > "$WORK/fw-$page.out" 2>"$WORK/fw-$page.err" &
    fw_pid=$!
  fi
  if [ "$have_pacer" = 1 ]; then
    "$PROBE/frame-pacer" --seconds "$WINDOW" > "$WORK/fp-$page.out" 2>"$WORK/fp-$page.err" &
    fp_pid=$!
  fi
  if [ "$have_turn" = 1 ]; then
    "$PROBE/turn-trace" --pid "$pid" --seconds "$WINDOW" > "$WORK/tt-$page.out" 2>"$WORK/tt-$page.err" &
    tt_pid=$!
  fi

  local per target_fy b other other_fy switches=0 raised=0 pace=0 occluded=0
  local SB_FX SC_FX
  refresh_geom "$pid"                     # 分母必须是**此刻**的窗口尺寸，不是启动时缓存的
  SB_FX="$(fx_of $SIDEBAR_X_PT)"; SC_FX="$(fx_of $CONTENT_X_PT)"
  raise_own "$pid" && raised=1
  per=$(( SCROLLS / BATCHES )); [ "$per" -lt 1 ] && per=1
  target_fy="$(fy_of "$page")"
  # 一批的耗时估算 = 滚轮 per×90ms + 抬窗 + 两次切页；剩下的时间按批平分当配速间隔
  pace="$(python3 -c "
batch=$per*0.09+4.0
print(f'{max(0.0,(0.92*$WINDOW-$BATCHES*batch)/$BATCHES):.2f}')")"
  b=0
  while [ "$b" -lt "$BATCHES" ]; do
    assert_front "$pid" || occluded=$(( occluded + 1 ))
    if [ -x "$PROBE/scroll" ]; then
      "$PROBE/scroll" --pid "$pid" --ticks -6 --clicks "$per" --fx "$SC_FX" --fy "$CONTENT_FY" >> "$WORK/acts-$page.log" 2>&1
    fi
    # 逐页切换：切到别的页再切回来（滚轮/点击全部按 pid 定向，不会打到别的窗口）
    other="$(echo "$PAGES_ALL" | awk -v i=$(( (b % 9) + 1 )) '{print $i}')"
    [ "$other" = "$page" ] && other="settings"
    other_fy="$(fy_of "$other")"
    if [ -x "$PROBE/click" ]; then
      "$PROBE/click" --pid "$pid" --fx "$SB_FX" --fy "$other_fy" >> "$WORK/acts-$page.log" 2>&1
      sleep 0.5
      "$PROBE/click" --pid "$pid" --fx "$SB_FX" --fy "$target_fy" >> "$WORK/acts-$page.log" 2>&1
      switches=$((switches + 1))
    fi
    local s; s="$(sf_n)"; [ "$s" -gt "$sfmax" ] 2>/dev/null && sfmax="$s"
    b=$((b + 1))
    # 配速：让最后一批落在窗口 92% 处，尾部只留几秒静止（否则尾部那一段间隔会被算进 p99/max）
    if [ "$b" -lt "$BATCHES" ] && [ "$pace" != "0" ]; then sleep "$pace"; fi
  done
  local scrolled=$(( per * BATCHES )) interact_s
  interact_s=$(( $(date +%s) - win_start_epoch ))

  # 等仪器跑完。注意坑：`kill -0` 对**已退未回收的僵尸**返回成功，用它轮询会把窗口一路拖到
  # deadline 之后（实测 30 s 窗被拖成 42 s）⇒ 先按绝对截止睡到位，再用 ps 的 stat 判活、wait 回收。
  local deadline j alive st
  deadline=$(( win_start_epoch + WINDOW + (have_turn == 1 ? 150 : 8) ))   # 绝对截止：从窗口起跑算，不是从交互跑完算
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive=0
    for j in "$fw_pid" "$fp_pid" "$tt_pid"; do
      [ -n "$j" ] || continue
      st="$(ps -p "$j" -o stat= 2>/dev/null)"
      [ -n "$st" ] && case "$st" in *Z*) ;; *) alive=1 ;; esac
    done
    [ "$alive" = 0 ] && break
    sleep 0.5
  done
  for j in "$fw_pid" "$fp_pid" "$tt_pid"; do
    [ -n "$j" ] || continue
    if ps -p "$j" -o stat= 2>/dev/null | grep -qv '^Z'; then
      kill "$j" 2>/dev/null; instrument_timeout=1
    fi
    wait "$j" 2>/dev/null
  done

  local w1 win_actual
  w1="$(python3 -c 'import time;print(f"{time.time():.3f}")')"
  # window_s 记**实测**窗口（仪器起跑 → 三把仪器都收工），不是请求值
  win_actual="$(python3 -c "print(f'{max(1,round(float($w1)-float($w0)))}')" 2>/dev/null || echo "$WINDOW")"

  local l1 ct1 t1 fp1 cpu_pct
  l1="$(load1)"; ct1="$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ')"
  t1="$(python3 -c 'import time;print(f"{time.time():.4f}")')"
  fp1="n/a"
  if [ "$have_foot" = 1 ]; then
    "$PROBE/probe-footprint" --pid "$pid" > "$WORK/foot1-$page.txt" 2>/dev/null
    fp1="$(keyval "$WORK/foot1-$page.txt" phys_footprint_mb)"; [ -n "$fp1" ] || fp1="n/a"
  fi
  [ -n "$fp1" ] || fp1="n/a"
  local s; s="$(sf_n)"; [ "$s" -gt "$sfmax" ] 2>/dev/null && sfmax="$s"

  cpu_pct="n/a"
  if [ -n "$ct1" ]; then
    cpu_pct="$(python3 - "$ct0" "$ct1" "$t0" "$t1" <<'PY'
import sys
def secs(x):
    p=[float(i) for i in x.split(":")]
    return sum(v*60**(len(p)-1-i) for i,v in enumerate(p))
c0,c1,t0,t1=sys.argv[1:5]
d=secs(c1)-secs(c0); w=float(t1)-float(t0)
print(f"{d/w*100:.2f}" if w>0 else "n/a")
PY
)"
  else
    echo "⚠️  [$page] 窗口结束时进程已消失，cpu_pct 记 n/a" >&2
  fi

  # 窗口**后**复验：交互的最后一步是点回目标页，此刻蓝胶囊还在目标行 ⇒ 这一窗的点击通道是活的
  local post_check="n/a"
  [ "$have_window" = 1 ] && geom_after="$(win_bounds "$pid")"
  wins_after="$("$PROBE/capture" --list 2>/dev/null | awk -F'\t' -v p="$pid" '$1==p' | wc -l | tr -d ' ')"
  if [ -x "$PROBE/capture" ]; then
    detected="$(detect_selected_page "$pid")"
    [ "${detected%% *}" = "$page" ] && post_check="match(${detected##* })" || post_check="differs:$detected"
  fi

  kill "$pid" 2>/dev/null; sleep 1.5; kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  # ── 读数汇总 ─────────────────────────────────────────────────────────────
  local vsync_ms="n/a" vsync_inst="" fw_presented="n/a" hitch="n/a" hitch2="n/a"
  local p50="n/a" p95="n/a" p99="n/a" pmax="n/a" cap_perm="n/a" pacer_note=""
  if [ "$have_pacer" = 1 ] && [ -s "$WORK/fp-$page.out" ]; then
    vsync_ms="$(grep '^vsync_p50_ms=' "$WORK/fp-$page.out" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
    vsync_inst="$(grep '^instrument=' "$WORK/fp-$page.out" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
    pacer_note="vsync_alt=$(grep '^vsync_p50_ms=' "$WORK/fp-$page.out" | tail -1 | cut -d= -f2 | tr -d ' ')"
  fi
  if [ "$have_window" = 1 ] && [ -s "$WORK/fw-$page.out" ]; then
    fw_presented="$(keyval "$WORK/fw-$page.out" presented_n)"
    p50="$(keyval "$WORK/fw-$page.out" presented_p50_ms)"
    p95="$(keyval "$WORK/fw-$page.out" presented_p95_ms)"
    p99="$(keyval "$WORK/fw-$page.out" presented_p99_ms)"
    pmax="$(keyval "$WORK/fw-$page.out" presented_max_ms)"
    hitch="$(keyval "$WORK/fw-$page.out" hitch_n)"
    hitch2="$(keyval "$WORK/fw-$page.out" hitch_gt2_n)"
    cap_perm="$(keyval "$WORK/fw-$page.out" capture_permission)"
  fi
  local turn_n="n/a" tp50="n/a" tp95="n/a" tp99="n/a" tmax="n/a" t100="n/a" hang="n/a" turn_note=""
  if [ "$have_turn" = 1 ] && [ -s "$WORK/tt-$page.out" ]; then
    turn_n="$(keyval "$WORK/tt-$page.out" turn_n)"
    tp50="$(keyval "$WORK/tt-$page.out" turn_p50_ms)"
    tp95="$(keyval "$WORK/tt-$page.out" turn_p95_ms)"
    tp99="$(keyval "$WORK/tt-$page.out" turn_p99_ms)"
    tmax="$(keyval "$WORK/tt-$page.out" turn_max_ms)"
    t100="$(keyval "$WORK/tt-$page.out" turn_gt_100ms_n)"
    hang="$(keyval "$WORK/tt-$page.out" hang_events_n)"
    turn_note="turn_instrument=$(keyval "$WORK/tt-$page.out" turn_instrument)"
  fi

  local frames_expected="n/a"
  if [ "$vsync_ms" != "n/a" ] && [ -n "$vsync_ms" ]; then
    frames_expected="$(python3 -c "print(int($win_actual / float('$vsync_ms') * 1000))")"
  fi
  local fp_delta="n/a"
  if [ "$fp0" != "n/a" ] && [ "$fp1" != "n/a" ]; then
    fp_delta="$(python3 -c "print(f'{float($fp1)-float($fp0):+.2f}')")"
  fi

  local instruments=""
  [ "$have_pacer" = 1 ] && instruments="cvdisplaylink"
  [ "$have_window" = 1 ] && instruments="${instruments:+$instruments+}screencapturekit"
  # turn 那把用仪器自己报的名字（schema 只认 xctrace / spindump 两个 token）
  local turn_token="xctrace"
  case "$(keyval "$WORK/tt-$page.out" turn_instrument 2>/dev/null)" in
    *spindump*) turn_token="spindump" ;;
    *xctrace*)  turn_token="xctrace" ;;
  esac
  [ "$have_turn" = 1 ] && instruments="${instruments:+$instruments+}$turn_token"
  [ "$have_foot" = 1 ] && instruments="${instruments:+$instruments+}taskinfo"
  [ -n "$instruments" ] || instruments="none"
  local n_inst
  n_inst=$(python3 -c "print(len('$instruments'.split('+')))")

  # basis：绝对判据 only when 两端 load < 15（本机 15 核）**且** 观测目录是新建空目录
  #（schema §一.6：攒着历史行的目录会把聚合与渲染成本算进读数，seeded 只能当相对对照）。
  local basis="relative"
  if [ "$MODE" = fresh ] \
     && python3 -c "import sys; sys.exit(0 if float('$l0')<15 and float('$l1')<15 else 1)"; then
    basis="absolute"
  fi

  # 样本支撑：合成器只在内容变化时出帧，帧数不足时百分位与 hitch 都没有样本支撑，
  # 拿 0 帧的窗口去给 F2 打「pass」就是「把没测到写成不存在」。
  local frame_support="yes"
  python3 -c "
import sys
try: sys.exit(0 if int('$fw_presented') >= 100 else 1)
except Exception: sys.exit(1)" || frame_support="no"

  local f1="n/a" f2="n/a" f3="n/a" f4="n/a"
  if [ "$basis" = "absolute" ] && [ "$n_inst" -ge 2 ] && [ "$frame_support" = "yes" ]; then
    f1="$(python3 -c "
try:
  print('pass' if float('$p95')<=float('$vsync_ms')*1.05 else 'fail')
except Exception: print('n/a')")"
    f2="$(python3 -c "
try: print('pass' if int('$hitch')==0 else 'fail')
except Exception: print('n/a')")"
    f3="$(python3 -c "
try: print('pass' if float('$pmax')<=16.7 else 'fail')
except Exception: print('n/a')")"
    f4="$(python3 -c "
try: print('pass' if int('$t100')==0 and int('$hang')==0 else 'fail')
except Exception: print('n/a')")"
  fi

  local notes=""
  [ -n "${TURN_NOTE:-}" ] && notes="$notes ${TURN_NOTE};"
  [ "$have_pacer" = 0 ] && notes="$notes 仪器未就绪:frame-pacer(vsync_* 记 n/a);"
  [ "$have_window" = 0 ] && notes="$notes 仪器未就绪:frame-window(presented_*/hitch_* 记 n/a);"
  [ "$have_foot" = 0 ] && notes="$notes 仪器未就绪:probe-footprint(footprint 记 n/a);"
  [ "$have_turn" = 0 ] && notes="$notes 仪器未就绪:turn-trace(turn_*/hang_events_n 记 n/a);"
  notes="$notes window=${win_actual}s(请求${WINDOW}s) 交互=${interact_s}s settle=${SETTLE}s scrolls=${scrolled}(${BATCHES}x${per}) switches=${switches}x2 侧栏点击(按 pid) geom=${geom_note} win=${WIN_W_PT}x${WIN_H_PT}pt geom_reject=${GEOM_REJECT:-none} bounds=${geom_before}>${geom_after} wins=${wins_before}>${wins_after} page_check=${page_check} switch_probe=${switch_probe} post_check=${post_check} raise=${raised} occluded_batches=${occluded}/8 cap_perm=${cap_perm} ${pacer_note} ${turn_note}"
  [ "$frame_support" = "no" ] && notes="$notes 呈现帧<100⇒百分位/hitch 无样本支撑(f*_verdict 记 n/a)"
  [ "$basis" = "relative" ] && [ "$MODE" = seeded ] && notes="$notes seeded 口径按 schema 一.6 只能相对对照"
  [ "$basis" = "relative" ] && [ "$MODE" = fresh ] && notes="$notes 两端 load 未同时 <15⇒只能相对对照"
  [ "$instrument_timeout" = 1 ] && notes="$notes 有仪器超过窗口收尾限未收工(已只杀自己起的仪器)"
  python3 -c "import sys; sys.exit(0 if float('$win_actual')>=20 else 1)" || notes="$notes 窗口短于 schema 下限 20s"
  [ -n "$ct1" ] && notes="$notes cputime=${ct0}->${ct1}"
  local foreign
  foreign="$(foreign_instances "$pid")"
  [ "$foreign" != "0" ] && notes="$notes 同名二进制他车道实例≈${foreign}个(不可杀)"
  notes="$(printf '%s' "$notes" | tr '\t\n' '  ' | sed 's/^ *//')"

  local row
  row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$run_id" "$page" "$page" "$COMMIT" "$BUILD" "$MODE" "$seed_events" "combined" "$win_actual" \
    "$vsync_ms" "$frames_expected" "$fw_presented" "$hitch" "$hitch2" \
    "$p50" "$p95" "$p99" "$pmax" "$tp50" "$tp95" "$tp99" "$tmax" "$t100" "$hang" \
    "$fp0" "$fp1" "$fp_delta" "$cpu_pct" "$l0" "$l1" "$sfmax" \
    "$instruments" "$basis" "$f1" "$f2" "$f3" "$f4" "$notes")"

  if [ "$APPEND" = 1 ]; then
    printf '%s\n' "$row" >> "$TSV"
  fi
  echo "run_id=$run_id"
  echo "status=ok"
  echo "$row" > "$WORK/row-$page-$ts.tsv"
  echo "── [$page] 行已生成（append=$APPEND）：$run_id" >&2
}

if [ "$MODE" = seeded ] && [ -z "$SEED" ]; then
  SEED="$(cat "$WORK/seed-dir.txt" 2>/dev/null)"
fi

for p in $PAGES; do
  run_page "$p" || { echo "run_id=-"; echo "status=failed"; echo "❌ $p 这一页没跑成" >&2; }
done
