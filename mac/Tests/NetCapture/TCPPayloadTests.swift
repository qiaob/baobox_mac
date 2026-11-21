import Foundation
import XCTest

/// 「TCP 包」的十六进制排版与文本判定（docs/packet-capture/CONTROL.md §4.2）。
final class TCPPayloadTests: XCTestCase {

    func testHexDumpFullAndPartialLines() {
        let data = Data("GET / HTTP/1.1\r\nHost".utf8)   // 20 字节
        let lines = TCPPayload.hexDump(data).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "00000000  47 45 54 20 2f 20 48 54  54 50 2f 31 2e 31 0d 0a  |GET / HTTP/1.1..|")
        XCTAssertEqual(lines[1], "00000010  48 6f 73 74                                       |Host|")
        // 最后一行的 ASCII 和满行对齐。
        XCTAssertEqual(lines[0].firstIndex(of: "|").map { lines[0].distance(from: lines[0].startIndex, to: $0) },
                       lines[1].firstIndex(of: "|").map { lines[1].distance(from: lines[1].startIndex, to: $0) })
    }

    /// 流视图里偏移按方向累计，不是每块从 0 开始。
    func testHexDumpStartOffset() {
        let line = TCPPayload.hexDump(Data([0x00, 0xFF, 0x41]), startOffset: 0x1F0)
        XCTAssertEqual(line, "000001f0  00 ff 41                                          |..A|")
        XCTAssertEqual(TCPPayload.hexDump(Data()), "")
        XCTAssertEqual(TCPPayload.offsetText(0x12345678), "12345678")
    }

    func testNineByteLineAlignment() {
        let lines = [TCPPayload.hexDump(Data(repeating: 0x41, count: 9)), TCPPayload.hexDump(Data(repeating: 0x41, count: 16))]
        XCTAssertEqual(lines[0].firstIndex(of: "|").map { lines[0].distance(from: lines[0].startIndex, to: $0) },
                       lines[1].firstIndex(of: "|").map { lines[1].distance(from: lines[1].startIndex, to: $0) })
    }

    func testLooksLikeText() {
        XCTAssertTrue(TCPPayload.looksLikeText(Data("220 smtp.example.com ESMTP\r\n".utf8)))
        XCTAssertTrue(TCPPayload.looksLikeText(Data("中文消息\n".utf8)))
        // 正好切在一个汉字中间也算文本。
        XCTAssertTrue(TCPPayload.looksLikeText(Data("中文".utf8).dropLast()))
        XCTAssertFalse(TCPPayload.looksLikeText(Data([0x16, 0x03, 0x01, 0x00, 0xA5, 0x01, 0x00])))
        XCTAssertFalse(TCPPayload.looksLikeText(Data([0xFF, 0xFE, 0x41])))
        XCTAssertFalse(TCPPayload.looksLikeText(Data()))
    }

    func testTextKeepsLineBreaksAndMarksControlBytes() {
        XCTAssertEqual(TCPPayload.text(Data("a\r\nb\tc\u{01}d\re".utf8)), "a\nb\tc·d\ne")
        // 解不开的字节（密文）也是点，不是替换符。
        XCTAssertEqual(TCPPayload.text(Data([0x53, 0x53, 0x48, 0xFF, 0xFE, 0x0A])), "SSH··\n")
    }
}
