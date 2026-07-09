import XCTest
@testable import C2SCore

final class BarcodePayloadTests: XCTestCase {

    private func urlValue(_ s: String) -> URL? {
        if case .url(let u) = BarcodePayload.classify(s).content { return u }
        return nil
    }
    private func isText(_ s: String) -> Bool {
        if case .text = BarcodePayload.classify(s).content { return true }
        return false
    }

    func testHTTPAndHTTPSAreURLs() {
        XCTAssertEqual(urlValue("http://example.com"), URL(string: "http://example.com"))
        XCTAssertEqual(urlValue("https://example.com/path?q=1"),
                       URL(string: "https://example.com/path?q=1"))
    }

    /// scheme 大小写不敏感(部分二维码全大写编码)。
    func testUppercaseSchemeIsURL() {
        XCTAssertNotNil(urlValue("HTTPS://Example.com"))
    }

    /// 解码常带首尾空白/换行 —— 分类前必须 trim,否则 URL 解析失败误判为文本。
    func testWhitespaceIsTrimmedBeforeParsing() {
        XCTAssertNotNil(urlValue("  https://example.com\n"))
    }

    func testBareDomainIsText() { XCTAssertTrue(isText("example.com")) }       // scheme 为 nil
    func testMailtoIsText() { XCTAssertTrue(isText("mailto:a@b.com")) }
    func testTelIsText() { XCTAssertTrue(isText("tel:+8613800000000")) }
    func testWifiIsText() { XCTAssertTrue(isText("WIFI:S:MyNet;T:WPA;P:secret;;")) }
    func testPlainTextIsText() { XCTAssertTrue(isText("hello world")) } // macOS14 宽松解析也不得误判
    func testEmptyIsText() { XCTAssertTrue(isText("")) }

    /// payload 保留完整原文,供文本卡复制全文(view 层才截断)。
    func testPayloadPreservesFullOriginal() {
        let raw = "WIFI:S:MyNet;T:WPA;P:secret;;"
        XCTAssertEqual(BarcodePayload.classify(raw).payload, raw)
    }
}
