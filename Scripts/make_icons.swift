// 生成速下图标：扩展 PNG + AppIcon.icns
// 用法: swift Scripts/make_icons.swift <输出目录>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func makeContext(_ size: Int) -> CGContext {
    return CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func writePNG(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// 绘制速下 App 图标（1024 画布等比缩放）：
/// 蓝靛紫三段渐变圆角底 + 顶部玻璃高光 + 底部暗角，
/// 白色「下载」字形（圆头箭头 + 接纳托盘），字形带柔和投影。
func drawDownloadIcon(size: Int) -> CGImage {
    let ctx = makeContext(size)
    let s = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // ---- 圆角背景 ----
    let inset = s * 0.045
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // 背景渐变：亮蓝 -> 靛 -> 紫（对角三段，层次比双色更饱满）
    let bgColors = [
        CGColor(srgbRed: 0.16, green: 0.50, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.38, green: 0.36, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.64, green: 0.34, blue: 0.95, alpha: 1),
    ] as CFArray
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

    // 顶部玻璃高光（左上径向白光）
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.34),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    let hlCenter = CGPoint(x: rect.minX + rect.width * 0.30, y: rect.maxY - rect.height * 0.22)
    ctx.drawRadialGradient(hl,
                           startCenter: hlCenter, startRadius: 0,
                           endCenter: hlCenter, endRadius: rect.width * 0.85,
                           options: [])

    // 底部暗角（收拢视觉重心，增加立体感）
    let dk = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(srgbRed: 0.05, green: 0.03, blue: 0.18, alpha: 0.22),
        CGColor(srgbRed: 0.05, green: 0.03, blue: 0.18, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    let dkCenter = CGPoint(x: rect.midX, y: rect.minY)
    ctx.drawRadialGradient(dk,
                           startCenter: dkCenter, startRadius: 0,
                           endCenter: dkCenter, endRadius: rect.height * 0.72,
                           options: [])

    // 内侧玻璃描边（1px 级别的细亮边，大图下呈现质感）
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.addPath(path)
    ctx.strokePath()

    // ---- 白色「下载」字形：箭头 + 托盘 ----
    // 坐标系原点在左下、y 向上；字形占画面中部约 52%，托盘独立于底部，构图留白舒展
    let cx = s * 0.5
    let shaftTop = s * 0.735   // 杆顶
    let joint     = s * 0.475  // 杆底/翼线交汇
    let tipY      = s * 0.295  // 箭头尖端
    let half      = s * 0.185  // 翼线半宽

    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(s * 0.115)
    // 字形柔和投影（视觉上落在背景上）
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.014), blur: s * 0.030,
                  color: CGColor(srgbRed: 0.08, green: 0.04, blue: 0.30, alpha: 0.30))

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: cx, y: shaftTop))
    arrow.addLine(to: CGPoint(x: cx, y: joint))
    arrow.move(to: CGPoint(x: cx - half, y: joint))
    arrow.addLine(to: CGPoint(x: cx, y: tipY))
    arrow.move(to: CGPoint(x: cx + half, y: joint))
    arrow.addLine(to: CGPoint(x: cx, y: tipY))
    ctx.addPath(arrow)
    ctx.strokePath()

    // 托盘：短圆头粗线，与箭头同宽视觉，稳定收底
    let trayY = s * 0.155
    let trayHalf = s * 0.21
    let tray = CGMutablePath()
    tray.move(to: CGPoint(x: cx - trayHalf, y: trayY))
    tray.addLine(to: CGPoint(x: cx + trayHalf, y: trayY))
    ctx.addPath(tray)
    ctx.strokePath()

    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: swift make_icons.swift <项目根目录>")
    exit(1)
}
let root = URL(fileURLWithPath: args[1], isDirectory: true)

// 扩展图标 -> <root>/Extension/icons/（扩展加载目录）
let extIcons = root.appendingPathComponent("Extension").appendingPathComponent("icons")
try? FileManager.default.createDirectory(at: extIcons, withIntermediateDirectories: true)
for size in [16, 48, 128] {
    let img = drawDownloadIcon(size: size)
    writePNG(img, to: extIcons.appendingPathComponent("icon\(size).png"))
    print("扩展图标 icon\(size).png ✓")
}

// AppIcon -> <root>/Resources/
let resDir = root.appendingPathComponent("Resources")
try? FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)
let iconset = resDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for (size, name) in sizes {
    let img = drawDownloadIcon(size: size)
    writePNG(img, to: iconset.appendingPathComponent(name))
}
print("AppIcon.iconset ✓")

// iconutil -> icns
let icns = resDir.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try? p.run()
p.waitUntilExit()
if FileManager.default.fileExists(atPath: icns.path) {
    print("AppIcon.icns ✓")
} else {
    print("iconutil 失败，请手动执行: iconutil -c icns \(iconset.path) -o \(icns.path)")
}
