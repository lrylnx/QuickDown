import SwiftUI
import QuickDownCore

// MARK: - 主窗口

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            // 左侧列表：自定义 ScrollView + 行（不用 List —— List 的选中机制与任何点击手势
            // 冲突，单击选中会失灵；改用 AppKit 点击识别器，单击/双击完全可控）
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.records) { rec in
                        DownloadRow(rec: rec)
                            .contentShape(Rectangle())
                            .background(rec.id == model.selectedID
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.clear)
                            .overlay(RowClickHandler(
                                onSelect: { model.selectedID = rec.id },
                                onDouble: { model.openFile(rec) }))
                            .contextMenu { rowMenu(rec) }
                    }
                }
            }
            .overlay {
                if model.records.isEmpty {
                    EmptyListView()
                }
            }
            .frame(width: 430)
            .frame(maxHeight: .infinity)

            Divider()

            // 右侧详情：内容在内部切换，面板本身保持稳定
            ZStack {
                if let sel = model.selectedID,
                   let rec = model.records.first(where: { $0.id == sel }) {
                    DetailView(rec: rec)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("选择一个下载任务查看详情")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("速下下载管理器")
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { StatusBarView() }
        .sheet(isPresented: $model.showAddSheet) {
            AddURLSheet()
                .environmentObject(model)
        }
        // Delete 键：删除选中的记录（仅移除列表，文件保留）
        .onDeleteCommand {
            if let id = model.selectedID {
                model.cancel(id)
            }
        }
        // 初始化菜单栏状态项（左键打开主界面 / 右键菜单），并捕获 openWindow 能力
        .onAppear {
            StatusItemController.shared.setup(model: model)
            let action = openWindowEnv
            StatusItemController.shared.setOpenWindow {
                action(id: "main")
            }
        }
    }

    @Environment(\.openWindow) private var openWindowEnv

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // 删除选中的下载记录（放在最左侧，紧邻新建下载）
            Button {
                if let id = model.selectedID {
                    model.cancel(id)
                }
            } label: {
                Label("删除记录", systemImage: "trash")
            }
            .disabled(model.selectedID == nil)
            .help("删除选中的下载记录（文件保留在下载目录）")

            Divider()

            Button {
                model.showAddSheet = true
            } label: {
                Label("新建下载", systemImage: "plus")
            }
            .help("新建下载 (⌘N)")

            Button {
                model.resumeAll()
            } label: {
                Label("全部开始", systemImage: "play.fill")
            }
            .help("全部开始")

            Button {
                model.pauseAll()
            } label: {
                Label("全部暂停", systemImage: "pause.fill")
            }
            .help("全部暂停")
        }
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.openDownloadFolder()
            } label: {
                Label("打开下载目录", systemImage: "folder")
            }
            .help("打开下载目录")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
    }

    private func openSettings() {
        // 触发主菜单里的「设置…」菜单项（与 Cmd+, 相同路径，SwiftUI Settings 场景注册的菜单项必定可用）
        if let mainMenu = NSApp.mainMenu {
            if performSettingsItem(in: mainMenu.items) { return }
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

    @ViewBuilder
    private func rowMenu(_ rec: DownloadRecord) -> some View {
        Button("暂停") { model.pause(rec.id) }
            .disabled(!rec.isActive)
        Button("继续") { model.resume(rec.id) }
            .disabled(rec.status != .paused && rec.status != .error)
        Button("重试") { model.retry(rec.id) }
            .disabled(rec.status != .error && rec.status != .paused)
        Button("重命名…") { promptRename(rec) }
        Divider()
        Button("打开文件夹") { model.revealInFinder(rec) }
            .disabled(rec.status != .completed)
        Button("复制链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rec.url, forType: .string)
        }
        Divider()
        Button("删除记录") { model.cancel(rec.id) }
            .help("仅从列表移除，文件保留")
        Button("删除记录和文件", role: .destructive) { model.cancel(rec.id, deleteFile: true) }
            .disabled(rec.status != .completed)
    }

    private func promptRename(_ rec: DownloadRecord) {
        let alert = NSAlert()
        alert.messageText = "重命名文件"
        alert.informativeText = "输入新的文件名（含扩展名，如 xxx.zip）："
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = rec.filename
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                model.rename(rec.id, to: name)
            }
        }
    }
}

// MARK: - 空状态

struct EmptyListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("暂无下载任务")
                .font(.headline)
            Text("点击右上角「+」新建下载；\n或在浏览器中点击下载链接，速下会自动接管。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                model.showAddSheet = true
            } label: {
                Label("新建下载", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - 分类标签

struct CategoryTag: View {
    let category: DownloadCategory

    var body: some View {
        Text(category.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    var color: Color {
        switch category {
        case .video: return .red
        case .music: return .purple
        case .archive: return .orange
        case .image: return .blue
        case .application: return .green
        case .document: return .teal
        case .code: return .indigo
        case .other: return .gray
        }
    }
}

// MARK: - 列表行点击识别器（AppKit 原生，单击/双击互不干扰）

/// 行的透明点击层：单击选中 + 双击打开
struct RowClickHandler: NSViewRepresentable {
    let onSelect: () -> Void
    let onDouble: () -> Void

    func makeNSView(context: Context) -> RowClickNSView {
        let view = RowClickNSView()
        view.onSelect = onSelect
        view.onDouble = onDouble
        let single = NSClickGestureRecognizer(target: view, action: #selector(RowClickNSView.singleClicked(_:)))
        single.numberOfClicksRequired = 1
        single.delaysPrimaryMouseButtonEvents = false // 单击立即响应
        let dbl = NSClickGestureRecognizer(target: view, action: #selector(RowClickNSView.doubleClicked(_:)))
        dbl.numberOfClicksRequired = 2
        dbl.delaysPrimaryMouseButtonEvents = true
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(dbl)
        return view
    }

    func updateNSView(_ nsView: RowClickNSView, context: Context) {
        nsView.onSelect = onSelect
        nsView.onDouble = onDouble
    }
}

final class RowClickNSView: NSView {
    var onSelect: (() -> Void)?
    var onDouble: (() -> Void)?

    @objc func singleClicked(_ sender: NSClickGestureRecognizer) {
        onSelect?()
    }

    @objc func doubleClicked(_ sender: NSClickGestureRecognizer) {
        onDouble?()
    }

    // 让右键事件向上传递，保证 SwiftUI contextMenu 正常工作
    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }
}

// MARK: - 列表行

struct DownloadRow: View {
    @EnvironmentObject private var model: AppModel
    let rec: DownloadRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Format.fileIcon(rec))
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(rec.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if rec.isActive || rec.status == .paused {
                    ProgressView(value: rec.progress >= 0 ? rec.progress : 0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                }

                Text(Format.statusText(rec, speed: model.speeds[rec.id]))
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                CategoryTag(category: rec.category)
                if rec.status == .downloading, let s = model.speeds[rec.id], s > 0 {
                    Text(Format.speed(s))
                        .font(.caption)
                        .monospacedDigit()
                }
                let shownSize = rec.totalSize > 0 ? rec.totalSize : rec.downloadedSize
                Text(shownSize > 0 ? Format.bytes(shownSize) : "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch rec.status {
        case .error: return .red
        case .completed: return .green
        case .paused: return .orange
        case .cancelled: return .secondary
        default: return .secondary
        }
    }
}

// MARK: - 详情面板

struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    let rec: DownloadRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: Format.fileIcon(rec))
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.filename)
                        .font(.headline)
                        .lineLimit(2)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            .padding(.top, 8)

            if rec.isActive || rec.status == .paused {
                ProgressView(value: rec.progress >= 0 ? rec.progress : 0)
                    .progressViewStyle(.linear)
                HStack {
                    Text(rec.progress >= 0 ? String(format: "%.1f%%", rec.progress * 100) : "大小未知")
                        .font(.caption)
                    Spacer()
                    if let s = model.speeds[rec.id], s > 0 {
                        Text("\(Format.speed(s)) · 剩余\(Format.eta(remaining: rec.totalSize - rec.downloadedSize, speed: s))")
                            .font(.caption)
                    }
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("状态").gridColumnAlignment(.trailing); Text(statusText).foregroundStyle(statusColor) }
                GridRow { Text("分类"); CategoryTag(category: rec.category) }
                if rec.totalSize > 0 {
                    GridRow { Text("大小"); Text(Format.bytes(rec.totalSize)) }
                }
                if rec.downloadedSize > 0 {
                    GridRow { Text("已下载"); Text(Format.bytes(rec.downloadedSize)) }
                }
                GridRow { Text("分段"); Text(rec.isSingle ? "单连接" : "\(rec.segments.count) 段") }
                GridRow { Text("创建"); Text(Format.date(rec.createdAt)) }
                if let c = rec.completedAt {
                    GridRow { Text("完成"); Text(Format.date(c)) }
                }
                GridRow { Text("目录"); Text(rec.directory).lineLimit(2).truncationMode(.middle) }
                GridRow { Text("链接"); Text(rec.url).lineLimit(3).truncationMode(.middle) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            // 底部操作按钮：预留充足安全边距，避免被窗口底边/状态栏遮挡
            HStack(spacing: 10) {
                actionButton
                Button {
                    model.revealInFinder(rec)
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
                .disabled(rec.status != .completed)
            }
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch rec.status {
        case .downloading, .connecting, .queued:
            Button { model.pause(rec.id) } label: { Label("暂停", systemImage: "pause.fill") }
        case .paused:
            Button { model.resume(rec.id) } label: { Label("继续", systemImage: "play.fill") }
        case .error:
            Button { model.retry(rec.id) } label: { Label("重试", systemImage: "arrow.clockwise") }
        case .completed:
            Button { model.cancel(rec.id) } label: { Label("删除记录", systemImage: "trash") }
                .help("仅从列表移除，文件保留在下载目录")
        case .cancelled:
            EmptyView()
        }
    }

    private var statusText: String {
        Format.statusText(rec, speed: model.speeds[rec.id])
    }

    private var statusColor: Color {
        switch rec.status {
        case .error: return .red
        case .completed: return .green
        case .paused: return .orange
        default: return .secondary
        }
    }
}

// MARK: - 底部状态栏

struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Label("进行中 \(model.activeCount)/\(model.records.count)", systemImage: "arrow.down.circle")
            if model.totalSpeed > 0 {
                Label(Format.speed(model.totalSpeed), systemImage: "gauge.with.dots.needle.67percent")
            }
            Spacer()
            if model.serverPort > 0 {
                Label("扩展端口 \(model.serverPort)", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            } else {
                Label("本地服务未启动", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - 新建下载

struct AddURLSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var filename = ""
    @State private var directory = SettingsStore.shared.settings.downloadDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建下载")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("下载链接")
                TextField("https://…", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .onAppear {
                        if let s = NSPasteboard.general.string(forType: .string),
                           s.hasPrefix("http"), s.contains("://") {
                            url = s
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("文件名（可选）")
                TextField("留空则自动识别", text: $filename)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("保存位置")
                HStack {
                    TextField("", text: $directory)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            directory = url.path
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("开始下载") {
                    model.add(urlString: url, filename: filename.isEmpty ? nil : filename,
                              directory: directory.isEmpty ? nil : directory)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var isValid: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), u.scheme != nil else { return false }
        return true
    }
}
