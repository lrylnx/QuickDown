import Foundation

// MARK: - 文件名处理

public enum FileNaming {

    /// 从 Content-Disposition 头解析文件名（支持 filename 与 filename*=UTF-8''...）
    public static func filename(fromContentDisposition value: String?) -> String? {
        guard let value = value else { return nil }

        // filename*=UTF-8''... 优先
        if let star = value.range(of: "filename*=", options: .caseInsensitive) {
            let rest = value[star.upperBound...]
            let raw = rest.split(separator: ";").first.map(String.init) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let eq = trimmed.range(of: "''") {
                let encoded = String(trimmed[eq.upperBound...])
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                    return sanitize(decoded)
                }
            }
        }

        // filename="..."
        if let m = value.range(of: "filename=", options: .caseInsensitive) {
            let rest = value[m.upperBound...]
            let raw = rest.split(separator: ";").first.map(String.init) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !cleaned.isEmpty {
                return sanitize(cleaned.removingPercentEncoding ?? cleaned)
            }
        }
        return nil
    }

    /// 从 URL 提取文件名
    public static func filename(fromURL url: URL) -> String? {
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return nil }
        return sanitize(last.removingPercentEncoding ?? last)
    }

    /// 清洗非法字符
    public static func sanitize(_ name: String) -> String {
        var n = name
        // 去掉路径分隔符与控制字符
        n = n.replacingOccurrences(of: "/", with: "_")
        n = n.replacingOccurrences(of: "\\", with: "_")
        n = n.replacingOccurrences(of: ":", with: "_")
        n = n.trimmingCharacters(in: CharacterSet.controlCharacters)
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉开头点号
        while n.hasPrefix(".") { n.removeFirst() }
        if n.isEmpty { n = "download" }
        if n.count > 180 { n = String(n.prefix(180)) }
        return n
    }

    /// 目录去重：已存在则追加 " (1)"、" (2)"
    public static func uniquePath(directory: String, filename: String) -> String {
        let fm = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = filename
        var counter = 1
        while fm.fileExists(atPath: (directory as NSString).appendingPathComponent(candidate)) {
            let suffix = ext.isEmpty ? " (\(counter))" : " (\(counter)).\(ext)"
            candidate = "\(base)\(suffix)"
            counter += 1
        }
        return (directory as NSString).appendingPathComponent(candidate)
    }

    /// 下载中的临时分段文件名
    public static func partFileName(for finalName: String, index: Int) -> String {
        ".\(finalName).part\(index)"
    }
}
