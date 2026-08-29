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

    /// 从 URL 提取文件名：优先查询参数里的真实名（蓝奏云等网盘 CDN 的
    /// fileName= / filename= 参数），其次 URL 路径末段
    public static func filename(fromURL url: URL) -> String? {
        if let q = filename(fromURLQuery: url) { return q }
        return filename(fromURLPath: url)
    }

    /// 从 URL 路径末段提取文件名
    public static func filename(fromURLPath url: URL) -> String? {
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/" else { return nil }
        return sanitize(last.removingPercentEncoding ?? last)
    }

    /// 从 URL 查询参数提取文件名（大小写不敏感：fileName / filename / file_name）
    public static func filename(fromURLQuery url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        for item in items {
            let key = item.name.lowercased()
            guard key == "filename" || key == "file_name" else { continue }
            // 查询串里 + 按表单编码惯例视为空格
            let raw = (item.value ?? "")
                .replacingOccurrences(of: "+", with: " ")
            let decoded = raw.removingPercentEncoding ?? raw
            let cleaned = sanitize(decoded)
            // 纯数字 id（如 &fi=312722080）之类不是文件名
            if cleaned.isEmpty || cleaned == "download" { continue }
            return cleaned
        }
        return nil
    }

    /// 判断给定文件名是否只是「URL 推导名」——空名、通用名、哈希名，
    /// 或与 URL 路径末段相同（说明上游只是拿 URL 兜底，并没有真实名字）。
    /// 用于决定是否用查询参数里的真实文件名（如蓝奏云 CDN 链接）覆盖它。
    public static func looksLikeDerived(_ name: String, url: URL) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        let generic = ["file", "download", "index", "default", "downloadfile", "unnamed", "未命名"]
        if generic.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }) { return true }
        // 哈希名：MD5 32 位 / SHA1 40 位十六进制
        let base = (trimmed as NSString).deletingPathExtension
        if base.count == 32 || base.count == 40 {
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            if base.unicodeScalars.allSatisfy({ hex.contains($0) }) { return true }
        }
        if let pathName = filename(fromURLPath: url), pathName == trimmed { return true }
        return false
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
