import Foundation
import XCTest

/// 列表筛选（docs/packet-capture/TOOLS.md §1）：两个过滤输入框共用的分词与匹配、隐藏名单、「隐藏未解密」、
/// 和左栏数字的口径。
final class FlowFilterTests: XCTestCase {

    private struct Row: FilterableFlow, Equatable {
        var host: String
        var url: String
        var method = "GET"
        var statusClass = 2
        var decrypted = true
        var deviceKey = "127.0.0.1"

        init(_ host: String, _ path: String = "/", method: String = "GET", status: Int = 2,
             decrypted: Bool = true, device: String = "127.0.0.1") {
            self.host = host
            self.url = "https://\(host)\(path)"
            self.method = method
            self.statusClass = status
            self.decrypted = decrypted
            self.deviceKey = device
        }
    }

    private let rows = [
        Row("api.example.com", "/v1/user?id=1"),
        Row("static.example.com", "/app.js"),
        Row("cdn.other.net", "/logo.png", status: 3),
        Row("www.google.com", "/gen_204", method: "POST"),
        Row("gsp-ssl.apple.com", "", method: "CONNECT", status: 0, decrypted: false),
        Row("api.example.com", "/api/log", method: "POST", status: 5, device: "192.168.0.9"),
    ]

    // MARK: - TermFilter：两个输入框共用的语法

    func testTermSplittingAndCase() {
        let filter = TermFilter(text: "  API,cdn，Static\t\n ")
        XCTAssertEqual(filter.include, ["api", "cdn", "static"], "空格、英文逗号、中文逗号都是分隔；转小写")
        XCTAssertEqual(filter.exclude, [])
        XCTAssertEqual(filter.text, "  API,cdn，Static\t\n ", "原文原样留着给输入框")
    }

    func testEmptyTextAndLoneDashFilterNothing() {
        for text in ["", "   ", ",，", "-", "- - ,-"] {
            let filter = TermFilter(text: text)
            XCTAssertTrue(filter.isEmpty, text)
            XCTAssertTrue(filter.matches("anything.com"), text)
        }
    }

    func testIncludeTermsAreOred() {
        let filter = TermFilter(text: "api cdn")
        XCTAssertTrue(filter.matches("api.example.com"))
        XCTAssertTrue(filter.matches("cdn.other.net"))
        XCTAssertFalse(filter.matches("www.google.com"))
        XCTAssertTrue(TermFilter(text: "EXAMPLE.com").matches("api.Example.COM"), "不分大小写")
    }

    func testExcludeOnlyKeepsEverythingElse() {
        let filter = TermFilter(text: "-google -apple")
        XCTAssertEqual(filter.include, [])
        XCTAssertEqual(filter.exclude, ["google", "apple"])
        XCTAssertFalse(filter.matches("www.google.com"))
        XCTAssertFalse(filter.matches("gsp-ssl.apple.com"))
        XCTAssertTrue(filter.matches("api.example.com"))
    }

    func testExcludeWinsOverInclude() {
        let filter = TermFilter(text: "example -static")
        XCTAssertTrue(filter.matches("api.example.com"))
        XCTAssertFalse(filter.matches("static.example.com"))
        XCTAssertFalse(filter.matches("cdn.other.net"))
    }

    /// 「过滤 URL」用的是同一个类型，被匹配的是完整 URL。
    func testURLScenarios() {
        let api = TermFilter(text: "/api/ -/api/log")
        XCTAssertTrue(api.matches("https://x.com/api/user"))
        XCTAssertFalse(api.matches("https://x.com/api/log?level=1"))
        XCTAssertFalse(api.matches("https://x.com/home"))

        let images = TermFilter(text: ".png .jpg")
        XCTAssertTrue(images.matches("https://cdn.x.com/a.PNG"))
        XCTAssertTrue(images.matches("https://cdn.x.com/b.jpg?w=10"))
        XCTAssertFalse(images.matches("https://cdn.x.com/c.gif"))

        let noAssets = TermFilter(text: "-.js -.css")
        XCTAssertFalse(noAssets.matches("https://x.com/app.js"))
        XCTAssertFalse(noAssets.matches("https://x.com/site.css"))
        XCTAssertTrue(noAssets.matches("https://x.com/api/v1"))
    }

    // MARK: - FlowFilter

    func testHostFilterMatchesHostOnlyAndURLFilterMatchesWholeURL() {
        var filter = FlowFilter()
        filter.hostTerms = TermFilter(text: "v1")   // 「v1」只出现在路径里：域名过滤不该命中
        XCTAssertEqual(filter.visible(rows), [])
        filter.hostTerms = TermFilter()
        filter.urlTerms = TermFilter(text: "v1")
        XCTAssertEqual(filter.visible(rows).map(\.url), ["https://api.example.com/v1/user?id=1"])
    }

    func testHiddenHostsAndHideUndecrypted() {
        var filter = FlowFilter()
        filter.hiddenHosts = ["www.google.com"]
        XCTAssertFalse(filter.visible(rows).contains { $0.host == "www.google.com" })
        XCTAssertTrue(filter.visible(rows).contains { !$0.decrypted })
        filter.hideUndecrypted = true
        XCTAssertFalse(filter.visible(rows).contains { !$0.decrypted })
        XCTAssertEqual(filter.visible(rows).count, 4)
        // 隐藏名单是精确域名，不是包含。
        filter.hiddenHosts = ["example.com"]
        XCTAssertEqual(filter.visible(rows).filter { $0.host.hasSuffix("example.com") }.count, 3)
    }

    func testConditionsAreAnded() {
        var filter = FlowFilter()
        filter.device = "127.0.0.1"
        filter.methods = ["GET"]
        filter.hostTerms = TermFilter(text: "example")
        filter.urlTerms = TermFilter(text: "-.js")
        XCTAssertEqual(filter.visible(rows).map(\.url), ["https://api.example.com/v1/user?id=1"])
        filter.statusClasses = [5]
        XCTAssertEqual(filter.visible(rows), [])
        filter.device = nil
        filter.methods = []
        XCTAssertEqual(filter.visible(rows).map(\.url), ["https://api.example.com/api/log"])
        filter.host = "static.example.com"
        XCTAssertEqual(filter.visible(rows), [])
    }

    /// 过滤只决定显示哪些行：同一批数据换不同的过滤文字得到不同子集，清空得到全集，源数组始终不变。
    func testFilteringNeverChangesTheData() {
        let source = rows
        var filter = FlowFilter()
        XCTAssertEqual(filter.visible(source), source)

        filter.hostTerms = TermFilter(text: "example")
        let byHost = filter.visible(source)
        XCTAssertEqual(byHost.count, 3)

        filter.hostTerms = TermFilter(text: "-example")
        let excluded = filter.visible(source)
        XCTAssertEqual(excluded.count, 3)
        XCTAssertTrue(Set(byHost.map(\.url)).isDisjoint(with: excluded.map(\.url)))

        filter.urlTerms = TermFilter(text: ".png")
        XCTAssertEqual(filter.visible(source).map(\.host), ["cdn.other.net"])

        // 过滤期间「新来」的行：命中的出现，不命中的不显示，但都在源数据里。
        let grown = source + [Row("img.other.net", "/b.png"), Row("api.example.com", "/c.png")]
        XCTAssertEqual(filter.visible(grown).map(\.host), ["cdn.other.net", "img.other.net"])

        filter.hostTerms = TermFilter()
        filter.urlTerms = TermFilter()
        XCTAssertEqual(filter.visible(grown), grown, "清空后之前被滤掉的（含过滤期间新来的）全部回来")
        XCTAssertEqual(source, rows, "源数组不变")
    }

    func testSelectedHostIsHidden() {
        var filter = FlowFilter()
        XCTAssertFalse(filter.selectedHostIsHidden)
        filter.host = "static.example.com"
        XCTAssertFalse(filter.selectedHostIsHidden)
        filter.hostTerms = TermFilter(text: "-static")
        XCTAssertTrue(filter.selectedHostIsHidden)
        filter.hostTerms = TermFilter(text: "api")
        XCTAssertTrue(filter.selectedHostIsHidden)
        filter.hostTerms = TermFilter(text: "example")
        XCTAssertFalse(filter.selectedHostIsHidden)
        filter.hiddenHosts = ["static.example.com"]
        XCTAssertTrue(filter.selectedHostIsHidden)
        // 「过滤 URL」不影响左栏选中的域名。
        filter.hiddenHosts = []
        filter.urlTerms = TermFilter(text: "nothing-matches-this")
        XCTAssertFalse(filter.selectedHostIsHidden)
    }

    func testHiddenCountOnlyCountsWhatTheFiltersHid() {
        var filter = FlowFilter()
        XCTAssertEqual(filter.hiddenCount(rows), 0)
        filter.hostTerms = TermFilter(text: "nomatch")
        XCTAssertEqual(filter.hiddenCount(rows), rows.count)
        filter.hostTerms = TermFilter()
        filter.urlTerms = TermFilter(text: "nomatch")
        XCTAssertEqual(filter.hiddenCount(rows), rows.count)
        // 方法筛掉的不算「被过滤条件藏起来」。
        filter.methods = ["POST"]
        XCTAssertEqual(filter.hiddenCount(rows), 2)
        // 调用方另加的条件（全文搜索）没过的也不算。
        XCTAssertEqual(filter.hiddenCount(rows) { $0.host.contains("google") }, 1)
        filter.urlTerms = TermFilter()
        filter.methods = []
        filter.hiddenHosts = ["www.google.com"]
        filter.hideUndecrypted = true
        XCTAssertEqual(filter.hiddenCount(rows), 2)
    }

    // MARK: - 左栏数字

    func testSidebarCounts() {
        var filter = FlowFilter()
        var counts = SidebarCounts.compute(rows, filter: filter)
        XCTAssertEqual(counts.total, 6)
        XCTAssertEqual(counts.byDevice, ["127.0.0.1": 5, "192.168.0.9": 1])
        XCTAssertEqual(counts.hosts.first, SidebarCounts.HostCount(host: "api.example.com", count: 2))
        XCTAssertEqual(counts.hosts.count, 5)
        // 同数按名字排。
        XCTAssertEqual(counts.hosts.dropFirst().map(\.host),
                       ["cdn.other.net", "gsp-ssl.apple.com", "static.example.com", "www.google.com"])

        // 藏噪音的三样都从数字里扣掉。
        filter.hiddenHosts = ["www.google.com"]
        filter.hideUndecrypted = true
        filter.hostTerms = TermFilter(text: "-static")
        counts = SidebarCounts.compute(rows, filter: filter)
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.hosts.map(\.host), ["api.example.com", "cdn.other.net"])

        // 选了来源：域名列表只数这个来源的；「全部」和各来源的数字不变。
        filter.device = "192.168.0.9"
        counts = SidebarCounts.compute(rows, filter: filter)
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts.hosts, [SidebarCounts.HostCount(host: "api.example.com", count: 1)])
    }

    /// 左栏的数字不随「过滤 URL」、选中的域名、方法、状态码变。
    func testSidebarCountsIgnoreURLFilterAndSelections() {
        var filter = FlowFilter()
        let before = SidebarCounts.compute(rows, filter: filter)
        filter.urlTerms = TermFilter(text: ".png")
        filter.host = "api.example.com"
        filter.methods = ["DELETE"]
        filter.statusClasses = [4]
        XCTAssertEqual(SidebarCounts.compute(rows, filter: filter), before)
    }
}
