//
//  keyboard-nav.swift — 真机「只用键盘」走查的注入件 + 焦点回读件（**验收装置，不是产品代码**）。
//
//  Owner: master-controller（开发工具，不进产品 target；不进 `Package.swift`）
//
//  为什么需要它（第 94 号格子的装置缺口）：`Tools/UIProbe/` 原本只有
//  `capture-window`（单窗口截图）/ `click-window`（鼠标点）/ `control-window`（AXPress、菜单）/
//  `scroll-window`（滚轮）/ `resize-window`（几何），**没有按键注入通道**。
//  2026-09-22 那轮"只用键盘走查九页"是本车道临时在 `tmp/uiprobe/kbd.swift` 写的一颗，
//  不入仓 ⇒ 每次都靠临时探针，不可复现。本轮把它正式收编。
//
//  编译（与其它探针同法，SwiftPM 不编 Tools/）：
//    mkdir -p tmp/uiprobe
//    swiftc -O Tools/UIProbe/keyboard-nav.swift -o tmp/uiprobe/kbdnav
//
//  用法：
//    kbdnav --focus       --pid <pid>                     # 读一次当前焦点元素
//    kbdnav --selftest    --pid <pid> [--tabs 8]          # 三件自证（见下），失败 exit=1
//    kbdnav --sweep       --pid <pid> [--max-tabs 60]     # 按 Tab 记焦点链，回环或到上限即停
//    kbdnav --pressables  --pid <pid>                     # 列该页"应有"分母（可 AXPress 的元素），逐颗打印
//    kbdnav --texts       --pid <pid> --query <子串>      # 有界遍历，打含该子串的无障碍文案（页头计数那类）
//    kbdnav --search-test --pid <pid> --query git         # 侧栏搜索框：Tab 聚焦 → 打字 → Return → Esc，三段读数
//    kbdnav --nav-test    --pid <pid> [--max-tabs 40]     # 侧栏列表容器：Tab 走到容器 → 方向键走行 → Return（判"行内靠方向键"是不是真出口）
//    kbdnav --act         --pid <pid> [--on <role>] [--key <return|space|none>]  # Tab 走到该类控件 → 按键 → 比按键前后的树快照
//                                                          #   --key none = 只把焦点**停**在那类控件上不按键（截图起点用）
//    kbdnav --tab         --pid <pid> [--repeat n]        # 注入 n 次 Tab 并逐步回读
//    kbdnav --shifttab    --pid <pid>
//    kbdnav --key         <return|esc|space|up|down> --pid <pid> [--repeat n]
//    kbdnav --type        "<文本>" --pid <pid>            # 往当前焦点里打字（侧栏搜索框键盘聚焦用）
//    kbdnav --focus-index <n> --pid <pid>                 # 程序化聚焦第 n 个可点元素（**只作旁证**，见守卫 2(3)）
//    kbdnav --axtree      --pid <pid> [--depth 24]
//
//  三条装置自带的假绿守卫（缺一条它就是"绿给自己看"）：
//  1. **前台闸门**：注入任何键之前必须确认目标 pid 就是 frontmost；不是 ⇒ exit=3 直接拒注入。
//     否则按键会打到当时最前的窗口（这台机器上同时有 IDE、别的车道的实例、`pid 45764` 那颗旧包），
//     而焦点回读"看起来"也会跟着变 ⇒ 一整份假焦点链。
//  2. **`--selftest` 三件自证**：
//     (1) `stable-reread`：不注入连读两次焦点必须同一点 —— 否则"焦点"这个读数本身就是飘的。
//     (2) `injector`：注入 Tab 之后焦点必须**离开起点并落到可 AXPress / 控件 role 的元素上**。
//         这就是"注入件对已知按钮能读到焦点变化"的正解：读得到 ≠ 键进得去，一次闸门量两件事。
//         不过 ⇒ 本轮所有 Tab 结论作废（它自己就是假绿源），也不许反过来拿它当"键盘不可达"的证据。
//     (3) 旁证（**不进闸门**）：对一颗已知按钮 `AXUIElementSetAttributeValue(kAXFocused)` 回 `err=0`
//         却**回读不命中**（2026-09-23 实测九页之前先撞到）⇒ `err=0` ≠ 聚焦成功。
//         §12.5 那条"命令页复选框能被程序化聚焦"的对照走的正是这条路，本轮订正：
//         **判"Tab 可达"只按注入 Tab 的焦点链判**，程序化聚焦降为旁证。
//  3. **回环 / 上限双停**：`--sweep` 既在"焦点回到已走过的停靠点"时停，也在 `--max-tabs` 处停，
//     并在末行明写 `环是否闭合`。到上限没回环 ⇒ 那是**有界未收敛**，不许写成"走完了"。
//     回环按 **CFEqual 对象同一性**判、不按签名判 —— 列表里逐行同字是常态，按签名会提前闭合把覆盖算高。
//
//  ⚠️ 已知的一个读数限制：SwiftUI 有时把整块卡片合成一个 `AXGroup`/`AXUnknown` 节点
//     （`Tools/UIProbe` 与 `Tests/**` 里那条"`.combine` 之后行内只有一个节点"是同一族）。
//     这时"焦点停靠点"与源码里的 `Button(` 数不是一对一 —— 所以分母一律取**无障碍树里真存在的可点元素**，
//     源码级 `Button(` / `axPressable` 计数只作为"树有没有漏数"的对照，见本文件末的注释。
//
//  退出码：0 正常；1 自证不通过；2 参数错误；3 前台闸门拒绝注入。
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 参数

var action = ""
var pid = 0
var repeatCount = 1
var typedText = ""
var keyName = ""
var depth = 24
var which = 0
var maxTabs = 60
var targetRole = "AXButton"

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--focus": action = "focus"
    case "--selftest": action = "selftest"
    case "--sweep": action = "sweep"
    case "--pressables": action = "pressables"
    case "--axtree": action = "axtree"
    case "--tab": action = "tab"
    case "--shifttab": action = "shifttab"
    case "--type": if action.isEmpty { action = "type" }; i += 1; typedText = argv[safe: i] ?? ""
    case "--query": i += 1; typedText = argv[safe: i] ?? ""
    case "--texts": action = "texts"
    case "--act": action = "act"
    case "--on": i += 1; targetRole = argv[safe: i] ?? "AXButton"
    case "--search-test": action = "searchtest"
    case "--nav-test": action = "navtest"
    case "--key": if action.isEmpty { action = "key" }; i += 1; keyName = argv[safe: i] ?? ""
    case "--focus-index": action = "focusindex"; i += 1; which = Int(argv[safe: i] ?? "") ?? 0
    case "--pid": i += 1; pid = Int(argv[safe: i] ?? "") ?? 0
    case "--repeat": i += 1; repeatCount = max(1, Int(argv[safe: i] ?? "") ?? 1)
    case "--max-tabs": i += 1; maxTabs = min(200, max(1, Int(argv[safe: i] ?? "") ?? 60))
    case "--tabs": i += 1; maxTabs = min(200, max(1, Int(argv[safe: i] ?? "") ?? 8))
    case "--depth": i += 1; depth = Int(argv[safe: i] ?? "") ?? 24
    default: break
    }
    i += 1
}

extension Array {
    subscript(safe index: Int) -> Element? { indices ~= index ? self[index] : nil }
}

guard pid > 0, !action.isEmpty else {
    FileHandle.standardError.write("需要 --pid 与动作（见文件头用法）\n".data(using: .utf8)!)
    exit(2)
}
if !AXIsProcessTrusted() {
    FileHandle.standardError.write("⚠️ AXIsProcessTrusted()=false ⇒ 读不到别的进程的无障碍树\n".data(using: .utf8)!)
}

let app = AXUIElementCreateApplication(pid_t(pid))

// MARK: - AX 读数

func copyAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
}
func str(_ el: AXUIElement, _ attr: String) -> String? { copyAttr(el, attr) as? String }
func actionNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    return AXUIElementCopyActionNames(el, &names) == .success ? ((names as? [String]) ?? []) : []
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (copyAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func roleOf(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute) ?? "?" }

/// 控件角色集合：SwiftUI 的标准 `Button` 在 AX 里是 `AXButton`，`Toggle` 是 `AXCheckBox`，
/// `Menu`/`Picker` 是 `AXPopUpButton`/`AXMenuButton`，列表行常是 `AXCell`/`AXRow`。
/// 只有 `actions` 里带 `AXPress` 的那些才算"可点元素"（见 `isPressable`）；
/// 角色清单只用来给 role 分布做旁证，**不参与分母**（否则会把不可点的静态文本数进来）。
let controlRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
    "AXLink", "AXMenuItem", "AXDisclosureTriangle", "AXIncrementor", "AXPageTurner",
]

func frameOf(_ el: AXUIElement) -> (CGPoint, CGSize)? {
    guard let posRef = copyAttr(el, kAXPositionAttribute), let sizeRef = copyAttr(el, kAXSizeAttribute)
    else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
    return (p, s)
}

func describe(_ el: AXUIElement) -> String {
    let role = roleOf(el)
    let sub = str(el, kAXSubroleAttribute)
    let idf = str(el, kAXIdentifierAttribute)
    let title = str(el, kAXTitleAttribute)
    let desc = str(el, kAXDescriptionAttribute)
    var valueHint = ""
    if let v = copyAttr(el, kAXValueAttribute) { valueHint = " value=\(String(describing: v).prefix(40))" }
    var posPart = ""
    if let (p, s) = frameOf(el) { posPart = " at=\(Int(p.x)),\(Int(p.y)) size=\(Int(s.width))x\(Int(s.height))" }
    let actions = actionNames(el)
    let label = [title, desc].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
    return "\(role)\(sub.map { "[\($0)]" } ?? "") id=\(idf ?? "-") label=\(label.isEmpty ? "-" : label)\(valueHint)\(posPart) actions=\(actions.isEmpty ? "-" : actions.joined(separator: ","))"
}

/// 停靠点的身份签名：role + identifier + label + 整数化几何。
/// 为什么带上几何：列表里同类控件的 label 常常逐行相同（"重新读取"、行名），
/// 只比 label 会把不同行折叠成"同一个停靠点"⇒ 回环会被提前误判。
func signature(_ el: AXUIElement) -> String {
    let idf = str(el, kAXIdentifierAttribute) ?? "-"
    let label = [str(el, kAXTitleAttribute), str(el, kAXDescriptionAttribute)]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
    let geo: String
    if let (p, s) = frameOf(el) { geo = "@\(Int(p.x)),\(Int(p.y))x\(Int(s.width))x\(Int(s.height))" }
    else { geo = "@nogeom" }
    return "\(roleOf(el))|\(idf)|\(label.prefix(120))|\(geo)"
}

/// 不含几何的签名：role + identifier + label + value。
/// 为什么要单独一把尺：2026-09-23 实测 Settings 页那颗页头按钮的 `y` 会在 146/174/188 之间跳
/// （ScrollView 随焦点自动滚动 ⇒ 同一点每次 frame 不同）。**带几何的签名因此不能用来判"是不是同一点"**，
/// 只能用来打印。同一点判定一律按 `CFEqual`（对象同一性）；覆盖度匹配按"同一性 或 无几何签名"两条任一。
func sigNoGeom(_ el: AXUIElement) -> String {
    let idf = str(el, kAXIdentifierAttribute) ?? "-"
    let label = [str(el, kAXTitleAttribute), str(el, kAXDescriptionAttribute)]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
    let val = (copyAttr(el, kAXValueAttribute).map { String(describing: $0) }) ?? "-"
    return "\(roleOf(el))|\(idf)|\(label.prefix(120))|\(val.prefix(40))"
}

func sameElement(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
    CFEqual(a as CFTypeRef, b as CFTypeRef)
}

/// 控件的「逻辑身份」四件套：role + subrole + identifier + **label** —— **不含** value / 几何。
/// 为什么是这四件（2026-09-23 两轮各撞一次，两次都是本装置的读数缺陷）：
///   - 不含几何：页头那颗合并节点的 `y` 会随 ScrollView 自动滚动在 146/174/188 之间跳，
///     带几何判"同一点"会把同一点读成两点、环永远闭不上（上一手 stable-reread 假死正是此因）。
///   - 不含 value：`停止引擎/启动引擎`、Toggle 的 0/1 这类**实时值**会随采集 tick 变，
///     带 value 判同一点会被数值抖动误伤。
///   - **必须含 label**：只按 `role|subrole|id` 判同一点会**折叠同类控件** —— Settings 页
///     `显示菜单栏 Extra` 与 `登录时启动` 两颗 Toggle 的 role/subrole/identifier 完全相同
///     （id 都是空），实测被读成"焦点没动"，于是**一个真停靠点被当成慢拍丢掉**、覆盖被算低。
///     这条同时会让 `tabUntilMoved` 在"焦点走到了同类兄弟控件"时白等满预算。
///   ⇒ 它**只用于同一点判定**；覆盖度分母仍按无障碍树里真存在的可 AXPress 元素数，不因这把尺改动。
func identityKey(_ el: AXUIElement) -> String {
    let label = [str(el, kAXTitleAttribute), str(el, kAXDescriptionAttribute)]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
    return "\(roleOf(el))|\(str(el, kAXSubroleAttribute) ?? "-")|\(str(el, kAXIdentifierAttribute) ?? "-")|\(label.prefix(120))"
}

func isPressable(_ el: AXUIElement) -> Bool { actionNames(el).contains("AXPress") }

/// 把元素上所有可读文案拼成一条（页头计数那类只出现在 title/description/value 里）。
func allText(_ el: AXUIElement) -> String {
    var parts: [String] = []
    for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
        if let s = str(el, a) { parts.append(s) }
        else if let v = copyAttr(el, a) as? NSNumber { parts.append(v.stringValue) }
    }
    return parts.joined(separator: " · ")
}

/// 有界遍历（节点上限 + 深度上限）：SwiftUI 大页能长到几千节点，不设上限这就不再"自己结束"。
func gatherTexts(matching needle: String, nodeCap: Int = 4000) -> [(String, String)] {
    var out: [(String, String)] = []
    var visited = 0
    func walk(_ el: AXUIElement, _ now: Int) {
        if now > depth || visited >= nodeCap { return }
        visited += 1
        let t = allText(el)
        if !needle.isEmpty && t.contains(needle) { out.append((roleOf(el), t)) }
        for c in children(el) { walk(c, now + 1) }
    }
    walk(rootElement().el, 0)
    if visited >= nodeCap { out.append(("装置提示", "遍历到节点上限 \(nodeCap) ⇒ 后面的节点没看，命中数是**下限**")) }
    return out
}

func isSearchField(_ el: AXUIElement) -> Bool {
    str(el, kAXSubroleAttribute) == "AXSearchField" || roleOf(el) == "AXTextField"
}

/// 有界节点计数 + 表模态存在性：按键前后各取一次，"这次按键有没有 observable 效果"就靠这两个量判，
/// 不去猜截图里哪块变了。
func snapshot() -> (nodes: Int, pressable: Int, sheets: Int) {
    var nodes = 0, pressable = 0, sheets = 0
    var visited = 0
    func walk(_ el: AXUIElement, _ now: Int) {
        if now > depth || visited >= 4000 { return }
        visited += 1; nodes += 1
        if isPressable(el) { pressable += 1 }
        if str(el, kAXSubroleAttribute) == "AXSheet" { sheets += 1 }
        for c in children(el) { walk(c, now + 1) }
    }
    walk(rootElement().el, 0)
    return (nodes, pressable, sheets)
}

func focused() -> AXUIElement? {
    guard let raw = copyAttr(app, kAXFocusedUIElementAttribute) else { return nil }
    return (raw as! AXUIElement)
}

/// `kAXWindowsAttribute` 在启动一两分钟后会稳定返回空（`Tools/UIProbe/scroll-window.swift` 已实测），
/// 拿不到就退回 app 子树 —— 两种情况都写进输出，不假装读到了窗口。
func rootElement() -> (el: AXUIElement, note: String) {
    if let w = (copyAttr(app, kAXWindowsAttribute) as? [AXUIElement])?.first {
        return (w, "根=AXWindow")
    }
    return (app, "根=AXApplication（kAXWindowsAttribute 为空，退回 app 子树）")
}

var pressList: [AXUIElement] = []
func collectPressable(_ el: AXUIElement, _ now: Int) {
    if now > depth { return }
    if isPressable(el) { pressList.append(el) }
    for c in children(el) { collectPressable(c, now + 1) }
}
func rebuildPressables() {
    pressList.removeAll(keepingCapacity: true)
    collectPressable(rootElement().el, 0)
}

// MARK: - 前台闸门

/// 注入之前必须确认目标就是 frontmost：否则按键打到别的窗口，焦点回读会跟着**别的窗口**演，
/// 整份焦点链就是假的（这台机器上同时跑着 IDE 与别的实例，`pid 45764` 那颗旧包尤其危险）。
func isFrontmostTarget() -> Bool {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid) { return true }
    // 兜底第二条：AX 的 frontmost 属性（窗口服务器与 NSWorkspace 偶有先后差）
    if let f = copyAttr(app, kAXFrontmostAttribute) as? Bool, f { return true }
    return false
}
/// 把目标提到 frontmost：两条机制轮着上（`activate()` 与直接写 AX 的 `kAXFrontmost`），
/// 每条各等一轮。本机同时跑着 IDE（我的探针就是它生出来的），提级会被焦点抢占防护挡一次，
/// 只试一次就判"起不来"会造成随机 false-block。
@discardableResult
func raiseTarget(attempts: Int = 12) -> Bool {
    for _ in 0..<attempts {
        NSRunningApplication(processIdentifier: pid_t(pid))?.activate()
        usleep(200_000)
        if isFrontmostTarget() { return true }
        _ = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        usleep(250_000)
        if isFrontmostTarget() { return true }
    }
    return false
}

func ensureFrontmostOrDie(_ what: String) {
    if raiseTarget() { return }
    FileHandle.standardError.write((
        "⛔ 前台闸门：目标 pid \(pid) 起不到 frontmost ⇒ 拒绝注入（\(what)）。"
        + "强行注入会把键打到别的窗口，焦点链全是假的。\n").data(using: .utf8)!)
    exit(3)
}

// MARK: - 键注入

let keyCodes: [String: Int64] = [
    "esc": 53, "escape": 53, "return": 36, "enter": 36, "space": 49,
    "tab": 48, "down": 125, "up": 126, "left": 123, "right": 124,
]

func postKey(_ keyCode: Int64, shift: Bool = false) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false)
    else { return }
    if shift {
        down.flags = .maskShift
        up.flags = .maskShift
    }
    down.post(tap: .cghidEventTap)
    usleep(60_000)
    up.post(tap: .cghidEventTap)
}

func typeString(_ s: String) {
    guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
    let uni = Array(s.utf16)
    uni.withUnsafeBufferPointer { buf in
        ev.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
    }
    ev.post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
}

// MARK: - 稳定回读（注入后「等到读数真的变了为止」）

/// 注入一次 Tab 并回读焦点。为什么不能「按一下 → 固定睡 230ms → 读一次」就完事
/// （2026-09-23 上一手与本手在同一台机器上各撞到一次）：
///   Settings 页那颗被 SwiftUI 合并出来的整块页头（`AXButton id=ellipsis.circle size=992x53`）上，
///   连按 12 次 Tab 的读数**逐字相同**。固定睡眠读一次**分不清**两种解释：
///     (a) 焦点真的卡在这颗控件上（→ App 的键盘环缺陷，是要报的结论），
///     (b) 焦点已经走了、只是回读还没刷新（→ 装置缺陷，会把环「提前闭合」把覆盖算低、
///         或在别的形状下把没走到的点算成走完了 = 假绿）。
///   ⇒ 这里按**逻辑身份**连读，读到身份变了立刻返回；读到预算用完仍不变才叫「未移动」。
/// 预算为什么给到 ~3 s（15 拍 × 200 ms）而不是 1 s：本 App 的采集 tick 是 3 s 一发
///   （`Sources/AIObservatoryUI/Shell`，AGENTS §6 的周期），Settings 页 2026-09-23 实测
///   同一颗控件上"按一次 Tab → 焦点不动"会持续 1~2 s 后才前进 —— 那是**主线程被 tick 占住**
///   把按键处理排到了后面，不是环断了。预算给短了就会把「慢」读成「卡死」（假红），
///   读到动了立刻返回也不会让总时长失控（绝大多数拍 <1 s）。
/// 返回 `(元素, 变化前多等了几个轮询)`；`pollsUsed == polls` 表示这一拍没动。
func tabUntilMoved(from prevIdentity: String?, polls: Int = 15, settle: UInt32 = 200_000)
    -> (el: AXUIElement?, pollsUsed: Int, moved: Bool) {
    postKey(48)
    var last: AXUIElement?
    for n in 1...polls {
        usleep(settle)
        guard let f = focused() else { continue }
        last = f
        if identityKey(f) != prevIdentity { return (f, n, true) }
    }
    return (last, polls, false)
}

/// 一次注入里"按满轮询仍未变"的读数由 `tabUntilMoved` 的 `moved` 字段带出去，
/// 调用方（`--sweep`）把它累计成 `stuckSteps` 打印 —— 这个数本身就是要报的形状：
/// 它 > 0 说明键盘环上存在一个**吞 Tab 的停靠点**（SwiftUI 合并节点或焦点被夺回）。

// MARK: - 动作

func reportFocused(_ prefix: String) {
    if let f = focused() { print("\(prefix)\(describe(f))") }
    else { print("\(prefix)（读不到 kAXFocusedUIElement：窗口无焦点或焦点在系统里）") }
}

switch action {
case "focus":
    reportFocused("focus: ")

case "tab":
    ensureFrontmostOrDie("tab")
    for n in 1...repeatCount {
        postKey(48)
        usleep(230_000)
        reportFocused("tab\(n): ")
    }

case "shifttab":
    ensureFrontmostOrDie("shift-tab")
    for n in 1...repeatCount {
        postKey(48, shift: true)
        usleep(230_000)
        reportFocused("shift-tab\(n): ")
    }

case "key":
    guard let code = keyCodes[keyName.lowercased()] else {
        FileHandle.standardError.write("不认识按键 \(keyName)\n".data(using: .utf8)!)
        exit(2)
    }
    ensureFrontmostOrDie("key:\(keyName)")
    for _ in 1...repeatCount { postKey(code); usleep(200_000) }
    reportFocused("after-\(keyName.lowercased()): ")

case "type":
    ensureFrontmostOrDie("type")
    typeString(typedText)
    usleep(300_000)
    reportFocused("after-type: ")

case "focusindex":
    rebuildPressables()
    guard which < pressList.count else { print("索引 \(which) 超出（分母 \(pressList.count)）"); exit(2) }
    let target = pressList[which]
    let err = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    print("setFocus err=\(err.rawValue)  target=\(describe(target))")
    usleep(250_000)
    reportFocused("readback: ")
    if let f = focused() {
        print("焦点是否落在目标上：\(CFEqual(f as CFTypeRef, target as CFTypeRef) ? "是" : "否")")
    }

case "texts":
    let root = rootElement()
    print(root.note)
    let hits = gatherTexts(matching: typedText)
    print("== 含「\(typedText)」的文案 \(hits.count) 条（有界遍历，节点上限 4000）")
    for (r, t) in hits.prefix(40) { print("  \(r): \(t.prefix(200))") }

case "searchtest":
    // 侧栏搜索框：只用键盘 Tab 走到它 → 打字 → Return → 读页头计数变化 → Esc 清除
    ensureFrontmostOrDie("searchtest")
    // 有界：最多 maxTabs 次 Tab 找搜索框，找不到就 exit 1（"键盘聚焦不了搜索框"是一条真缺陷候选）
    var reached = -1
    var startEl: AXUIElement?
    for step in 1...maxTabs {
        if let f = focused(), isSearchField(f) { reached = step; startEl = f; break }
        let prev = focused().map { identityKey($0) }
        _ = tabUntilMoved(from: prev)
        if !isFrontmostTarget() && !raiseTarget(attempts: 4) {
            print("searchtest: 第 \(step) 步前台断链且提不回来 ⇒ 中止")
            break
        }
    }
    guard reached > 0, let f0 = startEl else {
        print("searchtest: 有界 \(maxTabs) 次 Tab 内**没走到**文本框/搜索框 ⇒ 键盘聚焦失败（真缺陷候选，不许含糊）")
        exit(1)
    }
    let needles = ["共", "已加载", typedText].filter { !$0.isEmpty }
    func dumpHeaders(_ stage: String) {
        var seenLine = Set<String>()
        for nd in needles {
            for (r, t) in gatherTexts(matching: nd) {
                let key = r + t
                if seenLine.contains(key) { continue }
                seenLine.insert(key)
                print("  [\(stage)] \(r): \(t.prefix(220))")
            }
        }
    }
    print("searchtest: 第 \(reached) 次 Tab 落到搜索框：\(describe(f0))")
    dumpHeaders("改词前")
    typeString(typedText)
    usleep(300_000)
    print("searchtest: 打字后焦点 value：\(focused().map { describe($0) } ?? "nil")")
    postKey(36)   // Return：让侧栏词下推进当前板块的查询
    usleep(2_200_000)
    dumpHeaders("Return后")
    postKey(53)   // Esc：清除
    usleep(1_800_000)
    dumpHeaders("Esc后")
    print("searchtest: 结论 键盘聚焦=\(reached) 次 Tab｜打字+Return+Esc 三段读数已打在上面")
    exit(0)

case "act":
    // Tab（有界）走到某个 role 的元素上 → 按一下指定键 → 比按键前后的树快照。
    // 为什么要有这条：判"Return 触发"不能靠"看起来没变化"，要有可核对量。
    ensureFrontmostOrDie("act")
    let wanted = keyName.isEmpty ? "return" : keyName.lowercased()
    // `--key none` = 只把焦点**停**到该类控件上、不按键（给截图用：拍"焦点环停在一颗已知按钮上"
    //  而不触发任何动作 —— 按 Return/Space 会真的改状态，那张图就不是走查起点的样子了）。
    if wanted == "none" {
        var parkStep = -1
        for step in 1...maxTabs {
            if let f = focused(), roleOf(f) == targetRole || (targetRole == "控件" && (isPressable(f) || controlRoles.contains(roleOf(f)))) {
                parkStep = step
                print("park: 第 \(step) 次 Tab 把焦点停在（不按键）：\(describe(f))")
                break
            }
            _ = tabUntilMoved(from: focused().map { identityKey($0) })
            if !isFrontmostTarget() && !raiseTarget(attempts: 4) { print("park: 第 \(step) 步前台断链 ⇒ 中止"); break }
        }
        if parkStep < 0 { print("park: 有界 \(maxTabs) 次 Tab 内没走到 role=\(targetRole)") ; exit(1) }
        exit(0)
    }
    guard let code = keyCodes[wanted] else {
        FileHandle.standardError.write("不认识按键 \(keyName)\n".data(using: .utf8)!)
        exit(2)
    }
    var hit = -1
    var target: AXUIElement?
    for step in 1...maxTabs {
        if let f = focused(), roleOf(f) == targetRole || (targetRole == "控件" && (isPressable(f) || controlRoles.contains(roleOf(f)))) {
            hit = step; target = f; break
        }
        let prev = focused().map { identityKey($0) }
        let r = tabUntilMoved(from: prev)
        if !isFrontmostTarget() && !raiseTarget(attempts: 4) {
            print("act: 第 \(step) 步前台断链且提不回来 ⇒ 中止")
            break
        }
        _ = r
    }
    guard hit > 0, let t = target else {
        print("act: 有界 \(maxTabs) 次 Tab 内没走到 role=\(targetRole) ⇒ 这一格按【键盘到不了该类控件】记，不是「没测」")
        exit(1)
    }
    let before = snapshot()
    print("act: 第 \(hit) 次 Tab 落到目标：\(describe(t))")
    print("act: 按键前快照 节点=\(before.nodes) 可AXPress=\(before.pressable) AXSheet=\(before.sheets)")
    postKey(code)
    usleep(1_600_000)
    let after = snapshot()
    print("act: 按 \(wanted) 之后焦点：\(focused().map { describe($0) } ?? "nil")")
    print("act: 按键后快照 节点=\(after.nodes) 可AXPress=\(after.pressable) AXSheet=\(after.sheets)"
        + "  ⇒ Δ节点=\(after.nodes - before.nodes) Δ可点=\(after.pressable - before.pressable) Δ模态=\(after.sheets - before.sheets)")
    print("act: 有 observable 变化=\((after.nodes != before.nodes || after.pressable != before.pressable || after.sheets != before.sheets) ? "是" : "否（无树变化 ⇒ 该键在这颗控件上没有可见效果）")")
    exit(0)

case "navtest":
    // 侧栏（AXOutline）行内可达性：Tab 走到容器 → 上下键在行里移动 → Return 真的换页？
    //   为什么单独一条：SwiftUI 的 List 在无障碍里是「Tab 只落到容器、行内靠方向键」的形状。
    //   sweep 的漏清单会把行内的按钮算成"到不了"，那到底是**缺陷**还是**方向键可达**，
    //   必须有这条实测，不能靠解释含糊过去。有界：maxTabs 次方向键。
    ensureFrontmostOrDie("navtest")
    var onOutline = -1
    for step in 1...maxTabs {
        if let f = focused(), ["AXOutline", "AXList", "AXTable"].contains(roleOf(f)) { onOutline = step; break }
        _ = tabUntilMoved(from: focused().map { identityKey($0) })
    }
    guard onOutline > 0, let first = focused() else {
        print("navtest: 有界 \(maxTabs) 次 Tab 内**没走到**列表容器 ⇒ 侧栏行内可达性这一格记「测不到」，不算通过")
        exit(1)
    }
    print("navtest: 第 \(onOutline) 次 Tab 落到列表容器：\(describe(first))")
    var selReads: [String] = []
    for k in 1...min(maxTabs, 14) {
        if let down = keyCodes["down"] { postKey(down) }
        usleep(300_000)
        let nowDesc = focused().map { describe($0) } ?? "nil"
        let picked = (copyAttr(first, kAXSelectedChildrenAttribute) as? [AXUIElement]).map { String($0.count) } ?? "读不到"
        selReads.append("k[\(k)] 选中数=\(picked) 焦点=\(nowDesc.prefix(150))")
        print("  \(selReads.last!)")
    }
    let distinctSel = Set(selReads.map { $0.replacingOccurrences(of: #"k\[\d+\] "#, with: "", options: .regularExpression) })
    print("navtest: 方向键 \(selReads.count) 次 ⇒ 不同读数 \(distinctSel.count) 种 ⇒ \(distinctSel.count > 1 ? "容器内确实用方向键走得动（行内可达走的是这条，不是 Tab）" : "方向键也没有任何读数变化（侧栏行内键盘不可达）")")
    postKey(36)
    usleep(1_800_000)
    print("navtest: 容器内按 Return 之后焦点：\(focused().map { describe($0) } ?? "nil")")

case "pressables":
    let root = rootElement()
    print(root.note)
    rebuildPressables()
    print("== 可 AXPress 元素 \(pressList.count) 个（depth<=\(depth)）")
    for (n, el) in pressList.enumerated() {
        print("[\(n)] \(describe(el))")
        if n > 400 { print("...（截断，只影响打印不影响计数）"); break }
    }

case "sweep":
    ensureFrontmostOrDie("sweep")
    let root = rootElement()
    print(root.note)
    rebuildPressables()
    let denomCount = pressList.count
    print("分母：本页无障碍树里可 AXPress 元素 \(denomCount) 个")
    for (n, el) in pressList.enumerated() { print("应有[\(n)] \(describe(el))") }
    if let f0 = focused() { print("起点(未注入)：\(describe(f0))") }

    struct Stop { let elem: AXUIElement; let step: Int; let desc: String; let sig: String; let pressable: Bool }
    var visited: [Stop] = []
    var loopClosedAt = -1
    var injected = 0
    var stuckSteps = 0
    var truncated = false
    var stalled = false            // 键盘环卡死在同一个停靠点（不是回环）
    var stallIsAppDefect = false   // 卡住时按 Space 仍能改 value ⇒ 键进得去 ⇒ 卡是 App 的环缺陷

    for step in 1...maxTabs {
        let prevIdentity = focused().map { identityKey($0) }
        let r = tabUntilMoved(from: prevIdentity)
        injected += 1
        if !isFrontmostTarget() {
            if !raiseTarget(attempts: 4) {
                print("[\(injected)] ⚠️ 前台断链：目标不再是 frontmost 且提不回来 ⇒ 链路在此**截断**"
                    + "（后面的停靠点没看，下面的覆盖数是**下限**，不是「没走到」）")
                truncated = true
                break
            }
        }
        guard let f = r.el else {
            print("[\(step)] （焦点读不到 ⇒ 该步作废，不计停靠点）")
            continue
        }
        if !r.moved {
            // 按满轮询身份仍未变：这一拍**不记新停靠点**（否则同一点被记两次 = 环被提前"闭合"、
            // 覆盖被算高），但单独计数——它就是"这个停靠点吞 Tab"的读数，是要报的形状。
            stuckSteps += 1
            if stuckSteps >= 3 {
                print("[\(step)] ⚠️ 连续 \(stuckSteps) 拍焦点身份都不变 ⇒ 键盘环**卡在**：\(describe(f))")
                // 卡住有两种解释，必须在这一刻就地分辨，否则这页的结论只能写"不能判"：
                //   (A) 装置/通路坏了：键根本没进这个 App ⇒ 那"卡住"不是 App 的缺陷；
                //   (B) App 的键盘环在这里不前进：键进得去、只是 Tab 不挪焦点 ⇒ 这才是要报的缺陷。
                // 分辨办法：在**同一颗卡住的控件**上按 Space（Toggle 会把 value 翻面）。
                //   value 翻了 ⇒ 键确实进了这个 App（通路好），而 Tab 连续 3 拍不挪焦点
                //     ⇒ 判 (B)：这一页的 Tab 环在这颗控件上真的走不动。
                //   value 不翻 ⇒ 键根本没进去 ⇒ 判 (A)：装置问题，本轮这页的结论作废（不许写成 App 不可达）。
                let selfFocused = (copyAttr(f, kAXFocusedAttribute) as? Bool).map { $0 ? "true" : "false" } ?? "读不到"
                print("   冻结核验①：该控件自身 kAXFocused=\(selfFocused)（true ⇒ 焦点确实钉在它身上，不是回读飘）")
                if let winRef = copyAttr(app, kAXFocusedWindowAttribute) {
                    let win = winRef as! AXUIElement
                    print("   冻结核验②：焦点窗口=\(describe(win).prefix(140))")
                }
                if isPressable(f) || controlRoles.contains(roleOf(f)) {
                    // 分辨"键到底进没进去"：光看 value 不够 —— Button 没有 value 属性，
                    // 卡住的又常常正是 Button（2026-09-23 实测卡在「重新扫描」上）。
                    // 所以三条一起看：① Toggle 类看 value 翻面；② 任何控件看**按 Space 前后的树快照**
                    // （按钮被触发会改节点数/可点数/模态数）；③ 再给一次**满预算**的 Tab，
                    //   若焦点随后仍会前进，那说明前面只是 tick 把按键排 later（慢），不是环断。
                    let v0 = (copyAttr(f, kAXValueAttribute).map { String(describing: $0) }) ?? "-"
                    let snap0 = snapshot()
                    if let sp = keyCodes["space"] { postKey(sp) }
                    usleep(900_000)
                    let v1 = (focused().flatMap { copyAttr($0, kAXValueAttribute) }.map { String(describing: $0) }) ?? "-"
                    let snap1 = snapshot()
                    let valueFlipped = v0 != "-" && v1 != "-" && v0 != v1
                    let treeChanged = snap0 != snap1
                    let extra = tabUntilMoved(from: identityKey(f))
                    let laterMoved = extra.moved
                    let keysLand = valueFlipped || treeChanged || laterMoved
                    print("   冻结核验③：在这颗控件上按 Space ⇒ value \(v0.prefix(16)) -> \(v1.prefix(16))"
                        + " 翻面=\(valueFlipped ? "是" : "否/不适用") 树快照 \(snap0) -> \(snap1) 变=\(treeChanged ? "是" : "否")"
                        + "｜再给一次满预算 Tab ⇒ 焦点随后前进=\(laterMoved ? "是（等了 \(extra.pollsUsed) 拍）" : "否")")
                    print("   冻结核验③ 判：键进得去=\(keysLand ? "是" : "否")"
                        + (keysLand
                            ? "（三条里至少一条动了 ⇒ 通路好；Tab 环在这里不前进是 **App 的键盘环问题**）"
                            : "（三条全不动 ⇒ **装置/通路问题**，本页结论作废，不许写成 App 不可达）"))
                    stallIsAppDefect = keysLand
                    if laterMoved, let nf = extra.el {
                        print("   ⇒ 「再给一次 Tab 焦点就前进了」：这更像**主线程 tick 把按键排到后面**（慢），"
                            + "不是环永久断掉；本轮把这一拍记成「慢拍」，链继续走（不记断环）")
                        stuckSteps = 0
                        if !visited.contains(where: { sameElement($0.elem, nf) || $0.sig == sigNoGeom(nf) }) {
                            let pStop = isPressable(nf) || controlRoles.contains(roleOf(nf))
                            visited.append(Stop(elem: nf, step: step, desc: describe(nf), sig: sigNoGeom(nf), pressable: pStop))
                            print("[\(step).1] \(describe(nf))\(pStop ? "   ←可点" : "")   ←慢拍之后真正的落点")
                        }
                        continue
                    }
                } else {
                    print("   冻结核验③：卡住的不是控件 role（\(roleOf(f))），没法用 Space 分辨 ⇒ 本页按「不能判」记")
                    stallIsAppDefect = false
                }
                stalled = true
                break
            }
            print("[\(step)] （与上一拍同一身份，第 \(stuckSteps) 次）：\(describe(f))")
            continue
        }
        stuckSteps = 0
        // 回环判据：**只认对象同一性，或"逻辑身份 + 整数几何"同时相同**。
        // 为什么不能只按无几何签名判（2026-09-23 本手实测踩到）：列表页每行同字是常态
        //   —— Files 页 157 颗可点里绝大多数是行内同名按钮，按签名判"回到已走过的点"会在**第 2 行**
        //   就宣布环闭合 ⇒ 覆盖被算低、还写成"环闭合了"，这是本装置最危险的一种假绿/假红。
        // 几何漂移（ScrollView 随焦点自动滚）只会让环**闭不上**、走到 --max-tabs 停 ⇒
        //   那报的是"有界未收敛"，是可核对的下限，不会把没走到的点说成走完了。
        if let hit = visited.first(where: {
            sameElement($0.elem, f) || (identityKey($0.elem) == identityKey(f) && signature($0.elem) == signature(f))
        }) {
            print("[\(step)] 回环：\(describe(f))")
            print("↑ 与第 \(hit.step) 步是同一个停靠点（对象同一，或身份+几何全同）⇒ 环闭合")
            loopClosedAt = hit.step
            break
        }
        let isPressableStop = isPressable(f) || controlRoles.contains(roleOf(f))
        visited.append(Stop(elem: f, step: step, desc: describe(f), sig: sigNoGeom(f), pressable: isPressableStop))
        print("[\(step)] \(describe(f))\(isPressableStop ? "   ←可点" : "")")
    }

    // 到过几颗：**对象同一性**与**无几何签名**两条任一命中即算到过
    rebuildPressables()
    let visitedSigs = Set(visited.map { $0.sig })
    var reachedBySig = 0
    var reachedByIdentity = 0
    var missed: [(n: Int, el: AXUIElement, desc: String)] = []
    for (n, el) in pressList.enumerated() {
        let bySig = visitedSigs.contains(sigNoGeom(el))
        let byID = visited.contains { sameElement($0.elem, el) }
        if bySig { reachedBySig += 1 }
        if byID { reachedByIdentity += 1 }
        if !(bySig || byID) { missed.append((n, el, describe(el))) }
    }

    let pressableStops = visited.filter { $0.pressable }.count
    // 两个数**分开报**，不合成一个"好看"的比值：
    //   · 按对象同一 = **保守下限**（SwiftUI 重建对象时会漏认，见 identityKey 注释）；
    //   · 按无几何签名 = **含同类折叠的上限**（列表里逐行同字 ⇒ 到过一次第 3 行，
    //     会把第 4..N 行也算"到过"，所以它只能当上限看，不能当结论）。
    // 头条比值取**保守下限**，上限只作对照打印 —— 拿上限当结论就是本装置给自己发假绿。
    print("== 注入 Tab \(injected) 次｜不同停靠点 \(visited.count) 个（按 CFEqual 计）｜可点停靠 \(pressableStops) 个｜吞 Tab 拍 \(stuckSteps) 次")
    print("== 到过/应有 = \(reachedByIdentity)/\(denomCount)"
        + "（分母=本页树里可 AXPress 的颗数；到过=焦点链**按对象同一性**落进过该集合 = 保守下限）")
    print("== 到过（无几何签名口径，含同类折叠，只作上限对照）= \(reachedBySig)/\(denomCount)")
    print("== 环是否闭合：" + (loopClosedAt > 0
        ? "是（回到第 \(loopClosedAt) 步）"
        : stalled
            ? "否 —— 键盘环**卡死**在同一个停靠点（断环，不是回环）；Space 分辨结论见上面「冻结核验③」"
            : "否 —— 到 --max-tabs=\(maxTabs) 上限停，属【有界未收敛】，不许写成走完了"))
    if truncated { print("== ⚠️ 本报告是**截断的下限**：中途前台断链且提不回来，后面的停靠点没看") }

    // 漏点的**分类**（只是解释，**不改分母**——把分母改小凑比值是本格明令禁止的动作）。
    // 三类的判据都是**可核对的形状**，不是"我觉得不算"：
    //   窗口装饰：subrole 属于系统画的关闭/最小化/缩放/工具栏窗口件，键盘环归 WindowServer 管；
    //   滚动条件：subrole 是增量/减量箭头或翻页，SwiftUI 滚动视图的组成部分，标准 Tab 环不含；
    //   同名重复：label 与链上另一颗可点件逐字相同且更外层（工具栏 item 包着一个内层按钮 = 同一个动作的两份 AX 节点）；
    //   列表行容器：落在 AXOutline/AXList 里的行（Tab 只到容器，行内靠方向键 —— 这条要单独验，见 --nav-test）。
    var buckets: [String: [String]] = [:]
    func roleLabelKey(_ el: AXUIElement) -> String {
        let label = [str(el, kAXTitleAttribute), str(el, kAXDescriptionAttribute)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
        return "\(roleOf(el))#\(label)"
    }
    // 列表/侧栏容器的几何范围：Tab 环只落到**容器**（AXOutline），行内的按钮在标准 macOS
    // 键盘环里本来就不是独立 Tab 停靠点（行内靠方向键）。用几何包含判，比"猜 parent role"可靠，
    // 因为 SwiftUI 常把行包在 AXCell/AXGroup 里、parent 不是 outline。
    var containerRects: [(x: Double, y: Double, w: Double, h: Double)] = []
    func findContainers(_ el: AXUIElement, _ now: Int) {
        if now > depth { return }
        if ["AXOutline", "AXList", "AXTable"].contains(roleOf(el)), let (p, s) = frameOf(el) {
            containerRects.append((p.x, p.y, s.width, s.height))
        }
        for c in children(el) { findContainers(c, now + 1) }
    }
    findContainers(rootElement().el, 0)
    func insideContainer(_ el: AXUIElement) -> Bool {
        guard let (p, s) = frameOf(el) else { return false }
        let cx = p.x + s.width / 2, cy = p.y + s.height / 2
        return containerRects.contains { cx >= $0.x - 2 && cx <= $0.x + $0.w + 2 && cy >= $0.y - 2 && cy <= $0.y + $0.h + 2 }
    }
    // 链上到过的 role#label 集合：漏点若与某个**已到过**的停靠点同名同 role，
    // 那它就是"同一个动作的两份 AX 节点（外层包裹 + 内层控件）"，不是第 2 颗独立的可达件。
    let reachedRoleLabels = Set(visited.map { roleLabelKey($0.elem) })
    for m in missed {
        let el = m.el
        let sub = str(el, kAXSubroleAttribute) ?? "-"
        let d = "漏[\(m.n)] \(m.desc)"
        let parentRole: String
        if let pref = copyAttr(el, kAXParentAttribute) { parentRole = roleOf(pref as! AXUIElement) } else { parentRole = "-" }
        let key: String
        if ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton", "AXToolbarButton", "AXFloatingWindowButton"].contains(sub) {
            key = "窗口装饰（系统窗口件，Tab 环归 WindowServer）"
        } else if sub.hasPrefix("AXIncrement") || sub.hasPrefix("AXDecrement") {
            key = "滚动条件（增量/减量/翻页，标准 Tab 环不含）"
        } else if roleOf(el) == "AXStaticText" {
            key = "静态文本被挂了 AXPress（SwiftUI 合并节点，不是独立可点件）"
        } else if reachedRoleLabels.contains(roleLabelKey(el)) || ["AXOutline", "AXList", "AXTable", "AXRow", "AXCell"].contains(parentRole) || insideContainer(el) {
            key = "容器行内 / 同名包裹（Tab 只到容器、行内靠方向键；或同一动作的两份节点 ⇒ 见 navtest 与链上同名点）"
        } else {
            key = "页内独立可点件（**真缺陷候选**）"
        }
        buckets[key, default: []].append(d)
    }
    print("== 漏点分类（分母仍是 \(denomCount)，下面只是把 \(missed.count) 颗漏点按形状归栏，**不从中扣数**）")
    for (k, v) in buckets.sorted(by: { $0.key < $1.key }) {
        print("   [\(v.count)] \(k)")
        for line in v.prefix(30) { print("        \(line.prefix(230))") }
    }
    print("== 其中「页内独立可点件（真缺陷候选）」= \((buckets["页内独立可点件（**真缺陷候选**）"] ?? []).count) 颗")

    for m in missed { print("漏[\(m.n)] \(m.desc)") }
    print("== 漏掉 \(missed.count) 颗")

case "selftest":
    ensureFrontmostOrDie("selftest")
    rebuildPressables()
    let stDenom = pressList.count
    print("分母（本页树里可 AXPress）\(stDenom) 颗")

    // (1) 稳态复读：不注入，连读焦点 3 次，判"焦点这个读数本身飘不飘"。
    //     不按 CFEqual、不按 sigNoGeom（原因见 `identityKey` 注释：对象重建 + 实时重排会误伤），
    //     改按**逻辑身份** role|subrole|id：3 次里出现最多的身份 ≥ 2 即算稳（容忍一次重排抖动），
    //     三次全不同身份（读路真在乱跳）或读不到焦点才 FAIL。
    var stSamples: [AXUIElement] = []
    var stKeys: [String] = []
    for s in 1...3 {
        if let f = focused() { stSamples.append(f); stKeys.append(identityKey(f)) }
        else { stKeys.append("<nil>") }
        if s < 3 { usleep(350_000) }
    }
    let stBestPair = Dictionary(grouping: stKeys, by: { $0 }).values.map { $0.count }.max() ?? 0
    let stableRead = !stKeys.contains("<nil>") && stBestPair >= 2
    let e1 = stSamples.first
    let cfSame = stSamples.count >= 2 ? (sameElement(stSamples[0], stSamples[1]) ? "同对象" : "异对象：SwiftUI 重建，正常") : "样本不足"
    print("stable-reread: 不注入连读 3 次身份=[\(stKeys.joined(separator: " | "))] 众数命中 \(stBestPair)/3 ⇒ \(stableRead ? "OK" : "FAIL")（CFEqual 前两次=\(cfSame)；末次读数=\(focused().map { describe($0) } ?? "nil")）")
    guard stableRead, let startEl = e1 else {
        print("SELFTEST: stable-reread=FAIL ⇒ 回读通道不可信（3 次身份各不相同或读不到焦点），本轮 Tab 结论作废（先修装置，不要下「键盘可达/不可达」的结论）")
        exit(1)
    }

    // (2) **装置正对照 = 简报要求的"对已知按钮能读到焦点变化"那一条**（合并成一条闸门，两件事一次量）：
    //     ① 沿 Tab 环走（有界），直到焦点落在**一颗自己就读得出 role=AXButton 且 actions 含 AXPress** 的控件上
    //        —— 锚点条件**直接读焦点元素本身**，不去和 `--pressables` 的签名对表：
    //        2026-09-23 dashboard 实测焦点停在工具栏那颗 28x28 的内层按钮上，而分母列表里只有
    //        41x52 的工具栏外层包裹（`id=` 空串 vs 焦点侧 `id=-`），按签名对表永远"走不到已知按钮"
    //        ⇒ 那是**装置的匹配尺错了**，不是 App 没按钮。焦点元素自己带 AXPress 就是最强的"已知按钮"证据。
    //     ② 在这颗锚点上**再按 Tab**，身份必须变化 —— 证明回读通道不是钉死的。
    //     两条都过 ⇒ 装置可信；后面某页 Tab 环走不到某颗控件才是 **App 的缺陷**而不是装置的缺口。
    //     回读用 `tabUntilMoved`（等到身份变化为止），不是"按一下 → 固定睡 230 ms → 读一次"——
    //     后者会把「SwiftUI 焦点迁移比 230 ms 慢」读成「焦点没动」，2026-09-23 上一手 12 步全 FAIL 正是这个形状。
    //     单次"满预算仍未动"（tick 把按键排到后面）**不判死**：累计到 3 次才算这一页的环真卡住。
    var injectorOK = false
    var knownButtonOK = false
    var anchorDesc = "走不到已知按钮"
    var stops = 0
    var sawPressableStop = false
    var sawButtonRole = false
    var stStuck = 0
    for step in 1...maxTabs {
        let prev = focused().map { identityKey($0) }
        let r = tabUntilMoved(from: prev)
        stops += 1
        guard let f = r.el else { print("  st[\(step)] 焦点读不到"); continue }
        let pressableHere = isPressable(f)
        let controlHere = controlRoles.contains(roleOf(f))
        if pressableHere { sawPressableStop = true }
        if controlHere { sawButtonRole = true }
        let onKnown = roleOf(f) == "AXButton" && pressableHere
        print("  st[\(step)] \(describe(f))\(pressableHere || controlHere ? "   ←可点/控件" : "")"
            + (onKnown ? "   ←已知可点按钮（锚点）" : "")
            + (r.moved ? "" : "   ←这一拍按满 \(r.pollsUsed) 个轮询身份仍未变"))
        if !r.moved {
            stStuck += 1
            if stStuck >= 3 {
                print("injector: 连续 \(stStuck) 拍焦点身份不变 ⇒ 键盘环在 \(describe(f).prefix(120)) 上卡住，自证到此起环")
                break
            }
            continue
        }
        stStuck = 0
        if !onKnown { continue }        // ① 过：Tab 环能把焦点推到一颗已知可点按钮上。
        injectorOK = true
        anchorDesc = describe(f)
        // ② 在这颗已知按钮上再按 Tab，身份必须变。**给三次机会**：
        //    本 App 的 3 s 采集 tick 会把按键处理排到后面（实测同一颗按钮上会出现
        //    「满预算 3 s 仍不动、再按一次就走了」），一次不动就判"装置是假绿源"= 把**慢**读成**坏**（假红）。
        //    三次满预算都不动才判 FAIL —— 那才是"回读通道读不到已知按钮上的焦点变化"。
        let from = identityKey(f)
        var anchorTries = 0
        var movedOffAnchor = false
        var landing: AXUIElement?
        while anchorTries < 3 && !movedOffAnchor {
            anchorTries += 1
            let r2 = tabUntilMoved(from: from)
            movedOffAnchor = r2.el.map { identityKey($0) != from || sigNoGeom($0) != sigNoGeom(f) } ?? false
            landing = r2.el
        }
        knownButtonOK = movedOffAnchor
        print("known-button: 锚点=\(anchorDesc.prefix(160))")
        print("known-button: 在锚点上再按 Tab（第 \(anchorTries) 次满预算尝试内）⇒ 身份变化=\(movedOffAnchor ? "是" : "否")"
            + " 落点=\(landing.map { describe($0).prefix(160) } ?? "nil")"
            + " ⇒ \(knownButtonOK ? "OK（装置能读到已知按钮上的焦点变化）" : "FAIL（三次满预算都读不到变化 ⇒ 装置本身是假绿源）")")
        break
    }
    print("injector: 有界 \(stops) 步内 Tab 环走到已知可点按钮 ⇒ \(injectorOK ? "OK" : "FAIL")（锚点=\(anchorDesc.prefix(140))）")

    // (3) 附带一条读数（**不参与**闸门）：程序化聚焦一颗已知按钮，看 err 与回读是否一致。
    //     2026-09-23 实测：`AXUIElementSetAttributeValue(kAXFocused)` 在焦点被系统门禁挡住时
    //     仍然回 err=0，但回读停在原处 ⇒ **err=0 不等于聚焦成功**，这条别再拿来当"控件可聚焦"的证据。
    if stDenom > 0, let idx = pressList.firstIndex(where: { roleOf($0) == "AXButton" }) ?? pressList.firstIndex(where: { isPressable($0) }) {
        let target = pressList[idx]
        let err = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(250_000)
        let hit = focused().map { sameElement($0, target) } ?? false
        print("旁证 setFocus(已知按钮[\(idx)] \(roleOf(target))) err=\(err.rawValue) 回读命中=\(hit ? "是" : "否")"
            + "（err=0 而回读否 ⇒ 聚焦被系统门禁拒绝，不是 App 没做可聚焦）")
    }

    print("SELFTEST 结论：stable-reread=OK injector=\(injectorOK ? "OK" : "FAIL") known-button=\(knownButtonOK ? "OK" : "FAIL")"
        + "｜键盘环上有可点停靠=\(sawPressableStop ? "是" : "否") 控件 role=\(sawButtonRole ? "是" : "否")")
    if !injectorOK || !knownButtonOK {
        print("⇒ 注入路 / 已知按钮正对照 有一项没通过 ⇒ 有两种解释（装置坏了 / 键盘环里真没有可点元素），"
            + "本轮**不得**据此写「Tab 可达」也**不得**写「Tab 不可达」——装置本身就是假绿源，先修它")
        exit(1)
    }
    exit(0)

case "axtree":
    var nodes = 0
    var pressable = 0
    func walk(_ el: AXUIElement, _ indent: Int) {
        if indent > depth { return }
        nodes += 1
        if isPressable(el) { pressable += 1 }
        print("\(String(repeating: "  ", count: indent))\(describe(el))")
        for c in children(el) { walk(c, indent + 1) }
    }
    walk(app, 0)
    print("== 节点 \(nodes) 个，其中可 AXPress \(pressable) 个（depth<=\(depth)）")

default:
    exit(2)
}
exit(0)

//
//  —— 源码级分母对照（本装置**故意不自己数**，理由写在这里）——
//  本工具的 `--pressables` / `--sweep` 的分母只来自**运行时的无障碍树**。
//  源码级计数（`Button(` / `axPressable` 消费者 / 列表行出口）是另一把尺，由走查脚本用 grep 现数，
//  用途是回答"树有没有漏数"：若源码某页 12 颗标准 `Button` 而树上只枚举到 9 颗可 AXPress，
//  那 3 颗要么被 `.accessibilityElement(children: .combine)` 折叠进了父节点（SwiftUI 的既有形状，
//  `Tests/**` 里那条"行内 frame 判据没有对象"是同一族），要么就是**没有无障碍出口的真缺陷**。
//  两种解释必须分开写，不能只报一个比值。
//
