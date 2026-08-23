import Foundation
import QuickDownCore

// 无界面命令行工具：用于无头下载测试与服务器调试
// 用法:
//   QuickDownCLI download <url> [--dir <path>] [--segments N] [--concurrent N]
//   QuickDownCLI server [--port N]
//   QuickDownCLI resume-test <url> [--dir <path>]

func log(_ s: String) {
    print("[\(Date().formatted(date: .omitted, time: .standard))] \(s)")
    fflush(stdout)
}

func poll(_ condition: () -> Bool, timeout: TimeInterval, _ onTick: () -> Void = {}) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        onTick()
        Thread.sleep(forTimeInterval: 0.3)
    }
    return false
}

func runDownloadTest(args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("用法: QuickDownCLI download <url> [--dir <path>] [--segments N] [--concurrent N]")
        return 1
    }
    let url = args[1]
    var dir = FileManager.default.temporaryDirectory.appendingPathComponent("qd-cli-\(UUID().uuidString)").path
    var segments = 4
    var concurrent = 2

    var i = 2
    while i < args.count {
        switch args[i] {
        case "--dir": if i + 1 < args.count { dir = args[i + 1]; i += 2 }
        case "--segments": if i + 1 < args.count { segments = Int(args[i + 1]) ?? 4; i += 2 }
        case "--concurrent": if i + 1 < args.count { concurrent = Int(args[i + 1]) ?? 2; i += 2 }
        default: i += 1
        }
    }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    log("下载目录: \(dir)")

    let settings = AppSettings(downloadDirectory: dir, maxConcurrent: concurrent, maxSegments: segments,
                               minSegmentSize: 1, notifyOnComplete: false, serverPort: 10007)
    let store = DownloadStore(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("db.json"))
    let manager = DownloadManager(settings: settings, store: store)

    DownloadTask.debugLog = { log("  [引擎] \($0)") }

    manager.onChange = {
        let recs = manager.snapshot()
        if let r = recs.first(where: { $0.isActive || $0.status == .error || $0.status == .completed }) {
            let pct = r.totalSize > 0 ? String(format: "%.1f%%", r.progress * 100) : "?"
            log("状态=\(r.status.rawValue) 大小=\(r.downloadedSize)/\(r.totalSize) \(pct) 段=\(r.segments.count) 错误=\(r.errorMessage ?? "-")")
        }
    }

    let id = manager.add(NewDownloadRequest(url: url))
    log("已添加任务 \(id.uuidString)")

    let done = poll({ manager.snapshot().first { $0.id == id }?.status == .completed },
                    timeout: 180) {
        // 打印进度
    }
    let rec = manager.snapshot().first { $0.id == id }
    if done, let rec, let path = rec.finalPath {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        log("✅ 完成: \(path) (\(size) 字节) 分段=\(rec.isSingle ? "单连接" : "\(rec.segments.count)段")")
        return 0
    } else {
        log("❌ 失败: \(rec?.errorMessage ?? "超时")")
        return 1
    }
}

func runServerTest(port: UInt16) -> Int32 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qd-server-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let settings = AppSettings(downloadDirectory: dir, maxConcurrent: 2, maxSegments: 4,
                               minSegmentSize: 1, notifyOnComplete: false, serverPort: port)
    let store = DownloadStore(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("db.json"))
    let manager = DownloadManager(settings: settings, store: store)
    let server = LocalServer(manager: manager, port: port)
    try? server.start()
    log("服务器已启动 http://127.0.0.1:\(port)（Ctrl+C 退出）")
    log("接口: GET /ping, POST /add (JSON), GET /status, GET /")
    RunLoop.main.run()
    return 0
}

func runResumeTest(args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("用法: QuickDownCLI resume-test <url> [--dir <path>]")
        return 1
    }
    let url = args[1]
    var dir = FileManager.default.temporaryDirectory.appendingPathComponent("qd-resume-\(UUID().uuidString)").path
    if let idx = args.firstIndex(of: "--dir"), idx + 1 < args.count { dir = args[idx + 1] }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let settings = AppSettings(downloadDirectory: dir, maxConcurrent: 1, maxSegments: 4,
                               minSegmentSize: 1, notifyOnComplete: false, serverPort: 10007)
    let store = DownloadStore(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("db.json"))
    let manager = DownloadManager(settings: settings, store: store)

    let id = manager.add(NewDownloadRequest(url: url))
    log("开始下载 \(id)")

    // 等下载超过 1MB
    let started = poll({
        (manager.snapshot().first { $0.id == id }?.downloadedSize ?? 0) > 1024 * 1024
    }, timeout: 60)
    guard started else {
        log("❌ 未能在 60 秒内开始下载: \(manager.snapshot().first { $0.id == id }?.errorMessage ?? "未知")")
        return 1
    }
    manager.pause(id)
    let pausedOK = poll({
        manager.snapshot().first { $0.id == id }?.status == .paused
    }, timeout: 10)
    let pausedSize = manager.snapshot().first { $0.id == id }?.downloadedSize ?? 0
    log("⏸️ 已暂停，已下载 \(pausedSize) 字节 (pausedOK=\(pausedOK))")

    Thread.sleep(forTimeInterval: 2)
    let after = manager.snapshot().first { $0.id == id }?.downloadedSize ?? 0
    log("暂停 2 秒后大小: \(after)（应等于 \(pausedSize)）")

    manager.resume(id)
    log("🔄 继续下载...")
    let done = poll({ manager.snapshot().first { $0.id == id }?.status == .completed }, timeout: 180)
    let rec = manager.snapshot().first { $0.id == id }
    if done, let rec, let path = rec.finalPath {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        log("✅ 续传完成: \(path) (\(size) 字节)")
        return size == rec.totalSize ? 0 : 2
    } else {
        log("❌ 续传失败: \(rec?.errorMessage ?? "超时")")
        return 1
    }
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    print("用法: QuickDownCLI <download|server|resume-test> ...")
    exit(1)
}

switch cmd {
case "download":
    exit(runDownloadTest(args: args))
case "server":
    var port: UInt16 = 10007
    if let idx = args.firstIndex(of: "--port"), idx + 1 < args.count {
        port = UInt16(args[idx + 1]) ?? 10007
    }
    exit(runServerTest(port: port))
case "resume-test":
    exit(runResumeTest(args: args))
default:
    print("未知命令: \(cmd)")
    exit(1)
}
