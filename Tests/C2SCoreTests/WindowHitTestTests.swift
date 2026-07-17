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

    // MARK: - F24 v2 全窗角标(遮挡剔除)

    func testCornerHandleOccludedByFrontWindow() {
        // 后窗右下角恰好被前窗盖住 → 后窗角标剔除,前窗保留
        let front = window(1, CGRect(x: 300, y: 200, width: 500, height: 400))
        let back = window(2, CGRect(x: 100, y: 100, width: 400, height: 300)) // 右下角(500,400)在前窗内
        let handles = WindowCornerHandles.visible(in: [front, back],
                                                  viewport: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(handles.map(\.windowID), [1],
                       "被更前窗口遮住角的不画——角标不能浮在别人内容上")
    }

    func testCornerHandleVisibleWhenCornerClear() {
        // 两窗重叠但后窗右下角露在外面 → 两枚角标都在
        let front = window(1, CGRect(x: 100, y: 100, width: 300, height: 200))
        let back = window(2, CGRect(x: 200, y: 150, width: 600, height: 500))
        let handles = WindowCornerHandles.visible(in: [front, back],
                                                  viewport: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(handles.map(\.windowID), [1, 2])
        // 角标锚点 = frame 右下角内缩 10pt
        XCTAssertEqual(handles[1].corner, CGPoint(x: 790, y: 640))
    }

    func testCornerHandleClipsToViewport() {
        // 窗口伸出屏幕右缘:角标跟着裁剪后的 frame 走,不出屏
        let win = window(1, CGRect(x: 1400, y: 100, width: 600, height: 400))
        let handles = WindowCornerHandles.visible(in: [win],
                                                  viewport: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(handles.first?.corner, CGPoint(x: 1590, y: 490))
        XCTAssertEqual(handles.first?.frame, CGRect(x: 1400, y: 100, width: 200, height: 400))
    }

    func testTinyWindowGetsNoHandle() {
        let win = window(1, CGRect(x: 100, y: 100, width: 50, height: 30))
        XCTAssertTrue(WindowCornerHandles.visible(in: [win],
                                                  viewport: CGSize(width: 1600, height: 1000)).isEmpty,
                      "过小窗口(< 60×44)不给角标")
    }

    func testSliverWindowGetsNoHandle() {
        // 2026-07-17 Ghostty 幽灵角标实测还原:后窗只比前窗高出一条底边细缝,
        // 角「没被挡」但窗口本体 96% 不可见 → 不给角标
        let front = window(1, CGRect(x: 0, y: 33, width: 1728, height: 974))     // Claude
        let back = window(2, CGRect(x: 361, y: 78, width: 1038, height: 974))    // Ghostty,底边多露 45pt
        let handles = WindowCornerHandles.visible(in: [front, back],
                                                  viewport: CGSize(width: 1728, height: 1117))
        XCTAssertEqual(handles.map(\.windowID), [1],
                       "只剩残条的窗口不给角标——用户认不出那条缝属于谁")
    }

    func testHalfVisibleWindowKeepsHandle() {
        // 半露的窗口(可见 ~50%)角又没被挡 → 正常给角标
        let front = window(1, CGRect(x: 0, y: 0, width: 500, height: 800))
        let back = window(2, CGRect(x: 300, y: 100, width: 700, height: 600))
        let handles = WindowCornerHandles.visible(in: [front, back],
                                                  viewport: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(handles.map(\.windowID), [1, 2])
    }
}
