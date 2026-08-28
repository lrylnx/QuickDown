import Foundation

// MARK: - 应用设置

public struct AppSettings: Codable, Sendable {
    public var downloadDirectory: String
    public var maxConcurrent: Int       // 同时下载数
    public var maxSegments: Int         // 分段数
    public var minSegmentSize: Int64    // 小于该大小不分段
    public var launchAtLogin: Bool
    public var notifyOnComplete: Bool
    public var serverPort: UInt16
    public var speedLimitBps: Int64     // 0 = 不限速
    public var popWindowOnCapture: Bool // 扩展接管下载时弹出主窗口
    public var confirmOnCapture: Bool  // 扩展接管下载后先弹确认窗口（可重命名/选位置）
    public var sortIntoCategories: Bool // 按中文分类保存到子文件夹
    public var menuBarIconStyle: String // "color" 品牌彩色 / "mono" 黑白跟随系统

    // 代理
    public var proxyEnabled: Bool
    public var proxyHost: String
    public var proxyPort: Int
    public var proxyUsername: String?
    public var proxyPassword: String?

    public init(
        downloadDirectory: String = AppSettings.defaultDownloadDirectory,
        maxConcurrent: Int = 3,
        maxSegments: Int = 8,
        minSegmentSize: Int64 = 1024 * 1024, // 1MB 以下不分段
        launchAtLogin: Bool = false,
        notifyOnComplete: Bool = true,
        serverPort: UInt16 = 10007,
        speedLimitBps: Int64 = 0,
        popWindowOnCapture: Bool = true,
        confirmOnCapture: Bool = true,
        sortIntoCategories: Bool = true,
        menuBarIconStyle: String = "color",
        proxyEnabled: Bool = false,
        proxyHost: String = "127.0.0.1",
        proxyPort: Int = 7890,
        proxyUsername: String? = nil,
        proxyPassword: String? = nil
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxConcurrent = maxConcurrent
        self.maxSegments = maxSegments
        self.minSegmentSize = minSegmentSize
        self.launchAtLogin = launchAtLogin
        self.notifyOnComplete = notifyOnComplete
        self.serverPort = serverPort
        self.speedLimitBps = speedLimitBps
        self.popWindowOnCapture = popWindowOnCapture
        self.confirmOnCapture = confirmOnCapture
        self.sortIntoCategories = sortIntoCategories
        self.menuBarIconStyle = menuBarIconStyle
        self.proxyEnabled = proxyEnabled
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
    }

    /// 兼容旧配置文件：缺失字段使用默认值
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadDirectory = try c.decodeIfPresent(String.self, forKey: .downloadDirectory) ?? AppSettings.defaultDownloadDirectory
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 3
        maxSegments = try c.decodeIfPresent(Int.self, forKey: .maxSegments) ?? 8
        minSegmentSize = try c.decodeIfPresent(Int64.self, forKey: .minSegmentSize) ?? 1024 * 1024
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        notifyOnComplete = try c.decodeIfPresent(Bool.self, forKey: .notifyOnComplete) ?? true
        serverPort = try c.decodeIfPresent(UInt16.self, forKey: .serverPort) ?? 10007
        speedLimitBps = try c.decodeIfPresent(Int64.self, forKey: .speedLimitBps) ?? 0
        popWindowOnCapture = try c.decodeIfPresent(Bool.self, forKey: .popWindowOnCapture) ?? true
        confirmOnCapture = try c.decodeIfPresent(Bool.self, forKey: .confirmOnCapture) ?? true
        sortIntoCategories = try c.decodeIfPresent(Bool.self, forKey: .sortIntoCategories) ?? true
        menuBarIconStyle = try c.decodeIfPresent(String.self, forKey: .menuBarIconStyle) ?? "color"
        proxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyEnabled) ?? false
        proxyHost = try c.decodeIfPresent(String.self, forKey: .proxyHost) ?? "127.0.0.1"
        proxyPort = try c.decodeIfPresent(Int.self, forKey: .proxyPort) ?? 7890
        proxyUsername = try c.decodeIfPresent(String.self, forKey: .proxyUsername)
        proxyPassword = try c.decodeIfPresent(String.self, forKey: .proxyPassword)
    }

    public static var defaultDownloadDirectory: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return downloads?.path ?? NSHomeDirectory() + "/Downloads"
    }

    public var proxyURL: URL? {
        guard proxyEnabled, !proxyHost.isEmpty, proxyPort > 0 else { return nil }
        return URL(string: "http://\(proxyHost):\(proxyPort)")
    }
}

// MARK: - 设置存储

public final class SettingsStore {
    public static let shared = SettingsStore()
    private let fileURL: URL
    private let lock = NSLock()

    public private(set) var settings: AppSettings {
        get {
            lock.lock(); defer { lock.unlock() }
            return _settings
        }
        set {
            lock.lock(); _settings = newValue; lock.unlock()
            save()
        }
    }
    private var _settings: AppSettings

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("QuickDown", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: fileURL),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            _settings = s
        } else {
            _settings = AppSettings()
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var s = settings
        mutate(&s)
        settings = s
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
