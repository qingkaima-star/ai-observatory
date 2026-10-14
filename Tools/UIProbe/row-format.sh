#!/usr/bin/env bash
#
# ============================================================================
#  Tools/UIProbe/row-format.sh — 测量单元那一行的**列清单与装配**（#92 装置的表头唯一出处）
#
#  Owner: ws/rig（测量装置，不进产品 target）
#  ─────────────────────────────────────────────────────────
#  为什么单独一颗：
#   1. **列清单只能有一处**。上一轮的原始件（`tmp/ab-perf/manifest.tsv`）里，驱动器和
#      `measure-pages.sh` 各写了一份列顺序，加列时全靠手抄逗号 —— 抄错一位就是整列错位，
#      而 `phys_footprint` 取错列那一次是**静默产出空值**（不报错，只是那一列以后都不可信）。
#   2. **装配要能离线测**。`emit_row` 长在 `measure-pages.sh` 里，要验"值带空格/中文/逗号会不会
#      破表"就得跑一整场 180 s 的窗，于是没人验过。抽出来之后 `rig-selfcheck.sh` 一毫秒就能验，
#      而且**不需要起任何实例**。
#
#  这一版真踩到的两个坑（都写在下面的函数里，自检各钉一条）：
#   · `setf` 早先是 `eval "F_$1=$2"` ⇒ 值里一空就劈成两条命令（`bash: 静默: command not found`），
#     而表里天然带空格的值至少有两个：闸原因整句中文、`gate_agents` 的 pid 列表。
#   · 值里带逗号会**平移整列**（CSV 没有转义层）⇒ 一律先替换成分号，并让自检去数"字段数 == 列数"。
#
#  用法（被 source）：
#    . Tools/UIProbe/row-format.sh
#    row_reset; row_set section dashboard; row_set gate_reason "load 12.3 > 4"; row_line      # 打到 stdout
#    row_header                                    # 表头（与 row_line 同一张列清单）
#    row_cols | tr ' ' '\n' | wc -l               # 列数（自检拿它对齐字段数）
#  ⚠️ 新增一列 = 只改 ROW_COLS 一处 + 在调用方 `row_set` 填值；**不要**在任何别处再抄一遍列名。
# ============================================================================

# 列的分组（每列都得回答"读它的人能干什么"）：
#   · 身份：`section window_title arm round pair_page` —— 哪一页、哪一臂、第几轮。
#     §13 那轮的臂身份只存在于驱动器的 manifest 里，单看一行读不到 ⇒ 报告只能靠先后顺序猜，
#     配对配错臂没人能发现（而"配错臂"正是最容易在深夜补跑时发生的事）。
#   · 墙钟：`t0_epoch t1_epoch measured_wall_s window_s` —— Δcputime 的分母。
#     标称 `window_s` 与实测 `measured_wall_s` 两样都留：前者是判据④ 的**固定尺**（不许被
#     换成分母的方式悄悄放宽），后者是算 ms/tick 的**真尺**（footprint 探针的停顿只体现在后者）。
#   · 读数：`footprint_* cpu_pct cputime_delta_s ms_per_tick tick_cadence_s cadence_source`
#   · 闸：`load1_before load1_after gate gate_mode gate_agents`（`load_before/load_after` 是
#     上一版留下的**拼接串**，为兼容老解析原样保留，新代码一律读 `load1_*`）
#   · 活动量（§14 翻案的主项）：`events_delta commands_delta file_changes_delta
#     risk_events_delta perf_samples_delta events_total_last`
#   · 族分堆（把"引擎 tick"与"前台重算"分开，`family-sample.sh` / `turn-trace.sh` 各一列）：
#     `engine_leaf_n ui_leaf_n other_leaf_n sample_ok turn_p50_ms turn_gt_100ms_n turn_instrument`
ROW_COLS="section window_title arm round footprint_max_MB footprint_last_MB footprint_peak_MB samples \
window_s t0_epoch t1_epoch measured_wall_s cpu_pct cputime_delta_s load_before load_after \
load1_before load1_after ms_per_tick tick_cadence_s cadence_source \
events_delta commands_delta file_changes_delta risk_events_delta \
perf_samples_delta events_total_last \
engine_leaf_n ui_leaf_n other_leaf_n sample_ok turn_p50_ms turn_gt_100ms_n turn_instrument \
gate gate_mode gate_agents"

row_reset() { local c; for c in $ROW_COLS; do eval "F_$c=\"\""; done; }

# 填值一律走 `printf -v`，不许 eval：见文件头那条踩坑。
row_set() { printf -v "F_$1" '%s' "$2"; }

# 取列（自检与调用方都用它，避免"第几列"这种数法）
row_get() { eval "printf '%s' \"\${F_$1:-}\""; }

row_header() { printf '%s\n' "$(echo "$ROW_COLS" | tr ' ' ',')"; }

# 一行 = 与表头**同一张列清单**生成，值里的逗号先换成分号（见文件头）。
row_line() {
  local line="" c v
  for c in $ROW_COLS; do
    eval "v=\${F_$c:-}"; v="${v//,/;}"
    [ -n "$line" ] && line="$line,"
    line="$line$v"
  done
  printf '%s\n' "$line"
}
