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

/// 绘制：圆角渐变底 + 白色向下箭头入托盘
func drawDownloadIcon(size: Int) -> CGImage {
    let ctx = makeContext(size)
    let s = CGFloat(size)
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // 圆角背景
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // 渐变（绿 -> 蓝）
    let colors = [
        CGColor(red: 0.14, green: 0.72, blue: 0.48, alpha: 1),
        CGColor(red: 0.10, green: 0.50, blue: 0.88, alpha: 1),
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: s, y: 0),
                           options: [])

    // 向下箭头
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let cx = s * 0.5
    let shaftW = s * 0.17
    let shaftTop = s * 0.26
    let shaftBottom = s * 0.56
    ctx.fill(CGRect(x: cx - shaftW / 2, y: shaftTop, width: shaftW, height: shaftBottom - shaftTop))
    // 箭头三角
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: cx - s * 0.30, y: s * 0.50))
    tri.addLine(to: CGPoint(x: cx + s * 0.30, y: s * 0.50))
    tri.addLine(to: CGPoint(x: cx, y: s * 0.74))
    tri.closeSubpath()
    ctx.addPath(tri)
    ctx.fillPath()
    // 托盘
    let tray = CGMutablePath()
    tray.move(to: CGPoint(x: s * 0.20, y: s * 0.20))
    tray.addLine(to: CGPoint(x: s * 0.20, y: s * 0.30))
    tray.addLine(to: CGPoint(x: s * 0.30, y: s * 0.30))
    tray.addLine(to: CGPoint(x: s * 0.70, y: s * 0.30))
    tray.addLine(to: CGPoint(x: s * 0.80, y: s * 0.30))
    tray.addLine(to: CGPoint(x: s * 0.80, y: s * 0.20))
    tray.closeSubpath()
    ctx.addPath(tray)
    ctx.fillPath()

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
