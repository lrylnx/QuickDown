import SwiftUI
import QuickDownCore
import ServiceManagement

// MARK: - 设置窗口

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var settings = SettingsStore.shared.settings
    @State private var loginItemStatus = ""

    var body: some View {
        TabView {
            GeneralSettingsView(settings: $settings)
                .tabItem { Label("常规", systemImage: "gearshape") }
            ExtensionSettingsView(model: model, settings: $settings)
                .tabItem { Label("浏览器扩展", systemImage: "puzzlepiece.extension") }
            ProxySettingsView(settings: $settings)
                .tabItem { Label("代理", systemImage: "network") }
            AdvancedSettingsView(settings: $settings, loginItemStatus: $loginItemStatus, apply: apply)
                .tabItem { Label("高级", systemImage: "slider.horizontal.3") }
            AboutSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 440)
        .onAppear {
            refreshLoginStatus()
        }
        .onDisappear {
            apply()
        }
    }

    private func refreshLoginStatus() {
        if #available(macOS 13.0, *) {
            loginItemStatus = SMAppService.mainApp.status == .enabled ? "已开启" : "未开启"
        } else {
            loginItemStatus = "当前系统不支持"
        }
    }

    private func apply() {
        // 目录存在性检查
        var fm = settings
        if !FileManager.default.fileExists(atPath: fm.downloadDirectory) {
            try? FileManager.default.createDirectory(atPath: fm.downloadDirectory, withIntermediateDirectories: true)
        }
        fm.maxConcurrent = min(max(fm.maxConcurrent, 1), 10)
        fm.maxSegments = min(max(fm.maxSegments, 1), 16)
        fm.speedLimitBps = max(0, fm.speedLimitBps)
        SettingsStore.shared.update { $0 = fm }
        model.applySettings()
        refreshLoginStatus()
    }
}

// MARK: - 关于

/// 版本号：从 App Bundle 读取（CFBundleShortVersionString），与 Info.plist 单一来源保持一致
enum AppVersion {
    static let current: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (v?.isEmpty == false) ? v! : "1.4.0"
    }()
}

struct AboutSettingsView: View {
    private let repoURL = URL(string: "https://github.com/lrylnx/QuickDown")!

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            Text("速下 QuickDown")
                .font(.title2.bold())
            Text("版本 \(AppVersion.current)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("轻量、原生的 macOS 下载管理器：多线程分段加速、断点续传、网页视频嗅探、浏览器下载接管")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Divider()
                .padding(.horizontal, 48)
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.caption)
                Link("GitHub 源码与更新：github.com/lrylnx/QuickDown", destination: repoURL)
                    .font(.caption)
            }
            Text("MIT 开源许可 · 全中文界面 · 安装包仅约 2MB")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 常规

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var settings: AppSettings
    @State private var showDirPicker = false

    var body: some View {
        Form {
            HStack {
                Text("下载目录")
                Spacer()
                Text(settings.downloadDirectory)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        settings.downloadDirectory = url.path
                    }
                }
            }
            Picker("同时下载数", selection: $settings.maxConcurrent) {
                ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("每个文件分段数", selection: $settings.maxSegments) {
                ForEach(1...32, id: \.self) { Text("\($0)").tag($0) }
            }
            Text("分段数越高，支持 Range 的服务器下载越快（推荐 8，最高 32）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Toggle("下载完成后通知", isOn: $settings.notifyOnComplete)
            Toggle("按分类保存到子文件夹", isOn: $settings.sortIntoCategories)
            Text("视频 / 音乐 / 压缩包 / 图片 / 应用程序 / 文档 / 代码 / 其他")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Picker("菜单栏图标", selection: $settings.menuBarIconStyle) {
                Text("品牌彩色").tag("color")
                Text("黑白（跟随系统）").tag("mono")
            }
            Text("彩色与 App 图标同风格，黑白为模板图标自动适配深色/浅色菜单栏")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Picker("外观", selection: $settings.appearance) {
                Text("自动（跟随系统）").tag("auto")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Text("手动选择后，系统切换深浅色时速下保持所选外观")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Toggle("小于 1MB 的文件不分段", isOn: Binding(
                get: { settings.minSegmentSize > 0 },
                set: { settings.minSegmentSize = $0 ? 1024 * 1024 : 0 }
            ))
        }
        .formStyle(.grouped)
        .padding(20)
        .onChange(of: settings.menuBarIconStyle) { newStyle in
            // 菜单栏图标样式即时生效（无需关闭设置窗口）
            SettingsStore.shared.update { $0.menuBarIconStyle = newStyle }
            StatusItemController.shared.applyIconStyle(style: newStyle)
        }
        .onChange(of: settings.appearance) { newMode in
            // 外观即时生效（无需关闭设置窗口）：auto/light/dark
            SettingsStore.shared.update { $0.appearance = newMode }
            model.applySettings()
        }
    }
}

// MARK: - 浏览器扩展

/// 安装向导浮动面板：浮动层级（永远在最上层）+ 左侧定位。
/// 使用异步 continuation 而非 runModal —— 不阻塞主线程，按钮事件正常派发
@MainActor
final class WizardAlert: NSObject {
    private var panel: NSWindow!
    private var continuation: CheckedContinuation<Int, Never>?

    /// 显示向导弹窗，await 返回点击的按钮序号（0 开始）
    func show(title: String, message: String, buttons: [String],
              verticalFraction: CGFloat = 0.5, width: CGFloat = 400) async -> Int {
        // 估算高度：按行数
        let lineCount = message.components(separatedBy: "\n").count
        let height = max(180, 80 + CGFloat(lineCount) * 17 + 60)

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                             styleMask: [.titled],
                             backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating          // 浮动层级：永远在 Finder/浏览器之上
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        self.panel = panel

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // 说明文字（可选中复制）
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(x: 16, y: 70, width: width - 32, height: height - 110)
        label.isEditable = false
        label.isSelectable = true
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        content.addSubview(label)

        // 按钮：从右往左排列（macOS 惯例：第一个按钮在最右）
        var bx = width - 16
        let by: CGFloat = 24
        for (i, bTitle) in buttons.enumerated() {
            let btn = NSButton(title: bTitle, target: self, action: #selector(clicked(_:)))
            btn.tag = i
            btn.bezelStyle = .rounded
            let size = btn.sizeThatFits(NSSize(width: 200, height: 30))
            let w = max(size.width + 28, 80)
            bx -= w
            btn.frame = NSRect(x: bx, y: by, width: w, height: 28)
            if i == 0 { btn.keyEquivalent = "\r" } // 默认按钮回车触发
            content.addSubview(btn)
            bx -= 10
        }
        panel.contentView = content

        // 定位到屏幕左侧
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let x = vf.minX + 24
            let y = vf.minY + (vf.height - height) * verticalFraction
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // 显示并等待按钮点击（异步，不阻塞主线程）
        return await withCheckedContinuation { cont in
            continuation = cont
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        panel?.orderOut(nil)
        let c = continuation
        continuation = nil
        c?.resume(returning: sender.tag)
    }
}

/// 安装向导期间隐藏/恢复速下窗口（结构体内不能持有可变存储，用单例）
final class WizardWindowManager {
    static let shared = WizardWindowManager()
    private var hidden: [NSWindow] = []

    func hideAll() {
        hidden = NSApp.windows.filter { $0.isVisible }
        hidden.forEach { $0.orderOut(nil) }
    }

    func restoreAll() {
        NSApp.activate(ignoringOtherApps: true)
        hidden.forEach { $0.makeKeyAndOrderFront(nil) }
        hidden.removeAll()
    }
}

/// 已安装的 Chromium 内核浏览器
struct InstalledBrowser: Identifiable {
    let id: String
    let name: String
    let appPath: String

    var exists: Bool { FileManager.default.fileExists(atPath: appPath) }
}

extension ExtensionSettingsView {
    /// 扫描 /Applications 下的 Chromium 内核浏览器
    static func scanBrowsers() -> [InstalledBrowser] {
        let candidates: [(String, String, String)] = [
            ("chrome", "Google Chrome", "/Applications/Google Chrome.app"),
            ("edge", "Microsoft Edge", "/Applications/Microsoft Edge.app"),
            ("thorium", "Thorium", "/Applications/Thorium.app"),
            ("brave", "Brave", "/Applications/Brave Browser.app"),
            ("vivaldi", "Vivaldi", "/Applications/Vivaldi.app"),
            ("chromium", "Chromium", "/Applications/Chromium.app"),
            ("arc", "Arc", "/Applications/Arc.app"),
            ("opera", "Opera", "/Applications/Opera.app"),
        ]
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.2) }
            .map { InstalledBrowser(id: $0.0, name: $0.1, appPath: $0.2) }
    }
}

struct ExtensionSettingsView: View {
    @ObservedObject var model: AppModel
    @Binding var settings: AppSettings
    @State private var message = ""
    @State private var browsers: [InstalledBrowser] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("浏览器下载接管")
                .font(.headline)
            Text("速下自带中文浏览器扩展，可接管 Chrome / Edge / Thorium / Brave 等浏览器。\n现代浏览器出于安全限制，未打包扩展只能手动加载一次（约 30 秒），下方向导会一步步带你完成。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("接管下载时弹出主窗口", isOn: $settings.popWindowOnCapture)
                .help("浏览器下载被接管时，自动跳到速下窗口查看进度")
            Toggle("接管下载后先确认再下载", isOn: $settings.confirmOnCapture)
                .help("接管后弹出确认窗口：可重命名文件、选择保存位置，点击「开始下载」或「取消」")

            QDDivider()

            if browsers.isEmpty {
                Text("未检测到 Chrome / Edge / Thorium / Brave 等浏览器（请先安装）")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("检测到的浏览器：")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(browsers) { browser in
                    HStack {
                        HStack(spacing: 10) {
                            QDCategoryIcon(symbol: browserSymbol(browser.id),
                                           color: QDTheme.accent,
                                           size: 28)
                            Text(browser.name)
                        }
                        Spacer()
                        Button("一键安装向导…") {
                            runInstallWizard(browser)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(QDTheme.accent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 3)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本地服务端口：\(model.serverPort > 0 ? "\(model.serverPort)" : "未启动")")
                    Text("扩展通过 127.0.0.1 与速下通信")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                Button("打开扩展目录") { revealExtension() }
                Button("复制扩展路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(stableExtensionPath().path, forType: .string)
                    message = "扩展路径已复制到剪贴板"
                }
            }
        }
        .padding(20)
        .onAppear {
            browsers = Self.scanBrowsers()
        }
    }

    private func browserSymbol(_ id: String) -> String {
        switch id {
        case "chrome", "edge", "thorium", "brave", "chromium": return "globe"
        case "vivaldi", "opera": return "globe"
        case "arc": return "sparkles"
        default: return "puzzlepiece.extension"
        }
    }

    /// 稳定扩展路径：优先应用包内，同时同步一份到用户目录（可读、稳定、不怕 App 移动）
    private func stableExtensionPath() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("QuickDown/browser-extension", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 从应用包同步最新扩展文件（文件夹 + CRX 拖拽包）
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension"),
           fm.fileExists(atPath: bundled.path) {
            try? fm.removeItem(at: dir)
            try? fm.copyItem(at: bundled, to: dir)
        }
        if let bundledCRX = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension.crx"),
           fm.fileExists(atPath: bundledCRX.path) {
            try? fm.removeItem(atPath: dir.appendingPathComponent("BrowserExtension.crx").path)
            try? fm.copyItem(at: bundledCRX, to: dir.appendingPathComponent("BrowserExtension.crx"))
        }
        return dir
    }

    private func runInstallWizard(_ browser: InstalledBrowser) {
        let extDir = stableExtensionPath()
        Task { @MainActor in
            // 1. 打开该浏览器的扩展管理页
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", browser.name, "chrome://extensions"]
            try? p.run()
            // 等待浏览器打开扩展页
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // 2. 隐藏速下所有窗口，让屏幕只留浏览器扩展页
            WizardWindowManager.shared.hideAll()

            // 3. 第一步：请用户开启开发者模式（浮动面板在左下方，不挡浏览器右上角的开关）
            let alert1 = WizardAlert()
            let r1 = await alert1.show(
                title: "第一步：开启开发者模式",
                message: "\(browser.name) 的扩展页面已打开。\n请打开页面右上角的「开发者模式」开关，然后点「我已开启」继续。",
                buttons: ["我已开启", "取消"],
                verticalFraction: 0.15)
            if r1 != 0 {
                WizardWindowManager.shared.restoreAll() // 用户取消，恢复窗口
                return
            }

            // 4. 在 Finder 中选中扩展文件夹（Finder 弹到最前）
            NSWorkspace.shared.activateFileViewerSelecting([extDir])

            // 5. 第二步：拖入扩展页面完成安装（浮动面板在左侧中部，不挡 Finder）
            let alert2 = WizardAlert()
            _ = await alert2.show(
                title: "第二步：拖入扩展安装",
                message: """
                Finder 已打开并选中扩展文件夹，把它拖到 \(browser.name) 的扩展页面：
                ① 把「browser-extension」文件夹（或 BrowserExtension.crx）拖到扩展页面任意位置
                ② 弹出确认时点「添加扩展程序」
                ③ 扩展出现在列表中即安装成功

                文件位置：\(extDir.path)
                """,
                buttons: ["我已安装完成", "稍后再说"],
                verticalFraction: 0.5)

            // 6. 恢复速下窗口
            WizardWindowManager.shared.restoreAll()
        }
    }

    private func revealExtension() {
        let dir = stableExtensionPath()
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            message = "未找到扩展目录"
        }
    }
}

// MARK: - 代理

struct ProxySettingsView: View {
    @Binding var settings: AppSettings

    var body: some View {
        Form {
            Toggle("启用代理", isOn: $settings.proxyEnabled)
            TextField("代理地址", text: $settings.proxyHost)
                .disabled(!settings.proxyEnabled)
            TextField("端口", value: $settings.proxyPort, format: .number)
                .disabled(!settings.proxyEnabled)
            TextField("用户名（可选）", text: Binding(
                get: { settings.proxyUsername ?? "" },
                set: { settings.proxyUsername = $0.isEmpty ? nil : $0 }
            ))
            .disabled(!settings.proxyEnabled)
            SecureField("密码（可选）", text: Binding(
                get: { settings.proxyPassword ?? "" },
                set: { settings.proxyPassword = $0.isEmpty ? nil : $0 }
            ))
            .disabled(!settings.proxyEnabled)
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - 高级

struct AdvancedSettingsView: View {
    @Binding var settings: AppSettings
    @Binding var loginItemStatus: String
    var apply: () -> Void

    var body: some View {
        Form {
            Toggle("启用限速", isOn: Binding(
                get: { settings.speedLimitBps > 0 },
                set: { settings.speedLimitBps = $0 ? 5 * 1024 * 1024 : 0 }
            ))
            if settings.speedLimitBps > 0 {
                VStack(alignment: .leading) {
                    Slider(
                        value: Binding(
                            get: { Double(settings.speedLimitBps) },
                            set: { settings.speedLimitBps = Int64($0) }
                        ),
                        in: 100_000...200_000_000,
                        step: 100_000
                    )
                    Text("限速：\(Format.speed(Double(settings.speedLimitBps)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Toggle("开机自动启动", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        apply()
                        setLoginItem(newValue)
                    }
                ))
                Spacer()
                Text(loginItemStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("设置更改后自动生效。下载目录不存在时会自动创建。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func setLoginItem(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                    loginItemStatus = "已开启"
                } else {
                    try SMAppService.mainApp.unregister()
                    loginItemStatus = "未开启"
                }
            } catch {
                loginItemStatus = "设置失败：\(error.localizedDescription)"
            }
        }
    }
}
