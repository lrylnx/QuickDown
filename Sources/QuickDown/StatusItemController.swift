import AppKit
import SwiftUI
import QuickDownCore

/// 菜单栏状态项控制器：
/// - 左键点击 = 打开主界面
/// - 右键点击 = 弹出菜单
/// - 下载时按钮文字动态显示实时速度
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private weak var model: AppModel?
    private var openWindowAction: (() -> Void)?

    func setup(model: AppModel) {
        self.model = model
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            applyIconStyle(to: button)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "速下下载管理器：左键打开主界面，右键菜单"
        }
        statusItem = item
    }

    /// 按当前设置应用菜单栏图标样式（设置变更时即时刷新）
    func applyIconStyle(style: String? = nil) {
        let s = style ?? SettingsStore.shared.settings.menuBarIconStyle
        guard let button = statusItem?.button else { return }
        applyIconStyle(to: button, style: s)
    }

    private func applyIconStyle(to button: NSStatusBarButton, style: String? = nil) {
        let s = style ?? SettingsStore.shared.settings.menuBarIconStyle
        if s == "mono" {
            let img = makeMonoStatusImage()
            img.isTemplate = true   // 模板图：深色菜单栏自动白、浅色自动黑，与其他图标一致
            button.image = img
        } else {
            button.image = makeStatusImage()
        }
    }

    /// 绘制菜单栏图标（彩色版）：与 App 图标同风格 —— 蓝靛渐变圆角底 + 白色圆润下箭头
    private func makeStatusImage() -> NSImage {
        let d: CGFloat = 18
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        defer { img.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: d, height: d)
        let bg = NSBezierPath(roundedRect: rect, xRadius: d * 0.30, yRadius: d * 0.30)
        let grad = NSGradient(colors: [
            NSColor(srgbRed: 0.22, green: 0.44, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.38, blue: 0.95, alpha: 1),
        ])!
        grad.draw(in: bg, angle: 135)

        NSColor.white.setStroke()
        let bp = NSBezierPath()
        bp.lineWidth = 3.0
        bp.lineCapStyle = .round
        bp.lineJoinStyle = .round
        let cx = d / 2
        bp.move(to: NSPoint(x: cx, y: 14.0))
        bp.line(to: NSPoint(x: cx, y: 9.2))
        bp.move(to: NSPoint(x: cx - 4.4, y: 9.2))
        bp.line(to: NSPoint(x: cx, y: 3.8))
        bp.move(to: NSPoint(x: cx + 4.4, y: 9.2))
        bp.line(to: NSPoint(x: cx, y: 3.8))
        bp.stroke()

        return img
    }

    /// 绘制菜单栏图标（黑白版）：纯下箭头模板图，颜色交给系统自动适配
    private func makeMonoStatusImage() -> NSImage {
        let d: CGFloat = 18
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        defer { img.unlockFocus() }

        NSColor.black.setStroke()   // 模板图只取 alpha，实际颜色由系统决定
        let bp = NSBezierPath()
        bp.lineWidth = 2.4
        bp.lineCapStyle = .round
        bp.lineJoinStyle = .round
        let cx = d / 2
        bp.move(to: NSPoint(x: cx, y: 13.2))
        bp.line(to: NSPoint(x: cx, y: 8.6))
        bp.move(to: NSPoint(x: cx - 3.6, y: 8.6))
        bp.line(to: NSPoint(x: cx, y: 4.2))
        bp.move(to: NSPoint(x: cx + 3.6, y: 8.6))
        bp.line(to: NSPoint(x: cx, y: 4.2))
        bp.stroke()

        return img
    }

    /// 捕获 SwiftUI 的 openWindow 能力（主窗口关闭后仍可恢复）
    func setOpenWindow(_ action: @escaping () -> Void) {
        openWindowAction = action
    }

    /// 更新菜单栏文字：下载时显示速度，空闲时为空（只显示图标）
    func updateSpeed(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.button?.title = text
        }
    }

    @objc private func statusClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem?.popUpMenu(buildMenu())
        } else {
            showMainWindow()
        }
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI 的 Window 场景保证单窗口：窗口已存在则带到前台，已关闭则重建
        openWindowAction?()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "显示主窗口", action: #selector(menuShowMain), keyEquivalent: "")
        menu.addItem(withTitle: "新建下载…", action: #selector(menuNewDownload), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "全部开始", action: #selector(menuResumeAll), keyEquivalent: "")
        menu.addItem(withTitle: "全部暂停", action: #selector(menuPauseAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开下载目录", action: #selector(menuOpenFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出速下", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func menuShowMain() { showMainWindow() }

    @objc private func menuNewDownload() {
        showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.model?.showAddSheet = true
        }
    }

    @objc private func menuResumeAll() { model?.resumeAll() }
    @objc private func menuPauseAll() { model?.pauseAll() }
    @objc private func menuOpenFolder() { model?.openDownloadFolder() }

    @objc private func menuQuit() {
        DownloadManager.shared.persist()
        NSApp.terminate(nil)
    }
}
