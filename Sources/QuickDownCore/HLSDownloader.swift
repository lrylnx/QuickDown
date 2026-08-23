import Foundation
import AVFoundation
import CommonCrypto

// MARK: - HLS 播放列表模型

public struct HLSSegment: Sendable {
    public var index: Int
    public var uri: String            // 已解析的绝对地址
    public var duration: Double
    public var keyURI: String?        // AES-128 密钥地址
    public var keyIVHex: String?      // IV（十六进制），nil 则用媒体序号
    public var byteRangeStart: Int64? // EXT-X-BYTERANGE
    public var byteRangeLength: Int64?
}

public struct HLSPlaylist: Sendable {
    public var segments: [HLSSegment] = []
    public var isMaster: Bool = false
    public var variants: [(uri: String, bandwidth: Int64)] = []
    public var isFragmentedMP4: Bool = false
    public var initURI: String?       // EXT-X-MAP 初始化段
    public var initByteRange: (start: Int64, length: Int64)?
    public var mediaSequence: Int = 0
}

// MARK: - 播放列表解析

public enum HLSParser {

    public static func parse(_ text: String, baseURL: URL) -> HLSPlaylist {
        var playlist = HLSPlaylist()
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        playlist.isMaster = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") }

        if playlist.isMaster {
            var i = 0
            var lastBandwidth: Int64 = 0
            while i < lines.count {
                let line = lines[i]
                if line.hasPrefix("#EXT-X-STREAM-INF") {
                    let attrs = parseAttributes(line)
                    lastBandwidth = Int64(attrs["BANDWIDTH"] ?? "") ?? 0
                } else if !line.isEmpty && !line.hasPrefix("#") {
                    if let url = URL(string: line, relativeTo: baseURL) {
                        playlist.variants.append((url.absoluteString, lastBandwidth))
                    }
                }
                i += 1
            }
            return playlist
        }

        // 媒体播放列表
        var lastDuration: Double = 0
        var currentKeyURI: String?
        var currentKeyIV: String?
        var currentByteRange: (Int64, Int64)?
        var pendingMapInit: String?
        var pendingMapRange: (Int64, Int64)?

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                let parts = line.split(separator: ":")
                playlist.mediaSequence = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            } else if line.hasPrefix("#EXT-X-KEY") {
                let attrs = parseAttributes(line)
                let method = attrs["METHOD"] ?? "NONE"
                if method == "AES-128", let uri = attrs["URI"] {
                    if let u = URL(string: uri, relativeTo: baseURL) {
                        currentKeyURI = u.absoluteString
                    }
                    currentKeyIV = attrs["IV"]
                } else {
                    currentKeyURI = nil
                    currentKeyIV = nil
                }
            } else if line.hasPrefix("#EXT-X-MAP") {
                let attrs = parseAttributes(line)
                if let uri = attrs["URI"], let u = URL(string: uri, relativeTo: baseURL) {
                    pendingMapInit = u.absoluteString
                }
                if let r = attrs["BYTERANGE"] {
                    pendingMapRange = parseByteRange(r)
                }
                playlist.isFragmentedMP4 = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                let r = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                currentByteRange = parseByteRange(r)
            } else if line.hasPrefix("#EXTINF") {
                let d = String(line.dropFirst("#EXTINF:".count)).split(separator: ",").first.map(String.init) ?? "0"
                lastDuration = Double(d) ?? 0
            } else if !line.isEmpty && !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL) {
                    let seg = HLSSegment(
                        index: playlist.segments.count,
                        uri: url.absoluteString,
                        duration: lastDuration,
                        keyURI: currentKeyURI,
                        keyIVHex: currentKeyIV,
                        byteRangeStart: currentByteRange?.0,
                        byteRangeLength: currentByteRange?.1
                    )
                    playlist.segments.append(seg)
                    currentByteRange = nil
                }
            }
        }
        if let initURI = pendingMapInit {
            playlist.initURI = initURI
            playlist.initByteRange = pendingMapRange
        }
        return playlist
    }

    /// 解析 EXT-X-KEY / EXT-X-STREAM-INF 属性（支持带引号的值）
    static func parseAttributes(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let colon = line.firstIndex(of: ":") else { return result }
        let rest = line[line.index(after: colon)...]
        var key = ""
        var value = ""
        var inQuotes = false
        var currentKey: String?
        var current: [Character] = []
        for ch in rest {
            if ch == "\"" {
                inQuotes.toggle()
                if !inQuotes {
                    result[currentKey ?? ""] = String(current)
                    currentKey = nil
                    current = []
                }
            } else if ch == "," && !inQuotes {
                if let k = currentKey {
                    result[k] = String(current).trimmingCharacters(in: .whitespaces)
                } else if !current.isEmpty {
                    let s = String(current)
                    if let eq = s.firstIndex(of: "=") {
                        result[String(s[..<eq])] = String(s[s.index(after: eq)...])
                    }
                }
                currentKey = nil
                current = []
            } else if ch == "=" && !inQuotes && currentKey == nil {
                currentKey = String(current).trimmingCharacters(in: .whitespaces)
                current = []
            } else {
                current.append(ch)
            }
        }
        if let k = currentKey {
            result[k] = String(current).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func parseByteRange(_ s: String) -> (Int64, Int64)? {
        // "length@start" 或 "length"
        let parts = s.split(separator: "@")
        guard let len = Int64(parts[0]) else { return nil }
        if parts.count > 1, let start = Int64(parts[1]) {
            return (start, len)
        }
        return (0, len)
    }
}

// MARK: - AES-128-CBC 解密（CommonCrypto）

enum HLSCrypto {
    static func aesCBCDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == 16, iv.count == 16 else { return nil }
        let outLen = data.count + kCCBlockSizeAES128
        var out = Data(count: outLen)
        var numBytes: Int = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, outLen, &numBytes)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(numBytes)
    }

    /// 默认 IV：媒体序号的大端 16 字节
    static func defaultIV(sequence: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        var seq = UInt64(sequence)
        for i in (0..<8).reversed() {
            bytes[8 + i] = UInt8(seq & 0xFF)
            seq >>= 8
        }
        return Data(bytes)
    }

    /// 解析 "0x..." 十六进制 IV
    static func iv(fromHex hex: String) -> Data? {
        var h = hex
        if h.lowercased().hasPrefix("0x") { h.removeFirst(2) }
        guard h.count % 2 == 0 else { return nil }
        var data = Data()
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let byte = UInt8(h[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data
    }
}

// MARK: - HLS 下载任务

public final class HLSDownloadTask: @unchecked Sendable {

    public let box: DownloadStateBox
    public var onFinished: ((DownloadTask.Outcome) -> Void)?

    private let settings: AppSettings
    private let limiter: RateLimiter
    private var pauseRequested = false
    private var tempDir: URL?
    private var keyCache: [String: Data] = [:]
    private let keyLock = NSLock()
    private var estimatedTotal: Int64 = 0
    private var downloadedBytes: Int64 = 0

    init(box: DownloadStateBox, settings: AppSettings, limiter: RateLimiter) {
        self.box = box
        self.settings = settings
        self.limiter = limiter
    }

    public func pause() {
        pauseRequested = true
    }

    // MARK: - 主流程

    private func isStopped() -> Bool {
        if pauseRequested { return true }
        let status = box.record.status
        return status == .paused || status == .cancelled || Task.isCancelled
    }

    public func start() async {
        box.mutate { rec in
            rec.status = .connecting
            rec.errorMessage = nil
            rec.hlsInfo = nil
            // 修正文件名：输出为 .mp4
            if rec.filename.lowercased().hasSuffix(".m3u8") {
                rec.filename = String(rec.filename.dropLast(5)) + ".mp4"
            }
            if rec.filename.isEmpty || !rec.filename.lowercased().hasSuffix(".mp4") {
                rec.filename = "video-\(Int(Date().timeIntervalSince1970)).mp4"
            }
            rec.finalPath = nil
        }
        do {
            let playlistURL = try await resolvePlaylistURL()
            let playlist = try await fetchMediaPlaylist(from: playlistURL)
            try await download(playlist: playlist, playlistURL: playlistURL)
        } catch is CancellationError {
            cleanupTemp()
            box.mutate { $0.status = .paused }
            onFinished?(.cancelled)
            return
        } catch {
            cleanupTemp()
            box.mutate { rec in
                rec.status = .error
                rec.errorMessage = error.localizedDescription
            }
            onFinished?(.failed(message: error.localizedDescription))
            return
        }
        cleanupTemp()
        let path = box.record.finalPath
        box.mutate { rec in
            rec.status = .completed
            rec.completedAt = Date()
            rec.hlsInfo = nil
            if rec.totalSize > 0 { rec.downloadedSize = rec.totalSize }
        }
        if let path {
            onFinished?(.completed(finalPath: path))
        } else {
            onFinished?(.failed(message: "未知错误"))
        }
    }

    // MARK: - 播放列表获取

    private func resolvePlaylistURL() async throws -> URL {
        let text = try await fetchText(box.record.url)
        guard let base = URL(string: box.record.url) else { throw DownloadError.invalidURL }
        let parsed = HLSParser.parse(text, baseURL: base)
        guard parsed.isMaster else {
            // 本身就是媒体播放列表
            let tmp = tempPlaylistPath()
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            return URL(string: box.record.url)!
        }
        // 选最高码率变体
        guard let best = parsed.variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
            throw DownloadError.fileSystem("主播放列表没有可用的码率变体")
        }
        return URL(string: best.uri)!
    }

    private func fetchMediaPlaylist(from url: URL) async throws -> HLSPlaylist {
        let text = try await fetchText(url.absoluteString)
        let parsed = HLSParser.parse(text, baseURL: url)
        guard !parsed.segments.isEmpty else {
            throw DownloadError.fileSystem("播放列表中没有找到视频分片")
        }
        box.mutate { rec in
            rec.hlsInfo = HLSProgressInfo(total: parsed.segments.count, done: 0)
        }
        return parsed
    }

    private func fetchText(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw DownloadError.invalidURL }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = baseRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw DownloadError.httpStatus(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DownloadError.fileSystem("无法解析播放列表（编码不是 UTF-8）")
        }
        return text
    }

    // MARK: - 分片下载

    private func download(playlist: HLSPlaylist, playlistURL: URL) async throws {
        let segments = playlist.segments
        box.mutate { $0.status = .downloading }

        // 创建临时目录
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickDown-HLS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempDir = tmp

        // 下载 init 段（fMP4）
        var initData: Data?
        if let initURI = playlist.initURI {
            initData = try await fetchSegmentData(urlString: initURI,
                                                  rangeStart: playlist.initByteRange?.0,
                                                  rangeLength: playlist.initByteRange?.1)
        }

        // 并发下载分片（批次）
        let batchSize = min(max(settings.maxSegments, 1), 12)
        var finished = 0
        var downloadedBytesTotal: Int64 = 0
        var segmentSizes: [Int64] = Array(repeating: 0, count: segments.count)

        for batchStart in stride(from: 0, to: segments.count, by: batchSize) {
            if isStopped() { throw CancellationError() }
            let end = min(batchStart + batchSize, segments.count)
            let batch = Array(segments[batchStart..<end])

            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for seg in batch {
                    group.addTask {
                        let data = try await self.fetchSegmentData(urlString: seg.uri,
                                                                   rangeStart: seg.byteRangeStart,
                                                                   rangeLength: seg.byteRangeLength)
                        // 解密
                        var out = data
                        if let keyURI = seg.keyURI {
                            let key = try await self.fetchKey(keyURI)
                            let iv: Data
                            if let ivHex = seg.keyIVHex, let parsed = HLSCrypto.iv(fromHex: ivHex) {
                                iv = parsed
                            } else {
                                iv = HLSCrypto.defaultIV(sequence: playlist.mediaSequence + seg.index)
                            }
                            guard let decrypted = HLSCrypto.aesCBCDecrypt(data: data, key: key, iv: iv) else {
                                throw DownloadError.fileSystem("AES-128 解密失败（分片 \(seg.index)）")
                            }
                            out = decrypted
                        }
                        return (seg.index, out)
                    }
                }
                for try await (idx, data) in group {
                    let segURL = tmp.appendingPathComponent("seg-\(idx)")
                    try data.write(to: segURL)
                    segmentSizes[idx] = Int64(data.count)
                    finished += 1
                    downloadedBytesTotal += Int64(data.count)
                    // 估计总大小：用已完成分片的平均大小
                    let avg = Double(downloadedBytesTotal) / Double(finished)
                    estimatedTotal = Int64(avg * Double(segments.count))
                    box.mutate { rec in
                        rec.downloadedSize = downloadedBytesTotal
                        rec.totalSize = estimatedTotal
                        if var h = rec.hlsInfo { h.done = finished; rec.hlsInfo = h }
                    }
                }
            }
        }

        if isStopped() { throw CancellationError() }

        // 合并
        let finalName = box.record.filename
        let saveDir = box.record.resolvedSaveDirectory(settings: settings)
        let finalURL = URL(fileURLWithPath: FileNaming.uniquePath(directory: saveDir, filename: finalName))
        try FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)

        if playlist.isFragmentedMP4 {
            // fMP4：init 段 + 分片直接拼接
            FileManager.default.createFile(atPath: finalURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: finalURL)
            defer { try? out.close() }
            if let initData {
                try out.write(contentsOf: initData)
            }
            for i in 0..<segments.count {
                let segURL = tmp.appendingPathComponent("seg-\(i)")
                if let h = try? FileHandle(forReadingFrom: segURL) {
                    while let d = try? h.read(upToCount: 1024 * 1024), !d.isEmpty {
                        try out.write(contentsOf: d)
                    }
                }
            }
        } else {
            // TS：拼接后转封装为 MP4
            let tsURL = tmp.appendingPathComponent("combined.ts")
            FileManager.default.createFile(atPath: tsURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: tsURL)
            defer { try? out.close() }
            for i in 0..<segments.count {
                let segURL = tmp.appendingPathComponent("seg-\(i)")
                if let h = try? FileHandle(forReadingFrom: segURL) {
                    while let d = try? h.read(upToCount: 1024 * 1024), !d.isEmpty {
                        try out.write(contentsOf: d)
                    }
                }
            }
            let ok = await HLSDownloadTask.remuxTS(tsURL, to: finalURL)
            if !ok {
                // 转封装失败：直接保留 TS 文件
                try FileManager.default.moveItem(at: tsURL, to: finalURL)
                box.mutate { $0.errorMessage = "转封装 MP4 失败，已保留 TS 格式（可用 VLC 播放）" }
            }
        }

        // 最终字节数
        let finalSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? downloadedBytesTotal
        box.mutate { rec in
            rec.finalPath = finalURL.path
            rec.downloadedSize = finalSize
            rec.totalSize = finalSize
        }
    }

    // MARK: - 转封装

    static func remuxTS(_ tsURL: URL, to mp4URL: URL) async -> Bool {
        try? FileManager.default.removeItem(at: mp4URL)
        let asset = AVURLAsset(url: tsURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        session.outputURL = mp4URL
        session.outputFileType = .mp4
        return await withCheckedContinuation { cont in
            session.exportAsynchronously {
                cont.resume(returning: session.status == .completed)
            }
        }
    }

    // MARK: - 分片/密钥获取（带重试）

    private func fetchSegmentData(urlString: String, rangeStart: Int64?, rangeLength: Int64?) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            if isStopped() { throw CancellationError() }
            do {
                return try await fetchSegmentDataOnce(urlString: urlString, rangeStart: rangeStart, rangeLength: rangeLength)
            } catch let e as CancellationError {
                throw e
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(500 + attempt * 1000) * 1_000_000)
            }
        }
        throw lastError ?? DownloadError.segmentFailed
    }

    private func fetchSegmentDataOnce(urlString: String, rangeStart: Int64?, rangeLength: Int64?) async throws -> Data {
        guard let url = URL(string: urlString) else { throw DownloadError.invalidURL }
        let fetcher = HLSChunkFetcher(limiter: limiter)
        let session = URLSession(configuration: DownloadTask.sessionConfig(settings: settings),
                                 delegate: fetcher, delegateQueue: nil)
        var request = baseRequest(url: url)
        if let start = rangeStart, let len = rangeLength {
            request.setValue("bytes=\(start)-\(start + len - 1)", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        task.resume()
        let result = await withTaskCancellationHandler {
            await fetcher.awaitResult()
        } onCancel: {
            task.cancel()
        }
        session.invalidateAndCancel()
        switch result {
        case .success(let data):
            return data
        case .failure(let e):
            if e is CancellationError { throw CancellationError() }
            throw e
        }
    }

    private func fetchKey(_ keyURI: String) async throws -> Data {
        keyLock.lock()
        if let cached = keyCache[keyURI] {
            keyLock.unlock()
            return cached
        }
        keyLock.unlock()
        let data = try await fetchSegmentData(urlString: keyURI, rangeStart: nil, rangeLength: nil)
        keyLock.lock()
        keyCache[keyURI] = data
        keyLock.unlock()
        return data
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

    private func tempPlaylistPath() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qd-\(UUID().uuidString).m3u8")
    }

    private func cleanupTemp() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: - 分片数据块获取（数据块级回调）

private final class HLSChunkFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limiter: RateLimiter
    private var data = Data()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Result<Data, Error>, Never>?
    private let lock = NSLock()

    init(limiter: RateLimiter) {
        self.limiter = limiter
    }

    func awaitResult() async -> Result<Data, Error> {
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

    private func finish(_ r: Result<Data, Error>) {
        lock.lock()
        if result == nil { result = r }
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            finish(.failure(DownloadError.httpStatus(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        limiter.wait(for: chunk.count)
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
        } else {
            finish(.success(data))
        }
    }
}
