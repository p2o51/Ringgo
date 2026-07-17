import XCTest
@testable import C2SCore

/// F22 标注模型与渲染(spec §11):命中(最上层优先)/移动/序号自增/
/// 压平几何(含裁剪)/像素级抽查(压平真的画上去了)。
final class AnnotationTests: XCTestCase {

    private func solidImage(width: Int, height: Int,
                            r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    func testHitTestTopmostWins() {
        var doc = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300))
        let bottom = AnnotationObject(shape: .rect(CGRect(x: 50, y: 50, width: 100, height: 100), filled: true),
                                      color: .presetRed, lineWidth: 4)
        let top = AnnotationObject(shape: .rect(CGRect(x: 80, y: 80, width: 100, height: 100), filled: true),
                                   color: .presetBlue, lineWidth: 4)
        doc.add(bottom)
        doc.add(top)
        XCTAssertEqual(doc.hitTest(at: CGPoint(x: 100, y: 100), tolerance: 6), top.id,
                       "重叠区命中后画的(最上层)")
        XCTAssertEqual(doc.hitTest(at: CGPoint(x: 60, y: 60), tolerance: 6), bottom.id)
        XCTAssertNil(doc.hitTest(at: CGPoint(x: 300, y: 250), tolerance: 6))
    }

    func testHollowRectHitsBorderOnly() {
        var doc = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300))
        let hollow = AnnotationObject(shape: .rect(CGRect(x: 50, y: 50, width: 200, height: 150), filled: false),
                                      color: .presetRed, lineWidth: 4)
        doc.add(hollow)
        XCTAssertEqual(doc.hitTest(at: CGPoint(x: 50, y: 120), tolerance: 6), hollow.id, "边框命中")
        XCTAssertNil(doc.hitTest(at: CGPoint(x: 150, y: 120), tolerance: 6), "空心框内部不命中(不挡选择)")
    }

    func testMoveTranslatesShape() {
        var doc = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300))
        let arrow = AnnotationObject(shape: .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 50)),
                                     color: .presetRed, lineWidth: 4)
        doc.add(arrow)
        doc.move(id: arrow.id, by: CGVector(dx: 20, dy: -5))
        guard case .arrow(let from, let to)? = doc.object(id: arrow.id)?.shape else {
            return XCTFail("形状类型不应改变")
        }
        XCTAssertEqual(from, CGPoint(x: 30, y: 5))
        XCTAssertEqual(to, CGPoint(x: 120, y: 45))
    }

    func testCounterAutoIncrement() {
        var doc = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300))
        XCTAssertEqual(doc.nextCounterNumber, 1)
        doc.add(AnnotationObject(shape: .counter(center: .zero, number: 1), color: .presetRed, lineWidth: 4))
        doc.add(AnnotationObject(shape: .counter(center: .zero, number: 2), color: .presetRed, lineWidth: 4))
        doc.remove(id: doc.objects[0].id)
        XCTAssertEqual(doc.nextCounterNumber, 3, "序号 = 现存最大 + 1(删除不回收,防重号)")
    }

    func testFlattenSizeAndCrop() {
        let source = solidImage(width: 100, height: 80)
        var doc = AnnotationDocument(pixelSize: CGSize(width: 100, height: 80))
        let flat = AnnotationRenderer.flatten(doc, source: source)
        XCTAssertEqual(flat?.width, 100)
        XCTAssertEqual(flat?.height, 80)

        doc.cropRect = CGRect(x: 10, y: 10, width: 50, height: 40)
        let cropped = AnnotationRenderer.flatten(doc, source: source)
        XCTAssertEqual(cropped?.width, 50, "非破坏裁剪:压平按裁剪窗出图")
        XCTAssertEqual(cropped?.height, 40)
    }

    func testFlattenActuallyDraws() {
        // 白底 + 红实心框 → 框内像素变红、框外仍白;左上原点语义(y 向下)成立
        let source = solidImage(width: 100, height: 100)
        var doc = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100))
        doc.add(AnnotationObject(shape: .rect(CGRect(x: 10, y: 10, width: 30, height: 30), filled: true),
                                 color: .presetRed, lineWidth: 2))
        guard let flat = AnnotationRenderer.flatten(doc, source: source) else {
            return XCTFail("压平失败")
        }
        let inside = pixel(flat, x: 25, y: 25)
        XCTAssertGreaterThan(inside.r, 180, "框内应为红色(模型左上原点 → 位图同位)")
        XCTAssertLessThan(inside.g, 110)
        let outside = pixel(flat, x: 80, y: 80)
        XCTAssertGreaterThan(outside.g, 230, "框外保持白底")
    }

    func testSpotlightDimsOutsideOnly() {
        let source = solidImage(width: 100, height: 100)
        var doc = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100))
        doc.add(AnnotationObject(shape: .spotlight(CGRect(x: 40, y: 40, width: 20, height: 20)),
                                 color: .presetRed, lineWidth: 2))
        guard let flat = AnnotationRenderer.flatten(doc, source: source) else {
            return XCTFail("压平失败")
        }
        let inside = pixel(flat, x: 50, y: 50)
        let outside = pixel(flat, x: 10, y: 10)
        XCTAssertGreaterThan(inside.r, 230, "聚光区内保持原亮")
        XCTAssertLessThan(outside.r, 160, "聚光区外压暗")
    }

    func testOverlappingSpotlightsKeepIntersectionBright() {
        // even-odd 的 XOR 陷阱回归用例(2026-07-17 审查实测):两枚相交聚光,
        // 交集必须保持原亮(并集语义),不能被重新压暗
        let source = solidImage(width: 100, height: 100)
        var doc = AnnotationDocument(pixelSize: CGSize(width: 100, height: 100))
        doc.add(AnnotationObject(shape: .spotlight(CGRect(x: 20, y: 20, width: 40, height: 40)),
                                 color: .presetRed, lineWidth: 2))
        doc.add(AnnotationObject(shape: .spotlight(CGRect(x: 40, y: 40, width: 40, height: 40)),
                                 color: .presetRed, lineWidth: 2))
        guard let flat = AnnotationRenderer.flatten(doc, source: source) else {
            return XCTFail("压平失败")
        }
        XCTAssertGreaterThan(pixel(flat, x: 50, y: 50).r, 230, "交集区保持原亮(并集语义)")
        XCTAssertGreaterThan(pixel(flat, x: 30, y: 30).r, 230, "仅第一枚覆盖的区域原亮")
        XCTAssertGreaterThan(pixel(flat, x: 70, y: 70).r, 230, "仅第二枚覆盖的区域原亮")
        XCTAssertLessThan(pixel(flat, x: 10, y: 90).r, 160, "两枚都不覆盖的区域压暗")
    }
}
