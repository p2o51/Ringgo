import XCTest
import CoreGraphics
@testable import C2SCore

/// 选择规则 v3(2026-07-03 用户拍板,完全对齐谷歌)的行为测试:
///   全屏词聚成一条**全局阅读链**,选区 = 链上 [首触碰 … 末触碰] 连续区间。
///   表格/多栏/跨段一笔全选是刚需;跨区域对角线会连带中间内容 —— 谷歌同款、
///   可预期,是已明示并接受的权衡(v2 的 block 隔离把表格撕成碎片,被否)。
final class SelectionEngineTests: XCTestCase {

    // MARK: - 工具

    private func makeWords(_ specs: [(String, CGFloat, CGFloat, CGFloat, CGFloat, Int)]) -> [OCRWord] {
        specs.enumerated().map { i, s in
            OCRWord(id: i, text: s.0, rect: CGRect(x: s.1, y: s.2, width: s.3, height: s.4), block: s.5)
        }
    }

    private func center(_ w: OCRWord) -> CGPoint { CGPoint(x: w.rect.midX, y: w.rect.midY) }
    private func texts(_ ws: [OCRWord]) -> Set<String> { Set(ws.map(\.text)) }
    private func joined(_ ws: [OCRWord]) -> String { ws.map(\.text).joined(separator: " ") }

    // MARK: - S1:跨区域大对角线(v3 = 全局区间,谷歌同款)

    /// v3 语义:对角线从底部终端划到顶部聊天 → 全局阅读序 [首触碰…末触碰] 区间,
    /// 中间内容连带选中(可预期的谷歌行为;v2 的 block 隔离因撕碎表格被否)。
    func testS1_v3GlobalIntervalAcrossRegions() {
        let ws = makeWords([
            ("Meet", 60, 96, 74, 28, 0), ("Sonnet", 140, 96, 96, 28, 0), ("smarter", 250, 96, 110, 28, 0),
            ("Switch", 60, 136, 92, 28, 0), ("anytime", 160, 136, 110, 28, 0), ("model", 290, 136, 86, 28, 0),
            ("nFirstLaunch", 60, 620, 158, 28, 1), ("sudo", 228, 620, 66, 28, 1),
            ("Applications", 304, 620, 150, 28, 1), ("Xcode", 464, 620, 86, 28, 1),
        ])
        let engine = SelectionEngine(words: ws)
        // Applications(底) → 中间空白 → Sonnet(顶)
        let path = [center(ws[8]), CGPoint(x: 250, y: 400), center(ws[1])]

        let touched = engine.touchedWordIDs(alongPath: path)
        let selected = engine.brushSelection(path: path)

        // v4 锚点语义:两块都被带扫到 → 参与;区间整段填充(首行到行尾/末行从行首)
        XCTAssertEqual(selected.map(\.id), Array(touched.min()!...touched.max()!),
                       "参与区域内整行填充 — 实际 \(joined(selected))")
    }

    /// 用户实测(2026-07-03 傍晚,Recents 侧栏):从 Workspace 划到第三行 project,
    /// Android 语义 = 首行选到行尾、中间行整行、末行选到锚点(development/tracks 必须在);
    /// 同屏正文列在笔画带外 → 区域不参与,不得混入。
    func testSidebarDiagonalFillsFullLinesWithoutBleedingIntoMainColumn() {
        let ws = makeWords([
            // 侧栏(block 0,x 40…300)
            ("Workspace", 40, 100, 90, 20, 0), ("content", 136, 100, 70, 20, 0), ("development", 212, 100, 88, 20, 0),
            ("Spotify", 40, 140, 60, 20, 0), ("API", 106, 140, 34, 20, 0),
            ("library", 146, 140, 60, 20, 0), ("tracks", 212, 140, 50, 20, 0),
            ("Circle2Search", 40, 180, 110, 20, 0), ("project", 156, 180, 60, 20, 0), ("evaluation", 222, 180, 78, 20, 0),
            // 正文列(block 1,x 400…600,同样的行)
            ("main1", 400, 100, 200, 20, 1), ("main2", 400, 140, 200, 20, 1), ("main3", 400, 180, 200, 20, 1),
        ])
        let engine = SelectionEngine(words: ws)
        // Workspace 中心 → project 中心(带 ≈ 61…210,不达正文列)
        let selected = engine.brushSelection(path: [center(ws[0]), center(ws[8])])
        XCTAssertEqual(selected.map(\.text),
                       ["Workspace", "content", "development",
                        "Spotify", "API", "library", "tracks",
                        "Circle2Search", "project"],
                       "首行到行尾/中间整行/末行到锚点,正文列不混入 — 实际 \(joined(selected))")
    }

    /// 用户实测截图场景(2026-07-03 下午):三栏桌面(左侧栏/中栏正文/右面板)同行,
    /// 只在**中栏内**斜划 → 两侧栏虽在全局区间内,但在笔画横向带外,不得混入。
    func testSidePanelsOutsideStrokeBandAreNotSelected() {
        let ws = makeWords([
            // 左侧栏(x 40…160)
            ("side1", 40, 100, 120, 20, 0), ("side2", 40, 140, 120, 20, 0), ("side3", 40, 180, 120, 20, 0),
            // 中栏正文(x 400…820),每行两词
            ("m1a", 400, 100, 200, 20, 1), ("m1b", 620, 100, 200, 20, 1),
            ("m2a", 400, 140, 200, 20, 1), ("m2b", 620, 140, 200, 20, 1),
            ("m3a", 400, 180, 200, 20, 1), ("m3b", 620, 180, 200, 20, 1),
            // 右面板(x 1100…1250)
            ("r1", 1100, 100, 150, 20, 2), ("r2", 1100, 140, 150, 20, 2), ("r3", 1100, 180, 150, 20, 2),
        ])
        let engine = SelectionEngine(words: ws)
        // 中栏内对角线:m1a → m3b
        let selected = engine.brushSelection(path: [center(ws[3]), center(ws[8])])
        XCTAssertEqual(texts(selected), ["m1a", "m1b", "m2a", "m2b", "m3a", "m3b"],
                       "侧栏/右面板不得混入 — 实际 \(joined(selected))")
    }

    // MARK: - ADV-2:同行两远隔词,中间大空白,直线全程穿过

    func testADV2_twoDistantTouchedWordsBothKept() {
        let ws = makeWords([("swiftc", 60, 300, 110, 28, 0), ("done", 700, 300, 80, 28, 0)])
        let engine = SelectionEngine(words: ws)
        let selected = engine.brushSelection(path: [center(ws[0]), center(ws[1])])
        XCTAssertEqual(texts(selected), ["swiftc", "done"], "实际 \(joined(selected))")
    }

    // MARK: - 同行双栏(v3:同一视觉行按 x 桥接 = 谷歌同款,表格行的刚需)

    func testSameLineColumnsBridgeInReadingOrder() {
        let ws = makeWords([
            ("hello", 60, 300, 90, 28, 0), ("MID", 300, 300, 80, 28, 0),          // 左栏
            ("sudo", 560, 300, 70, 28, 1), ("Applications", 660, 300, 150, 28, 1), // 右栏(同 y)
        ])
        let engine = SelectionEngine(words: ws)
        // V 形:hello → 下沉 → sudo;区间 = 行内 hello…sudo(Applications 在区间外)
        let path = [center(ws[0]), CGPoint(x: 330, y: 384), center(ws[2])]
        let selected = engine.brushSelection(path: path)
        XCTAssertEqual(selected.map(\.text), ["hello", "MID", "sudo"],
                       "同行区间按阅读序填充,区间外不进 — 实际 \(joined(selected))")
    }

    // MARK: - ADV-6:两端对齐/宽制表符,合法整行全触碰,大间距不砍断

    func testADV6_wideGapFullLineNotSplit() {
        let ws = makeWords([
            ("col1", 60, 300, 80, 28, 0), ("col2", 320, 300, 80, 28, 0), ("col3", 600, 300, 80, 28, 0),
        ])
        let engine = SelectionEngine(words: ws)
        let selected = engine.brushSelection(path: [center(ws[0]), center(ws[1]), center(ws[2])])
        XCTAssertEqual(texts(selected), ["col1", "col2", "col3"], "实际 \(joined(selected))")
    }

    // MARK: - 段落对角线(v2 核心场景,2026-07-02 用户需求)

    /// 6×4 词网格(单 block 段落),陡对角线每行只碰 ~1 词
    /// → v2:选中阅读链上 [首触碰 … 末触碰] 的整个连续区间(谷歌同款)。
    func testParagraphDiagonalFillsReadingOrderRange() {
        var specs: [(String, CGFloat, CGFloat, CGFloat, CGFloat, Int)] = []
        for r in 0..<6 {
            for c in 0..<4 {
                specs.append(("w\(r)\(c)", 60 + CGFloat(c) * 120, 300 + CGFloat(r) * 36, 100, 28, 0))
            }
        }
        let ws = makeWords(specs)
        let engine = SelectionEngine(words: ws)
        var path: [CGPoint] = []
        for r in 0..<6 {
            path.append(CGPoint(x: 110 + CGFloat(r) * 70, y: 314 + CGFloat(r) * 36))
        }
        let touched = engine.touchedWordIDs(alongPath: path)
        // 网格按行主序构造,id 即阅读链位置
        let lo = touched.min()!, hi = touched.max()!
        let expected = Set(lo...hi)
        let selected = Set(engine.brushSelection(path: path).map(\.id))
        XCTAssertEqual(selected, expected,
                       "段内对角线应填满 [首触碰…末触碰] 区间;触碰 \(touched.sorted())")
        XCTAssertGreaterThan(selected.count, touched.count, "区间应大于触碰集(有补全发生)")
    }

    /// 用户原话场景:直线从段落左上角划到右下角 → 选中整个段落。
    func testUserScenario_topLeftToBottomRightSelectsWholeParagraph() {
        var specs: [(String, CGFloat, CGFloat, CGFloat, CGFloat, Int)] = []
        for r in 0..<4 {
            for c in 0..<4 {
                specs.append(("w\(r)\(c)", 60 + CGFloat(c) * 120, 300 + CGFloat(r) * 36, 100, 28, 0))
            }
        }
        let ws = makeWords(specs)
        let engine = SelectionEngine(words: ws)
        // 左上词中心 → 右下词中心的直线
        let selected = engine.brushSelection(path: [center(ws[0]), center(ws[15])])
        XCTAssertEqual(selected.count, 16, "应选中整段 16 词,实际 \(selected.count):\(joined(selected))")
    }

    /// 用户实测截图场景(2026-07-03):3 行 × 2 列表格,v2 的 block 隔离把选区撕成碎片。
    /// v3 全局链:对角线 Term1 → date3 应选中整张表(行内跨列、行间跨行连续填充)。
    func testTableDiagonalSelectsAllCellsBetweenAnchors() {
        let ws = makeWords([
            ("Term1", 100, 250, 80, 28, 0), ("entry1", 190, 250, 100, 28, 0),  // r1 左单元格
            ("date1", 700, 250, 200, 28, 1),                                    // r1 右单元格
            ("Term2", 100, 360, 80, 28, 2), ("entry2", 190, 360, 100, 28, 2),  // r2 左
            ("date2", 700, 360, 200, 28, 3),                                    // r2 右
            ("Term3", 100, 470, 80, 28, 4), ("entry3", 190, 470, 100, 28, 4),  // r3 左
            ("date3", 700, 470, 200, 28, 5),                                    // r3 右
        ])
        let engine = SelectionEngine(words: ws)
        let selected = engine.brushSelection(path: [center(ws[0]), center(ws[8])])
        XCTAssertEqual(selected.map(\.text),
                       ["Term1", "entry1", "date1", "Term2", "entry2", "date2", "Term3", "entry3", "date3"],
                       "表格对角线整表全选、阅读序输出 — 实际 \(joined(selected))")
    }

    func testLargeTextInAnotherBlockDoesNotMergeSmallTextLines() {
        let ws = makeWords([
            // block 0:两行 10pt 小字，正确阅读链应为 a,b,c,d
            ("a", 0, 0, 30, 10, 0), ("b", 100, 0, 30, 10, 0),
            ("c", 10, 20, 30, 10, 0), ("d", 110, 20, 30, 10, 0),
            // block 1:足以主导全局中位数的 100pt 大字
            ("L0", 400, 0, 100, 100, 1), ("L1", 400, 120, 100, 100, 1),
            ("L2", 400, 240, 100, 100, 1), ("L3", 400, 360, 100, 100, 1),
            ("L4", 400, 480, 100, 100, 1),
        ])
        let engine = SelectionEngine(words: ws)

        let selected = engine.selection(fromTouched: [0, 2])

        XCTAssertEqual(selected.map(\.text), ["a", "b", "c"],
                       "其他 block 的大字号不得把小字两行合并成 x 排序")
    }

    func testSameLineVerticalJitterPreservesHorizontalReadingOrder() {
        let ws = makeWords([
            ("left", 10, 100, 60, 20, 0),   // midY = 110
            ("right", 100, 99, 60, 20, 0),  // midY = 109，Vision 常见轻微抖动
        ])
        let engine = SelectionEngine(words: ws)

        let selected = engine.selection(fromTouched: [0, 1])

        XCTAssertEqual(selected.map(\.text), ["left", "right"])
        XCTAssertEqual(SelectionEngine.text(for: selected), "left right")
    }

    // MARK: - 回归:正常沿行划 / 轻点 / 弧线绕过

    private var regressionWords: [OCRWord] {
        makeWords([
            ("sudo", 60, 300, 70, 28, 0), ("brew", 140, 300, 70, 28, 0),
            ("install", 220, 300, 90, 28, 0), ("xcode", 320, 300, 90, 28, 0),
        ])
    }

    func testRegression_sweepAlongLineSelectsAll() {
        let ws = regressionWords
        let engine = SelectionEngine(words: ws)
        let selected = engine.brushSelection(path: [center(ws[0]), center(ws[3])])
        XCTAssertEqual(texts(selected), ["sudo", "brew", "install", "xcode"])
    }

    func testRegression_singlePointSelectsOneWord() {
        let ws = regressionWords
        let engine = SelectionEngine(words: ws)
        let selected = engine.brushSelection(path: [center(ws[2])])
        XCTAssertEqual(joined(selected), "install")
    }

    /// 弧线从 brew 下方绕过:v2 = swipe 语义,brew 在 [sudo…xcode] 区间内 → 一并选中。
    func testRegression_arcBypassFillsRange() {
        let ws = regressionWords
        let engine = SelectionEngine(words: ws)
        let arc = [center(ws[0]), CGPoint(x: 175, y: 340), center(ws[2]), center(ws[3])]
        let selected = engine.brushSelection(path: arc)
        XCTAssertEqual(texts(selected), ["sudo", "brew", "install", "xcode"],
                       "区间填充应补回 brew — 实际 \(joined(selected))")
    }

    // MARK: - BrushSession 增量 == 批量

    func testBrushSessionIncrementalMatchesBatch() {
        let ws = makeWords([
            ("Meet", 60, 96, 74, 28, 0), ("Sonnet", 140, 96, 96, 28, 0), ("smarter", 250, 96, 110, 28, 0),
            ("Switch", 60, 136, 92, 28, 0), ("anytime", 160, 136, 110, 28, 0), ("model", 290, 136, 86, 28, 0),
            ("nFirstLaunch", 60, 620, 158, 28, 1), ("sudo", 228, 620, 66, 28, 1),
            ("Applications", 304, 620, 150, 28, 1), ("Xcode", 464, 620, 86, 28, 1),
        ])
        let engine = SelectionEngine(words: ws)
        var path: [CGPoint] = []
        let from = CGPoint(x: 379, y: 634), to = CGPoint(x: 188, y: 110)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            path.append(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        let batch = engine.brushSelection(path: path)

        let session = BrushSession(engine: engine)
        for p in path { session.append([p]) }  // 一次一点,最大化增量路径覆盖
        XCTAssertEqual(session.selection.map(\.id), batch.map(\.id),
                       "增量触碰必须与批量完全一致")
        XCTAssertEqual(session.touched, engine.touchedWordIDs(alongPath: path))
    }

    // MARK: - 轻点 / 手柄 / 矩形

    func testTappedWord() {
        let ws = regressionWords
        let engine = SelectionEngine(words: ws)
        XCTAssertEqual(engine.tappedWord(at: center(ws[1]))?.text, "brew")
        XCTAssertNil(engine.tappedWord(at: CGPoint(x: 700, y: 700)), "空白处轻点 → nil → 路由图搜")
    }

    func testExtendedSelectionAlongGlobalChain() {
        let ws = makeWords([
            ("a", 60, 100, 40, 20, 0), ("b", 110, 100, 40, 20, 0),
            ("c", 60, 130, 40, 20, 0), ("d", 110, 130, 40, 20, 0),
            ("other", 600, 300, 60, 20, 1),
        ])
        let engine = SelectionEngine(words: ws)
        // 沿全局阅读链 = a b c d(与笔刷区间填充同一语义)
        XCTAssertEqual(engine.extendedSelection(anchorID: 0, targetID: 3)?.map(\.text), ["a", "b", "c", "d"])
        // v3:手柄允许跨区域沿全局链扩展(谷歌同款)
        XCTAssertEqual(engine.extendedSelection(anchorID: 0, targetID: 4)?.map(\.text),
                       ["a", "b", "c", "d", "other"])
    }

    func testHandleTargetPrefersSameLineBand() {
        let ws = makeWords([
            ("a", 60, 100, 40, 20, 0), ("b", 110, 100, 40, 20, 0),
            ("c", 60, 160, 40, 20, 0),
        ])
        let engine = SelectionEngine(words: ws)
        let target = engine.handleTarget(near: CGPoint(x: 128, y: 112), inBlock: 0)
        XCTAssertEqual(target?.text, "b")
    }

    func testWordsInRect() {
        let ws = regressionWords
        let engine = SelectionEngine(words: ws)
        let hit = engine.words(inRect: CGRect(x: 130, y: 290, width: 190, height: 50))
        XCTAssertEqual(hit.map(\.text), ["brew", "install"])
        XCTAssertTrue(engine.words(inRect: CGRect(x: 600, y: 600, width: 100, height: 100)).isEmpty,
                      "无词矩形 → 空 → 路由图搜")
    }

    // MARK: - 文本拼装(CJK 不插空格)

    func testTextAssemblyCJK() {
        let ws = makeWords([
            ("本地", 60, 100, 40, 20, 0), ("文字", 104, 100, 40, 20, 0),
            ("hello", 150, 100, 50, 20, 0), ("世界", 210, 100, 40, 20, 0),
        ])
        XCTAssertEqual(SelectionEngine.text(for: ws), "本地文字 hello 世界")
    }
}
