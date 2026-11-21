import Foundation
import XCTest

/// 请求参数分栏（docs/packet-capture/TOOLS.md §2）：Query、Cookie、Set-Cookie、表单正文，和请求头文本的互转。
final class RequestParamsTests: XCTestCase {

    private func nv(_ name: String, _ value: String) -> NameValue { NameValue(name: name, value: value) }

    // MARK: - Query

    func testQueryItemsDecodeAndKeepOrder() {
        XCTAssertEqual(RequestParams.queryItems(path: "/v1/search?q=%E4%B8%AD%E6%96%87+test&page=2&q=again&flag&=empty&&x=a%3Db"),
                       [nv("q", "中文 test"), nv("page", "2"), nv("q", "again"), nv("flag", ""), nv("", "empty"),
                        nv("x", "a=b")])
    }

    func testQueryItemsEdgeCases() {
        XCTAssertEqual(RequestParams.queryItems(path: "/plain"), [])
        XCTAssertEqual(RequestParams.queryItems(path: "/empty?"), [])
        XCTAssertEqual(RequestParams.queryItems(path: ""), [])
        // 只拆第一个 ? 之后；值里再出现 ? 原样保留；# 之后不算。
        XCTAssertEqual(RequestParams.queryItems(path: "/a?u=http://x.com/?y=1#frag"), [nv("u", "http://x.com/?y=1")])
        // 解码失败（坏的百分号）显示原文。
        XCTAssertEqual(RequestParams.queryItems(path: "/a?bad=%zz&half=%E4%B8"), [nv("bad", "%zz"), nv("half", "%E4%B8")])
    }

    // MARK: - Cookie

    func testCookieHeader() {
        XCTAssertEqual(RequestParams.cookies(header: "sid=abc123; theme=dark;  empty=;flag ; token=a=b=c"),
                       [nv("sid", "abc123"), nv("theme", "dark"), nv("empty", ""), nv("flag", ""), nv("token", "a=b=c")])
        XCTAssertEqual(RequestParams.cookies(header: ""), [])
        XCTAssertEqual(RequestParams.cookies(header: " ; ;"), [])
        // 不解码：Cookie 的值没有统一编码，原样给。
        XCTAssertEqual(RequestParams.cookies(header: "q=%20x"), [nv("q", "%20x")])
    }

    /// HTTP/2 会把 Cookie 拆成好几个头：合起来拆，大小写不论。
    func testCookieHeadersAcrossSeveralFields() {
        let headers = [HTTPHeader(name: "cookie", value: "a=1; b=2"),
                       HTTPHeader(name: "user-agent", value: "x"),
                       HTTPHeader(name: "Cookie", value: "c=3")]
        XCTAssertEqual(RequestParams.cookies(headers: headers), [nv("a", "1"), nv("b", "2"), nv("c", "3")])
        XCTAssertEqual(RequestParams.cookies(headers: []), [])
    }

    func testSetCookies() {
        let headers = [HTTPHeader(name: "Set-Cookie", value: "sid=abc; Path=/; HttpOnly; Secure"),
                       HTTPHeader(name: "content-type", value: "text/html"),
                       HTTPHeader(name: "set-cookie", value: "theme=dark"),
                       HTTPHeader(name: "set-cookie", value: "  "),
                       HTTPHeader(name: "set-cookie", value: "odd; Max-Age=0")]
        XCTAssertEqual(RequestParams.setCookies(headers: headers), [
            SetCookie(name: "sid", value: "abc", attributes: "Path=/; HttpOnly; Secure"),
            SetCookie(name: "theme", value: "dark", attributes: ""),
            SetCookie(name: "odd", value: "", attributes: "Max-Age=0"),
        ])
        XCTAssertEqual(RequestParams.copyText(RequestParams.setCookies(headers: headers)),
                       "sid=abc; Path=/; HttpOnly; Secure\ntheme=dark\nodd=; Max-Age=0")
    }

    // MARK: - 表单

    func testFormItems() {
        let body = Data("user=a%40x.com&note=hello+world&tags=1&tags=2".utf8)
        XCTAssertEqual(RequestParams.formItems(body: body, contentType: "application/x-www-form-urlencoded; charset=UTF-8"),
                       [nv("user", "a@x.com"), nv("note", "hello world"), nv("tags", "1"), nv("tags", "2")])
        XCTAssertEqual(RequestParams.formItems(body: body, contentType: "Application/X-WWW-Form-Urlencoded"),
                       [nv("user", "a@x.com"), nv("note", "hello world"), nv("tags", "1"), nv("tags", "2")])
        // 不是表单：nil（界面按 JSON / 文本显示）。
        XCTAssertNil(RequestParams.formItems(body: body, contentType: "application/json"))
        XCTAssertNil(RequestParams.formItems(body: body, contentType: nil))
        // 是表单但没正文：空表；不是 UTF-8：nil。
        XCTAssertEqual(RequestParams.formItems(body: nil, contentType: "application/x-www-form-urlencoded"), [])
        XCTAssertNil(RequestParams.formItems(body: Data([0xFF, 0xFE, 0x00]), contentType: "application/x-www-form-urlencoded"))
    }

    func testCopyText() {
        XCTAssertEqual(RequestParams.copyText([nv("a", "1"), nv("b", "x: y")]), "a: 1\nb: x: y")
        XCTAssertEqual(RequestParams.copyText([NameValue]()), "")
    }

    // MARK: - 请求头文本

    func testHeaderTextRoundTripDropsWireHeaders() {
        let headers = [HTTPHeader(name: "Content-Type", value: "application/json"),
                       HTTPHeader(name: "content-length", value: "42"),
                       HTTPHeader(name: "Content-Encoding", value: "gzip"),
                       HTTPHeader(name: "transfer-encoding", value: "chunked"),
                       HTTPHeader(name: "x-a", value: "1"),
                       HTTPHeader(name: "x-a", value: "2")]
        let text = HeaderText.text(headers)
        XCTAssertEqual(text, "Content-Type: application/json\nx-a: 1\nx-a: 2")
        XCTAssertEqual(HeaderText.headers(text), [HTTPHeader(name: "Content-Type", value: "application/json"),
                                                  HTTPHeader(name: "x-a", value: "1"),
                                                  HTTPHeader(name: "x-a", value: "2")])
        XCTAssertEqual(HeaderText.text(headers, omittingWireHeaders: false).split(separator: "\n").count, 6)
    }

    /// 文本框只放真正的文本：Protobuf / gRPC 常常碰巧是合法 UTF-8，带控制字符的一律当二进制。
    func testBodyText() {
        XCTAssertEqual(BodyText.text(Data("{\"a\":1}\n\tline\r\n".utf8)), "{\"a\":1}\n\tline\r\n")
        XCTAssertEqual(BodyText.text(Data("中文 ✓".utf8)), "中文 ✓")
        XCTAssertEqual(BodyText.text(Data()), "")
        XCTAssertNil(BodyText.text(Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x2A])), "gRPC 帧：合法 UTF-8，但不是文本")
        XCTAssertNil(BodyText.text(Data([0x08, 0x96, 0x01])), "不是 UTF-8")
        XCTAssertNil(BodyText.text(Data("a\u{1B}[0m".utf8)))
        XCTAssertNil(BodyText.text(Data("del\u{7F}".utf8)))
    }

    func testHeaderTextParsing() {
        let text = "  Authorization :  Bearer a:b:c  \r\n\n   \nno-colon-line\n: empty name\nx-empty:\r\nHost: api.x.com:8443"
        XCTAssertEqual(HeaderText.headers(text), [
            HTTPHeader(name: "Authorization", value: "Bearer a:b:c"),   // 按第一个冒号切，值里的冒号保留
            HTTPHeader(name: "x-empty", value: ""),
            HTTPHeader(name: "Host", value: "api.x.com:8443"),
        ])
        XCTAssertEqual(HeaderText.headers(""), [])
    }
}
