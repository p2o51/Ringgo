import AppKit
import Combine
import C2SCore

/// 全局状态机与模块接线(features §6 架构):
/// idle → (蓄力,可取消) → capturing → overlayActive,同一入口去重。
@MainActor
public final class AppCoordinator: ObservableObject {

    public enum Phase: Equatable { case idle, capturing, overlayActive }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var multitouchStatus: MultitouchTriggerStatus = .disabled

    public let settings: SettingsStore
    public let capture = CaptureService()
    private let hotkeys = HotkeyManager()
    private let multitouch = MultitouchTrigger()
    private let ocr = OCRService()
    private let search = SearchService()
    private let overlay = OverlayWindowController()

    private var previousApp: NSRunningApplication?
    private var ocrTask: Task<Void, Never>?
    private var speculativeCapture: Task<CaptureResult, Error>?
    private var settingsSink: AnyCancellable?
    private var workspaceSinks: Set<AnyCancellable> = []
    private var currentCapture: CaptureResult?
    private var lastTextQuery: String?
    private var lastImageSearchRect: CGRect?
    /// 等 Lens 会话 URL(vsrid)就绪后要以 multisearch 挂上的查询
    /// (F11 整屏提问 / F15 图片可视化与编辑共用)。
    private struct PendingLensPrompt {
        /// 真实查询(可能是 prompt 包装)。
        let query: String
        /// 药丸显示文本(nil = 只显示缩略图)。
        let pillText: String?
        let chip: QueryModeChip?
        let aiMode: Bool
    }
    private var pendingLensPrompt: PendingLensPrompt?
    /// 当前 prompt 模式(翻译/可视化/编辑;nil = 普通搜索)。决定搜索框
    /// 提交时的重新包装路由;任何新普通搜索都退出模式。
    private var promptMode: QueryPromptMode?
    /// 当前圈图的 Lens 会话结果页 URL(带 vsrid;新搜索时清空)。
    /// 图片可视化/编辑在它之上 multisearch,绝不能用上一张图的旧会话。
    private var lensSessionURL: URL?
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
        multitouch.onFirstTap = { [weak self] in self?.prewarmCapture() }
        multitouch.onDoubleTap = { [weak self] in self?.handle(.threeFingerDoubleTap) }
        applyTriggerSettings()
        hotkeys.start()
        installMultitouchLifecycleObservers()
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

    /// 设置页开始录制新快捷键：暂停 Carbon 热键与蓄力监听，避免自触发覆盖层。
    public func beginHotkeyRecording() {
        hotkeys.suspend()
    }

    /// 录制结束：先同步最新配置，再恢复全局触发。
    public func endHotkeyRecording() {
        hotkeys.apply(config: settings.triggerConfig)
        hotkeys.resume()
    }

    public func retryMultitouch() {
        multitouch.stop()
        applyMultitouchSetting()
    }

    private func applyTriggerSettings() {
        hotkeys.apply(config: settings.triggerConfig)
        applyMultitouchSetting()
    }

    private func applyMultitouchSetting() {
        guard settings.multitouchEnabled else {
            multitouch.stop()
            multitouchStatus = .disabled
            return
        }
        multitouchStatus = multitouch.start()
    }

    private func installMultitouchLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.settings.multitouchEnabled else { return }
                self.multitouch.stop()
                self.multitouchStatus = .sleeping
            }
            .store(in: &workspaceSinks)

        center.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.settings.multitouchEnabled else { return }
                self.retryMultitouch()
            }
            .store(in: &workspaceSinks)
    }

    // MARK: - 触发

    private func handle(_ event: TriggerEvent) {
        switch event {
        case .hotkey, .menuBar, .doubleShift, .threeFingerDoubleTap:
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
            Haptics.fire() // 蓄力跨过阈值(触控板)
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
        cb.onAskAboutScreen = { [weak self] question in self?.askAboutScreen(question) }
        cb.onCopyImage = { [weak self] rect in self?.copyImageSelection(overlayRect: rect) }
        cb.onLensPageURL = { [weak self] url in self?.handleLensPageURL(url) }
        cb.onToggleTranslateSelection = { [weak self] in self?.toggleSelectionTranslation() }
        cb.onToggleVisualizeSelection = { [weak self] in self?.toggleSelectionVisualization() }
        cb.onTranslateImage = { [weak self] in self?.translateImageSelection() }
        cb.onVisualizeImage = { [weak self] in self?.visualizeImageSelection() }
        cb.onSubmitImageEdit = { [weak self] text in self?.performImageEdit(instruction: text) }
        cb.onFocusedOCR = { [weak self] rect in
            await self?.focusedOCR(overlayRect: rect) ?? []
        }
        cb.onLensBlocked = { [weak self] reason in self?.handleLensBlocked(reason) }
        cb.onLensFailure = { [weak self] reason in self?.handleLensFailure(reason) }
        cb.onDismiss = { [weak self] in self?.dismissOverlay() }
        overlay.present(capture: result,
                        callbacks: cb,
                        reduceEffects: settings.reduceEffects,
                        translationTargetCode: settings.translationTargetCode,
                        onPickTranslationTarget: { [weak self] code in
                            self?.settings.translationTargetCode = code
                        })

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

    /// 「改选文字」补刀:裁剪当前截图的选区重跑 OCR(F17,小框小字整屏识别漏)。
    private func focusedOCR(overlayRect: CGRect) async -> [OCRWord] {
        guard let cap = currentCapture else { return [] }
        return await ocr.words(in: cap.image, context: cap.context, focusOn: overlayRect)
    }

    private func dismissOverlay() {
        guard phase == .overlayActive else { return }
        ocrTask?.cancel()
        ocrTask = nil
        currentCapture = nil
        lastImageSearchRect = nil
        lastLensThumbnail = nil
        pendingLensPrompt = nil
        promptMode = nil
        lensSessionURL = nil
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
        pendingLensPrompt = nil
        lensSessionURL = nil
        promptMode = nil // 普通搜索 = 退出 prompt 模式
        guard let url = search.textSearchURL(query: q, viewport: overlay.viewportSize) else { return }
        overlay.showResult(.web(url), query: q)
    }

    /// 迷你工具条「翻译」开关(2026-07-03 用户拍板):
    /// 开 = 真实查询变为「将下面的文字翻译成 {目标语言}:{选中文字}」+ Google AI Mode;
    /// 药丸显示原文(可编辑重译)+ 模式 chip;按钮高亮。再点 = 退回普通搜索。
    private func toggleSelectionTranslation() {
        guard let text = lastTextQuery, !text.isEmpty else { return }
        if promptMode == .translate {
            performTextSearch(text) // 内部清 chip、清模式
            return
        }
        performSelectionTranslation(of: text)
    }

    private func performSelectionTranslation(of text: String) {
        let targetName = currentTranslationTargetName()
        let prompt = "将下面的文字翻译成\(targetName):\n\n\(text)"
        guard let url = SearchURLBuilder.googleSearch(query: prompt,
                                                      viewport: overlay.viewportSize,
                                                      aiMode: true) else { return }
        promptMode = .translate
        lastTextQuery = text // 药丸保持原文,可编辑后重译
        overlay.showResult(.web(url), query: text,
                           chip: QueryModeChip(mode: .translate, icon: "translate",
                                               label: "翻译 · \(targetName)"))
    }

    // MARK: - F15 可视化 / 图片编辑(2026-07-03:AI Mode 让 Gemini 出图表或 nano banana 出图)

    /// 迷你工具条「可视化」开关(文字选区,与「翻译」同构):
    /// 开 = prompt 包装 + Google AI Mode,让 Gemini 用可视化图表或 nano banana
    /// 生成图片来可视化选中文字;药丸显示原文(可编辑重发)+ chip。再点 = 退回普通搜索。
    private func toggleSelectionVisualization() {
        guard let text = lastTextQuery, !text.isEmpty else { return }
        if promptMode == .visualize {
            performTextSearch(text)
            return
        }
        performSelectionVisualization(of: text)
    }

    private func performSelectionVisualization(of text: String) {
        let prompt = "请可视化下面的内容:适合数据或结构就生成可视化图表"
            + "(信息图/流程图/对比表等),更适合画面就用 nano banana 生成一张图片:\n\n\(text)"
        guard let url = SearchURLBuilder.googleSearch(query: prompt,
                                                      viewport: overlay.viewportSize,
                                                      aiMode: true) else { return }
        promptMode = .visualize
        lastTextQuery = text
        overlay.showResult(.web(url), query: text, chip: Self.visualizeChip)
    }

    /// 迷你工具条「翻译」(图片选区,一次性动作):当前 Lens 会话 multisearch
    /// 挂翻译 prompt + AI Mode,Gemini 把图里的文字翻成目标语言(与文字翻译同一设置)。
    /// 不设 promptMode:后续在搜索框输入 = 同会话 AI Mode 追问(multisearch 路由)。
    private func translateImageSelection() {
        let targetName = currentTranslationTargetName()
        let prompt = "请把这张图片里的所有文字翻译成\(targetName),按原文的结构和顺序输出译文。"
        fireLensPrompt(prompt, pillText: nil,
                       chip: QueryModeChip(mode: .translate, icon: "translate",
                                           label: "翻译 · \(targetName)"),
                       aiMode: true)
    }

    /// 迷你工具条「可视化」(图片选区,一次性动作):当前 Lens 会话 multisearch
    /// 挂可视化 prompt + AI Mode(图随会话参数保留,Gemini 能看到圈出的图)。
    /// 不设 promptMode:后续在搜索框输入 = 同会话 AI Mode 追问(multisearch 路由)。
    private func visualizeImageSelection() {
        let prompt = "请可视化这张图片的内容:适合数据或结构就生成可视化图表"
            + "(信息图/流程图/对比表等),更适合画面就用 nano banana 生成一张新图片来呈现。"
        fireLensPrompt(prompt, pillText: nil, chip: Self.visualizeChip, aiMode: true)
    }

    /// 编辑指令提交(v4,2026-07-03:迷你工具条「编辑」旁的内联输入框回车;
    /// 编辑模式下面板搜索框回车 = 同一入口):nano banana prompt 包装 +
    /// 当前 Lens 会话 multisearch + AI Mode。模式保持:改指令再回车 = 对原图重新编辑。
    private func performImageEdit(instruction: String) {
        let q = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        promptMode = .editImage
        let prompt = "请用 nano banana 编辑这张图片,直接生成编辑后的图片。编辑要求:\(q)"
        fireLensPrompt(prompt, pillText: q, chip: Self.editChip, aiMode: true)
    }

    private static let visualizeChip =
        QueryModeChip(mode: .visualize, icon: "chart.bar.xaxis", label: "可视化")
    private static let editChip =
        QueryModeChip(mode: .editImage, icon: "wand.and.stars", label: "编辑 · Nano Banana")

    /// 在当前圈图的 Lens 会话上挂 prompt 型查询:会话 URL(vsrid)已就绪 → 立即
    /// multisearch;未就绪(上传还在飞)→ 挂起,handleLensPageURL 就绪后自动发出。
    private func fireLensPrompt(_ query: String, pillText: String?,
                                chip: QueryModeChip?, aiMode: Bool) {
        guard lastLensThumbnail != nil else { return }
        if let base = lensSessionURL,
           let url = SearchURLBuilder.lensMultisearch(currentResultURL: base,
                                                      text: query, aiMode: aiMode) {
            lastTextQuery = pillText
            overlay.showResult(.web(url), query: pillText,
                               queryImage: lastLensThumbnail, chip: chip)
        } else {
            pendingLensPrompt = PendingLensPrompt(query: query, pillText: pillText,
                                                  chip: chip, aiMode: aiMode)
        }
    }

    private func currentTranslationTargetName() -> String {
        let code = settings.translationTargetCode.isEmpty
            ? (TranslationLanguageOption.menuOptions().first?.id ?? "en")
            : settings.translationTargetCode
        return TranslationLanguageOption.option(for: code).displayName
    }

    /// F11 搜索框提交路由:
    /// - 图搜会话中(药丸有缩略图 + 当前页带 vsrid)→ **multisearch**:同一 Lens 会话上
    ///   追加/替换 q,图不被顶掉(谷歌原生行为);
    /// - 否则 → 整条文字查询(搜索框 = 可编辑的查询,直接替换)。
    private func handleQuerySubmit(_ text: String, currentPageURL: URL?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch promptMode {
        case .translate:
            // 翻译模式:编辑药丸原文后回车 = 重译新文本(模式保持)
            performSelectionTranslation(of: trimmed)
            return
        case .visualize:
            // 可视化模式(文字):编辑原文后回车 = 重新可视化(模式保持)
            performSelectionVisualization(of: trimmed)
            return
        case .editImage:
            // 编辑模式(图片):回车 = 以新指令对原图重新编辑(模式保持)
            performImageEdit(instruction: trimmed)
            return
        case nil:
            break
        }
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
        pendingLensPrompt = nil
        promptMode = nil
        lensSessionURL = nil // 新上传 = 新会话,旧 vsrid 作废(防可视化/编辑挂错图)
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

    /// 底部工具条「整屏提问」(安卓同款):整张截图发 Lens,结果页(vsrid)就绪后
    /// 自动以 multisearch 追加提问文字 —— 图+文 AI 问答。
    private func askAboutScreen(_ question: String) {
        guard let cap = currentCapture else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        lastTextQuery = nil
        lastImageSearchRect = nil
        promptMode = nil
        lensSessionURL = nil // 新上传 = 新会话
        pendingLensPrompt = PendingLensPrompt(query: q, pillText: q, chip: nil, aiMode: false)
        lastLensThumbnail = LensService.downscaled(cap.image, maxDimension: 240)
        lensAttempt += 1
        do {
            let payload = try search.lensUploadPayload(for: cap.image, attempt: lensAttempt)
            overlay.showResult(.lensUpload(payload), query: q, queryImage: lastLensThumbnail)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "图像搜索失败,请重试。"
            overlay.showResult(.error(message: message, retry: { [weak self] in
                self?.askAboutScreen(q)
            }, login: nil), query: q, queryImage: lastLensThumbnail)
        }
    }

    /// 面板页面 URL 变化:带 vsrid 的 Lens 结果页 = 当前圈图会话的真源
    /// (可视化/编辑在其上 multisearch);挂起的 prompt 此刻才能发出。
    private func handleLensPageURL(_ url: URL?) {
        guard let url else { return }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           items.contains(where: { $0.name == "vsrid" }) {
            lensSessionURL = url
        }
        guard let pending = pendingLensPrompt,
              let multisearch = SearchURLBuilder.lensMultisearch(currentResultURL: url,
                                                                 text: pending.query,
                                                                 aiMode: pending.aiMode)
        else { return }
        pendingLensPrompt = nil
        lastTextQuery = pending.pillText
        overlay.showResult(.web(multisearch), query: pending.pillText,
                           queryImage: lastLensThumbnail, chip: pending.chip)
    }

    /// 迷你工具条「复制」(图片选区):按坐标真源裁剪并写入剪贴板。
    private func copyImageSelection(overlayRect: CGRect) {
        guard let cap = currentCapture else { return }
        let px = cap.context.pixelRect(fromOverlay: overlayRect)
        guard !px.isNull, let cropped = cap.image.cropping(to: px) else { return }
        let image = NSImage(cgImage: cropped, size: overlayRect.size)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        Haptics.confirm()
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
            alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 Ringgo。\n若已允许,需要重新启动 Ringgo 才会生效。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "重新启动 Ringgo")
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
    public func relaunch(completion: ((Bool) -> Void)? = nil) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { application, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if error == nil,
                       let application,
                       application.processIdentifier != currentPID {
                        completion?(true)
                        NSApp.terminate(nil)
                        return
                    }

                    // 新实例未真正启动时保留当前进程，避免“重新启动”变成单纯退出。
                    completion?(false)
                    let alert = NSAlert()
                    alert.messageText = "无法重新启动 Ringgo"
                    alert.informativeText = error?.localizedDescription
                        ?? "系统没有启动新的 Ringgo 实例，请手动退出后重新打开应用。"
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}
