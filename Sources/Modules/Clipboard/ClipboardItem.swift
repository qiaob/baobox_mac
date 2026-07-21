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

    /// 用于去重的内容签名（图片按文件名，其余按文本）。
    var contentSignature: String {
        switch type {
        case .image: return "image:\(imageFilename ?? "")"
        default: return "\(type.rawValue):\(text ?? "")"
        }
    }
}
