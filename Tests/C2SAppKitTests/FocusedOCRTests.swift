import XCTest
import CoreGraphics
import AppKit
import C2SCore
@testable import C2SAppKit

/// F17 定向补刀 OCR:真实 Vision 调用,验证裁剪识别 + 坐标映射回全屏。
final class FocusedOCRTests: XCTestCase {

    /// 画一张 800×600 图,在指定点坐标写一行字(背景/文字颜色可调,模拟低对比)。
    private func makeImage(text: String, at origin: CGPoint, fontSize: CGFloat,
                           textColor: NSColor = .black,
                           background: NSColor = .white) -> CGImage {
        let size = CGSize(width: 800, height: 600)
        let ctx = CGContext(data: nil, width: 800, height: 600,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        // CGContext 左下原点:点坐标(左上原点)换算 y
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: textColor,
        ]).draw(at: NSPoint(x: origin.x, y: size.height - origin.y - fontSize * 1.3))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private var context: DisplayContext {
        DisplayContext(displayID: 1,
                       screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                       pointSize: CGSize(width: 800, height: 600),
                       pixelSize: CGSize(width: 800, height: 600),
                       scale: 1)
    }

    /// 补刀识别出的词框必须落在 focus 区域内(全屏坐标,不是裁剪区坐标)。
    func testFocusedWordsMapBackToFullScreenCoordinates() async {
        let textOrigin = CGPoint(x: 400, y: 300)
        let image = makeImage(text: "Hello World", at: textOrigin, fontSize: 16)
        let focus = CGRect(x: 360, y: 270, width: 240, height: 80)

        let ocr = OCRService()
        let words = await ocr.words(in: image, context: context, focusOn: focus)

        XCTAssertFalse(words.isEmpty, "焦点区域内有清晰文字,补刀必须认出")
        XCTAssertTrue(words.contains { $0.text.localizedCaseInsensitiveContains("hello") },
                      "应识别出 Hello,实际: \(words.map(\.text))")
        for w in words {
            XCTAssertTrue(focus.insetBy(dx: -10, dy: -10).contains(w.rect),
                          "词框 \(w.rect) 应落在焦点区域 \(focus) 内(全屏坐标)")
        }
        // id 约束(并表前提)
        XCTAssertEqual(words.map(\.id), Array(0..<words.count))
    }

    /// 焦点区域没有文字:返回空,不误报。
    func testFocusedOCRReturnsEmptyForBlankRegion() async {
        let image = makeImage(text: "Hello World", at: CGPoint(x: 400, y: 300), fontSize: 16)
        let focus = CGRect(x: 40, y: 40, width: 200, height: 100) // 远离文字的空白区

        let ocr = OCRService()
        let words = await ocr.words(in: image, context: context, focusOn: focus)
        XCTAssertTrue(words.isEmpty)
    }

    /// 低对比小字 + 小框(朋友实测场景:毛玻璃侧栏小字,台前调度背景一变
    /// 对比度就掉):裁剪 + 放大后必须仍能识别。
    func testFocusedOCRReadsSmallLowContrastText() async {
        let textOrigin = CGPoint(x: 400, y: 300)
        let image = makeImage(text: "Recents", at: textOrigin, fontSize: 11,
                              textColor: NSColor(white: 0.45, alpha: 1),
                              background: NSColor(white: 0.92, alpha: 1))
        let focus = CGRect(x: 380, y: 285, width: 120, height: 40) // 小框,minDim 40px → 4× 放大

        let ocr = OCRService()
        let words = await ocr.words(in: image, context: context, focusOn: focus)

        XCTAssertTrue(words.contains { $0.text.localizedCaseInsensitiveContains("recents") },
                      "低对比小字放大后应识别,实际: \(words.map(\.text))")
        for w in words {
            XCTAssertTrue(focus.insetBy(dx: -10, dy: -10).contains(w.rect),
                          "放大不得破坏坐标映射:词框 \(w.rect) 应在 \(focus) 内")
        }
    }

    /// 完全出图的焦点区域:安全返回空。
    func testFocusedOCROutOfBounds() async {
        let image = makeImage(text: "Hi", at: CGPoint(x: 100, y: 100), fontSize: 16)
        let focus = CGRect(x: 900, y: 700, width: 100, height: 100)

        let ocr = OCRService()
        let words = await ocr.words(in: image, context: context, focusOn: focus)
        XCTAssertTrue(words.isEmpty)
    }
}
