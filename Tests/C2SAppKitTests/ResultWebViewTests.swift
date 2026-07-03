import XCTest
@testable import C2SAppKit

final class ResultWebViewTests: XCTestCase {

    func testOnlyLens403IsReportedAsAnonymousAccessBlock() throws {
        let lens = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://lens.google.com/search?p=1")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil))
        let external = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/private")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil))
        let captcha = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://lens.google.com/sorry/index")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil))

        XCTAssertTrue(ResultWebView.shouldTreatAsLensAccessBlock(lens))
        XCTAssertFalse(ResultWebView.shouldTreatAsLensAccessBlock(external))
        XCTAssertFalse(ResultWebView.shouldTreatAsLensAccessBlock(captcha))
    }

    /// 实测(2026-07-02):真实的匿名风控 403 发生在上传 303 之后的
    /// www.google.com/search?vsrid=… —— 只认 lens.google.com 会漏掉真实拦截。
    func testGoogleSearchResult403IsTreatedAsAccessBlock() throws {
        let resultPage = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://www.google.com/search?vsrid=abc&udm=26")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil))
        let accounts = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://accounts.google.com/ServiceLogin")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil))
        let googleHome = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://www.google.com/")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil))

        XCTAssertTrue(ResultWebView.shouldTreatAsLensAccessBlock(resultPage),
                      "结果页 403 = 真实风控场景,必须触发恢复卡")
        XCTAssertFalse(ResultWebView.shouldTreatAsLensAccessBlock(accounts))
        XCTAssertFalse(ResultWebView.shouldTreatAsLensAccessBlock(googleHome))
    }

    func testOnlyLensNavigationFailuresUseImageSearchErrorCard() {
        let lensError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://lens.google.com/v3/upload")!])
        let externalError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://example.com/")!])

        XCTAssertTrue(ResultWebView.shouldReportLensNavigationFailure(lensError, currentURL: nil))
        XCTAssertFalse(ResultWebView.shouldReportLensNavigationFailure(externalError, currentURL: nil))
    }

    /// 403 → decisionHandler(.cancel) → WebKit 补发 "Frame load interrupted"(102):
    /// 不是网络失败,不得覆盖「登录 Google」恢复卡(用户实测截图场景)。
    func testFrameLoadInterruptedIsNotReportedAsFailure() {
        let interrupted = NSError(
            domain: "WebKitErrorDomain",
            code: 102,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://www.google.com/search?vsrid=x")!])

        XCTAssertFalse(ResultWebView.shouldReportLensNavigationFailure(interrupted, currentURL: nil))
    }

    func testCancelledLensNavigationIsNotReportedAsFailure() {
        let cancelled = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://lens.google.com/search")!])

        XCTAssertFalse(ResultWebView.shouldReportLensNavigationFailure(cancelled, currentURL: nil))
    }
}
