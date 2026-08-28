import SwiftUI
import QuickDownCore

@main
struct QuickDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // 使用单窗口场景 Window（而非 WindowGroup）：保证无论 openWindow 被调用多少次，
        // 主窗口永远只有一份 —— 已存在则带到前台，已关闭则重建，不会叠加出多个窗口。
        Window("速下下载管理器", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建下载…") { model.showAddSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("全部开始") { model.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("全部暂停") { model.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appSettings) {
                Button("打开下载目录") { model.openDownloadFolder() }
            }
        }

        // 接管确认窗口：浏览器下载被接管后逐个确认（可重命名/选保存位置）
        Window("确认下载", id: "confirm") {
            CaptureConfirmView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 说明：应用以菜单栏应用运行（Info.plist LSUIElement=true，无 Dock 图标）。
    // 菜单栏图标由 StatusItemController 管理：左键打开主界面，右键菜单。

    /// 关闭主窗口时只隐藏窗口，不退出应用（下载器需长期驻留菜单栏）。
    /// 自定义 NSStatusItem 对 SwiftUI 不可见，必须显式阻止「最后一个窗口关闭即终止」。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DownloadManager.shared.persist()
    }
}
