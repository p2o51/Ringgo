import XCTest
import CoreGraphics
@testable import C2SCore

/// bestMatch:圈选闭合 → 贴合检测框(原版"形态转化"语义,2026-07-03)。
final class ObjectSnapBestMatchTests: XCTestCase {

    func testLooseCircleAroundSmallObjectSnapsToIt() {
        // 松圈:400×400 包围盒里只有一个 120×90 的部件 → IoU 很低也必须贴上去
        let widget = CGRect(x: 140, y: 140, width: 120, height: 90)
        let enclosure = CGRect(x: 40, y: 40, width: 400, height: 400)
        XCTAssertEqual(ObjectSnap.bestMatch(for: enclosure, boxes: [widget]), widget)
    }

    func testPicksLargestEnclosedCandidate() {
        // 圈住一个卡片(大)和它里面的图标(小)→ 主体是卡片
        let icon = CGRect(x: 100, y: 100, width: 32, height: 32)
        let card = CGRect(x: 80, y: 80, width: 240, height: 160)
        let enclosure = CGRect(x: 40, y: 40, width: 360, height: 300)
        XCTAssertEqual(ObjectSnap.bestMatch(for: enclosure, boxes: [icon, card]), card)
    }

    func testMostlyOutsideCandidateIgnored() {
        // 候选大半在包围盒外(coverage < 0.85)且 IoU 低 → 不贴,维持手绘框
        let outside = CGRect(x: 300, y: 0, width: 300, height: 300)
        let enclosure = CGRect(x: 0, y: 0, width: 340, height: 340)
        XCTAssertNil(ObjectSnap.bestMatch(for: enclosure, boxes: [outside]))
    }

    func testTightEnclosureFallsBackToIoU() {
        // 手绘框和候选几乎重合(无"被包住"关系,靠 IoU 兜底)
        let box = CGRect(x: 100, y: 100, width: 200, height: 150)
        let enclosure = CGRect(x: 90, y: 95, width: 205, height: 150)
        XCTAssertEqual(ObjectSnap.bestMatch(for: enclosure, boxes: [box]), box)
    }

    func testEmptyCandidatesReturnsNil() {
        XCTAssertNil(ObjectSnap.bestMatch(for: CGRect(x: 0, y: 0, width: 100, height: 100), boxes: []))
    }
}

/// F8 物体吸附纯逻辑测试:轻点吸附取最小含点框、IoU 去重留小框、
/// filtered 滤除碎屑框与近全屏框、dedupe 输出按面积升序。
final class ObjectSnapTests: XCTestCase {

    // MARK: - snap:轻点吸附

    /// 嵌套框(大卡片内套小缩略图):点落在最内层 → 吸附面积最小的框(最贴物体)。
    func testSnapNestedBoxesPicksSmallest() {
        let outer = CGRect(x: 0, y: 0, width: 400, height: 300)
        let middle = CGRect(x: 50, y: 50, width: 200, height: 150)
        let inner = CGRect(x: 80, y: 80, width: 60, height: 40)
        let snapped = ObjectSnap.snap(point: CGPoint(x: 100, y: 100),
                                      boxes: [outer, middle, inner])
        XCTAssertEqual(snapped, inner,
                       "嵌套框应吸附面积最小者 — 实际 \(String(describing: snapped))")
    }

    /// 点在所有框之外 → nil(调用方回退默认框)。
    func testSnapPointOutsideAllBoxesReturnsNil() {
        let boxes = [CGRect(x: 0, y: 0, width: 100, height: 100),
                     CGRect(x: 200, y: 200, width: 50, height: 50)]
        XCTAssertNil(ObjectSnap.snap(point: CGPoint(x: 500, y: 500), boxes: boxes),
                     "无框命中必须返回 nil,让调用方走默认框回退")
    }

    /// 空候选列表 → nil,不崩。
    func testSnapEmptyBoxesReturnsNil() {
        XCTAssertNil(ObjectSnap.snap(point: CGPoint(x: 10, y: 10), boxes: []))
    }

    /// 两个不相交框,点只落在较大那个里 → 吸附含点框,不被"全局最小"带偏。
    func testSnapOnlyConsidersBoxesContainingPoint() {
        let small = CGRect(x: 500, y: 500, width: 30, height: 30)
        let big = CGRect(x: 0, y: 0, width: 200, height: 200)
        let snapped = ObjectSnap.snap(point: CGPoint(x: 100, y: 100), boxes: [small, big])
        XCTAssertEqual(snapped, big,
                       "只在含点框中取最小 — 实际 \(String(describing: snapped))")
    }

    // MARK: - dedupe:IoU 去重

    /// 两个几乎重合的框(IoU = 0.96 ≥ 0.8)→ 只留面积较小者。
    func testDedupeNearCoincidentKeepsSmallerOnly() {
        let big = CGRect(x: 0, y: 0, width: 100, height: 100)   // 面积 10000
        let small = CGRect(x: 0, y: 0, width: 96, height: 100)  // 面积 9600,交 9600/并 10000 = 0.96
        let result = ObjectSnap.dedupe([big, small])
        XCTAssertEqual(result, [small], "高重叠对只留小框 — 实际 \(result)")
    }

    /// 完全不重叠的框全部保留(且按面积升序输出)。
    func testDedupeDisjointBoxesAllKept() {
        let a = CGRect(x: 0, y: 0, width: 50, height: 50)         // 2500
        let b = CGRect(x: 200, y: 200, width: 100, height: 100)   // 10000
        let result = ObjectSnap.dedupe([b, a])
        XCTAssertEqual(result, [a, b], "不重叠都保留、面积升序 — 实际 \(result)")
    }

    /// 部分重叠但 IoU(≈0.33)低于阈值 → 都保留,不得误杀。
    func testDedupePartialOverlapBelowThresholdBothKept() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 50, y: 0, width: 100, height: 100)  // 交 5000/并 15000 ≈ 0.33
        let result = ObjectSnap.dedupe([a, b])
        XCTAssertEqual(result.count, 2, "IoU 低于阈值的重叠不去重 — 实际 \(result)")
    }

    /// 输出必须按面积升序(吸附取最小、绘制从小到大都依赖该序)。
    func testDedupeOutputSortedByAreaAscending() {
        let boxes = [CGRect(x: 0, y: 0, width: 300, height: 100),    // 30000
                     CGRect(x: 400, y: 0, width: 50, height: 50),    // 2500
                     CGRect(x: 0, y: 300, width: 100, height: 100)]  // 10000
        let result = ObjectSnap.dedupe(boxes)
        XCTAssertEqual(result.count, 3)
        let areas = result.map { $0.width * $0.height }
        XCTAssertEqual(areas, areas.sorted(), "dedupe 输出必须按面积升序 — 实际 \(areas)")
    }

    // MARK: - filtered:碎屑框与近全屏框

    /// 任一边 < minSide 的碎屑框被滤除;正常框保留。
    func testFilteredRemovesBoxesWithTinySide() {
        let canvas = CGSize(width: 1000, height: 800)
        let thin = CGRect(x: 0, y: 0, width: 10, height: 100)    // 宽 10 < 24
        let flat = CGRect(x: 0, y: 200, width: 100, height: 8)   // 高 8 < 24
        let ok = CGRect(x: 300, y: 300, width: 120, height: 90)
        let result = ObjectSnap.filtered([thin, flat, ok], canvas: canvas)
        XCTAssertEqual(result, [ok], "碎屑框必须滤除 — 实际 \(result)")
    }

    /// 面积 > 屏幕面积 × maxAreaRatio 的近全屏框被滤除(吸附它等于没吸附)。
    func testFilteredRemovesNearFullScreenBox() {
        let canvas = CGSize(width: 1000, height: 800)  // 屏幕面积 800000,默认阈值 720000
        let nearFull = CGRect(x: 0, y: 0, width: 980, height: 780)  // 764400 > 720000
        let ok = CGRect(x: 100, y: 100, width: 400, height: 300)
        let result = ObjectSnap.filtered([nearFull, ok], canvas: canvas)
        XCTAssertEqual(result, [ok], "近全屏框必须滤除 — 实际 \(result)")
    }

    /// 参数可调:收紧 minSide / 放宽 maxAreaRatio 均按传入值生效。
    func testFilteredHonorsCustomParameters() {
        let canvas = CGSize(width: 1000, height: 800)
        let smallish = CGRect(x: 0, y: 0, width: 30, height: 30)
        let nearFull = CGRect(x: 0, y: 0, width: 980, height: 780)
        // minSide 收紧到 40 → smallish 出局;maxAreaRatio 放宽到 1.0 → nearFull 保留
        let result = ObjectSnap.filtered([smallish, nearFull], canvas: canvas,
                                         minSide: 40, maxAreaRatio: 1.0)
        XCTAssertEqual(result, [nearFull], "自定义参数必须生效 — 实际 \(result)")
    }
}
