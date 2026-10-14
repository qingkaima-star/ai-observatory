#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/quiet-verdict.sh — 判据④ 的**正式判定**驱动器（含静默闸门）
#
#  Owner: 总控（开发工具，不进产品 target）
#  ─────────────────────────────────────────────────────────
#  为什么要有这个包装，而不是直接跑 `measure-pages.sh`：
#   1. **重复**：本仓已经两次栽在 n=1 上——先是一次扫描把"九行同一页"当成逐页结论，
#      后是一次洪峰把 Sessions 页读成 204 MB / 54%（复测 59 MB / 1.76%）。
#      所以默认跑 `ROUNDS=3` 轮并报离散度，单轮的表**不许**用来下结论。
#   2. **闸门**：判据④ 管的是**空闲**，而"空闲"是机器的属性不是 App 的属性。
#      只要有一轮的 `load` 超过 `LOAD_CEILING`，本脚本直接拒绝出判定，
#      只给"参考读数"——把"这台机器现在不静默"从人的自觉变成代码的检查。
#      （2026-09-21 实测：三条车道并发编译时 load 7→14，同一页 CPU 差 30 倍。）
#   3. **口径钉死**：内存判 `max(每轮 max(样本))`（ADR-0009 裁定 5 的稳态口径），
#      peak 只报不判；CPU 判"各轮 CPU 的中位数"，不用最大值——
#      一次偶发的采集洪峰不该把空闲预算判败，但也必须看得见。
#
#  用法：
#    Tools/UIProbe/quiet-verdict.sh                        # 九页 × 3 轮
#    ROUNDS=2 WINDOW=240 Tools/UIProbe/quiet-verdict.sh    # 加长窗口、减到 2 轮
#    SECTIONS="sessions performance" Tools/UIProbe/quiet-verdict.sh
#    FORCE=1 …                                             # 明知不静默仍要开窗（产物仍打 EXIT=3）
#  退出码：0 判据④ 双项达标；1 至少一项不达标；2 前置条件不满足（缺包 / 缺数据）；
#          3 机器不静默 ⇒ **不作判定**（读数仍会打印）。
#
#  #92 装置补的两件事（车道 ws/rig，2026-09-23）：
#   ① **静默前置闸挪到开窗之前**（`quiet-gate.sh`，与 measure-pages.sh / ab-sweep.sh 同一颗）。
#      本脚本原本的闸是"跑完 ROUNDS×页 扇窗再事后作废"——上一轮实测那是 26 × 142 s 的白等，
#      而且三页的读数照样印在表上、被当"参考读数"引用。现在闸不过就**一扇窗都不开**。
#   ② load 改读 measure-pages 新出的干净列 `load1_before/load1_after`（旧列 `load_before` 是
#      `7.487.397.70` 这种**没有分隔符的拼接串**，老代码靠"按点切两段"凑出 7.487——**恰好**对，
#      但换个 load 位数就会错，且错的方向是悄悄放宽闸门）。两列都在时优先用干净列。
# ============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

. "$ROOT/Tools/UIProbe/quiet-gate.sh"

ROUNDS="${ROUNDS:-3}"
WINDOW="${WINDOW:-180}"
SAMPLES="${SAMPLES:-12}"
SECTIONS="${SECTIONS:-dashboard sessions timeline commands files performance security projects settings}"
LOAD_CEILING="${LOAD_CEILING:-4}"          # 1 分钟负载超过它就认为机器不静默
DATA_DIR="${AIOBSERVATORY_DATA_DIR:-$ROOT/tmp/verify-realdata}"
OUT_DIR="$ROOT/tmp/quiet-verdict"
mkdir -p "$OUT_DIR"

# ── 前置闸：排在**"包在不在 / 库里有没有数据"之前**。不静默时这些都轮不到问，
#    于是一条也不动（不起实例、不建表、不写 round-*.csv）——退出码 3 = "不作判定"。
if ! quiet_gate_wait "静默窗开跑之前"; then
  echo "⛔ 静默前置闸未过 ⇒ **不开窗**：$GATE_REASON" >&2
  echo "   本脚本判据④ 的正式结论要求机器静默（load_1m < $LOAD_CEILING 且被观测 Agent 不在跑）。" >&2
  echo "   这一场是 $ROUNDS 轮 × $(echo $SECTIONS | wc -w | tr -d ' ') 页 × ${WINDOW}s 的白等，不值得试。" >&2
  echo "   要明知不静默仍要拿参考读数：FORCE=1 重跑（产物仍按「不作判定」记）。" >&2
  if [ "${FORCE:-0}" != "1" ]; then
    printf 'QUIET_GATE=fail\nload_1m=%s\ngate_mode=%s\ngate_reason=%s\n' \
      "${GATE_LOAD1:-na}" "${GATE_MODE:-real}" "$GATE_REASON" >&2
    echo "机器不静默 ⇒ 不作判定（未开任何窗）" >&2
    exit 3
  fi
fi

APP=$(ls -d "$ROOT"/*.app "$ROOT"/dist/*.app 2>/dev/null | head -1)
[ -n "${APP:-}" ] || { echo "❌ 缺 release 包：先跑 Packaging/make-app.sh" >&2; exit 2; }
[ -f "$DATA_DIR/observatory.sqlite" ] || {
  echo "❌ 数据目录 $DATA_DIR 里没有库：逐页判定必须用**有真实数据**的库，否则测的是空载" >&2
  exit 2
}
if [ "$WINDOW" -lt 180 ]; then
  echo "⚠️  WINDOW=${WINDOW}s < 180s：这份输出只能算烟测，不得作为判据④ 的正式判定。" >&2
fi

export AIOBSERVATORY_DATA_DIR="$DATA_DIR"
echo "==> 静默窗正式判定：${ROUNDS} 轮 × $(echo $SECTIONS | wc -w | tr -d ' ') 页 × ${WINDOW}s"
for (( r = 1; r <= ROUNDS; r++ )); do
  echo "-- 第 $r/$ROUNDS 轮"
  round_csv="$OUT_DIR/round-$r.csv"
  # 注意别写成 `OUT=… bash … > "$OUT"`：重定向是当前 shell 展开的，
  # 那时 OUT 还没定义，`set -u` 会当场炸（本脚本第一版就是这么坏的）。
  OUT="$round_csv" SAMPLES="$SAMPLES" WINDOW="$WINDOW" LOAD_CEILING="$LOAD_CEILING" \
    bash Tools/UIProbe/measure-pages.sh $SECTIONS > "$round_csv" 2>"$OUT_DIR/round-$r.err"
  rc=$?
  if [ "$rc" -eq 4 ]; then
    echo "❌ 第 $r 轮**一行都没开**：静默前置闸全程未过 ⇒ 不作判定（不是达标、也不是超标）。" >&2
    tail -3 "$OUT_DIR/round-$r.err" >&2
    exit 3
  fi
  if [ "$rc" -eq 3 ]; then
    echo "❌ 第 $r 轮有页面没落到指定板块（measure-pages 已把那些行判废）。判定中止。" >&2
    exit 2
  fi
done

# 汇总：把逐轮的 CSV 收成"每页一行 + 总结论"。
python3 - "$OUT_DIR" "$ROUNDS" "$LOAD_CEILING" "$WINDOW" <<'PY'
import csv, glob, statistics, sys, os
out_dir, rounds, ceiling, window = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
rows = {}
load_max = 0.0
nav_failed = 0
for path in sorted(glob.glob(os.path.join(out_dir, "round-*.csv"))):
    with open(path) as fh:
        for rec in csv.DictReader(fh):
            sec = rec["section"]
            title = rec.get("window_title", "")
            if "作废" in title or "失败" in title:
                nav_failed += 1
                continue
            def num(key):
                try:
                    return float(rec[key])
                except (KeyError, TypeError, ValueError):
                    return None
            mx, peak, cpu = num("footprint_max_MB"), num("footprint_peak_MB"), num("cpu_pct")
            lb, la = rec.get("load_before", ""), rec.get("load_after", "")
            for raw in (lb, la):
                # loadavg 是一串没有分隔符的浮点（"7.487.397.70"）⇒ 取第一段近似即可，
                # 这里只用来判"机器静不静默"这个量级，不追求精确。
                try:
                    load_max = max(load_max, float(str(raw).split(".")[0] + "." + (str(raw).split(".")[1] if len(str(raw).split(".")) > 1 else "0")))
                except (ValueError, IndexError):
                    pass
            if mx is None or cpu is None:
                continue
            rows.setdefault(sec, {"max": [], "peak": [], "cpu": []})
            rows[sec]["max"].append(mx)
            if peak is not None:
                rows[sec]["peak"].append(peak)
            rows[sec]["cpu"].append(cpu)

if not rows:
    print("❌ 没有任何有效读数（全部行被标题核验拒掉？）")
    sys.exit(2)

print(f"\n{'页':<12}{'轮数':>4}{'max(样本)MB 各轮':>26}{'最差':>7}{'peak MB':>9}{'CPU% 各轮':>26}{'中位':>7}")
worst_mem = 0.0
cpu_medians = {}
for sec, d in rows.items():
    mems, cpus = d["max"], d["cpu"]
    med = statistics.median(cpus)
    cpu_medians[sec] = med
    worst_mem = max(worst_mem, max(mems))
    peak = max(d["peak"]) if d["peak"] else 0
    print(f"{sec:<12}{len(mems):>4}{str([int(m) for m in mems]):>26}{int(max(mems)):>7}"
          f"{int(peak):>9}{str([round(c, 2) for c in cpus]):>26}{round(med, 2):>7}")

worst_cpu = max(cpu_medians.values())
worst_page = max(cpu_medians, key=cpu_medians.get)
worst_mem_page = max((max(d["max"]), s) for s, d in rows.items())[1]
print(f"\n最差页：内存 {worst_mem_page}（max {worst_mem:.0f} MB）  CPU {worst_page}（中位 {worst_cpu:.2f}%）")
print(f"机器负载峰值（各轮 load 列首段）≈ {load_max:.1f}   静默闸门 LOAD_CEILING={ceiling}")

if nav_failed:
    print(f"⚠️  有 {nav_failed} 行未落到指定板块，已从统计中剔除。")

if load_max > ceiling:
    print(f"\n⛔ 不作判定：机器不静默（load ≈ {load_max:.1f} > {ceiling}）。"
          f"\n   判据④ 管的是**空闲**，上面这些数只能当参考。"
          f"\n   请关掉其它会话/编译任务后重跑本脚本。")
    sys.exit(3)

mem_ok = worst_mem <= 200
cpu_ok = worst_cpu < 3
print(f"\n内存（稳态上限口径 = max(每轮 max(样本))）：{worst_mem:.0f} MB {'≤' if mem_ok else '>'}200 MB  ⇒ {'🟢' if mem_ok else '🔴'}")
print(f"CPU  （各轮中位数的最大值）：{worst_cpu:.2f}% {'<' if cpu_ok else '≥'}3%  ⇒ {'🟢' if cpu_ok else '🔴'}")
print("（peak 只报不判：ADR-0009 裁定 6。峰值高于 max(样本) 说明采样太稀，不是达标与否的依据。）")
sys.exit(0 if (mem_ok and cpu_ok) else 1)
PY
