import AppKit
import Combine
import SwiftUI
import C2SCore

/// F22/S5 编辑器 AI 一次性动作。
enum EditorAIPrompt {
    case translate
    case visualize
}

/// S5 共享搜索面板(编辑器侧,单实例)。
///
/// v2(2026-07-17 用户实测拍板):**原装面板,不做山寨**——宿主是一块透明
/// 无边框浮窗,里面装圈选同款 `ResultSheetView`(同一套药丸/模式 chip/
/// 双联详情屏/403 风控「登录 Google」恢复流;WKWebView dataStore = .default
/// 持久,与圈选面板同一份 Google 登录态)。透明区域不吃点击(SwiftUI 命中
/// 测试天然放行),视觉上就是「编辑器旁边浮着那块熟悉的手机屏」。
///
/// 会话边界(spec S5):每次发送 = 新 Lens 会话 + 重传当前压平画布;
/// 面板内追问 = 同会话 multisearch;串图竞态用 staleVSRID + 上传 commit 双门拦截。
@MainActor
final class EditorSearchPanelController {

    private let search = SearchService()
    private let sheetModel = ResultSheetModel()
    private let reduceEffects: () -> Bool

    private final class EditorPanelWindow: NSWindow {
        override var canBecomeKey: Bool { true } // borderless 要接住药丸输入
    }
    private var window: EditorPanelWindow?
    private var detailSink: AnyCancellable?

    /// 容器宽:面板 390 + 两侧 24 边距(ResultSheetView 的 panelSize 假设);
    /// 详情屏展开时向左扩一块(双联手机屏)。
    private static let baseWidth: CGFloat = 438
    private static let detailExtraWidth: CGFloat = 404
    private static let baseHeight: CGFloat = 893 // 390 × 19.5/9 + 边距,受屏高再钳

    struct PendingPrompt {
        let query: String
        let pillText: String?
        let chip: QueryModeChip?
        let aiMode: Bool
    }
    private var pendingPrompt: PendingPrompt?
    private var lensAttempt = 0
    /// 药丸缩略图 = 发出去的画布(与文字 query 对等的查询上下文)。
    private var lastThumbnail: CGImage?
    /// 重试用(降采样 ≤1600:上传管线同尺寸,重发字节一致;不钉 5K 原图)。
    private var lastRequest: (image: CGImage, prompt: PendingPrompt)?
    /// 会话代际门(防串图):send() 记旧 vsrid;新上传的无 vsrid 页先到才开闸。
    private var staleVSRID: String?
    private var sawUploadCommit = false

    init(reduceEffects: @escaping () -> Bool) {
        self.reduceEffects = reduceEffects
        sheetModel.onQuerySubmit = { [weak self] text in self?.submitFollowUp(text) }
        sheetModel.onPageURLChanged = { [weak self] url in self?.handlePageURL(url) }
        sheetModel.onLensBlocked = { [weak self] reason in self?.handleBlocked(reason) }
        sheetModel.onLensFailure = { [weak self] reason in self?.handleFailure(reason) }
        sheetModel.onDismiss = { [weak self] in self?.closePanel() } // × = 收面板(非覆盖层语义)
        // 双联详情屏:向左扩窗,右缘不动(面板停靠位不变)
        detailSink = sheetModel.$detailURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in self?.adjustWidth(detailOpen: url != nil) }
    }

    // MARK: 发送(编辑器 AI 行三 chip / 提问框)

    func send(image: CGImage, query: String, pillText: String?,
              chip: QueryModeChip?, aiMode: Bool, nextTo window: NSWindow?) {
        let prompt = PendingPrompt(query: query, pillText: pillText, chip: chip, aiMode: aiMode)
        lastRequest = (LensService.downscaled(image, maxDimension: 1600) ?? image, prompt)
        staleVSRID = Self.vsrid(of: sheetModel.currentPageURL)
        sawUploadCommit = false
        sheetModel.currentPageURL = nil // 新会话:旧 vsrid 作废(spec S5 会话安全)
        pendingPrompt = prompt
        lastThumbnail = LensService.downscaled(image, maxDimension: 240)
        lensAttempt += 1
        do {
            let payload = try search.lensUploadPayload(for: image, attempt: lensAttempt)
            show(.lensUpload(payload), query: pillText, queryImage: lastThumbnail)
        } catch {
            pendingPrompt = nil
            let message = (error as? LocalizedError)?.errorDescription
                ?? L10n.t("error.image_search_failed", "图像搜索失败,请重试。")
            show(.error(message: message, retry: { [weak self] in self?.retry() }, login: nil),
                 query: pillText, queryImage: lastThumbnail)
        }
        present(nextTo: window)
    }

    /// OverlayWindowController.showResult 的编辑器版(loadToken 语义一致)。
    private func show(_ content: ResultContent, query: String?, queryImage: CGImage?,
                      chip: QueryModeChip? = nil) {
        sheetModel.loadToken &+= 1
        sheetModel.content = content
        sheetModel.query = query
        sheetModel.queryImage = queryImage
        sheetModel.modeChip = chip
    }

    // MARK: 会话状态机(F11 handleLensPageURL 的编辑器版 + 代际门)

    private func handlePageURL(_ url: URL?) {
        guard let url else { return }
        let vsrid = Self.vsrid(of: url)
        if vsrid == nil {
            sawUploadCommit = true // 本次上传的 baseURL/重定向链先到 → 开闸
            return
        }
        if vsrid == staleVSRID { return } // 旧会话迟到页,丢弃
        guard sawUploadCommit || pendingPrompt == nil else { return }
        staleVSRID = nil
        guard let pending = pendingPrompt,
              let multisearch = SearchURLBuilder.lensMultisearch(currentResultURL: url,
                                                                 text: pending.query,
                                                                 aiMode: pending.aiMode)
        else { return }
        pendingPrompt = nil
        show(.web(multisearch), query: pending.pillText,
             queryImage: lastThumbnail, chip: pending.chip)
    }

    /// 药丸追问(spec S5):同会话 multisearch;无 vsrid 降级纯文字搜索。
    /// 路由 = AppCoordinator.handleQuerySubmit 去掉 promptMode 的版本。
    private func submitFollowUp(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingPrompt = nil
        if lastThumbnail != nil,
           let base = sheetModel.currentPageURL,
           let multisearch = SearchURLBuilder.lensMultisearch(currentResultURL: base, text: trimmed) {
            show(.web(multisearch), query: trimmed, queryImage: lastThumbnail)
            return
        }
        guard let url = SearchURLBuilder.googleSearch(query: trimmed,
                                                      viewport: CGSize(width: 390, height: 845))
        else { return }
        show(.web(url), query: trimmed, queryImage: nil)
    }

    /// 403 风控:原装恢复流——错误卡带「重试 / 登录 Google」,登录一次 cookie
    /// 留存(与圈选面板同一 dataStore),根治(复刻 AppCoordinator.handleLensBlocked)。
    private func handleBlocked(_ reason: String) {
        show(.error(message: reason,
                    retry: { [weak self] in self?.retry() },
                    login: { [weak self] in
                        guard let self,
                              let url = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.google.com%2F")
                        else { return }
                        self.show(.web(url), query: nil, queryImage: nil)
                    }),
             query: nil, queryImage: lastThumbnail)
    }

    private func handleFailure(_ reason: String) {
        show(.error(message: reason,
                    retry: { [weak self] in self?.retry() },
                    login: nil),
             query: nil, queryImage: lastThumbnail)
    }

    private func retry() {
        guard let (image, prompt) = lastRequest else { return }
        send(image: image, query: prompt.query, pillText: prompt.pillText,
             chip: prompt.chip, aiMode: prompt.aiMode, nextTo: nil)
    }

    private static func vsrid(of url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "vsrid" })?.value
    }

    // MARK: 浮窗宿主(透明无边框;面板自带全部 chrome,空白区点击穿透)

    private func present(nextTo editorWindow: NSWindow?) {
        let panel = ensureWindow()
        if let editorWindow {
            let screen = editorWindow.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame ?? .zero
            let height = min(Self.baseHeight, screen.height)
            // 右缘 = 编辑器右缘 + 面板宽(放不下贴屏右缘)
            var x = editorWindow.frame.maxX + 8
            if x + Self.baseWidth > screen.maxX { x = screen.maxX - Self.baseWidth }
            x = max(screen.minX, x)
            let y = min(editorWindow.frame.maxY, screen.maxY) - height
            panel.setFrame(CGRect(x: x, y: max(screen.minY, y),
                                  width: Self.baseWidth, height: height),
                           display: true)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> EditorPanelWindow {
        if let window { return window }
        let w = EditorPanelWindow(contentRect: CGRect(x: 0, y: 0,
                                                      width: Self.baseWidth,
                                                      height: Self.baseHeight),
                                  styleMask: .borderless,
                                  backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false // 面板自带投影
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = false // 面板有自己的抓手条
        w.contentView = NSHostingView(rootView: ResultSheetView(model: sheetModel,
                                                                reduceEffects: reduceEffects()))
        window = w
        return w
    }

    /// 双联详情屏:窗体向左扩(右缘锚定,面板停靠位不动)。
    private func adjustWidth(detailOpen: Bool) {
        guard let window, window.isVisible else { return }
        let targetWidth = Self.baseWidth + (detailOpen ? Self.detailExtraWidth : 0)
        var frame = window.frame
        guard frame.width != targetWidth else { return }
        frame.origin.x = frame.maxX - targetWidth
        frame.size.width = targetWidth
        window.setFrame(frame, display: true, animate: !reduceEffects())
    }

    private func closePanel() {
        window?.orderOut(nil)
    }
}
