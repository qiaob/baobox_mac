import AppKit
import SwiftUI

// 快速入口建议行（docs/launcher/TECH_DESIGN.md §5.4、§5.5）用到的视图小件：颜色值那几行的色块、
// 输入框左边挂着的图片标签、图片条目行首的缩略图。
// 单独一个文件，`LauncherViews.swift` 里只留接入点。（「搜文件名含…」换输入框用的是 `LauncherFieldHandle.replaceText`。）

/// 输入框左边挂着的图片标签的内容。
struct LauncherAttachmentChip {
    /// 缩略图；还没解出来时为 nil（先显示一个图片图标）。
    var thumbnail: NSImage?
    /// 像素尺寸「1280×720」；还没读出来时为 nil。
    var sizeText: String?
}

/// 挂着的图片：圆角小标签，缩略图约 28pt 高（按比例，最宽 56pt），右边一行小字是像素尺寸。⌫（输入框为空时）/ Esc 去掉。
struct LauncherAttachmentChipView: View {
    let chip: LauncherAttachmentChip

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let thumbnail = chip.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 56, maxHeight: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
            }
            if let size = chip.sizeText {
                Text(verbatim: size)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(3)
        .padding(.trailing, chip.sizeText == nil ? 0 : 4)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .help(chip.sizeText ?? "")
    }
}

/// 图片条目行首的缩略图：26 × 26 的圆角方块，按比例铺满后裁掉多出来的（同命令图标底的大小和圆角）。
struct LauncherThumbnailIcon: View {
    let image: NSImage
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: 26, height: 26)
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? Color.white.opacity(0.7) : Color.primary.opacity(0.15), lineWidth: 1))
    }
}

/// 颜色值建议行的行首图标：这个颜色的圆角方块（同命令图标底的大小和圆角）。带透明度时下面垫一层棋盘格，
/// 看得出是半透明；细描边让白色、很浅的颜色在浅色面板上也有边。
struct LauncherColorSwatch: View {
    let color: LauncherColor
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack {
            if color.hasAlpha {
                LauncherCheckerboard()
            }
            Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
        }
        .frame(width: 26, height: 26)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? Color.white.opacity(0.7) : Color.primary.opacity(0.18), lineWidth: 1))
    }
}

/// 透明色块下面的棋盘格（4 × 4）。
private struct LauncherCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell = size.width / 4
            for row in 0..<4 {
                for column in 0..<4 {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    let shade = (row + column).isMultiple(of: 2) ? Color.white : Color(white: 0.8)
                    context.fill(Path(rect), with: .color(shade))
                }
            }
        }
    }
}
