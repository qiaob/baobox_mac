import Foundation
import XCTest

/// 测速与菜单栏实时网速的纯逻辑（docs/netcheck/SPEED.md §7）。
final class NetSpeedLogicTests: XCTestCase {

    private let k = 1024.0
    private var m: Double { k * k }
    private var g: Double { k * k * k }

    // MARK: - 菜单栏的写法

    func testCompactEachMagnitude() {
        XCTAssertEqual(NetSpeedFormat.compact(0), "0K")
        XCTAssertEqual(NetSpeedFormat.compact(1023), "0K")
        XCTAssertEqual(NetSpeedFormat.compact(k), "1K")
        XCTAssertEqual(NetSpeedFormat.compact(356 * k), "356K")
        XCTAssertEqual(NetSpeedFormat.compact(1.2 * m), "1.2M")
        XCTAssertEqual(NetSpeedFormat.compact(12 * m), "12M")
        XCTAssertEqual(NetSpeedFormat.compact(120 * m), "120M")
        XCTAssertEqual(NetSpeedFormat.compact(1.2 * g), "1.2G")
        XCTAssertEqual(NetSpeedFormat.compact(12 * g), "12G")
    }

    func testCompactBoundaries() {
        // 999 K 还是 K；显示出来到 1000 K 就进位成 1.0 M
        XCTAssertEqual(NetSpeedFormat.compact(999 * k), "999K")
        XCTAssertEqual(NetSpeedFormat.compact(999.4 * k), "999K")
        XCTAssertEqual(NetSpeedFormat.compact(999.5 * k), "1.0M")
        XCTAssertEqual(NetSpeedFormat.compact(1000 * k), "1.0M")
        XCTAssertEqual(NetSpeedFormat.compact(1023 * k), "1.0M")
        XCTAssertEqual(NetSpeedFormat.compact(m), "1.0M")
        // 9.9 M → 10 M
        XCTAssertEqual(NetSpeedFormat.compact(9.9 * m), "9.9M")
        XCTAssertEqual(NetSpeedFormat.compact(9.94 * m), "9.9M")
        XCTAssertEqual(NetSpeedFormat.compact(9.95 * m), "10M")
        XCTAssertEqual(NetSpeedFormat.compact(10 * m), "10M")
        // 1023 M → 1.0 G
        XCTAssertEqual(NetSpeedFormat.compact(999 * m), "999M")
        XCTAssertEqual(NetSpeedFormat.compact(999.5 * m), "1.0G")
        XCTAssertEqual(NetSpeedFormat.compact(1023 * m), "1.0G")
        XCTAssertEqual(NetSpeedFormat.compact(9.95 * g), "10G")
    }

    func testCompactBadInput() {
        XCTAssertEqual(NetSpeedFormat.compact(-5), "0K")
        XCTAssertEqual(NetSpeedFormat.compact(.nan), "0K")
        XCTAssertEqual(NetSpeedFormat.compact(.infinity), "0K")
    }

    func testMenuBarText() {
        XCTAssertEqual(NetSpeedFormat.menuBarText(down: 1.2 * m, up: 356 * k, mode: .down), "↓1.2M/s")
        XCTAssertEqual(NetSpeedFormat.menuBarText(down: 1.2 * m, up: 356 * k, mode: .both), "↓1.2M ↑356K")
        XCTAssertEqual(NetSpeedFormat.menuBarText(down: 0, up: 0, mode: .both), "↓0K ↑0K")
    }

    // MARK: - 定宽

    func testWidthCandidates() {
        XCTAssertEqual(NetSpeedFormat.widthCandidates(mode: .down),
                       ["↓888K/s", "↓8.8M/s", "↓888M/s", "↓8.8G/s", "↓888G/s"])
        let both = NetSpeedFormat.widthCandidates(mode: .both)
        XCTAssertEqual(both.count, 25)
        XCTAssertTrue(both.contains("↓888M ↑888G"))
        XCTAssertTrue(both.allSatisfy { $0.hasPrefix("↓") && $0.contains(" ↑") && !$0.hasSuffix("/s") })
    }

    /// 每种真实的写法都能在候选里找到一个同样形状（数字换成 8）的。
    func testEveryRealShapeIsACandidate() {
        let values: [Double] = [0, 500, k, 356 * k, 999 * k, 999.5 * k, 1.2 * m, 9.94 * m, 9.95 * m, 120 * m, 999 * m,
                                1023 * m, 1.2 * g, 12 * g, 999 * g]
        let digits = CharacterSet.decimalDigits
        func shape(_ text: String) -> String {
            String(text.unicodeScalars.map { digits.contains($0) ? "8" : Character($0) })
        }
        let downShapes = Set(NetSpeedFormat.widthCandidates(mode: .down))
        for value in values {
            let text = shape(NetSpeedFormat.menuBarText(down: value, up: 0, mode: .down))
            // 位数少的（356K、0K）比候选窄，不必一样；但单位和小数点的位置必须是候选里出现过的
            let padded = text.replacingOccurrences(of: "↓", with: "")
            XCTAssertTrue(downShapes.contains { $0.hasSuffix(padded) }, "\(text) 没有对应的候选")
        }
    }

    func testWidestTextPicksTheWidest() {
        // 假字体：数字 8、点 3、K 7、M 10、G 9、其余 5
        func width(_ text: String) -> Double {
            text.reduce(0) { sum, c in
                switch c {
                case "8": return sum + 8
                case ".": return sum + 3
                case "K": return sum + 7
                case "M": return sum + 10
                case "G": return sum + 9
                default: return sum + 5
                }
            }
        }
        XCTAssertEqual(NetSpeedFormat.widestText(mode: .down, width: width), "↓888M/s")
        XCTAssertEqual(NetSpeedFormat.widestText(mode: .both, width: width), "↓888M ↑888M")
        // 换一种字体：G 最宽
        XCTAssertEqual(NetSpeedFormat.widestText(mode: .down, width: { $0.contains("888G") ? 100 : 50 }), "↓888G/s")
        // 一样宽时取第一个
        XCTAssertEqual(NetSpeedFormat.widestText(mode: .down, width: { _ in 1 }), "↓888K/s")
    }

    // MARK: - 详情的写法

    func testRateAndAmount() {
        XCTAssertEqual(NetSpeedFormat.rate(1.2 * m), "1.2 MB/s")
        XCTAssertEqual(NetSpeedFormat.rate(356 * k), "356 KB/s")
        XCTAssertEqual(NetSpeedFormat.rate(10), "0 KB/s")
        XCTAssertEqual(NetSpeedFormat.amount(512), "512 B")
        XCTAssertEqual(NetSpeedFormat.amount(356 * k), "356 KB")
        XCTAssertEqual(NetSpeedFormat.amount(45.2 * m), "45.2 MB")
        XCTAssertEqual(NetSpeedFormat.amount(356 * m), "356 MB")
        XCTAssertEqual(NetSpeedFormat.amount(999.6 * m), "1.0 GB")
        XCTAssertEqual(NetSpeedFormat.amount(12.3 * g), "12.3 GB")
        XCTAssertEqual(NetSpeedFormat.amount(1.1 * g), "1.1 GB")
        XCTAssertEqual(NetSpeedFormat.amount(2 * g * k), "2.0 TB")
        XCTAssertEqual(NetSpeedFormat.amount(-1), "0 B")
    }

    func testMbpsAndMilliseconds() {
        // 93 Mbps = 11.625 MB/s（十进制）
        XCTAssertEqual(NetSpeedFormat.mbps(11_625_000), "93")
        XCTAssertEqual(NetSpeedFormat.mbps(1_162_500), "9.3")
        XCTAssertEqual(NetSpeedFormat.mbps(1_237_500), "9.9")
        XCTAssertEqual(NetSpeedFormat.mbps(1_250_000), "10")
        XCTAssertEqual(NetSpeedFormat.mbps(106_250), "0.85")
        XCTAssertEqual(NetSpeedFormat.mbps(0), "0.00")
        XCTAssertEqual(NetSpeedFormat.milliseconds(0.012), "12")
        XCTAssertEqual(NetSpeedFormat.milliseconds(0.0083), "8.3")
        XCTAssertEqual(NetSpeedFormat.milliseconds(0.00996), "10")
        XCTAssertEqual(NetSpeedFormat.milliseconds(.nan), "0.0")
    }

    // MARK: - 网卡筛选

    func testInterfaceFilter() {
        for name in ["en0", "en1", "en12", "pdp_ip0", "pdp_ip3"] {
            XCTAssertTrue(NetTrafficMath.counts(name: name, isUp: true), name)
            XCTAssertFalse(NetTrafficMath.counts(name: name, isUp: false), "\(name) 停用时不算")
        }
        for name in ["lo0", "utun0", "utun4", "ipsec0", "awdl0", "llw0", "bridge0", "ap1", "gif0", "stf0", "anpi0",
                     "vmnet1", "vmenet0", "en", "enx", "en0a", "pdp_ip", "", "EN0"] {
            XCTAssertFalse(NetTrafficMath.counts(name: name, isUp: true), name)
        }
    }

    // MARK: - 计数差值

    private func snapshot(_ time: TimeInterval, _ counters: [String: (UInt64, UInt64)], is32Bit: Bool = false) -> NetTrafficSnapshot {
        NetTrafficSnapshot(time: time, counters: counters.mapValues { NetTrafficCounter(received: $0.0, sent: $0.1) },
                           is32Bit: is32Bit)
    }

    func testRateBetweenReadings() {
        let a = snapshot(10, ["en0": (1_000, 500), "en1": (0, 0)])
        let b = snapshot(11, ["en0": (3_048, 1_524), "en1": (100, 0)])
        let rate = NetTrafficMath.rate(from: a, to: b)
        XCTAssertEqual(rate?.down, 2_148)
        XCTAssertEqual(rate?.up, 1_024)
        XCTAssertEqual(rate?.totalDown, 3_148)
        XCTAssertEqual(rate?.totalUp, 1_524)
        // 半秒的间隔按半秒算
        XCTAssertEqual(NetTrafficMath.rate(from: a, to: snapshot(10.5, ["en0": (2_000, 500)]))?.down, 2_000)
    }

    func testCounterGoesDown() {
        // 64 位计数变小 = 网卡重置：那一秒按 0
        let a = snapshot(0, ["en0": (5_000_000, 9_000)])
        let b = snapshot(1, ["en0": (1_000, 9_100)])
        XCTAssertEqual(NetTrafficMath.rate(from: a, to: b)?.down, 0)
        XCTAssertEqual(NetTrafficMath.rate(from: a, to: b)?.up, 100)
        XCTAssertEqual(NetTrafficMath.delta(from: 10, to: 3, is32Bit: false), 0)
    }

    func testThirtyTwoBitWrap() {
        let max32 = UInt64(UInt32.max)
        XCTAssertEqual(NetTrafficMath.delta(from: max32 - 99, to: 50, is32Bit: true), 150)
        XCTAssertEqual(NetTrafficMath.delta(from: max32, to: 0, is32Bit: true), 1)
        let a = snapshot(0, ["en0": (max32 - 999, 0)], is32Bit: true)
        let b = snapshot(1, ["en0": (1_000, 0)], is32Bit: true)
        XCTAssertEqual(NetTrafficMath.rate(from: a, to: b)?.down, 2_000)
        // 超出 32 位的数不是回绕（数据不对）：按 0
        XCTAssertEqual(NetTrafficMath.delta(from: max32 + 10, to: 5, is32Bit: true), 0)
    }

    func testGapTooLongOrBackwards() {
        let a = snapshot(100, ["en0": (0, 0)])
        XCTAssertNil(NetTrafficMath.rate(from: a, to: snapshot(103.5, ["en0": (9_999_999, 0)])), "刚从睡眠醒来那一次丢掉")
        XCTAssertNotNil(NetTrafficMath.rate(from: a, to: snapshot(103, ["en0": (1, 0)])))
        XCTAssertNil(NetTrafficMath.rate(from: a, to: snapshot(100, ["en0": (1, 0)])))
        XCTAssertNil(NetTrafficMath.rate(from: a, to: snapshot(99, ["en0": (1, 0)])))
    }

    func testInterfacesComingAndGoing() {
        // 新出现的网卡（刚插上的网线）这一秒不算，免得把它开机以来的累计当成这一秒的
        let a = snapshot(0, ["en0": (100, 100)])
        let b = snapshot(1, ["en0": (200, 100), "en5": (9_000_000, 9_000_000)])
        XCTAssertEqual(NetTrafficMath.rate(from: a, to: b)?.down, 100)
        // 消失的网卡不出负数
        let c = snapshot(2, [:])
        XCTAssertEqual(NetTrafficMath.rate(from: b, to: c)?.down, 0)
        XCTAssertEqual(NetTrafficMath.rate(from: b, to: c)?.totalDown, 0)
    }

    // MARK: - 测速窗口

    func testMeterDropsWarmup() {
        var meter = NetSpeedMeter(start: 0, cap: 1 << 40)
        // 起速段 1.5 秒里收了 10 MB（不计）
        var t = 0.0
        while t < 1.5 {
            t += 0.25
            meter.add(1_666_667)
            meter.tick(at: t)
        }
        let afterWarmup = meter.baseline
        XCTAssertNotNil(afterWarmup)
        XCTAssertEqual(afterWarmup?.time ?? 0, 1.5, accuracy: 0.001)
        // 之后每 0.25 秒 2 MB = 8 MB/s，到 6 秒（后 4.5 秒）
        while t < 6 {
            t += 0.25
            XCTAssertFalse(meter.isFinished(at: t - 0.01))
            meter.add(2_000_000)
            meter.tick(at: t)
        }
        XCTAssertTrue(meter.isFinished(at: t))
        XCTAssertEqual(NetSpeedPlan.phaseDuration - NetSpeedPlan.warmup, 4.5)
        XCTAssertEqual(meter.result(at: t) ?? 0, 8_000_000, accuracy: 1)
        XCTAssertEqual(meter.currentRate(at: t) ?? 0, 8_000_000, accuracy: 1)
        XCTAssertEqual(meter.progress(at: t), 1)
    }

    func testPlanCaps() {
        XCTAssertEqual(NetSpeedPlan.downloadCap, 500 * 1024 * 1024)
        XCTAssertEqual(NetSpeedPlan.uploadCap, 300 * 1024 * 1024)
        // 上限先到就停：下载 500 MB 到了，时间还没到也算完
        var meter = NetSpeedMeter(start: 0, cap: NetSpeedPlan.downloadCap)
        meter.add(NetSpeedPlan.downloadCap)
        XCTAssertTrue(meter.isFinished(at: 2))
    }

    func testMeterCapReachedFirst() {
        // 上限 100 MB：0.5 秒就到了（起速段都没过完），用全程平均
        var meter = NetSpeedMeter(start: 10, cap: 100_000_000)
        meter.add(60_000_000)
        meter.tick(at: 10.25)
        XCTAssertFalse(meter.isFinished(at: 10.25))
        meter.add(40_000_000)
        meter.tick(at: 10.5)
        XCTAssertTrue(meter.isFinished(at: 10.5))
        XCTAssertNil(meter.baseline)
        XCTAssertEqual(meter.result(at: 10.5) ?? 0, 200_000_000, accuracy: 1)
        XCTAssertEqual(meter.progress(at: 10.5), 1)
    }

    func testMeterCapShortlyAfterWarmup() {
        // 起速段过完 0.25 秒就到上限：之后的窗口太短，也用全程平均
        var meter = NetSpeedMeter(start: 0, cap: 1_000)
        meter.add(600)
        meter.tick(at: 1.5)
        meter.add(400)
        meter.tick(at: 1.75)
        XCTAssertTrue(meter.isFinished(at: 1.75))
        XCTAssertEqual(meter.result(at: 1.75) ?? 0, 1_000 / 1.75, accuracy: 0.001)
    }

    func testMeterNothingReceived() {
        var meter = NetSpeedMeter(start: 0, cap: 1_000)
        meter.tick(at: 2)
        meter.tick(at: 8)
        XCTAssertTrue(meter.isFinished(at: 8))
        XCTAssertNil(meter.result(at: 8))
        XCTAssertEqual(meter.currentRate(at: 8), 0)
        let fresh = NetSpeedMeter(start: 0, cap: 1_000)
        XCTAssertNil(fresh.currentRate(at: 0.1))
        meter.add(-5)
        XCTAssertEqual(meter.total, 0)
    }

    func testMeterLiveWindow() {
        var meter = NetSpeedMeter(start: 0, cap: 1 << 40)
        // 先 1 MB/s 跑 3 秒，再 4 MB/s 跑 1.5 秒：「这一刻」只看最近一秒
        var t = 0.0
        while t < 3 {
            t += 0.25
            meter.add(250_000)
            meter.tick(at: t)
        }
        while t < 4.5 {
            t += 0.25
            meter.add(1_000_000)
            meter.tick(at: t)
        }
        XCTAssertEqual(meter.currentRate(at: t) ?? 0, 4_000_000, accuracy: 1)
        XCTAssertEqual(meter.progress(at: 3), 0.5)
    }

    // MARK: - 延迟

    func testMedianAndJitter() {
        XCTAssertNil(NetSpeedLatency.median([]))
        XCTAssertEqual(NetSpeedLatency.median([0.012]), 0.012)
        XCTAssertEqual(NetSpeedLatency.median([0.030, 0.010, 0.020]), 0.020)
        XCTAssertEqual(NetSpeedLatency.median([0.040, 0.010, 0.030, 0.020]) ?? 0, 0.025, accuracy: 1e-12)
        XCTAssertNil(NetSpeedLatency.jitter([]))
        XCTAssertNil(NetSpeedLatency.jitter([0.012]))
        XCTAssertEqual(NetSpeedLatency.jitter([0.010, 0.014]) ?? 0, 0.004, accuracy: 1e-12)
        // |14-10| + |11-14| + |11-11| = 7，三个差 → 7/3 ms
        XCTAssertEqual(NetSpeedLatency.jitter([0.010, 0.014, 0.011, 0.011]) ?? 0, 0.007 / 3, accuracy: 1e-12)
    }

    func testServerTiming() {
        // 2026-11-25 实测的形状（URLSession 把两个同名头用逗号并成一个）
        let real = #"cfSpeedEdge;dur=4, cfSpeedWorker;dur=30, cfL4;desc="?proto=TCP&rtt=8170&min_rtt=8019&x=0""#
        XCTAssertEqual(NetSpeedLatency.serverTime(real), 0.034, accuracy: 1e-12)
        XCTAssertEqual(NetSpeedLatency.serverTime("app;dur=12.5"), 0.0125, accuracy: 1e-12)
        XCTAssertEqual(NetSpeedLatency.serverTime("app;DUR=\"7\""), 0.007, accuracy: 1e-12)
        XCTAssertEqual(NetSpeedLatency.serverTime(nil), 0)
        XCTAssertEqual(NetSpeedLatency.serverTime(""), 0)
        XCTAssertEqual(NetSpeedLatency.serverTime("cfL4;desc=\"rtt=8\""), 0)
        XCTAssertEqual(NetSpeedLatency.serverTime("x;dur=abc, y;dur=-3, z;dur=nan"), 0)
    }

    func testLatencySample() {
        XCTAssertEqual(NetSpeedLatency.sample(measured: 0.045, serverTiming: "a;dur=4, b;dur=30"), 0.011, accuracy: 1e-12)
        // 服务端的数比测到的还大：不扣
        XCTAssertEqual(NetSpeedLatency.sample(measured: 0.020, serverTiming: "a;dur=30"), 0.020)
        XCTAssertEqual(NetSpeedLatency.sample(measured: 0.020, serverTiming: nil), 0.020)
    }

    // MARK: - /meta

    /// 2026-11-25 实测的回包形状（值换成了文档用的假数据：IP、ASN、运营商、位置）
    private let meta = #"{"hostname":"speed.cloudflare.com","clientIp":"203.0.113.7","httpProtocol":"HTTP/1.1","asn":64500,"asOrganization":"Example Broadband","country":"DE","city":"Frankfurt","postalCode":"00000","latitude":"0","longitude":"0","colo":{"iata":"FRA","lat":50.0,"lon":8.5,"cca2":"DE","region":"Europe","city":"Frankfurt"}}"#

    func testMetaReal() {
        let server = NetSpeedMeta.parse(meta)
        XCTAssertEqual(server?.colo, "FRA")
        XCTAssertEqual(server?.coloCity, "Frankfurt")
        XCTAssertEqual(server?.asn, 64500)
        XCTAssertEqual(server?.organization, "Example Broadband")
        XCTAssertEqual(server?.node, "Frankfurt (FRA)")
        XCTAssertEqual(server?.exit, "Example Broadband (AS64500)")
    }

    func testMetaMissingFields() {
        XCTAssertEqual(NetSpeedMeta.parse(#"{"colo":"SIN"}"#)?.node, "SIN")
        XCTAssertNil(NetSpeedMeta.parse(#"{"colo":"SIN"}"#)?.exit)
        XCTAssertEqual(NetSpeedMeta.parse(#"{"asn":"AS13335"}"#)?.exit, "AS13335")
        XCTAssertEqual(NetSpeedMeta.parse(#"{"asOrganization":"Cloudflare"}"#)?.exit, "Cloudflare")
        XCTAssertEqual(NetSpeedMeta.parse(#"{"colo":{"city":"Tokyo"}}"#)?.node, "Tokyo")
        // 一样有用的都没有
        XCTAssertNil(NetSpeedMeta.parse(#"{"hostname":"speed.cloudflare.com"}"#))
        XCTAssertNil(NetSpeedMeta.parse("{}"))
    }

    func testMetaWrongTypes() {
        // 类型不符的字段跳过：asn 是布尔、组织名是数字、colo 是数组
        let odd = #"{"asn":true,"asOrganization":42,"colo":["FRA"],"city":"Frankfurt"}"#
        XCTAssertNil(NetSpeedMeta.parse(odd))
        XCTAssertEqual(NetSpeedMeta.parse(#"{"asn":0,"colo":{"iata":7,"city":"Osaka"}}"#)?.node, "Osaka")
        XCTAssertNil(NetSpeedMeta.parse(#"{"asn":0,"colo":{"iata":7,"city":"Osaka"}}"#)?.exit)
        XCTAssertNil(NetSpeedMeta.parse(#"{"asn":"ASxyz"}"#))
    }

    func testMetaNotJSON() {
        XCTAssertNil(NetSpeedMeta.parse(""))
        XCTAssertNil(NetSpeedMeta.parse("<html>403 Forbidden</html>"))
        XCTAssertNil(NetSpeedMeta.parse(#"["SIN"]"#))
        XCTAssertNil(NetSpeedMeta.parse("null"))
    }
}
