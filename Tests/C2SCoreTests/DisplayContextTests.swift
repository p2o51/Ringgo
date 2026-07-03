import XCTest
import CoreGraphics
@testable import C2SCore

final class DisplayContextTests: XCTestCase {

    /// 2x Retina 屏,截图像素 = 点 × 2。
    private var retina: DisplayContext {
        DisplayContext(displayID: 1,
                       screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                       pointSize: CGSize(width: 1512, height: 982),
                       pixelSize: CGSize(width: 3024, height: 1964),
                       scale: 2)
    }

    /// 1x 外接屏(原项目写死 ×2 在这种屏上全错)。
    private var external1x: DisplayContext {
        DisplayContext(displayID: 2,
                       screenFrame: CGRect(x: 1512, y: 100, width: 1920, height: 1080),
                       pointSize: CGSize(width: 1920, height: 1080),
                       pixelSize: CGSize(width: 1920, height: 1080),
                       scale: 1)
    }

    func testVisionNormalizedToOverlayFlipsY() {
        let ctx = DisplayContext(displayID: 0, screenFrame: .zero,
                                 pointSize: CGSize(width: 1000, height: 500),
                                 pixelSize: CGSize(width: 2000, height: 1000), scale: 2)
        // Vision 左下原点 (0.1, 0.2) 尺寸 (0.3, 0.1)
        let r = ctx.overlayRect(fromNormalized: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        XCTAssertEqual(r.minX, 100, accuracy: 0.001)
        XCTAssertEqual(r.minY, (1 - 0.2 - 0.1) * 500, accuracy: 0.001) // = 350
        XCTAssertEqual(r.width, 300, accuracy: 0.001)
        XCTAssertEqual(r.height, 50, accuracy: 0.001)
    }

    func testOverlayToPixelPureScaleNoFlip() {
        let px = retina.pixelRect(fromOverlay: CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(px, CGRect(x: 20, y: 40, width: 200, height: 100))
    }

    func testOverlayToPixelOn1xScreen() {
        let px = external1x.pixelRect(fromOverlay: CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(px, CGRect(x: 10, y: 20, width: 100, height: 50), "1x 屏必须 1:1,不得残留 ×2")
    }

    func testPixelRectClampsToImageBounds() {
        let px = retina.pixelRect(fromOverlay: CGRect(x: 1500, y: 970, width: 100, height: 100))
        XCTAssertFalse(px.isNull)
        XCTAssertLessThanOrEqual(px.maxX, retina.pixelSize.width)
        XCTAssertLessThanOrEqual(px.maxY, retina.pixelSize.height)
    }

    func testPixelRectFullyOutsideReturnsNull() {
        let px = retina.pixelRect(fromOverlay: CGRect(x: 5000, y: 5000, width: 10, height: 10))
        XCTAssertTrue(px.isNull)
    }

    func testEffectiveScaleUsesRealImageRatioNotDeclaredScale() {
        // 缩放分辨率场景:声明 scale=2 但实际像素比是 1.5(以真实图像为准)
        let ctx = DisplayContext(displayID: 3, screenFrame: .zero,
                                 pointSize: CGSize(width: 1000, height: 1000),
                                 pixelSize: CGSize(width: 1500, height: 1500), scale: 2)
        XCTAssertEqual(ctx.effectiveScaleX, 1.5, accuracy: 0.001)
        let px = ctx.pixelRect(fromOverlay: CGRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertEqual(px, CGRect(x: 150, y: 150, width: 300, height: 300))
    }

    func testGlobalPointToOverlayLocal() {
        // 副屏 frame (1512, 100, 1920×1080),全局点(AppKit 左下)→ 本地左上
        let p = external1x.overlayPoint(fromGlobal: CGPoint(x: 1512 + 50, y: 100 + 980))
        XCTAssertEqual(p.x, 50, accuracy: 0.001)
        XCTAssertEqual(p.y, 1080 - 980, accuracy: 0.001) // = 100
    }

    /// 端到端一致性:Vision 框 → 覆盖层 → 像素,应还原到原始像素框(整像素内)。
    func testRoundTripVisionToPixel() {
        let ctx = retina
        // 假设 OCR 在像素图上认出一个词:像素框(左上)(400, 300, 220, 44)
        let pixelTruth = CGRect(x: 400, y: 300, width: 220, height: 44)
        // Vision 会报归一化左下:
        let normalized = CGRect(x: pixelTruth.minX / ctx.pixelSize.width,
                                y: (ctx.pixelSize.height - pixelTruth.maxY) / ctx.pixelSize.height,
                                width: pixelTruth.width / ctx.pixelSize.width,
                                height: pixelTruth.height / ctx.pixelSize.height)
        let overlay = ctx.overlayRect(fromNormalized: normalized)
        let roundTrip = ctx.pixelRect(fromOverlay: overlay)
        XCTAssertEqual(roundTrip.minX, pixelTruth.minX, accuracy: 1)
        XCTAssertEqual(roundTrip.minY, pixelTruth.minY, accuracy: 1)
        XCTAssertEqual(roundTrip.width, pixelTruth.width, accuracy: 1)
        XCTAssertEqual(roundTrip.height, pixelTruth.height, accuracy: 1)
    }
}
