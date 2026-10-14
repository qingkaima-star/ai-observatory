#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/rig-selfcheck.sh — 测量装置自己的对照实验（#92；零实例、零写库、不挑机器负载）
#
#  Owner: ws/rig
#  ─────────────────────────────────────────────────────────
#  为什么要有这颗：本轮四件改动全是**尺子**，而尺子的错不会自己报错——
#  它只安静地给出一张看起来正常的表。§13→§14 那一轮就是三条这样的错叠在一起
#  （整进程 CPU 记给单页 / 活动量不入表 / 丢对规则不对称），26 扇窗跑完才被发现。
#  所以这里跑的不是产品，是装置自己：每一格都问一句「如果我把它改坏，谁会变红」。
#
#  全部检查**不需要起 App、不需要静默机器**：
#   · 闸的分支用 `quiet-gate.sh` 暴露的取数口（`LOAD_CMD` / `PROBE_PIDS_CMD`）喂进去。
#     喂出来的记录一律 `gate_mode=injected` ⇒ **不许**当验收读数引用（这一列存在的理由
#     就是"自检的把戏不能伪装成真测量"；`rig-selfcheck.sh` 专门有一格钉这件事）。
#   · 汇总步骤的数学用一份**合成 manifest**（生成线已知：臂 A 固定开销 3.000 s/窗、
#     臂 B 2.000 s/窗、每笔事件 0.350 s）反推。对不上就是汇总步骤错了——
#     **期望值写死在这里，不去迁就读数**（§14 那次如果先有这一格，就不会有人去引用 434 vs 112）。
#
#  用法：Tools/UIProbe/rig-selfcheck.sh          # 全跑；全绿 exit 0
#        Tools/UIProbe/rig-selfcheck.sh --list   # 只看格名（不跑）
#  退出码：0 全绿；1 有格红（红在哪格逐行打出来）；2 环境缺东西（sqlite3 / python3 / awk）
# ============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$ROOT/tmp/rig-selfcheck"; mkdir -p "$T"
PASS=0; FAIL=0; LIST_ONLY=0
[ "${1:-}" = "--list" ] && LIST_ONLY=1

for tool in sqlite3 python3 awk pgrep grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ 环境缺 $tool ⇒ 自检跑不了（缺工具不等于通过）" >&2; exit 2; }
done

ck() {   # $1=格名 $2=0 表示通过 $3=人读说明。每格独立计分：一格红不许顺手停掉别的格。
  local name="$1" rc="$2" desc="$3"
  if [ "$LIST_ONLY" = "1" ]; then echo "  - $name — $desc"; return 0; fi
  if [ "$rc" = "0" ]; then PASS=$((PASS+1)); printf '✅ %-30s %s\n' "$name" "$desc"
  else FAIL=$((FAIL+1)); printf '❌ %-30s %s\n' "$name" "$desc"; fi
}
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{d=a-b; if(d<0)d=-d; print (d<=t)?0:1}'; }

# 生成线（改这里必须同时改上面注释里那句"为什么是这个数"）
GEN_FIXED_A=3.000      # s/窗：臂 A 与活动量无关的固定开销（引擎 tick + 前台重算）
GEN_FIXED_B=2.000      # s/窗：臂 B 同上
GEN_SLOPE=0.350        # s/笔：每笔被观测事件摊走的成本（**不参与归因**）
GEN_POOLED=2.500       # 设计平衡 ⇒ 合并回归的截距 = 两臂固定开销的均值
GEN_GAP=1.000          # 同活动量下的臂间截距差（A−B）

if [ "$LIST_ONLY" = "1" ]; then echo "格名列表："; fi

# ════════ 格 1：静默前置闸的四条分支（闸必须有牙，而且咬错方向也算红）════════
. "$ROOT/Tools/UIProbe/quiet-gate.sh"

# ⚠️ 取数口是**按空白分词当命令执行**的（`raw=$($LOAD_CMD)`），所以这里只写不需要引号的命令：
#    `printf ' 0.5 …'` 会被拆成 printf 的格式串 `'` ⇒ 闸读到一条"不是个数"的垃圾 ⇒ 判"不静默"。
#    这个失败方向是**对的**（读坏了不放行），但自检要验的是"能放行"那一支，所以一律用 `echo`。
run_gate() {   # $1 = LOAD_CMD 覆盖 $2 = PROBE_CMD 覆盖 $3 = LOAD_CEILING 覆盖（可空）
  LOAD_CMD="$1" PROBE_CMD="$2" LOAD_CEILING="${3:-4}" GATE_TRIES=1 \
    bash "$ROOT/Tools/UIProbe/quiet-gate.sh" > "$T/gate.out" 2>&1
}

run_gate "echo 12.34 12 12" "true"
ck gate_high_load_refuses $(( $? == 0 ? 1 : 0 )) "load 12.3 / 上限 4 ⇒ 必须拒（退出码非 0）"

run_gate "echo 0.50 0.5 0.5" "true"
ck gate_quiet_passes $(( $? == 0 ? 0 : 1 )) "load 0.5 + 无 Agent ⇒ 必须放行（否则闸是死的）"

run_gate "echo 0.50 0.5 0.5" "true"
grep -q "gate_mode=injected" "$T/gate.out"
ck gate_injection_marked $? "换过任何取数口 ⇒ 必须标 injected（自检的把戏不许伪装成真测量）"

run_gate "echo 9.90 9 9" "true"
ck gate_load_alone_blocks $(( $? == 0 ? 1 : 0 )) "只有 load 超闸也必须拒（Agent 名单空不构成放行）"

run_gate "echo 0.20 0.2 0.2" "echo 8888"
ck gate_agent_alone_blocks $(( $? == 0 ? 1 : 0 )) "load 0.2 但有 Agent 进程也必须拒（存在即不静默，不看 CPU%）"
grep -q "命中 pid 8888" "$T/gate.out"
ck gate_agent_pid_reported $? "拒的理由里必须带命中的 pid（可核对，不是「感觉机器挺忙」）"

run_gate "echo n/a" "true"
ck gate_garbage_load_refuses $(( $? == 0 ? 1 : 0 )) "load 读数不是个数 ⇒ 按不静默处理（读坏了比读到高值更危险）"

run_gate "echo 0.10 0.1 0.1" "true" "abc"
ck gate_bad_ceiling_refuses $(( $? == 0 ? 1 : 0 )) "LOAD_CEILING 不是个数 ⇒ 拒（不能拿一个坏上限去放行）"

bash "$ROOT/Tools/UIProbe/quiet-gate.sh" --print-agents > "$T/agents.txt" 2>&1
grep -q "签名表现读" "$T/agents.txt"
ck gate_agents_from_source $? "Agent 名单现读产品签名表（不是装置里抄的第二份常量）"
if grep -qE '(^|[[:space:]])String([[:space:]]|$)' "$T/agents.txt"; then r=1; else r=0; fi
ck gate_agents_no_type_literal $r "名单里不许混进类型声明字面量（少一道筛就会混进 String 这个词）"

# ════════ 格 2：闸拦下时，两个驱动器都必须「零动作」并给出新退出码 ════════
# ⚠️ 这两格**不依赖宿主此刻的状态**：不静默是**注入出来的**（load 30 + 明确没有 Agent），
#    所以正常构建里必红、把上限改松的变异构建里必绿转红。上一版这里蹭了"本机恰好有 codex 在跑"，
#    那意味着换一台真静默的机器跑自检会出现**假绿**（闸真被改松也照样通过）。
LOAD_CMD="echo 30.0 30 30" PROBE_CMD="true" GATE_TRIES=1 GATE_WAIT=1 \
  bash "$ROOT/Tools/UIProbe/measure-pages.sh" dashboard > "$T/mp.out" 2>&1
rc=$?
ck measure_refuses_exit4 $(( rc == 4 ? 0 : 1 )) "不静默 ⇒ measure-pages 退出码 4（实得 $rc），读数 0 行"
if grep -q "^section,window_title" "$T/mp.out"; then r=1; else r=0; fi
ck measure_no_csv_when_blocked $r "被拦下时 stdout 里不许出现表头或任何行（stdout 就是 CSV）"
if grep -q "残留（按本树路径查）" "$T/mp.out"; then r=1; else r=0; fi
ck measure_gate_before_anything $r "闸在找包/起实例**之前** ⇒ 连收尾清理那段都不该跑到（零动作的可核对证据）"

APP_A=/Users/dev/nope-a.app APP_B=/Users/dev/nope-b.app \
DATA_A="$T/da" DATA_B="$T/db" PAGES=dashboard ROUNDS=1 GATE_WAIT=1 \
LOAD_CMD="echo 30.0 30 30" PROBE_CMD="true" GATE_TRIES=1 \
  bash "$ROOT/Tools/UIProbe/ab-sweep.sh" > "$T/ab.out" 2>&1
rc=$?
ck sweep_refuses_exit4 $(( rc == 4 ? 0 : 1 )) "A/B 驱动器同样一对都不开（实得 $rc）"
if grep -q "APP_A 不存在" "$T/ab.out"; then r=1; else r=0; fi
ck sweep_gate_before_package_check $r "闸排在包检查之前 ⇒ 不静默时不许先报「缺包」"
if [ -f "$T/da/manifest.csv" ] || [ -d "$T/da" ]; then r=1; else r=0; fi
ck sweep_wrote_no_manifest $r "一窗未开 ⇒ 不留一张空表（空表会被下游读成「全是 0」）"

# ════════ 格 3：表那一行不许被空格 / 逗号 / 中文破掉（row-format.sh）════════
bash -c '
  . "'"$ROOT"'/Tools/UIProbe/row-format.sh"
  row_reset
  row_set section dashboard
  row_set gate_agents "111 222 333"
  row_set window_title "静默闸未过·未开这一行(原因=load_1m 12.3 > 4; 命中 pid 111 222, 已重试 3 次)"
  row_line' > "$T/row.txt" 2> "$T/row.err"
ck row_set_survives_spaces $(( $? == 0 ? 0 : 1 )) "值里带空格/分号/逗号/中文 ⇒ 填值不许把它劈成命令（旧 eval 版在这里丢尾巴）"
cols=$(bash -c ". '$ROOT/Tools/UIProbe/row-format.sh'; row_header" | awk -F, '{print NF}')
got=$(awk -F, 'NR==1{print NF}' "$T/row.txt")
ck row_field_count_matches $(( cols == got ? 0 : 1 )) "字段数必须等于列数（表头 $cols / 行 $got）"
if grep -q "命中 pid 111 222" "$T/row.txt"; then r=0; else r=1; fi
ck row_reason_not_truncated $r "闸原因必须整句进表（截断 = 事后没人知道这一行为什么被拦）"
if grep -q "12.3 > 4; 命中 pid 111 222; 已重试" "$T/row.txt"; then r=0; else r=1; fi
ck row_comma_escaped $r "值里的逗号被换成分号：CSV 没有转义层，平移整列比空值更难查"

# ════════ 格 4：族分堆的解析器（把「引擎 tick」与「前台重算」分开的那一列）════════
bash "$ROOT/Tools/UIProbe/family-sample.sh" --self-check > /dev/null 2>&1
ck family_selfcheck $? "叶子按「路径上最深的族帧」归族；父帧不重复计数；族边界与 Sources/ 同源"

# ════════ 格 5：汇总步骤的数学与纪律（合成 manifest，生成线已知）════════
python3 - "$T/synth-manifest.csv" "$GEN_FIXED_A" "$GEN_FIXED_B" "$GEN_SLOPE" <<'PY'
import csv, sys
path, fa, fb, slope = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
cols = ["pair","section","window_title","arm","round","window_s","t0_epoch","t1_epoch",
        "measured_wall_s","cpu_pct","cputime_delta_s","load_before","load_after","load1_before",
        "load1_after","ms_per_tick","tick_cadence_s","cadence_source","events_delta","commands_delta",
        "file_changes_delta","risk_events_delta","perf_samples_delta","events_total_last",
        "engine_leaf_n","ui_leaf_n","other_leaf_n","sample_ok","turn_p50_ms","turn_gt_100ms_n",
        "turn_instrument","gate","gate_mode","gate_agents"]
# 设计：六对里五对两臂事件数**相同**（配平），第六对故意不同（r3：A 5 笔 / B 40 笔）。
# ⇒ 只比截距的报告会给出「A 每窗贵 1.000 s」；而 r4 / r7 这两对的 Δcpu 总量差是**反号**的
#   （谁的窗口里事件多，谁就看起来贵）。这一格钉的就是「总量会把方向读反」这件事。
# ⚠️ 设计必须**配平**（两臂事件均值相同）才敢期望合并截距 = 两臂固定开销的均值：
#    第一版没配平，读回 2.708 而不是 2.500 —— 那是我把期望值写错，不是汇总步骤错。
pairs = [(10,10),(20,20),(40,40),(5,40),(30,30),(12,12),(40,5)]   # 末对与第 4 对镜像 ⇒ 两臂事件均值相同
rows = []
for i,(ea,eb) in enumerate(pairs, start=1):
    for arm, ev, fixed in (("a", ea, fa), ("b", eb, fb)):
        dcpu = round(fixed + slope*ev, 3)
        r = {c: "" for c in cols}
        r.update(pair=f"r{i}-dashboard", section="dashboard", window_title="今日概览",
                 arm=arm, round=i, window_s=90, t0_epoch=1790000000+i*200,
                 t1_epoch=1790000143+i*200, measured_wall_s=90, cputime_delta_s=dcpu,
                 load1_before=1.2, load1_after=1.4, tick_cadence_s=3.0, cadence_source="measured",
                 events_delta=ev, commands_delta=ev, file_changes_delta=0, risk_events_delta=0,
                 perf_samples_delta=100, events_total_last=ev, gate="pass", gate_mode="real")
        rows.append(r)
# 第八对：**窗开成了**（gate=pass、load 达标）但活动量读不出来（库里取不到 ⇒ events 为空）。
#   这一格专钉"na 当 0"：写成 0 就是"这一窗零活动"的假读数 —— 回归的自变量被污染成 0，
#   斜率与截距一起作废而没人看得见（`sqlite3` 报错时 stdout 是空的，`awk` 会读成 0，就是这个形状）。
for arm in ("a","b"):
    r = {c: "" for c in cols}
    r.update(pair="r8-activityblind", section="activityblind", arm=arm, round=8,
             window_title="今日概览", load1_before=1.1, load1_after=1.1,
             cputime_delta_s=1.5, measured_wall_s=90, tick_cadence_s=3.0,
             events_delta="", gate="pass", gate_mode="real")
    rows.append(r)
# 第七对：两臂都被闸拦下 ⇒ 一扇窗都没开（表里 gate=fail、读数留空，不是 0）
for arm in ("a","b"):
    r = {c: "" for c in cols}
    r.update(pair="r7-dashboard", section="dashboard", arm=arm, round=7,
             window_title="静默闸未过·未开这一行(原因=load 超闸)",
             load1_before=9.9, gate="fail", gate_mode="real")
    rows.append(r)
with open(path, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=cols); w.writeheader(); w.writerows(rows)
PY
python3 "$ROOT/Tools/UIProbe/ab-report.py" --manifest "$T/synth-manifest.csv" \
        --json "$T/synth-report.json" > "$T/report.txt" 2>&1
rc=$?
ck report_runs_and_keeps_pairs $(( rc == 0 ? 0 : 1 )) "合成 manifest 跑通且至少有合格对（实得 exit $rc）"

read -r got_int got_slope got_a got_b got_beta <<EOF2
$(python3 - "$T/synth-report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
g = d["regression_diag"]["全部"]; att = d["attribution"]
print("%.3f %.3f %.3f %.3f %.3f" % (
    g["intercept"], g["slope"],
    att["arm_a"]["intercept"], att["arm_b"]["intercept"],
    (d["pooled_beta"] or [0,0,99])[2]))
PY
)
EOF2
ck report_recovers_slope     $(near "$got_slope" "$GEN_SLOPE" 0.02) "斜率读回 $got_slope（生成线 $GEN_SLOPE s/笔）"
ck report_recovers_pooled_intercept $(near "$got_int" "$GEN_POOLED" 0.02) "合并截距读回 $got_int（设计平衡 ⇒ 应等于两臂固定开销均值 $GEN_POOLED）"
ck report_perarm_intercept_a $(near "$got_a" "$GEN_FIXED_A" 0.02) "臂 A 截距读回 $got_a（生成线 $GEN_FIXED_A s/窗）"
ck report_perarm_intercept_b $(near "$got_b" "$GEN_FIXED_B" 0.02) "臂 B 截距读回 $got_b（生成线 $GEN_FIXED_B s/窗）"
ck report_arm_gap_is_the_attribution $(near "$got_beta" "$GEN_GAP" 0.02) "同活动量臂间截距差读回 $got_beta（生成线 $GEN_GAP：A 每窗更贵）"
grep -q "斜率不参与归因" "$T/report.txt"
ck report_states_slope_excluded $? "报告明写「斜率不参与归因」（这一列最容易被顺手引用错）"
grep -q "r7-dashboard" "$T/report.txt"
ck report_lists_dropped_pair $? "被闸丢掉的那一对连事件数一起出现在表里（本轮教训：丢掉的那对恰好唯一反号）"
python3 - "$T/synth-report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
dr = [x[0] for x in d["dropped"]]; kept = d["kept"]
bad = []
if "r7-dashboard" not in dr: bad.append("丢掉的对没进 dropped 清单")
if any(p.startswith("r7") for p in kept): bad.append("丢掉的对混进了保留清单")
# 对称性：任何一对里出现 gate=fail ⇒ 整对必须落在 dropped，绝不能留在 kept
for p in kept:
    if not all(r["gate"] == "pass" for r in d["rows"] if r["pair"] == p):
        bad.append(f"{p} 一臂 gate=fail 却仍被保留（不对称）")
print("❌ " + "；".join(bad) if bad else "✅ 丢对清单与保留清单互斥，且两臂同进退")
raise SystemExit(1 if bad else 0)
PY
ck report_drop_is_symmetric $? "丢对两臂一起：一臂 gate=fail ⇒ 整对不计（缺一臂也算）"
grep -q "活动量取不到" "$T/report.txt"; r=$?
ck report_na_not_zero $r "开成了窗但活动量取不到 ⇒ 走 na 分支被丢掉，绝不当成「这窗零活动」"
python3 - "$T/synth-report.json" r8-activityblind <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); p = sys.argv[2]
bad = []
if p in d["kept"]: bad.append("活动量取不到的对被保留（= 把 na 当 0 了）")
if not any(x[0] == p for x in d["dropped"]): bad.append("活动量取不到的对没进 dropped 清单")
print("❌ " + "；".join(bad) if bad else "✅ 机器读的那份里，r8 既不在 kept 也在 dropped")
raise SystemExit(1 if bad else 0)
PY
ck report_na_pair_dropped $? "JSON 侧同一条：events 为 na 的一对不在保留清单、且在丢掉清单里"
# 反号那一格：r4 的 Δcpu 总量差与截距差**符号相反**，报告必须把两种符号都摊出来
grep -q "a>b" "$T/report.txt" && grep -q "a<b" "$T/report.txt"; r=$?
ck report_shows_both_signs $r "符号分布把**所有**对（含反号那对）一起摊开：「三对同号」不能靠挑对讲出来"

# ════════ 格 6：只读性与时间基准（装置对任何库都不该有写权限）════════
DBA="$ROOT/Tools/UIProbe/db-activity.sh"
grep -q 'SQLITE_URI="file:\$ABS?mode=ro"' "$DBA"
ck db_readonly_uri $? "唯一的连接串就是 ?mode=ro（§13.2 活库 sha 不变靠的是这条）"
grep -nE 'sqlite3 ' "$DBA" | grep -vE 'SQLITE_URI|command -v|^[0-9]+: *#' > "$T/rw.txt"
ck db_no_other_connection $(( $(wc -l < "$T/rw.txt" | tr -d ' ') == 0 ? 0 : 1 )) "没有第二条绕过 ro 的 sqlite3 连接"
grep -q '978307200' "$DBA"
ck refdate_offset_documented $? "ReferenceDate 偏移写死并注明（搞错基准 = 差 31 年 = 永远「窗内 0 笔」这种假样本）"

echo
echo "== 装置自检合计：✅ $PASS / ❌ $FAIL =="
if [ "$LIST_ONLY" = "1" ]; then exit 0; fi
[ "$FAIL" = "0" ] || { echo "❌ 装置自检未全绿 ⇒ 这一轮的读数不可信：先修尺子，再开窗。" >&2; exit 1; }
echo "RIG_SELFCHECK=pass"
exit 0
