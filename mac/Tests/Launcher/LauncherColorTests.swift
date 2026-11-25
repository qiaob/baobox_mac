import Foundation
import XCTest

/// 快速入口认颜色值、写成 HEX / RGB / HSL 三种写法（docs/launcher/TECH_DESIGN.md §5.4）。
final class LauncherColorTests: XCTestCase {

    private func formats(_ text: String) -> [String]? {
        guard let color = LauncherColor.parse(text) else { return nil }
        return [color.hexString, color.rgbString, color.hslString]
    }

    // MARK: - HEX

    func testSixDigitHex() {
        XCTAssertEqual(formats("#17A398"), ["#17A398", "rgb(23, 163, 152)", "hsl(175, 75%, 36%)"])
        XCTAssertEqual(formats("#17a398"), ["#17A398", "rgb(23, 163, 152)", "hsl(175, 75%, 36%)"], "小写也认，写出来是大写")
        XCTAssertEqual(formats("#2BC4B8")?.first, "#2BC4B8")
    }

    func testThreeDigitHexExpands() {
        XCTAssertEqual(formats("#fff"), ["#FFFFFF", "rgb(255, 255, 255)", "hsl(0, 0%, 100%)"])
        XCTAssertEqual(formats("#000"), ["#000000", "rgb(0, 0, 0)", "hsl(0, 0%, 0%)"])
        XCTAssertEqual(formats("#f00"), ["#FF0000", "rgb(255, 0, 0)", "hsl(0, 100%, 50%)"])
        XCTAssertEqual(formats("#0F0")?[1], "rgb(0, 255, 0)")
    }

    func testEightDigitHexHasAlpha() {
        XCTAssertEqual(formats("#17A39880"), ["#17A39880", "rgba(23, 163, 152, 0.5)", "hsla(175, 75%, 36%, 0.5)"])
        XCTAssertEqual(formats("#17A398FF"), ["#17A398", "rgb(23, 163, 152)", "hsl(175, 75%, 36%)"], "FF = 不透明，不写透明度")
        XCTAssertEqual(formats("#00000000")?[1], "rgba(0, 0, 0, 0)")
    }

    func testInvalidHex() {
        for text in ["#", "#1", "#12", "#1234", "#12345", "#1234567", "#123456789", "#GGG", "#12345G", "##123456",
                     "# 123456", "#１２３", "123456", "#ff ", "#ff\u{0}"] {
            XCTAssertNil(LauncherColor.parse(text), text)
        }
    }

    // MARK: - rgb()

    func testRGBCommaSyntax() {
        XCTAssertEqual(formats("rgb(23, 163, 152)"), ["#17A398", "rgb(23, 163, 152)", "hsl(175, 75%, 36%)"])
        XCTAssertEqual(formats("rgb(23,163,152)")?.first, "#17A398")
        XCTAssertEqual(formats("RGB( 23 , 163 , 152 )")?.first, "#17A398")
        XCTAssertEqual(formats("rgba(23, 163, 152, 0.5)")?[1], "rgba(23, 163, 152, 0.5)")
        XCTAssertEqual(formats("rgba(23, 163, 152, 1)")?[1], "rgb(23, 163, 152)")
        XCTAssertEqual(formats("rgb(23, 163, 152, 50%)")?[1], "rgba(23, 163, 152, 0.5)", "rgb() 也能带第四个值")
        XCTAssertEqual(formats("rgba(23, 163, 152)")?[1], "rgb(23, 163, 152)", "rgba() 不带透明度也认")
        XCTAssertEqual(formats("rgb(100%, 0%, 50%)")?.first, "#FF0080")
        XCTAssertEqual(formats("rgb(127.5, 0, 0)")?.first, "#800000")
        XCTAssertEqual(formats("rgba(0, 0, 0, .25)")?[1], "rgba(0, 0, 0, 0.25)")
    }

    func testRGBSpaceSyntax() {
        XCTAssertEqual(formats("rgb(23 163 152)")?.first, "#17A398")
        XCTAssertEqual(formats("rgb(23 163 152 / 50%)")?[1], "rgba(23, 163, 152, 0.5)")
        XCTAssertEqual(formats("rgb(23 163 152/0.5)")?[1], "rgba(23, 163, 152, 0.5)")
        XCTAssertEqual(formats("rgb(  23   163   152  )")?.first, "#17A398")
    }

    func testInvalidRGB() {
        for text in ["rgb()", "rgb(1, 2)", "rgb(1, 2, 3, 4, 5)", "rgb(256, 0, 0)", "rgb(300, 0, 0)", "rgb(-1, 0, 0)",
                     "rgb(101%, 0, 0)", "rgb(a, b, c)", "rgb(1, 2, 3", "rgb 1, 2, 3)", "rgb(1,, 2, 3)",
                     "rgb(1, 2, 3, 2)", "rgb(1, 2, 3, 150%)", "rgb(1 2 3 / 0.5 / 1)", "rgb(1, 2 3)", "rgb(1, 2, 3 / 0.5)",
                     "rgb(1 2)", "rgb(1 2 3 4)", "rgb(1e2, 0, 0)", "rgb(inf, 0, 0)", "rgb(nan, 0, 0)", "rgb(+1, 0, 0)",
                     "rgb(1., 0, 0)", "rgb((1), 2, 3)", "rgbx(1, 2, 3)", "rgb(1, 2, 3) extra", "color(1, 2, 3)",
                     "rgb(1 2 3 /)"] {
            XCTAssertNil(LauncherColor.parse(text), text)
        }
    }

    // MARK: - hsl()

    func testHSL() {
        XCTAssertEqual(formats("hsl(175, 75%, 36%)")?.last, "hsl(175, 75%, 36%)")
        XCTAssertEqual(formats("hsl(0, 100%, 50%)"), ["#FF0000", "rgb(255, 0, 0)", "hsl(0, 100%, 50%)"])
        XCTAssertEqual(formats("hsl(120, 100%, 25%)")?.first, "#008000")
        XCTAssertEqual(formats("hsl(240 100% 50%)")?.first, "#0000FF")
        XCTAssertEqual(formats("hsl(240deg 100% 50%)")?.first, "#0000FF")
        XCTAssertEqual(formats("hsl(-120, 100%, 50%)")?.first, "#0000FF", "负的色相折回 0..<360")
        XCTAssertEqual(formats("hsl(480, 100%, 50%)")?.first, "#00FF00", "超过 360 也折回")
        XCTAssertEqual(formats("hsl(175, 75, 36)")?.last, "hsl(175, 75%, 36%)", "% 可写可不写")
        XCTAssertEqual(formats("hsla(175, 75%, 36%, 0.5)")?.last, "hsla(175, 75%, 36%, 0.5)")
        XCTAssertEqual(formats("HSLA(175 75% 36% / 25%)")?.last, "hsla(175, 75%, 36%, 0.25)")
        XCTAssertEqual(formats("hsl(0, 0%, 50%)")?.first, "#808080")
    }

    func testInvalidHSL() {
        for text in ["hsl()", "hsl(10, 50%)", "hsl(10, 200%, 50%)", "hsl(10, 50%, 101%)", "hsl(10, -5%, 50%)",
                     "hsl(abc, 50%, 50%)", "hsl(10turn, 50%, 50%)", "hsl(10, 50%, 50%, 2)", "hsl(--10, 50%, 50%)",
                     "hsl(10 50% 50% / 0.5 / 1)", "hsx(10, 50%, 50%)"] {
            XCTAssertNil(LauncherColor.parse(text), text)
        }
    }

    // MARK: - 分量、往返

    func testComponentsAreClampedAndRoundTrip() {
        let color = LauncherColor(red: 2, green: -1, blue: .nan, alpha: 5)
        XCTAssertEqual(color, LauncherColor(red: 1, green: 0, blue: 0, alpha: 1))

        for hex in ["#17A398", "#2BC4B8", "#FF8800", "#123456", "#ABCDEF", "#7F7F7F"] {
            guard let parsed = LauncherColor.parse(hex) else { return XCTFail(hex) }
            XCTAssertEqual(LauncherColor.parse(parsed.rgbString)?.hexString, hex, "RGB 写法再读回来是同一个颜色：\(hex)")
            let (h, s, l) = parsed.hsl
            let back = LauncherColor.fromHSL(hue: h, saturation: s, lightness: l)
            XCTAssertEqual(back.hexString, hex, "HSL 分量再换回 RGB：\(hex)")
        }
    }

    func testAlphaText() {
        XCTAssertEqual(LauncherColor.alphaText(0.5), "0.5")
        XCTAssertEqual(LauncherColor.alphaText(0.25), "0.25")
        XCTAssertEqual(LauncherColor.alphaText(0.333), "0.33")
        XCTAssertEqual(LauncherColor.alphaText(1), "1")
        XCTAssertEqual(LauncherColor.alphaText(0), "0")
        XCTAssertEqual(LauncherColor.alphaText(0.1), "0.1")
    }

    func testLongInputIsRejectedEarly() {
        XCTAssertNil(LauncherColor.parse("rgb(" + String(repeating: "1, ", count: 100) + "1)"))
    }
}
