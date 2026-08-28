import SwiftUI
import QuickDownCore

// MARK: - 接管确认窗口
//
// 浏览器扩展接管下载且设置开启「接管后确认」时弹出：
// 展示任务信息，可重命名文件、选择保存位置，点「开始下载」或「取消」。
// 多个任务排队时逐个确认（窗口内自动切换到下一个）。

struct CaptureConfirmView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let rec = model.currentConfirmRecord {
            CaptureConfirmContent(rec: rec)
                .id(rec.id) // 切换到下一个任务时整体重建，重置编辑状态
        } else {
            // 队列已空：自动关闭窗口
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { dismiss() }
        }
    }
}

private struct CaptureConfirmContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let rec: DownloadRecord

    @State private var filename = ""
    @State private var directory = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            filenameField
            directoryField
            landingHint
            queueHint
            Divider()
            buttons
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            filename = rec.filename
            directory = rec.directory
        }
        .onChange(of: model.confirmQueue) { queue in
            if queue.isEmpty { dismiss() }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            QDCategoryIcon(symbol: Format.fileIcon(rec), color: QDTheme.accent, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("确认下载")
                    .font(.title3.bold())
                Text(rec.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(rec.url)
            }
        }
    }

    // MARK: 文件名

    private var filenameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文件名")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("文件名", text: $filename)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: 保存位置

    private var directoryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("保存位置")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack {
                TextField("", text: $directory)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
                    if panel.runModal() == .OK, let url = panel.url {
                        directory = url.path
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("选择保存文件夹")
            }
        }
    }

    /// 开启分类时提示实际落地目录（与主界面新建下载行为一致）
    private var landingHint: some View {
        let landing = categoryFolder(for: directory)
        return Group {
            if !landing.isEmpty, landing != directory {
                Text("将保存到分类文件夹：\(landing)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryFolder(for dir: String) -> String {
        guard SettingsStore.shared.settings.sortIntoCategories else { return "" }
        let ext = (filename as NSString).pathExtension
        let category = DownloadCategory.from(extension: ext).rawValue
        return (dir as NSString).appendingPathComponent(category)
    }

    // MARK: 队列提示

    @ViewBuilder
    private var queueHint: some View {
        if model.confirmQueue.count > 1 {
            Text("第 1 个，共 \(model.confirmQueue.count) 个下载等待确认")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 按钮

    private var buttons: some View {
        HStack {
            Spacer()
            Button("取消") {
                model.cancelCapture(id: rec.id)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            Button("开始下载") {
                model.confirmCapture(id: rec.id, filename: filename, directory: directory)
            }
            .buttonStyle(QDPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
    }

    private var isValid: Bool {
        !filename.trimmingCharacters(in: .whitespaces).isEmpty && !directory.isEmpty
    }
}
