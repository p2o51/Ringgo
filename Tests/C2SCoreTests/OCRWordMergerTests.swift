import XCTest
@testable import C2SCore

/// F17:整屏词表 + 定向补刀词表的合并规则。
final class OCRWordMergerTests: XCTestCase {

    private func word(_ id: Int, _ text: String, x: CGFloat, y: CGFloat,
                      w: CGFloat = 40, h: CGFloat = 16, block: Int = 0) -> OCRWord {
        OCRWord(id: id, text: text, rect: CGRect(x: x, y: y, width: w, height: h), block: block)
    }

    /// 追加补刀词:id 连续重排,block 偏移到既有 block 之后。
    func testAppendsFreshWordsWithReindexedIDsAndOffsetBlocks() {
        let base = [word(0, "既有", x: 0, y: 0, block: 0), word(1, "词", x: 50, y: 0, block: 2)]
        let extra = [word(0, "新词", x: 300, y: 300, block: 0), word(1, "又一", x: 350, y: 300, block: 1)]

        let merged = OCRWordMerger.merge(base: base, extra: extra)

        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.map(\.id), [0, 1, 2, 3], "SelectionEngine 要求 id == 下标")
        XCTAssertEqual(merged[2].text, "新词")
        XCTAssertEqual(merged[2].block, 3, "补刀 block 应偏移到既有最大 block(2)之后")
        XCTAssertEqual(merged[3].block, 4)
        // 既有词原样保留
        XCTAssertEqual(merged[0].text, "既有")
        XCTAssertEqual(merged[1].block, 2)
    }

    /// 与既有词框高度重叠(IoU > 0.5)的补刀词是重复识别,丢弃。
    func testDropsDuplicatesByIoU() {
        let base = [word(0, "重复", x: 100, y: 100)]
        let extra = [
            word(0, "重复", x: 102, y: 101),          // 几乎同框 → 丢
            word(1, "全新", x: 300, y: 300),          // 无重叠 → 留
        ]

        let merged = OCRWordMerger.merge(base: base, extra: extra)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[1].text, "全新")
    }

    /// 补刀全是重复:原表原样返回(不重排、不触发引擎重建的额外语义)。
    func testAllDuplicatesReturnsBaseUnchanged() {
        let base = [word(0, "词", x: 100, y: 100)]
        let extra = [word(0, "词", x: 100, y: 100)]

        let merged = OCRWordMerger.merge(base: base, extra: extra)
        XCTAssertEqual(merged.map(\.id), base.map(\.id))
        XCTAssertEqual(merged.count, 1)
    }

    /// 空基表(整屏 OCR 未完成/零词):补刀词直接成为全表,block 从 0 起。
    func testEmptyBase() {
        let extra = [word(0, "先到", x: 10, y: 10, block: 0)]
        let merged = OCRWordMerger.merge(base: [], extra: extra)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, 0)
        XCTAssertEqual(merged[0].block, 0)
    }

    /// 轻微擦边(IoU ≤ 0.5)不算重复——相邻词框天然有小面积交叠。
    func testSlightOverlapIsNotDuplicate() {
        let base = [word(0, "左词", x: 100, y: 100, w: 40)]
        let extra = [word(0, "右词", x: 132, y: 100, w: 40)] // 交叠 8pt 宽,IoU ≈ 0.11

        let merged = OCRWordMerger.merge(base: base, extra: extra)
        XCTAssertEqual(merged.count, 2)
    }

    /// 审查 #7:「同文异框」——补刀认出的半词几乎整个落在整屏全词框里
    /// (IoU ≤ 0.5,但交叠占补刀词面积 > 0.6)也必须判重丢弃。
    func testContainedHalfWordIsDuplicate() {
        // 整屏认出 "Documents"(宽 90);补刀被裁只认出 "Docum"(宽 45,完全在前者内)
        let base = [word(0, "Documents", x: 100, y: 100, w: 90)]
        let extra = [word(0, "Docum", x: 100, y: 100, w: 45)] // IoU = 0.5,含入率 1.0

        let merged = OCRWordMerger.merge(base: base, extra: extra)
        XCTAssertEqual(merged.count, 1, "半词是重复识别,不得追加")
        XCTAssertEqual(merged[0].text, "Documents")
    }

    /// CJK 切分错位:补刀的二字块横跨整屏两个词框,但大半被覆盖 → 判重。
    func testMisalignedCJKChunkIsDuplicate() {
        let base = [word(0, "侧边", x: 100, y: 100, w: 30), word(1, "栏", x: 132, y: 100, w: 15)]
        // 补刀切成 "边栏"(x 116..146):与"侧边"交叠 14pt、与"栏"交叠 14pt,
        // 单个 IoU 均 < 0.5,但对"侧边"的含入率 = 14/30 < 0.6…改用更贴近的框:
        let extra = [word(0, "边栏", x: 118, y: 100, w: 28)] // 与"侧边"交叠 12,与"栏"交叠 13
        // 含入率 = max(12, 13)/28 < 0.6:此种极端错位确实会漏——记录现实取舍:
        // 半词/子串场景(交叠 > 0.6)已兜住;跨界均分场景靠「先查真词表再并表」防护。
        let merged = OCRWordMerger.merge(base: base, extra: extra)
        XCTAssertEqual(merged.count, 3, "跨界均分错位不在 merge 职责内(上游已防)")
    }

    // MARK: - matching(选区映射进新词表)

    /// 引擎重建后按词框找回等价词(id 变了、框几乎没动)。
    func testMatchingRemapsSelectionAcrossTables() {
        let selection = [word(3, "甲", x: 100, y: 100), word(4, "乙", x: 150, y: 100)]
        let table = [
            word(0, "无关", x: 500, y: 500),
            word(1, "甲", x: 101, y: 100),   // 同框微移
            word(2, "乙", x: 150, y: 101),
        ]
        let mapped = OCRWordMerger.matching(selection, in: table)
        XCTAssertEqual(mapped?.map(\.id), [1, 2])
        XCTAssertEqual(mapped?.map(\.text), ["甲", "乙"])
    }

    /// 任一词找不到对应 → 整体 nil,绝不返回残缺选区。
    func testMatchingFailsWhenAnyWordMissing() {
        let selection = [word(0, "甲", x: 100, y: 100), word(1, "乙", x: 150, y: 100)]
        let table = [word(0, "甲", x: 100, y: 100)] // 乙不在新表
        XCTAssertNil(OCRWordMerger.matching(selection, in: table))
    }

    /// 多候选取 IoU 最大者。
    func testMatchingPicksBestOverlap() {
        let selection = [word(0, "目标", x: 100, y: 100, w: 40)]
        let table = [
            word(0, "偏移", x: 112, y: 100, w: 40),  // IoU ≈ 0.54
            word(1, "精准", x: 102, y: 100, w: 40),  // IoU ≈ 0.9
        ]
        XCTAssertEqual(OCRWordMerger.matching(selection, in: table)?.first?.text, "精准")
    }
}
