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
    private var openConfirmWindowAction: (() -> Void)?

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

    /// 绘制菜单栏图标（彩色版）：与 App 图标同风格 —— 翠绿渐变圆角底 + 白色双层下冲箭头
    private func makeStatusImage() -> NSImage {
        let d: CGFloat = 18
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        defer { img.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: d, height: d)
        let bg = NSBezierPath(roundedRect: rect, xRadius: d * 0.30, yRadius: d * 0.30)
        let grad = NSGradient(colors: [
            NSColor(srgbRed: 0.30, green: 0.87, blue: 0.55, alpha: 1),
            NSColor(srgbRed: 0.03, green: 0.42, blue: 0.31, alpha: 1),
        ])!
        grad.draw(in: bg, angle: 135)

        NSColor.white.setStroke()
        let bp = NSBezierPath()
        bp.lineWidth = 2.2
        bp.lineCapStyle = .round
        bp.lineJoinStyle = .round
        let cx = d / 2
        // 双层下冲箭头（快进朝下 = 疾速下载），与 App 图标同构
        bp.move(to: NSPoint(x: cx - 5.0, y: 13.4))
        bp.line(to: NSPoint(x: cx, y: 9.6))
        bp.line(to: NSPoint(x: cx + 5.0, y: 13.4))
        bp.move(to: NSPoint(x: cx - 5.0, y: 8.4))
        bp.line(to: NSPoint(x: cx, y: 4.6))
        bp.line(to: NSPoint(x: cx + 5.0, y: 8.4))
        bp.stroke()

        return img
    }

    /// 绘制菜单栏图标（黑白版）：双层下冲箭头撑满 18pt 画布，
    /// 模板图只取 alpha、颜色由系统自动适配深浅菜单栏
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
        // 双层下冲箭头：与彩色版同构
        bp.move(to: NSPoint(x: cx - 5.4, y: 14.0))
        bp.line(to: NSPoint(x: cx, y: 9.8))
        bp.line(to: NSPoint(x: cx + 5.4, y: 14.0))
        bp.move(to: NSPoint(x: cx - 5.4, y: 8.6))
        bp.line(to: NSPoint(x: cx, y: 4.4))
        bp.line(to: NSPoint(x: cx + 5.4, y: 8.6))
        bp.stroke()

        return img
    }

    /// 捕获 SwiftUI 的 openWindow 能力（主窗口关闭后仍可恢复）
    func setOpenWindow(_ action: @escaping () -> Void) {
        openWindowAction = action
    }

    /// 捕获「确认下载」窗口的打开能力
    func setOpenConfirmWindow(_ action: @escaping () -> Void) {
        openConfirmWindowAction = action
    }

    /// 打开（或带到前台）「确认下载」窗口；队列清空时由视图自行 dismiss
    func showConfirmWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let action = openConfirmWindowAction {
            action()
        } else {
            // 主窗口从未出现过（openWindow 尚未捕获）：先唤起主窗口触发捕获，再重试
            showMainWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.popWindowToFront(titled: "确认下载")
            }
            return
        }
        // openWindow 是异步创建窗口，稍候把它顶到所有应用前方
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.popWindowToFront(titled: "确认下载")
        }
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
        // activate 在新版 macOS 是协作式的，速下在后台时可能抢不到焦点，
        // 窗口会开在当前应用后面 —— 统一用「短暂置顶」确保出现在最前
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.popWindowToFront(titled: "速下下载管理器")
        }
    }

    /// 把指定标题的窗口顶到所有应用前方（主窗口/确认窗口/设置窗口共用）。
    /// 应用全程保持 accessory（LSUIElement，永不出现 Dock 图标）：
    /// 配合 NSApp.activate + 短暂 .floating 置顶，保证窗口开在最前；
    /// 若协作式激活没抢到焦点，窗口也会浮在最上层，点一下即成为前台窗口。
    private func popWindowToFront(titled title: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard let win = NSApp.windows.first(where: { $0.title == title }) else { return }
        win.makeKeyAndOrderFront(nil)
        win.level = .floating
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            win.level = .normal
        }
    }

    /// 打开设置：触发主菜单「设置…」（SwiftUI Settings 场景注册项），并把设置窗口带到前台
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainMenu = NSApp.mainMenu, performSettingsItem(in: mainMenu.items) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.popWindowToFront(titled: "设置")
            }
            return
        }
        NSApp.sendAction(NSSelectorFromString("showSettingsWindow:"), to: nil, from: nil)
    }

    private func performSettingsItem(in items: [NSMenuItem]) -> Bool {
        for item in items {
            if item.title.contains("设置"), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
                return true
            }
            if let submenu = item.submenu, performSettingsItem(in: submenu.items) {
                return true
            }
        }
        return false
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "显示主窗口", action: #selector(menuShowMain), keyEquivalent: "")
        menu.addItem(withTitle: "新建下载…", action: #selector(menuNewDownload), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "全部开始", action: #selector(menuResumeAll), keyEquivalent: "")
        menu.addItem(withTitle: "全部暂停", action: #selector(menuPauseAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "打开下载目录", action: #selector(menuOpenFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出速下", action: #selector(menuQuit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func menuOpenSettings() { openSettings() }

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
