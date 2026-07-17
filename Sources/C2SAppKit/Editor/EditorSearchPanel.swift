import AppKit
import SwiftUI
import C2SCore

/// F22/S5 编辑器 AI 一次性动作。
enum EditorAIPrompt {
    case translate
    case visualize
}

/// S5 编辑器侧搜索状态(ResultSheetModel 的精简版):
/// content/药丸/chip/当前页 URL/挂起 prompt——PendingLensPrompt 机制照搬 F11。
@MainActor
final class EditorSearchModel: ObservableObject {
    @Published var source: WebSource?
    @Published var isLoading = false
    /// 药丸可编辑文字(提问/追问)。
    @Published var queryText = ""
    /// 药丸缩略图 = 发出去的画布(查询上下文,与文字 query 对等)。
    @Published var queryThumbnail: CGImage?
    @Published var modeChip: QueryModeChip?
    @Published var errorMessage: String?

    var currentPageURL: URL?

    struct PendingPrompt {
        let query: String
        let pillText: String?
        let chip: QueryModeChip?
        let aiMode: Bool
    }
    var pendingPrompt: PendingPrompt?
    var attempt = 0
}

/// S5 共享搜索面板(编辑器侧,单实例):独立浮窗,复用 ResultWebView
/// (dataStore = .default 持久 → 与圈选面板天然共享 Google 登录态/cookie)。
/// 会话边界(spec S5):**每次发送 = 新 Lens 会话 + 重传当前压平画布**;
/// 进面板后的药丸追问沿用同会话 multisearch 语义。
/// 仲裁:面板跟随最近一次发起请求的编辑器窗口重新停靠;发起窗口关闭面板原地保留。
@MainActor
final class EditorSearchPanelController {

    private let search = SearchService()
    private let model = EditorSearchModel()
    private var panel: NSPanel?
    /// 重试 = 原样重发最近一次请求(风控/断网错误卡用)。
    /// 只存降采样版(≤1600px,上传管线本来就压到这个尺寸,重发字节一致)——
    /// 存 5K 原图会把 ~56MB 无限期钉在单例上(内存纪律,2026-07-17 审查)。
    private var lastRequest: (image: CGImage, prompt: EditorSearchModel.PendingPrompt)?

    /// 会话代际门(2026-07-17 审查,防串图竞态):
    /// - staleVSRID:send() 时记下旧会话的 vsrid,迟到的旧结果页回调一律丢弃;
    /// - sawUploadCommit:新上传的 baseURL/重定向链(无 vsrid 页)先到,才开闸
    ///   接受带 vsrid 的结果页——挡住「上一次上传的 vsrid 抢先消费新 prompt」。
    private var staleVSRID: String?
    private var sawUploadCommit = false

    private static let panelSize = CGSize(width: 390, height: 720)

    // MARK: 发送(编辑器 AI 行三 chip / 提问框)

    func send(image: CGImage, query: String, pillText: String?,
              chip: QueryModeChip?, aiMode: Bool, nextTo window: NSWindow?) {
        let prompt = EditorSearchModel.PendingPrompt(query: query, pillText: pillText,
                                                     chip: chip, aiMode: aiMode)
        lastRequest = (LensService.downscaled(image, maxDimension: 1600) ?? image, prompt)
        staleVSRID = Self.vsrid(of: model.currentPageURL)
        sawUploadCommit = false
        model.errorMessage = nil
        model.currentPageURL = nil // 新会话:旧 vsrid 作废(spec S5 会话安全)
        model.pendingPrompt = prompt
        model.modeChip = nil // multisearch 落地后才挂 chip(与覆盖层一致)
        model.queryText = pillText ?? ""
        model.queryThumbnail = LensService.downscaled(image, maxDimension: 240)
        model.attempt += 1
        do {
            let payload = try search.lensUploadPayload(for: image, attempt: model.attempt)
            model.source = .lensUpload(html: payload.html, baseURL: payload.baseURL,
                                       token: payload.attempt)
        } catch {
            model.pendingPrompt = nil
            model.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.t("error.image_search_failed", "图像搜索失败,请重试。")
        }
        present(nextTo: window)
    }

    private static func vsrid(of url: URL?) -> String? {
        guard let url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "vsrid" })?.value
    }

    // MARK: 面板窗

    private func present(nextTo window: NSWindow?) {
        let panel = ensurePanel()
        if let window {
            // 停靠在发起窗口右侧(放不下换左侧),顶对齐
            let frame = window.frame
            let screen = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame ?? .zero
            let gap: CGFloat = 14
            var x = frame.maxX + gap
            if x + Self.panelSize.width > screen.maxX {
                x = frame.minX - gap - Self.panelSize.width
            }
            x = max(screen.minX + 8, min(x, screen.maxX - Self.panelSize.width - 8))
            let y = min(frame.maxY, screen.maxY) - Self.panelSize.height
            panel.setFrame(CGRect(origin: CGPoint(x: x, y: max(screen.minY + 8, y)),
                                  size: Self.panelSize), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.title = L10n.t("editor.panel.title", "搜索")
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        let view = EditorSearchPanelView(
            model: model,
            onSubmit: { [weak self] text in self?.submitFollowUp(text) },
            onURLChange: { [weak self] url in self?.handlePageURL(url) },
            onBlocked: { [weak self] reason in self?.model.errorMessage = reason },
            onFailure: { [weak self] reason in self?.model.errorMessage = reason },
            onRetry: { [weak self] in self?.retry() })
        p.contentView = NSHostingView(rootView: view)
        panel = p
        return p
    }

    // MARK: 会话状态机(F11 handleLensPageURL 的编辑器版)

    private func handlePageURL(_ url: URL?) {
        guard let url else { return }
        let vsrid = Self.vsrid(of: url)
        if vsrid == nil {
            // 无 vsrid 页 = 本次上传的 baseURL/重定向链先到 → 开闸
            sawUploadCommit = true
            return
        }
        // 代际门:旧会话迟到的结果页(同 vsrid)/新上传落地前抢跑的旧 vsrid,一律丢弃
        if vsrid == staleVSRID { return }
        guard sawUploadCommit || model.pendingPrompt == nil else { return }
        staleVSRID = nil
        model.currentPageURL = url
        guard let pending = model.pendingPrompt,
              let multisearch = SearchURLBuilder.lensMultisearch(currentResultURL: url,
                                                                 text: pending.query,
                                                                 aiMode: pending.aiMode)
        else { return }
        model.pendingPrompt = nil
        model.attempt += 1
        model.source = .url(multisearch, token: model.attempt)
        model.modeChip = pending.chip
        if let pillText = pending.pillText { model.queryText = pillText }
    }

    /// 药丸追问(spec S5 会话边界):同会话 multisearch;无 vsrid 降级纯文字搜索。
    private func submitFollowUp(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.errorMessage = nil
        model.pendingPrompt = nil
        model.modeChip = nil // 手动追问退出 prompt 模式(与覆盖层语义一致)
        model.attempt += 1
        if let base = model.currentPageURL,
           let multisearch = SearchURLBuilder.lensMultisearch(currentResultURL: base, text: trimmed) {
            model.source = .url(multisearch, token: model.attempt)
        } else if let url = SearchURLBuilder.googleSearch(query: trimmed,
                                                          viewport: Self.panelSize) {
            model.source = .url(url, token: model.attempt)
        }
        model.queryText = trimmed
    }

    private func retry() {
        guard let (image, prompt) = lastRequest else { return }
        send(image: image, query: prompt.query, pillText: prompt.pillText,
             chip: prompt.chip, aiMode: prompt.aiMode, nextTo: nil)
    }
}

// MARK: - 面板内容(ResultSheetView 的精简版:药丸 + WebView,无抓手/详情屏/停靠)

private struct EditorSearchPanelView: View {
    @ObservedObject var model: EditorSearchModel
    let onSubmit: (String) -> Void
    let onURLChange: (URL?) -> Void
    let onBlocked: (String) -> Void
    let onFailure: (String) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            pill
            content
        }
        .padding(10)
        .background(.regularMaterial)
    }

    private var pill: some View {
        HStack(spacing: 6) {
            if let thumbnail = model.queryThumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 26, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if let chip = model.modeChip {
                HStack(spacing: 3) {
                    Image(systemName: chip.icon).font(.system(size: 9, weight: .medium))
                    Text(chip.label).font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            }
            TextField(L10n.t("editor.panel.placeholder", "接着追问…"),
                      text: Binding(get: { model.queryText },
                                    set: { model.queryText = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { onSubmit(model.queryText) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    @ViewBuilder private var content: some View {
        if let message = model.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L10n.t("common.retry", "重试"), action: onRetry)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let source = model.source {
            ResultWebView(source: source,
                          isLoading: Binding(get: { model.isLoading },
                                             set: { model.isLoading = $0 }),
                          onBlocked: onBlocked,
                          onFailure: onFailure,
                          onURLChange: onURLChange,
                          // 编辑器面板无详情屏:离开 Google 域直接交给默认浏览器
                          onOpenDetail: { NSWorkspace.shared.open($0) })
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
        } else {
            Text(L10n.t("editor.panel.empty", "从编辑器发起翻译 / 提问 / 可视化"))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
