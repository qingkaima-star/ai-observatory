#!/usr/bin/env bash
#
# ============================================================================
# Packaging/make-app.sh — 唯一打包入口：把 SwiftPM 可执行文件组装成可分发的 .app bundle
#
# Owner: WS-Packaging
# 用法: Packaging/make-app.sh
#
# 这个脚本必须保持的不变量（改动前先读懂为什么，别退回反例）：
#   1  Info.plist 只有一个真值源 = Packaging/Info.plist 拷进 bundle，
#      不在 shell 里用 heredoc + 变量插值现写（元数据要能被 `plutil -lint/-p` 独立审阅）。
#   2  写 Contents/PkgInfo：4 字节包类型 + finder 签名，APPL 包该有的类型指纹。
#   3  Resources/PrivacyInfo.xcprivacy → Contents/Resources/（存在才拷，缺失如实警告，
#      绝不伪造一个空文件充数）。
#   4  CFBundleIconFile 只在真的有 .icns 时才写（指向不存在的文件比不写更糟，
#      见 Packaging/Info.plist 的对应注释块）。
#      ⚠️ 这条不变量早期曾写着"当前仓库零图标资源 ⇒ 两个键都不出现"——那是**过去**的状态，
#      图标已在 #24 补进 `Packaging/AppIcon.icns`，现在 `:210-222` 会真的写这两个键，
#      并由 `dist/build-info.txt` 的 `icon : yes` 自证。留这句话在这里是为了说明
#      "为什么脚本注释和实际行为曾经不一致"，不是让人以为仍然没有图标。
#   5  签名必须传 --entitlements，并把「实际签进去的是什么」打印出来 ——
#      唯一可信证据是 `codesign -d --entitlements -` 的输出，不是磁盘上的那份 plist。
#      BASE 档是**有意空 dict**，理由见 Packaging/ENTITLEMENTS-NOTES.md 第 1 节。
#   6  不用已弃用的 --deep：内层→外层逐个签（单可执行文件包内层 0 个属正常）。
#   7  **签名与签名校验失败必须硬失败**：非零退出 + 报错行。
#      永不允许 `2>/dev/null || echo "（跳过签名）"` 这类写法 —— 三处叠加时
#      （吞 stderr、吞退出码、--deep）会让一个未签名的包打印 ✅ 产出。
#   8  --timestamp 显式给值（ad-hoc 用 none：安全时间戳要走 OCSP 联网，且 ad-hoc
#      身份下签了也没有信任价值）。本脚本可完全离线跑完。
#   9  验证结果全部打印，并区分「预期失败」与「真失败」：codesign --verify --strict、
#      codesign -d（身份 / flags / entitlements）、spctl -a、plutil -lint + -p。
#      ad-hoc 包被 Gatekeeper 拒是**预期**（无 Developer ID、无公证），不是缺陷；
#      但 `spctl` 与「启动即 SIGKILL」是两层不同的事，见 ENTITLEMENTS-NOTES.md 第 2.2 节。
#  10  写 dist/build-info.txt：版本、最低系统、签名身份、entitlements 档位、清单/图标有无、
#      exe 与 plist 的 SHA-256 —— 只用于「同一个人核对自己刚构建的包」，不是发布渠道。
#  11  任何 rm -rf 都经 rm_rf_within_dist 守卫：路径不在 $DIST/*.app 形态内即拒绝。
#  12  构建前用 plutil -extract 校验 plist 的 CFBundleExecutable / CFBundleIdentifier
#      与本脚本常量一致 —— 挡住「改名后 App 静默退化到开发期数据路径」（ADR-0003）。
#  13  --disable-sandbox 参数化为 AIX_SPM_SANDBOX_FLAG：本地必须带（外层已在 sandbox 内），
#      CI 上显式传空串还原 SwiftPM 默认行为（口径见 Documentation/INSTALL.md）。
#
# 边界：只写 $ROOT/dist/ 内。无 sudo、无网络、不碰 Sources/ 与 Tests/。
# ============================================================================
set -euo pipefail

# ---- 常量 ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="AIObservatory"          # = Package.swift:26 的 executable product 名
BUNDLE_ID="com.aix.aiobservatory" # = DataLocation.swift:36 的判定串，不可漂移

PLIST_SRC="$ROOT/Packaging/Info.plist"
ENT_BASE="$ROOT/Packaging/Observatory-App.entitlements"
ENT_ES="$ROOT/Packaging/Observatory-App-Optional-EndpointSecurity.entitlements"
PRIVACY_SRC="$ROOT/Resources/PrivacyInfo.xcprivacy"

# 产物目录：允许外部指定，但**必须**落在仓库内。
DIST="${AIX_DIST_DIR:-$ROOT/dist}"

# 签名身份与开关（默认全部是"本地 ad-hoc"这一条最保守的路）。
SIGN_IDENTITY="${AIX_SIGN_IDENTITY:--}"                 # '-' = ad-hoc
HARDENED_RUNTIME="${AIX_HARDENED_RUNTIME:-0}"           # 1 才加 --options runtime，见第 5 步注释
TIMESTAMP="${AIX_SIGN_TIMESTAMP:-none}"                 # ad-hoc 用 none；Developer ID + 联网可改 secure
USE_ES_ENTITLEMENTS="${AIX_ES_ENTITLEMENTS:-0}"         # 1 = 签可选 ES 档（默认 BASE）

# ---- 输出helper ------------------------------------------------------------
die()  { printf '\n❌ %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    ⚠️  %s\n' "$*"; }

# ---- 安全守卫 --------------------------------------------------------------
# 任何删除都必须落在 $DIST 下的 *.app，否则拒绝。防的是变量未展开/被覆盖成
# 家目录之类灾难（$DIST 为空或为 / 时也不会误删）。
rm_rf_within_dist() {
    local target="$1"
    case "$target" in
        "$DIST"/*.app) [ -n "$DIST" ] && [ "$DIST" != "/" ] && rm -rf -- "$target" ;;
        *) die "拒绝删除 dist 之外的路径：$target" ;;
    esac
}

# ============================================================================
# 0/6 前置校验：元数据自洽
# ============================================================================
step "0/6 前置校验"
cd "$ROOT"

case "$DIST" in
    "$ROOT"/*) ;;
    *) die "AIX_DIST_DIR 必须位于仓库内（当前：$DIST）。本工作流禁止向仓库外写入。" ;;
esac
note "仓库根 : $ROOT"
note "产物目录: $DIST"

[ -f "$PLIST_SRC" ] || die "缺少 $PLIST_SRC"

# entitlements 必须是合法 plist，且 BASE 档应为空 dict（这是设计而非遗漏）。
for ent in "$ENT_BASE" "$ENT_ES"; do
    [ -f "$ent" ] || die "缺少 $ent"
    plutil -lint "$ent" >/dev/null || die "entitlements 不是合法 plist: $ent"
done

plutil -lint "$PLIST_SRC" >/dev/null || die "Info.plist 不是合法 plist: $PLIST_SRC"

plist_get() { plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; }

ACTUAL_EXEC="$(plist_get CFBundleExecutable "$PLIST_SRC")"
ACTUAL_BID="$(plist_get CFBundleIdentifier "$PLIST_SRC")"
[ "$ACTUAL_EXEC" = "$APP_NAME" ] || \
    die "Info.plist CFBundleExecutable='$ACTUAL_EXEC' 与脚本常量 '$APP_NAME' 不符（SwiftPM 产品名，见 Package.swift:26）"
[ "$ACTUAL_BID" = "$BUNDLE_ID" ] || \
    die "Info.plist CFBundleIdentifier='$ACTUAL_BID' 与脚本常量 '$BUNDLE_ID' 不符 —— 该值被 DataLocation.swift:36 用来判定正式运行，漂移会让数据库静默落到仓库内 observatory-data/（ADR-0003）"
note "身份自洽: $ACTUAL_EXEC / $ACTUAL_BID ✅"

if [ "$USE_ES_ENTITLEMENTS" = "1" ]; then
    ENT_SELECTED="$ENT_ES"
    warn "选中**可选** EndpointSecurity 档：$ENT_ES"
    warn "  该 entitlement 需向 Apple 申请；ad-hoc 签名不会授予它。"
    warn "  ⚠️ 实测（2026-09-19）：这样签出来的包**启动即被 AMFI SIGKILL（退出码 137）**，"
    warn "     不是「降级为轮询」—— 因为进程声明了它拿不到的受控 entitlement。"
    warn "     签名验证仍会通过（codesign 只看自洽性），所以别把 ✅ 当成可用。"
    warn "     控制实验与机理：Packaging/ENTITLEMENTS-NOTES.md 第 2.2 节。"
else
    ENT_SELECTED="$ENT_BASE"
    note "entitlements: $ENT_BASE（BASE 档；**有意为空 dict**，"
    note "  理由见 Packaging/ENTITLEMENTS-NOTES.md 第 1 节 —— 论证不能写进 .entitlements，见下）"
fi

# ⚠️ 维护约束（负责人 2026-09-19 实测）：`codesign --entitlements` 用 AMFI 的严格
# 解析器读该文件，**不接受 XML 注释**。带注释的 entitlements 能通过 `plutil -lint`
# 却在签名时炸：`Failed to parse entitlements: AMFIUnserializeXML: syntax error`。
# ⇒ 两份 .entitlements 必须是纯 dict；一切说明写进 Packaging/ENTITLEMENTS-NOTES.md。
#    （Info.plist 不受此限制，LaunchServices 容忍注释，故那里的决策注释保留。）

# ============================================================================
# 1/6 构建 release
# ============================================================================
step "1/6 构建 release（$APP_NAME）"

# `--disable-sandbox` 是**本地执行环境**的权宜：本仓库的开发执行环境本身已运行在
# sandbox 内，SwiftPM 再嵌套一层 sandbox-exec 会直接失败并报
# `sandbox_apply: Operation not permitted`（ADR-0001 第 6 条、
# Documentation/README.md「为什么本地必须带 --disable-sandbox」）。
# 公开 CI 的 runner 没有外层 sandbox，**不需要**这个 flag；在那里加它属于多余，
# 且会掩盖真实的沙箱兼容性回归。CI 上以 `AIX_SPM_SANDBOX_FLAG=` （显式空串）
# 调用本脚本即可还原 SwiftPM 默认行为。
if [ -z "${AIX_SPM_SANDBOX_FLAG+x}" ]; then
    SPM_SANDBOX_FLAG="--disable-sandbox"
else
    SPM_SANDBOX_FLAG="$AIX_SPM_SANDBOX_FLAG"
fi

SPM_FLAGS=()
if [ -n "$SPM_SANDBOX_FLAG" ]; then
    SPM_FLAGS+=("$SPM_SANDBOX_FLAG")
    note "SwiftPM flag: $SPM_SANDBOX_FLAG"
else
    note "SwiftPM flag: （无 —— 按 CI 形态运行）"
fi

BIN=""
if [ "${AIX_SKIP_BUILD:-0}" = "1" ]; then
    warn "AIX_SKIP_BUILD=1：跳过编译，复用既有 release 产物"
else
    xcrun swift build "${SPM_FLAGS[@]}" -c release --product "$APP_NAME"
fi

BIN_DIR="$(xcrun swift build "${SPM_FLAGS[@]}" -c release --product "$APP_NAME" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || die "未找到可执行文件 $BIN"
note "可执行文件: $BIN"

# ============================================================================
# 2/6 组装 bundle 骨架
# ============================================================================
step "2/6 组装 bundle"
APP="$DIST/$APP_NAME.app"
mkdir -p "$DIST"
if [ -e "$APP" ]; then
    rm_rf_within_dist "$APP"
    note "清理旧 bundle: $APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod 0755 "$APP/Contents/MacOS/$APP_NAME"

# PkgInfo：4 字节包类型 + 4 字节 finder 签名，LaunchServices 在 Info.plist 之外
# 识别 APPL 包的传统类型指纹（不变量 #2）。
printf 'APPL????' > "$APP/Contents/PkgInfo"
note "Contents/PkgInfo 已写入 (APPL????)"

# ============================================================================
# 3/6 元数据与资源
# ============================================================================
step "3/6 Info.plist 与资源"
PLIST_DST="$APP/Contents/Info.plist"
cp "$PLIST_SRC" "$PLIST_DST"
note "Info.plist ← Packaging/Info.plist（保留其中的决策注释；LaunchServices 忽略 XML 注释）"

# 版本：真值在 plist；只有构建者显式传变量时才覆写，且如实打印改前/改后。
for pair in "CFBundleShortVersionString:${AIX_SHORT_VERSION:-}" "CFBundleVersion:${AIX_BUILD_VERSION:-}"; do
    key="${pair%%:*}"
    val="${pair#*:}"
    if [ -n "$val" ]; then
        old="$(plist_get "$key" "$PLIST_DST")"
        plutil -replace "$key" -string "$val" "$PLIST_DST"
        note "$key: $old → $val（构建变量覆写）"
    fi
done
note "版本: $(plist_get CFBundleShortVersionString "$PLIST_DST") (build $(plist_get CFBundleVersion "$PLIST_DST"))"

# 图标：存在才拷、才写 CFBundleIconFile；否则两个键都不出现。
# （资源已于 2026-09-20 落地：Packaging/AppIcon.icns，由 Packaging/make-icon.swift 重建。）
ICON_SRC=""
for cand in "$ROOT/Packaging/AppIcon.icns" "$ROOT/Resources/AppIcon.icns"; do
    if [ -f "$cand" ]; then ICON_SRC="$cand"; break; fi
done
if [ -n "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
    plutil -replace CFBundleIconFile -string "AppIcon" "$PLIST_DST"
    note "图标: $(basename "$ICON_SRC") → Contents/Resources/AppIcon.icns，已写 CFBundleIconFile"
else
    warn "未发现 AppIcon.icns → 不写 CFBundleIconFile（指向不存在的文件比不写更糟）"
fi

# 隐私清单：由并行子代理交付；缺失时如实报告而不是静默跳过、也不是造一个空文件。
if [ -f "$PRIVACY_SRC" ]; then
    cp "$PRIVACY_SRC" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
    note "隐私清单: PrivacyInfo.xcprivacy → Contents/Resources/"
else
    warn "缺少 $PRIVACY_SRC → 产物不含隐私清单（脚本不伪造一个空文件）"
    warn "  影响：App Store 提交/公证会被拒；本地 ad-hoc 运行无功能影响。不阻塞本脚本。"
fi

plutil -lint "$PLIST_DST" >/dev/null || die "落盘后的 Info.plist 非法"
plutil -p "$PLIST_DST" | sed 's/^/    │ /'

# ============================================================================
# 4/6 签名（内层 → 外层，不使用已弃用的 --deep）
# ============================================================================
step "4/6 签名"

# SwiftPM 产物是"单个可执行文件 + 无嵌套代码"，所以下面通常 0 个内层对象；
# 逻辑保留是为了：**一旦**将来出现 Frameworks/PlugIns/XPC，签名顺序仍然正确。
# 主可执行文件（Contents/MacOS/*）不单独签 —— 它随 bundle 一起签，
# 先签它再签 bundle 会让内层签名失效（这正是 --deep 的语义问题之一）。
NESTED="$(find "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" "$APP/Contents/XPCServices" \
              -maxdepth 3 \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.bundle' \) \
              2>/dev/null || true)"
inner_count=0
while IFS= read -r item; do
    [ -n "$item" ] || continue
    inner_count=$((inner_count + 1))
    note "内层签名: ${item#"$APP"/}"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp="$TIMESTAMP" --verbose=4 "$item" \
        || die "内层签名失败: $item"
done <<EOF
$NESTED
EOF
note "内层可签名对象: $inner_count 个（单可执行文件包 = 0 属正常）"

# 外层：entitlements 随 bundle 签名嵌进主可执行文件的代码目录。
CS_ARGS=(--force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID"
         --entitlements "$ENT_SELECTED" --timestamp="$TIMESTAMP" --verbose=4)
if [ "$HARDENED_RUNTIME" = "1" ]; then
    # HR 是**签名标志位**，不是 entitlement —— 想断言"启用了 HR"只能看
    # codesign -dvvv 的 flags 里有没有 runtime，不能看 entitlements 文件。
    # libproc 观测面与 HR 全量兼容，六条 cs.* 例外一条都不需要
    # （逐项论证见 Packaging/ENTITLEMENTS-NOTES.md 第 1.3 节）。
    # 默认关闭的理由：ad-hoc 下任何人可重签去掉它，它不构成信任信号，
    # 但会削减运行时能力，需要真机单独验证一轮后再固化。
    CS_ARGS+=(--options runtime)
    note "--options runtime：开启"
else
    note "--options runtime：未开启（默认）。⇒ 不要在任何文档里声称本包启用了 Hardened Runtime。"
fi
codesign "${CS_ARGS[@]}" "$APP" || die "签名失败（见上面的 codesign 输出）—— 不变量 #7：绝不静默降级成「未签名也算成功」"

# ============================================================================
# 5/6 验证（全部打印，不隐藏；区分预期失败与真失败）
# ============================================================================
step "5/6 验证"

printf '    codesign --verify --strict:\n'
if codesign --verify --strict --verbose=4 "$APP" 2>&1 | sed 's/^/    │ /'; then
    note "签名校验通过 ✅"
else
    die "签名校验未通过（见上）"
fi

printf '    签名详情（身份 / flags / 需求）:\n'
codesign -dvvv "$APP" 2>&1 | grep -Ei "^(Identifier|Format|CodeDirectory|TeamIdentifier|Authority|Signature)" \
    | sed 's/^/    │ /' || true
if codesign -dvvv "$APP" 2>&1 | grep -q "flags=.*runtime"; then
    note "Hardened Runtime: 已生效（签名 flags 含 runtime）"
else
    note "Hardened Runtime: 未生效（flags 不含 runtime）"
fi

printf '    实际嵌入的 entitlements（这是唯一可信的"签了什么"证据）:\n'
# 用 `--entitlements -`；`--entitlements :-` 已在本机 codesign 上打印
# "Specifying ':' in the path is deprecated"（负责人 2026-09-19 实测）。
codesign -d --entitlements - "$APP" 2>&1 | sed 's/^/    │ /' || true

printf '    spctl -a（Gatekeeper 评估）:\n'
if spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/    │ /'; then
    note "Gatekeeper 放行 ✅"
else
    if [ "$SIGN_IDENTITY" = "-" ]; then
        warn "ad-hoc 包被 Gatekeeper 拒绝是**预期**结果（无 Developer ID、无公证），不是缺陷。"
        warn "  本机自产自用：无 quarantine xattr，直接 open 即可；"
        warn "  跨机分发需 Developer ID 签名 + 公证，见 Documentation/INSTALL.md 第 7 节。"
    else
        die "用了真实签名身份仍未过 spctl —— 需要排查（证书链 / timestamp / 公证）。"
    fi
fi

note "隔离属性（quarantine 会改变 Gatekeeper 行为）:"
xattr -l "$APP" 2>/dev/null | sed 's/^/    │ /' || echo "    │ （无扩展属性）"

# ============================================================================
# 6/6 制品与构建信息
# ============================================================================
step "6/6 制品信息"
BIN_DIGEST="$(shasum -a 256 "$APP/Contents/MacOS/$APP_NAME" | awk '{print $1}')"
PLIST_DIGEST="$(shasum -a 256 "$PLIST_DST" | awk '{print $1}')"
INFO="$DIST/build-info.txt"
{
    printf 'app            : %s\n' "$APP"
    printf 'bundle id      : %s\n' "$BUNDLE_ID"
    printf 'version        : %s (build %s)\n' \
        "$(plist_get CFBundleShortVersionString "$PLIST_DST")" \
        "$(plist_get CFBundleVersion "$PLIST_DST")"
    printf 'min system     : %s\n' "$(plist_get LSMinimumSystemVersion "$PLIST_DST")"
    printf 'sign identity  : %s\n' "$SIGN_IDENTITY"
    printf 'timestamp      : %s\n' "$TIMESTAMP"
    printf 'hardened runtime: %s\n' "$HARDENED_RUNTIME"
    printf 'entitlements   : %s\n' "$ENT_SELECTED"
    printf 'privacy manifest: %s\n' "$([ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ] && echo yes || echo absent)"
    printf 'icon           : %s\n' "$([ -f "$APP/Contents/Resources/AppIcon.icns" ] && echo yes || echo absent)"
    printf 'sha256 exe     : %s\n' "$BIN_DIGEST"
    printf 'sha256 plist   : %s\n' "$PLIST_DIGEST"
} > "$INFO"
cat "$INFO" | sed 's/^/    /'

printf '\n✅ 产出: %s\n' "$APP"
printf '   构建信息: %s\n' "$INFO"
printf '   运行: open "%s"\n' "$APP"
printf '   自查: codesign --verify --strict --verbose=4 "%s"\n' "$APP"
