import Compression
import Foundation

/// HTTP/1.1 增量解析与 body 解压展示。
///
/// 说明：本模块只解析 HTTP/1.1 明文（TLS 已由上层终止，进来的是明文字节）。HTTP/2、
/// WebSocket、QUIC 不在解析范围（上层透传）。解析失败只丢该 flow 的解析结果，连接仍尽量透传。

// MARK: - 解析结果

/// 一条完整解析出的 HTTP 消息（请求或响应）。
struct ParsedHTTPMessage {
    /// 请求行 / 响应行原文。
    var startLine: String = ""
    var headers: [HTTPHeader] = []
    var body: Data = Data()
    /// body 是否因超上限被截断（截断后不再缓存，但转发不截断）。
    var truncated: Bool = false
    /// 消费掉的原始字节数（用于中继时定位边界）。
    var consumedBytes: Int = 0

    // 请求专用解析
    var method: String {
        startLine.split(separator: " ").first.map(String.init) ?? ""
    }
    var requestTarget: String {
        let parts = startLine.split(separator: " ")
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    // 响应专用解析
    var statusCode: Int? {
        let parts = startLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
}

// MARK: - 增量解析器

/// HTTP/1.1 增量解析器：喂入字节，产出消息。状态机：startLine → headers → body → done。
///
/// 用法：`feed(_:)` 追加字节后反复调用 `nextMessage()` 取出已完成的消息（keep-alive 下一条数据流
/// 可能含多条消息）。捕获副本受 `bodyCap` 限制；超限停缓存并标 truncated（转发由上层负责，不截断）。
final class HTTPParser {

    enum Role { case request, response }

    private let role: Role
    private let bodyCap: Int
    private var buffer = Data()

    /// 上一条请求的方法（用于响应无 body 语义判定，如 HEAD / 204 / 304）。
    var lastRequestMethod: String?

    init(role: Role, bodyCap: Int = NetCaptureEnv.bodyCap) {
        self.role = role
        self.bodyCap = bodyCap
    }

    func feed(_ data: Data) {
        buffer.append(data)
    }

    /// 尝试从缓冲区解析出下一条完整消息；不完整返回 nil（等更多字节）。
    func nextMessage() -> ParsedHTTPMessage? {
        // 找到头结束（\r\n\r\n）。
        guard let headerEnd = rangeOfHeaderTerminator(in: buffer) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            // 非法头：丢弃缓冲，避免卡死。
            buffer.removeAll(keepingCapacity: false)
            return nil
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        var message = ParsedHTTPMessage()
        message.startLine = lines.removeFirst()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            message.headers.append(HTTPHeader(name: name, value: value))
        }

        let bodyStart = headerEnd.upperBound
        let headerByteCount = bodyStart - buffer.startIndex

        // 判定 body 编码。
        let te = message.headers.value(for: "Transfer-Encoding")?.lowercased()
        let clStr = message.headers.value(for: "Content-Length")
        let hasChunked = te?.contains("chunked") ?? false

        if hasChunked {
            guard let (bodyData, consumed, truncated) = parseChunked(from: bodyStart) else { return nil }
            message.body = bodyData
            message.truncated = truncated
            message.consumedBytes = headerByteCount + consumed
            buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: message.consumedBytes))
            return message
        }

        if let clStr, let length = Int(clStr) {
            let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
            guard available >= length else { return nil } // 等更多字节
            let end = buffer.index(bodyStart, offsetBy: length)
            let full = buffer.subdata(in: bodyStart..<end)
            if length > bodyCap {
                message.body = full.prefix(bodyCap)
                message.truncated = true
            } else {
                message.body = full
            }
            message.consumedBytes = headerByteCount + length
            buffer.removeSubrange(buffer.startIndex..<end)
            return message
        }

        // 无 Content-Length / chunked：
        // - 请求：视为无 body（GET/POST 表单等应带 CL；无 CL 的请求体在代理场景罕见）。
        // - 响应：某些状态无 body（204/304/HEAD）→ 无 body；否则 body 读到连接关闭
        //   （由上层在连接结束时用 `finish()` 收尾）。
        if role == .request {
            message.consumedBytes = headerByteCount
            buffer.removeSubrange(buffer.startIndex..<bodyStart)
            return message
        }
        if bodilessResponse(message) {
            message.consumedBytes = headerByteCount
            buffer.removeSubrange(buffer.startIndex..<bodyStart)
            return message
        }
        // 响应 body 读到连接关闭：这里先不消费，交由 finish() 处理。
        return nil
    }

    /// 连接关闭时收尾：对「读到连接关闭」型响应，把缓冲区剩余头+体当作一条消息返回。
    func finish() -> ParsedHTTPMessage? {
        guard role == .response, !buffer.isEmpty else { return nil }
        guard let headerEnd = rangeOfHeaderTerminator(in: buffer) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        var message = ParsedHTTPMessage()
        message.startLine = lines.removeFirst()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            message.headers.append(HTTPHeader(name: name, value: value))
        }
        let bodyStart = headerEnd.upperBound
        let full = buffer.subdata(in: bodyStart..<buffer.endIndex)
        if full.count > bodyCap {
            message.body = full.prefix(bodyCap)
            message.truncated = true
        } else {
            message.body = full
        }
        message.consumedBytes = buffer.count
        buffer.removeAll(keepingCapacity: false)
        return message
    }

    // MARK: 辅助

    private func bodilessResponse(_ message: ParsedHTTPMessage) -> Bool {
        if lastRequestMethod?.uppercased() == "HEAD" { return true }
        if let code = message.statusCode {
            if code == 204 || code == 304 { return true }
            if (100..<200).contains(code) { return true }
        }
        return false
    }

    /// 在 data 中查找首个 `\r\n\r\n`，返回其范围（4 字节）。
    private func rangeOfHeaderTerminator(in data: Data) -> Range<Data.Index>? {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        return data.range(of: terminator)
    }

    /// 解析 chunked body，从 start 起。返回 (解码后 body, 消费字节数, 是否截断)；不完整返回 nil。
    private func parseChunked(from start: Data.Index) -> (Data, Int, Bool)? {
        var cursor = start
        var out = Data()
        var truncated = false
        while true {
            // 读一行 chunk size。
            guard let lineEnd = rangeOfCRLF(in: buffer, from: cursor) else { return nil }
            let sizeLine = buffer.subdata(in: cursor..<lineEnd.lowerBound)
            guard let sizeStr = String(data: sizeLine, encoding: .isoLatin1) else { return nil }
            // chunk-size 可能带扩展（; 后），取分号前的十六进制。
            let hex = sizeStr.split(separator: ";").first.map(String.init) ?? sizeStr
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            cursor = lineEnd.upperBound
            if size == 0 {
                // 最后一个 chunk：其后是可选 trailer + CRLF。找结尾 CRLF。
                guard let end = rangeOfCRLF(in: buffer, from: cursor) else { return nil }
                let consumed = end.upperBound - start
                return (out, consumed, truncated)
            }
            let chunkEnd = buffer.index(cursor, offsetBy: size, limitedBy: buffer.endIndex)
            guard let chunkEnd, buffer.distance(from: chunkEnd, to: buffer.endIndex) >= 2 else { return nil }
            let chunk = buffer.subdata(in: cursor..<chunkEnd)
            if out.count < bodyCap {
                let room = bodyCap - out.count
                if chunk.count > room { out.append(chunk.prefix(room)); truncated = true }
                else { out.append(chunk) }
            } else {
                truncated = true
            }
            // 跳过 chunk 后的 CRLF。
            cursor = buffer.index(chunkEnd, offsetBy: 2)
        }
    }

    private func rangeOfCRLF(in data: Data, from start: Data.Index) -> Range<Data.Index>? {
        let crlf = Data([0x0D, 0x0A])
        return data.range(of: crlf, in: start..<data.endIndex)
    }
}

// MARK: - Body 解压 / 展示

/// 依据 Content-Encoding 把 body 解码为可展示字节。仅用于「展示」，不改变转发的原始字节。
enum HTTPBodyCodec {

    /// body 解压展示附注。用具名枚举而非裸英文串：原生 UI 走 `localizedText`（本地化），
    /// 导出 / MCP 等面向 AI 的文本走 `englishText`（稳定英文）。
    enum DecodeNote: Sendable {
        case gzipFailed
        case deflateFailed
        case brotliNotDecompressed
        case otherEncodingNotDecompressed(String)

        /// 稳定英文，供 Markdown 导出 / MCP（面向 AI）。
        var englishText: String {
            switch self {
            case .gzipFailed: return "gzip decode failed"
            case .deflateFailed: return "deflate decode failed"
            case .brotliNotDecompressed: return "brotli not decompressed"
            case .otherEncodingNotDecompressed(let e): return "encoding \(e) not decompressed"
            }
        }

        /// 本地化文案，供原生 SwiftUI 详情视图。
        var localizedText: String {
            switch self {
            case .gzipFailed: return L("netcapture.body.gzipFailed")
            case .deflateFailed: return L("netcapture.body.deflateFailed")
            case .brotliNotDecompressed: return L("netcapture.body.brotli")
            case .otherEncodingNotDecompressed(let e): return L("netcapture.body.otherEncoding \(e)")
            }
        }
    }

    struct DecodedBody {
        let data: Data
        /// 展示附注（如「brotli 未解压」）；nil = 无需说明。
        let note: DecodeNote?
    }

    /// 依据头里的 Content-Encoding 解压 body。无法解压（brotli 等）时原样返回并附注。
    static func decodedForDisplay(body: Data, headers: [HTTPHeader]) -> DecodedBody {
        let encoding = headers.value(for: "Content-Encoding")?.lowercased()
            .trimmingCharacters(in: .whitespaces) ?? ""
        switch encoding {
        case "gzip", "x-gzip":
            if let out = gunzip(body) { return DecodedBody(data: out, note: nil) }
            return DecodedBody(data: body, note: .gzipFailed)
        case "deflate":
            if let out = inflateDeflate(body) { return DecodedBody(data: out, note: nil) }
            return DecodedBody(data: body, note: .deflateFailed)
        case "br":
            // 系统 Compression 框架无 brotli 解码器，原样展示大小并注明。
            return DecodedBody(data: body, note: .brotliNotDecompressed)
        case "", "identity":
            return DecodedBody(data: body, note: nil)
        default:
            return DecodedBody(data: body, note: .otherEncodingNotDecompressed(encoding))
        }
    }

    /// 解 gzip：解析 gzip 头（RFC 1952）跳过后，用 COMPRESSION_ZLIB（原始 DEFLATE）解压。
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flg = bytes[3]
        var offset = 10
        // FEXTRA
        if flg & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        // FNAME
        if flg & 0x08 != 0 {
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flg & 0x10 != 0 {
            while offset < bytes.count && bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flg & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { return nil }
        let deflateBody = data.subdata(in: (data.startIndex + offset)..<(data.endIndex - 8))
        return rawInflate(deflateBody)
    }

    /// Content-Encoding: deflate —— 规范是 zlib（RFC 1950，2 字节头），但不少服务端发裸 DEFLATE。
    /// 先尝试跳过 2 字节 zlib 头，失败再尝试裸解。
    static func inflateDeflate(_ data: Data) -> Data? {
        if data.count > 2, (data.first! & 0x0f) == 0x08 {
            let stripped = data.subdata(in: (data.startIndex + 2)..<data.endIndex)
            if let out = rawInflate(stripped) { return out }
        }
        return rawInflate(data)
    }

    /// 原始 DEFLATE（RFC 1951）解压。输出上限为 body 展示上限的若干倍，防解压炸弹。
    static func rawInflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let capacity = max(64 * 1024, min(data.count * 12, 64 * 1024 * 1024))
        var result = Data()
        let ok = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Bool in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return false }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(dst, capacity,
                                                    srcBase, data.count,
                                                    nil, COMPRESSION_ZLIB)
            guard written > 0 else { return false }
            result.append(dst, count: written)
            return true
        }
        return ok ? result : nil
    }
}
