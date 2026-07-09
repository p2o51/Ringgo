import AppKit
import SwiftUI
import WebKit

/// 右键菜单增强(2026-07-03):右键链接时经 JS 捎回 href,
/// willOpenMenu 里在「打开链接」后插一项「在默认浏览器中打开」。
/// 结果面板与详情屏共用。
final class ContextMenuWebView: WKWebView {
    var lastContextLink: URL?
    /// 经右键菜单打开浏览器后的回调(调用方决定是否退出覆盖层)。
    var onDidOpenInBrowser: (() -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard lastContextLink != nil else { return } // 右键不在链接上 → 原菜单
        let openTitle = L10n.t("common.open_in_browser", "在默认浏览器中打开")
        let item = NSMenuItem(title: openTitle,
                              action: #selector(openContextLinkInBrowser(_:)),
                              keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "arrow.up.forward.app",
                             accessibilityDescription: openTitle)
        // 插在系统「打开链接」之后;找不到就置顶
        let anchor = menu.items.firstIndex {
            $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
        }
        menu.insertItem(item, at: anchor.map { $0 + 1 } ?? 0)
    }

    @objc private func openContextLinkInBrowser(_ sender: Any?) {
        guard let url = lastContextLink else { return }
        NSWorkspace.shared.open(url)
        onDidOpenInBrowser?() // 退出覆盖层,浏览器就在眼前
    }
}

/// contextmenu 事件 → 把链接 href 递回原生侧(空串 = 右键不在链接上)。
enum ContextLinkBridge {
    static let messageName = "c2sContextLink"
    static let script = """
    document.addEventListener('contextmenu', function (event) {
      var anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
      try {
        window.webkit.messageHandlers.c2sContextLink.postMessage(anchor ? anchor.href : '');
      } catch (e) {}
    }, true);
    """

    /// 给配置装上桥(脚本进全部 frame;handler 弱持 webView,无环)。
    static func install(on configuration: WKWebViewConfiguration) -> Handler {
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let handler = Handler()
        configuration.userContentController.add(handler, name: messageName)
        return handler
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        weak var webView: ContextMenuWebView?
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            let href = message.body as? String ?? ""
            webView?.lastContextLink = href.isEmpty ? nil : URL(string: href)
        }
    }
}

/// 面板 WebView 的加载源。token 变化 = 强制重新加载:
/// 去重只为挡住 SwiftUI 重绘风暴,同 query 的「新一次搜索」必须照常加载
/// (用户可能已在 WebView 里点走,重选同一个词不能静默无效)。
enum WebSource: Equatable {
    case url(URL, token: Int)
    /// Lens 面板内上传:自动提交表单(见 LensUploadPayload)。
    case lensUpload(html: String, baseURL: URL, token: Int)
}

/// WKWebView 封装(机制 §7):伪装 Safari UA、加载源去重防重载循环、
/// 403 风控检测(→ onBlocked)、`/sorry` 验证码页放行(用户可在面板内完成验证)、
/// 完整 navigation delegate 生命周期、加载态回报。
///
/// dataStore 用 `.default()`(持久):Lens 上传与结果同会话;
/// 用户在面板里登录过 Google 后 cookie 留存,风控 403 即根治。
struct ResultWebView: NSViewRepresentable {
    let source: WebSource
    @Binding var isLoading: Bool
    /// Google 风控拦截(403)回调,参数 = 用户可读原因。
    var onBlocked: ((String) -> Void)?
    /// Lens 顶层导航失败回调(离线、DNS、TLS 等)。
    var onFailure: ((String) -> Void)?
    /// 主 frame URL 变化(multisearch 需要拿到带 vsrid 的当前结果页 URL)。
    var onURLChange: ((URL?) -> Void)?
    /// 离开 Google 域的主框架导航(点结果链接/重定向落地/target=_blank)→ 交给详情屏。
    /// 结果面板永远停在 Google 上下文,外部页面在旁边的详情屏打开(2026-07-03 双联屏)。
    var onOpenDetail: ((URL) -> Void)?
    /// 右键菜单「在默认浏览器中打开」执行后(二级菜单已是确认,直接退出覆盖层)。
    var onOpenedInBrowser: (() -> Void)?

    /// iPhone Safari UA:面板是手机比例(390pt),必须要 Google 的**移动版**布局;
    /// 桌面 UA 会按桌面宽度渲染导致横向裁切。上传与结果同一 UA(会话一致)。
    private static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// google.com/search 去重脚本:查询 UI 统一走面板药丸(文字)/覆盖层可调矩形(图),
    /// Google 自带的顶部搜索条(logo 行 + #tsf 表单,图搜时还含缩略图)纯属重复 → 隐藏。
    /// 结构实测(2026-07-03,移动 UA):顶层 <header> h=107 包住 logo+表单,筛选 tabs 在其外,保留。
    /// 只作用于 /search 路径;登录页、/sorry、第三方站一律不动。
    private static let declutterScript = #"""
    (function () {
      if (!/(^|\.)google\./.test(location.hostname) || location.pathname !== '/search') { return; }
      if (document.getElementById('c2s-declutter')) { return; }
      var style = document.createElement('style');
      style.id = 'c2s-declutter';
      style.textContent = 'body > header, #tsf, #sfcnt { display: none !important; }'
        + ' body { margin-top: 0 !important; padding-top: 0 !important; }';
      document.documentElement.appendChild(style);
      // Google 会整块重渲染,style 被移除就补回(CSS 选择器天然覆盖新节点)
      var observer = new MutationObserver(function () {
        if (!document.getElementById('c2s-declutter')) {
          document.documentElement.appendChild(style);
        }
      });
      observer.observe(document.documentElement, { childList: true, subtree: false });
    })();
    """#

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // 持久会话(Lens 绑定 + 登录留存)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.declutterScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        let contextHandler = ContextLinkBridge.install(on: config)
        let webView = ContextMenuWebView(frame: .zero, configuration: config)
        contextHandler.webView = webView
        context.coordinator.contextHandler = contextHandler
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator // target=_blank / window.open 在本视图内打开
        webView.allowsMagnification = true
        // 背景透明化(不强求):页面边界外区域与面板材质融合
        webView.underPageBackgroundColor = .clear
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self // 每次更新刷新 binding/闭包
        // SwiftUI 重绘(拖拽面板等)会反复进这里:源未变绝不重复加载(防重载循环)
        (webView as? ContextMenuWebView)?.onDidOpenInBrowser = onOpenedInBrowser
        guard context.coordinator.lastSource != source else { return }
        context.coordinator.lastSource = source
        switch source {
        case .url(let url, _):
            webView.load(URLRequest(url: url))
        case .lensUpload(let html, let baseURL, _):
            // 顶层表单 POST 导航上传(免 CORS),WebView 跟随 303 落到结果页
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

        // target=_blank / window.open:外部站点 → 详情屏;Google 内链就地加载
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                if let onOpenDetail = parent.onOpenDetail, ResultWebView.isExternalDestination(url) {
                    onOpenDetail(url)
                } else {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        /// 主框架驶向 Google 生态之外(点结果链接 / google.com/url 重定向落地)
        /// → 取消并交给详情屏:结果面板永远停在 Google 上下文(2026-07-03 双联屏)。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let onOpenDetail = parent.onOpenDetail,
               navigationAction.targetFrame?.isMainFrame ?? true,
               let url = navigationAction.request.url,
               ResultWebView.isExternalDestination(url) {
                onOpenDetail(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        var parent: ResultWebView
        var lastSource: WebSource?
        var contextHandler: ContextLinkBridge.Handler?

        init(_ parent: ResultWebView) { self.parent = parent }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            // Google 风控:匿名会话在部分网络出口对结果页直接 403。
            // 只对主 frame 判定;取消导航,交给错误卡(重试 / 登录 Google)。
            if navigationResponse.isForMainFrame,
               let http = navigationResponse.response as? HTTPURLResponse,
               ResultWebView.shouldTreatAsLensAccessBlock(http),
               parent.onBlocked != nil {
                parent.isLoading = false
                parent.onBlocked?(L10n.t("result.blocked_403", "Google 拒绝了匿名访问(403)。在面板里登录一次 Google 后即可正常识图。"))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.onURLChange?(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.onURLChange?(webView.url)
            // `/sorry` 验证码页刻意放行:用户可直接在面板里完成人机验证,
            // 通过后 Google 自动跳回结果页(绝不自动重载,防循环)。
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(in: webView, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 新导航顶掉旧导航产生的取消(-999)不算失败,交给新导航的回调驱动加载态
            handleNavigationFailure(in: webView, error: error)
        }

        private func handleNavigationFailure(in webView: WKWebView, error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.isLoading = false
            guard parent.onFailure != nil,
                  ResultWebView.shouldReportLensNavigationFailure(error, currentURL: webView.url)
            else { return }
            parent.onFailure?(L10n.f("result.image_search_network_failed", "图像搜索网络连接失败：%@", error.localizedDescription))
        }
    }

    /// 详情屏领地判定(v2,2026-07-03 实测修正):主面板只保留**搜索/会话必需面**;
    /// `*.google.com` 全放行是漏洞 —— support.google.com 等内容型子域也该进详情屏。
    static func isExternalDestination(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http"),
              let host = url.host?.lowercased() else { return false }
        // 搜索/会话面:结果页、Lens 上传会话、登录、consent
        let internalHosts: Set<String> = [
            "google.com", "www.google.com", "lens.google.com",
            "accounts.google.com", "consent.google.com", "myaccount.google.com",
        ]
        if internalHosts.contains(host) { return false }
        // 资源域(子帧素材;主框架基本不会落在这里,保守放行)
        let assetSuffixes = ["gstatic.com", "googleusercontent.com", "googleapis.com"]
        if assetSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        return true
    }

    /// 只把 Lens 会话自身的 403 当作匿名风控;验证码、登录页和普通外链必须照常展示。
    static func shouldTreatAsLensAccessBlock(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 403
            && isLensSessionURL(response.url)
            && response.url?.path.contains("/sorry") != true
    }

    /// Lens 表单/结果导航的网络失败才进入图搜错误卡;普通网页失败保留 WebKit 行为。
    static func shouldReportLensNavigationFailure(_ error: Error, currentURL: URL?) -> Bool {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return false }
        // 403 路径的 decisionHandler(.cancel) 会让 WebKit 补发
        // "Frame load interrupted"(WebKitErrorDomain 102)——它不是网络失败,
        // 绝不能覆盖 onBlocked 已弹出的「登录 Google」恢复卡
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return false }
        let failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? currentURL
        return isLensSessionURL(failingURL)
    }

    /// Lens 会话 URL = 上传端点(lens.google.com)或上传 303 之后的结果页
    /// (www.google.com/search?vsrid=…)。实测(2026-07-02)匿名风控 403 就发生在
    /// 后者 —— 只认 lens.google.com 会漏掉真实拦截;而结果页内点开的第三方站 403
    /// 因 host 不属 Google 而照常展示。
    static func isLensSessionURL(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        if host == "lens.google.com" || host.hasSuffix(".lens.google.com") { return true }
        if (host == "www.google.com" || host == "google.com"), url.path.hasPrefix("/search") { return true }
        return false
    }
}
