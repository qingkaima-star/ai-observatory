#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/turn-trace.sh — 仪器三：进程外取「主线程单次 turn」与「hang」
#
#  Owner: WS-Frames（取证轮工具，不进产品 target；产物落 tmp/frames/，gitignore）
#  命令行契约：Tools/UIProbe/frames-tools.contract.md 的 `turn-trace` 行（钉死，勿改）。
#  stdout 只打 key=value；人读的解释与报错一律走 stderr。
#
#  ─────────────────────────────────────────────────────────────────────────
#  三档仪器的实测可用性（本机 macOS 26.5.2 / xctrace 16.0，全部本次自己跑出来的）
#   (a) `xcrun xctrace record --template 'Animation Hitches' --attach PID --time-limit Ns --no-prompt`
#       —— **可用**，非 root、无 Developer Mode 也能录（`xcrun devinit status` 报 disabled 不影响）。
#          实测 rc=0 两次：20 s 窗口 → 571 MB / 1.7 GB 包、墙钟 79 s / 294 s（3–15× 目标窗口）。
#   (b) 同命令换 `--template 'System Trace'` —— 作为降档保留（本脚本 (a) 失败时自动试一次）。
#   (c) `spindump` —— 本机 `spindump requires root privileges`，`sudo -n` 试探需要密码 ⇒ 不可用。
#       留这一段是给后来人看口径的：**读 spindump 必须连 Note 一起读**。
#       `CPU Time: 1.064s / Duration: 120s` 看着像 0.88% 很省，但同段的
#       `Note: process was unresponsive for 119 seconds before sampling` 才是真相
#       —— 主线程约 91% 忙且挂起。只看 CPU 百分比会把「挂死」读成「很闲」。
#
#  ─────────────────────────────────────────────────────────────────────────
#  列口径（这一版修掉了两处**静默假阴性**，改动理由写在行内）：
#   * `turn_*` = **主线程 CFRunLoop `individual_iteration` 的 START→END 配对**（墙钟毫秒）。
#     这是真正「单次 turn」的口径。正对照实测：给一个干净窗口注入 12 次 120 ms 主线程 sleep，
#     `turn_gt_100ms_n=12`、`turn_p50_ms=16.665`（= 60Hz 心跳），一条不多一条不少。
#   * `hang_events_n` = **`potential-hangs` 表行数**（Apple 自己的挂起判定，表头 hangs-threshold=33ms）。
#     ⚠️ 上一版取的是 `hang-risks`：实测在有 13 条真挂起的那一窗里 `hang-risks` 是 **0 行**，
#     照它下结论会把「有 hang」读成「零 hang = F4 达标」。`hang_risks_n` 仍作为附加列打出来。
#   * `frame_lifetime_*` / `hitches_n` = 合成器口径（每帧寿命、Apple 记的 hitch 事件），
#     是 turn 的**上界代理**：帧寿命 > 100 ms ⇒ 那一拍确实超了；≤ 100 ms **不能**反推
#     主线程没超（一帧可能由多个 turn 拼成）。方向不对称，所以只有「超限」可用它判。
#   * ⚠️ `xctrace --attach` 会把目标冻住再放开 ⇒ 录制开头会出现一条仪器自己造的 hang
#     （实测第一条 12472 ms）。所以另打 `hang_earliest_start_ms` 与 `hang_events_ex_first5s_n`，
#     让人一眼分清「App 挂了」还是「仪器挂上去那一下」。
#
#  ⚠️ 本工具会 attach 目标进程（有侵入、会拖慢被观测方）⇒ **只许在取证轮跑，禁入帧判据窗口**。
#     判据窗内只允许 frame-pacer / frame-window / probe-footprint 三件。
#
#  用法:
#    Tools/UIProbe/turn-trace.sh --pid 1234 --seconds 20
#    Tools/UIProbe/turn-trace.sh --pid 1234 --seconds 20 --keep-trace      # 留住那个 1.7 GB 的包
#    Tools/UIProbe/turn-trace.sh --reuse tmp/frames/turn-1234-xxx.trace     # 只重解析，不再录
#    Tools/UIProbe/turn-trace.sh --pid 1234 --seconds 20 --template 'System Trace'
#  退出码: 0 采到并解析; 2 参数错; 3 三档全不可用; 4 有包但解析失败
# ============================================================================
set -u

PID=""
SECONDS_=20
KEEP=0
REUSE=""
OUT_DIR=""
TEMPLATE="Animation Hitches"
EARLY_MS=5000      # attach 造成的冻结窗口（ms）：这段时间里的 hang 先算仪器自己的账
MAX_TRACE_MB=2500  # 包体积预算：超过就中途停录（同机实测有 30 s → 20 GB 的包，不拦会写满宿主盘）

while [ $# -gt 0 ]; do
  case "$1" in
    --pid)        PID="${2:-}"; shift 2 ;;
    --seconds)    SECONDS_="${2:-20}"; shift 2 ;;
    --template)   TEMPLATE="${2:-}"; shift 2 ;;
    --outdir)     OUT_DIR="${2:-}"; shift 2 ;;
    --reuse)      REUSE="${2:-}"; shift 2 ;;
    --max-trace-mb) MAX_TRACE_MB="${2:-2500}"; shift 2 ;;
    --keep-trace) KEEP=1; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -n "$OUT_DIR" ] || OUT_DIR="$ROOT/tmp/frames"
mkdir -p "$OUT_DIR"

emit_na() {
  printf 'turn_n=n/a\nturn_p50_ms=n/a\nturn_p95_ms=n/a\nturn_p99_ms=n/a\nturn_max_ms=n/a\n'
  printf 'turn_gt_100ms_n=n/a\nhang_events_n=n/a\n'
  printf 'turn_instrument=none\n'
  printf 'turn_note=%s\n' "$1"
}

TRACE=""
REC_LOG=""
WALL_NOTE="未录制（--reuse）"
KPERF_BUSY=0
record_with_inner() {   # $1 = 模板名；成功时把包路径写进全局 TRACE 并 return 0
  local tpl="$1" stamp safe log
  stamp="$(date +%Y%m%d-%H%M%S)"
  safe="$(printf '%s' "$tpl" | tr ' ' '-')"
  TRACE="$OUT_DIR/turn-${PID}-${safe}-${stamp}.trace"
  REC_LOG="$OUT_DIR/turn-${PID}-${safe}-${stamp}.record.log"
  echo "  == xcrun xctrace record --template '$tpl' --attach $PID --time-limit ${SECONDS_}s --no-prompt ==" >&2
  local t0 t1 rc wall watchdog
  t0=$(date +%s)
  # 默认让 xctrace 自己收尾（--time-limit），不要从外面 kill——会留半成品包。
  # 但**磁盘安全优先于读数完整**：包长超过 --max-trace-mb 时中途停掉，
  # 并把这一档判为失败（同机实测有 30 s → 20 GB 的包，不按预算拦会把宿主盘写满）。
  xcrun xctrace record --template "$tpl" --attach "$PID" \
    --time-limit "${SECONDS_}s" --output "$TRACE" --no-prompt --quiet >"$REC_LOG" 2>&1 &
  local xpid=$!
  watchdog=0
  while kill -0 "$xpid" 2>/dev/null; do
    sleep 1   # 1 s 一轮：实测包最快可到 ≈600 MB/s（8 s 的包冲到 4.8 GB），3 s 一轮会超写 ~2 GB
    local sz_kb; sz_kb=$(du -sk "$TRACE" 2>/dev/null | awk '{print $1}')
    if [ "${sz_kb:-0}" -gt "$(( MAX_TRACE_MB * 1024 ))" ]; then
      echo "  ⛔ 包已达 ${sz_kb}KB > 预算 ${MAX_TRACE_MB}MB ⇒ 中途停录（磁盘安全优先于读数完整）" >&2
      kill -TERM "$xpid" 2>/dev/null; watchdog=1; break
    fi
  done
  wait "$xpid" 2>/dev/null; rc=$?
  t1=$(date +%s); wall=$(( t1 - t0 ))
  echo "  rc=$rc 墙钟 ${wall}s（录 ${SECONDS_}s ⇒ ≈$(( wall / (SECONDS_ > 0 ? SECONDS_ : 1) ))× 目标窗口，会压满 CPU）" >&2
  if [ "$watchdog" -eq 1 ]; then   # 超预算中止：不重试（重试只会再吃一份预算）
    echo "  ❌ 因超预算中止（不是模板不可用）；目标进程可能被拖得太慢，考虑缩窗口或换 --template" >&2
    rm -rf "$TRACE" "$REC_LOG"; TRACE=""
    return 1
  fi
  if [ $rc -eq 0 ] && [ -d "$TRACE" ]; then
    TEMPLATE="$tpl"
    WALL_NOTE="record ${SECONDS_}s 用了 ${wall}s 墙钟"
    echo "  ✅ 录到 $(basename "$TRACE")（$(du -sh "$TRACE" 2>/dev/null | awk '{print $1}')）" >&2
    return 0
  fi
  echo "  ❌ 模板 '$tpl' 无头录制失败，原样报错：" >&2
  head -20 "$REC_LOG" >&2
  # 本机实测的**互斥**：同一时刻全机只允许一个 kperf 会话，别的车道在录时这条一定失败，
  # 原样报错是 `Failed to start the recording: _lockKPerf: could not lock kperf. Likely another session just started.`
  # ⇒ 这不是「仪器不可用」，是「资源被占」。等 25 s 再试一次，仍占着就把 KPERF_BUSY 报给上层。
  if grep -q "could not lock kperf" "$REC_LOG" 2>/dev/null; then
    KPERF_BUSY=1
    echo "  ↻ 检测到 kperf 被别的 xctrace 会话占着 ⇒ 等 25 s 重试一次（全机同一时刻只能有一个 trace 会话）" >&2
    rm -rf "$TRACE" "$REC_LOG"; sleep 25
    record_with_inner "$tpl" && return 0
  fi
  rm -rf "$TRACE" "$REC_LOG"; TRACE=""
  return 1
}

record_with() {   # 外层：内层可能已因 kperf 重试过一次
  record_with_inner "$1"
}

if [ -n "$REUSE" ]; then
  [ -d "$REUSE" ] || { echo "--reuse 的 .trace 不存在：$REUSE" >&2; exit 2; }
  TRACE="$REUSE"
else
  [ -n "$PID" ] || { echo "必须给 --pid P（turn-trace 既不启动也不 kill 目标）" >&2; exit 2; }
  case "$SECONDS_" in ''|*[!0-9]*) echo "--seconds 必须是整数" >&2; exit 2 ;; esac
  kill -0 "$PID" 2>/dev/null || { echo "pid $PID 不存在（别拿它继续量）" >&2; exit 2; }
  echo "  机器状态 before: load=$(uptime | sed 's/.*load averages*://;s/^ *//') swift-frontend=$(pgrep -f swift-frontend | wc -l | tr -d ' ')" >&2

  # .trace 实测 ≈ 85 MB/s（20 s → 571 MB ~ 1.7 GB）⇒ 先量磁盘，别把宿主写满。
  # 上限取「实测最坏 700 MB/s」与「--max-trace-mb 预算」的较小者 + 2 GB 余量。
  # 为什么按 700 MB/s：本机实测包速**跨三个数量级**——同一个模板同一个目标：
  #   20 s → 571 MB / 1.1 GB / 1.7 GB；8 s → 4.8 GB（≈600 MB/s，被 --max-trace-mb 拦下）；
  #   同机另一条车道 30 s → 20 GB。低负载时 ≈30–85 MB/s，负载高时暴涨。
  # ⇒ 只按平均值估会在中途把宿主盘写满，必须「预估值取上界 + 运行中按预算拦」两道。
  avail_kb=$(df -kP "$OUT_DIR" | awk 'NR==2 {print $4}')
  need_kb=$(( 700 * 1024 * SECONDS_ ))
  [ "$need_kb" -gt "$(( MAX_TRACE_MB * 1024 ))" ] && need_kb=$(( MAX_TRACE_MB * 1024 ))
  need_kb=$(( need_kb + 2 * 1048576 ))
  if [ "${avail_kb:-0}" -lt "$need_kb" ]; then
    echo "  磁盘可用 ${avail_kb}KB < 预估 ${need_kb}KB" >&2
    emit_na "disk-space-guard: 拒绝录制（$(df -h "$OUT_DIR" | tail -1)）"
    exit 3
  fi

  if ! record_with "$TEMPLATE"; then
    [ "$TEMPLATE" = "System Trace" ] || { echo "  == 降档 (b)：--template 'System Trace' ==" >&2; record_with 'System Trace' || true; }
  fi
fi

if [ -z "$TRACE" ]; then
  echo "  == 两档 xctrace 都没录成 ⇒ 降档 (c) spindump（只允许 sudo -n 非交互试探）==" >&2
  if command -v sudo >/dev/null 2>&1; then
    # ⚠️ 返回码必须单独取：`x=$(cmd | head -3)` 之后 $? 是 head 的 rc（本机第一版就因此把
    # 「a password is required」误判成「有 root」，白跑了一次 spindump）。
    sudo_out=$(sudo -n true 2>&1); sudo_rc=$?
    sudo_probe=$(printf '%s' "$sudo_out" | head -3)
  else
    sudo_rc=127; sudo_probe="sudo 不存在"
  fi
  echo "  sudo -n true rc=$sudo_rc 原样输出: $(printf '%s' "$sudo_probe" | tr '\n' ' ')" >&2
  if [ $sudo_rc -eq 0 ]; then
    spin="$OUT_DIR/spindump-${PID}-$(date +%Y%m%d-%H%M%S).txt"
    sudo -n /usr/sbin/spindump -sample "${PID:-0}" "$SECONDS_" -stdout >"$spin" 2>&1
    echo "  spindump rc=$? → $spin  ⚠️ 下面几行必须连 Note 一起读：" >&2
    grep -m 6 -E "Note:|CPU Time:|Event: hang|Duration:" "$spin" >&2 || true
    emit_na "spindump-only: xctrace (a)(b) 均失败；spindump 给的是采样占比不是逐回合时长，口径不兼容 ⇒ 全列 n/a（原文 $spin）"
    exit 3
  fi
  WHY="xctrace-failed"
  [ "$KPERF_BUSY" -eq 1 ] && WHY="kperf-busy(全机同一时刻只允许一个 xctrace 会话，别的车道在录) + xctrace-failed"
  emit_na "$WHY + spindump-needs-password（sudo -n 原样='$(printf '%s' "$sudo_probe" | tr '\n' ' ')'）; ${WALL_NOTE}"
  exit 3
fi

# —— 导出：每张表单独一个 XML。——
# 只有一个坑：`--xpath` 必须是**完整路径**且属性值用双引号；写成 `--schema X`
# 或 `--xpath '<table schema="X"/>'` 会让 xctrace 抛
# `-[NSXMLElement traceNodeKind]: unrecognized selector` 并留下 0 字节文件（实测过）。
STAMP="$(date +%Y%m%d-%H%M%S)"
XL="$OUT_DIR/turn-parse-$$-$STAMP"
cleanup() {
  rm -f "$XL".*.xml "$XL".*.err 2>/dev/null
  if [ "$KEEP" -eq 0 ] && [ -z "$REUSE" ]; then rm -rf "$TRACE" "$REC_LOG" 2>/dev/null; fi
}
trap cleanup EXIT

export_table() {
  local schema="$1"
  xcrun xctrace export --input "$TRACE" \
    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
    > "$XL.$schema.xml" 2>"$XL.$schema.err"
  if [ ! -s "$XL.$schema.xml" ]; then
    echo "  ❌ 导出 $schema 失败：$(head -2 "$XL.$schema.err" | tr '\n' ' ')" >&2
    : > "$XL.$schema.xml"
  fi
}
for t in runloop-events potential-hangs hitches hitches-frame-lifetimes hang-risks; do export_table "$t"; done

if ! command -v python3 >/dev/null 2>&1; then
  emit_na "no-python3: 包在（$(basename "$TRACE")）但本机没有 python3 解析导出 XML; ${WALL_NOTE}"
  exit 4
fi

python3 - "$XL" "$EARLY_MS" "$TEMPLATE" "$WALL_NOTE" "$(basename "$TRACE")" <<'PY'
import os, re, sys
xl, early_ms, template, wall_note, trace_name = sys.argv[1:6]

def load(schema):
    """返回 (rows, cols)：rows 是 list[list[已解析值]]，值取 fmt= 原文（人读数），
    数字另存 text（纳秒原值）。xctrace 的导出用 id=/ref= 去重，必须建全局 id 表。"""
    ⚠️ 返回 None = **这张表在当前模板里不存在**；返回 [] = 表存在但 0 行。
    这个区分是契约级的：前者只能 n/a，后者才是真零。实测 `System Trace` 模板里
    runloop-events 有数据，而 potential-hangs / hitches / hitches-frame-lifetimes **根本没有**——
    照 0 行处理就会把「量不到 hang」写成「零 hang = F4 达标」。"""
    path = "%s.%s.xml" % (xl, schema)
    if not os.path.exists(path):
        return None
    txt = open(path, encoding="utf-8", errors="replace").read()
    if "<schema " not in txt:
        return None
    idmap = {}
    rows = []
    for body in re.findall(r"<row>(.*?)</row>", txt, re.S):
        cells = []
        for m in re.finditer(r"<([a-z0-9-]+)((?:\s[^>]*?)?)(?:/>|>(.*?)</\1>)", body, re.S):
            tag, attrs, inner = m.group(1), m.group(2) or "", m.group(3) or ""
            cid = re.search(r'\bid="(\d+)"', attrs)
            ref = re.search(r'\bref="(\d+)"', attrs)
            fmt = re.search(r'fmt="([^"]*)"', attrs)
            num = inner.strip()
            if ref:
                cells.append(idmap.get(ref.group(1), {}))
                continue
            val = {"tag": tag, "fmt": fmt.group(1) if fmt else inner.strip(), "num": num}
            if cid:
                idmap[cid.group(1)] = val
            cells.append(val)
        rows.append(cells)
    return rows

def ms_of(cell):
    """时长列：优先用 fmt（'122.60 ms'），退到纳秒原值。
    ⚠️ 上一版用 `<duration units="...">` 正则，实测本机导出**根本没有 units= 属性**
    （形如 <duration id="2" fmt="16.11 ms">16108875</duration>）⇒ 命中 0 行 ⇒ turn_n=0 假阴性。"""
    if not cell:
        return None
    f = cell.get("fmt", "")
    m = re.match(r"([\d.]+)\s*ms$", f)
    if m:
        return float(m.group(1))
    m = re.match(r"^(\d+)$", cell.get("num", ""))
    if m:
        return int(m.group(1)) / 1e6
    m = re.match(r"([\d.]+)\s*s$", f)
    if m:
        return float(m.group(1)) * 1000
    return None

def ns_of(cell):
    if not cell:
        return None
    m = re.match(r"^(\d+)$", cell.get("num", ""))
    return int(m.group(1)) if m else None

def pct(vals, p):
    return None if not vals else vals[max(0, min(len(vals) - 1, int(len(vals) * p)))]

def fmt3(v):
    return "n/a" if v is None else "%.3f" % v

log = lambda s: sys.stderr.write(s + "\n")

# ---------- (1) 主线程单次 turn：CFRunLoop individual_iteration START→END ----------
starts, ends = [], []
missing = set()
rl = load("runloop-events")
if rl is None:
    missing.add("runloop-events")
for cells in (rl or []):
    if len(cells) < 8:
        continue
    if cells[2].get("fmt") != "individual_iteration":
        continue
    if cells[7].get("fmt") != "Yes":            # is-main：只要主线程
        continue
    t = ns_of(cells[0])
    if t is None:
        continue
    (starts if cells[3].get("fmt") == "START" else ends if cells[3].get("fmt") == "END" else []).append(t)
turns = sorted((e - s) / 1e6 for s, e in zip(starts, ends) if e >= s)
log("  主线程 turn=%d（START=%d END=%d 未配对=%d）" % (len(turns), len(starts), len(ends), abs(len(starts) - len(ends))))

out = []
if turns:
    out += ["turn_n=%d" % len(turns),
            "turn_p50_ms=%s" % fmt3(pct(turns, .50)),
            "turn_p95_ms=%s" % fmt3(pct(turns, .95)),
            "turn_p99_ms=%s" % fmt3(pct(turns, .99)),
            "turn_max_ms=%s" % fmt3(turns[-1]),
            "turn_gt_100ms_n=%d" % sum(1 for t in turns if t > 100)]
else:
    out += ["turn_n=n/a", "turn_p50_ms=n/a", "turn_p95_ms=n/a", "turn_p99_ms=n/a",
            "turn_max_ms=n/a", "turn_gt_100ms_n=n/a"]

# ---------- (2) hang：potential-hangs（Apple 判定）----------
hang_ms, hang_types, hang_starts = [], {}, []
hp = load("potential-hangs")
if hp is None:
    missing.add("potential-hangs")
for cells in (hp or []):
    if not cells:
        continue
    hang_starts.append((ns_of(cells[0]) or 0) / 1e6)
    d = ms_of(cells[1]) if len(cells) > 1 else None
    if d is not None:
        hang_ms.append(d)
    ht = cells[2].get("fmt") if len(cells) > 2 else None
    hang_types[ht or "?"] = hang_types.get(ht or "?", 0) + 1
ex_early = sum(1 for s in hang_starts if s > float(early_ms))
log("  potential-hangs=%s 行 %s 最长 %s ms（前 %sms 内 %d 条 = 疑似 attach 冻结）" % (
    "表不存在" if hp is None else len(hang_starts), hang_types,
    fmt3(max(hang_ms) if hang_ms else None), early_ms, len(hang_starts) - ex_early))
if "potential-hangs" in missing:
    out += ["hang_events_n=n/a", "hang_max_ms=n/a", "hang_earliest_start_ms=n/a",
            "hang_events_ex_first_%sms_n=n/a" % int(float(early_ms)), "hang_types=table-missing"]
else:
    out += ["hang_events_n=%d" % len(hang_starts),
            "hang_max_ms=%s" % fmt3(max(hang_ms) if hang_ms else None),
            "hang_earliest_start_ms=%s" % fmt3(min(hang_starts) if hang_starts else None),
            "hang_events_ex_first_%sms_n=%d" % (int(float(early_ms)), ex_early),
            "hang_types=%s" % (";".join("%s:%d" % (k, v) for k, v in sorted(hang_types.items())) or "none")]

# ---------- (3) Apple 自己的 hitch 事件 + 合成器帧寿命（对照列）----------
hr = load("hitches")
if hr is None:
    missing.add("hitches")
hitch_rows = hr or []
hitch_ms = sorted(m for m in (ms_of(r[1]) if len(r) > 1 else None for r in hitch_rows) if m is not None)
lr = load("hitches-frame-lifetimes")
if lr is None:
    missing.add("hitches-frame-lifetimes")
life = sorted(m for m in (ms_of(r[1]) if len(r) > 1 else None for r in (lr or [])) if m is not None)
rr = load("hang-risks")
if rr is None:
    missing.add("hang-risks")
risk = rr or []
log("  hitches=%s 帧寿命=%s hang-risks=%s 缺表=%s" % (
    "表不存在" if hr is None else len(hitch_rows), "表不存在" if lr is None else len(life),
    "表不存在" if rr is None else len(risk), sorted(missing) or "无"))
out += ["hitches_n=%s" % (len(hitch_rows) if hr is not None else "n/a"),
        "hitches_max_ms=%s" % fmt3(hitch_ms[-1] if hitch_ms else None),
        "frame_lifetime_n=%s" % (len(life) if lr is not None else "n/a"),
        "frame_lifetime_p50_ms=%s" % fmt3(pct(life, .50)),
        "frame_lifetime_p95_ms=%s" % fmt3(pct(life, .95)),
        "frame_lifetime_max_ms=%s" % fmt3(life[-1] if life else None),
        "hang_risks_n=%s" % (len(risk) if rr is not None else "n/a"),
        "tables_missing=%s" % (";".join(sorted(missing)) or "none")]

if not turns and not life and not hitch_rows and not hang_starts and rl:
    out.append("turn_note=四张表全空：这一窗目标进程没有任何可归属的 runloop 回合/呈现帧"
               "（无动画、后台无窗口、attach 到非 GUI 进程都会这样）——不构成「没有卡顿」的证据")
else:
    out.append("turn_note=turn=主线程 CFRunLoop individual_iteration 首尾配对（墙钟，非 CPU 采样）; "
               "hang=potential-hangs 行（表头阈值 33ms，**不是** 3s watchdog）; "
               "frame_lifetime/hitches=合成器口径上界代理（>100ms 可判超限，≤100ms 不可判达标）; "
               "attach 前 %dms 内的 hang 先算仪器自己的账; %s; trace=%s" % (int(float(early_ms)), wall_note, trace_name))

seen = set()
for line in out:                      # 同名 key 只打第一次（口径冲突时以先算出来的为准，别打两遍）
    k = line.split("=", 1)[0]
    if k in seen:
        continue
    seen.add(k)
    print(line)
print("turn_instrument=xctrace+%s" % template.replace(" ", "+"))
PY
rc=$?
[ $rc -eq 0 ] || { echo "❌ 解析器 rc=$rc（包留在 $(basename "$TRACE")，可 --reuse 重跑）" >&2; KEEP=1; emit_na "parse-failed rc=$rc trace=$(basename "$TRACE")"; exit 4; }
echo "  机器状态 after : load=$(uptime | sed 's/.*load averages*://;s/^ *//') swift-frontend=$(pgrep -f swift-frontend | wc -l | tr -d ' ')" >&2
exit 0
