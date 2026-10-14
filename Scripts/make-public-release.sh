#!/usr/bin/env bash
#
# ============================================================================
# Scripts/make-public-release.sh — 产出「可公开」的压扁仓库副本 + 四道发布前自检
#
# 自检④（图像资产）是**故意**要人签字的：grep 查不到渲染进像素的路径。
#
# Owner: WS-Packaging
# 用法: Scripts/make-public-release.sh            # 跑完自动删除副本
#       AIX_KEEP_OUTPUT=1 Scripts/make-public-release.sh   # 保留副本继续手工查
#
# ---------------------------------------------------------------------------
# 为什么要压扁（不是历史洁癖，是隐私事故预防）
# ---------------------------------------------------------------------------
# ADR-0005（AiX-Vault/04-决策记录/ADR-0005-公开历史的个人邮箱处置.md）的事实基线：
#
#     git log --all --format='%ae' | sort | uniq -c
#     → 117 个提交，100% 是同一个个人邮箱（作者名 `one`，QQ 号码邮箱）
#
# 本项目是一个**隐私/审计产品**。把这条历史推上公网，等于把作者的私人邮箱公开 117 次，
# 而 git 历史不可撤回（镜像、爬虫、archive 会留在别处）。LICENSE 里不写邮箱
# **不等于**不泄漏 —— 那正是 ADR-0005 记录的误区。
#
# 三个方案里 ADR 选了 B：
#   A. `git filter-repo --mail-map` —— 要装外部工具（本机没有，且纪律禁止静默装依赖）；
#   B. **公网只推压扁后的单一初始提交**，本地全量历史留在私有仓继续做审计与 blame；  ← 本脚本
#   C. 明确接受公开 —— 不可逆，且对隐私产品是自相矛盾。
#
# 代价与补偿：外部贡献者看不到内部演进；演进过程在 Obsidian 库 `03-进度日志/` 里另有记录。
# ADR-0005 §2 要求公开副本自带一份说明 —— 本脚本会在缺 `NOTICE` 时生成一份。
#
# ---------------------------------------------------------------------------
# 边界（硬性）
# ---------------------------------------------------------------------------
# · **只读**源仓库：不 commit、不 rebase、不 filter-branch、不 push、不建 remote。
#   压扁发生在 tmp 里的**副本**上，源仓库历史一个字节都不动。
# · 产出只落在 $ROOT/tmp/public-release/（`tmp/` 已在 .gitignore 里，脚本会断言）。
# · 唯一的 git 写操作发生在副本内部的独立 .git 上。
# · 不碰源仓库的 .build：第③道自检在副本自己的 .build 里构建。
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 公开副本里那条唯一提交用的身份。默认是**占位主体**，与 ADR-0005 §3 一致：
# 用户明确提供一个愿意公开的地址之后，用 AIX_PUBLISH_EMAIL 覆盖再推。
PUBLISH_NAME="${AIX_PUBLISH_NAME:-AiX Project Authors}"
PUBLISH_EMAIL="${AIX_PUBLISH_EMAIL:-noreply@aixproject.invalid}"
# 绝对禁止把源仓库里那个个人邮箱带进副本（自检 ① 会验，这里先做一道更早的拦截）。
# 用 awk 而不是 head 取第一条：head 提前关管道会在 pipefail 下把上游变成失败。
BLOCKED_EMAIL="${AIX_BLOCKED_EMAIL:-$(git -C "$ROOT" log --all --format='%ae' 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1{print $2}' || true)}"

SRC_REV="${AIX_SRC_REV:-HEAD}"
OUT_ROOT="$ROOT/tmp/public-release"
WORK="$OUT_ROOT/public"
LOG_DIR="$OUT_ROOT/logs"

# 自检 ② 用的检索串。写成字符类是为了让这个文件自身不含那个字面量
# （否则它自己就会被自己的检查命中，也和 ci.yml 里 G1–G4 的处理方式一致）。
PATH_NEEDLE='/[U]sers/one'

die()  { printf '\n❌ %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    ⚠️  %s\n' "$*"; }
ok()   { printf '    ✅ %s\n' "$*"; }
bad()  { printf '    ❌ %s\n' "$*"; }

# 只允许删 $OUT_ROOT 下的顶层目录，别的形态一律拒绝（防止变量为空时误删）。
rm_rf_within_out_root() {
    local target="${1:-}"
    case "$target" in
        "$OUT_ROOT"/*)
            [ -n "$OUT_ROOT" ] && [ "$OUT_ROOT" != "$ROOT" ] && [ "$OUT_ROOT" != "/" ] \
                || die "拒绝删除：OUT_ROOT 异常（$OUT_ROOT）"
            rm -rf -- "$target" ;;
        ""|"$OUT_ROOT") die "拒绝删除：目标为空或等于 OUT_ROOT" ;;
        *) die "拒绝删除产出目录之外的路径：$target" ;;
    esac
}

# ============================================================================
# 0 前置断言
# ============================================================================
step "0/5 前置断言（源仓库只读、产出目录被忽略）"
cd "$ROOT"

git rev-parse --git-dir >/dev/null 2>&1 || die "不在 git 仓库里：$ROOT"

# 产出目录必须在忽略列表里，否则副本会被源仓库看见、甚至被误提交。
# 注意用 git-common-dir：工作树里的 .git 是个文件，不是目录，直接拼 .git/info/exclude 会写错地方。
if ! git check-ignore -q "$OUT_ROOT"; then
    EXCLUDE="$(git rev-parse --git-common-dir)/info/exclude"
    echo "    （登记到 $EXCLUDE —— 只影响本地，不修改任何被跟踪文件）"
    mkdir -p "$(dirname "$EXCLUDE")"
    grep -qxF 'tmp/' "$EXCLUDE" 2>/dev/null || printf 'tmp/\n' >> "$EXCLUDE"
    git check-ignore -q "$OUT_ROOT" || die "产出目录 $OUT_ROOT 未被忽略；拒绝在会污染工作树的地方写文件"
fi
note "产出目录已被忽略: ${OUT_ROOT#"$ROOT"/}"

if [ -n "$(git status --porcelain)" ]; then
    warn "源工作树不干净；导出用的是 $SRC_REV 这个**提交**，未提交的改动不会进副本："
    git status --porcelain | sed 's/^/       /' | head -6
fi

note "源仓库  : $ROOT"
note "导出修订 : $(git rev-parse --short "$SRC_REV")  ($(git log -1 --format=%s "$SRC_REV" | cut -c1-60))"
note "源历史  : $(git rev-list --count "$SRC_REV") 个提交，作者邮箱分布："
git log --all --format='%ae' | sort | uniq -c | sed 's/^/       /'
note "副本身份: $PUBLISH_NAME <$PUBLISH_EMAIL>"
if [ -n "$BLOCKED_EMAIL" ]; then note "禁止出现在副本: $BLOCKED_EMAIL"; fi
if [ "$PUBLISH_EMAIL" = "$BLOCKED_EMAIL" ]; then
    die "AIX_PUBLISH_EMAIL 不能就是源仓库里那个个人邮箱"
fi

# ADR-0005 副作用清单：压扁会不会打断依赖 git 元数据的东西。
step "0b/5 依赖 git 元数据的代码（压扁后是否会失效）"
GIT_META="$(grep -rn 'git describe\|git rev-list\|git log --pretty\|git show -s' \
              Scripts Packaging Resources .github/workflows 2>/dev/null || true)"
if [ -n "$GIT_META" ]; then
    warn "以下位置读 git 元数据，压扁后要人工确认："
    printf '%s\n' "$GIT_META" | sed 's/^/       /'
else
    ok "Scripts/Packaging/.github 里没有任何按 git describe / git log 生成版本号的地方"
fi
note "（实测参考：Scripts/verify.sh 与 Scripts/merge-workstream.sh 只读当前分支名与 ref 是否存在，"
note "  不读提交数量或哈希 ⇒ 压扁不影响它们。）"

# ============================================================================
# 1 导出 + 压扁
# ============================================================================
step "1/5 导出工作树并生成单一初始提交"
if [ -d "$WORK" ]; then rm_rf_within_out_root "$WORK"; fi
mkdir -p "$WORK" "$LOG_DIR"

# git archive 只打包**被跟踪**的文件 ⇒ .build / dist / tmp / observatory-data /
# .scratch-tests 天然不会进副本。
FILE_COUNT="$(git archive "$SRC_REV" | tar -t | grep -cv '/$' || true)"
git archive "$SRC_REV" | tar -x -C "$WORK"
note "副本文件数: $FILE_COUNT（源仓库跟踪的文件全集）"

[ -f "$WORK/LICENSE" ] || die "副本里没有 LICENSE —— 缺许可证的公开等于「保留所有权利」"
[ -f "$WORK/.gitignore" ] || warn "副本没有 .gitignore；贡献者的构建产物可能被提交"

# ADR-0005 §2：公开副本要自带一份说明，讲清楚「历史去哪了」。
if [ ! -f "$WORK/NOTICE" ]; then
    cat > "$WORK/NOTICE" <<'NOTICE'
AiX
Copyright 2026 AiX Project Authors

This is the public release of the project, distributed under the Apache License,
Version 2.0 (see LICENSE).

Note on history: this repository intentionally starts from a single squashed
commit. The internal development history (including per-workstream review and
decision records) is kept out of the public repository on purpose, because it
contains author identities that were never intended to be published.
Consequently `git blame` and `git log` here are not an audit trail; the
engineering rationale for individual changes lives in the documentation under
Documentation/ (start with README.md, SECURITY.md and PRIVACY.md).
NOTICE
    note "已生成 NOTICE（ADR-0005 §2 要求的「历史去哪了」说明）"
fi

git -C "$WORK" init -q -b main
git -C "$WORK" add -A
git -C "$WORK" -c user.name="$PUBLISH_NAME" -c user.email="$PUBLISH_EMAIL" \
    commit -q -F - <<MSG
Initial open-source release

Squashed public release of AiX — a 100% local,
zero-upload macOS 26 auditor for AI agent activity (Codex / Claude Code /
Cursor Agent).

Development history is deliberately not published: every internal commit
carried a private author e-mail, and publishing it would leak it
irreproducibly. See the repository's NOTICE file.

License: Apache-2.0 (see LICENSE).
MSG
note "副本历史: $(git -C "$WORK" rev-list --count HEAD) 个提交（预期 1）"

# ============================================================================
# 2 自检① 作者邮箱
# ============================================================================
step "2/5 自检①：副本里只允许出现一个邮箱，且它不是那个个人邮箱"
FAILS=0
EMAILS_LIST="$(git -C "$WORK" log --all --format='%ae' | sort -u)"
EMAILS_N="$(printf '%s\n' "$EMAILS_LIST" | grep -c . || true)"
printf '%s\n' "$EMAILS_LIST" | sed 's/^/       /'
note "唯一邮箱数: $EMAILS_N"
if [ "$EMAILS_N" = "1" ] && ! printf '%s\n' "$EMAILS_LIST" | grep -qxF "$BLOCKED_EMAIL"; then
    ok "自检①通过：单一邮箱且不含源仓库的个人邮箱"
else
    bad "自检①失败：期望 1 个非个人邮箱，实际 $EMAILS_N 个"
    FAILS=$((FAILS + 1))
fi
# ①-b：历史干净不等于副本干净——文档正文里**抄写**过那个邮箱，压扁是查不出来的
# （Documentation/OPEN-SOURCE.md §9 记过这条同源泄漏，原先只有人工两道跑）。
if [ -n "$BLOCKED_EMAIL" ]; then
    BODY_HITS="$(cd "$WORK" && grep -rl --exclude-dir=.build --exclude-dir=.git -F "$BLOCKED_EMAIL" . 2>/dev/null || true)"
    if [ -z "$BODY_HITS" ]; then
        ok "自检①-b通过：副本文件正文里也没有抄写过那个个人邮箱"
    else
        bad "自检①-b失败：以下文件正文里抄写了源仓库的个人邮箱"
        printf '%s\n' "$BODY_HITS" | sed 's/^/       /'
        FAILS=$((FAILS + 1))
    fi
else
    warn "自检①-b 跳过：没能从源历史里取到待禁邮箱（AIX_BLOCKED_EMAIL 可显式提供）"
fi

# ============================================================================
# 3 自检② 绝对个人路径
# ============================================================================
step "3/5 自检②：副本里 grep -rn \"$PATH_NEEDLE\"（去注释外的一切命中都算泄漏本机布局）"
HITS_FILE="$LOG_DIR/personal-paths.txt"
( cd "$WORK" && grep -rn "$PATH_NEEDLE" --exclude-dir=.build --exclude-dir=.git . \
    > "$HITS_FILE" 2>/dev/null || true )
HITS_TOTAL="$(grep -c . "$HITS_FILE" || true)"
HITS_FILES="$(cut -d: -f1 "$HITS_FILE" 2>/dev/null | sort -u | grep -c . || true)"
note "命中 $HITS_TOTAL 行 / $HITS_FILES 个文件"
if [ "$HITS_TOTAL" = "0" ]; then
    ok "自检②通过：副本里没有任何绝对个人路径"
else
    bad "自检②失败：推上去就等于发布本机目录布局。按归属拆分："
    cut -d: -f1 "$HITS_FILE" | sort | uniq -c | sort -rn | sed 's/^/       /'
    note "全清单: ${HITS_FILE#"$ROOT"/}"
    FAILS=$((FAILS + 1))
fi

# ============================================================================
# 4 自检③ 副本能构建且零警告
# ============================================================================
step "4/5 自检③：在副本里 swift build（--disable-sandbox），要求零错误零警告"
BUILD_LOG="$LOG_DIR/build.log"
BUILD_RC=0
# 用 if 包一层：`set -e` 下直接写 `( … ); RC=$?` 会在构建失败时先退出脚本，
# 拿不到失败原因也就打印不出「压扁丢了什么」。
if ! ( cd "$WORK" && xcrun swift build --disable-sandbox ) > "$BUILD_LOG" 2>&1; then
    BUILD_RC=1
fi
BUILD_WARN="$(grep -c 'warning:' "$BUILD_LOG" || true)"
note "swift build 退出码: $BUILD_RC   （日志: ${BUILD_LOG#"$ROOT"/}）"
tail -3 "$BUILD_LOG" | sed 's/^/       /'
if [ "$BUILD_RC" = "0" ] && [ "$BUILD_WARN" = "0" ]; then
    ok "自检③通过：副本独立可构建，零警告（压扁没有丢文件）"
elif [ "$BUILD_RC" != "0" ]; then
    bad "自检③失败：副本构建不过 —— 压扁过程丢了东西，看日志："
    grep -E "error:|No such file|missing" "$BUILD_LOG" | head -10 | sed 's/^/       /'
    FAILS=$((FAILS + 1))
else
    bad "自检③失败：$BUILD_WARN 条警告（AGENTS.md 第 4 节：零警告才算完成）"
    grep "warning:" "$BUILD_LOG" | head -10 | sed 's/^/       /'
    FAILS=$((FAILS + 1))
fi

# ============================================================================
# 5 自检④ 图像资产：机器只查得到"存成文本"的路径，像素必须人眼过一遍
# ============================================================================
step "5/6 自检④：图像/二进制资产（grep 对像素是半盲的 ⇒ 这一道要人签字）"
MANIFEST="$LOG_DIR/image-assets.txt"
: > "$MANIFEST"
ASSET_N=0
IMG_META_HITS=0
# 用进程替换而不是管道：管道会让循环体跑在子 shell 里，累加计数出来全是 0。
while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    ASSET_N=$((ASSET_N + 1))
    digest="$(shasum -a 256 "$WORK/$asset" | awk '{print $1}')"
    printf '%s  %s\n' "$digest" "$asset" >> "$MANIFEST"
    if grep -qa "$PATH_NEEDLE" "$WORK/$asset" 2>/dev/null; then
        bad "自检④：$asset 的**元数据**里含本机绝对路径（EXIF/XMP/ICC 这类文本 chunk）"
        IMG_META_HITS=$((IMG_META_HITS + 1))
    fi
done < <(git -C "$WORK" ls-files | grep -Ei '\.(png|jpe?g|gif|icns|ico|pdf|mov|mp4|svg)$' || true)

ATTEST_TOKEN=""
if [ "$ASSET_N" = "0" ]; then
    ok "副本里没有图像/二进制资产 ⇒ 自检④ 空过（这条不算「通过」，算「没有要看的对象」）"
elif [ "$IMG_META_HITS" != "0" ]; then
    bad "自检④失败：$IMG_META_HITS/$ASSET_N 个图像资产的元数据带本机路径，必须先换图"
    FAILS=$((FAILS + 1))
else
    note "上面那半边只证明**没存成文本**。渲染进像素的路径 grep 结构上查不到："
    note "实拍教训——首页图底部那行「识别：可执行文件路径 …」grep 0 命中，人眼一眼看见。"
    note "所以这一道必须逐张**打开看**：真实项目目录名、用户名、会话标题、"
    note "终端里敲过的命令，全都会以像素的形式留在图上。"
    sed 's/^/       /' "$MANIFEST"
    ATTEST_TOKEN="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
    if [ "${AIX_EYEBALL_ATTEST:-}" = "$ATTEST_TOKEN" ]; then
        ok "自检④通过：$ASSET_N 个图像资产已逐张人眼复核（签署 $ATTEST_TOKEN）"
    else
        bad "自检④未完成：$ASSET_N 个图像资产**没有**人眼复核签署"
        note "看完之后带摘要重跑：AIX_EYEBALL_ATTEST=$ATTEST_TOKEN Scripts/make-public-release.sh"
        note "（摘要按图的内容算：任何一张图变了，上一次的签署自动失效，蒙不过这一轮）"
        FAILS=$((FAILS + 1))
    fi
fi

# ============================================================================
# 6 汇总
# ============================================================================
step "6/6 汇总"
printf '    %-4s %s\n' "①" "作者邮箱唯一且非个人地址"
printf '    %-4s %s\n' "②" "无绝对个人路径（实测命中 $HITS_TOTAL 行 / $HITS_FILES 文件）"
printf '    %-4s %s\n' "③" "副本可构建且零警告"
printf '    %-4s %s\n' "④" "图像资产：元数据可 grep（$ASSET_N 个）+ 像素需人眼签署${ATTEST_TOKEN:+（摘要 $ATTEST_TOKEN）}"
printf '    %-4s %s\n' "" "副本提交数: $(git -C "$WORK" rev-list --count HEAD)"

if [ "${AIX_KEEP_OUTPUT:-0}" = "1" ]; then
    warn "AIX_KEEP_OUTPUT=1 → 保留副本：${WORK#"$ROOT"/}"
else
    rm_rf_within_out_root "$OUT_ROOT"
    note "已删除副本与日志（$OUT_ROOT）；要看明细请加 AIX_KEEP_OUTPUT=1"
fi

if [ "$FAILS" = "0" ]; then
    printf '\n✅ 四道自检全部通过。推送仍需用户明确同意（ADR-0005 §4，本脚本不 push）。\n'
    exit 0
fi
printf '\n❌ %d 项自检未通过 ⇒ 现在**不能**公开。逐条归属见上面的文件分布。\n' "$FAILS"
exit 1
