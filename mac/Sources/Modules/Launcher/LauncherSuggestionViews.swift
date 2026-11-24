import AppKit
import SwiftUI

// 快速入口建议行（docs/launcher/TECH_DESIGN.md §5.4）用到的视图小件：颜色值那几行的色块。
// 单独一个文件，`LauncherViews.swift` 里只留接入点。（「搜文件名含…」换输入框用的是 `LauncherFieldHandle.replaceText`。）

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
