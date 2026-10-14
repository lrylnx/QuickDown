import Foundation
import CryptoKit
import Darwin

/// 浏览器原生通信的安装注册与帧编码；不保存下载任务。
public enum BrowserIntegration {
    public static let hostName = "com.quickdown.bridge"
    public static let browserDirectories = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary",
        "Google/ChromeForTesting", "Microsoft Edge", "Thorium", "BraveSoftware/Brave-Browser",
        "Chromium", "Vivaldi", "Arc/User Data", "com.operasoftware.Opera"
    ]

    public static func extensionID(path: String) -> String {
        extensionID(digest: Data(SHA256.hash(data: Data(path.utf8))))
    }

    private static func extensionID(digest: Data) -> String {
        digest.prefix(16).map { byte in
            String(UnicodeScalar(97 + UInt32(byte >> 4))!) + String(UnicodeScalar(97 + UInt32(byte & 15))!)
        }.joined()
    }

    public static func encodedMessage(_ object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        guard json.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        var length = UInt32(json.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(json)
        return data
    }

    public static func readMessage(from input: FileHandle) throws -> [String: Any] {
        func readExactly(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let part = try input.read(upToCount: count - data.count), !part.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                data.append(part)
            }
            return data
        }
        let header = try readExactly(4)
        let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        // 启动请求很小；拒绝不受控的输入长度。
        guard length > 0, length <= 65536 else { throw CocoaError(.fileReadTooLarge) }
        let data = try readExactly(Int(length))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    @discardableResult
    public static func register(appURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                extensionPaths: [URL] = [], browserDataDirectories: [URL]? = nil) throws -> Int {
        let fm = FileManager.default
        let app = appURL.resolvingSymlinksInPath()
        let bridge = app.appendingPathComponent("Contents/MacOS/QuickDownBridge")
        guard fm.isExecutableFile(atPath: bridge.path) else { throw CocoaError(.fileNoSuchFile) }
        let support = home.appendingPathComponent("Library/Application Support")
        let directories = browserDataDirectories ?? browserDirectories.map { support.appendingPathComponent($0) }
        let name = "速下 - 浏览器下载接管"
        var ids = Set<String>()
        let paths = extensionPaths + [appURL.appendingPathComponent("Contents/Resources/BrowserExtension"),
                                     app.appendingPathComponent("Contents/Resources/BrowserExtension"),
                                     support.appendingPathComponent("QuickDown/browser-extension")]
        for path in paths {
            // Chromium 按加载时的路径生成 ID，符号链接路径与真实路径都需允许。
            ids.insert(extensionID(path: path.standardizedFileURL.path))
            ids.insert(extensionID(path: path.resolvingSymlinksInPath().path))
            // Foundation 会缩写 /private/var、/private/tmp；Chromium 的 realpath 不会。
            if let resolved = realpath(path.path, nil) {
                ids.insert(extensionID(path: String(cString: resolved)))
                free(resolved)
            }
        }
        // CRX 及以后带固定 key 的扩展也在允许列表中。
        if let manifestData = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/BrowserExtension/manifest.json")),
           let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
           let key = manifest["key"] as? String, let data = Data(base64Encoded: key) {
            ids.insert(extensionID(digest: Data(SHA256.hash(data: data))))
        }
        if let publicKey = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/BrowserExtensionPublicKey.der")) {
            ids.insert(extensionID(digest: Data(SHA256.hash(data: publicKey))))
        }
        for directory in directories {
            let profiles = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for profile in profiles where profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile") {
                for file in ["Preferences", "Secure Preferences"] {
                    guard let data = try? Data(contentsOf: profile.appendingPathComponent(file)),
                          let preferences = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let extensions = preferences["extensions"] as? [String: Any],
                          let settings = extensions["settings"] as? [String: [String: Any]] else { continue }
                    for (id, info) in settings {
                        var manifest = info["manifest"] as? [String: Any]
                        if let path = info["path"] as? String {
                            let expanded = (path as NSString).expandingTildeInPath
                            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : profile.appendingPathComponent(expanded)
                            if let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) {
                                manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                            }
                        }
                        if manifest?["name"] as? String == name, id.count == 32,
                           id.allSatisfy({ ("a"..."p").contains(String($0)) }) { ids.insert(id) }
                    }
                }
            }
        }
        let manifest: [String: Any] = ["name": hostName, "description": "QuickDown App launcher",
            "path": bridge.path, "type": "stdio", "allowed_origins": ids.sorted().map { "chrome-extension://\($0)/" }]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        for directory in directories {
            let hosts = directory.appendingPathComponent("NativeMessagingHosts")
            try fm.createDirectory(at: hosts, withIntermediateDirectories: true)
            try data.write(to: hosts.appendingPathComponent(hostName + ".json"), options: .atomic)
        }
        return directories.count
    }
}
