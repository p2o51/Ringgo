import XCTest
import CoreGraphics
@testable import C2SAppKit
@testable import C2SCore

@MainActor
final class SelectionViewModelTests: XCTestCase {

    private let viewport = CGSize(width: 300, height: 300)

    private var word: OCRWord {
        OCRWord(id: 0,
                text: "alpha",
                rect: CGRect(x: 80, y: 90, width: 40, height: 20),
                block: 0)
    }

    func testDragPastThresholdFinishesAsBrushInsteadOfTap() {
        let model = SelectionViewModel()
        model.prepare(viewport: viewport)
        model.updateWords([word])

        let start = CGPoint(x: 10, y: 100)
        let end = CGPoint(x: 100, y: 100)
        model.dragChanged(location: end, start: start)
        model.dragEnded(location: end, start: start)

        XCTAssertEqual(model.selectedText, "alpha")
    }

    /// v3:OCR 完成前的轻点先挂起;词框到达后**点在词上才选词**,
    /// 点在空白(即使矩形里有词)→ 矩形 → 图搜(框 = 图,2026-07-03 拍板)。
    func testPendingTapOnEmptyAreaRoutesToImageAfterOCR() {
        let model = SelectionViewModel()
        model.prepare(viewport: viewport)

        var textQueries: [String] = []
        var imageRects: [CGRect] = []
        model.onTextSearch = { textQueries.append($0) }
        model.onImageSearch = { imageRects.append($0) }

        let tap = CGPoint(x: 150, y: 150) // 不在 alpha(80,90,40,20)上,但默认矩形会罩住它
        model.dragEnded(location: tap, start: tap)

        XCTAssertTrue(textQueries.isEmpty)
        XCTAssertTrue(imageRects.isEmpty, "OCR 未完成不得抢跑路由")

        model.updateWords([word])

        XCTAssertTrue(textQueries.isEmpty, "矩形含词也不得翻转成文字搜索(框=图)")
        XCTAssertEqual(imageRects.count, 1)
    }

    func testPendingTapOnWordResolvesToTextAfterOCR() {
        let model = SelectionViewModel()
        model.prepare(viewport: viewport)

        var textQueries: [String] = []
        var imageRects: [CGRect] = []
        model.onTextSearch = { textQueries.append($0) }
        model.onImageSearch = { imageRects.append($0) }

        let tap = CGPoint(x: 100, y: 100) // 正落在 alpha 词框内
        model.dragEnded(location: tap, start: tap)
        model.updateWords([word])

        XCTAssertEqual(textQueries, ["alpha"], "OCR 后应按原始意图选词")
        XCTAssertTrue(imageRects.isEmpty)
        XCTAssertEqual(model.selectedText, "alpha")
    }

    func testRectSelectionRoutesToImageAfterEmptyOCRResult() {
        let model = SelectionViewModel()
        model.prepare(viewport: viewport)

        var imageRects: [CGRect] = []
        model.onImageSearch = { imageRects.append($0) }

        let tap = CGPoint(x: 150, y: 150)
        model.dragEnded(location: tap, start: tap)
        XCTAssertTrue(imageRects.isEmpty)

        model.updateWords([])
        XCTAssertEqual(imageRects.count, 1)
    }
}
