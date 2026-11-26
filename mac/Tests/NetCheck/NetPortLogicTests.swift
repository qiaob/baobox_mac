import Foundation
import XCTest

/// 本机端口占用的纯逻辑测试：lsof -F 解析、ps 命令行合并、过滤与端口查询识别。
final class NetPortLogicTests: XCTestCase {

    func testParseLsofFieldOutput() {
        let sample = """
        p1234
        cnode
        Lalice
        f20
        PTCP
        n127.0.0.1:3000
        f21
        PTCP
        n[::1]:3000
        f22
        PTCP
        n127.0.0.1:3000->127.0.0.1:54321
        p5678
        cPython
        Lalice
        f4
        PTCP
        n*:8080
        f5
        PTCP
        n*:8080
        p99
        cmDNSResponder
        L_mdnsresponder
        f8
        PUDP
        n*:5353
        f9
        PUDP
        n*:*
        """
        let entries = NetPortLogic.parseLsofFieldOutput(sample)
        // 已建立连接（->）和无端口（*:*）被跳过，重复项合并，按端口升序排
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].port, 3000)
        XCTAssertEqual(entries[0].address, "127.0.0.1")
        XCTAssertTrue(entries[0].isLocalOnly)
        XCTAssertEqual(entries[0].bindLabel, "127.0.0.1:3000")
        XCTAssertEqual(entries[0].processName, "node")
        XCTAssertEqual(entries[0].user, "alice")

        XCTAssertEqual(entries[1].port, 3000)
        XCTAssertEqual(entries[1].address, "::1")
        XCTAssertTrue(entries[1].isLocalOnly)
        XCTAssertEqual(entries[1].bindLabel, "[::1]:3000")

        XCTAssertEqual(entries[2].port, 5353)
        XCTAssertEqual(entries[2].proto, .udp)
        XCTAssertFalse(entries[2].isLocalOnly)

        XCTAssertEqual(entries[3].port, 8080)
        XCTAssertEqual(entries[3].address, "*")
        XCTAssertEqual(entries[3].bindLabel, "*:8080")
    }

    func testParsePSAndAttach() {
        let ps = """
          1234 /usr/local/bin/node /Users/alice/app/node_modules/.bin/vite --port 3000
          5678 python3 -m http.server 8080
        invalid line
        """
        let map = NetPortLogic.parsePSOutput(ps)
        XCTAssertEqual(map[1234], "/usr/local/bin/node /Users/alice/app/node_modules/.bin/vite --port 3000")
        XCTAssertEqual(map[5678], "python3 -m http.server 8080")
        XCTAssertEqual(map.count, 2)

        let raw = [
            NetPortEntry(pid: 1234, processName: "node", user: "alice", proto: .tcp, address: "127.0.0.1", port: 3000),
            NetPortEntry(pid: 9999, processName: "other", user: "alice", proto: .tcp, address: "*", port: 9000),
        ]
        let attached = NetPortLogic.attachCommandLines(raw, commands: map)
        XCTAssertEqual(attached[0].commandLine, "/usr/local/bin/node /Users/alice/app/node_modules/.bin/vite --port 3000")
        XCTAssertEqual(attached[1].commandLine, "")
    }

    func testFilterByPortProcessPIDAndCommand() {
        let entries = [
            NetPortEntry(pid: 1234, processName: "node", user: "alice", proto: .tcp, address: "127.0.0.1", port: 3000,
                         commandLine: "node vite --port 3000"),
            NetPortEntry(pid: 5678, processName: "postgres", user: "alice", proto: .tcp, address: "127.0.0.1", port: 5432,
                         commandLine: "/opt/homebrew/opt/postgresql/bin/postgres"),
            NetPortEntry(pid: 99, processName: "mDNSResponder", user: "root", proto: .udp, address: "*", port: 5353),
        ]
        XCTAssertEqual(NetPortLogic.filter(entries, query: ":3000").map(\.pid), [1234])
        XCTAssertEqual(NetPortLogic.filter(entries, query: "5432").map(\.pid), [5678])
        XCTAssertEqual(NetPortLogic.filter(entries, query: "vite").map(\.pid), [1234])
        XCTAssertEqual(NetPortLogic.filter(entries, query: "udp").map(\.pid), [99])
        XCTAssertEqual(NetPortLogic.filter(entries, query: "   ").count, 3)
    }

    func testExtractPortQuery() {
        XCTAssertEqual(NetPortLogic.extractPortQuery(":3000"), "3000")
        XCTAssertEqual(NetPortLogic.extractPortQuery(" :8080 "), "8080")
        XCTAssertEqual(NetPortLogic.extractPortQuery("port 5173"), "5173")
        XCTAssertEqual(NetPortLogic.extractPortQuery("PORT:6379"), "6379")
        XCTAssertEqual(NetPortLogic.extractPortQuery("端口 8000"), "8000")
        XCTAssertEqual(NetPortLogic.extractPortQuery("端口：9000"), "9000")
        // 超出端口范围或非端口查询
        XCTAssertNil(NetPortLogic.extractPortQuery(":0"))
        XCTAssertNil(NetPortLogic.extractPortQuery(":70000"))
        XCTAssertNil(NetPortLogic.extractPortQuery("3000"))
        XCTAssertNil(NetPortLogic.extractPortQuery("https://example.com:3000"))
    }
}
