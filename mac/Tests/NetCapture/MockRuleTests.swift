import Foundation
import XCTest

/// Mock 规则（docs/packet-capture/TOOLS.md §4）：从一条请求预填、保存前整理、存盘格式与容错。
final class MockRuleTests: XCTestCase {

    func testDraftFromACapturedRequest() {
        let rule = MockRule.draft(
            method: "get", host: "API.x.com", path: "/v1/user/42?expand=1&x=2",
            status: 201,
            headers: [HTTPHeader(name: "Content-Type", value: "application/json"),
                      HTTPHeader(name: "Content-Length", value: "99"),
                      HTTPHeader(name: "content-encoding", value: "gzip"),
                      HTTPHeader(name: "Transfer-Encoding", value: "chunked"),
                      HTTPHeader(name: "x-trace", value: "abc")],
            body: Data(#"{"id":42}"#.utf8))
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.method, "GET")
        XCTAssertEqual(rule.host, "api.x.com")
        XCTAssertEqual(rule.path, "/v1/user/42", "去掉 ? 之后")
        XCTAssertEqual(rule.status, 201)
        XCTAssertEqual(rule.headers, [HTTPHeader(name: "Content-Type", value: "application/json"),
                                      HTTPHeader(name: "x-trace", value: "abc")],
                       "长度、压缩、分块三个头去掉（正文已解压，引擎会重算）")
        XCTAssertEqual(rule.body, Data(#"{"id":42}"#.utf8))
        XCTAssertFalse(rule.id.isEmpty)
    }

    func testDraftWithoutAResponseYet() {
        let rule = MockRule.draft(method: "POST", host: "x.com", path: "/", status: nil, headers: [], body: nil)
        XCTAssertEqual(rule.status, 200)
        XCTAssertEqual(rule.headers, [])
        XCTAssertEqual(rule.body, Data())
    }

    func testNormalizedAndValid() {
        let rule = MockRule(method: " post ", host: "  Api.X.com ", path: " v1/items?page=2 ", status: 404).normalized()
        XCTAssertEqual(rule.method, "POST")
        XCTAssertEqual(rule.host, "api.x.com")
        XCTAssertEqual(rule.path, "/v1/items")
        XCTAssertEqual(MockRule(method: "  ").normalized().method, MockRule.anyMethod, "方法空着 = 任意")
        XCTAssertEqual(MockRule(path: "").normalized().path, "/")
        XCTAssertEqual(MockRule(path: "*/login").normalized().path, "*/login", "以 * 开头的通配不补 /")

        XCTAssertTrue(MockRule(host: "x.com", status: 200).isValid)
        XCTAssertFalse(MockRule(host: "  ", status: 200).isValid, "没有域名")
        XCTAssertFalse(MockRule(host: "x.com", status: 99).isValid)
        XCTAssertFalse(MockRule(host: "x.com", status: 600).isValid)
        XCTAssertTrue(MockRule(host: "x.com", status: 599).isValid)
    }

    func testFileRoundTrip() throws {
        let rules = [
            MockRule(id: "a", enabled: false, method: "*", host: "x.com", path: "/v1/*", status: 418,
                     headers: [HTTPHeader(name: "x-a", value: "1"), HTTPHeader(name: "x-a", value: "2")],
                     body: Data([0x00, 0xFF, 0x10])),
            MockRule(id: "b", host: "y.org"),
        ]
        let data = try XCTUnwrap(MockRuleFile.encode(rules))
        XCTAssertEqual(MockRuleFile.decode(data), rules)
        // 正文在文件里是 base64，头是 [[名, 值]]（和发给引擎的同一个形状）。
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json[0]["body"] as? String, "AP8Q")
        XCTAssertEqual(json[0]["headers"] as? [[String]], [["x-a", "1"], ["x-a", "2"]])
        XCTAssertEqual(MockRuleFile.decode(try XCTUnwrap(MockRuleFile.encode([]))), [])
    }

    /// 文件不是数组 = 坏文件（nil，调用方改名留着）；数组里坏掉的项跳过、缺的字段用默认值。
    func testFileTolerance() throws {
        XCTAssertNil(MockRuleFile.decode(Data("not json".utf8)))
        XCTAssertNil(MockRuleFile.decode(Data(#"{"id":"a","host":"x.com"}"#.utf8)))
        XCTAssertNil(MockRuleFile.decode(Data()))

        let mixed = Data("""
        [
          {"id":"ok","host":"x.com","path":"/a","status":201,"enabled":true,"method":"GET","headers":[["k","v"]],"body":"aGk="},
          {"id":"no-host","path":"/b"},
          "junk",
          42,
          {"host":"y.com"},
          {"id":"odd","host":"z.com","status":"200","enabled":"yes","headers":[["only-name"],["a","b"]],"body":"%%%"}
        ]
        """.utf8)
        let rules = try XCTUnwrap(MockRuleFile.decode(mixed))
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[0], MockRule(id: "ok", enabled: true, method: "GET", host: "x.com", path: "/a", status: 201,
                                          headers: [HTTPHeader(name: "k", value: "v")], body: Data("hi".utf8)))
        // 只有 host：其余都是默认值，id 现生成。
        XCTAssertEqual(rules[1].host, "y.com")
        XCTAssertEqual(rules[1].method, MockRule.anyMethod)
        XCTAssertEqual(rules[1].path, "/")
        XCTAssertEqual(rules[1].status, 200)
        XCTAssertTrue(rules[1].enabled)
        XCTAssertFalse(rules[1].id.isEmpty)
        // 类型不对的字段按默认值，形状不对的头跳过。
        XCTAssertEqual(rules[2].id, "odd")
        XCTAssertEqual(rules[2].status, 200)
        XCTAssertTrue(rules[2].enabled)
        XCTAssertEqual(rules[2].headers, [HTTPHeader(name: "a", value: "b")])
        XCTAssertEqual(rules[2].body, Data())
    }
}
