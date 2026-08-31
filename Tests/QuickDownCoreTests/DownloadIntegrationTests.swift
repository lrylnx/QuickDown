import XCTest
@testable import QuickDownCore

/// 真实网络集成测试：分段下载、单连接回退、断点续传、本地服务器
final class DownloadIntegrationTests: XCTestCase {

    var tempDir: URL!
    var manager: DownloadManager!
    var store: DownloadStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qd-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let settings = AppSettings(
            downloadDirectory: tempDir.path,
            maxConcurrent: 2,
            maxSegments: 4,
            minSegmentSize: 1024 * 1024,
            notifyOnComplete: false,
            serverPort: 10007
        )
        store = DownloadStore(fileURL: tempDir.appendingPathComponent("db.json"))
        manager = DownloadManager(settings: settings, store: store)
    }

    override func tearDownWithError() throws {
        manager.pauseAll()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 工具

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 120,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTFail("等待超时", file: file, line: line)
    }

    private func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    // MARK: - 分段下载（OVH 支持 Range）

    func testSegmentedDownload() async throws {
        let url = "https://proof.ovh.net/files/10Mb.dat"
        let id = manager.add(NewDownloadRequest(url: url))
        await waitUntil { self.manager.snapshot().first { $0.id == id }?.status == .completed }

        let rec = manager.snapshot().first { $0.id == id }
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.status, .completed, "错误：\(rec?.errorMessage ?? "")")
        XCTAssertEqual(rec?.totalSize, 10485760)
        XCTAssertFalse(rec?.isSingle ?? true, "应使用分段下载")
        XCTAssertEqual(rec?.segments.count, 4)

        guard let finalPath = rec?.finalPath else { return XCTFail("无最终路径") }
        XCTAssertEqual(fileSize(finalPath), 10485760)

        // 不应残留分段文件
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.contains(".part") }
        XCTAssertTrue(leftovers.isEmpty, "残留分段文件: \(leftovers)")
    }

    // MARK: - 单连接回退（Cloudflare 忽略 Range）

    func testSingleConnectionFallback() async throws {
        let url = "https://speed.cloudflare.com/__down?bytes=1000000"
        let id = manager.add(NewDownloadRequest(url: url))
        await waitUntil { self.manager.snapshot().first { $0.id == id }?.status == .completed }

        let rec = manager.snapshot().first { $0.id == id }
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.status, .completed, "错误：\(rec?.errorMessage ?? "")")
        XCTAssertTrue(rec?.isSingle ?? false, "应回退为单连接")
        guard let finalPath = rec?.finalPath else { return XCTFail("无最终路径") }
        XCTAssertEqual(fileSize(finalPath), 1000000)
    }

    // MARK: - 断点续传

    func testPauseResume() async throws {
        let url = "https://proof.ovh.net/files/10Mb.dat"
        let id = manager.add(NewDownloadRequest(url: url))

        // 等下载开始并下载了一部分
        await waitUntil {
            let rec = self.manager.snapshot().first { $0.id == id }
            return (rec?.downloadedSize ?? 0) > 512 * 1024
        }
        manager.pause(id)
        await waitUntil { self.manager.snapshot().first { $0.id == id }?.status == .paused }
        let pausedSize = manager.snapshot().first { $0.id == id }?.downloadedSize ?? 0
        XCTAssertGreaterThan(pausedSize, 0)

        // 暂停期间大小不应增长
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = manager.snapshot().first { $0.id == id }?.downloadedSize ?? 0
        XCTAssertEqual(after, pausedSize, "暂停后仍在下载")

        // 继续下载
        manager.resume(id)
        await waitUntil { self.manager.snapshot().first { $0.id == id }?.status == .completed }
        let rec = manager.snapshot().first { $0.id == id }
        XCTAssertEqual(rec?.status, .completed, "错误：\(rec?.errorMessage ?? "")")
        guard let finalPath = rec?.finalPath else { return XCTFail("无最终路径") }
        XCTAssertEqual(fileSize(finalPath), 10485760)
    }

    // MARK: - 失败处理（404）

    func testErrorOn404() async throws {
        let id = manager.add(NewDownloadRequest(url: "https://proof.ovh.net/files/not-exist-\(UUID().uuidString).dat"))
        await waitUntil { self.manager.snapshot().first { $0.id == id }?.status == .error }
        let rec = manager.snapshot().first { $0.id == id }
        XCTAssertEqual(rec?.status, .error)
        XCTAssertFalse(rec?.errorMessage?.isEmpty ?? true)
    }

    // MARK: - 本地服务器

    func testLocalServerHTTP() async throws {
        let server = LocalServer(manager: manager, port: 19407)
        try server.start()
        defer { server.stop() }
        try? await Task.sleep(nanoseconds: 500_000_000)

        // /ping
        let ping = URL(string: "http://127.0.0.1:19407/ping")!
        let (data, resp) = try await URLSession.shared.data(from: ping)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")

        // /add
        var req = URLRequest(url: URL(string: "http://127.0.0.1:19407/add")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(NewDownloadRequest(
            url: "https://proof.ovh.net/files/10Mb.dat",
            filename: "server-test.dat"
        ))
        let (d2, r2) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: d2) as? [String: Any]
        XCTAssertEqual(json?["ok"] as? Bool, true)

        // 非法 JSON
        var bad = URLRequest(url: URL(string: "http://127.0.0.1:19407/add")!)
        bad.httpMethod = "POST"
        bad.setValue("application/json", forHTTPHeaderField: "Content-Type")
        bad.httpBody = Data("not json".utf8)
        let (_, r3) = try await URLSession.shared.data(for: bad)
        XCTAssertEqual((r3 as? HTTPURLResponse)?.statusCode, 400)
    }

    // MARK: - 持久化

    func testPersistence() {
        let id = manager.add(NewDownloadRequest(url: "https://example.com/file.bin"))
        let reloaded = DownloadStore(fileURL: store.fileURL).load()
        XCTAssertTrue(reloaded.contains { $0.id == id })
    }

    // MARK: - 孤儿 .part 清理

    func testOrphanPartCleanup() {
        let fm = FileManager.default
        let orphan1 = tempDir.appendingPathComponent(".orphan-a.dmg.part0").path
        let orphan2 = tempDir.appendingPathComponent(".orphan-b.mp4.part3").path
        let dsStore = tempDir.appendingPathComponent(".DS_Store").path
        fm.createFile(atPath: orphan1, contents: Data(count: 10))
        fm.createFile(atPath: orphan2, contents: Data(count: 10))
        fm.createFile(atPath: dsStore, contents: Data(count: 10))

        // 有主任务的分片应被保留：加入一个暂停任务并预置它的分片
        let id = manager.add(NewDownloadRequest(
            url: "http://example.com/keep.bin",
            filename: "keep.bin",
            directory: tempDir.path
        ), autoStart: false)
        XCTAssertNotNil(id)
        let ownedPart = tempDir.appendingPathComponent(".keep.bin.part0").path
        fm.createFile(atPath: ownedPart, contents: Data(count: 10))

        manager.cleanupOrphanPartFiles()

        XCTAssertFalse(fm.fileExists(atPath: orphan1), "无主分片应被清理")
        XCTAssertFalse(fm.fileExists(atPath: orphan2), "无主分片应被清理")
        XCTAssertTrue(fm.fileExists(atPath: ownedPart), "属于现有任务的分片应保留（断点续传）")
        XCTAssertTrue(fm.fileExists(atPath: dsStore), ".DS_Store 等非分片文件不应被误删")
    }

    func testCancelRemovesOwnParts() {
        let fm = FileManager.default
        // 预置一个暂停任务（无运行中 task）对应的分片，取消时应被清掉
        let id = manager.add(NewDownloadRequest(
            url: "http://example.com/tmp.bin",
            filename: "tmp.bin",
            directory: tempDir.path
        ), autoStart: false)
        let part0 = tempDir.appendingPathComponent(".tmp.bin.part0").path
        fm.createFile(atPath: part0, contents: Data(count: 10))

        manager.cancel(id)

        XCTAssertFalse(fm.fileExists(atPath: part0), "取消任务后应清掉自己的 .part 分片")
    }
}
