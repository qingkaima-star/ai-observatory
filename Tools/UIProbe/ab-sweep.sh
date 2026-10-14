#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/ab-sweep.sh — 受控 A/B 配对驱动器（#92 装置第一格的"流程侧"）
#
#  Owner: ws/rig（测量装置，不进产品 target）
#  ─────────────────────────────────────────────────────────
#  为什么必须有一颗**驱动器**，而不是"每个臂各跑一次 measure-pages.sh 再手工配表"：
#    §13 那一轮的 26 扇窗就是两个临时驱动脚本（`tmp/ab-perf/driver-0923.sh` /
#    `driver-supplement.sh`，都在 tmp/，跑完就没人管了）跑的。它们的闸是**事后**的：
#    `LOAD_CEILING=4` 对本仓自带的静默闸一次都没满足过，却在**全部跑完之后**才被
#    `quiet-verdict.sh` 以 `QUIET_VERDICT_EXIT=3 ⛔ 不作判定` 作废（§13.7 限制 2）。
#    ⇒ 「闸在脚本里但不在驱动流程里」= 成本（26 × 142 s ≈ 62 分钟机器时间）先付掉了，
#      才发现买回来的读数一张都不能用。这一格的存在就是把闸挪到**每一对开始之前**：
#      闸不过 ⇒ 不起实例、不取数、这一对整对丢掉，两臂同规则。
#
#  丢对规则（§14 点名要的两条，落成代码而不是落成注释）：
#    1. **两臂对称**：一对里任何一侧出问题 ⇒ 两侧一起丢，绝不出现"只丢 A 的半对"。
#       （本轮教训：dashboard 第 5 轮被按"单臂 load 差"丢掉，而那一对恰好是**四对里唯一反号**的——
#         丢掉它之后剩下的三对同号，于是"首页 A 更贵 +3~+12 pt"被当成结论收了。
#         见 §14：配平活动量之后 A 反而 ≤ B。）
#    2. **只允许一条丢对理由**：静默前置闸不过（load 超上限，或被观测 Agent 在跑）。
#       其它任何异常（缺包、库取不到、落页核验不过、脚本退出码不是 0/4）都是**仪器坏了**，
#       当场以非零码中止整场，不做"悄悄丢掉一行了事"——那等于给报告留一个没人知道的洞。
#
#  实例卫生（需求方 2026-09-23 直接指令）：
#    · 同一时刻只一颗：A 跑完并确认退出，才起 B。绝不并行两臂（两臂同时跑 = 互相抢 CPU，
#      量出来的差值是"谁先抢到核"）。measure-pages.sh 每个测量单元跑完立刻收自己那颗。
#    · 只按**自己写下的 pid** 收，绝不按进程名批量 kill（同名会杀掉别车正在验证的实例）。
#    · 驱动器不额外起实例，因此整场不静默时可以**零实例**跑完（这正是本轮的实况）。
#
#  用法：
#    APP_A=/Users/dev/tree-a/dist/AIObservatory.app \
#    APP_B=/Users/dev/tree-b/dist/AIObservatory.app \
#    DATA_A=$PWD/tmp/ab-sweep/data-a DATA_B=$PWD/tmp/ab-sweep/data-b \
#    Tools/UIProbe/ab-sweep.sh
#    PAGES="dashboard" ROUNDS=1 …          # 冒烟：一页一轮（仍受同一颗闸管）
#    WINDOW=180 SAMPLES=12 SETTLE=45 …     # 正式口径（<180 s 只能算烟测，见 measure-pages 文件头）
#  产物（全部落 tmp/，已 gitignore）：
#    manifest.csv      每一扇窗一行 = measure-pages 的全部列 + 驱动器补的 pair；
#                      **表头从第一个真实产出的 CSV 抄过来**，列名不在两处各写一遍（两处写必漂移）。
#    pairs.tsv         逐对结论（保留/丢弃 + 丢弃理由 + 两臂各自的事件数）
#    run-<r>-<页>-<臂>.csv/.log   单窗原件（measure-pages 原样产出，含它自己那些 gate=fail 行）
#    fixture-sha.txt     母本 + 两臂副本库的 sha（同源同字节当场可核）
#    control-db.txt      不参与本轮那份库的前后 sha（装置对任何库只该有读权限）
#  退出码：0 全部对有效；1 至少一对被闸丢掉（表仍可用，但报告必须列出丢了哪些）；
#          2 前置条件不满足（缺包 / 缺臂库 / 参数错）；3 落页核验不过 ⇒ 仪器坏了，中止整场；
#          4 **每一对都被静默前置闸拦下 ⇒ 一窗未开、不作判定**。
# ============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

. "$ROOT/Tools/UIProbe/quiet-gate.sh"          # 唯一那颗闸（measure-pages / quiet-verdict 共用）

APP_A="${APP_A:-}"; APP_B="${APP_B:-}"
DATA_A="${DATA_A:-}"; DATA_B="${DATA_B:-}"
PAGES="${PAGES:-dashboard timeline security}"
ROUNDS="${ROUNDS:-3}"
WINDOW="${WINDOW:-180}"; SAMPLES="${SAMPLES:-12}"; SETTLE="${SETTLE:-45}"
OUT_DIR="${OUT_DIR:-$ROOT/tmp/ab-sweep}"
CONTROL_DB="${CONTROL_DB:-$ROOT/observatory-data/observatory.sqlite}"   # 只 shasum 作对照，绝不打开
LOAD_CEILING="${LOAD_CEILING:-4}"

usage_fail() { echo "❌ $*" >&2; exit 2; }
[ -n "$APP_A" ] || usage_fail "缺 APP_A（臂 A 的 .app 路径）"
[ -n "$APP_B" ] || usage_fail "缺 APP_B（臂 B 的 .app 路径）"
[ -n "$DATA_A" ] && [ -n "$DATA_B" ] || usage_fail "缺 DATA_A / DATA_B（两臂各自的**副本库**目录）"
[ "$DATA_A" != "$DATA_B" ] || usage_fail "DATA_A 与 DATA_B 是同一个目录 ⇒ 两臂会互相写库，配平无从谈起"
if [ "$WINDOW" -lt 180 ]; then
  echo "⚠️  WINDOW=${WINDOW}s < 180s ⇒ 烟测口径，不得用于判据④ 的正式判定（与 measure-pages.sh 同一条）。" >&2
fi

# ── 整场前置闸排在**"包在不在"之前**：机器不静默时，"该去哪找两颗包"都还轮不到问。
#    于是本轮实况是：load 10.4 + 两条 codex ⇒ 退出码 4、零实例、零读数、零写盘（除 tmp/ 里几个记录）。
if ! quiet_gate_wait "A/B 整场开测之前"; then
  echo "⛔ 静默前置闸未过 ⇒ **一对都不开**：$GATE_REASON" >&2
  echo "   配平 A/B 的前提是两臂处在同一台静默机器上；机器不静默时算出的差值是按名字排队的核时。" >&2
  printf 'QUIET_GATE=fail\nload_1m=%s\ngate_mode=%s\ngate_reason=%s\nDRIVER_EXIT=4\n' \
    "${GATE_LOAD1:-na}" "${GATE_MODE:-real}" "$GATE_REASON" >&2
  exit 4
fi

[ -d "$APP_A" ] || usage_fail "APP_A 不存在：$APP_A"
[ -d "$APP_B" ] || usage_fail "APP_B 不存在：$APP_B"
case "$CONTROL_DB" in
  *"$DATA_A"*|*"$DATA_B"*) usage_fail "CONTROL_DB 不许指向任一臂的库（它必须是**不参与本轮**的那份对照）" ;;
esac

mkdir -p "$OUT_DIR" "$DATA_A" "$DATA_B"
MANIFEST="$OUT_DIR/manifest.csv"
PAIRS="$OUT_DIR/pairs.tsv"
PROGRESS="$OUT_DIR/driver.progress"
# 每次跑**从头建表**：往上一轮的 manifest 上追加 = 两轮的口径混在一张表里，
# 而这两轮的 LOAD_CEILING / 包可能根本不是同一套（表里没有任何一列能看出这件事）。
rm -f "$MANIFEST" "$PROGRESS"

# 臂库就位：没有就从母本 cp -p 一份（各臂**独立副本**，迁移互不污染 —— §13.2 的同源同字节）。
# 就位后把三颗库的 sha 打进 `fixture-sha.txt`：两臂相等且等于母本 ⇒ "同源同字节"是**当场可核对**的，
# 不是收尾时口头说的。
arm_db_ready() {   # $1=目录 $2=臂名
  local dir="$1" arm="$2"
  if [ ! -f "$dir/observatory.sqlite" ]; then
    { [ -n "${MASTER_DB:-}" ] && [ -f "$MASTER_DB" ]; } \
      || usage_fail "臂 $arm 的库不存在（$dir/observatory.sqlite），且没给 MASTER_DB 母本"
    mkdir -p "$dir"; cp -p "$MASTER_DB" "$dir/observatory.sqlite"
    echo "   臂 $arm：已从母本 cp -p 一份副本 → $dir" >&2
  fi
  shasum -a 256 "$dir/observatory.sqlite" | sed "s|$dir/observatory.sqlite|arm-$(printf '%s' "$arm" | tr -d '\n') 库|" >> "$OUT_DIR/fixture-sha.txt"
}
: > "$OUT_DIR/fixture-sha.txt"
[ -n "${MASTER_DB:-}" ] && [ -f "${MASTER_DB:-}" ] && shasum -a 256 "$MASTER_DB" | sed 's|$|（母本）|' >> "$OUT_DIR/fixture-sha.txt"
arm_db_ready "$DATA_A" a
arm_db_ready "$DATA_B" b
if [ "$(awk '{print $1}' "$OUT_DIR/fixture-sha.txt" | sort -u | wc -l | tr -d ' ')" != "1" ]; then
  echo "⚠️  两臂的库 sha 不一致（见 $OUT_DIR/fixture-sha.txt）⇒ 数据形状不同，任何差值都不是构建差。" >&2
fi

# 活库对照：只 shasum，不 open、不 copy。收尾再读一次，两次不同 ⇒ 本轮写了不该写的东西。
CONTROL_SHA_BEFORE=""
if [ -f "$CONTROL_DB" ]; then
  CONTROL_SHA_BEFORE=$(shasum -a 256 "$CONTROL_DB" | awk '{print $1}')
  printf 'control_db=%s\ncontrol_db_sha_before=%s\n' "$CONTROL_DB" "$CONTROL_SHA_BEFORE" > "$OUT_DIR/control-db.txt"
  echo "ℹ️  对照库（不碰只记 sha）：$CONTROL_DB $CONTROL_SHA_BEFORE" >&2
fi

echo "==> A/B 配对扫描：$ROUNDS 轮 × $(echo "$PAGES" | wc -w | tr -d ' ') 页 × 两臂（A→B 紧邻）"
echo "    臂 A=$APP_A  库=$DATA_A"
echo "    臂 B=$APP_B  库=$DATA_B"
echo "    静默前置闸：LOAD_CEILING=$LOAD_CEILING GATE_TRIES=${GATE_TRIES:-3}×${GATE_WAIT:-20}s（名单现读，见 quiet-gate.sh）"

pairs_total=0; pairs_kept=0; pairs_dropped=0
printf 'round\tpage\tpair\tdecision\treason\tevents_a\tevents_b\tload_1m_before\tgate_mode\n' > "$PAIRS"

# 从单窗 CSV 里按**列名**取值（不数第几列：列顺序由 measure-pages 决定，数位置早晚会取错一位，
# `phys_footprint` 取错列那次静默产出空值就是这笔账）。取不到 ⇒ 打印 na，绝不打印 0。
col_value() {   # $1=csv $2=列名
  awk -F, -v c="$2" 'NR==1{for(i=1;i<=NF;i++) if($i==c) k=i; next}
                     { if(!k){print "na"; exit} ; gsub(/[ \t\r]/,"",$k); print $k; exit }' "$1"
}

# 丢掉一对：两臂**一起**记，事件数取不到的写 `na(未开窗)` 而不是 0。
drop_pair() {   # $1=轮 $2=页 $3=理由 $4=events_a $5=events_b $6=load1 $7=gate_mode
  pairs_dropped=$((pairs_dropped + 1))
  printf '%s\t%s\tr%s-%s\tdrop\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$PAIRS"
  echo "[$(date '+%H:%M:%S')] r$1-$2 ⛔ 整对丢掉（两臂对称）：$3" >&2
}

for (( r = 1; r <= ROUNDS; r++ )); do
  for page in $PAGES; do
    pairs_total=$((pairs_total + 1))
    pair_id="r${r}-${page}"
    # ── 对级闸：**这一对开始之前**判。不过 ⇒ 两臂一起丢，一扇窗都不开、一颗实例都不起。
    if ! quiet_gate_wait "$pair_id 这一对开测之前"; then
      drop_pair "$r" "$page" "静默前置闸未过：${GATE_REASON}" "na(未开窗)" "na(未开窗)" \
        "${GATE_LOAD1:-na}" "${GATE_MODE:-real}"
      continue
    fi
    LOAD_PAIR_BEFORE="$GATE_LOAD1"

    rows_this_pair=0; ev_a="na"; ev_b="na"
    for arm in a b; do
      case "$arm" in
        a) app="$APP_A"; dir="$DATA_A" ;;
        b) app="$APP_B"; dir="$DATA_B" ;;
      esac
      csv="$OUT_DIR/run-$pair_id-$arm.csv"; log="$OUT_DIR/run-$pair_id-$arm.log"
      ARM="$arm" ROUND="$r" APP_OVERRIDE="$app" AIOBSERVATORY_DATA_DIR="$dir" \
      WINDOW="$WINDOW" SAMPLES="$SAMPLES" SETTLE="$SETTLE" \
      GATE_TRIES=1 GATE_TRIES_ROW=1 LOAD_CEILING="$LOAD_CEILING" \
      OUT="$csv" bash "$ROOT/Tools/UIProbe/measure-pages.sh" "$page" >> "$log" 2>&1
      rc=$?
      case "$rc" in
        0) : ;;
        4) drop_pair "$r" "$page" "开窗之前机器变忙（臂 $arm 这一行被闸拦下）⇒ 整对作废" \
             "$([ "$arm" = a ] && col_value "$csv" events_delta || echo "$ev_a")" \
             "$([ "$arm" = b ] && col_value "$csv" events_delta || echo "$ev_b")" \
             "${GATE_LOAD1:-na}" "${GATE_MODE:-real}"; rows_this_pair=0; break ;;
        3) echo "❌ 臂 $arm：$page 没落到指定板块 ⇒ **仪器坏了**，中止整场（不做'悄悄丢掉一行'）" >&2
           tail -3 "$log" >&2; exit 3 ;;
        *) echo "❌ 臂 $arm：measure-pages 退出码 $rc（非 0/3/4）⇒ 前置条件不满足，中止整场" >&2
           tail -5 "$log" >&2; exit 2 ;;
      esac
      if [ ! -s "$csv" ] || [ "$(wc -l < "$csv" | tr -d ' ')" -lt 2 ]; then
        echo "❌ 臂 $arm：$csv 里没有数据行 ⇒ 仪器坏了，中止整场" >&2; exit 2
      fi
      [ -f "$MANIFEST" ] || { head -1 "$csv" | sed 's/^/pair,/' > "$MANIFEST"; }
      # 产出的行**一律进表**（包括 gate=fail 的行）：报告要能看见"哪些行没开成"，
      # 只往表里写成功行 = 报告永远不知道少了谁。
      tail -n +2 "$csv" | sed "s|^|$pair_id,|" >> "$MANIFEST"
      rows_this_pair=$((rows_this_pair + 1))
      case "$arm" in a) ev_a=$(col_value "$csv" events_delta) ;; b) ev_b=$(col_value "$csv" events_delta) ;; esac
      echo "[$(date '+%H:%M:%S')] $pair_id 臂 $arm 完成  $(sysctl -n vm.loadavg)" >> "$PROGRESS"
    done
    [ "$rows_this_pair" = "2" ] || continue
    pairs_kept=$((pairs_kept + 1))
    printf '%s\t%s\t%s\tkeep\tsilence-gate-passed\t%s\t%s\t%s\t%s\n' \
      "$r" "$page" "$pair_id" "$ev_a" "$ev_b" "$LOAD_PAIR_BEFORE" "${GATE_MODE:-real}" >> "$PAIRS"
  done
done

if [ ! -f "$MANIFEST" ]; then
  echo "⛔ 一窗未开：$pairs_total 对**全部**被静默前置闸在开窗之前拦下 ⇒ 不作判定（读数 0 行）。" >&2
  echo "   需要的是机器静默（load_1m < ${LOAD_CEILING} 且被观测 Agent 不在跑），不是更多轮数或更长窗口。" >&2
  echo "   逐对记录（哪一对被谁丢掉、事件数为何）：$PAIRS" >&2
  echo "DRIVER_EXIT=4"
  exit 4
fi

# 对照库复测：两次 sha 不同 ⇒ 本轮写了不该写的库（装置对任何库都只该有读权限）。
if [ -n "$CONTROL_SHA_BEFORE" ] && [ -f "$CONTROL_DB" ]; then
  CONTROL_SHA_AFTER=$(shasum -a 256 "$CONTROL_DB" | awk '{print $1}')
  printf 'control_db_sha_after=%s\ncontrol_db_unchanged=%s\n' "$CONTROL_SHA_AFTER" \
    "$([ "$CONTROL_SHA_BEFORE" = "$CONTROL_SHA_AFTER" ] && echo 1 || echo 0)" >> "$OUT_DIR/control-db.txt"
  if [ "$CONTROL_SHA_BEFORE" != "$CONTROL_SHA_AFTER" ]; then
    echo "❌ 对照库被写过：$CONTROL_SHA_BEFORE → $CONTROL_SHA_AFTER ⇒ 本轮口径作废（装置只许只读）。" >&2
    exit 2
  fi
fi

echo "==> 完成：$pairs_total 对 = 有效 $pairs_kept + 被闸丢掉 $pairs_dropped；读数表 $MANIFEST"
echo "    逐对结论 $PAIRS"
LEFT=$(pgrep -f "$APP_A/Contents/MacOS|$APP_B/Contents/MacOS" | wc -l | tr -d ' ')
echo "本车道遗留实例数 = $LEFT" >&2
[ "$LEFT" != "0" ] && echo "⚠️  还有实例没退 ⇒ 不算收口。" >&2
[ "$pairs_dropped" -gt 0 ] && { echo "⚠️  有 $pairs_dropped 对被闸丢掉（报告必须连事件数一起列出这些对）。" >&2; exit 1; }
exit 0
