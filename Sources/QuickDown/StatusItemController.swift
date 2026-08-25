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
            button.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                   accessibilityDescription: "速下下载管理器")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "速下下载管理器：左键打开主界面，右键菜单"
        }
        statusItem = item
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
        openWindowAction?() // SwiftUI 原生恢复窗口（即使已关闭）
        // 兜底：窗口已存在时直接置前
        if let w = NSApp.windows.first(where: { $0.title.contains("速下") || $0.isMainWindow }) {
            w.makeKeyAndOrderFront(nil)
        }
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
