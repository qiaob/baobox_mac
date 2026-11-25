import AppKit
import CoreText

/// 文字工具的图标：自己画的大写「T」（截图标注与屏幕标注画笔的工具条共用）。
///
/// 不用系统符号 `textformat`：它跟着系统语言变，中文下画出来是「格式」两个字，
/// 夹在一排图形图标里像一段文案，认不出是文字工具。
enum AnnotationTextToolIcon {
    /// - Parameter pointSize: 与同一排系统符号相同的字号；「T」按字形轮廓画，上下左右居中。
    static func image(pointSize: CGFloat = 13, accessibilityDescription: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: pointSize + 2, weight: .regular) as CTFont
        var character: UniChar = 0x54  // "T"
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
              let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
            // 取不到字形（不该发生）：退回不随语言变的带框 T。
            return NSImage(systemSymbolName: "t.square", accessibilityDescription: accessibilityDescription)
                ?? NSImage()
        }
        let box = path.boundingBoxOfPath
        let size = NSSize(width: ceil(box.width) + 2, height: ceil(box.height) + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: (rect.width - box.width) / 2 - box.minX,
                                y: (rect.height - box.height) / 2 - box.minY)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        // 模板图：颜色跟按钮的 contentTintColor（未选中 / 选中）走。
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
