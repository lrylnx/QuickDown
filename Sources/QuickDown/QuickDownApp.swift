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

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(model)
        } label: {
            Image(systemName: "arrow.down.circle.fill")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - 应用代理

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 说明：应用以菜单栏应用运行（Info.plist LSUIElement=true，无 Dock 图标）。
    // 不再调用 setActivationPolicy(.regular)，保持 accessory 策略。

    func applicationWillTerminate(_ notification: Notification) {
        DownloadManager.shared.persist()
    }
}

// MARK: - 菜单栏菜单

struct MenuBarMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("显示主窗口") {
            // SwiftUI 原生：openWindow(id:) 无论窗口是否已关闭都能恢复/唤起
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("新建下载…") { model.showAddSheet = true }
        Divider()
        Button("全部开始") { model.resumeAll() }
        Button("全部暂停") { model.pauseAll() }
        Divider()
        Button("打开下载目录") { model.openDownloadFolder() }
        Divider()
        Button("退出速下") {
            DownloadManager.shared.persist()
            NSApp.terminate(nil)
        }
    }
}
