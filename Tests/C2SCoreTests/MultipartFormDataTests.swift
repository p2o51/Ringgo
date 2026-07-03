import XCTest
@testable import C2SCore

/// 字节级验证 multipart 构造 —— 原项目双反斜杠 bug 的回归防线(机制 §7)。
final class MultipartFormDataTests: XCTestCase {

    func testExactBodyBytes() {
        var form = MultipartFormData(boundary: "XYZ")
        form.appendField(name: "processed_image_dimensions", value: "800,600")
        form.appendFile(name: "encoded_image", filename: "image.jpg",
                        mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
        let body = form.finalizedBody()

        var expected = Data()
        expected.append(Data("--XYZ\r\n".utf8))
        expected.append(Data("Content-Disposition: form-data; name=\"processed_image_dimensions\"\r\n\r\n".utf8))
        expected.append(Data("800,600\r\n".utf8))
        expected.append(Data("--XYZ\r\n".utf8))
        expected.append(Data("Content-Disposition: form-data; name=\"encoded_image\"; filename=\"image.jpg\"\r\n".utf8))
        expected.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        expected.append(Data([0xFF, 0xD8, 0xFF]))
        expected.append(Data("\r\n".utf8))
        expected.append(Data("--XYZ--\r\n".utf8))

        XCTAssertEqual(body, expected)
    }

    func testNoLiteralEscapeSequencesInBody() {
        var form = MultipartFormData(boundary: "BOUND")
        form.appendField(name: "a", value: "b")
        let body = form.finalizedBody()
        // 双反斜杠 bug 的特征:body 里出现字面量 "\r\n"(0x5C 0x72)或 "\(boundary)"
        XCTAssertFalse(body.contains(subdata: Data("\\r\\n".utf8)), "不得出现字面量 \\r\\n")
        XCTAssertFalse(body.contains(subdata: Data("\\(".utf8)), "不得出现未插值的 \\(")
        // 真 CRLF 必须存在
        XCTAssertTrue(body.contains(subdata: Data([0x0D, 0x0A])))
    }

    func testHeaderBoundaryMatchesBodyBoundary() {
        let form = MultipartFormData()
        XCTAssertEqual(form.contentTypeHeaderValue, "multipart/form-data; boundary=\(form.boundary)")
        var f2 = form
        f2.appendField(name: "x", value: "y")
        let body = f2.finalizedBody()
        XCTAssertTrue(body.contains(subdata: Data("--\(form.boundary)\r\n".utf8)))
        XCTAssertTrue(body.contains(subdata: Data("--\(form.boundary)--\r\n".utf8)))
    }
}

private extension Data {
    func contains(subdata needle: Data) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        return range(of: needle) != nil
    }
}
