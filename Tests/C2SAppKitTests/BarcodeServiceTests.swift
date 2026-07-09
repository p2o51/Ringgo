import XCTest
import CoreImage
import CoreGraphics
@testable import C2SAppKit
@testable import C2SCore

/// 端到端二维码冒烟:CoreImage 生成 QR → BarcodeService 检测 → 断言 payload 往返一致。
/// 真 Vision,较慢。
final class BarcodeServiceTests: XCTestCase {

    /// 用 `CIQRCodeGenerator` 造一张够大的 QR 位图(放大 10× 保证 Vision 稳定解码)。
    private func qrImage(_ message: String) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(message.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(output, from: output.extent)!
    }

    func testDecodesURLQRCode() async {
        let image = qrImage("https://example.com/hello")
        let result = await BarcodeService().detect(in: image)
        XCTAssertEqual(result?.payload, "https://example.com/hello")
        guard case .url(let u)? = result?.content else {
            return XCTFail("应分类为 URL: \(String(describing: result?.content))")
        }
        XCTAssertEqual(u, URL(string: "https://example.com/hello"))
    }

    func testDecodesTextQRCode() async {
        let payload = "WIFI:S:Net;T:WPA;P:pw;;"
        let result = await BarcodeService().detect(in: qrImage(payload))
        XCTAssertEqual(result?.payload, payload)
        guard case .text? = result?.content else {
            return XCTFail("非 URL 应分类为文本: \(String(describing: result?.content))")
        }
    }

    func testBlankImageReturnsNil() async {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let result = await BarcodeService().detect(in: ctx.makeImage()!)
        XCTAssertNil(result, "空白图不应误报二维码")
    }
}
