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
