#!/usr/bin/env bash
# verify.sh — 工作树自检：构建 + 测试 + 棘轮 + 路径 + 探针可编译。
# 用法：Scripts/verify.sh [--tests]
# 返回非零码表示未通过，视为工作未完成。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

echo "==> 工作目录: $ROOT"
echo "==> 分支: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(no git)')"

# ── 0/4 磁盘水位（2026-09-21 事故加的硬闸）──────────────────────────────────
# 起因：性能取证在 $TMPDIR 留下 21 个孤儿 `instruments*.ktrace` 合计 103 GB（单个最大 20 GB），
# 可用一度只剩 4.4 GiB ⇒ `swift build` 直接 ENOSPC，打断了一整轮交付。
# 规矩：水位不够就别开始编译——**半途失败比不开始更贵**（它会留下半新半旧的 .build 与一条红 main）。
echo
echo "==> 0/4 磁盘水位（可用 < 20 GiB 不开工）"
AVAIL_KB="$(df -k /System/Volumes/Data 2>/dev/null | tail -1 | awk '{print $4}')"
if [ -z "${AVAIL_KB:-}" ] || ! [ "$AVAIL_KB" -eq "$AVAIL_KB" 2>/dev/null ]; then
    echo "⚠️  读不到磁盘水位（df 失败），这一道跳过——**不是通过**，请手工确认 df -h /System/Volumes/Data"
elif [ "$AVAIL_KB" -lt 20971520 ]; then
    echo "❌ 可用仅 $((AVAIL_KB / 1048576)) GiB（阈值 20 GiB）：不开工。先清取证垃圾再跑。"
else
    echo "✅ 可用 $((AVAIL_KB / 1048576)) GiB ≥ 20 GiB"
fi
# 取证垃圾清点：只报不删（删谁的进程还占着的文件会毁证据），但**单个 > 2 GB 的 .ktrace 直接判红**——
# 那就是 103 GB 事故的特征签名，说明有人在静默窗外跑了没收尾的 Instruments/xctrace。
if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR%/}" ]; then
    # ⚠️ 本脚本开头是 `set -euo pipefail`：**`| head` 提前关管道会让上游吃 SIGPIPE，整条脚本以 141 退出**
    # （我加这道闸的第一版就栽在这上面：构建根本没开始就"红"了）。所以这两处一律 `|| true` 兜住，
    # 并且判红只由显式的 `[ -n "$BIG" ]` 决定，不由管道退出码决定。
    BIG="$(find "$TMPDIR" -maxdepth 1 \( -name '*.ktrace' -o -name 'xrgpu_aps_*' \) -size +2G 2>/dev/null | head -5 || true)"
    if [ -n "$BIG" ]; then
        echo "❌ \$TMPDIR 里有超 2 GB 的取证残留（跑完没收尾）："; echo "$BIG"
        echo "   先确认采集进程已退出（kill -0 <pid> / lsof -a +D \"\$TMPDIR\"）再删，然后重跑。"
        exit 1
    fi
    echo "── \$TMPDIR 最大的 5 个文件（供参考）"
    du -ak "$TMPDIR" 2>/dev/null | sort -rn | sed -n '1,5p' | awk '{printf "   %8.1f MB  %s\n", $1/1024, $2}' || true
    # 用 `sed -n '1,5p'` 而不是 `head -5`：sed 会读完整个流，不会让 `sort`/`du` 提前收到 SIGPIPE。
fi

echo
echo "==> 1/5 swift build（含严格并发检查）"
mkdir -p "$ROOT/.build"
xcrun swift build --disable-sandbox 2>&1 | tee "$ROOT/.build/verify-build.log" | grep -E "error:|warning:" && {
    echo "❌ 构建存在问题"
    exit 1
} || true
xcrun swift build --disable-sandbox >/dev/null 2>&1 || { echo "❌ swift build 失败"; exit 1; }
echo "✅ 构建通过，无错误"

# 只量 `swift build` 会漏掉**测试目标**的警告：那条 `try` 加在非抛错的 seed(...) 上
# 就是靠 `--build-tests` 才报出来的（`ws/perfclose` 交回的第 6 条）。
# 不补这一道，"0 警告"这句话就只覆盖了一半的编译单元。
echo "==> 1/5 附：测试目标构建（同样要求 0 警告）"
xcrun swift build --build-tests --disable-sandbox 2>&1 \
    | tee "$ROOT/.build/verify-build-tests.log" \
    | grep -E "error:|warning:" && {
    echo "❌ 测试构建存在错误/警告"
    exit 1
} || true
xcrun swift build --build-tests --disable-sandbox >/dev/null 2>&1 || { echo "❌ 测试目标构建失败"; exit 1; }
echo "✅ 测试目标构建通过，无错误无警告"

echo
echo "==> 2/5 swift test"
# 完整输出落盘，终端只给尾部；**失败时必须把失败的用例名打出来**。
# 原先写成 `swift test | tail -25`：套件一大、失败行后面还跟着几十行通过行，
# 名字就被尾巴切掉了 ⇒ 门禁红了却没人知道是哪条，只能整个重跑一次（2026-09-21 就吃了这个亏）。
TEST_LOG="$ROOT/.build/verify-test.log"
if xcrun swift test --disable-sandbox > "$TEST_LOG" 2>&1; then
    tail -12 "$TEST_LOG"
    echo "✅ 测试通过"
else
    echo "❌ swift test 失败。失败的用例与问题记录："
    grep -E "✘|✖|Issue recorded|error:|failed after" "$TEST_LOG" | head -30
    echo "（完整输出：.build/verify-test.log）"
    exit 1
fi

echo
echo "==> 3/5 quiet 设计棘轮（只拦新增违规，存量见 Scripts/quiet-design-baseline.txt）"
# 为什么进自检：`gate-quiet-design.sh` 三条门禁以前没有任何 CI 引用它 —— 没人跑的门禁
# 等于没有门禁，ADR-0008 的禁令正是这样一路烂回去的。存量违规（6 个自绘轴文件、5 处禁令命中）
# 记成基线由 ws/uiclose 慢慢清，**新写的代码再加一类就当场红**。
bash Scripts/ratchet-quiet-design.sh || exit 1

echo
echo "==> 4/5 个人绝对路径（合成主体口径：本机目录布局不许写进仓）"
# 为什么进自检：这条此前**只有** `make-public-release.sh` 自检② 查，而那脚本只在公开发布前跑。
# 结果 `ws/uiclose` 交进来的一条用例带着 12 处真实 `/Users/<用户名>/…` 一路过了双构建 + 1 179 条
# 测试 + 棘轮，main 绿着却把本机布局固化进了公开产物。⇒ 低频门禁挡不住高频写入，
# 必须挪到每次合入都跑的地方。
# 用 `git grep` 而不是 `grep -rn`：只查**被跟踪**的文件，天然排除 tmp/、.build/，
# 也避开 worktree 那个 `.git` 指针文件的稳定误报。检索串写成字符类，本脚本自身不被自己命中。
NEEDLE='/[U]sers/one'
PATH_HITS="$(git grep -I -n -- "$NEEDLE" 2>/dev/null || true)"
if [ -z "$PATH_HITS" ]; then
    echo "  ―  被跟踪文件里 0 处个人绝对路径"
else
    echo "❌ 个人绝对路径 $(printf '%s\n' "$PATH_HITS" | grep -c .) 处（含注释，注释同样算）："
    printf '%s\n' "$PATH_HITS" | sed 's/^/     /'
    echo "   改法见 Sources/AIObservatoryTestSupport/FixturePaths.swift 头注释："
    echo "   只参与比较的用合成值（/Users/dev/…）、要落盘的用 Scratch、断言家目录语义的才留 NSHomeDirectory()。"
    exit 1
fi

echo
echo "==> 5/5 Tools/UIProbe 探针必须还能类型检查（收编进来的仪器不许烂在仓里）"
# 为什么进自检（#94）：`keyboard-nav.swift` 本轮被正式收编进主线树，而 `Tools/UIProbe/*.swift`
# **不在 `Package.swift` 里**（它们是独立编译的探针）⇒ 上面两次构建一个都不编它们。
# 不补这一道，"收编"就只是把一颗没人检查的探针从 tmp/ 搬进仓——那是本仓最恨的形状（门禁在、射程不在）。
# 代价量过：12 个文件全跑一遍 ~2.5 s（模块缓存命中后单个 0.15–0.35 s）。
PROBE_TOTAL=0
PROBE_FAIL=""
for probe in Tools/UIProbe/*.swift; do
    [ -e "$probe" ] || continue
    PROBE_TOTAL=$((PROBE_TOTAL + 1))
    if ! probe_output="$(xcrun swiftc -typecheck "$probe" 2>&1)"; then
        PROBE_FAIL="${PROBE_FAIL}${probe}
"
        printf '%s\n' "$probe_output" | sed 's/^/     /'
    fi
done
if [ -n "$PROBE_FAIL" ]; then
    echo "❌ 这些探针编不过（它们不在 SwiftPM 的射程里，只有这一道会发现）："
    printf '%s' "$PROBE_FAIL" | sed 's/^/   /'
    exit 1
fi
echo "  ―  ${PROBE_TOTAL} 个探针全部 typecheck 通过"

echo
echo "🎉 自检全部通过，可以交付合并"
