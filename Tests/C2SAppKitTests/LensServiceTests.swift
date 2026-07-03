import XCTest
import CoreGraphics
@testable import C2SAppKit

/// Lens v2(面板内表单上传)的可单测部分:HTML 生成、转义、降采样、载荷。
final class LensServiceTests: XCTestCase {

    private func makeImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testUploadHTMLStructure() {
        let html = LensService.uploadHTML(jpegBase64: "QUJDRA==",
                                          pixelSize: CGSize(width: 640, height: 480),
                                          languageCode: "zh-CN",
                                          timestampMillis: 1_700_000_000_123)
        // 表单要素
        XCTAssertTrue(html.contains("method=\"post\""))
        XCTAssertTrue(html.contains("enctype=\"multipart/form-data\""))
        XCTAssertTrue(html.contains("name=\"encoded_image\""))
        XCTAssertTrue(html.contains("name=\"processed_image_dimensions\" value=\"640,480\""))
        XCTAssertTrue(html.contains(".submit()"), "必须自动提交")
        XCTAssertTrue(html.contains("'QUJDRA=='"), "base64 嵌入 JS 单引号串")
        // action URL:& 必须转义为 &amp;(HTML 属性语境),且不得残留裸 &
        guard let actionStart = html.range(of: "action=\""),
              let actionEnd = html.range(of: "\"", range: actionStart.upperBound..<html.endIndex) else {
            return XCTFail("找不到 action 属性")
        }
        let action = String(html[actionStart.upperBound..<actionEnd.lowerBound])
        XCTAssertTrue(action.hasPrefix("https://lens.google.com/v3/upload?"))
        XCTAssertTrue(action.contains("st=1700000000123"))
        XCTAssertTrue(action.contains("hl=zh-CN"))
        XCTAssertTrue(action.contains("vpw=640") && action.contains("vph=480"))
        XCTAssertFalse(action.replacingOccurrences(of: "&amp;", with: "").contains("&"),
                       "action 里不得有未转义的 &: \(action)")
    }

    func testUploadPayloadPropagatesAttemptAndBase() throws {
        let service = LensService()
        let payload = try service.uploadPayload(for: makeImage(width: 320, height: 200), attempt: 7)
        XCTAssertEqual(payload.attempt, 7)
        XCTAssertEqual(payload.baseURL.absoluteString, "https://www.google.com/")
        XCTAssertTrue(payload.html.contains("value=\"320,200\""))
    }

    func testDownscaleKeepsSmallImage() {
        let img = makeImage(width: 800, height: 600)
        let out = LensService.downscaled(img, maxDimension: 1600)
        XCTAssertEqual(out?.width, 800)
        XCTAssertEqual(out?.height, 600)
    }

    func testDownscaleShrinksLargeImageProportionally() {
        let img = makeImage(width: 3200, height: 1600)
        let out = LensService.downscaled(img, maxDimension: 1600)
        XCTAssertEqual(out?.width, 1600)
        XCTAssertEqual(out?.height, 800)
    }

    func testJpegEncodeProducesJFIF() throws {
        let data = try XCTUnwrap(LensService.jpegEncoded(makeImage(width: 64, height: 64), quality: 0.85))
        XCTAssertGreaterThan(data.count, 100)
        XCTAssertEqual(data.prefix(3), Data([0xFF, 0xD8, 0xFF]), "JPEG magic")
    }
}
