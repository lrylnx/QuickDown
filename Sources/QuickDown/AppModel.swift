import Foundation
import SwiftUI
import UserNotifications
import QuickDownCore

// MARK: - 应用模型（连接引擎与界面）

@MainActor
final class AppModel: ObservableObject {

    let manager: DownloadManager
    private var server: LocalServer?

    @Published var records: [DownloadRecord] = []
    @Published var selectedID: UUID?
    @Published var speeds: [UUID: Double] = [:]
    @Published var serverPort: UInt16 = 10007
    @Published var showAddSheet = false
    /// 等待确认的接管任务 id 队列（确认窗口逐个展示）
    @Published var confirmQueue: [UUID] = []

    private var lastSnapshot: [UUID: (bytes: Int64, date: Date)] = [:]
    private var ticker: Timer?
    private var speedEMA: [UUID: Double] = [:]

    init() {
        manager = DownloadManager.shared
        manager.onChange = { [weak self] in
            Task { @MainActor in
                self?.needsRefresh = true
                self?.refresh()
            }
        }
        manager.onCompleted = { [weak self] rec in
            Task { @MainActor in self?.notifyCompleted(rec) }
        }
        // 浏览器接管下载时，唤起主窗口（扩展端 /add 成功触发）
        NotificationCenter.default.addObserver(forName: .quickdownShowMainWindow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showMainWindow() }
        }
        // 接管确认流程：/add 到达且开启确认时，弹「确认下载」窗口（可重命名/选位置）
        NotificationCenter.default.addObserver(forName: .quickdownConfirmDownload, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let uuidString = note.object as? String,
                  let id = UUID(uuidString: uuidString) else { return }
            Task { @MainActor in self.enqueueConfirm(id) }
        }
        startServer()
        refresh()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// 显示主窗口（菜单栏左键 / 接管下载 / 通知触发）
    func showMainWindow() {
        StatusItemController.shared.showMainWindow()
    }

    // MARK: - 接管确认窗口

    private func enqueueConfirm(_ id: UUID) {
        guard !confirmQueue.contains(id) else { return }
        confirmQueue.append(id)
        showConfirmWindow()
    }

    /// 弹出「确认下载」窗口（唤起应用 + 打开窗口场景）
    func showConfirmWindow() {
        NSApp.activate(ignoringOtherApps: true)
        StatusItemController.shared.showConfirmWindow()
    }

    /// 确认窗口当前展示的任务记录
    var currentConfirmRecord: DownloadRecord? {
        guard let id = confirmQueue.first else { return nil }
        return records.first { $0.id == id }
    }

    /// 「开始下载」：应用重命名/目录修改并恢复任务
    func confirmCapture(id: UUID, filename: String, directory: String) {
        if let rec = records.first(where: { $0.id == id }) {
            let nameChanged = filename.trimmingCharacters(in: .whitespaces) != rec.filename
            let dirChanged = directory != rec.directory
            if nameChanged || dirChanged {
                manager.setSaveLocation(id, filename: filename, directory: directory)
            }
            manager.resume(id)
        }
        advanceConfirmQueue()
    }

    /// 「取消」：移除该任务（尚未开始下载，无文件残留）
    func cancelCapture(id: UUID) {
        manager.cancel(id)
        advanceConfirmQueue()
    }

    private func advanceConfirmQueue() {
        if !confirmQueue.isEmpty { confirmQueue.removeFirst() }
        // 队列清空后由确认窗口视图自行 dismiss；还有后续任务则保持在窗口中逐个确认
    }

    // MARK: - 服务器

    func startServer() {
        let port = SettingsStore.shared.settings.serverPort
        let server = LocalServer(manager: manager, port: port)
        do {
            try server.start()
            serverPort = server.port
        } catch {
            serverPort = 0
        }
        self.server = server
    }

    // MARK: - 刷新

    private var hasAutoSelected = false

    func refresh() {
        records = manager.snapshot()
        // 待确认任务被删除（如用户在主列表手动移除）时同步清理确认队列
        if !confirmQueue.isEmpty {
            let ids = Set(records.map { $0.id })
            confirmQueue.removeAll { !ids.contains($0) }
        }
        // 选中项被删除时：自动选中列表第一条（支持连续删除）。
        // 注意：用户主动点击空白处取消选择（selectedID 为 nil）不会触发此处，避免闪烁。
        if let sel = selectedID, !records.contains(where: { $0.id == sel }) {
            selectedID = records.first?.id
        }
        // 首次出现记录时默认选中第一条
        if !hasAutoSelected, selectedID == nil, let first = records.first {
            selectedID = first.id
            hasAutoSelected = true
        }
    }

    private var needsRefresh = false

    private func tick() {
        // 空闲静默优化：无活动下载且无新变化时直接返回（零开销），
        // 避免每 0.5 秒给 UI 赋值触发无谓的重绘
        let hasActive = records.contains { $0.isActive }
        guard hasActive || needsRefresh else { return }
        needsRefresh = false

        refresh()

        guard hasActive else {
            // 无活动下载：清空速度缓存，菜单栏只显示图标
            lastSnapshot.removeAll()
            speedEMA.removeAll()
            speeds = [:]
            StatusItemController.shared.updateSpeed("")
            return
        }

        let now = Date()
        var newSpeeds: [UUID: Double] = [:]
        for rec in records {
            guard rec.status == .downloading || rec.status == .connecting else { continue }
            let prev = lastSnapshot[rec.id]
            if let prev {
                let dt = now.timeIntervalSince(prev.date)
                if dt > 0.05 {
                    let inst = Double(rec.downloadedSize - prev.bytes) / dt
                    let ema = speedEMA[rec.id] ?? inst
                    let smoothed = ema * 0.6 + inst * 0.4
                    speedEMA[rec.id] = smoothed
                    newSpeeds[rec.id] = max(0, smoothed)
                }
            }
            lastSnapshot[rec.id] = (rec.downloadedSize, now)
        }
        speeds = newSpeeds
        // 清理不再活跃的记录
        let activeIDs = Set(records.filter { $0.status == .downloading || $0.status == .connecting }.map { $0.id })
        lastSnapshot = lastSnapshot.filter { activeIDs.contains($0.key) }
        speedEMA = speedEMA.filter { activeIDs.contains($0.key) }
        // 菜单栏实时速度显示
        let total = speeds.values.reduce(0, +)
        StatusItemController.shared.updateSpeed(total > 0 ? Format.speed(total) : "")
    }

    var totalSpeed: Double {
        speeds.values.reduce(0, +)
    }

    var activeCount: Int {
        records.filter { $0.isActive }.count
    }

    // MARK: - 操作

    func add(urlString: String, filename: String?, directory: String?) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return }
        let req = NewDownloadRequest(url: trimmed,
                                     filename: filename?.isEmpty == false ? filename : nil,
                                     directory: directory?.isEmpty == false ? directory : nil)
        manager.add(req)
    }

    func pause(_ id: UUID) { manager.pause(id) }
    func resume(_ id: UUID) { manager.resume(id) }
    func cancel(_ id: UUID, deleteFile: Bool = false) { manager.cancel(id, deleteFile: deleteFile) }
    func retry(_ id: UUID) { manager.retry(id) }
    func rename(_ id: UUID, to newName: String) { manager.rename(id, to: newName) }
    func pauseAll() { manager.pauseAll() }
    func resumeAll() { manager.resumeAll() }
    func removeCompleted() { manager.removeCompleted() }

    func revealInFinder(_ rec: DownloadRecord) {
        let path: String
        if let finalPath = rec.finalPath, FileManager.default.fileExists(atPath: finalPath) {
            path = finalPath
        } else {
            path = rec.directory
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 双击打开：已完成直接打开文件，未完成打开所在目录
    func openFile(_ rec: DownloadRecord) {
        if rec.status == .completed,
           let finalPath = rec.finalPath,
           FileManager.default.fileExists(atPath: finalPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: finalPath))
        } else {
            revealInFinder(rec)
        }
    }

    func openDownloadFolder() {
        let dir = SettingsStore.shared.settings.downloadDirectory
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    // MARK: - 通知

    private func notifyCompleted(_ rec: DownloadRecord) {
        guard SettingsStore.shared.settings.notifyOnComplete else { return }
        // 右下角 toast：文件名 + 打开文件/打开文件夹（非激活面板，不抢焦点）
        CompletionToast.shared.show(filename: rec.filename,
                                    filePath: rec.finalPath,
                                    directory: rec.directory)
        // UNUserNotificationCenter 在无 .app 包体的裸进程中会直接抛异常（开发调试场景），
        // 正常安装运行（有 bundle id）才发通知
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "下载完成"
        content.body = rec.filename
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        center.add(UNNotificationRequest(identifier: rec.id.uuidString, content: content, trigger: trigger))
    }

    // MARK: - 设置变更

    func applySettings() {
        let s = SettingsStore.shared.settings
        manager.updateSettings(s)
        if server?.port != s.serverPort || server == nil {
            startServer()
        }
        StatusItemController.shared.applyIconStyle()
    }
}

// MARK: - 格式化工具

enum Format {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func speed(_ bps: Double) -> String {
        let b = Int64(bps)
        if b <= 0 { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file) + "/s"
    }

    static func eta(remaining: Int64, speed: Double) -> String {
        guard speed > 0, remaining > 0 else { return "—" }
        let secs = Int(Double(remaining) / speed)
        if secs < 60 { return "\(secs)秒" }
        if secs < 3600 { return "\(secs / 60)分\(secs % 60)秒" }
        return "\(secs / 3600)时\((secs % 3600) / 60)分"
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func statusText(_ rec: DownloadRecord, speed: Double?) -> String {
        switch rec.status {
        case .queued: return "排队中"
        case .connecting: return "连接中…"
        case .downloading:
            if let hls = rec.hlsInfo, hls.total > 0 {
                return "视频分片 \(hls.done)/\(hls.total) · \(Format.speed(speed ?? 0))"
            }
            if rec.totalSize > 0 {
                let pct = String(format: "%.1f%%", rec.progress * 100)
                if let s = speed, s > 0 {
                    return "\(pct) · \(Format.speed(s)) · 剩余\(Format.eta(remaining: rec.totalSize - rec.downloadedSize, speed: s))"
                }
                return pct
            }
            return "下载中 · \(Format.speed(speed ?? 0))"
        case .paused: return "已暂停"
        case .completed:
            let size = rec.totalSize > 0 ? rec.totalSize : rec.downloadedSize
            return "已完成 · \(Format.bytes(size))"
        case .error: return "出错：\(rec.errorMessage ?? "未知错误")"
        case .cancelled: return "已取消"
        }
    }

    static func fileIcon(_ rec: DownloadRecord) -> String {
        let ext = (rec.filename as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso", "apk", "exe", "msi": return "doc.zipper"
        case "mp4", "mkv", "avi", "mov", "flv", "webm", "ts", "m4v", "mpg", "mpeg": return "film"
        case "mp3", "wav", "flac", "aac", "ogg", "m4a", "wma": return "music.note"
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "heic": return "photo"
        case "txt", "md", "log", "srt", "vtt": return "doc.plaintext"
        case "xls", "xlsx", "csv", "numbers": return "tablecells"
        case "doc", "docx", "pages": return "doc.text"
        case "ppt", "pptx", "key": return "chart.bar"
        case "html", "htm", "css", "js", "json", "xml": return "chevron.left.forwardslash.chevron.right"
        default: return "arrow.down.doc"
        }
    }
}
