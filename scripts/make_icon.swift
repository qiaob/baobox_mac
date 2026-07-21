#!/usr/bin/swift
// Baobox 应用图标生成器。
//
// 设计：Big Sur 规格圆角方（1024 画布、824 内容区、185 圆角），
// 青碧渐变底 + 翻开盖子的白色宝箱，箱口金光、金色锁扣、三颗星光 ——「打开的百宝箱」。
// 用法：swift scripts/make_icon.swift <输出.iconset 目录>
// 之后：iconutil -c icns <目录> -o Sources/Resources/AppIcon.icns

import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let tealLight = NSColor(srgbRed: 0x3E / 255.0, green: 0xD9 / 255.0, blue: 0xC9 / 255.0, alpha: 1)
let tealDark = NSColor(srgbRed: 0x0A / 255.0, green: 0x4E / 255.0, blue: 0x4C / 255.0, alpha: 1)
let deep = NSColor(srgbRed: 0x0E / 255.0, green: 0x3F / 255.0, blue: 0x3E / 255.0, alpha: 1)
let gold = NSColor(srgbRed: 1.00, green: 0.80, blue: 0.30, alpha: 1)
let goldSoft = NSColor(srgbRed: 1.00, green: 0.86, blue: 0.45, alpha: 1)

/// 四角星（sparkle）：外径 r，内腰 r*0.3。
func sparkle(cx: CGFloat, cy: CGFloat, r: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let inner = r * 0.3
    path.move(to: NSPoint(x: cx, y: cy + r))
    path.curve(to: NSPoint(x: cx + r, y: cy),
               controlPoint1: NSPoint(x: cx + inner * 0.35, y: cy + inner),
               controlPoint2: NSPoint(x: cx + inner, y: cy + inner * 0.35))
    path.curve(to: NSPoint(x: cx, y: cy - r),
               controlPoint1: NSPoint(x: cx + inner, y: cy - inner * 0.35),
               controlPoint2: NSPoint(x: cx + inner * 0.35, y: cy - inner))
    path.curve(to: NSPoint(x: cx - r, y: cy),
               controlPoint1: NSPoint(x: cx - inner * 0.35, y: cy - inner),
               controlPoint2: NSPoint(x: cx - inner, y: cy - inner * 0.35))
    path.curve(to: NSPoint(x: cx, y: cy + r),
               controlPoint1: NSPoint(x: cx - inner, y: cy + inner * 0.35),
               controlPoint2: NSPoint(x: cx - inner * 0.35, y: cy + inner))
    path.close()
    return path
}

/// 全部几何按 1024 画布书写，各尺寸通过缩放矢量重绘保证清晰。
func draw1024() {
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                          xRadius: 185, yRadius: 185)
    NSGradient(starting: tealLight, ending: tealDark)!.draw(in: bg, angle: 270)

    // 箱体
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 282, y: 210, width: 460, height: 260),
                 xRadius: 42, yRadius: 42).fill()

    // 箱口金光：先铺一层柔光，再叠实色发光条
    goldSoft.withAlphaComponent(0.4).setFill()
    NSBezierPath(roundedRect: NSRect(x: 288, y: 414, width: 448, height: 80),
                 xRadius: 40, yRadius: 40).fill()
    goldSoft.setFill()
    NSBezierPath(roundedRect: NSRect(x: 302, y: 428, width: 420, height: 52),
                 xRadius: 26, yRadius: 26).fill()

    // 翻开的箱盖（绕左侧铰点转起），内衬压一层浅色
    NSGraphicsContext.current!.cgContext.saveGState()
    let tilt = NSAffineTransform()
    tilt.translateX(by: 284, yBy: 470)
    tilt.rotate(byDegrees: 28)
    tilt.concat()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: -10, y: 0, width: 460, height: 150),
                 xRadius: 54, yRadius: 54).fill()
    deep.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: NSRect(x: 24, y: 26, width: 392, height: 98),
                 xRadius: 40, yRadius: 40).fill()
    NSGraphicsContext.current!.cgContext.restoreGState()

    // 金色锁扣 + 锁点
    gold.setFill()
    NSBezierPath(roundedRect: NSRect(x: 478, y: 386, width: 68, height: 94),
                 xRadius: 20, yRadius: 20).fill()
    deep.setFill()
    NSBezierPath(ovalIn: NSRect(x: 496, y: 424, width: 32, height: 32)).fill()

    // 星光
    gold.setFill()
    sparkle(cx: 712, cy: 668, r: 74).fill()
    sparkle(cx: 560, cy: 760, r: 44).fill()
    sparkle(cx: 790, cy: 540, r: 34).fill()
}

func writePNG(pixels: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw1024()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent(name))
}

for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                    (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    writePNG(pixels: pt * scale, name: name)
}
print("iconset 已生成：\(outDir.path)")
