import Foundation

/// 网络检测的文案：IP 检测的表（纯逻辑给的结构化的值 → 本地化的字）、纯文本报告；测速的文案在后面。
enum NetCheckText {

    static func title(_ item: NetCheckItem) -> String {
        switch item {
        case .ipv4: return L("netcheck.item.ipv4")
        case .ipv6: return L("netcheck.item.ipv6")
        case .dns: return L("netcheck.item.dns")
        case .webrtc: return L("netcheck.item.webrtc")
        case .timezone: return L("netcheck.item.timezone")
        }
    }

    /// 行名；DNS 那一行带台数：「DNS（8 台）」。
    static func title(_ row: NetCheckRow) -> String {
        guard row.item == .dns, let count = row.serverCount else { return title(row.item) }
        return L("netcheck.item.dnsServers \(count)")
    }

    static func title(_ aspect: NetCheckAspect) -> String {
        switch aspect {
        case .country: return L("netcheck.aspect.country")
        case .owner: return L("netcheck.aspect.owner")
        case .address: return L("netcheck.aspect.address")
        case .timezone: return L("netcheck.aspect.timezone")
        }
    }

    /// 结论：「一致」「不一致」「没测出来，无法比较」。
    static func conclusion(_ conclusion: NetCheckConclusion) -> String {
        switch conclusion {
        case .consistent: return L("netcheck.conclusion.consistent")
        case .inconsistent: return L("netcheck.conclusion.inconsistent")
        case .cannotCompare: return L("netcheck.conclusion.cannotCompare")
        }
    }

    /// 「不一致」下面的小字：「对不上的：国家、归属」。一致 / 无法比较时 nil。
    static func mismatches(_ conclusion: NetCheckConclusion) -> String? {
        guard case .inconsistent(let aspects) = conclusion, !aspects.isEmpty else { return nil }
        return L("netcheck.conclusion.mismatches \(aspects.map { title($0) }.joined(separator: L("netcheck.separator")))")
    }

    /// 相对时间（「3 分钟前」），跟着 App 语言。不到 5 秒写「刚刚」（基底会写成「0秒后」）。
    static func relative(_ date: Date) -> String {
        let now = Date()
        if NetCheckTime.isJustNow(date, now: now) { return L("netcheck.time.justNow") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// 一格里的字。
    static func value(_ value: NetCheckValue, at date: Date = Date()) -> String {
        switch value {
        case .text(let text): return text
        case .place(let code, let country, let city): return place(code: code, country: country, city: city)
        case .noIPv6: return L("netcheck.value.noIPv6")
        case .notFound: return L("netcheck.value.notFound")
        case .noPublicAddress: return L("netcheck.value.noPublicAddress")
        case .fakeIP: return L("netcheck.value.fakeIP")
        case .servers(let count): return L("netcheck.value.servers \(count)")
        case .systemZone(let zone): return L("netcheck.value.systemZone \(zoneWithOffset(zone, at: date))")
        case .ipZone(let zone): return L("netcheck.value.ipZone \(zoneWithOffset(zone, at: date))")
        case .empty: return ""
        }
    }

    private static func zoneWithOffset(_ zone: String?, at date: Date) -> String {
        guard let zone, !zone.isEmpty else { return L("netcheck.value.notFound") }
        guard let offset = NetCheckCompare.utcOffsetLabel(for: zone, at: date) else { return zone }
        return "\(zone) (\(offset))"
    }

    /// 「美国 · Ashburn」：认得出代码时国家用 App 语言的地区名，后面跟城市（和国家同名时不重复）；认不出用原文。
    static func place(code: String?, country: String, city: String) -> String {
        let name = code.flatMap { L10n.locale.localizedString(forRegionCode: $0) } ?? country
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        // 城市和国家同名（新加坡）时不重复：本地化的国家名、回包里的原文都比一次（中文界面不会出现「新加坡 · Singapore」）
        if !city.isEmpty, city.caseInsensitiveCompare(name) != .orderedSame,
           city.caseInsensitiveCompare(country) != .orderedSame,
           NetCheckCountry.code(nil, name: city) != code || code == nil {
            parts.append(city)
        }
        return parts.isEmpty ? L("netcheck.value.notFound") : parts.joined(separator: " · ")
    }

    /// 「没测出来：<原因>」。
    static func failure(_ failure: NetCheckRowFailure) -> String {
        let why: String
        switch failure {
        case .failed(let message): why = message
        case .dnsServiceError(let message): why = L("netcheck.failure.bashws \(message)")
        case .dnsNoResolvers: why = L("netcheck.failure.noResolvers")
        }
        return L("netcheck.failure \(why)")
    }

    /// 归属后面的灰色小标签。
    static func flag(_ flag: NetCheckExitFlag) -> String {
        switch flag {
        case .hosting: return L("netcheck.flag.hosting")
        case .vpn: return L("netcheck.flag.vpn")
        case .proxy: return L("netcheck.flag.proxy")
        case .tor: return L("netcheck.flag.tor")
        case .publicDNS: return L("netcheck.flag.publicDNS")
        }
    }

    // MARK: - 本机网络环境摘要

    static func envLAN(_ env: NetCheckEnvironment) -> String {
        guard let lan = env.lan else { return L("netcheck.env.none") }
        return "\(lan.interface) · \(lan.ip)"
    }

    static func envProxy(_ env: NetCheckEnvironment) -> String {
        let entries = env.proxy.entries
        return entries.isEmpty ? L("netcheck.env.off") : entries.joined(separator: " · ")
    }

    static func envTunnels(_ env: NetCheckEnvironment) -> String {
        compactList(env.tunnels.map(\.label), empty: L("netcheck.env.none"))
    }

    static func envDNS(_ env: NetCheckEnvironment) -> String {
        compactList(env.dnsServers, empty: L("netcheck.env.none"))
    }

    private static func compactList(_ items: [String], empty: String, limit: Int = 2) -> String {
        guard !items.isEmpty else { return empty }
        if items.count <= limit { return items.joined(separator: ", ") }
        let head = items.prefix(limit).joined(separator: ", ")
        return "\(head) \(L("netcheck.env.more \(items.count - limit)"))"
    }

    static func environmentReportLine(_ env: NetCheckEnvironment) -> String {
        let colon = L("netcheck.report.colon")
        let parts = [
            L("netcheck.env.lan") + colon + envLAN(env),
            L("netcheck.env.proxy") + colon + envProxy(env),
            L("netcheck.env.tunnel") + colon + envTunnels(env),
            L("netcheck.env.dns") + colon + envDNS(env),
        ]
        return L("netcheck.report.env \(parts.joined(separator: " · "))")
    }

    /// 二级菜单里的一行：「上次检测：一致 · 3 分钟前」。
    static func menuLine(_ outcome: NetCheckSession.Outcome) -> String {
        L("netcheck.menu.last \(conclusion(outcome.table.conclusion)) \(relative(outcome.at))")
    }

    /// 「复制报告」的纯文本：第一行结论和时间，不一致时第二行是对不上的那几样；之后每一条一行，最后是定位的说明。
    static func report(_ outcome: NetCheckSession.Outcome) -> String {
        let table = outcome.table
        var lines = [L("netcheck.report.title \(conclusion(table.conclusion)) \(outcome.at.formatted(date: .abbreviated, time: .standard))")]
        if let mismatches = mismatches(table.conclusion) { lines.append(mismatches) }
        if let env = outcome.environment { lines.append(environmentReportLine(env)) }
        lines.append("")
        let words = NetCheckCompare.ReportWords(rowTitle: { title($0) }, value: { value($0, at: outcome.at) },
                                                failure: { failure($0) }, flag: { flag($0) },
                                                mismatch: L("netcheck.report.mismatch"), colon: L("netcheck.report.colon"))
        lines.append(contentsOf: NetCheckCompare.reportLines(table, words: words))
        lines.append("")
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

    /// 负载延迟小字：「负载 ↓ 28 ms · ↑ 45 ms」；都没测到时 nil。
    static func loadedLatency(_ latency: NetSpeedLatencyResult) -> String? {
        var parts: [String] = []
        if let down = latency.downloadLoaded { parts.append("↓ \(milliseconds(down))") }
        if let up = latency.uploadLoaded { parts.append("↑ \(milliseconds(up))") }
        guard !parts.isEmpty else { return nil }
        return L("netcheck.speed.loaded \(parts.joined(separator: " · "))")
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

    /// 一项结果的一行：`93 Mbps（11.1 MB/s）` / `12 ms（抖动 1.3 ms · 负载 ↓ 28 ms · ↑ 45 ms）` / `没测出来：…`。
    static func reportValue(_ phase: NetSpeedPhase, _ result: NetSpeedResult) -> String {
        switch phase {
        case .latency:
            switch result.latency {
            case .success(let latency):
                let details = [jitter(latency), loadedLatency(latency)].compactMap { $0 }
                guard !details.isEmpty else { return milliseconds(latency.median) }
                return L("netcheck.speed.report.detail \(milliseconds(latency.median)) \(details.joined(separator: " · "))")
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

    // MARK: - 单目标诊断与常用服务连通性

    static func serviceGroupTitle(_ group: NetServiceGroup) -> String {
        switch group {
        case .china: return L("netcheck.diag.group.china")
        case .global: return L("netcheck.diag.group.global")
        case .ai: return L("netcheck.diag.group.ai")
        }
    }

    static func serviceOutcomeText(_ outcome: NetServiceOutcome) -> String {
        switch outcome {
        case .reachable(let status):
            return status == 204 ? "204" : L("netcheck.diag.status.reachable \(status)")
        case .restricted(let status):
            return L("netcheck.diag.status.restricted \(status)")
        case .unreachable(let kind, let detail):
            switch kind {
            case .timeout: return L("netcheck.diag.error.timeout")
            case .dnsFailed: return L("netcheck.diag.error.dnsFailed")
            case .tlsError: return L("netcheck.diag.error.tlsFailed")
            case .connectionFailed: return L("netcheck.diag.error.connFailed")
            case .other: return detail
            }
        }
    }

    static func pathTag(_ viaProxy: Bool?) -> String? {
        guard let viaProxy else { return nil }
        return viaProxy ? L("netcheck.diag.viaProxy") : L("netcheck.diag.direct")
    }

    static func diagDNSSummary(_ dns: NetDiagDNSResult) -> String {
        if dns.state == .skipped {
            return L("netcheck.diag.dns.ipLiteral \(dns.addresses.first ?? "")")
        }
        if let error = dns.error { return error }
        var parts = dns.addresses.prefix(4).map { $0 }
        if dns.addresses.count > 4 {
            parts.append(L("netcheck.env.more \(dns.addresses.count - 4)"))
        }
        let joined = parts.joined(separator: ", ")
        return dns.fakeIP ? "\(joined) · Fake-IP" : joined
    }

    static func diagTCPSummary(_ tcp: NetDiagTCPResult, target: NetDiagTarget) -> String {
        if let error = tcp.error { return error }
        return L("netcheck.diag.tcp.connected \(target.hostPortLabel)")
    }

    static func diagTLSSummary(_ tls: NetDiagTLSResult, at now: Date) -> String {
        if tls.state == .skipped { return L("netcheck.diag.tls.skipped") }
        if let error = tls.error { return error }
        var parts: [String] = []
        if let ver = tls.protocolVersion { parts.append(ver) }
        if let subject = tls.subject, !subject.isEmpty { parts.append(subject) }
        if let issuer = tls.issuer, !issuer.isEmpty {
            parts.append(L("netcheck.diag.tls.issuer \(issuer)"))
        }
        if let expires = tls.expiresAt {
            let days = NetDiagLogic.daysUntilExpiry(notAfter: expires, now: now)
            if days < 0 {
                parts.append(L("netcheck.diag.tls.expired"))
            } else {
                parts.append(L("netcheck.diag.tls.validDays \(days)"))
            }
        }
        if tls.trusted == false {
            parts.append(L("netcheck.diag.tls.untrusted"))
        }
        return parts.isEmpty ? L("netcheck.diag.tls.ok") : parts.joined(separator: " · ")
    }

    static func diagHTTPSummary(_ http: NetDiagHTTPResult) -> String {
        if let error = http.error { return error }
        var parts: [String] = []
        if let code = http.statusCode { parts.append("HTTP \(code)") }
        if let proto = http.networkProtocol, !proto.isEmpty { parts.append(proto) }
        if let path = pathTag(http.viaProxy) { parts.append(path) }
        if let remote = http.remoteAddress, !remote.isEmpty { parts.append(remote) }
        if let loc = http.redirectLocation, !loc.isEmpty { parts.append("→ \(loc)") }
        if let note = http.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    static func diagReport(_ report: NetDiagReport) -> String {
        let colon = L("netcheck.report.colon")
        var lines: [String] = [
            L("netcheck.diag.report.title \(report.target.urlString) \(report.at.formatted(date: .abbreviated, time: .standard))"),
            "",
        ]
        func line(_ name: String, duration: TimeInterval?, summary: String) -> String {
            let timing = duration.map { " (\(milliseconds($0)))" } ?? ""
            return "\(name)\(timing)\(colon)\(summary)"
        }
        lines.append(line("DNS", duration: report.dns.duration, summary: diagDNSSummary(report.dns)))
        lines.append(line("TCP", duration: report.tcp.duration, summary: diagTCPSummary(report.tcp, target: report.target)))
        lines.append(line("TLS", duration: report.tls.duration, summary: diagTLSSummary(report.tls, at: report.at)))
        lines.append(line("HTTP", duration: report.http.ttfb, summary: diagHTTPSummary(report.http)))
        return lines.joined(separator: "\n")
    }
}
