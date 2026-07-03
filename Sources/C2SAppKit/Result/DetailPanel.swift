import AppKit
import Combine
import SwiftUI
import WebKit

/// 详情屏(2026-07-03「双联手机屏」):点结果里的外部链接后,
/// 在结果面板旁滑出的第二块手机尺寸面板;顶栏 ‹ › ↗ ×。
/// 桌面端不全屏跳转 —— 结果上下文保持可见,详情在旁边展开。
@MainActor
final class DetailPanelModel: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURL: URL?

    weak var webView: WKWebView?
    var observers: Set<AnyCancellable> = []

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
}

struct DetailPanel: View {
    let url: URL
    let token: Int
    let size: CGSize
    let reduceEffects: Bool
    var onClose: () -> Void
    /// ↗ 确认打开 / 右键浏览器打开后:退出整个覆盖层。
    var onDismissOverlay: () -> Void = {}

    @StateObject private var model = DetailPanelModel()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 0) {
            navBar
            DetailWebView(initialURL: url, token: token, model: model,
                          onOpenedInBrowser: onDismissOverlay)
        }
        .frame(width: size.width, height: size.height)
        .panelGlassDetail(in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 8)
    }

    /// 顶栏:后退/前进 + 加载指示 + 浏览器打开 + 关闭。
    private var navBar: some View {
        HStack(spacing: 10) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoBack)
            .opacity(model.canGoBack ? 1 : 0.35)
            .accessibilityLabel("后退")

            Button { model.goForward() } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoForward)
            .opacity(model.canGoForward ? 1 : 0.35)
            .accessibilityLabel("前进")

            if model.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            Spacer(minLength: 0)

            ConfirmOpenButton(
                urlProvider: { model.currentURL ?? url },
                onOpened: onDismissOverlay)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭详情")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

/// 详情 WebView:iPhone UA(与结果面板一致),持久 dataStore;
/// canGoBack/Forward/URL/加载态经 KVO publisher 回流模型驱动顶栏。
private struct DetailWebView: NSViewRepresentable {
    let initialURL: URL
    let token: Int
    @ObservedObject var model: DetailPanelModel
    var onOpenedInBrowser: () -> Void = {}

    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let contextHandler = ContextLinkBridge.install(on: config)
        let webView = ContextMenuWebView(frame: .zero, configuration: config)
        contextHandler.webView = webView
        context.coordinator.contextHandler = contextHandler
        webView.customUserAgent = Self.mobileUA
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .clear

        model.webView = webView
        model.observers = [
            webView.publisher(for: \.canGoBack).receive(on: DispatchQueue.main)
                .sink { [weak model] in model?.canGoBack = $0 },
            webView.publisher(for: \.canGoForward).receive(on: DispatchQueue.main)
                .sink { [weak model] in model?.canGoForward = $0 },
            webView.publisher(for: \.isLoading).receive(on: DispatchQueue.main)
                .sink { [weak model] in model?.isLoading = $0 },
            webView.publisher(for: \.url).receive(on: DispatchQueue.main)
                .sink { [weak model] in model?.currentURL = $0 },
        ]
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        (webView as? ContextMenuWebView)?.onDidOpenInBrowser = onOpenedInBrowser
        let key = "\(token)|\(initialURL.absoluteString)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        webView.load(URLRequest(url: initialURL))
    }

    final class Coordinator {
        var lastKey: String?
        var contextHandler: ContextLinkBridge.Handler?
    }
}

/// 与主面板同款玻璃背板(私有扩展避免跨文件可见性)。
private extension View {
    @ViewBuilder
    func panelGlassDetail(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial)
        }
    }
}
