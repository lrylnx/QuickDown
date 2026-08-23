import XCTest
import CommonCrypto
@testable import QuickDownCore

final class HLSParserTests: XCTestCase {

    func testMasterPlaylistDetection() {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1280x720
        v7/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2560000
        v9/prog_index.m3u8
        """
        let base = URL(string: "https://example.com/master.m3u8")!
        let p = HLSParser.parse(text, baseURL: base)
        XCTAssertTrue(p.isMaster)
        XCTAssertEqual(p.variants.count, 2)
        XCTAssertEqual(p.variants[0].uri, "https://example.com/v7/prog_index.m3u8")
        XCTAssertEqual(p.variants[0].bandwidth, 1280000)
        XCTAssertEqual(p.variants[1].bandwidth, 2560000)
    }

    func testMediaPlaylistBasic() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-MEDIA-SEQUENCE:10
        #EXTINF:6.00000,
        seg0.ts
        #EXTINF:5.50000,
        https://cdn.example.com/seg1.ts
        #EXT-X-ENDLIST
        """
        let base = URL(string: "https://example.com/playlist.m3u8")!
        let p = HLSParser.parse(text, baseURL: base)
        XCTAssertFalse(p.isMaster)
        XCTAssertEqual(p.segments.count, 2)
        XCTAssertEqual(p.mediaSequence, 10)
        XCTAssertEqual(p.segments[0].uri, "https://example.com/seg0.ts")
        XCTAssertEqual(p.segments[0].duration, 6.0, accuracy: 0.001)
        XCTAssertEqual(p.segments[1].uri, "https://cdn.example.com/seg1.ts")
    }

    func testAES128KeyParsing() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="https://key.example/key.key",IV=0x1234567890abcdef1234567890abcdef
        #EXTINF:6,
        seg.ts
        """
        let base = URL(string: "https://example.com/p.m3u8")!
        let p = HLSParser.parse(text, baseURL: base)
        XCTAssertEqual(p.segments[0].keyURI, "https://key.example/key.key")
        XCTAssertEqual(p.segments[0].keyIVHex, "0x1234567890abcdef1234567890abcdef")
    }

    func testKeyResetToNone() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key1.key"
        #EXTINF:6,
        a.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:6,
        b.ts
        """
        let base = URL(string: "https://e.com/p.m3u8")!
        let p = HLSParser.parse(text, baseURL: base)
        XCTAssertNotNil(p.segments[0].keyURI)
        XCTAssertNil(p.segments[1].keyURI)
    }

    func testByteRange() {
        let text = """
        #EXTM3U
        #EXT-X-BYTERANGE:76242@0
        #EXTINF:6,
        main.ts
        #EXT-X-BYTERANGE:76242
        #EXTINF:6,
        main.ts
        """
        let base = URL(string: "https://e.com/p.m3u8")!
        let p = HLSParser.parse(text, baseURL: base)
        XCTAssertEqual(p.segments[0].byteRangeStart, 0)
        XCTAssertEqual(p.segments[0].byteRangeLength, 76242)
        XCTAssertEqual(p.segments[1].byteRangeStart, 0) // 无 @ 时从头
        XCTAssertEqual(p.segments[1].byteRangeLength, 76242)
    }

    func testFragmentedMP4Detection() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
        #EXTINF:6,
        seg1.m4s
        #EXTINF:6,
        seg2.m4s
        """
        let base = URL(string: "https://e.com/p.m3u8")!
        let p = HLSParser.parse(text, baseURL: base)
        XCTAssertTrue(p.isFragmentedMP4)
        XCTAssertEqual(p.initURI, "https://e.com/init.mp4")
        XCTAssertEqual(p.initByteRange?.0, 0)
        XCTAssertEqual(p.initByteRange?.1, 720)
    }

    func testIVHexParsing() {
        let iv = HLSCrypto.iv(fromHex: "0x00112233445566778899aabbccddeeff")
        XCTAssertEqual(iv?.count, 16)
        XCTAssertEqual(iv?[0], 0x00)
        XCTAssertEqual(iv?[15], 0xFF)
    }

    func testDefaultIV() {
        let iv = HLSCrypto.defaultIV(sequence: 258)
        XCTAssertEqual(iv.count, 16)
        // 大端 0x102 = 00000000 00000102
        XCTAssertEqual(iv[14], 0x01)
        XCTAssertEqual(iv[15], 0x02)
    }

    func testAESDecryptRoundTrip() {
        let key = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
        let iv = Data(repeating: 0x10, count: 16)
        let plain = Data("Hello HLS AES-128 encryption test!".utf8)

        // 用 CommonCrypto 加密（与 openssl 默认 PKCS7 一致）
        let encLen = plain.count + kCCBlockSizeAES128
        var enc = Data(count: encLen)
        var num = 0
        let status: CCCryptorStatus = enc.withUnsafeMutableBytes { outPtr in
            plain.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, plain.count, outPtr.baseAddress, encLen, &num)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        enc = enc.prefix(num)

        let decrypted = HLSCrypto.aesCBCDecrypt(data: enc, key: key, iv: iv)
        XCTAssertEqual(decrypted, plain)
    }
}
