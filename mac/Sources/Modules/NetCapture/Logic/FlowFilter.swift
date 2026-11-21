import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：列表筛选（docs/packet-capture/TOOLS.md §1）。
//
// 纯界面过滤：只决定列表里显示哪些行。不向引擎发任何东西、不改解密范围、不改存着的数据；
// 被滤掉的请求照常抓、照常存、照常计入状态栏的总数。文本搜索要读正文，留在 FlowStore。

/// 筛选要看的那几样。`Flow`（FlowStore.swift）实现它；单元测试用一个小结构体。
protocol FilterableFlow {
    var host: String { get }
    /// 完整 URL：`scheme://host[:port]/path?query`。
    var url: String { get }
    var method: String { get }
    /// 状态码的百位（2 / 3 / 4 / 5），还没有响应是 0。
    var statusClass: Int { get }
    var decrypted: Bool { get }
    /// 来源设备（客户端 IP；不知道来源的归一个占位桶）。
    var deviceKey: String { get }
    /// 是 WebSocket 连接（工具条的「WS」筛选看它）。
    var isWebSocket: Bool { get }
}

/// 两个过滤输入框（「过滤域名」「过滤 URL」）共用的语法：
/// - 按空格或逗号（含中文逗号）分词，不分大小写，做「包含」匹配；
/// - 普通词之间是「或」：包含任意一个就算命中；
/// - `-` 开头的词是排除：包含它就不要，排除优先；只有排除词 = 除了被排除的都要；
/// - 空词、单独一个 `-` 忽略；整框为空 = 不过滤。
struct TermFilter: Equatable, Sendable {
    /// 用户输入的原文（输入框绑定它）。
    let text: String
    /// 小写的普通词。
    let include: [String]
    /// 小写的排除词（不含开头的 `-`）。
    let exclude: [String]

    init(text: String = "") {
        self.text = text
        var include: [String] = []
        var exclude: [String] = []
        let separators: Set<Character> = [",", "，"]
        for piece in text.split(whereSeparator: { $0.isWhitespace || separators.contains($0) }) {
            let term = piece.lowercased()
            if term.hasPrefix("-") {
                let rest = String(term.dropFirst())
                if !rest.isEmpty { exclude.append(rest) }
            } else {
                include.append(term)
            }
        }
        self.include = include
        self.exclude = exclude
    }

    /// 没有任何有效的词：什么都不滤。
    var isEmpty: Bool { include.isEmpty && exclude.isEmpty }

    func matches(_ string: String) -> Bool {
        guard !isEmpty else { return true }
        let lower = string.lowercased()
        if exclude.contains(where: { lower.contains($0) }) { return false }
        return include.isEmpty || include.contains(where: { lower.contains($0) })
    }
}

/// 列表的全部筛选条件。分两类：
/// - **藏噪音**（隐藏名单、「隐藏未解密」、「过滤域名」输入框）：被藏的不出现在列表里，也不计入左栏的数字；
/// - **挑选**（来源、左栏选中的域名、方法、状态码类别）和「过滤 URL」输入框：只影响请求列表，左栏的数字不随它变。
struct FlowFilter: Equatable, Sendable {
    /// 来源设备；nil = 全部。
    var device: String?
    /// 左栏选中的域名；nil = 全部。
    var host: String?
    var methods: Set<String> = []
    var statusClasses: Set<Int> = []
    /// 工具条的「WS」：只看 WebSocket。
    var webSocketOnly = false
    /// 精确域名。
    var hiddenHosts: Set<String> = []
    var hideUndecrypted = false
    /// 「过滤域名」输入框：匹配域名（不含端口和路径）。
    var hostTerms = TermFilter()
    /// 「过滤 URL」输入框：匹配完整 URL。
    var urlTerms = TermFilter()

    /// 这一行在请求列表里出现吗。
    func includes<F: FilterableFlow>(_ flow: F) -> Bool {
        passesNoise(host: flow.host, decrypted: flow.decrypted)
            && selects(flow)
            && (urlTerms.isEmpty || urlTerms.matches(flow.url))   // URL 要现拼，没写过滤词就不拼
    }

    /// 没被「藏噪音」那三样藏掉（左栏的数字只看这个和来源）。
    func passesNoise(host: String, decrypted: Bool) -> Bool {
        if hideUndecrypted && !decrypted { return false }
        if hiddenHosts.contains(host) { return false }
        return hostTerms.matches(host)
    }

    /// 符合用户挑的来源、域名、方法、状态码类别、「WS」。
    func selects<F: FilterableFlow>(_ flow: F) -> Bool {
        if let selected = device, selected != flow.deviceKey { return false }
        if let selected = host, selected != flow.host { return false }
        if !methods.isEmpty && !methods.contains(flow.method.uppercased()) { return false }
        if !statusClasses.isEmpty && !statusClasses.contains(flow.statusClass) { return false }
        if webSocketOnly && !flow.isWebSocket { return false }
        return true
    }

    /// 选中的域名被隐藏名单或「过滤域名」藏掉了：该取消选中，否则列表空了却看不出原因。
    var selectedHostIsHidden: Bool {
        guard let host else { return false }
        return hiddenHosts.contains(host) || !hostTerms.matches(host)
    }

    /// 按条件取子集，顺序不变；`flows` 本身不动。
    func visible<F: FilterableFlow>(_ flows: [F]) -> [F] {
        flows.filter { includes($0) }
    }

    /// 被「藏」掉的条数：符合挑选条件、却被隐藏名单 / 「隐藏未解密」/ 两个过滤输入框滤掉的。
    /// 列表空了而这个数不是 0 时，列表区说明「N 条请求被过滤条件隐藏」。`extra` 是调用方另加的条件（全文搜索）。
    func hiddenCount<F: FilterableFlow>(_ flows: [F], where extra: (F) -> Bool = { _ in true }) -> Int {
        flows.reduce(0) { count, flow in
            guard selects(flow), extra(flow) else { return count }
            let shown = passesNoise(host: flow.host, decrypted: flow.decrypted)
                && (urlTerms.isEmpty || urlTerms.matches(flow.url))
            return shown ? count : count + 1
        }
    }
}

/// 左栏的数字：一次遍历算完，存起来，别每次重绘都重算。
struct SidebarCounts: Equatable, Sendable {
    struct HostCount: Equatable, Sendable {
        let host: String
        let count: Int
    }

    /// 「全部」那一行：所有来源里没被藏的。
    var total = 0
    /// 每个来源没被藏的条数。
    var byDevice: [String: Int] = [:]
    /// 当前来源（`filter.device`）下各域名没被藏的条数，多的在前、同数按名字。
    var hosts: [HostCount] = []

    /// 只看「藏噪音」和来源，不看左栏选中的域名、方法、状态码、「过滤 URL」。
    static func compute<S: Sequence>(_ flows: S, filter: FlowFilter) -> SidebarCounts where S.Element: FilterableFlow {
        var counts = SidebarCounts()
        var perHost: [String: Int] = [:]
        for flow in flows where filter.passesNoise(host: flow.host, decrypted: flow.decrypted) {
            counts.total += 1
            counts.byDevice[flow.deviceKey, default: 0] += 1
            if filter.device == nil || filter.device == flow.deviceKey {
                perHost[flow.host, default: 0] += 1
            }
        }
        counts.hosts = perHost.map { HostCount(host: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.host < $1.host }
        return counts
    }
}
