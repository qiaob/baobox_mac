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

    /// 相对时间（「3 分钟前」），跟着 App 语言。
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 一格里的字。
    static func value(_ value: NetCheckValue) -> String {
        switch value {
        case .text(let text): return text
        case .noIPv6: return L("netcheck.value.noIPv6")
        case .notFound: return L("netcheck.value.notFound")
        case .noPublicAddress: return L("netcheck.value.noPublicAddress")
        case .servers(let count): return L("netcheck.value.servers \(count)")
        case .systemZone(let zone): return L("netcheck.value.systemZone \(zone ?? L("netcheck.value.notFound"))")
        case .ipZone(let zone): return L("netcheck.value.ipZone \(zone ?? L("netcheck.value.notFound"))")
        case .empty: return ""
        }
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
        }
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
        lines.append("")
        let words = NetCheckCompare.ReportWords(rowTitle: { title($0) }, value: { value($0) },
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
