import XCTest
import C2SCore
@testable import C2SAppKit

/// 选区类型切换(迷你工具条「改选」chip):文字 ⇄ 图片,含定向补刀 OCR 回退。
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
    func testSwitchImageSelectionToTextWithWords() async {
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

        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .switched)
        XCTAssertEqual(vm.selectedText, "第一第二")
        XCTAssertEqual(textQueries, ["第一第二"])
        XCTAssertNil(vm.rectSelection)
        XCTAssertNotNil(vm.textHandleAnchors, "切回文字后应有泪滴手柄")
    }

    /// 框内无已知词 + 未接线补刀:返回 false,矩形选区原地不动。
    func testSwitchImageSelectionToTextWithoutWords() async {
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

        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .noText)
        XCTAssertEqual(vm.rectSelection, before, "切换失败选区必须原地不动")
        XCTAssertTrue(textQueries.isEmpty, "不得发出文字搜索")
    }

    /// F17 补刀:框内无已知词 → 定向 OCR 返回新词 → 并表后成功切换。
    func testFocusedOCRFallbackFindsWords() async {
        let vm = makeViewModel(words: [
            OCRWord(id: 0, text: "远处", rect: CGRect(x: 20, y: 20, width: 40, height: 16), block: 0),
        ])
        var textQueries: [String] = []
        var focusedRects: [CGRect] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }
        vm.onFocusedOCR = { rect in
            focusedRects.append(rect)
            // 补刀在框内新识别出两个小字词
            return [
                OCRWord(id: 0, text: "小字", rect: CGRect(x: rect.midX - 30, y: rect.midY - 8,
                                                          width: 28, height: 14), block: 0),
                OCRWord(id: 1, text: "内容", rect: CGRect(x: rect.midX + 2, y: rect.midY - 8,
                                                          width: 28, height: 14), block: 0),
            ]
        }

        let blank = CGPoint(x: 600, y: 450)
        vm.dragEnded(location: blank, start: blank)

        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .switched, "补刀识别出词后应成功切换")
        XCTAssertEqual(focusedRects.count, 1)
        XCTAssertEqual(vm.selectedText, "小字内容")
        XCTAssertEqual(textQueries, ["小字内容"])
    }

    /// F17 补刀期间选区变了(用户重拖):结果作废,不动新选区。
    func testFocusedOCRResultDiscardedWhenSelectionChanged() async {
        let vm = makeViewModel(words: [])
        var textQueries: [String] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }
        vm.onFocusedOCR = { rect in
            // 补刀在飞时用户点了别处出新框
            await MainActor.run {
                let elsewhere = CGPoint(x: 150, y: 150)
                vm.dragEnded(location: elsewhere, start: elsewhere)
            }
            return [OCRWord(id: 0, text: "迟到", rect: CGRect(x: rect.midX, y: rect.midY,
                                                              width: 30, height: 14), block: 0)]
        }

        let blank = CGPoint(x: 600, y: 450)
        vm.dragEnded(location: blank, start: blank)

        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .superseded, "选区已变,过期补刀结果必须静默作废")
        XCTAssertNil(vm.selectedText)
        XCTAssertNotNil(vm.rectSelection, "新框保持")
        XCTAssertTrue(textQueries.isEmpty)
    }

    /// F17:OCR 未完成(引擎缺席)时补刀同样可用。
    func testFocusedOCRWorksBeforeFullOCR() async {
        let vm = SelectionViewModel()
        vm.prepare(viewport: CGSize(width: 800, height: 600))
        var textQueries: [String] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }
        vm.onFocusedOCR = { rect in
            [OCRWord(id: 0, text: "先到", rect: CGRect(x: rect.midX - 15, y: rect.midY - 7,
                                                        width: 30, height: 14), block: 0)]
        }

        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)
        XCTAssertNotNil(vm.rectSelection)

        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .switched)
        XCTAssertEqual(vm.selectedText, "先到")
        XCTAssertEqual(textQueries, ["先到"])
    }

    /// F17 竞态:补刀切换成功后,整屏 OCR 晚到(且仍认不出那几个小字)——
    /// 补刀词必须重新并入新词表,选区原样保住,不得被冲掉。
    func testLateFullOCRPreservesFocusedSelection() async {
        let vm = SelectionViewModel() // 引擎缺席 = 整屏 OCR 还在飞
        vm.prepare(viewport: CGSize(width: 800, height: 600))
        var textQueries: [String] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }
        vm.onFocusedOCR = { rect in
            [OCRWord(id: 0, text: "侧栏", rect: CGRect(x: rect.midX - 15, y: rect.midY - 7,
                                                        width: 30, height: 14), block: 0)]
        }

        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)
        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .switched)
        XCTAssertEqual(vm.selectedText, "侧栏")

        // 整屏 OCR 姗姗来迟,词表里只有别处的词(小字它就是认不出)
        vm.updateWords([
            OCRWord(id: 0, text: "别处", rect: CGRect(x: 40, y: 40, width: 40, height: 16), block: 0),
        ])
        XCTAssertEqual(vm.selectedText, "侧栏", "补刀选区必须挺过整屏词表替换")
        XCTAssertEqual(textQueries, ["侧栏"], "选区保住时不得重发搜索")
        XCTAssertNotNil(vm.textHandleAnchors)
    }

    /// 普通文字选区在整屏词表刷新(同一批词重发)后同样按词框保住。
    func testWordTableRefreshPreservesBrushSelection() {
        let words = [
            OCRWord(id: 0, text: "你好", rect: CGRect(x: 100, y: 100, width: 40, height: 16), block: 0),
        ]
        let vm = makeViewModel(words: words)
        vm.onTextSearch = { _ in }
        vm.onImageSearch = { _ in }
        let tap = CGPoint(x: 110, y: 108)
        vm.dragEnded(location: tap, start: tap)
        XCTAssertEqual(vm.selectedText, "你好")

        // 同样内容的词表重发(id 重排):选区按框映射保住
        vm.updateWords([
            OCRWord(id: 0, text: "新增", rect: CGRect(x: 300, y: 300, width: 40, height: 16), block: 0),
            OCRWord(id: 1, text: "你好", rect: CGRect(x: 100, y: 100, width: 40, height: 16), block: 0),
        ])
        XCTAssertEqual(vm.selectedText, "你好")
    }

    /// 审查 #2/#3/#6 回归:OCR 未完成时出的框(图搜寄存在 pendingGesture),
    /// 「改选文字」失败**不得**吞掉兜底路由——整屏 OCR 到达后照常发图搜。
    func testFailedSwitchKeepsDeferredImageRouting() async {
        let vm = SelectionViewModel() // 整屏 OCR 在飞
        vm.prepare(viewport: CGSize(width: 800, height: 600))
        var imageRects: [CGRect] = []
        vm.onImageSearch = { imageRects.append($0) }
        vm.onTextSearch = { _ in }
        vm.onFocusedOCR = { _ in [] } // 补刀也没认出字

        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)
        XCTAssertTrue(imageRects.isEmpty, "OCR 未完成,图搜应挂起")

        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .noText)

        // 整屏 OCR 到达(空白区真没词):挂起的图搜必须补发,不能留死框
        vm.updateWords([])
        XCTAssertEqual(imageRects.count, 1, "兜底图搜路由不得被失败的改选吞掉")
    }

    /// 审查 #1 回归:补刀 await 期间整屏词表到达且框内有词——必须用真词表,
    /// 补刀词(分词可能不同)整体丢弃,绝不并表出重复词。
    /// (词不在轻点点位上 → 挂起手势解析为图搜、框保持 → 切换用真词表完成。)
    func testFullOCRArrivingDuringFocusedWinsOverExtras() async {
        let vm = SelectionViewModel()
        vm.prepare(viewport: CGSize(width: 800, height: 600))
        var textQueries: [String] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }
        vm.onFocusedOCR = { rect in
            // 补刀在飞时整屏词表先到:框内其实有词(不压轻点点位),分词与补刀不同
            await MainActor.run {
                vm.updateWords([
                    OCRWord(id: 0, text: "侧边栏", rect: CGRect(x: 340, y: 240, width: 42, height: 15), block: 0),
                ])
            }
            // 补刀按不同切分认出两个半词(与整屏词框 IoU 都 ≤ 0.5)
            return [
                OCRWord(id: 0, text: "侧边", rect: CGRect(x: 340, y: 240, width: 26, height: 15), block: 0),
                OCRWord(id: 1, text: "栏", rect: CGRect(x: 368, y: 240, width: 14, height: 15), block: 0),
            ]
        }

        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)

        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .switched)
        XCTAssertEqual(vm.selectedText, "侧边栏", "必须用整屏真词表,不得混入补刀的另一套切分")
        XCTAssertEqual(textQueries, ["侧边栏"], "有且只有一次干净的文字搜索")
    }

    /// 同上竞态的另一分支:整屏词恰在轻点点位上 → 挂起的轻点意图先解析成
    /// 选词(旧语义兜底),晚到的改选静默让位(.superseded),最终态依然干净。
    func testPendingTapResolutionWinsOverLateFocusedSwitch() async {
        let vm = SelectionViewModel()
        vm.prepare(viewport: CGSize(width: 800, height: 600))
        var textQueries: [String] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }
        vm.onFocusedOCR = { rect in
            await MainActor.run {
                // 词正压在轻点点位(400,300)上
                vm.updateWords([
                    OCRWord(id: 0, text: "侧边栏", rect: CGRect(x: 380, y: 292, width: 42, height: 15), block: 0),
                ])
            }
            return [
                OCRWord(id: 0, text: "侧边", rect: CGRect(x: 380, y: 292, width: 26, height: 15), block: 0),
            ]
        }

        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)

        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .superseded, "挂起轻点已解析,改选静默让位")
        XCTAssertEqual(vm.selectedText, "侧边栏")
        XCTAssertEqual(textQueries, ["侧边栏"], "只有轻点解析发出的一次搜索,无重复")
    }

    /// 审查 #4/#9 回归:切换任务被取消(用户转去编辑/翻译)→ .superseded,
    /// 补刀结果静默作废,选区不动、不发搜索。
    func testCancelledSwitchIsSuperseded() async {
        let vm = SelectionViewModel()
        vm.prepare(viewport: CGSize(width: 800, height: 600))
        var textQueries: [String] = []
        vm.onTextSearch = { textQueries.append($0) }
        vm.onImageSearch = { _ in }
        vm.onFocusedOCR = { rect in
            [OCRWord(id: 0, text: "命中", rect: CGRect(x: rect.midX - 15, y: rect.midY - 7,
                                                        width: 30, height: 14), block: 0)]
        }

        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)

        let task = Task { @MainActor in
            await vm.switchSelectionToText()
        }
        task.cancel() // 模拟工具条:用户点了编辑/翻译,意图已变
        let outcome = await task.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertNotNil(vm.rectSelection, "选区必须原地不动")
        XCTAssertNil(vm.selectedText)
        XCTAssertTrue(textQueries.isEmpty)
    }

    /// 非对应状态下调用是无操作(防御性)。
    func testSwitchIsNoOpInWrongState() async {
        let vm = makeViewModel(words: [])
        vm.onImageSearch = { _ in }
        vm.onTextSearch = { _ in }

        // 无选区:两个方向都不动
        vm.switchSelectionToImage()
        XCTAssertNil(vm.rectSelection)
        let outcome = await vm.switchSelectionToText()
        XCTAssertEqual(outcome, .superseded, "无选区 = 无事可做,静默")

        // 矩形态调用「改图」不动
        let blank = CGPoint(x: 400, y: 300)
        vm.dragEnded(location: blank, start: blank)
        let rect = vm.rectSelection
        vm.switchSelectionToImage()
        XCTAssertEqual(vm.rectSelection, rect)
    }
}
