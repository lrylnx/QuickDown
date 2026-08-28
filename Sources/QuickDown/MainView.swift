import SwiftUI
import QuickDownCore

// MARK: - 主窗口

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)

            // 右侧详情：内容在内部切换，面板本身保持稳定
            ZStack {
                if let sel = model.selectedID,
                   let rec = model.records.first(where: { $0.id == sel }) {
                    DetailView(rec: rec)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("选择一个下载任务查看详情")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("下载任务")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(model.records.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.records) { rec in
                        DownloadRow(rec: rec)
                            .contextMenu { rowMenu(rec) }
                    }
                }
                .padding(.bottom, 10)
            }
            .overlay {
                if model.records.isEmpty {
                    EmptyListView()
                }
            }
        }
        .frame(width: 430)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

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
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(QDTheme.accent.opacity(0.10))
                    .frame(width: 92, height: 92)
                Circle()
                    .fill(QDTheme.accent.opacity(0.05))
                    .frame(width: 68, height: 68)
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(QDTheme.accentGradient)
            }

            VStack(spacing: 5) {
                Text("暂无下载任务")
                    .font(.headline)
                Text("点击「新建下载」开始，\n或在浏览器中点击下载链接，速下会自动接管。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button {
                model.showAddSheet = true
            } label: {
                Label("新建下载", systemImage: "plus")
            }
            .buttonStyle(QDPrimaryButtonStyle())
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
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(category.color.opacity(0.14)))
            .foregroundStyle(category.color)
            .overlay(Capsule().stroke(category.color.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - 列表行点击识别器（AppKit 原生，单击/双击互不干扰）
// 在原有单击/双击基础上补充鼠标悬停跟踪，用于行高亮反馈。

struct RowClickHandler: NSViewRepresentable {
    let onSelect: () -> Void
    let onDouble: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> RowClickNSView {
        let view = RowClickNSView()
        view.onSelect = onSelect
        view.onDouble = onDouble
        view.onHover = onHover
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
        nsView.onHover = onHover
    }
}

final class RowClickNSView: NSView {
    var onSelect: (() -> Void)?
    var onDouble: (() -> Void)?
    var onHover: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }

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
    @State private var hovering = false
    /// 进度条是否可见：下载/暂停/出错始终可见；完成项仅在“本次会话刚完成”时显示 1 秒后淡出，
    /// 避免列表长期堆满绿色进度条。布局槽位固定保留，行高不跳。
    @State private var showProgressBar = true

    private var isSelected: Bool { rec.id == model.selectedID }

    var body: some View {
        HStack(spacing: 10) {
            QDCategoryIcon(symbol: Format.fileIcon(rec),
                           color: rec.category.color,
                           size: 34)

            // 固定三行结构，任何状态下高度一致：文件名行 + 进度条行 + 状态信息行，切换不跳动
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rec.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    CategoryTag(category: rec.category)
                }

                QDProgressBar(value: rec.progress >= 0 ? rec.progress : 0,
                              height: 5,
                              gradient: progressGradient)
                    .opacity(showProgressBar ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: showProgressBar)

                HStack(spacing: 5) {
                    StatusDot(color: statusColor, size: 6)
                    Text(Format.statusText(rec, speed: model.speeds[rec.id]))
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    sizeText
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
        .overlay(RowClickHandler(
            onSelect: { model.selectedID = rec.id },
            onDouble: { model.openFile(rec) },
            onHover: { hovering = $0 }))
        .onAppear {
            // 首次出现时若已是完成状态（如启动后、切换筛选），不显示绿色进度条
            if rec.status == .completed { showProgressBar = false }
        }
        .onChange(of: rec.status) { newStatus in
            // 仅在本次会话内真正“完成”的那一刻，绿色进度条显示 1 秒后淡出
            if newStatus == .completed {
                withAnimation(.easeInOut(duration: 0.25)) { showProgressBar = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeOut(duration: 0.5)) { showProgressBar = false }
                }
            }
        }
    }

    /// 进度条颜色随状态变化：下载中品牌渐变、完成绿色、暂停橙色、出错红色
    private var progressGradient: LinearGradient {
        switch rec.status {
        case .completed:
            return LinearGradient(colors: [Color(red: 0.24, green: 0.70, blue: 0.45),
                                           Color(red: 0.35, green: 0.85, blue: 0.58)],
                                  startPoint: .leading, endPoint: .trailing)
        case .paused:
            return LinearGradient(colors: [Color(red: 0.96, green: 0.60, blue: 0.25),
                                           Color(red: 0.98, green: 0.70, blue: 0.38)],
                                  startPoint: .leading, endPoint: .trailing)
        case .error:
            return LinearGradient(colors: [Color(red: 0.95, green: 0.38, blue: 0.36),
                                           Color(red: 0.98, green: 0.55, blue: 0.42)],
                                  startPoint: .leading, endPoint: .trailing)
        default:
            return QDTheme.accentGradient
        }
    }

    private var sizeText: some View {
        let shownSize = rec.totalSize > 0 ? rec.totalSize : rec.downloadedSize
        return Text(shownSize > 0 ? Format.bytes(shownSize) : "—")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }

    private var backgroundColor: Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if hovering { return Color.primary.opacity(0.045) }
        return .clear
    }

    private var statusColor: Color {
        rec.status.color
    }
}

// MARK: - 详情面板

struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    let rec: DownloadRecord

    var body: some View {
        // 所有状态共用同一结构（头部 + 信息卡片 + 操作按钮），无独立进度条卡片，切换不跳动
        VStack(alignment: .leading, spacing: 14) {
            header

            infoCard

            Spacer(minLength: 12)

            // 底部操作按钮：预留充足安全边距，避免被窗口底边/状态栏遮挡
            HStack(spacing: 10) {
                actionButton
                Button {
                    model.revealInFinder(rec)
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(rec.status != .completed)
            }
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 14) {
            QDCategoryIcon(symbol: Format.fileIcon(rec),
                           color: rec.category.color,
                           size: 50)
            VStack(alignment: .leading, spacing: 5) {
                Text(rec.filename)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    StatusDot(color: statusColor, size: 8)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    // MARK: 信息卡片

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("详细信息")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                GridRow {
                    infoLabel("状态")
                    Text(statusText)
                        .foregroundStyle(statusColor)
                        .gridColumnAlignment(.leading)
                }
                GridRow {
                    infoLabel("分类")
                    CategoryTag(category: rec.category)
                }
                if rec.progress >= 0 {
                    GridRow {
                        infoLabel("进度")
                        Text(String(format: "%.1f%%", rec.progress * 100)).monospacedDigit()
                    }
                }
                if rec.totalSize > 0 {
                    GridRow {
                        infoLabel("大小")
                        Text(Format.bytes(rec.totalSize)).monospacedDigit()
                    }
                }
                if rec.downloadedSize > 0 {
                    GridRow {
                        infoLabel("已下载")
                        Text(Format.bytes(rec.downloadedSize)).monospacedDigit()
                    }
                }
                GridRow {
                    infoLabel("分段")
                    Text(rec.isSingle ? "单连接" : "\(rec.segments.count) 段")
                }
                GridRow {
                    infoLabel("创建")
                    Text(Format.date(rec.createdAt)).monospacedDigit()
                }
                if let c = rec.completedAt {
                    GridRow {
                        infoLabel("完成")
                        Text(Format.date(c)).monospacedDigit()
                    }
                }
                GridRow {
                    infoLabel("目录")
                    Text(rec.directory).lineLimit(2).truncationMode(.middle)
                }
                GridRow {
                    infoLabel("链接")
                    Text(rec.url).lineLimit(3).truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .qdCard()
    }

    private func infoLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.tertiary)
            .gridColumnAlignment(.trailing)
    }

    // MARK: 操作按钮

    @ViewBuilder
    private var actionButton: some View {
        switch rec.status {
        case .downloading, .connecting, .queued:
            Button { model.pause(rec.id) } label: { Label("暂停", systemImage: "pause.fill") }
                .buttonStyle(QDPrimaryButtonStyle())
        case .paused:
            Button { model.resume(rec.id) } label: { Label("继续", systemImage: "play.fill") }
                .buttonStyle(QDPrimaryButtonStyle())
        case .error:
            Button { model.retry(rec.id) } label: { Label("重试", systemImage: "arrow.clockwise") }
                .buttonStyle(QDPrimaryButtonStyle())
        case .completed:
            Button { model.cancel(rec.id) } label: { Label("删除记录", systemImage: "trash") }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
                .help("仅从列表移除，文件保留在下载目录")
        case .cancelled:
            EmptyView()
        }
    }

    private var statusText: String {
        Format.statusText(rec, speed: model.speeds[rec.id])
    }

    private var statusColor: Color {
        rec.status.color
    }
}

// MARK: - 底部状态栏

struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                StatusDot(color: model.activeCount > 0 ? QDTheme.accent : .secondary, size: 6)
                Text("进行中 \(model.activeCount)/\(model.records.count)")
            }
            if model.totalSpeed > 0 {
                Label(Format.speed(model.totalSpeed), systemImage: "gauge.with.dots.needle.67percent")
                    .foregroundStyle(.secondary)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                QDCategoryIcon(symbol: "link", color: QDTheme.accent, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("新建下载")
                        .font(.title3.bold())
                    Text("粘贴下载链接，其余可留空")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("下载链接")
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
                fieldLabel("文件名（可选）")
                TextField("留空则自动识别", text: $filename)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("保存位置")
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
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("开始下载") {
                    model.add(urlString: url, filename: filename.isEmpty ? nil : filename,
                              directory: directory.isEmpty ? nil : directory)
                    dismiss()
                }
                .buttonStyle(QDPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var isValid: Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), u.scheme != nil else { return false }
        return true
    }
}
