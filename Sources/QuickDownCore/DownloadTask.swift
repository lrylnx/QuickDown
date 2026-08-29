import Foundation

// MARK: - 错误定义

public enum DownloadError: Error, LocalizedError {
    case invalidURL
    case unsupportedScheme
    case httpStatus(Int, String)
    case rangeNotSupported
    case segmentFailed
    case restartFromZero
    case fileSystem(String)
    case authRequired

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 URL"
        case .unsupportedScheme: return "不支持的协议（仅支持 http/https/file）"
        case .httpStatus(let code, let msg): return "HTTP \(code) \(msg)"
        case .rangeNotSupported: return "服务器不支持分段下载"
        case .segmentFailed: return "部分分段下载失败"
        case .restartFromZero: return "服务器忽略续传位置，重新开始"
        case .fileSystem(let msg): return "文件系统错误：\(msg)"
        case .authRequired: return "需要认证或访问被拒绝（401/403）"
        }
    }
}

// MARK: - 状态盒（线程安全的可变下载记录）

public final class DownloadStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _record: DownloadRecord

    public init(_ record: DownloadRecord) { _record = record }

    public var record: DownloadRecord {
        lock.lock(); defer { lock.unlock() }
        return _record
    }

    public func mutate(_ f: (inout DownloadRecord) -> Void) {
        lock.lock(); f(&_record); lock.unlock()
    }
}

// MARK: - 限速器（全局令牌窗口）

final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var windowStart = Date()
    private var windowBytes: Int64 = 0
    var limitBps: Int64

    init(limitBps: Int64) { self.limitBps = limitBps }

    func wait(for count: Int) {
        guard limitBps > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(windowStart) >= 1.0 {
            windowStart = now
            windowBytes = 0
        }
        windowBytes += Int64(count)
        guard windowBytes > limitBps else { return }
        let over = Double(windowBytes - limitBps)
        let sleep = over / Double(limitBps)
        windowStart = windowStart.addingTimeInterval(sleep)
        windowBytes = 0
        Thread.sleep(forTimeInterval: sleep)
    }
}

// MARK: - 探测结果

struct ProbeInfo {
    var totalSize: Int64
    var acceptsRanges: Bool
    var filename: String?
}

// MARK: - 单个下载任务

public final class DownloadTask: @unchecked Sendable {

    public enum Outcome {
        case completed(finalPath: String)
        case cancelled
        case failed(message: String)
    }

    /// 调试日志钩子
    public static var debugLog: ((String) -> Void)?

    public let box: DownloadStateBox
    public var onFinished: ((Outcome) -> Void)?

    private let settings: AppSettings
    private let limiter: RateLimiter
    private var session: URLSession
    private var probeSession: URLSession?
    private var segmentTasks: [Int: Task<Void, Error>] = [:]
    private let lock = NSLock()
    private var didRestartSingle = false
    private var pauseRequested = false

    init(box: DownloadStateBox, settings: AppSettings, limiter: RateLimiter) {
        self.box = box
        self.settings = settings
        self.limiter = limiter
        session = Self.makeSession(settings: settings)
    }

    static func sessionConfig(settings: AppSettings) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0
        config.httpMaximumConnectionsPerHost = 16
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxy = settings.proxyURL {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: proxy.host ?? "",
                kCFNetworkProxiesHTTPPort as String: proxy.port ?? 80,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host ?? "",
                kCFNetworkProxiesHTTPSPort as String: proxy.port ?? 80,
            ]
            if let u = settings.proxyUsername, let p = settings.proxyPassword {
                config.connectionProxyDictionary?[kCFProxyUsernameKey as String] = u
                config.connectionProxyDictionary?[kCFProxyPasswordKey as String] = p
            }
        }
        return config
    }

    private static func makeSession(settings: AppSettings) -> URLSession {
        URLSession(configuration: sessionConfig(settings: settings))
    }

    // MARK: - 对外操作

    public func start() async {
        box.mutate { $0.status = .connecting; $0.errorMessage = nil }
        // m3u8 流媒体 -> HLS 下载器（分片下载 + 合并为 MP4）
        if Self.isHLSURL(box.record.url) {
            let hls = HLSDownloadTask(box: box, settings: settings, limiter: limiter)
            hls.onFinished = onFinished
            await hls.start()
            return
        }
        Self.debugLog?("start: probing \(box.record.url)")
        do {
            let info = try await probe()
            Self.debugLog?("probe done: total=\(info.totalSize) ranges=\(info.acceptsRanges) name=\(info.filename ?? "-")")
            if pauseRequested { throw CancellationError() }
            box.mutate { rec in
                if rec.totalSize > 0 && info.totalSize > 0 && rec.totalSize != info.totalSize {
                    // 服务器文件大小变了 -> 全部重新下载
                    rec.segments = []
                    rec.downloadedSize = 0
                    self.resetPartFiles(directory: rec.directory, filename: rec.filename)
                }
                rec.totalSize = info.totalSize
                // 文件名：服务器 Content-Disposition 提供的名字优先于"通用名/无后缀名"
                if let name = info.filename, !name.isEmpty, Self.shouldPreferServerFilename(rec.filename) {
                    rec.filename = name
                    rec.finalPath = nil
                }
                if rec.finalPath == nil {
                    rec.finalPath = FileNaming.uniquePath(
                        directory: rec.resolvedSaveDirectory(settings: self.settings),
                        filename: rec.filename)
                }
            }
            try await run(info)

            let path = box.record.finalPath
            box.mutate { rec in
                rec.status = .completed
                rec.completedAt = Date()
                if rec.totalSize > 0 { rec.downloadedSize = rec.totalSize }
                rec.errorMessage = nil
            }
            if let path { onFinished?(.completed(finalPath: path)) }
            else { onFinished?(.failed(message: "未知错误")) }
        } catch is CancellationError {
            box.mutate { $0.status = .paused }
            onFinished?(.cancelled)
        } catch let e as DownloadError {
            if case .rangeNotSupported = e, !didRestartSingle {
                didRestartSingle = true
                restartAsSingle()
                return
            }
            finishFailed(e.localizedDescription)
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                box.mutate { $0.status = .paused }
                onFinished?(.cancelled)
            } else {
                finishFailed(error.localizedDescription)
            }
        }
    }

    private func finishFailed(_ message: String) {
        box.mutate { rec in
            rec.status = .error
            rec.errorMessage = message
        }
        onFinished?(.failed(message: message))
    }

    public func pause() {
        pauseRequested = true
        cancelSegmentTasks()
        box.mutate { $0.status = .paused }
    }

    public func cancel() {
        pauseRequested = true
        cancelSegmentTasks()
        resetPartFiles()
        box.mutate { $0.status = .cancelled }
    }

    // MARK: - 探测

    private func probe() async throws -> ProbeInfo {
        // 跟随 HTML 中转页（meta refresh）最多 3 次，直达真实文件地址
        var currentURL = box.record.url
        for _ in 0..<4 {
            let result = try await probeOnce(urlString: currentURL)
            if let refreshURL = result.htmlRefreshURL {
                currentURL = refreshURL
                box.mutate { $0.url = refreshURL }
                continue
            }
            return result.info
        }
        throw DownloadError.fileSystem("网页跳转次数过多，请尝试在浏览器中点击下载链接")
    }

    private func probeOnce(urlString: String) async throws -> (info: ProbeInfo, htmlRefreshURL: String?) {
        // 探测使用独立的一次性会话，避免取消请求后污染主下载会话的连接
        let probeSession = URLSession(configuration: .ephemeral)
        self.probeSession = probeSession
        defer {
            probeSession.invalidateAndCancel()
            self.probeSession = nil
        }

        guard let url = URL(string: urlString) else { throw DownloadError.invalidURL }
        if url.isFileURL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return (ProbeInfo(totalSize: Int64(size ?? 0), acceptsRanges: false,
                              filename: FileNaming.filename(fromURL: url) ?? url.lastPathComponent), nil)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw DownloadError.unsupportedScheme
        }

        var request = baseRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let (bytes, response) = try await probeSession.bytes(for: request)
        bytes.task.cancel() // 只取响应头

        guard let http = response as? HTTPURLResponse else { throw DownloadError.invalidURL }

        // HTTP 头大小写不敏感（部分服务器返回小写头，如 content-range）
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let s = v as? String {
                headers[(k as? String ?? "").lowercased()] = s
            }
        }

        let contentType = headers["content-type"] ?? ""
        // 内容为 HTML 时读取页面头部，尝试识别 meta refresh 跳转
        var htmlRefresh: String?
        if contentType.lowercased().contains("text/html") {
            if let refresh = try? await Self.fetchMetaRefresh(from: urlString, session: probeSession) {
                htmlRefresh = refresh
            }
        }

        var total: Int64 = -1
        var acceptsRanges = false
        if http.statusCode == 206 {
            acceptsRanges = true
            if let cr = headers["content-range"], let slash = cr.lastIndex(of: "/") {
                let after = cr[cr.index(after: slash)...]
                total = Int64(after) ?? -1
            }
        } else if http.statusCode == 200 {
            if let cl = headers["content-length"], let v = Int64(cl) {
                total = v
            }
            // 服务器返回 200 但声明支持 Range（部分 CDN 对 bytes=0-0 直接回 200）
            if headers["accept-ranges"]?.lowercased() == "bytes" {
                acceptsRanges = true
            }
        } else if http.statusCode == 401 || http.statusCode == 403 {
            throw DownloadError.authRequired
        } else if http.statusCode >= 400 {
            throw DownloadError.httpStatus(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        let filename = FileNaming.filename(fromContentDisposition: headers["content-disposition"])
        return (ProbeInfo(totalSize: total, acceptsRanges: acceptsRanges, filename: filename), htmlRefresh)
    }

    /// 读取 HTML 页面并解析 meta refresh 跳转地址
    private static func fetchMetaRefresh(from urlString: String, session: URLSession) async throws -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("QuickDown/1.0", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 128 * 1024 { break }
        }
        return metaRefreshURL(from: data, base: http.url ?? url)
    }

    /// 解析 <meta http-equiv="refresh" content="0;url=...">（大小写不敏感，支持相对地址）
    static func metaRefreshURL(from data: Data, base: URL) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let pattern = #"<meta[^>]+http-equiv\s*=\s*["']refresh["'][^>]+content\s*=\s*["']\s*\d+(?:\.\d+)?\s*;\s*url\s*=\s*([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let urlString = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return nil }
        if let absolute = URL(string: urlString), absolute.scheme != nil {
            return absolute.absoluteString
        }
        return URL(string: urlString, relativeTo: base)?.absoluteString
    }

    // MARK: - 运行

    private func run(_ info: ProbeInfo) async throws {
        let rec = box.record
        guard let url = URL(string: rec.url) else { throw DownloadError.invalidURL }

        if url.isFileURL {
            box.mutate { $0.status = .downloading }
            try copyLocalFile(from: url, to: rec.finalPath ?? "")
            box.mutate { $0.downloadedSize = info.totalSize }
            return
        }

        let canSegment = info.acceptsRanges && info.totalSize > 0 && info.totalSize >= settings.minSegmentSize
        if canSegment {
            try await runSegmented(info)
        } else {
            try await runSingle(info)
        }
    }

    // MARK: 分段模式

    private func runSegmented(_ info: ProbeInfo) async throws {
        Self.debugLog?("runSegmented: total=\(info.totalSize) segs=\(settings.maxSegments)")
        box.mutate { rec in
            rec.isSingle = false
            rec.status = .downloading
            if rec.segments.isEmpty || rec.segments.count != settings.maxSegments {
                rec.segments = Self.split(totalSize: info.totalSize, count: settings.maxSegments)
            }
            // 一致性：段文件大小与记录不符则重置该段
            for i in rec.segments.indices {
                let seg = rec.segments[i]
                let size = partFileSize(directory: rec.directory, filename: rec.filename, index: seg.index)
                if size != seg.downloaded {
                    rec.segments[i].downloaded = 0
                    try? FileManager.default.removeItem(
                        at: partFileURL(directory: rec.directory, filename: rec.filename, index: seg.index))
                }
            }
            rec.downloadedSize = rec.segments.reduce(0) { $0 + $1.downloaded }
        }

        let segs = box.record.segments
        let pending = segs.filter { $0.end < 0 || $0.downloaded < ($0.end - $0.start + 1) }
        Self.debugLog?("runSegmented: segments=\(segs.map { "\($0.start)-\($0.end)/\($0.downloaded)" }) pending=\(pending.count)")
        if pending.isEmpty {
            try merge()
            return
        }

        for seg in segs where seg.end < 0 || seg.downloaded < (seg.end - seg.start + 1) {
            let task = Task<Void, Error> { [weak self] in
                Self.debugLog?("segment \(seg.index): task body entered")
                guard let self else { return }
                try await self.downloadSegment(seg)
            }
            segmentTasks[seg.index] = task
        }
        Self.debugLog?("tasks created: \(segmentTasks.count), awaiting...")
        var failed = false
        for (_, t) in segmentTasks {
            do { _ = try await t.value }
            catch is CancellationError { throw CancellationError() }
            catch { failed = true }
        }
        segmentTasks.removeAll()

        guard !pauseRequested else { throw CancellationError() }
        if failed { throw DownloadError.segmentFailed }
        try merge()
    }

    // MARK: 单连接模式

    private func runSingle(_ info: ProbeInfo) async throws {
        box.mutate { rec in
            rec.isSingle = true
            rec.status = .downloading
            if rec.downloadedSize > 0 && !info.acceptsRanges {
                // 服务器不支持续传，从零开始
                rec.downloadedSize = 0
                rec.segments = []
                try? FileManager.default.removeItem(
                    at: partFileURL(directory: rec.directory, filename: rec.filename, index: 0))
            }
            if rec.segments.isEmpty {
                // 单连接：end 用 totalSize-1（含端点），未知大小时为 -1（流式）
                rec.segments = [SegmentState(index: 0, start: 0, end: info.totalSize > 0 ? info.totalSize - 1 : -1, downloaded: 0)]
            } else if rec.segments.count == 1, info.totalSize > 0 {
                // 归一化旧记录的端点（防止历史 off-by-one）
                rec.segments[0].end = info.totalSize - 1
            }
            rec.downloadedSize = rec.segments.first?.downloaded ?? 0
        }

        let seg = box.record.segments.first ?? SegmentState(index: 0, start: 0, end: info.totalSize, downloaded: 0)
        if seg.end >= 0 && seg.downloaded >= (seg.end - seg.start + 1) {
            try merge()
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.downloadSegment(seg)
        }
        segmentTasks[0] = task
        do {
            _ = try await task.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DownloadError.segmentFailed
        }
        segmentTasks.removeAll()

        guard !pauseRequested else { throw CancellationError() }
        try merge()
    }

    // MARK: - 分段下载（数据块回调模式，避免逐字节读取的性能开销）

    private func downloadSegment(_ seg: SegmentState) async throws {
        let rec = box.record
        guard let url = URL(string: rec.url) else { throw DownloadError.invalidURL }
        let single = box.record.isSingle
        let partURL = partFileURL(directory: rec.directory, filename: rec.filename, index: seg.index)

        // 当前起点（可能因续传重置而更新）
        var start = seg.nextStart
        let end = seg.end

        var lastError: Error?

        for attempt in 0..<4 {
            if Task.isCancelled || pauseRequested { throw CancellationError() }
            Self.debugLog?("segment \(seg.index): attempt \(attempt) requesting \(rangeHeader(start: start, end: end, single: single))")

            ensurePartFile(partURL, expectedSize: start - seg.start)

            var request = baseRequest(url: url)
            request.setValue(rangeHeader(start: start, end: end, single: single), forHTTPHeaderField: "Range")

            let delegate = SegmentDownloadDelegate(
                partURL: partURL,
                index: seg.index,
                isSingle: single,
                startAt: start,
                limiter: limiter,
                onBytes: { [weak self] count in
                    self?.box.mutate { rec in
                        if rec.segments.indices.contains(seg.index) {
                            rec.segments[seg.index].downloaded += Int64(count)
                        }
                        rec.downloadedSize = rec.segments.reduce(0) { $0 + $1.downloaded }
                    }
                }
            )
            let session = URLSession(
                configuration: Self.sessionConfig(settings: settings),
                delegate: delegate,
                delegateQueue: nil
            )
            let task = session.dataTask(with: request)
            task.resume()

            let result = await withTaskCancellationHandler {
                await delegate.awaitResult()
            } onCancel: {
                task.cancel()
            }
            session.invalidateAndCancel()

            switch result {
            case .success:
                Self.debugLog?("segment \(seg.index): done")
                // 段完成：校正为精确值
                if end >= 0 {
                    box.mutate { rec in
                        if rec.segments.indices.contains(seg.index) {
                            rec.segments[seg.index].downloaded = end - rec.segments[seg.index].start + 1
                        }
                        rec.downloadedSize = rec.segments.reduce(0) { $0 + $1.downloaded }
                    }
                }
                return
            case .failure(let e):
                if e is CancellationError { throw CancellationError() }
                if let de = e as? DownloadError, case .restartFromZero = de {
                    // 服务器忽略续传位置：整段从头下载
                    start = 0
                    box.mutate { rec in
                        if rec.segments.indices.contains(seg.index) { rec.segments[seg.index].downloaded = 0 }
                        rec.downloadedSize = rec.segments.reduce(0) { $0 + $1.downloaded }
                    }
                    try? FileManager.default.removeItem(at: partURL)
                    ensurePartFile(partURL, expectedSize: 0)
                    continue
                }
                if let de = e as? DownloadError, case .rangeNotSupported = de {
                    throw de
                }
                lastError = e
            }
            try? await Task.sleep(nanoseconds: UInt64(1 + attempt) * 1_000_000_000)
        }
        throw lastError ?? DownloadError.segmentFailed
    }

    private func restartAsSingle() {
        cancelSegmentTasks()
        resetPartFiles()
        // 换一个全新会话，避免复用被取消请求污染过的连接
        session.invalidateAndCancel()
        session = Self.makeSession(settings: settings)
        box.mutate { rec in
            rec.isSingle = true
            rec.segments = []
            rec.downloadedSize = 0
            rec.status = .connecting
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await self.probe()
                try await self.runSingle(info)
                let path = self.box.record.finalPath
                self.box.mutate { rec in
                    rec.status = .completed
                    rec.completedAt = Date()
                    if rec.totalSize > 0 { rec.downloadedSize = rec.totalSize }
                }
                if let path { self.onFinished?(.completed(finalPath: path)) }
            } catch is CancellationError {
                self.box.mutate { $0.status = .paused }
                self.onFinished?(.cancelled)
            } catch {
                self.finishFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - 合并

    private func merge() throws {
        let rec = box.record
        guard let finalPath = rec.finalPath, !finalPath.isEmpty else {
            throw DownloadError.fileSystem("未设置保存路径")
        }
        let dir = (finalPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fm = FileManager.default
        if fm.fileExists(atPath: finalPath) {
            try? fm.removeItem(atPath: finalPath)
        }
        fm.createFile(atPath: finalPath, contents: nil)
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: finalPath))
        defer { try? out.close() }
        let count = max(box.record.segments.count, 1)
        for i in 0..<count {
            let part = partFileURL(directory: rec.directory, filename: rec.filename, index: i)
            guard let handle = try? FileHandle(forReadingFrom: part) else { continue }
            defer { try? handle.close() }
            while true {
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
                try out.write(contentsOf: data)
            }
            try? fm.removeItem(at: part)
        }
        box.mutate { $0.finalPath = finalPath }
    }

    // MARK: - 工具

    /// 是否应优先采用服务器 Content-Disposition 提供的文件名
    /// （当前名字为空、无扩展名、通用占位名、或是 32/40 位十六进制哈希名时）
    static func shouldPreferServerFilename(_ current: String) -> Bool {
        if current.isEmpty { return true }
        let ext = (current as NSString).pathExtension
        if ext.isEmpty { return true }
        let lower = current.lowercased()
        let generic = ["file", "download", "index", "default", "downloadfile", "unnamed", "未命名"]
        if generic.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) { return true }
        // 哈希文件名（MD5 32 位 / SHA1 40 位十六进制）
        let base = (current as NSString).deletingPathExtension
        if base.count == 32 || base.count == 40 {
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            if base.unicodeScalars.allSatisfy({ hex.contains($0) }) { return true }
        }
        return false
    }

    static func isHLSURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasSuffix(".m3u8") || lower.contains(".m3u8?")
    }

    private func baseRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let rec = box.record
        if let ua = rec.userAgent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        } else {
            request.setValue("QuickDown/1.0", forHTTPHeaderField: "User-Agent")
        }
        if let ref = rec.referer, !ref.isEmpty {
            request.setValue(ref, forHTTPHeaderField: "Referer")
        }
        if let cookie = rec.cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func rangeHeader(start: Int64, end: Int64, single: Bool) -> String {
        if end >= 0 { return "bytes=\(start)-\(end)" }
        if single && start > 0 { return "bytes=\(start)-" }
        return "bytes=0-"
    }

    static func split(totalSize: Int64, count: Int) -> [SegmentState] {
        guard totalSize > 0 else { return [SegmentState(index: 0, start: 0, end: -1, downloaded: 0)] }
        let n = min(max(count, 1), 64, Int(totalSize))
        let base = totalSize / Int64(n)
        var segs: [SegmentState] = []
        for i in 0..<n {
            let start = Int64(i) * base
            let end = (i == n - 1) ? totalSize - 1 : start + base - 1
            segs.append(SegmentState(index: i, start: start, end: end, downloaded: 0))
        }
        return segs
    }

    private func partFileURL(directory: String, filename: String, index: Int) -> URL {
        let name = FileNaming.partFileName(for: filename, index: index)
        return URL(fileURLWithPath: directory).appendingPathComponent(name)
    }

    private func partFileSize(directory: String, filename: String, index: Int) -> Int64 {
        let url = partFileURL(directory: directory, filename: filename, index: index)
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func ensurePartFile(_ url: URL, expectedSize: Int64) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().path
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size != expectedSize {
            if let handle = try? FileHandle(forUpdating: url) {
                try? handle.truncate(atOffset: UInt64(expectedSize))
                try? handle.close()
            }
        }
    }

    private func resetPartFiles(directory: String? = nil, filename: String? = nil) {
        let rec = box.record
        let dir = directory ?? rec.directory
        let name = filename ?? rec.filename
        let fm = FileManager.default
        for i in 0..<max(rec.segments.count, 8) {
            let part = FileNaming.partFileName(for: name, index: i)
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(part))
        }
    }

    private func cancelSegmentTasks() {
        lock.lock()
        let tasks = segmentTasks.values
        lock.unlock()
        for t in tasks { t.cancel() }
    }

    private func copyLocalFile(from src: URL, to dest: String) throws {
        let fm = FileManager.default
        let dir = (dest as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: dest)
        try fm.copyItem(at: src, to: URL(fileURLWithPath: dest))
    }
}

// MARK: - 分段下载委托（数据块级写入，性能远优于逐字节迭代）

private final class SegmentDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partURL: URL
    private let index: Int
    private let isSingle: Bool
    private let startAt: Int64
    private let limiter: RateLimiter
    private let onBytes: (Int) -> Void

    private var handle: FileHandle?
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?
    private let lock = NSLock()

    init(partURL: URL, index: Int, isSingle: Bool, startAt: Int64,
         limiter: RateLimiter, onBytes: @escaping (Int) -> Void) {
        self.partURL = partURL
        self.index = index
        self.isSingle = isSingle
        self.startAt = startAt
        self.limiter = limiter
        self.onBytes = onBytes
    }

    func awaitResult() async -> Result<Void, Error> {
        await withCheckedContinuation { cont in
            lock.lock()
            if let r = result {
                lock.unlock()
                cont.resume(returning: r)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    private func finish(_ r: Result<Void, Error>) {
        lock.lock()
        if result == nil { result = r }
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: r)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(DownloadError.invalidURL))
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode

        if status == 416 {
            finish(.failure(DownloadError.httpStatus(416, "Range 越界")))
            completionHandler(.cancel)
            return
        }
        if status >= 400 {
            finish(.failure(DownloadError.httpStatus(status, HTTPURLResponse.localizedString(forStatusCode: status))))
            completionHandler(.cancel)
            return
        }
        // 分段模式下服务器忽略 Range（返回整个文件）
        if status == 200 && !isSingle {
            finish(.failure(DownloadError.rangeNotSupported))
            completionHandler(.cancel)
            return
        }
        // 单连接续传但服务器忽略 Range：从头开始
        if status == 200 && isSingle && startAt > 0 {
            finish(.failure(DownloadError.restartFromZero))
            completionHandler(.cancel)
            return
        }
        // 206 时校验 Content-Range 起始位置（头大小写不敏感）
        if status == 206 && startAt > 0 {
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let s = v as? String {
                    headers[(k as? String ?? "").lowercased()] = s
                }
            }
            if let cr = headers["content-range"] {
                let expected = "bytes \(startAt)-"
                if !cr.hasPrefix(expected) {
                    finish(.failure(DownloadError.restartFromZero))
                    completionHandler(.cancel)
                    return
                }
            }
        }

        do {
            let h = try FileHandle(forWritingTo: partURL)
            try h.seekToEnd()
            handle = h
        } catch {
            finish(.failure(DownloadError.fileSystem(error.localizedDescription)))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        limiter.wait(for: data.count)
        do {
            try handle?.write(contentsOf: data)
            onBytes(data.count)
        } catch {
            finish(.failure(DownloadError.fileSystem(error.localizedDescription)))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
        } else {
            finish(.success(()))
        }
    }
}
