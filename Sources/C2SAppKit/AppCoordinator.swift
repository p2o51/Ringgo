import AppKit
import Combine
import C2SCore

/// 全局状态机与模块接线(features §6 架构):
/// idle → (蓄力,可取消) → capturing → overlayActive,同一入口去重。
@MainActor
public final class AppCoordinator: ObservableObject {

    public enum Phase: Equatable { case idle, capturing, overlayActive }

    @Published public private(set) var phase: Phase = .idle

    public let settings: SettingsStore
    public let capture = CaptureService()
    private let hotkeys = HotkeyManager()
    private let ocr = OCRService()
    private let search = SearchService()
    private let overlay = OverlayWindowController()

    private var previousApp: NSRunningApplication?
    private var ocrTask: Task<Void, Never>?
    private var speculativeCapture: Task<CaptureResult, Error>?
    private var settingsSink: AnyCancellable?
    private var currentCapture: CaptureResult?
    private var lastTextQuery: String?
    private var lastImageSearchRect: CGRect?
    /// 药丸缩略图:圈出的图的查询上下文(与文字 query 对等),错误卡/重试期间保留。
    private var lastLensThumbnail: CGImage?
    private var lensAttempt = 0

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public func start() {
        capture.prewarm()
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        hotkeys.onError = { [weak self] message in self?.showHotkeyError(message) }
        applyTriggerSettings()
        hotkeys.start()
        // 设置变更 → 重新应用触发配置(objectWillChange 在变更前发出,故异步一拍后读取)
        settingsSink = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyTriggerSettings() }
            }
    }

    /// 菜单栏「立即圈选」。
    public func captureNow() { handle(.menuBar) }

    /// 菜单 hover / 打开时预热抓屏管线(features F1)。
    public func prewarmCapture() { capture.prewarm() }

    private func applyTriggerSettings() {
        hotkeys.apply(config: settings.triggerConfig)
    }

    // MARK: - 触发

    private func handle(_ event: TriggerEvent) {
        switch event {
        case .hotkey, .menuBar, .doubleShift:
            // 开关语义(v3.1):覆盖层已开 → 再按 = 关闭。
            // 轻点已不再退出(点空白=新框,对齐原版),鼠标党靠热键/Esc 离场。
            if phase == .overlayActive {
                dismissOverlay()
                return
            }
            beginCapture()
        case .chargeBegan:
            // 蓄力的 ~250ms 里并行预抓屏 → 松手即冻结、零空窗(features F1)。
            // 无屏幕录制权限时绝不投机:captureScreenUnderMouse 会触发 TCC 授权弹窗,
            // 而任何 ⌘⇧ 前缀快捷键(⌘⇧Z/⌘⇧4…)按下过程都会路过「恰好 ⌘⇧」状态。
            guard phase == .idle, speculativeCapture == nil,
                  capture.hasScreenRecordingPermission else { return }
            let capture = self.capture
            speculativeCapture = Task {
                // 缓一拍再拍:⌘⇧ 前缀快捷键大多在此窗口内结束并取消蓄力,
                // 避免每按一次 ⌘⇧Z 就白拍一张全屏
                try await Task.sleep(nanoseconds: 120_000_000)
                try Task.checkCancellation()
                return try await capture.captureScreenUnderMouse()
            }
        case .chargeFired:
            beginCapture()
        case .chargeCancelled:
            speculativeCapture?.cancel()
            speculativeCapture = nil
        }
    }

    private func beginCapture() {
        guard phase == .idle else { return } // capturing/overlay 时再触发一律忽略
        phase = .capturing
        previousApp = NSWorkspace.shared.frontmostApplication
        let pending = speculativeCapture
        speculativeCapture = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result: CaptureResult
                if let pending, let speculated = try? await pending.value {
                    result = speculated
                } else {
                    result = try await self.capture.captureScreenUnderMouse()
                }
                self.presentOverlay(with: result)
            } catch {
                self.phase = .idle
                self.showCaptureError(error)
            }
        }
    }

    // MARK: - 覆盖层

    private func presentOverlay(with result: CaptureResult) {
        phase = .overlayActive
        currentCapture = result
        lastTextQuery = nil

        var cb = OverlayWindowController.Callbacks()
        cb.onTextSearch = { [weak self] text in self?.performTextSearch(text) }
        cb.onImageSearch = { [weak self] rect in self?.performImageSearch(overlayRect: rect) }
        cb.onQuerySubmit = { [weak self] text, pageURL in
            self?.handleQuerySubmit(text, currentPageURL: pageURL)
        }
        cb.onLensBlocked = { [weak self] reason in self?.handleLensBlocked(reason) }
        cb.onLensFailure = { [weak self] reason in self?.handleLensFailure(reason) }
        cb.onDismiss = { [weak self] in self?.dismissOverlay() }
        overlay.present(capture: result,
                        callbacks: cb,
                        reduceEffects: settings.reduceEffects)

        // 全量词框在 detached Task 里算(不占主线程,features F3)
        ocrTask?.cancel()
        let image = result.image
        let context = result.context
        let ocr = self.ocr
        let overlay = self.overlay
        ocrTask = Task.detached(priority: .userInitiated) {
            let words = await ocr.words(in: image, context: context)
            guard !Task.isCancelled else { return }
            await MainActor.run { overlay.updateWords(words) }
        }
    }

    private func dismissOverlay() {
        guard phase == .overlayActive else { return }
        ocrTask?.cancel()
        ocrTask = nil
        currentCapture = nil
        lastImageSearchRect = nil
        lastLensThumbnail = nil
        overlay.dismiss()
        phase = .idle
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: - 搜索路由

    private func performTextSearch(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        lastTextQuery = q
        lastLensThumbnail = nil
        guard let url = search.textSearchURL(query: q, viewport: overlay.viewportSize) else { return }
        overlay.showResult(.web(url), query: q)
    }

    /// F11 搜索框提交路由:
    /// - 图搜会话中(药丸有缩略图 + 当前页带 vsrid)→ **multisearch**:同一 Lens 会话上
    ///   追加/替换 q,图不被顶掉(谷歌原生行为);
    /// - 否则 → 整条文字查询(搜索框 = 可编辑的查询,直接替换)。
    private func handleQuerySubmit(_ text: String, currentPageURL: URL?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if lastLensThumbnail != nil,
           let base = currentPageURL,
           let multisearch = SearchURLBuilder.lensMultisearch(currentResultURL: base, text: trimmed) {
            lastTextQuery = trimmed
            overlay.showResult(.web(multisearch), query: trimmed, queryImage: lastLensThumbnail)
            return
        }
        performTextSearch(trimmed)
    }

    private func performImageSearch(overlayRect: CGRect) {
        guard let cap = currentCapture else { return }
        let px = cap.context.pixelRect(fromOverlay: overlayRect)
        guard !px.isNull, px.width >= 4, px.height >= 4,
              let cropped = cap.image.cropping(to: px) else { return }
        lastTextQuery = nil
        lastImageSearchRect = overlayRect
        // 药丸缩略图 = 圈出的图(查询上下文与文字 query 对等)
        lastLensThumbnail = LensService.downscaled(cropped, maxDimension: 240)
        lensAttempt += 1
        do {
            // 上传发生在面板 WebView 会话内(表单 POST 导航),与结果展示同会话
            let payload = try search.lensUploadPayload(for: cropped, attempt: lensAttempt)
            overlay.showResult(.lensUpload(payload), query: nil, queryImage: lastLensThumbnail)
        } catch {
            // 原生错误卡 + 重试;绝不拿错误串去搜(features §8)
            let message = (error as? LocalizedError)?.errorDescription ?? "图像搜索失败,请重试。"
            overlay.showResult(.error(message: message, retry: { [weak self] in
                self?.performImageSearch(overlayRect: overlayRect)
            }, login: nil), query: nil, queryImage: lastLensThumbnail)
        }
    }

    /// 面板 WebView 报告被 Google 风控拦截(403):
    /// 匿名会话在部分网络出口必被拒,登录一次 Google(cookie 持久化)即根治。
    private func handleLensBlocked(_ reason: String) {
        guard phase == .overlayActive else { return }
        let rect = lastImageSearchRect
        overlay.showResult(.error(
            message: reason,
            retry: rect.map { r in { [weak self] in self?.performImageSearch(overlayRect: r) } },
            login: { [weak self] in
                guard let self,
                      let url = URL(string: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.google.com%2F")
                else { return }
                self.overlay.showResult(.web(url), query: nil)
            }), query: nil, queryImage: lastLensThumbnail)
    }

    /// Lens 表单 POST 的 DNS/TLS/离线等导航失败：显示原生错误卡并保留重试入口。
    private func handleLensFailure(_ reason: String) {
        guard phase == .overlayActive else { return }
        let retry: (() -> Void)? = lastImageSearchRect.map { rect in
            { [weak self] in
                guard let self else { return }
                self.performImageSearch(overlayRect: rect)
            }
        }
        overlay.showResult(.error(message: reason, retry: retry, login: nil),
                           query: nil, queryImage: lastLensThumbnail)
    }

    // MARK: - 用户可感知的错误(原项目静默失败 → 必须反馈)

    private var lastHotkeyErrorMessage: String?

    private func showHotkeyError(_ message: String) {
        // 同一错误只弹一次:设置任何变更都会触发 apply() 重注册,
        // 注册持续失败时不能每改一个无关开关就弹一个模态框
        guard message != lastHotkeyErrorMessage else { return }
        lastHotkeyErrorMessage = message
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "热键注册失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法截取屏幕"
        alert.alertStyle = .warning
        if let e = error as? CaptureService.CaptureError, case .noPermission = e {
            // TCC 既定行为:授权只对之后新启动的进程生效,已运行的进程必须重启
            alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 C2S。\n若已允许,需要重新启动 C2S 才会生效。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "重新启动 C2S")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            case .alertSecondButtonReturn:
                relaunch()
            default:
                break
            }
        } else {
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.runModal()
        }
    }

    /// 以新进程重开自身后退出(授权后刷新 TCC 状态的唯一途径)。
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { application, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if error == nil,
                       let application,
                       application.processIdentifier != currentPID {
                        NSApp.terminate(nil)
                        return
                    }

                    // 新实例未真正启动时保留当前进程，避免“重新启动”变成单纯退出。
                    let alert = NSAlert()
                    alert.messageText = "无法重新启动 C2S"
                    alert.informativeText = error?.localizedDescription
                        ?? "系统没有启动新的 C2S 实例，请手动退出后重新打开应用。"
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}
