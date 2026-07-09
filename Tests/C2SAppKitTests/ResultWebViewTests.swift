import XCTest
import WebKit
@testable import C2SAppKit

final class ResultWebViewTests: XCTestCase {

    // MARK: - ⌘C 路由:结果面板 WebView 聚焦时放行系统复制(否则被选区复制劫持)

    /// WebView 聚焦时 firstResponder 是内部内容视图(WKWebView 的子视图),
    /// 沿 superview 链上溯应判定为「在 WebView 内」→ ⌘C 归网页,复制 AI Mode 回答。
    @MainActor
    func testResponderInsideWebViewIsDetected() {
        let webView = WKWebView(frame: .zero)
        let contentView = NSView(frame: .zero) // 模拟内部 WKContentView
        webView.addSubview(contentView)

        XCTAssertTrue(OverlayWindowController.responderIsInWebView(contentView),
                      "WebView 子视图聚焦 = 焦点在网页里,⌘C 必须放行给 WebView")
        XCTAssertTrue(OverlayWindowController.responderIsInWebView(webView),
                      "WebView 本身聚焦也算在网页里")
    }

    /// 覆盖层画布 / 底部输入框等非 WebView 的响应者:不放行,⌘C 归选区复制。
    @MainActor
    func testResponderOutsideWebViewIsNotDetected() {
        XCTAssertFalse(OverlayWindowController.responderIsInWebView(nil))
        XCTAssertFalse(OverlayWindowController.responderIsInWebView(NSView(frame: .zero)))
        XCTAssertFalse(OverlayWindowController.responderIsInWebView(NSTextView(frame: .zero)),
                       "输入框(NSTextView)不是 WebView,走上面的选中长度判定,不走这条")
    }

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
