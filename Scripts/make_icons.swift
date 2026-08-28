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

/// 绘制：深蓝靛渐变圆角底 + 高光 + 白色圆润向下箭头 + 落地线
func drawDownloadIcon(size: Int) -> CGImage {
    let ctx = makeContext(size)
    let s = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // 圆角背景
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // 背景渐变（深蓝 -> 靛紫，对角）
    let colors = [
        CGColor(srgbRed: 0.20, green: 0.42, blue: 0.98, alpha: 1),   // 亮蓝
        CGColor(srgbRed: 0.55, green: 0.36, blue: 0.95, alpha: 1),   // 靛紫
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

    // 顶部高光（左上柔和光晕）
    let hlColors = [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.32),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: hlColors, locations: [0, 1])!
    let hlCenter = CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.25)
    ctx.drawRadialGradient(hl,
                           startCenter: hlCenter, startRadius: 0,
                           endCenter: hlCenter, endRadius: rect.width * 0.75,
                           options: [])

    // 白色圆润向下箭头（round cap/join 描边绘制，整体圆润精致）
    // 注意：CGContext 坐标原点在左下、y 向上，因此"向下"= y 递减
    let cx = s * 0.5
    let shaftTop = s * 0.74   // 杆顶部（上方）
    let joint = s * 0.50      // 杆底部 / 箭头交汇点（中部）
    let tipY = s * 0.26       // 箭头尖端（下方）
    let half = s * 0.27
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(s * 0.165)

    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: cx, y: shaftTop))
    arrow.addLine(to: CGPoint(x: cx, y: joint))
    // 两条翼线从杆底两侧汇聚到下方尖端，构成标准的向下箭头（⌄）
    arrow.move(to: CGPoint(x: cx - half, y: joint))
    arrow.addLine(to: CGPoint(x: cx, y: tipY))
    arrow.move(to: CGPoint(x: cx + half, y: joint))
    arrow.addLine(to: CGPoint(x: cx, y: tipY))
    ctx.addPath(arrow)
    ctx.strokePath()

    // 落地线（箭头下方的收纳托盘线，半透明白）
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
    ctx.setLineWidth(s * 0.055)
    ctx.setLineCap(.round)
    let line = CGMutablePath()
    let lineY = s * 0.13
    line.move(to: CGPoint(x: cx - s * 0.23, y: lineY))
    line.addLine(to: CGPoint(x: cx + s * 0.23, y: lineY))
    ctx.addPath(line)
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
