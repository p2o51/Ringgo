import XCTest
@testable import C2SCore

/// F20/F24 CG 全局坐标换算(spec §8/§11):SCWindow/CGWindowList 的 frame 是
/// 主屏左上原点、y 向下;错位在单屏开发期完全看不出来——单测必须覆盖
/// 副屏在主屏**上方**与**左侧(负坐标)**的用例,不许只测单屏。
final class DisplayContextCGGlobalTests: XCTestCase {

    /// 主屏 2560×1440(AppKit 全局原点在它左下角)。
    private let mainHeight: CGFloat = 1440

    func testMainDisplayIdentity() {
        // 主屏上:CG 全局(左上原点)与覆盖层本地(左上原点)应逐值相等
        let ctx = DisplayContext(displayID: 1,
                                 screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                 pointSize: CGSize(width: 2560, height: 1440),
                                 pixelSize: CGSize(width: 5120, height: 2880),
                                 scale: 2)
        let cg = CGRect(x: 300, y: 200, width: 800, height: 500)
        let overlay = ctx.overlayRect(fromCGGlobal: cg, mainDisplayHeight: mainHeight)
        XCTAssertEqual(overlay, cg, "主屏上两套左上原点坐标系重合")
    }

    func testSecondaryAboveMain() {
        // 副屏 1920×1080 摆在主屏正上方:AppKit y = 1440…2520,CG y = -1080…0
        let ctx = DisplayContext(displayID: 2,
                                 screenFrame: CGRect(x: 0, y: 1440, width: 1920, height: 1080),
                                 pointSize: CGSize(width: 1920, height: 1080),
                                 pixelSize: CGSize(width: 3840, height: 2160),
                                 scale: 2)
        // 窗口距副屏顶 100pt:CG y = -1080 + 100 = -980
        let cg = CGRect(x: 100, y: -980, width: 400, height: 300)
        let overlay = ctx.overlayRect(fromCGGlobal: cg, mainDisplayHeight: mainHeight)
        XCTAssertEqual(overlay, CGRect(x: 100, y: 100, width: 400, height: 300),
                       "CG 负 y(主屏上方)必须正确落到副屏本地坐标")
    }

    func testSecondaryLeftOfMainNegativeX() {
        // 副屏在主屏左侧(负 x),顶边与主屏顶对齐:AppKit (−1920, 360, 1920, 1080)
        let ctx = DisplayContext(displayID: 3,
                                 screenFrame: CGRect(x: -1920, y: 360, width: 1920, height: 1080),
                                 pointSize: CGSize(width: 1920, height: 1080),
                                 pixelSize: CGSize(width: 3840, height: 2160),
                                 scale: 2)
        let cg = CGRect(x: -1500, y: 200, width: 600, height: 400)
        let overlay = ctx.overlayRect(fromCGGlobal: cg, mainDisplayHeight: mainHeight)
        XCTAssertEqual(overlay, CGRect(x: 420, y: 200, width: 600, height: 400),
                       "负 x 副屏:x 只做平移,y 经主屏高换轴")
    }

    func testRoundTrip() {
        let ctx = DisplayContext(displayID: 2,
                                 screenFrame: CGRect(x: -1920, y: 360, width: 1920, height: 1080),
                                 pointSize: CGSize(width: 1920, height: 1080),
                                 pixelSize: CGSize(width: 3840, height: 2160),
                                 scale: 2)
        let overlay = CGRect(x: 37, y: 91, width: 240, height: 180)
        let cg = ctx.cgGlobalRect(fromOverlay: overlay, mainDisplayHeight: mainHeight)
        let back = ctx.overlayRect(fromCGGlobal: cg, mainDisplayHeight: mainHeight)
        XCTAssertEqual(back, overlay, "overlay → CG → overlay 必须无损往返")
    }
}
