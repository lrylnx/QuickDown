import Foundation

// MARK: - 下载管理器（并发队列 + 生命周期）

public final class DownloadManager: @unchecked Sendable {
    public static let shared = DownloadManager()

    private let lock = NSLock()
    private var boxes: [UUID: DownloadStateBox] = [:]
    private var tasks: [UUID: DownloadTask] = [:]
    private var settings: AppSettings
    private let limiter = RateLimiter(limitBps: 0)
    private var saveTimer: Timer?
    private let store: DownloadStore

    /// 任何状态变化（主线程回调）
    public var onChange: (() -> Void)?
    /// 单个下载完成（主线程回调）
    public var onCompleted: ((DownloadRecord) -> Void)?

    public init(settings: AppSettings? = nil, store: DownloadStore? = nil) {
        self.settings = settings ?? SettingsStore.shared.settings
        self.store = store ?? DownloadStore.shared
        loadPersisted()
        // 启动后清理下载目录里不属于任何任务的孤儿 .part 分片
        // （上次退出时被中断/崩溃/记录被删但分片残留的临时文件）。
        // 后台执行，避免拖慢启动；仅删除无主分片，不影响断点续传。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.cleanupOrphanPartFiles()
        }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 静默优化：仅在有活动下载时周期保存进度（供断点恢复）；
            // 空闲时的状态变化已在各操作中即时保存，无需定时写盘
            self.lock.lock()
            let hasActive = !self.tasks.isEmpty
            self.lock.unlock()
            if hasActive {
                self.persist()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    public func updateSettings(_ s: AppSettings) {
        lock.lock()
        settings = s
        limiter.limitBps = s.speedLimitBps
        lock.unlock()
        SettingsStore.shared.update { $0 = s }
        startNext()
    }

    // MARK: - 快照

    public func snapshot() -> [DownloadRecord] {
        lock.lock()
        let recs = boxes.values.map { $0.record }
        lock.unlock()
        return recs.sorted { a, b in
            let rankA = statusRank(a.status)
            let rankB = statusRank(b.status)
            if rankA != rankB { return rankA < rankB }
            return a.createdAt > b.createdAt
        }
    }

    private func statusRank(_ s: DownloadStatus) -> Int {
        switch s {
        case .downloading, .connecting, .queued: return 0
        case .paused: return 1
        case .error: return 2
        case .completed: return 3
        case .cancelled: return 4
        }
    }

    // MARK: - 增删改

    /// 新增下载。autoStart=false 时以「已暂停」状态入列（接管确认流程用），
    /// 由确认窗口或用户手动恢复。
    @discardableResult
    public func add(_ request: NewDownloadRequest, autoStart: Bool = true) -> UUID {
        var filename = request.filename ?? ""
        if let url = URL(string: request.url) {
            let derived = FileNaming.filename(fromURL: url)
            if filename.isEmpty {
                filename = derived ?? "download"
            } else if let derived, FileNaming.looksLikeDerived(filename, url: url) {
                // 上游给的只是 URL 推导名（哈希名/通用名/路径末段）时，
                // 用 URL 查询参数里的真实文件名纠正（蓝奏云等网盘 CDN）
                filename = derived
            }
        }
        if filename.isEmpty { filename = "download" }
        let directory = request.directory ?? settings.downloadDirectory

        var record = DownloadRecord(
            url: request.url,
            filename: filename,
            directory: directory,
            status: autoStart ? .queued : .paused,
            referer: request.referer,
            userAgent: request.userAgent,
            cookie: request.cookie
        )
        let settingsCopy = settings
        record.finalPath = FileNaming.uniquePath(
            directory: record.resolvedSaveDirectory(settings: settingsCopy),
            filename: filename)

        lock.lock()
        boxes[record.id] = DownloadStateBox(record)
        lock.unlock()
        persist()
        notify()
        if autoStart {
            startNext()
        }
        return record.id
    }

    /// 更新未开始任务（paused/queued）的文件名与保存目录（接管确认窗口用）
    public func setSaveLocation(_ id: UUID, filename: String, directory: String) {
        let clean = FileNaming.sanitize(filename)
        guard !clean.isEmpty, !directory.isEmpty else { return }
        lock.lock()
        let box = boxes[id]
        let settingsCopy = settings
        lock.unlock()
        guard let box else { return }
        box.mutate { rec in
            guard rec.status == .paused || rec.status == .queued else { return }
            rec.filename = clean
            rec.directory = directory
            rec.finalPath = FileNaming.uniquePath(
                directory: rec.resolvedSaveDirectory(settings: settingsCopy),
                filename: clean)
        }
        persist()
        notify()
    }

    public func pause(_ id: UUID) {
        lock.lock()
        let task = tasks[id]
        let box = boxes[id]
        lock.unlock()
        if let task {
            task.pause()
        } else if let box {
            box.mutate { $0.status = .paused }
        }
        persist()
        notify()
    }

    public func resume(_ id: UUID) {
        lock.lock()
        let box = boxes[id]
        lock.unlock()
        guard let box else { return }
        box.mutate { rec in
            rec.status = .queued
            rec.errorMessage = nil
        }
        persist()
        notify()
        startNext()
    }

    /// 取消并删除记录；deleteFile 同时删除已下载文件。
    /// 无论该任务当前是否在运行（含已暂停/排队），都会一并清掉它自己的 .part 临时分片，
    /// 避免取消后留下孤儿临时文件堆积。
    public func cancel(_ id: UUID, deleteFile: Bool = false) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        let box = boxes.removeValue(forKey: id)
        lock.unlock()
        if let task { task.cancel() }
        if let box {
            let rec = box.record
            Self.removePartFiles(directory: rec.directory, filename: rec.filename,
                                 segments: rec.segments)
            if deleteFile {
                if let p = rec.finalPath { try? FileManager.default.removeItem(atPath: p) }
            }
        }
        persist()
        notify()
        startNext()
    }

    public func retry(_ id: UUID) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
        resume(id)
    }

    /// 重命名：更新记录、迁移 part 文件、移动/改名已完成文件（含分类文件夹变更）
    public func rename(_ id: UUID, to newName: String) {
        let clean = FileNaming.sanitize(newName)
        guard !clean.isEmpty else { return }
        lock.lock()
        guard let box = boxes[id] else {
            lock.unlock()
            return
        }
        let settingsCopy = settings
        lock.unlock()

        let old = box.record
        guard old.filename != clean else { return }

        let oldFinal = old.finalPath
        let oldSegCount = max(old.segments.count, 8)
        let oldDirectory = old.directory
        let oldFilename = old.filename

        box.mutate { rec in
            rec.filename = clean
            rec.finalPath = nil
        }

        // 迁移 part 文件（下载中/暂停的任务）
        let fm = FileManager.default
        for i in 0..<oldSegCount {
            let oldPart = (oldDirectory as NSString)
                .appendingPathComponent(FileNaming.partFileName(for: oldFilename, index: i))
            let newPart = (oldDirectory as NSString)
                .appendingPathComponent(FileNaming.partFileName(for: clean, index: i))
            if fm.fileExists(atPath: oldPart), oldPart != newPart {
                try? fm.moveItem(atPath: oldPart, toPath: newPart)
            }
        }

        // 迁移/重命名已完成文件
        let newFinal = FileNaming.uniquePath(
            directory: box.record.resolvedSaveDirectory(settings: settingsCopy),
            filename: clean)
        if let oldPath = oldFinal, fm.fileExists(atPath: oldPath) {
            try? fm.createDirectory(
                atPath: (newFinal as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            if oldPath != newFinal {
                try? fm.moveItem(atPath: oldPath, toPath: newFinal)
            }
        }

        box.mutate { rec in
            rec.finalPath = newFinal
        }
        persist()
        notify()
    }

    public func pauseAll() {
        lock.lock()
        let ids = Array(tasks.keys)
        lock.unlock()
        for id in ids { pause(id) }
    }

    public func resumeAll() {
        lock.lock()
        let ids = Array(boxes.keys)
        lock.unlock()
        for id in ids { resume(id) }
    }

    public func removeCompleted() {
        lock.lock()
        let ids = boxes.compactMap { key, box -> UUID? in
            box.record.status == .completed ? key : nil
        }
        lock.unlock()
        for id in ids {
            lock.lock()
            boxes.removeValue(forKey: id)
            lock.unlock()
        }
        persist()
        notify()
    }

    // MARK: - 调度

    private func startNext() {
        lock.lock()
        let active = tasks.count
        let maxConcurrent = max(settings.maxConcurrent, 1)
        var candidates: [UUID] = []
        if active < maxConcurrent {
            candidates = boxes.compactMap { key, box in
                box.record.status == .queued ? key : nil
            }
            candidates.sort { a, b in
                boxes[a]!.record.createdAt < boxes[b]!.record.createdAt
            }
            candidates = Array(candidates.prefix(maxConcurrent - active))
        }
        let settingsCopy = settings
        lock.unlock()

        for id in candidates {
            start(id, settings: settingsCopy)
        }
    }

    private func start(_ id: UUID, settings: AppSettings) {
        lock.lock()
        guard let box = boxes[id], tasks[id] == nil else {
            lock.unlock()
            return
        }
        let task = DownloadTask(box: box, settings: settings, limiter: limiter)
        task.onFinished = { [weak self] outcome in
            self?.handleFinished(id: id, outcome: outcome)
        }
        tasks[id] = task
        lock.unlock()

        Task { await task.start() }
    }

    private func handleFinished(id: UUID, outcome: DownloadTask.Outcome) {
        lock.lock()
        tasks.removeValue(forKey: id)
        let box = boxes[id]
        lock.unlock()

        switch outcome {
        case .completed(let path):
            if let box {
                let rec = box.record
                onCompleted?(rec)
                _ = path
            }
        case .cancelled:
            break
        case .failed:
            break
        }
        persist()
        notify()
        startNext()
    }

    // MARK: - 孤儿 .part 清理

    /// 删除指定任务的全部 .part 临时分片（取消任务时调用）。
    static func removePartFiles(directory: String, filename: String, segments: [SegmentState]) {
        let fm = FileManager.default
        for i in 0..<max(segments.count, 8) {
            let part = FileNaming.partFileName(for: filename, index: i)
            try? fm.removeItem(atPath: (directory as NSString).appendingPathComponent(part))
        }
    }

    /// 扫描下载目录，删除不属于任何已知任务的孤儿 .part 分片。
    /// 仅清理"有分片文件、但没有对应下载记录"的残留，正在下载/可续传任务的
    /// 分片（文件名与目录均与记录匹配）会被保留。
    public func cleanupOrphanPartFiles() {
        let fm = FileManager.default
        let dir = settings.downloadDirectory
        guard !dir.isEmpty, fm.fileExists(atPath: dir),
              let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }

        // 已知任务拥有的分片路径集合
        lock.lock()
        let owned: Set<String> = {
            var s = Set<String>()
            for box in boxes.values {
                let rec = box.record
                let segCount = max(rec.segments.count, 8)
                for i in 0..<segCount {
                    s.insert((rec.directory as NSString)
                        .appendingPathComponent(FileNaming.partFileName(for: rec.filename, index: i)))
                }
            }
            return s
        }()
        lock.unlock()

        var deleted = 0
        for entry in entries where FileNaming.parsePartFileName(entry) != nil {
            let full = (dir as NSString).appendingPathComponent(entry)
            if !owned.contains(full), (try? fm.removeItem(atPath: full)) != nil {
                deleted += 1
            }
        }
        if deleted > 0 {
            NSLog("QuickDown: 启动清理孤儿 .part 分片 \(deleted) 个（目录: %@）", dir)
        }
    }

    // MARK: - 持久化

    private func loadPersisted() {
        let stored = store.load()
        lock.lock()
        for rec in stored where boxes[rec.id] == nil {
            // 上次退出时正在下载的恢复为暂停
            var r = rec
            if r.status == .downloading || r.status == .connecting || r.status == .queued {
                r.status = .paused
            }
            boxes[r.id] = DownloadStateBox(r)
        }
        lock.unlock()
    }

    public func persist() {
        let recs = snapshot()
        store.save(recs)
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }
}
