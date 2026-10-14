import XCTest
@testable import QuickDownCore

final class BrowserCaptureSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testFreshCaptureAccepted() {
        let session = BrowserCaptureSession(now: start)
        XCTAssertTrue(session.accepts(session: session.id, capturedAt: "1000100",
                                      now: start.addingTimeInterval(1)))
    }

    func testOfflineAndExpiredCaptureRejected() {
        let session = BrowserCaptureSession(now: start)
        XCTAssertFalse(session.accepts(session: session.id, capturedAt: "999999", now: start))
        XCTAssertFalse(session.accepts(session: session.id, capturedAt: "1000000",
                                       now: start.addingTimeInterval(3.001)))
        XCTAssertFalse(session.accepts(session: session.id, capturedAt: "1001000", now: start))
    }

    func testRestartAndMalformedCredentialsRejected() {
        let first = BrowserCaptureSession(now: start)
        let second = BrowserCaptureSession(now: start)
        XCTAssertFalse(second.accepts(session: first.id, capturedAt: "1000000", now: start))
        for invalid in [nil, "NaN", "inf", "", "not-a-number"] as [String?] {
            XCTAssertFalse(first.accepts(session: first.id, capturedAt: invalid, now: start))
        }
        XCTAssertFalse(first.accepts(session: nil, capturedAt: "1000000", now: start))
    }
    func testHTTPHandshakeAndCaptureGuard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qd-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = DownloadManager(settings: AppSettings(downloadDirectory: directory.path, notifyOnComplete: false),
                                      store: DownloadStore(fileURL: directory.appendingPathComponent("db.json")))
        let server = LocalServer(manager: manager, port: 19577)
        try server.start()
        defer { server.stop(); manager.pauseAll(); try? FileManager.default.removeItem(at: directory) }
        let base = "http://127.0.0.1:\(server.port)"
        let (data, response) = try await URLSession.shared.data(from: URL(string: base + "/integration")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "QuickDown")
        XCTAssertEqual(info["protocol"] as? Int, 2)
        let session = try XCTUnwrap(info["session"] as? String)
        let startedAt = try XCTUnwrap(info["startedAt"] as? Double)

        var request = URLRequest(url: URL(string: base + "/add")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"url\":\"http://127.0.0.1:1/file\"}".utf8)
        request.setValue("wrong-session", forHTTPHeaderField: "X-QuickDown-Session")
        request.setValue(String(Date().timeIntervalSince1970 * 1000), forHTTPHeaderField: "X-QuickDown-Captured-At")
        let (_, rejected) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(manager.snapshot().isEmpty)

        request.setValue(session, forHTTPHeaderField: "X-QuickDown-Session")
        request.setValue(String(startedAt - 1), forHTTPHeaderField: "X-QuickDown-Captured-At")
        let (_, stale) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((stale as? HTTPURLResponse)?.statusCode, 409)
        XCTAssertTrue(manager.snapshot().isEmpty)

        // 有效凭据进入 JSON 校验，非法 JSON 返回 400，而非会话校验的 409。
        request.httpBody = Data("not json".utf8)
        request.setValue(String(Date().timeIntervalSince1970 * 1000), forHTTPHeaderField: "X-QuickDown-Captured-At")
        let (_, current) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((current as? HTTPURLResponse)?.statusCode, 400)

        request.httpMethod = "OPTIONS"
        let (_, preflight) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((preflight as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue((preflight as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Headers")?.contains("X-QuickDown-Session") == true)
    }

}
