import XCTest
@testable import QuickDownCore

final class FileNamingTests: XCTestCase {

    func testContentDispositionBasic() {
        let name = FileNaming.filename(fromContentDisposition: #"attachment; filename="report.pdf""#)
        XCTAssertEqual(name, "report.pdf")
    }

    func testContentDispositionUTF8Star() {
        let encoded = "attachment; filename*=UTF-8''%E6%B5%8B%E8%AF%95%E6%96%87%E4%BB%B6.zip"
        let name = FileNaming.filename(fromContentDisposition: encoded)
        XCTAssertEqual(name, "测试文件.zip")
    }

    func testContentDispositionPlain() {
        let name = FileNaming.filename(fromContentDisposition: "attachment; filename=file.bin")
        XCTAssertEqual(name, "file.bin")
    }

    func testContentDispositionNil() {
        XCTAssertNil(FileNaming.filename(fromContentDisposition: nil))
        XCTAssertNil(FileNaming.filename(fromContentDisposition: "inline"))
    }

    func testFilenameFromURL() {
        XCTAssertEqual(FileNaming.filename(fromURL: URL(string: "https://a.com/b/c/file.zip")!), "file.zip")
        XCTAssertEqual(FileNaming.filename(fromURL: URL(string: "https://a.com/%E6%B5%8B%E8%AF%95.txt")!), "测试.txt")
        XCTAssertNil(FileNaming.filename(fromURL: URL(string: "https://a.com/")!))
    }

    func testFilenameFromURLQuery() {
        // 蓝奏云真实场景：路径是哈希名，真实文件名在 fileName= 查询参数里
        let lanzou = URL(string:
            "https://pdf2.webgetstore.com/2026/08/29/025fcd6c0ce08ed21e1257963be6fd3f.pkg" +
            "?sg=29beda218fda51a7d46b339976bd88fe&e=6a927ae1" +
            "&fileName=%E9%80%9F%E4%B8%8B%E4%B8%8B%E8%BD%BD%E7%AE%A1%E7%90%86%E5%99%A8-%E4%B8%80%E9%94%AE%E5%AE%89%E8%A3%851.30.pkg" +
            "&fi=312722080")!
        XCTAssertEqual(FileNaming.filename(fromURL: lanzou), "速下下载管理器-一键安装1.30.pkg")
        // 大小写不敏感 & file_name 别名
        let lower = URL(string: "https://a.com/x.bin?filename=setup.exe")!
        XCTAssertEqual(FileNaming.filename(fromURL: lower), "setup.exe")
        let snake = URL(string: "https://a.com/x.bin?file_name=tool.zip")!
        XCTAssertEqual(FileNaming.filename(fromURL: snake), "tool.zip")
        // 查询参数缺席时回退路径末段
        let noQuery = URL(string: "https://a.com/dir/video.mp4?sg=abc&t=1")!
        XCTAssertEqual(FileNaming.filename(fromURL: noQuery), "video.mp4")
    }

    func testLooksLikeDerived() {
        let lanzou = URL(string:
            "https://cdn.example.com/2026/025fcd6c0ce08ed21e1257963be6fd3f.pkg" +
            "?fileName=%E9%80%9F%E4%B8%8B-%E4%B8%80%E9%94%AE%E5%AE%89%E8%A3%85.pkg")!
        // 哈希名 / 与路径末段相同 / 通用名 / 空名 → 视为「URL 推导名」
        XCTAssertTrue(FileNaming.looksLikeDerived("025fcd6c0ce08ed21e1257963be6fd3f.pkg", url: lanzou))
        XCTAssertTrue(FileNaming.looksLikeDerived("", url: lanzou))
        XCTAssertTrue(FileNaming.looksLikeDerived("file.bin", url: lanzou))
        XCTAssertTrue(FileNaming.looksLikeDerived("download", url: lanzou))
        // 真实名字（如 Content-Disposition 提供）→ 不覆盖
        XCTAssertFalse(FileNaming.looksLikeDerived("安装器.pkg", url: lanzou))
        XCTAssertFalse(FileNaming.looksLikeDerived("installer.pkg", url: lanzou))
    }

    func testSanitize() {
        XCTAssertEqual(FileNaming.sanitize("a/b\\c:d"), "a_b_c_d")
        XCTAssertEqual(FileNaming.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FileNaming.sanitize("   "), "download")
        XCTAssertEqual(FileNaming.sanitize("正常文件.zip"), "正常文件.zip")
    }

    func testUniquePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let p1 = FileNaming.uniquePath(directory: dir.path, filename: "a.txt")
        XCTAssertEqual(p1, dir.appendingPathComponent("a.txt").path)
        FileManager.default.createFile(atPath: p1, contents: Data())
        let p2 = FileNaming.uniquePath(directory: dir.path, filename: "a.txt")
        XCTAssertEqual(p2, dir.appendingPathComponent("a (1).txt").path)
        FileManager.default.createFile(atPath: p2, contents: Data())
        let p3 = FileNaming.uniquePath(directory: dir.path, filename: "a.txt")
        XCTAssertEqual(p3, dir.appendingPathComponent("a (2).txt").path)
    }

    func testSplit() {
        let segs = DownloadTask.split(totalSize: 10, count: 4)
        XCTAssertEqual(segs.count, 4)
        XCTAssertEqual(segs[0].start, 0)
        XCTAssertEqual(segs[0].end, 1)
        XCTAssertEqual(segs[3].end, 9)
        let total = segs.reduce(Int64(0)) { $0 + ($1.end - $1.start + 1) }
        XCTAssertEqual(total, 10)
    }

    func testSplitSmall() {
        let segs = DownloadTask.split(totalSize: 5, count: 8)
        XCTAssertEqual(segs.count, 5) // 不超过总大小
    }

    func testSegmentRemaining() {
        var seg = SegmentState(index: 0, start: 100, end: 199, downloaded: 30)
        XCTAssertEqual(seg.remaining, 70)
        XCTAssertEqual(seg.nextStart, 130)
        seg.downloaded = 100
        XCTAssertEqual(seg.remaining, 0)
    }
}
