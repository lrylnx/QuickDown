import SwiftUI
import QuickDownCore

@main
struct QuickDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("速下下载管理器", id: "main") {
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

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 说明：应用以菜单栏应用运行（Info.plist LSUIElement=true，无 Dock 图标）。
    // 菜单栏图标由 StatusItemController 管理：左键打开主界面，右键菜单。

    func applicationWillTerminate(_ notification: Notification) {
        DownloadManager.shared.persist()
    }
}
