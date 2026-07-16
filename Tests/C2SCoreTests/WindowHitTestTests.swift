import XCTest
@testable import C2SCore

/// F20/F24 窗口命中(spec §8):输入按 front-to-back 排序
/// (真源 = CGWindowListCopyWindowInfo 的文档保证序),命中第一个含点者。
final class WindowHitTestTests: XCTestCase {

    private func window(_ id: UInt32, _ frame: CGRect) -> PickableWindow {
        PickableWindow(windowID: id, frame: frame, title: nil, ownerPID: 100)
    }

    func testTopmostWins() {
        // 两窗重叠:列表序 = front-to-back,点落在重叠区必须命中前面那个
        let front = window(1, CGRect(x: 100, y: 100, width: 400, height: 300))
        let back = window(2, CGRect(x: 50, y: 50, width: 800, height: 600))
        let hit = WindowHitTest.topmost(at: CGPoint(x: 200, y: 200), in: [front, back])
        XCTAssertEqual(hit?.windowID, 1, "z-order:前面的窗口挡住后面的")
    }

    func testFallsThroughToBack() {
        let front = window(1, CGRect(x: 100, y: 100, width: 400, height: 300))
        let back = window(2, CGRect(x: 50, y: 50, width: 800, height: 600))
        let hit = WindowHitTest.topmost(at: CGPoint(x: 60, y: 500), in: [front, back])
        XCTAssertEqual(hit?.windowID, 2, "点不在前窗内 → 命中其下的窗口")
    }

    func testMissReturnsNil() {
        let win = window(1, CGRect(x: 100, y: 100, width: 400, height: 300))
        XCTAssertNil(WindowHitTest.topmost(at: CGPoint(x: 10, y: 10), in: [win]),
                     "点击落空(空桌面):返回 nil → 截图模式不快门、覆盖层保持(spec S1)")
        XCTAssertNil(WindowHitTest.topmost(at: .zero, in: []), "空列表不崩")
    }
}
