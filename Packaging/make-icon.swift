// make-icon.swift
// 从 `Packaging/icon-source.png` 重建 `Packaging/AppIcon.icns`。
//
// 为什么要有这个脚本，而不是「把图拖进 Preview」：交付包必须能可重跑地重建。
// 手工产物在下次打包时既无法证明它还在，也无法证明它还是这一张。
//
// 源图（生成器产出）有两个必须先处理掉的问题，都是实测出来的：
//   1. `sips -g hasAlpha` = **no** ⇒ 背景是不透明的白。直接塞进 bundle 的话，
//      Dock 上会是「白方块里画着一个圆角图标」的截图观感，而不是图标本身。
//   2. 右下角有生成器水印文字。它落在 macOS 图标栅格的**留白区**里，所以可以无损丢掉：
//      先按暗度求出 squircle 的包围盒（浅灰水印文字亮度高于该阈值，天然落在框外），
//      再把框外的近白像素键成透明。
//
// 网格：squircle 占画布 80%、居中、四周透明留白。macOS **不会**替我们做圆角遮罩，
// 所以圆角必须已经在资源里 —— 这也是不能直接把方图当图标用的原因。
//
// 用法：swift Packaging/make-icon.swift [仓库根目录]（默认当前目录）

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let repoRoot = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath
let sourcePath = "\(repoRoot)/Packaging/icon-source.png"
/// 目录名必须以 `<名字>.iconset` 结尾：`iconutil` 是按后缀认的，
/// 用 `.iconset`（点开头的隐藏名）会被它判成 `Invalid Iconset`。
let iconsetDir = "\(repoRoot)/Packaging/AppIcon.iconset"
let icnsPath = "\(repoRoot)/Packaging/AppIcon.icns"

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("❌ \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    print(message)
}

/// 画布边长。所有尺寸都从这张母图缩出去，保证各尺寸之间是同一份几何。
let canvasSide = 1024
/// squircle 占画布的比例（macOS 惯例约 0.8）。
let subjectRatio = 0.80
/// 判定「属于主体」的亮度阈值：squircle 是深石墨色，白底与浅灰水印都在它之上。
let subjectLuminanceCeiling = 0.55
/// 漫水判定「仍属背景」的下限：亮度高于它 ⇒ 还不是主体。
/// 取 0.78 而不是近白，是因为源图在 squircle 底下烤了一层**浅灰柔和投影**；
/// 主体内部最亮的斜向高光带亮度在 0.6–0.7 一档，留这段余量才不会把高光打穿。
let backgroundFloodFloor = 0.78

// MARK: - 读源图

guard let source = CGImageSourceCreateWithURL(
    URL(fileURLWithPath: sourcePath) as CFURL,
    [kCGImageSourceShouldCache: true] as CFDictionary
), let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    die("读不到源图：\(sourcePath)")
}

let width = master.width
let height = master.height
guard width > 0, height > 0 else { die("源图尺寸非法：\(width)x\(height)") }

/// 把任意 CGImage 摊成 RGBA8 缓冲，方便逐像素读亮度与写 alpha。
///
/// 返回里**必须带上 context**：`context.data` 指向 context 自己持有的缓冲，
/// 只把指针递出来而让 context 离开作用域，得到的就是一个悬垂指针（实测 SIGSEGV）。
func bitmap(_ image: CGImage) -> (context: CGContext, data: UnsafeMutableRawPointer, bytesPerRow: Int) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bytesPerRow = image.width * 4
    guard let context = CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { die("无法创建位图上下文") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let pointer = context.data else { die("位图上下文没有数据") }
    return (context, pointer, bytesPerRow)
}

// MARK: - 求主体包围盒（按暗度，绕开水印文字）

let masterScan = bitmap(master)
let pixels = masterScan.data.assumingMemoryBound(to: UInt8.self)
let stride = masterScan.bytesPerRow
_ = masterScan.context   // 显式续命：扫描期间缓冲必须活着

var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    for x in 0..<width {
        let o = y * stride + x * 4
        let r = Double(pixels[o]) / 255.0
        let g = Double(pixels[o + 1]) / 255.0
        let b = Double(pixels[o + 2]) / 255.0
        // 感知亮度足够暗 ⇒ 属于 squircle 本体。
        guard 0.2126 * r + 0.7152 * g + 0.0722 * b < subjectLuminanceCeiling else { continue }
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX > minX, maxY > minY else {
    die("在源图里找不到暗色主体（阈值 \(subjectLuminanceCeiling)）——源图可能不是预期的深底图标")
}

let boxWidth = maxX - minX + 1
let boxHeight = maxY - minY + 1
// 主体必须是正方形：取长边，按包围盒中心扩出去，再夹回画布内。
let side = max(boxWidth, boxHeight)
var cropOriginX = minX - (side - boxWidth) / 2
var cropOriginY = minY - (side - boxHeight) / 2
cropOriginX = max(0, min(cropOriginX, width - side))
cropOriginY = max(0, min(cropOriginY, height - side))
guard cropOriginX + side <= width, cropOriginY + side <= height else {
    die("主体包围盒 \(side)px 超出源图 \(width)x\(height)")
}
log("主体包围盒：\(boxWidth)x\(boxHeight) @(\(minX),\(minY)) ⇒ 正方形裁剪 \(side)px @(\(cropOriginX),\(cropOriginY))")

guard let subject = master.cropping(to: CGRect(
    x: cropOriginX, y: cropOriginY, width: side, height: side
)) else { die("裁剪失败") }

// MARK: - 近白键成透明（圆角外的那圈白）

let subjectPixels = bitmap(subject)
let sp = subjectPixels.data.assumingMemoryBound(to: UInt8.self)
let sStride = subjectPixels.bytesPerRow

/// 从四条边向内漫水，把「与边界连通且足够浅」的像素键成透明。
///
/// 为什么不能只做近白色键：源图在 squircle 底下**烤了一层柔和投影**，
/// 那是浅灰不是白（实测近白键只吃掉 2.1%，而按圆角几何应有约 4.2%），
/// 剩下的会在图标四角留一圈灰光晕。
/// 漫水从边界出发、遇到暗色主体即停，所以只会吃掉「背景 + 投影」，
/// 不会在主体内部的高光带上打洞（那部分被主体边缘挡住，漫水到不了）。
var visited = [Bool](repeating: false, count: side * side)
var stack: [Int] = []
stack.reserveCapacity(side * 4)
for i in 0..<side {
    stack.append(i)                                  // 上边
    stack.append((side - 1) * side + i)              // 下边
    stack.append(i * side)                           // 左边
    stack.append(i * side + side - 1)                // 右边
}
func luminanceOf(_ index: Int) -> Double {
    let o = index * 4
    return (0.2126 * Double(sp[o]) + 0.7152 * Double(sp[o + 1]) + 0.0722 * Double(sp[o + 2])) / 255.0
}
var keyed = 0
while let index = stack.popLast() {
    if index < 0 || index >= side * side || visited[index] { continue }
    guard luminanceOf(index) > backgroundFloodFloor else { continue }   // 够暗 ⇒ 已是主体，停
    visited[index] = true
    let o = index * 4
    sp[o + 3] = 0
    keyed += 1
    let x = index % side, y = index / side
    if x > 0 { stack.append(index - 1) }
    if x < side - 1 { stack.append(index + 1) }
    if y > 0 { stack.append(index - side) }
    if y < side - 1 { stack.append(index + side) }
}
log("漫水键掉背景/投影：\(keyed)/\(side * side)（\(String(format: "%.1f", Double(keyed) * 100 / Double(side * side)))%；按圆角几何预期约 4–6%，含烤进去的柔和投影）")

guard let subjectImage = CGContext(
    data: subjectPixels.data, width: side, height: side,
    bitsPerComponent: 8, bytesPerRow: sStride,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)?.makeImage() else { die("回写位图失败") }

// MARK: - 铺到 1024 透明画布

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let canvas = CGContext(
    data: nil, width: canvasSide, height: canvasSide,
    bitsPerComponent: 8, bytesPerRow: canvasSide * 4,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { die("无法创建母图画布") }
canvas.clear(CGRect(x: 0, y: 0, width: canvasSide, height: canvasSide))
let drawSide = Int(Double(canvasSide) * subjectRatio)
let offset = (canvasSide - drawSide) / 2
canvas.interpolationQuality = .high
canvas.draw(subjectImage, in: CGRect(x: offset, y: offset, width: drawSide, height: drawSide))
guard let masterCanvas = canvas.makeImage() else { die("母图合成失败") }

// MARK: - 导出 iconset 并合成 icns

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
do {
    try fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
} catch {
    die("建 iconset 目录失败：\(error)")
}

/// (文件名, 像素边长)。`iconutil` 认这套命名，缺一个尺寸就少一档分辨率。
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    guard let scaled = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { die("建 \(name) 上下文失败") }
    scaled.clear(CGRect(x: 0, y: 0, width: size, height: size))
    scaled.interpolationQuality = .high
    scaled.draw(masterCanvas, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = scaled.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: "\(iconsetDir)/\(name)") as CFURL,
            UTType.png.identifier as CFString, 1, nil
          ) else { die("写 \(name) 失败") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { die("finalize \(name) 失败") }
}
log("iconset 已导出 \(variants.count) 个尺寸")

try? fm.removeItem(atPath: icnsPath)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
let pipe = Pipe()
task.standardError = pipe
do {
    try task.run()
    task.waitUntilExit()
} catch {
    die("iconutil 启动失败：\(error)")
}
guard task.terminationStatus == 0 else {
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    die("iconutil 退出码 \(task.terminationStatus)：\(text)")
}
try? fm.removeItem(atPath: iconsetDir)

guard let attributes = try? fm.attributesOfItem(atPath: icnsPath),
      let bytes = attributes[.size] as? Int else { die("没生成 \(icnsPath)") }
log("✅ \(icnsPath)（\(bytes) 字节）")
