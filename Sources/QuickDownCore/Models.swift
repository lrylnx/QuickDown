import Foundation

// MARK: - 文件分类

public enum DownloadCategory: String, Codable, CaseIterable, Sendable {
    case video = "视频"
    case music = "音乐"
    case archive = "压缩包"
    case image = "图片"
    case application = "应用程序"
    case document = "文档"
    case code = "代码"
    case other = "其他"

    public static func from(extension ext: String) -> DownloadCategory {
        switch ext.lowercased() {
        case "mp4", "mkv", "mov", "avi", "flv", "wmv", "webm", "ts": return .video
        case "mp3", "flac", "wav", "aac", "ogg", "m4a", "wma": return .music
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso": return .archive
        case "jpg", "jpeg", "png", "gif", "bmp", "webp", "heic": return .image
        case "exe", "dmg", "pkg", "app", "msi", "apk": return .application
        case "txt", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv",
             "md", "rtf", "odt", "ods", "odp", "pages", "numbers", "key",
             "epub", "srt", "vtt", "log": return .document
        case "js", "py", "html", "css", "json", "xml", "swift", "java",
             "c", "cpp", "h", "go", "rs", "sh", "sql", "yml", "yaml", "toml",
             "ipynb": return .code
        default: return .other
        }
    }
}

// MARK: - 下载状态

public enum DownloadStatus: String, Codable, Sendable {
    case queued       // 排队等待
    case connecting   // 连接中/探测中
    case downloading  // 下载中
    case paused       // 已暂停
    case completed    // 已完成
    case error        // 出错
    case cancelled    // 已取消
}

// MARK: - 分段状态

public struct SegmentState: Codable, Sendable, Equatable {
    public var index: Int
    public var start: Int64       // 该段起始字节（含）
    public var end: Int64         // 该段结束字节（含），-1 表示未知（流式）
    public var downloaded: Int64  // 该段已下载字节数

    public init(index: Int, start: Int64, end: Int64, downloaded: Int64) {
        self.index = index
        self.start = start
        self.end = end
        self.downloaded = downloaded
    }

    /// 剩余需要下载的字节数
    public var remaining: Int64 {
        if end < 0 { return -1 }
        return max(0, (end - start + 1) - downloaded)
    }

    /// 该段当前请求的 Range 起始位置（续传用）
    public var nextStart: Int64 { start + downloaded }
}

// MARK: - HLS 进度

public struct HLSProgressInfo: Codable, Sendable {
    public var total: Int
    public var done: Int
    public init(total: Int, done: Int) {
        self.total = total
        self.done = done
    }
}

// MARK: - 下载记录

public struct DownloadRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var url: String
    public var filename: String
    public var directory: String
    public var totalSize: Int64         // -1 未知
    public var downloadedSize: Int64
    public var status: DownloadStatus
    public var segments: [SegmentState]
    public var referer: String?
    public var userAgent: String?
    public var cookie: String?
    public var createdAt: Date
    public var completedAt: Date?
    public var errorMessage: String?
    public var isSingle: Bool           // 单连接模式（服务器不支持分段）
    public var finalPath: String?       // 完成后文件位置
    public var hlsInfo: HLSProgressInfo? // HLS 分片进度（下载中）

    public init(
        id: UUID = UUID(),
        url: String,
        filename: String,
        directory: String,
        totalSize: Int64 = -1,
        downloadedSize: Int64 = 0,
        status: DownloadStatus = .queued,
        segments: [SegmentState] = [],
        referer: String? = nil,
        userAgent: String? = nil,
        cookie: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        isSingle: Bool = false,
        finalPath: String? = nil,
        hlsInfo: HLSProgressInfo? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.directory = directory
        self.totalSize = totalSize
        self.downloadedSize = downloadedSize
        self.status = status
        self.segments = segments
        self.referer = referer
        self.userAgent = userAgent
        self.cookie = cookie
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.isSingle = isSingle
        self.finalPath = finalPath
        self.hlsInfo = hlsInfo
    }

    /// 进度 0...1（未知大小时按 -1 处理）
    public var progress: Double {
        guard totalSize > 0 else { return -1 }
        return min(1.0, Double(downloadedSize) / Double(totalSize))
    }

    public var isActive: Bool {
        status == .queued || status == .connecting || status == .downloading
    }

    /// 中文分类（按文件扩展名）
    public var category: DownloadCategory {
        DownloadCategory.from(extension: (filename as NSString).pathExtension)
    }

    /// 实际保存目录（开启分类时在下载目录下建中文子文件夹）
    public func resolvedSaveDirectory(settings: AppSettings) -> String {
        guard settings.sortIntoCategories else { return directory }
        return (directory as NSString).appendingPathComponent(category.rawValue)
    }
}

// MARK: - 新增下载请求（来自扩展 / 界面）

public struct NewDownloadRequest: Codable, Sendable {
    public var url: String
    public var filename: String?
    public var directory: String?
    public var referer: String?
    public var userAgent: String?
    public var cookie: String?

    public init(
        url: String,
        filename: String? = nil,
        directory: String? = nil,
        referer: String? = nil,
        userAgent: String? = nil,
        cookie: String? = nil
    ) {
        self.url = url
        self.filename = filename
        self.directory = directory
        self.referer = referer
        self.userAgent = userAgent
        self.cookie = cookie
    }
}
