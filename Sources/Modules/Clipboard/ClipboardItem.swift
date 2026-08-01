import Foundation

enum ClipboardItemType: String, Codable {
    case text
    case link
    case image
    case file
}

struct ClipboardItem: Codable, Identifiable, Equatable {
    let id: UUID
    let type: ClipboardItemType
    /// text/link：内容；file：路径（多文件以 \n 分隔）
    var text: String?
    /// image：Application Support/Baobox/ClipboardImages 下的相对文件名
    var imageFilename: String?
    let sourceAppName: String?
    let sourceBundleID: String?
    /// 说明：规格中为 let；因为去重时需刷新时间戳，这里改为 var 以保持 id 稳定。
    var createdAt: Date
    var isPinned: Bool
    /// 来源把内容标记为敏感（org.nspasteboard.ConcealedType，典型是 1Password 等密码管理器）。
    /// 仅当用户在设置里显式开启「记录敏感内容」时才会入库，面板里默认打码显示。
    var isConcealed: Bool

    /// 用于去重的内容签名（图片按文件名，其余按文本）。
    var contentSignature: String {
        switch type {
        case .image: return "image:\(imageFilename ?? "")"
        default: return "\(type.rawValue):\(text ?? "")"
        }
    }

    // 手写 CodingKeys + init(from:)：`isConcealed` 是后加的字段，老的 clipboard.json
    // 里没有这个键，合成的 Decodable 实现会整份解码失败 → 用户历史全部清空。
    private enum CodingKeys: String, CodingKey {
        case id, type, text, imageFilename, sourceAppName, sourceBundleID, createdAt, isPinned, isConcealed
    }

    init(id: UUID, type: ClipboardItemType, text: String?, imageFilename: String?,
         sourceAppName: String?, sourceBundleID: String?, createdAt: Date,
         isPinned: Bool, isConcealed: Bool = false) {
        self.id = id
        self.type = type
        self.text = text
        self.imageFilename = imageFilename
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isConcealed = isConcealed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(ClipboardItemType.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        imageFilename = try container.decodeIfPresent(String.self, forKey: .imageFilename)
        sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isConcealed = try container.decodeIfPresent(Bool.self, forKey: .isConcealed) ?? false
    }
}
