import XCTest
import C2SCore
@testable import C2SAppKit

/// 选区类型切换(迷你工具条「改选」chip):文字 ⇄ 图片。
@MainActor
final class SelectionSwitchTests: XCTestCase {

    private func makeViewModel(words: [OCRWord]) -> SelectionViewModel {
        let vm = SelectionViewModel()
        vm.prepare(viewport: CGSize(width: 800, height: 600))
        vm.updateWords(words)
        return vm
    }

    /// 文字选区 → 图片框:外接框外扩转矩形,发一次图搜,原词框全在新框内。
    func testSwitchTextSelectionToImage() {
        let wordRect = CGRect(x: 100, y: 100, width: 40, height: 16)
        let vm = makeViewModel(words: [OCRWord(id: 0, text: "你好", rect: wordRect, block: 0)])
        var imageRects: [CGRect] = []
        var textQueries: [String] = []
        vm.onImageSearch = { imageRects.append($0) }
        vm.onTextSearch = { textQueries.append($0) }

        // 轻点词 → 文字选中
        let tap = CGPoint(x: 110, y: 108)
        vm.dragEnded(location: tap, start: tap)
        XCTAssertEqual(vm.selectedText, "你好")
        XCTAssertEqual(textQueries, ["你好"])

        vm.switchSelectionToImage()
        guard let rect = vm.rectSelection else {
            return XCTFail("切换后应为矩形选区")
        }
        XCTAssertTrue(rect.contains(wordRect), "新框应完整包住原选区")
        XCTAssertEqual(imageRects, [rect], "切换应立即发一次图搜")
        XCTAssertNil(vm.selectedText)
    }

    /// 图片框 → 文字选区:框内词(中心落框内)按阅读序整体选中,发文字搜索。
    func testSwitchImageSelectionToTextWithWords() {
        let words = [
            OCRWord(id: 0, text: "第一", rect: CGRect(x: 360, y: 240, width: 40, height: 16), block: 0),
            OCRWord(id: 1, text: "第二", rect: CGRect(x: 410, y: 240, width: 40, height: 16), block: 0),
        ]
        let vm = makeViewModel(words: words)
        var textQueries: [String] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }

        // 轻点空白(词框之外)→ 以点为中心的默认矩形,覆盖两个词
        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)
        XCTAssertNotNil(vm.rectSelection, "点空白应出矩形框")

        XCTAssertTrue(vm.switchSelectionToText())
        XCTAssertEqual(vm.selectedText, "第一第二")
        XCTAssertEqual(textQueries, ["第一第二"])
        XCTAssertNil(vm.rectSelection)
        XCTAssertNotNil(vm.textHandleAnchors, "切回文字后应有泪滴手柄")
    }

    /// 框内没有文字:返回 false,矩形选区原地不动。
    func testSwitchImageSelectionToTextWithoutWords() {
        // 有词但远在框外(框内无字比全屏无字更贴近实际场景)
        let vm = makeViewModel(words: [
            OCRWord(id: 0, text: "远处", rect: CGRect(x: 20, y: 20, width: 40, height: 16), block: 0),
        ])
        var textQueries: [String] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }

        let blank = CGPoint(x: 600, y: 450)
        vm.dragEnded(location: blank, start: blank)
        let before = vm.rectSelection
        XCTAssertNotNil(before)

        XCTAssertFalse(vm.switchSelectionToText())
        XCTAssertEqual(vm.rectSelection, before, "切换失败选区必须原地不动")
        XCTAssertTrue(textQueries.isEmpty, "不得发出文字搜索")
    }

    /// OCR 未完成(引擎缺席)时同样返回 false,不动选区。
    func testSwitchImageSelectionToTextBeforeOCR() {
        let vm = SelectionViewModel()
        vm.prepare(viewport: CGSize(width: 800, height: 600))
        vm.onImageSearch = { _ in }

        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)
        XCTAssertNotNil(vm.rectSelection)

        XCTAssertFalse(vm.switchSelectionToText())
        XCTAssertNotNil(vm.rectSelection)
    }

    /// 非对应状态下调用是无操作(防御性)。
    func testSwitchIsNoOpInWrongState() {
        let vm = makeViewModel(words: [])
        vm.onImageSearch = { _ in }
        vm.onTextSearch = { _ in }

        // 无选区:两个方向都不动
        vm.switchSelectionToImage()
        XCTAssertNil(vm.rectSelection)
        XCTAssertFalse(vm.switchSelectionToText())

        // 矩形态调用「改图」不动
        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)
        let rect = vm.rectSelection
        vm.switchSelectionToImage()
        XCTAssertEqual(vm.rectSelection, rect)
    }
}
