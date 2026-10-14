import Foundation
import QuickDownCore

@main
struct QuickDownBridge {
    static var appURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func main() async {
        if CommandLine.arguments.contains("--register-home") {
            do {
                let args = CommandLine.arguments
                func value(_ option: String) -> String? {
                    guard let index = args.firstIndex(of: option), index + 1 < args.count else { return nil }
                    return args[index + 1]
                }
                guard let home = value("--register-home") else { throw CocoaError(.fileReadCorruptFile) }
                let paths = value("--extension-path").map { [URL(fileURLWithPath: $0)] } ?? []
                let directories = value("--browser-data-dir").map { [URL(fileURLWithPath: $0)] }
                let count = try BrowserIntegration.register(appURL: appURL, home: URL(fileURLWithPath: home),
                                                           extensionPaths: paths, browserDataDirectories: directories)
                print("已注册原生启动服务：\(count) 个浏览器")
            } catch {
                FileHandle.standardError.write(Data("注册失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        let reply: [String: Any]
        do {
            let message = try BrowserIntegration.readMessage(from: .standardInput)
            guard message["action"] as? String == "launch" else { throw CocoaError(.featureUnsupported) }
            reply = await launch()
        } catch {
            reply = ["ok": false, "error": "invalid_request"]
        }
        if let data = try? BrowserIntegration.encodedMessage(reply) { try? FileHandle.standardOutput.write(contentsOf: data) }
    }

    static func connection() async -> [String: Any]? {
        await withTaskGroup(of: [String: Any]?.self) { group in
            for port in 10007...10016 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/integration")!)
                    request.timeoutInterval = 0.4
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          var info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          info["name"] as? String == "QuickDown", info["protocol"] as? Int == 2,
                          info["session"] is String, info["startedAt"] is NSNumber else { return nil }
                    info["port"] = port
                    info["ok"] = true
                    return info
                }
            }
            for await result in group { if let result { group.cancelAll(); return result } }
            return nil
        }
    }

    static func launch() async -> [String: Any] {
        if let existing = await connection() { return existing }
        guard Bundle(url: appURL)?.bundleIdentifier == "com.quickdown.app" else {
            return ["ok": false, "error": "app_not_found"]
        }
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", appURL.path]
            // stdout 只能写 Native Messaging 协议帧。
            process.standardOutput = FileHandle.standardError
            try process.run()
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if let result = await connection() { return result }
                if !process.isRunning && process.terminationStatus != 0 { return ["ok": false, "error": "launch_failed"] }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning { process.terminate() }
            return ["ok": false, "error": "launch_timeout"]
        } catch { return ["ok": false, "error": "launch_failed"] }
    }
}
