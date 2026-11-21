import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：认出一条原始 TCP 连接跑的是什么协议。
// 见 docs/packet-capture/CONTROL.md §4.3。
//
// 只认、不解析。先看内容特征（可靠），认不出再按端口给一个带问号的猜测。特征写得保守：宁可认不出，不要认错。
// TCP 是字节流，读到的每一段边界是任意的，所以输入是两个方向各自**累计**的前若干字节，不是第一段。

/// 认出来的协议。`guessed` = 内容认不出，只是按端口猜的（界面上名字后面带问号）。
struct TCPProtocolMatch: Equatable, Sendable {
    var name: String
    var guessed: Bool

    /// 界面上显示的名字：猜的带问号。
    var label: String { guessed ? name + "?" : name }

    /// 默认按文本显示的协议（其余默认十六进制）。SSH 的版本行是文本，后面是密文，照样按文本看得到版本行。
    var prefersText: Bool { Self.textProtocols.contains(name) }

    static let textProtocols: Set<String> = ["SMTP", "IMAP", "POP3", "FTP", "XMPP", "Redis", "SSH"]
}

enum TCPProtocol {
    /// 每个方向最多攒这么多字节来认。
    static let prefixLimit = 64

    /// 一条连接上此刻能拿来认的东西。
    struct Input: Equatable, Sendable {
        enum Side: Sendable { case client, server }

        var port: Int
        /// 解开过的 TLS 才有（这一页上的连接多半没有）。
        var sni: String?
        /// 客户端、服务器各自累计的前 `prefixLimit` 个字节。
        var client: Data
        var server: Data
        /// 客户端到目前一共发了多少字节（RTMP 的握手、DNS 的长度头要看）。
        var clientTotal: Int
        /// 谁先说的话；还没人说话是 nil。POP3（服务器先说）和 Redis 的内联命令（客户端先说）靠它分开。
        var firstSpeaker: Side?
    }

    /// 认一次。内容认得出给确定的；认不出按端口猜；都不中 nil（界面显示「未知」）。
    static func identify(_ input: Input) -> TCPProtocolMatch? {
        if let name = byContent(input) { return TCPProtocolMatch(name: name, guessed: false) }
        if let name = byPort(input.port) { return TCPProtocolMatch(name: name, guessed: true) }
        return nil
    }

    // MARK: - 内容特征

    static func byContent(_ input: Input) -> String? {
        let client = [UInt8](input.client.prefix(prefixLimit))
        let server = [UInt8](input.server.prefix(prefixLimit))

        if isSSH(client) || isSSH(server) { return "SSH" }
        if isMQTT(client) { return "MQTT" }
        if starts(client, "AMQP", then: [0x00]) || starts(server, "AMQP", then: [0x00]) { return "AMQP" }
        if isMySQL(server) { return "MySQL" }
        if isPostgres(client) { return "PostgreSQL" }
        if isRESP(client) || (input.firstSpeaker == .client && isRedisInline(client)) { return "Redis" }
        if isMongo(client) { return "MongoDB" }
        if let greeting = serverGreeting(server, input: input) { return greeting }
        if isXMPP(client) || isXMPP(server) { return "XMPP" }
        if starts(client, [0x13] + Array("BitTorrent protocol".utf8)) { return "BitTorrent" }
        if starts(client, [0x16, 0xF1, 0x04]) { return "mmtls" }
        if isTLS(client) { return "TLS" }
        if isRTMP(client: client, server: server, clientTotal: input.clientTotal) { return "RTMP" }
        if input.port == 53, isDNS(client, total: input.clientTotal) { return "DNS" }
        if let sni = input.sni?.lowercased(), sni == "mtalk.google.com" || sni.hasSuffix(".mtalk.google.com") {
            return "FCM"
        }
        return nil
    }

    /// `SSH-<版本号>.` 开头（`SSH-2.0-OpenSSH_9.6`）。
    private static func isSSH(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 6, starts(bytes, "SSH-") else { return false }
        return isDigit(bytes[4]) && bytes[5] == UInt8(ascii: ".")
    }

    /// CONNECT 报文：首字节 0x10，剩余长度（1–4 字节变长），然后是协议名 `MQTT`（3.1.1 / 5）或 `MQIsdp`（3.1）。
    private static func isMQTT(_ bytes: [UInt8]) -> Bool {
        guard bytes.first == 0x10 else { return false }
        var index = 1
        var length = 0
        var multiplier = 1
        while true {
            guard index < bytes.count, index <= 4 else { return false }
            let byte = bytes[index]
            length += Int(byte & 0x7F) * multiplier
            multiplier *= 128
            index += 1
            if byte & 0x80 == 0 { break }
        }
        guard length >= 10 else { return false }
        let rest = Array(bytes[index...])
        return starts(rest, [0x00, 0x04] + Array("MQTT".utf8)) || starts(rest, [0x00, 0x06] + Array("MQIsdp".utf8))
    }

    /// 服务器的握手包：3 字节长度（小端）+ 序号 0 + 协议版本 0x0a + 以 0 结尾、数字开头的版本字符串。
    private static func isMySQL(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 8, bytes[3] == 0x00, bytes[4] == 0x0A else { return false }
        let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16
        guard (20...1024).contains(length), isDigit(bytes[5]) else { return false }
        // 版本字符串形如 `8.0.33`、`5.5.5-10.11.6-MariaDB-0+deb12u1`：可打印、不带空格。
        guard let end = bytes[5...].firstIndex(of: 0x00), end > 5 else { return false }
        return bytes[5..<end].allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// 启动报文（长度 + 协议号 3.0 = 0x00030000）或 SSLRequest（长度 8 + 0x04d2162f）。
    private static func isPostgres(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 8 else { return false }
        let length = bigEndian32(bytes, at: 0)
        let code = bigEndian32(bytes, at: 4)
        if code == 0x04D2_162F { return length == 8 }
        return code == 0x0003_0000 && (9...10_000).contains(length)
    }

    /// RESP 数组：`*<数字>\r\n$<数字>`。只凭首字节是 `*` 不算。
    private static func isRESP(_ bytes: [UInt8]) -> Bool {
        guard bytes.first == UInt8(ascii: "*") else { return false }
        var index = 1
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        guard index > 1, index + 3 < bytes.count else { return false }
        return bytes[index] == 0x0D && bytes[index + 1] == 0x0A && bytes[index + 2] == UInt8(ascii: "$")
            && isDigit(bytes[index + 3])
    }

    /// 内联命令 `PING\r\n`、`AUTH …`。只在客户端先说话时认（POP3 的客户端也会发 AUTH，但那是服务器先打招呼）。
    private static func isRedisInline(_ bytes: [UInt8]) -> Bool {
        starts(bytes, "PING\r\n") || (starts(bytes, "AUTH ") && bytes.count > 5 && bytes[5] > 0x20 && bytes[5] < 0x7F)
    }

    /// 消息头 16 字节：长度、请求号、responseTo（请求里是 0）、opCode = 2013（OP_MSG）或 2004（OP_QUERY），都是小端。
    private static func isMongo(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 16 else { return false }
        let length = littleEndian32(bytes, at: 0)
        let responseTo = littleEndian32(bytes, at: 8)
        let opCode = littleEndian32(bytes, at: 12)
        return (opCode == 2013 || opCode == 2004) && responseTo == 0 && (21...48_000_000).contains(length)
    }

    /// 服务器先打招呼的文本协议。
    private static func serverGreeting(_ server: [UInt8], input: Input) -> String? {
        guard !server.isEmpty else { return nil }
        let text = String(decoding: server, as: UTF8.self)
        let upper = text.uppercased()
        if text.hasPrefix("220 ") || text.hasPrefix("220-") {
            if upper.contains("SMTP") { return "SMTP" }
            if upper.contains("FTP") { return "FTP" }
            return nil
        }
        if text.hasPrefix("* OK") { return "IMAP" }
        // `+OK` 也是 Redis 的回答；只有服务器先说话时才是 POP3 的招呼。
        if text.hasPrefix("+OK"), input.firstSpeaker == .server { return "POP3" }
        return nil
    }

    /// `<stream:stream` 开头，或 `<?xml` 开头且后面跟着 `<stream`。只有 `<?xml` 的（SOAP 之类）不算。
    private static func isXMPP(_ bytes: [UInt8]) -> Bool {
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix("<stream:stream") { return true }
        return text.hasPrefix("<?xml") && text.contains("<stream")
    }

    /// TLS 记录头 `16 03 0x` + 长度，里面是 ClientHello（握手类型 1）。
    private static func isTLS(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 6, bytes[0] == 0x16, bytes[1] == 0x03, bytes[2] <= 0x04 else { return false }
        return bytes[5] == 0x01
    }

    /// 握手：客户端先发 C0（0x03）+ C1（1536 字节），共 1537 字节；服务器回话的话首字节也是 0x03。
    private static func isRTMP(client: [UInt8], server: [UInt8], clientTotal: Int) -> Bool {
        guard client.first == 0x03, clientTotal >= 1537 else { return false }
        return server.isEmpty || server.first == 0x03
    }

    /// DNS over TCP：前两个字节是后面这条消息的长度（≥ 12 字节的头），头里问题数 1–16，且整条消息已经到齐。
    private static func isDNS(_ bytes: [UInt8], total: Int) -> Bool {
        guard bytes.count >= 14 else { return false }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        let questions = Int(bytes[6]) << 8 | Int(bytes[7])
        return length >= 12 && (1...16).contains(questions) && total >= length + 2
    }

    // MARK: - 端口提示

    static func byPort(_ port: Int) -> String? {
        switch port {
        case 22: return "SSH"
        case 25, 465, 587: return "SMTP"
        case 110, 995: return "POP3"
        case 143, 993: return "IMAP"
        case 1883, 8883: return "MQTT"
        case 3306: return "MySQL"
        case 5432: return "PostgreSQL"
        case 6379: return "Redis"
        case 27017: return "MongoDB"
        case 5222, 5223: return "XMPP"
        case 5228...5230: return "FCM"
        case 5671, 5672: return "AMQP"
        case 1935: return "RTMP"
        default: return nil
        }
    }

    // MARK: - 小工具

    private static func starts(_ bytes: [UInt8], _ text: String, then tail: [UInt8] = []) -> Bool {
        starts(bytes, Array(text.utf8) + tail)
    }

    private static func starts(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func bigEndian32(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16 | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
    }

    private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index]) | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 24
    }
}
