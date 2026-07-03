import XCTest
import CoreGraphics
@testable import C2SCore

final class BlockClustererTests: XCTestCase {

    func testStackedParagraphLinesFormOneBlock() {
        let lines = [
            CGRect(x: 60, y: 100, width: 800, height: 24),
            CGRect(x: 60, y: 130, width: 780, height: 24),
            CGRect(x: 60, y: 160, width: 500, height: 24),
        ]
        let blocks = BlockClusterer.assignBlocks(lineRects: lines)
        XCTAssertEqual(Set(blocks).count, 1)
    }

    func testSameYColumnsAreSeparateBlocks() {
        // ADV-8 场景:同 y 的聊天块与终端块
        let lines = [
            CGRect(x: 60, y: 300, width: 320, height: 28),   // 左栏
            CGRect(x: 560, y: 300, width: 250, height: 28),  // 右栏(同 y,水平不重叠)
        ]
        let blocks = BlockClusterer.assignBlocks(lineRects: lines)
        XCTAssertNotEqual(blocks[0], blocks[1], "同 y 双栏必须物理隔离")
    }

    func testTwoColumnsOfStackedLines() {
        let lines = [
            // 左栏 3 行
            CGRect(x: 60, y: 100, width: 300, height: 24),
            CGRect(x: 60, y: 130, width: 300, height: 24),
            CGRect(x: 60, y: 160, width: 300, height: 24),
            // 右栏 3 行
            CGRect(x: 500, y: 100, width: 300, height: 24),
            CGRect(x: 500, y: 130, width: 300, height: 24),
            CGRect(x: 500, y: 160, width: 300, height: 24),
        ]
        let blocks = BlockClusterer.assignBlocks(lineRects: lines)
        XCTAssertEqual(blocks[0], blocks[1])
        XCTAssertEqual(blocks[1], blocks[2])
        XCTAssertEqual(blocks[3], blocks[4])
        XCTAssertEqual(blocks[4], blocks[5])
        XCTAssertNotEqual(blocks[0], blocks[3])
    }

    func testDistantVerticalSectionsSplit() {
        let lines = [
            CGRect(x: 60, y: 100, width: 400, height: 24),
            CGRect(x: 60, y: 600, width: 400, height: 24),  // 远隔一大段
        ]
        let blocks = BlockClusterer.assignBlocks(lineRects: lines)
        XCTAssertNotEqual(blocks[0], blocks[1])
    }

    func testBlockNumberingIsStableReadingOrder() {
        let lines = [
            CGRect(x: 500, y: 600, width: 300, height: 24), // 靠下 → 后编号
            CGRect(x: 60, y: 100, width: 300, height: 24),  // 左上 → block 0
        ]
        let blocks = BlockClusterer.assignBlocks(lineRects: lines)
        XCTAssertEqual(blocks[1], 0)
        XCTAssertEqual(blocks[0], 1)
    }
}
