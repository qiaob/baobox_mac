import Foundation
import XCTest

/// 展示用的 JSON 解析（docs/packet-capture/TOOLS.md §2）：键保持原文顺序、数字保留原文、解不开就 nil。
final class JSONNodeTests: XCTestCase {

    private func parse(_ text: String) -> JSONNode? { JSONNode.parse(Data(text.utf8)) }

    func testKeysKeepSourceOrderAndNumbersKeepSourceText() throws {
        let node = try XCTUnwrap(parse(#"{"z":1,"a":12345678901234567890,"m":0.1000,"e":-1.5E+3,"t":true,"n":null}"#))
        guard case .object(let members) = node else { return XCTFail("not an object") }
        XCTAssertEqual(members.map(\.key), ["z", "a", "m", "e", "t", "n"])
        XCTAssertEqual(members[1].value, .number("12345678901234567890"), "不丢精度")
        XCTAssertEqual(members[2].value, .number("0.1000"), "不改写法")
        XCTAssertEqual(members[3].value, .number("-1.5E+3"))
        XCTAssertEqual(members[4].value, .bool(true))
        XCTAssertEqual(members[5].value, .null)
    }

    func testStringsAndEscapes() throws {
        let node = try XCTUnwrap(parse(#"["a\"b\\c\/d\n\t", "\u4e2d\u6587", "\ud83d\ude00", "\ud800x", "直接中文"]"#))
        XCTAssertEqual(node, .array([.string("a\"b\\c/d\n\t"), .string("中文"), .string("😀"),
                                     .string("\u{FFFD}x"), .string("直接中文")]))
    }

    func testNestingAndWhitespace() throws {
        let node = try XCTUnwrap(parse(" \n{ \"a\" : [ 1 , { \"b\" : [] } , {} ] }\r\n"))
        XCTAssertEqual(node, .object([JSONMember(key: "a", value: .array([
            .number("1"), .object([JSONMember(key: "b", value: .array([]))]), .object([]),
        ]))]))
        // UTF-8 BOM 开头也认。
        XCTAssertEqual(JSONNode.parse(Data([0xEF, 0xBB, 0xBF]) + Data("[1]".utf8)), .array([.number("1")]))
    }

    func testInvalidJSONReturnsNil() {
        let bad = ["", "   ", "{", "[1,]", "{\"a\":1,}", "{'a':1}", "[01]", "[1.]", "[.5]", "[1e]", "[-]",
                   "tru", "nul", "[1] x", "{\"a\" 1}", "{1:2}", "\"no end", "[\"tab\there\"]", "[\"\\x\"]",
                   "[\"\\u12\"]", "NaN", "// comment\n{}"]
        for text in bad {
            XCTAssertNil(parse(text), text)
        }
    }

    func testTooLargeOrTooDeepIsNotATree() {
        let big = Data("\"".utf8) + Data(repeating: 0x61, count: JSONNode.maxTreeBytes) + Data("\"".utf8)
        XCTAssertNil(JSONNode.parse(big), "超过 2 MB 不建树")
        let deep = String(repeating: "[", count: JSONNode.maxDepth + 1) + String(repeating: "]", count: JSONNode.maxDepth + 1)
        XCTAssertNil(parse(deep))
        let ok = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        XCTAssertNotNil(parse(ok))
    }

    func testPrettyTextKeepsOrderAndRoundTrips() throws {
        let source = #"{"z":{"y":[1,2.50,"s\"q"],"empty":{},"list":[]},"a":false,"n":null,"c":"中\n文"}"#
        let node = try XCTUnwrap(parse(source))
        let pretty = node.prettyText()
        XCTAssertEqual(pretty, """
        {
          "z": {
            "y": [
              1,
              2.50,
              "s\\"q"
            ],
            "empty": {},
            "list": []
          },
          "a": false,
          "n": null,
          "c": "中\\n文"
        }
        """)
        // 文本再解一遍得到同一棵树（树和文本对得上）。
        XCTAssertEqual(parse(pretty), node)
        XCTAssertEqual(JSONNode.quoted("a\u{01}b"), "\"a\\u0001b\"")
    }

    func testChildrenAreCappedPerLevel() throws {
        let items = (0..<250).map(String.init).joined(separator: ",")
        let node = try XCTUnwrap(parse("[\(items)]"))
        let children = node.children()
        XCTAssertEqual(children.items.count, JSONNode.childLimit)
        XCTAssertEqual(children.remaining, 50)
        XCTAssertEqual(children.items.first, JSONChild(label: "0", node: .number("0")))
        XCTAssertEqual(children.items.last?.label, "199")

        let object = try XCTUnwrap(parse(#"{"b":1,"a":2}"#))
        XCTAssertEqual(object.children(limit: 1).items, [JSONChild(label: "b", node: .number("1"))])
        XCTAssertEqual(object.children(limit: 1).remaining, 1)
        XCTAssertEqual(JSONNode.string("x").children().items, [])
    }

    func testSummaryAndScalarText() throws {
        XCTAssertEqual(try XCTUnwrap(parse(#"{"a":1,"b":2}"#)).summary, "{2}")
        XCTAssertEqual(try XCTUnwrap(parse("[1,2,3]")).summary, "[3]")
        XCTAssertEqual(JSONNode.string("hi \"you\"").scalarText, #""hi \"you\"""#)
        XCTAssertEqual(JSONNode.number("1e3").scalarText, "1e3")
        XCTAssertEqual(JSONNode.null.scalarText, "null")
        XCTAssertTrue(JSONNode.array([]).isContainer)
        XCTAssertFalse(JSONNode.bool(false).isContainer)
    }

    func testLooksLikeJSON() {
        XCTAssertTrue(JSONNode.looksLikeJSON(Data("x".utf8), contentType: "application/vnd.api+json"))
        XCTAssertTrue(JSONNode.looksLikeJSON(Data("  \n {\"a\":1}".utf8), contentType: "text/plain"))
        XCTAssertTrue(JSONNode.looksLikeJSON(Data("[1]".utf8), contentType: nil))
        XCTAssertFalse(JSONNode.looksLikeJSON(Data("<html>".utf8), contentType: "text/html"))
        XCTAssertFalse(JSONNode.looksLikeJSON(Data(), contentType: nil))
    }
}
