#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/measure-idle.sh — 静默基线开销的唯一产出工具
#
#  Owner: WS-Verify（验收证据产出工具，不进产品 target）
#  ─────────────────────────────────────────────────────────
#  为什么要有这个脚本，而不是随手 `ps` 一下：
#  验收标准「空闲 CPU < 3% / 内存 < 200 MB」约束的是**交付给用户的那个包**，
#  所以主口径必须是 `Packaging/make-app.sh` 出来的 release `.app`。
#  debug 构建没有优化、带 Swift 运行时检查、`@Observable` 的变更记录也在跑，
#  拿 debug 数字去判一条对 release 的预算，属于「测试绿但生产不触发」的同类错误
#  （先前 RSS 在 180 与 211 MB 之间反复，就是混了两种构建）。
#
#  口径（三条都是踩过的坑）：
#   1. CPU **只能**按「累计 CPU 时间差 / 墙钟差」算。`ps -o %cpu` 是衰减平均，
#      同一进程能读到 0.0–17.1% 乱跳，用它验收会系统性低估。
#   2. `ps -o time=` 只到百分秒，短窗口下量化误差很大 ⇒ **窗口默认 180 秒**，
#      并把 Δcputime 的原始秒数一起打出来，让人能自己复算。
#   3. 启动后先静置，别把首帧 / 订阅 / 首轮采样算进「空闲」。
#   4. 内存**判据口径是 `phys_footprint`**（F5）。RSS 列只留作对照：本机实测 RSS ≈ 2× footprint
#      （186.6 vs 91 MB），用 RSS 对 200 MB 上限属于双倍高估。
#      取数用 Apple 自带的 `/usr/bin/footprint`，它与车道内 `task_info(TASK_VM_INFO)` 探针
#      互为**独立仪器**；两者不一致时以 footprint 为准并回报差值。
#
#  另外：观测目录每次新建、绝不复用调试用的 `tmp/verify`
#  （那里攒着几千行历史事件，聚合与渲染成本会污染读数）。
#
#  用法：
#    Tools/UIProbe/measure-idle.sh                     # release + debug 各一轮
#    Tools/UIProbe/measure-idle.sh release             # 只跑主口径
#    Tools/UIProbe/measure-idle.sh release 300 sessions # 指定窗口秒数与板块
#  退出码：0 全部测完；2 缺 release 包 / 进程起不来。
# ============================================================================
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

TARGETS="${1:-release debug}"
WINDOW="${2:-180}"
SECTION="${3:-dashboard}"
SETTLE="${SETTLE:-20}"
# 窗口内采样次数。ADR-0009 裁定 4：内存要同时报 max 与 peak，而首末两点既看不见台阶、
# 也看不见采样间隙里的峰值 ⇒ 采样次数必须是显式参数，不能像以前那样"取两点算一条"。
SAMPLES="${SAMPLES:-12}"
BASE_DIR="$ROOT/tmp/baseline"

if [ "$WINDOW" -lt 180 ]; then
  echo "⚠️  窗口 ${WINDOW}s < 180s：ps -o time= 的量化误差在这个量级上足够推翻 <3% 的结论。" >&2
fi

# 静默窗自检：有编译器在跑就不要引用这组绝对值。
# F5 取数：/usr/bin/footprint 报的就是 task 的 phys_footprint（单位随大小在 B/KB/MB/GB 间变）。
# 它只读、不 attach、不停线程，所以允许出现在静默基线脚本里；但**帧判据窗口内仍然不许**跑任何
# 会 attach 目标的仪器（sample/heap/leaks/vmmap）—— 那是另开的取证轮。
footprint_mb() {
  local pid="$1" line value unit
  line="$(footprint -p "$pid" 2>/dev/null | grep -m1 'Footprint:' || true)"
  if [ -z "$line" ]; then printf 'n/a'; return; fi
  value="$(printf '%s' "$line" | sed -E 's/.*Footprint: ([0-9.]+) (B|KB|MB|GB).*/\1/')"
  unit="$(printf '%s' "$line" | sed -E 's/.*Footprint: [0-9.]+ (B|KB|MB|GB).*/\1/')"
  python3 -c "
v = float('$value'); u = '$unit'
scale = {'B': 1.0/1048576, 'KB': 1.0/1024, 'MB': 1.0, 'GB': 1024.0}[u]
print(f'{v * scale:.1f}')" 2>/dev/null || printf 'n/a'
}

# 一次 `footprint -p` 把 phys_footprint 与 phys_footprint_peak **同一刻**读走（两个数，空格分隔）。
# 单位必须显式换算：直接取awk第 2 列会在 MB/GB 交界处错三个数量级（`$3` 是单位不是值）。
# peak 取不到时回落到当前值 —— 不写 0，0 会让"峰值 ≥ 稳态"这条自检假绿。
footprint_pair() {
  local pid="$1" out
  out="$(footprint -p "$pid" 2>/dev/null | python3 -c '
import re, sys
sc = {"B": 1.0 / 1048576, "KB": 1.0 / 1024, "MB": 1.0, "GB": 1024.0}
cur = peak = None
for line in sys.stdin:
    m = re.match(r"\s*phys_footprint(_peak)?:\s*([0-9.]+)\s*([BKMG]?B)", line)
    if not m:
        continue
    v = float(m.group(2)) * sc.get(m.group(3), 1.0)
    if m.group(1):
        peak = v
    else:
        cur = v
if cur is None:
    print("")
else:
    print(f"{cur:.1f} {peak if peak is not None else cur:.1f}")
' 2>/dev/null)"
  printf '%s' "${out:-}"
}

busy_note() {
  local compilers
  compilers="$(pgrep -fl 'swift-frontend|swift-build|xcbuild' 2>/dev/null | grep -v 'measure-idle' | wc -l | tr -d ' ')"
  printf 'load=%s  编译器进程=%s' "$(uptime | sed 's/.*load averages*://;s/^ *//')" "$compilers"
}

measure_one() {
  local label="$1" bin="$2"
  local data="$BASE_DIR/$label-$SECTION-$(date +%H%M%S)"
  mkdir -p "$data"

  echo
  echo "===== [$label] $bin"
  echo "  观测目录（新建，不复用 tmp/verify）: ${data#$ROOT/}"
  echo "  机器状态 before: $(busy_note)"

  AIOBSERVATORY_DATA_DIR="$data" AIOBSERVATORY_SECTION="$SECTION" \
    nohup "$bin" > "$data/app.log" 2>&1 &
  local pid=$!
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "  ❌ 进程起不来，见 $data/app.log" >&2
    return 2
  fi

  sleep "$SETTLE"   # 首帧 / 订阅 / 首轮采样跑完，不把启动成本算进「空闲」

  local ct0 t0 r0 f0
  ct0=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ')
  t0=$(python3 -c 'import time;print(f"{time.time():.4f}")')
  r0=$(ps -o rss= -p "$pid" | tr -d ' ')
  f0=$(footprint_mb "$pid")
  if [ -z "$ct0" ] || [ -z "$r0" ]; then
    echo "  ❌ 静置后进程已消失（崩了？）" >&2
    return 2
  fi

  # 窗口内**逐次采样**，不再"只取首末两点"。两个理由都是踩过坑的：
  #   1) 峰值发生在采样间隙（实测 60 s 内 MALLOC_LARGE 一个 16 MB arena 来去 ⇒ 91→78 MB 的抖动），
  #      两点法既看不见台阶也报不出 peak（ADR-0009 裁定 4 要求同报峰值）；
  #   2) 用末值判 200 MB 会把"中途 210 MB 然后回落"判成达标。
  # 序列写成 TSV 交给下面一次 python 统一算，免得口径分叉在两个地方。
  local interval=$(( WINDOW / SAMPLES )); [ "$interval" -lt 1 ] && interval=1
  local series="$ROOT/tmp/idle-series-$pid.tsv"
  mkdir -p "$ROOT/tmp"
  : > "$series"
  local i ct_i t_i r_i pair fp fpeak
  for (( i = 0; i <= SAMPLES; i++ )); do
    ct_i=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ')
    t_i=$(python3 -c 'import time;print(f"{time.time():.4f}")')
    r_i=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    pair=$(footprint_pair "$pid")
    fp="${pair%% *}"; fpeak="${pair##* }"
    if [ -z "$ct_i" ]; then
      echo "  ⚠️  第 $i 次采样时进程已消失，序列在此截断（样本数 ${i}/${SAMPLES}）" >&2
      break
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(python3 -c "print(f'{$t_i - $t0:.2f}')")" "$ct_i" "${r_i:-0}" "${fp:-}" "${fpeak:-}" >> "$series"
    [ "$i" -lt "$SAMPLES" ] && sleep "$interval"
  done

  local ct1 t1 r1 f1
  ct1=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ')
  t1=$(python3 -c 'import time;print(f"{time.time():.4f}")')
  r1=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
  f1=$(footprint_mb "$pid")

  # 只收自己起的那个 pid —— 多条车道跑同一个二进制名，pkill 会打死别人的实例。
  kill "$pid" 2>/dev/null; sleep 1.5; kill -9 "$pid" 2>/dev/null

  if [ -z "$ct1" ]; then
    echo "  ❌ 窗口结束时进程已消失，无法计算" >&2
    return 2
  fi

  python3 - "$ct0" "$ct1" "$t0" "$t1" "$r0" "$r1" "$f0" "$f1" "$label" "$SECTION" "$WINDOW" "$SETTLE" "$series" "$SAMPLES" <<'PY'
import sys
ct0, ct1, t0, t1, r0, r1, f0, f1, label, section, window, settle, series, samples = sys.argv[1:15]

def secs(x):
    p = [float(i) for i in x.split(":")]
    return sum(v * 60 ** (len(p) - 1 - i) for i, v in enumerate(p))

c0, c1 = secs(ct0), secs(ct1)
d = c1 - c0
w = float(t1) - float(t0)
pct = d / w * 100
print(f"  静置 {settle}s 后开始计时，窗口 {w:.2f}s")
print(f"  cputime  {c0:.2f}s -> {c1:.2f}s   Δ={d:.2f}s   ← 原始秒数，可自行复算")
print(f"  CPU      = Δcputime / Δwall = {d:.2f} / {w:.2f} = {pct:.2f}%")
print(f"  RSS      {int(r0)/1024:.1f} MB -> {int(r1)/1024:.1f} MB  (Δ {(int(r1)-int(r0))/1024:+.1f} MB)")

# F5 / ADR-0009 口径（2026-09-20 起）：内存预算判的是 phys_footprint，不是 ps 的 RSS —— 本机实测
# RSS ≈ 2× footprint，拿 RSS 去对 120/200 MB 是双倍高估。取不到就如实打 n/a，不猜。
def _mb(x):
    x = x.strip()
    return None if x in ("", "n/a") else float(x)

# 六元组：max / last / peak / P95 / argmax / 斜率。以前只有首末两点，等于把
# 「中途冲高再回落」和「一路上台阶」压成同一个数——那正是判据④ 会被糊过去的地方。
pts = []
try:
    with open(series) as fh:
        for line in fh:
            c = line.rstrip("\n").split("\t")
            if len(c) < 5 or not c[3].strip():
                continue
            pts.append((float(c[0]), float(c[3]), float(c[4]) if c[4].strip() else float(c[3])))
except OSError:
    pts = []

m0, m1 = _mb(f0), _mb(f1)
if pts:
    vals = [p[1] for p in pts]
    tmax = max(vals)
    tmax_i = vals.index(tmax)
    last = vals[-1]
    peak = max(p[2] for p in pts)
    srt = sorted(vals)
    p95 = srt[max(0, int(round(0.95 * (len(srt) - 1))))]
    n = len(pts)
    sx = sum(p[0] for p in pts); sy = sum(vals)
    sxx = sum(p[0] * p[0] for p in pts); sxy = sum(p[0] * p[1] for p in pts)
    denom = n * sxx - sx * sx
    slope = (n * sxy - sx * sy) / denom if denom > 1e-9 else 0.0   # MB / 秒
    print(f"  footprint 样本 {n} 点（窗口 {window}s）")
    print(f"    max   {tmax:.1f} MB @ t={pts[tmax_i][0]:.0f}s   ← 稳态上限判这一行")
    print(f"    P95   {p95:.1f} MB      last {last:.1f} MB      斜率 {slope * 60:+.2f} MB/min")
    print(f"    peak  {peak:.1f} MB（footprint 自报，含采样间隙）   ← 只报事实，不据它打勾也不据它判败")
    if abs(peak - tmax) > 1.0:
        print(f"    ⚠️  peak 比 max(样本) 高 {peak - tmax:.1f} MB ⇒ 采样太稀，峰值落在间隙里；判定用 max，但别对外说'峰值就是 {tmax:.0f}'")
    verdict_mb = tmax
    mb_note = f"footprint max {tmax:.1f}{'≤' if verdict_mb < 200 else '>'}200MB（稳态上限口径 = max(样本)；peak {peak:.1f} 另记）"
elif m0 is None or m1 is None:
    print(f"  footprint {f0} -> {f1}   ← F5 口径取不到，本行判据降级为对照")
    mb_note = "内存判据不可判：footprint 取不到"
else:
    print(f"  footprint {m0:.1f} MB -> {m1:.1f} MB  (Δ {m1 - m0:+.1f} MB)   ← 序列为空，退回两点法")
    mb_note = f"footprint {'≤' if m1 < 200 else '>'}200MB（两点法，判据强度低于 max/peak）"
if m1 is not None and pts:
    r1mb = int(r1) / 1024 if r1.strip() else 0
    print(f"  RSS/footprint = {r1mb / pts[-1][1]:.2f}×  （≈2 即说明用 RSS 判预算会双倍高估）")
print(f"  判定     CPU {'≤' if pct < 3 else '>'}3% 上限   |   {mb_note}")
print(f"  对照     首末两点 {f0} -> {f1}；RSS {r1 if r1.strip() else 'n/a'} KB —— 旧口径只作参照，不据它打勾")
PY
  echo "  机器状态 after : $(busy_note)"
}

RELEASE_BIN="$ROOT/dist/AIObservatory.app/Contents/MacOS/AIObservatory"
DEBUG_BIN="$ROOT/.build/debug/AIObservatory"

if [ ! -x "$RELEASE_BIN" ]; then
  echo "❌ 找不到 release 包：$RELEASE_BIN" >&2
  echo "   先跑：Packaging/make-app.sh   （验完再删，不入库）" >&2
  case " $TARGETS " in *" release "*) exit 2 ;; esac
fi

for t in $TARGETS; do
  case "$t" in
    release) measure_one release "$RELEASE_BIN" ;;
    debug)   measure_one debug   "$DEBUG_BIN" ;;
    *) echo "未知目标：$t（可用：release debug）" >&2; exit 2 ;;
  esac
done

echo
echo "说明：判据口径 = release 那一组；debug 只作对照，不能用它给 <3% 打勾。"
echo "     观测目录在 ${BASE_DIR#$ROOT/} 下，含真实路径，看完即删，不入库。"
