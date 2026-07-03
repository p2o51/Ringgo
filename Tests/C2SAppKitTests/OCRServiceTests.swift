import XCTest
import CoreGraphics
import CoreText
import AppKit
@testable import C2SAppKit
@testable import C2SCore

/// 端到端 OCR 冒烟(移植自 docs/reference/VisionWordSelection.reference.swift):
/// 渲染已知内容 → OCRService 词级框 → 断言词数/中文/坐标合理。真 Vision,较慢。
final class OCRServiceTests: XCTestCase {

    private static let W = 1000, H = 760

    private func makeTestImage() -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Self.W, height: Self.H, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: Self.W, height: Self.H))

        func drawLine(_ text: String, x: CGFloat, yFromBottom: CGFloat, size: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attr: [NSAttributedString.Key: Any] = [.font: font,
                                                       .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attr))
            ctx.textPosition = CGPoint(x: x, y: yFromBottom)
            CTLineDraw(line, ctx)
        }

        drawLine("Circle to Search", x: 60, yFromBottom: 690, size: 40)
        let para = "The quick brown fox jumps over the lazy dog while machine learning models recognize printed text"
        drawLine(para, x: 60, yFromBottom: 560, size: 18)
        drawLine("本地文字识别测试", x: 60, yFromBottom: 330, size: 34)
        // 无文字的"图片"区(蓝色方块)
        ctx.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 60, width: 300, height: 200))
        return ctx.makeImage()!
    }

    func testWordsEndToEnd() async {
        let image = makeTestImage()
        // 1:1 上下文(点 == 像素),隔离坐标换算,专注词框提取
        let context = DisplayContext(displayID: 0,
                                     screenFrame: CGRect(x: 0, y: 0, width: Self.W, height: Self.H),
                                     pointSize: CGSize(width: Self.W, height: Self.H),
                                     pixelSize: CGSize(width: Self.W, height: Self.H),
                                     scale: 1)
        let service = OCRService()
        let words = await service.words(in: image, context: context)

        XCTAssertGreaterThanOrEqual(words.count, 15, "至少识别出标题+段落的词,实际 \(words.count)")
        XCTAssertEqual(words.map(\.id), Array(0..<words.count), "id 必须是 0..<count(引擎前提)")

        // 词框在覆盖层坐标范围内
        for w in words {
            XCTAssertTrue(w.rect.minX >= -5 && w.rect.maxX <= CGFloat(Self.W) + 5, "\(w.text) x 越界: \(w.rect)")
            XCTAssertTrue(w.rect.minY >= -5 && w.rect.maxY <= CGFloat(Self.H) + 5, "\(w.text) y 越界: \(w.rect)")
        }

        // 标题在图像上部(翻 Y 正确的关键信号):CG 底部 690 → 顶部约 760-690-40 ≈ 30
        if let title = words.first(where: { $0.text.lowercased() == "circle" }) {
            XCTAssertLessThan(title.rect.midY, 120, "标题应在顶部,翻 Y 错误会跑到底部: \(title.rect)")
        } else {
            XCTFail("没识别到标题词 Circle: \(words.map(\.text))")
        }

        // 中文词(约 2 字块)
        let cjk = words.filter { $0.text.unicodeScalars.contains { $0.value > 0x2E00 } }
        XCTAssertFalse(cjk.isEmpty, "必须识别出中文词块")

        // 蓝色图片区内不应有词(0 命中 → 路由图搜的前提)
        let imageArea = CGRect(x: 60, y: CGFloat(Self.H) - 60 - 200, width: 300, height: 200)
        let inImage = words.filter { imageArea.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
        XCTAssertTrue(inImage.isEmpty, "图片区不应识别出词: \(inImage.map(\.text))")

        // 与 SelectionEngine 集成:沿段落划一笔能选中词
        let engine = SelectionEngine(words: words)
        if let quick = words.first(where: { $0.text.lowercased() == "quick" }),
           let fox = words.first(where: { $0.text.lowercased() == "fox" }) {
            let sel = engine.brushSelection(path: [CGPoint(x: quick.rect.midX, y: quick.rect.midY),
                                                   CGPoint(x: fox.rect.midX, y: fox.rect.midY)])
            let texts = sel.map { $0.text.lowercased() }
            XCTAssertTrue(texts.contains("quick") && texts.contains("fox"),
                          "划过 quick→fox 必须包含两端: \(texts)")
        } else {
            XCTFail("没识别到 quick/fox: \(words.map(\.text))")
        }
    }

    func testSameImageCacheReturnsSameResult() async {
        let image = makeTestImage()
        let context = DisplayContext(displayID: 0,
                                     screenFrame: CGRect(x: 0, y: 0, width: Self.W, height: Self.H),
                                     pointSize: CGSize(width: Self.W, height: Self.H),
                                     pixelSize: CGSize(width: Self.W, height: Self.H),
                                     scale: 1)
        let service = OCRService()
        let first = await service.words(in: image, context: context)
        let second = await service.words(in: image, context: context)
        XCTAssertEqual(first.map(\.text), second.map(\.text), "同图缓存/重算结果必须一致")
    }
}
