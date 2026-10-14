import XCTest
@testable import QuickDownCore

final class BrowserIntegrationTests: XCTestCase {
    func testNativeMessageUTF8RoundTrip() throws {
        let pipe = Pipe()
        let frame = try BrowserIntegration.encodedMessage(["action": "launch", "text": "速下"])
        try pipe.fileHandleForWriting.write(contentsOf: frame)
        try pipe.fileHandleForWriting.close()
        let decoded = try BrowserIntegration.readMessage(from: pipe.fileHandleForReading)
        XCTAssertEqual(decoded["action"] as? String, "launch")
        XCTAssertEqual(decoded["text"] as? String, "速下")
    }

    func testTruncatedAndOversizedFramesRejected() throws {
        for frame in [Data([2, 0, 0, 0, 123]), Data([255, 255, 255, 255])] {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: frame)
            try pipe.fileHandleForWriting.close()
            XCTAssertThrowsError(try BrowserIntegration.readMessage(from: pipe.fileHandleForReading))
        }
    }

    func testRegistrationPreservesProfileIDsAndUsesExecutablePath() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qd-registration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("QuickDown.app")
        let bridge = app.appendingPathComponent("Contents/MacOS/QuickDownBridge")
        try fm.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bridge)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
        let directory = root.appendingPathComponent("browser")
        let profile = directory.appendingPathComponent("Default")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        let existingID = String(repeating: "b", count: 32)
        let preferences = ["extensions": ["settings": [existingID: ["manifest": ["name": "速下 - 浏览器下载接管"]]]]]
        try JSONSerialization.data(withJSONObject: preferences).write(to: profile.appendingPathComponent("Secure Preferences"))
        let actual = root.appendingPathComponent("actual-extension")
        try fm.createDirectory(at: actual, withIntermediateDirectories: true)
        let extPath = root.appendingPathComponent("custom-extension")
        try fm.createSymbolicLink(at: extPath, withDestinationURL: actual)
        XCTAssertEqual(try BrowserIntegration.register(appURL: app, home: root, extensionPaths: [extPath],
                                                       browserDataDirectories: [directory]), 1)
        let data = try Data(contentsOf: directory.appendingPathComponent("NativeMessagingHosts/com.quickdown.bridge.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["path"] as? String, bridge.resolvingSymlinksInPath().path)
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        let origins = try XCTUnwrap(manifest["allowed_origins"] as? [String])
        XCTAssertTrue(origins.contains("chrome-extension://\(existingID)/"))
        XCTAssertTrue(origins.contains("chrome-extension://\(BrowserIntegration.extensionID(path: extPath.resolvingSymlinksInPath().path))/"))
        XCTAssertTrue(origins.contains("chrome-extension://\(BrowserIntegration.extensionID(path: extPath.standardizedFileURL.path))/"))
        XCTAssertFalse(origins.contains("*"))
        XCTAssertTrue(origins.allSatisfy { $0.count == 52 })
    }

    func testRegistrationRejectsMissingBridge() {
        XCTAssertThrowsError(try BrowserIntegration.register(appURL: URL(fileURLWithPath: "/missing/QuickDown.app")))
    }
    func testRegistrationWorksBeforeFirstBrowserLaunch() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("qd-first-browser-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let app = home.appendingPathComponent("QuickDown.app")
        let bridge = app.appendingPathComponent("Contents/MacOS/QuickDownBridge")
        try fm.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bridge)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
        XCTAssertEqual(try BrowserIntegration.register(appURL: app, home: home), BrowserIntegration.browserDirectories.count)
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/com.quickdown.bridge.json").path))
    }

}
