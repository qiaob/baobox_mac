import Foundation

/// 网络泄露检测的文案：纯逻辑给的结构化原因 → 本地化的句子；纯文本报告。
enum NetCheckText {

    private static func list(_ items: [String]) -> String {
        items.joined(separator: L("netcheck.separator"))
    }

    static func title(_ item: NetCheckItem) -> String {
        switch item {
        case .exit: return L("netcheck.item.exit")
        case .ipv6: return L("netcheck.item.ipv6")
        case .dns: return L("netcheck.item.dns")
        case .webrtc: return L("netcheck.item.webrtc")
        case .timezone: return L("netcheck.item.timezone")
        }
    }

    static func title(_ goal: NetCheckGoal) -> String {
        switch goal {
        case .carrier: return L("netcheck.goal.carrier")
        case .location: return L("netcheck.goal.location")
        }
    }

    static func headline(_ verdict: NetCheckVerdict) -> String {
        switch verdict {
        case .ok: return L("netcheck.headline.ok")
        case .notice: return L("netcheck.headline.notice")
        case .leak: return L("netcheck.headline.leak")
        case .unknown: return L("netcheck.headline.unknown")
        }
    }

    /// 相对时间（「3 分钟前」），跟着 App 语言。
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 菜单与报告里放在每一行前面的记号。
    static func mark(_ verdict: NetCheckVerdict) -> String {
        switch verdict {
        case .ok: return "✓"
        case .notice: return "!"
        case .leak: return "✗"
        case .unknown: return "?"
        }
    }

    /// 窗口里的图标（SF Symbol）。
    static func symbol(_ verdict: NetCheckVerdict) -> String {
        switch verdict {
        case .ok: return "checkmark.circle.fill"
        case .notice: return "exclamationmark.circle.fill"
        case .leak: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private static func flag(_ flag: NetCheckExitFlag) -> String {
        switch flag {
        case .hosting(let name?): return L("netcheck.flag.hosting \(name)")
        case .hosting(nil): return L("netcheck.flag.hostingUnknown")
        case .vpn: return L("netcheck.flag.vpn")
        case .proxy: return L("netcheck.flag.proxy")
        case .tor: return L("netcheck.flag.tor")
        }
    }

    static func detail(_ reason: NetCheckReason) -> String {
        switch reason {
        case .failed(let why): return L("netcheck.reason.failed \(why)")
        case .exitIsReal(let ip): return L("netcheck.reason.exitIsReal \(ip)")
        case .exitFlagged(let ip, let flags): return L("netcheck.reason.exitFlagged \(ip) \(list(flags.map { flag($0) }))")
        case .exitClean(let ip): return ip
        case .noIPv6: return L("netcheck.reason.noIPv6")
        case .ipv6IsReal(let ip): return L("netcheck.reason.ipv6IsReal \(ip)")
        case .ipv6Differs(let ip): return L("netcheck.reason.ipv6Differs \(ip)")
        case .ipv6Matches(let ip): return L("netcheck.reason.ipv6Matches \(ip)")
        case .ipv6CannotCompare(let ip): return L("netcheck.reason.ipv6CannotCompare \(ip)")
        case .dnsServiceError(let why): return L("netcheck.reason.dnsServiceError \(why)")
        case .dnsNoResolvers: return L("netcheck.reason.dnsNoResolvers")
        case .dnsLeak(let servers): return L("netcheck.reason.dnsLeak \(list(servers))")
        case .dnsUndeclared(let count, let owners): return L("netcheck.reason.dnsUndeclared \(count) \(list(owners))")
        case .dnsClean(let count, let owners): return L("netcheck.reason.dnsClean \(count) \(list(owners))")
        case .webrtcCannotCompare(let ips): return L("netcheck.reason.webrtcCannotCompare \(list(ips))")
        case .webrtcLeak(let ips): return L("netcheck.reason.webrtcLeak \(list(ips))")
        case .webrtcLocal(let ips): return L("netcheck.reason.webrtcLocal \(list(ips))")
        case .webrtcNothing: return L("netcheck.reason.webrtcNothing")
        case .webrtcMatches: return L("netcheck.reason.webrtcMatches")
        case .timezoneUnavailable: return L("netcheck.reason.timezoneUnavailable")
        case .exitTimezoneUnknown: return L("netcheck.reason.exitTimezoneUnknown")
        case .timezoneMatch(let zone): return L("netcheck.reason.timezoneMatch \(zone)")
        case .timezoneMismatch(let system, let exit): return L("netcheck.reason.timezoneMismatch \(system) \(exit)")
        }
    }

    private static func hint(_ hint: NetCheckProxyHint) -> String {
        switch hint {
        case .hostingExit: return L("netcheck.hint.hostingExit")
        case .timezoneMismatch: return L("netcheck.hint.timezoneMismatch")
        case .dnsCarrier: return L("netcheck.hint.dnsCarrier")
        }
    }

    static func detail(_ reason: NetCheckSummaryReason) -> String {
        switch reason {
        case .tunnelOff: return L("netcheck.summary.tunnelOff")
        case .partialLeak(let items): return L("netcheck.summary.partialLeak \(list(items.map { title($0) }))")
        case .undetermined(let items): return L("netcheck.summary.undetermined \(list(items.map { title($0) }))")
        case .carrierClean: return L("netcheck.summary.carrierClean")
        case .ipLeak(let items): return L("netcheck.summary.ipLeak \(list(items.map { title($0) }))")
        case .locationHidden(let place, let hints):
            let seen = place.map { L("netcheck.summary.locationSeen \($0)") } ?? L("netcheck.summary.locationExitOnly")
            if hints.isEmpty { return seen }
            return L("netcheck.summary.locationProxyHints \(seen) \(list(hints.map { hint($0) }))")
        }
    }

    /// 一行：`✗ DNS：…`。
    static func line(_ finding: NetCheckFinding) -> String {
        L("netcheck.line \(mark(finding.verdict)) \(title(finding.item)) \(detail(finding.reason))")
    }

    static func line(_ summary: NetCheckSummary) -> String {
        L("netcheck.line \(mark(summary.verdict)) \(title(summary.goal)) \(detail(summary.reason))")
    }

    /// 「复制报告」的纯文本。
    static func report(_ outcome: NetCheckSession.Outcome) -> String {
        var lines = [L("netcheck.report.title \(headline(outcome.overall))"), ""]
        lines.append(L("netcheck.report.summary"))
        lines.append(contentsOf: outcome.summary.map { line($0) })
        lines.append("")
        lines.append(L("netcheck.report.items"))
        lines.append(contentsOf: outcome.findings.map { line($0) })
        if let words = outcome.dnsConclusion {
            lines.append(L("netcheck.report.bashws \(words)"))
        }
        if !outcome.realDeclared {
            lines.append(L("netcheck.note.declare"))
        }
        lines.append(L("netcheck.note.gps"))
        return lines.joined(separator: "\n")
    }

    // MARK: - 测速（docs/netcheck/SPEED.md §1.3）

    static func title(_ phase: NetSpeedPhase) -> String {
        switch phase {
        case .latency: return L("netcheck.speed.phase.latency")
        case .download: return L("netcheck.speed.phase.download")
        case .upload: return L("netcheck.speed.phase.upload")
        }
    }

    /// `93 Mbps`（单位不翻译）。
    static func mbps(_ bytesPerSecond: Double) -> String {
        "\(NetSpeedFormat.mbps(bytesPerSecond)) Mbps"
    }

    /// `12 ms`。
    static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(NetSpeedFormat.milliseconds(seconds)) ms"
    }

    /// 抖动那行小字；只测到一次时没有。
    static func jitter(_ latency: NetSpeedLatencyResult) -> String? {
        latency.jitter.map { L("netcheck.speed.jitter \(milliseconds($0))") }
    }

    /// 「经 Frankfurt (FRA) · 出口 Example Broadband (AS64500)」；`/meta` 没拿到时 nil（不显示那一行）。
    static func via(_ server: NetSpeedServer?) -> String? {
        switch (server?.node, server?.exit) {
        case (let node?, let exit?): return L("netcheck.speed.via \(node) \(exit)")
        case (let node?, nil): return L("netcheck.speed.viaNode \(node)")
        case (nil, let exit?): return L("netcheck.speed.viaExit \(exit)")
        case (nil, nil): return nil
        }
    }

    static func used(_ result: NetSpeedResult) -> String {
        L("netcheck.speed.used \(NetSpeedFormat.amount(Double(result.bytesUsed)))")
    }

    /// 二级菜单里的一行：「上次测速：↓ 93 Mbps ↑ 21 Mbps · 12 ms · 3 分钟前」，没测出来的写「—」。
    static func menuLine(_ result: NetSpeedResult) -> String {
        let dash = "—"
        let down = (try? result.download.get()).map { mbps($0) } ?? dash
        let up = (try? result.upload.get()).map { mbps($0) } ?? dash
        let ping = (try? result.latency.get()).map { milliseconds($0.median) } ?? dash
        return L("netcheck.menu.lastSpeed \(down) \(up) \(ping) \(relative(result.at))")
    }

    /// 一项结果的一行：`93 Mbps（11.1 MB/s）` / `12 ms（抖动 1.3 ms）` / `没测出来：…`。
    static func reportValue(_ phase: NetSpeedPhase, _ result: NetSpeedResult) -> String {
        switch phase {
        case .latency:
            switch result.latency {
            case .success(let latency):
                guard let jitter = jitter(latency) else { return milliseconds(latency.median) }
                return L("netcheck.speed.report.detail \(milliseconds(latency.median)) \(jitter)")
            case .failure(let why):
                return L("netcheck.speed.failedBecause \(why.message)")
            }
        case .download, .upload:
            switch phase == .download ? result.download : result.upload {
            case .success(let rate):
                return L("netcheck.speed.report.detail \(mbps(rate)) \(NetSpeedFormat.rate(rate))")
            case .failure(let why):
                return L("netcheck.speed.failedBecause \(why.message)")
            }
        }
    }

    /// 「复制结果」的纯文本。
    static func speedReport(_ result: NetSpeedResult) -> String {
        var lines = [L("netcheck.speed.report.title \(result.at.formatted(date: .abbreviated, time: .shortened))")]
        for phase in [NetSpeedPhase.download, .upload, .latency] {
            lines.append(L("netcheck.speed.report.line \(title(phase)) \(reportValue(phase, result))"))
        }
        if let via = via(result.server) { lines.append(via) }
        lines.append(used(result))
        return lines.joined(separator: "\n")
    }
}
