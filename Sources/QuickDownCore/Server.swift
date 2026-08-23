import Foundation
import AppKit
import CryptoKit

// MARK: - 本地 HTTP / WebSocket 服务器（基于 POSIX socket，供浏览器扩展调用）

public final class LocalServer: @unchecked Sendable {

    private var serverFD: Int32 = -1
    private var acceptThread: Thread?
    private let manager: DownloadManager
    private let lock = NSLock()
    public private(set) var port: UInt16

    public init(manager: DownloadManager, port: UInt16) {
        self.manager = manager
        self.port = port
    }

    deinit { stop() }

    public func start() throws {
        stop()
        for offset in 0..<10 {
            let candidate = port &+ UInt16(offset)
            if let fd = bindAndListen(candidate) {
                serverFD = fd
                port = candidate
                let t = Thread { [weak self] in self?.acceptLoop() }
                t.name = "quickdown.accept"
                t.start()
                acceptThread = t
                return
            }
        }
        throw DownloadError.fileSystem("无法绑定本地端口（10007-10016 均被占用）")
    }

    public func stop() {
        lock.lock()
        let fd = serverFD
        serverFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        acceptThread?.cancel()
        acceptThread = nil
    }

    // MARK: - socket

    private func bindAndListen(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound, listen(fd, 32) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func acceptLoop() {
        while true {
            let cfd = accept(serverFD, nil, nil)
            if cfd < 0 { break }
            let handler = ConnectionHandler(fd: cfd, manager: manager)
            DispatchQueue.global().async { [weak self] in
                self?.serve(handler)
            }
        }
    }

    private func serve(_ h: ConnectionHandler) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while !h.finished {
            let n = recv(h.fd, &buf, buf.count, 0)
            if n <= 0 { break }
            h.buffer.append(contentsOf: buf[0..<n])
            process(h)
        }
        close(h.fd)
        h.fd = -1
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        guard fd >= 0, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return send(fd, base.advanced(by: sent), bytes.count - sent, 0)
            }
            if n <= 0 { break }
            sent += n
        }
    }

    // MARK: - 协议处理

    private func process(_ h: ConnectionHandler) {
        if h.isWebSocket {
            processWebSocket(h)
            return
        }
        guard let req = parseHTTPRequest(h.buffer) else { return }
        h.buffer.removeAll()

        if req.isWebSocketUpgrade {
            guard let accept = wsAcceptKey(req.headers["sec-websocket-key"]) else {
                sendResponse(h, status: 400, body: "bad request")
                h.finished = true
                return
            }
            let resp = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: websocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            sendAll(h.fd, Data(resp.utf8))
            h.isWebSocket = true
            wsSend(h, text: "waiting") // 通知扩展：可以接管下载
            return
        }

        let (status, body) = route(req)
        sendResponse(h, status: status, body: body)
        h.finished = true
    }

    private func route(_ req: HTTPRequest) -> (Int, String) {
        let path = req.path.components(separatedBy: "?").first ?? req.path
        switch (req.method, path) {
        case ("OPTIONS", _):
            // CORS 预检请求：必须返回 2xx（sendResponse 会自动附带 Access-Control-Allow-* 头）
            return (200, "")
        case ("GET", "/ping"):
            return (200, "ok")
        case ("GET", "/"):
            return (200, "{\"name\":\"QuickDown\",\"version\":\"1.0\",\"desc\":\"速下下载管理器本地服务\"}")
        case ("POST", "/add"):
            let result = handleAdd(req.body)
            if result.0 == 200 && SettingsStore.shared.settings.popWindowOnCapture {
                activateApp()
            }
            return result
        case ("GET", "/status"):
            let active = manager.snapshot().filter { $0.isActive }.count
            return (200, "{\"active\":\(active)}")
        case ("GET", "/activate"):
            activateApp()
            return (200, "ok")
        default:
            return (404, "{\"error\":\"not found\"}")
        }
    }

    private func handleAdd(_ body: Data) -> (Int, String) {
        var request: NewDownloadRequest
        do {
            request = try JSONDecoder().decode(NewDownloadRequest.self, from: body)
        } catch {
            return (400, "{\"error\":\"invalid json\"}")
        }
        guard let url = URL(string: request.url), url.scheme != nil else {
            return (400, "{\"error\":\"invalid url\"}")
        }
        let id = manager.add(request)
        return (200, "{\"ok\":true,\"id\":\"\(id.uuidString)\"}")
    }

    /// 唤起应用主窗口（仅当速下不在前台时，避免打扰正在操作其他应用的用户）
    private func activateApp() {
        DispatchQueue.main.async {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let isSelf = frontmost == Bundle.main.bundleIdentifier
            guard !isSelf else { return }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible || $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        }
    }

    private func sendResponse(_ h: ConnectionHandler, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\n" +
                   "Content-Type: application/json; charset=utf-8\r\n" +
                   "Access-Control-Allow-Origin: *\r\n" +
                   "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                   "Access-Control-Allow-Headers: Content-Type\r\n" +
                   "Content-Length: \(bodyData.count)\r\n" +
                   "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        sendAll(h.fd, out)
    }

    // MARK: - WebSocket（NDM 官方扩展兼容）

    private func processWebSocket(_ h: ConnectionHandler) {
        guard let (frames, remaining) = parseWebSocketFrames(h.buffer) else { return }
        h.buffer = remaining
        for frame in frames {
            switch frame.opcode {
            case 0x8: // close
                wsSend(h, opcode: 0x8, payload: Data())
                h.finished = true
            case 0x9: // ping -> pong
                wsSend(h, opcode: 0xA, payload: frame.payload)
            case 0x1: // text
                if let text = String(data: frame.payload, encoding: .utf8) {
                    handleNDMMessage(text)
                    wsSend(h, text: "waiting")
                }
            default:
                break
            }
        }
    }

    /// 解析 NDM 扩展的文本协议消息并加入下载
    private func handleNDMMessage(_ text: String) {
        var url: String?
        var filename: String?
        var referer: String?
        var cookie: String?
        var userAgent: String?

        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            if line.hasPrefix("2:") {
                url = String(line.dropFirst(2))
            } else if line.hasPrefix("3:") {
                filename = String(line.dropFirst(2))
            } else if line.hasPrefix("Referer: ") {
                referer = String(line.dropFirst("Referer: ".count))
            } else if line.hasPrefix("5:") {
                referer = String(line.dropFirst(2))
            } else if line.hasPrefix("Cookie: ") {
                cookie = String(line.dropFirst("Cookie: ".count))
            } else if line.hasPrefix("x-User-Agent: ") {
                userAgent = String(line.dropFirst("x-User-Agent: ".count))
            }
        }
        guard let url, URL(string: url) != nil else { return }
        manager.add(NewDownloadRequest(url: url, filename: filename, referer: referer,
                                       userAgent: userAgent, cookie: cookie))
    }

    private func wsSend(_ h: ConnectionHandler, text: String) {
        wsSend(h, opcode: 0x1, payload: Data(text.utf8))
    }

    private func wsSend(_ h: ConnectionHandler, opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len < 65536 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            var l = UInt64(len)
            var bytes: [UInt8] = []
            for _ in 0..<8 {
                bytes.insert(UInt8(l & 0xFF), at: 0)
                l >>= 8
            }
            frame.append(contentsOf: bytes)
        }
        frame.append(payload)
        sendAll(h.fd, frame)
    }

    private func wsAcceptKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    private func parseWebSocketFrames(_ buffer: Data) -> ([(opcode: UInt8, payload: Data)], Data)? {
        var frames: [(opcode: UInt8, payload: Data)] = []
        var offset = 0
        while true {
            guard buffer.count - offset >= 2 else { return (frames, offset > 0 ? Data(buffer[offset...]) : Data()) }
            let b0 = buffer[offset]
            let b1 = buffer[offset + 1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7F)
            var idx = offset + 2
            if len == 126 {
                guard buffer.count - idx >= 2 else { return (frames, Data(buffer[offset...])) }
                len = (Int(buffer[idx]) << 8) | Int(buffer[idx + 1])
                idx += 2
            } else if len == 127 {
                guard buffer.count - idx >= 8 else { return (frames, Data(buffer[offset...])) }
                var l: UInt64 = 0
                for i in 0..<8 {
                    l = (l << 8) | UInt64(buffer[idx + i])
                }
                len = Int(l)
                idx += 8
            }
            var maskKey: [UInt8] = []
            if masked {
                guard buffer.count - idx >= 4 else { return (frames, Data(buffer[offset...])) }
                maskKey = Array(buffer[idx..<(idx + 4)])
                idx += 4
            }
            guard buffer.count - idx >= len else { return (frames, Data(buffer[offset...])) }
            var payload = Data(buffer[idx..<(idx + len)])
            if masked {
                for i in 0..<payload.count {
                    payload[i] ^= maskKey[i % 4]
                }
            }
            frames.append((opcode, payload))
            offset = idx + len
        }
    }

    // MARK: - HTTP 请求解析

    private func parseHTTPRequest(_ buffer: Data) -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: Data(headerData), encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.lowerBound + 4
        guard buffer.count - bodyStart >= contentLength else { return nil }
        let body = buffer[bodyStart..<(bodyStart + contentLength)]

        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }
}

// MARK: - 内部类型

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    var isWebSocketUpgrade: Bool {
        (headers["upgrade"] ?? "").lowercased() == "websocket"
    }
}

private final class ConnectionHandler {
    var fd: Int32
    let manager: DownloadManager
    var buffer = Data()
    var isWebSocket = false
    var finished = false

    init(fd: Int32, manager: DownloadManager) {
        self.fd = fd
        self.manager = manager
    }
}
