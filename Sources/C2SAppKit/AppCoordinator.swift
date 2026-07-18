import AppKit
import Combine
import ScreenCaptureKit
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
    private let barcode = BarcodeService()
    private let search = SearchService()
    private let overlay = OverlayWindowController()
    /// F21 托盘 + F20 产物管线(lazy:依赖 init 注入的 settings)。
    private lazy var tray = QuickAccessTray(settings: settings)
    private lazy var shotPipeline = ShotPipeline(settings: settings, tray: tray)
    /// F23 钉图(托盘 📌 / 编辑器 📌 进入)。
    private lazy var pinManager = PinManager(settings: settings)
    /// F22 标注编辑器(托盘点击/✏️ 进入)。
    private lazy var editorManager = AnnotationEditorManager(settings: settings, tray: tray,
                                                             pinManager: pinManager)

    /// 当前覆盖层会话模式(触发点定死;spec §1 热键定意图)。
    private var overlayMode: OverlayMode = .search
    /// F20 会话级 SCWindow 快照(整窗实抓用;与抓屏并行现拉,spec S1)。
    private var shotSCWindowsTask: Task<[UInt32: SCWindow], Never>?

    private var previousApp: NSRunningApplication?
    private var ocrTask: Task<Void, Never>?
    private var barcodeTask: Task<Void, Never>?
    private var lensPreparationTask: Task<Void, Never>?
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
        tray.onOpenItem = { [weak self] item in
            guard let self else { return }
            // spec S3:覆盖层还在(圈选 📸 后点托盘)→ 先退覆盖层再开编辑器,
            // 否则编辑器窗口开在 .screenSaver 覆盖层下面不可见(非会话期 no-op)
            self.dismissOverlay(immediate: true)
            self.editorManager.open(item)
        }
        tray.onPinItem = { [weak self] item in self?.pinManager.pin(item: item) }
        pinManager.onAnnotate = { [weak self] item in
            guard let self else { return }
            self.dismissOverlay(immediate: true)
            self.editorManager.open(item)
        }
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

    /// F20 菜单栏「截图」/ `c2s://shot`。
    public func shotNow() { handle(.shotMenu) }

    /// F20 直拍当前屏全屏(菜单栏「截取全屏」/ `c2s://shot?mode=full`,不进覆盖层)。
    /// afterMenuFade:菜单触发延迟 ~180ms 等菜单淡出,避免拍到残影(spec S1)。
    public func shotFullScreenNow(afterMenuFade: Bool = false) {
        guard phase == .idle else { return }
        phase = .capturing
        Task { @MainActor [weak self] in
            guard let self else { return }
            if afterMenuFade {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            self.tray.hideForCapture() // 托盘不入镜(spec §10)
            do {
                let result = try await self.capture.captureScreenUnderMouse()
                self.tray.restoreAfterCapture()
                self.phase = .idle
                self.shotPipeline.deliver(.init(image: result.image,
                                                pointSize: result.context.pointSize,
                                                forcePNG: false,
                                                originGlobal: result.context.screenFrame),
                                          on: result.context.screenFrame)
            } catch {
                self.tray.restoreAfterCapture()
                self.phase = .idle
                self.showCaptureError(error)
            }
        }
    }

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
            // 跨模式互斥(spec S1):截图会话中按圈选热键 = 先结束再进圈选。
            // immediate:淡出中的旧覆盖层会被拍进新冻结帧(抓屏不排除自家窗口)。
            if phase == .overlayActive {
                let wasShot = overlayMode == .shot
                dismissOverlay(immediate: wasShot)
                if !wasShot { return } // 同模式再按 = 关
            }
            beginCapture(mode: .search)
        case .shotHotkey, .shotMenu:
            if phase == .overlayActive {
                let wasSearch = overlayMode == .search
                dismissOverlay(immediate: wasSearch)
                if !wasSearch { return } // 同模式再按 = 关
            }
            beginCapture(mode: .shot)
        case .shotFullScreen:
            shotFullScreenNow()
        case .chargeBegan:
            // 蓄力的 ~250ms 里并行预抓屏 → 松手即冻结、零空窗(features F1)。
            // 无屏幕录制权限时绝不投机:captureScreenUnderMouse 会触发 TCC 授权弹窗,
            // 而任何 ⌘⇧ 前缀快捷键(⌘⇧Z/⌘⇧4…)按下过程都会路过「恰好 ⌘⇧」状态。
            guard phase == .idle, speculativeCapture == nil,
                  capture.hasScreenRecordingPermission else { return }
            let capture = self.capture
            let tray = self.tray
            speculativeCapture = Task {
                // 缓一拍再拍:⌘⇧ 前缀快捷键大多在此窗口内结束并取消蓄力,
                // 避免每按一次 ⌘⇧Z 就白拍一张全屏。托盘也在这一拍之后才避让
                // (spec §10)——放在 sleep 前会让每次 ⌘⇧Z 都看到托盘闪没闪回。
                try await Task.sleep(nanoseconds: 120_000_000)
                try Task.checkCancellation()
                tray.hideForCapture()
                return try await capture.captureScreenUnderMouse()
            }
        case .chargeFired:
            Haptics.fire() // 蓄力跨过阈值(触控板)
            beginCapture(mode: .search)
        case .chargeCancelled:
            speculativeCapture?.cancel()
            speculativeCapture = nil
            // 只在空闲态恢复:截图会话期间(托盘刻意压住到会话结束)路过的
            // ⌘⇧ 松开不能把托盘放回来挡住点击目标
            if phase == .idle { tray.restoreAfterCapture() }
        }
    }

    private func beginCapture(mode: OverlayMode = .search) {
        guard phase == .idle else { return } // capturing/overlay 时再触发一律忽略
        phase = .capturing
        overlayMode = mode
        previousApp = NSWorkspace.shared.frontmostApplication
        tray.hideForCapture() // 冻结帧不含托盘(spec §10:连拍第二张不入镜)
        if mode == .shot {
            // 会话级 SCWindow 快照与抓屏并行现拉(整窗实抓用;不读长寿命缓存,spec S1)
            shotSCWindowsTask?.cancel()
            shotSCWindowsTask = Task { await WindowSnapshotBuilder.freshSCWindows() }
        }
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
                // 帧已定格:圈选模式托盘立即回来(📸 投递可见,spec §10);
                // 截图模式保持隐藏到会话结束——托盘层级高于覆盖层,留着会挡住
                // 左下角的窗口点击目标,dismissOverlay 统一恢复。
                if mode == .search { self.tray.restoreAfterCapture() }
                self.presentOverlay(with: result)
            } catch {
                self.tray.restoreAfterCapture()
                self.phase = .idle
                self.showCaptureError(error)
            }
        }
    }

    // MARK: - 覆盖层

    private func presentOverlay(with result: CaptureResult) {
        if overlayMode == .shot {
            presentShotOverlay(with: result)
            return
        }
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
        cb.onShootSelection = { [weak self] rect in self?.shootSelection(overlayRect: rect) }
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

        // F24 窗口手柄(spec S7):会话级窗口快照,与 shot 模式同一数据源
        overlay.updateSearchWindows(WindowSnapshotBuilder.pickables(for: result.context))

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

    // MARK: - F20 截图模式(spec §2:松手/点击即快门,覆盖层立刻退,不跑 OCR/条码)

    private func presentShotOverlay(with result: CaptureResult) {
        phase = .overlayActive
        currentCapture = result

        var cb = OverlayWindowController.ShotCallbacks()
        cb.onRegion = { [weak self] rect in self?.shootRegion(rect) }
        cb.onWindow = { [weak self] win in self?.shootWindow(win) }
        cb.onFullScreen = { [weak self] in self?.shootFrozenFullScreen() }
        cb.onDismiss = { [weak self] in self?.dismissOverlay() }
        overlay.presentShot(capture: result, callbacks: cb, reduceEffects: settings.reduceEffects)

        // 命中列表:CGWindowList 同步、便宜,z-order 有文档保证(spec §8)
        overlay.updateShotWindows(WindowSnapshotBuilder.pickables(for: result.context))
    }

    /// 快门后的覆盖层退场:留 ~150ms 给闪白动画(减弱动态 = 立即)。
    /// 产物在快门当刻已交付——闪白期间按 Esc/热键只会让这里的延迟退场空转,不丢图。
    private func dismissOverlayAfterShutterFlash() {
        let reduce = settings.reduceEffects
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduce {
            dismissOverlay()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            MainActor.assumeIsolated { self?.dismissOverlay() }
        }
    }

    /// 区域截图:从冻结帧裁剪(所见即所得,spec S2)。
    private func shootRegion(_ rect: CGRect) {
        guard let cap = currentCapture else { return }
        let px = cap.context.pixelRect(fromOverlay: rect)
        guard !px.isNull, px.width >= 2, px.height >= 2,
              let cropped = cap.image.cropping(to: px) else {
            dismissOverlay()
            return
        }
        shotPipeline.deliver(.init(image: cropped, pointSize: rect.size, forcePNG: false,
                                   originGlobal: cap.context.globalRect(fromOverlay: rect)),
                             on: cap.context.screenFrame)
        dismissOverlayAfterShutterFlash()
    }

    /// ⏎ 全屏:整张冻结帧。
    private func shootFrozenFullScreen() {
        guard let cap = currentCapture else { return }
        shotPipeline.deliver(.init(image: cap.image,
                                   pointSize: cap.context.pointSize,
                                   forcePNG: false,
                                   originGlobal: cap.context.screenFrame),
                             on: cap.context.screenFrame)
        dismissOverlayAfterShutterFlash()
    }

    /// 整窗截图:快门时刻单窗实抓(透明圆角+合成阴影;内容以快门时刻为准,
    /// 接受与冻结预览的时差,spec S2)。窗口已消失/实抓失败 → 回退按窗框裁冻结帧。
    private func shootWindow(_ win: PickableWindow) {
        guard let cap = currentCapture else { return }
        let context = cap.context
        let frozen = cap.image
        let overlayFrame = win.frame
        let includeShadow = settings.shotWindowShadow
        let scTask = shotSCWindowsTask
        Task { @MainActor [weak self] in
            guard let self else { return }
            let originGlobal = context.globalRect(fromOverlay: overlayFrame)
            if let scWindow = (await scTask?.value)?[win.windowID],
               let output = try? await WindowCaptureService.capture(window: scWindow,
                                                                    includeShadow: includeShadow) {
                // 产物含阴影外扩边距 → origin 反向外扩,钉图才能「窗口框对齐原位、
                // 阴影向外溢出」(spec S6;不扩会整体偏 ~36pt,审查)
                let insets = output.shadowInsets
                let pinOrigin = CGRect(x: originGlobal.minX - insets.left,
                                       y: originGlobal.minY - insets.bottom,
                                       width: originGlobal.width + insets.left + insets.right,
                                       height: originGlobal.height + insets.top + insets.bottom)
                self.shotPipeline.deliver(.init(image: output.image,
                                                pointSize: output.pointSize,
                                                forcePNG: true, // 透明 alpha,强制 PNG(spec §6)
                                                originGlobal: pinOrigin),
                                          on: context.screenFrame)
                return
            }
            // 回退:无透明、无阴影(spec S2 静默降级)
            let px = context.pixelRect(fromOverlay: overlayFrame)
            guard !px.isNull, let cropped = frozen.cropping(to: px) else { return }
            self.shotPipeline.deliver(.init(image: cropped,
                                            pointSize: overlayFrame.size,
                                            forcePNG: false,
                                            originGlobal: originGlobal),
                                      on: context.screenFrame)
        }
        dismissOverlayAfterShutterFlash()
    }

    private func dismissOverlay(immediate: Bool = false) {
        guard phase == .overlayActive else { return }
        ocrTask?.cancel()
        ocrTask = nil
        if let image = currentCapture?.image {
            let ocr = self.ocr
            Task { await ocr.clearCache(for: image) }
        }
        barcodeTask?.cancel()
        barcodeTask = nil
        lensPreparationTask?.cancel()
        lensPreparationTask = nil
        // 只放引用不 cancel:shootWindow 已捕获本地引用,取消会把实抓打断成回退路径
        shotSCWindowsTask = nil
        currentCapture = nil
        lastImageSearchRect = nil
        lastLensThumbnail = nil
        pendingLensPrompt = nil
        promptMode = nil
        lensSessionURL = nil
        overlay.dismiss(immediate: immediate)
        phase = .idle
        tray.restoreAfterCapture() // 幂等;shot 会话期间被压住的托盘在此恢复
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: - 搜索路由

    private func performTextSearch(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        lastTextQuery = q
        lensPreparationTask?.cancel()
        lensPreparationTask = nil
        lastImageSearchRect = nil
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
        let prompt = L10n.f("prompt.translate_text", "将下面的文字翻译成%1$@:\n\n%2$@", targetName, text)
        guard let url = SearchURLBuilder.googleSearch(query: prompt,
                                                      viewport: overlay.viewportSize,
                                                      aiMode: true) else { return }
        promptMode = .translate
        lastTextQuery = text // 药丸保持原文,可编辑后重译
        overlay.showResult(.web(url), query: text,
                           chip: QueryModeChip(mode: .translate, icon: "translate",
                                               label: L10n.f("chip.translate", "翻译 · %@", targetName)))
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
        let prompt = L10n.f("prompt.visualize_text",
                            "请可视化下面的内容:适合数据或结构就生成可视化图表(信息图/流程图/对比表等),更适合画面就用 nano banana 生成一张图片:\n\n%@",
                            text)
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
        let prompt = L10n.f("prompt.translate_image",
                            "请把这张图片里的所有文字翻译成%@,按原文的结构和顺序输出译文。", targetName)
        fireLensPrompt(prompt, pillText: nil,
                       chip: QueryModeChip(mode: .translate, icon: "translate",
                                           label: L10n.f("chip.translate", "翻译 · %@", targetName)),
                       aiMode: true)
    }

    /// 迷你工具条「可视化」(图片选区,一次性动作):当前 Lens 会话 multisearch
    /// 挂可视化 prompt + AI Mode(图随会话参数保留,Gemini 能看到圈出的图)。
    /// 不设 promptMode:后续在搜索框输入 = 同会话 AI Mode 追问(multisearch 路由)。
    private func visualizeImageSelection() {
        let prompt = L10n.t("prompt.visualize_image",
                            "请可视化这张图片的内容:适合数据或结构就生成可视化图表(信息图/流程图/对比表等),更适合画面就用 nano banana 生成一张新图片来呈现。")
        fireLensPrompt(prompt, pillText: nil, chip: Self.visualizeChip, aiMode: true)
    }

    /// 编辑指令提交(v4,2026-07-03:迷你工具条「编辑」旁的内联输入框回车;
    /// 编辑模式下面板搜索框回车 = 同一入口):nano banana prompt 包装 +
    /// 当前 Lens 会话 multisearch + AI Mode。模式保持:改指令再回车 = 对原图重新编辑。
    private func performImageEdit(instruction: String) {
        let q = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        promptMode = .editImage
        let prompt = L10n.f("prompt.edit_image",
                            "请用 nano banana 编辑这张图片,直接生成编辑后的图片。编辑要求:%@", q)
        fireLensPrompt(prompt, pillText: q, chip: Self.editChip, aiMode: true)
    }

    private static var visualizeChip: QueryModeChip {
        QueryModeChip(mode: .visualize, icon: "chart.bar.xaxis",
                      label: L10n.t("common.visualize", "可视化"))
    }
    private static var editChip: QueryModeChip {
        QueryModeChip(mode: .editImage, icon: "wand.and.stars",
                      label: L10n.t("chip.edit", "编辑 · Nano Banana"))
    }

    /// 在当前圈图的 Lens 会话上挂 prompt 型查询:会话 URL(vsrid)已就绪 → 立即
    /// multisearch;未就绪(上传还在飞)→ 挂起,handleLensPageURL 就绪后自动发出。
    private func fireLensPrompt(_ query: String, pillText: String?,
                                chip: QueryModeChip?, aiMode: Bool) {
        // 后台载荷准备的几十毫秒内缩略图可能尚未就绪；仍记录用户意图，
        // 等 vsrid 到达后自动续发，不能让一次快速点击静默丢失。
        guard lastLensThumbnail != nil || lastImageSearchRect != nil
                || lensPreparationTask != nil else { return }
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
        lastLensThumbnail = nil
        // F9 二维码检测(纯增量,与下面的 Lens 图搜互不影响)
        detectBarcode(in: cropped, forRect: overlayRect)
        lensAttempt += 1
        let attempt = lensAttempt
        lensPreparationTask?.cancel()
        overlay.showResult(.loading(query: nil), query: nil)
        lensPreparationTask = Task.detached(priority: .userInitiated) { [weak self] in
            let thumbnail = LensService.downscaled(cropped, maxDimension: 240)
            do {
                // 降采样/JPEG/Base64/HTML 全部离开 MainActor；上传仍在同一 WKWebView 会话。
                let payload = try LensService().uploadPayload(for: cropped, attempt: attempt)
                guard !Task.isCancelled else { return }
                await self?.finishImageSearchPreparation(payload: payload,
                                                         thumbnail: thumbnail,
                                                         rect: overlayRect,
                                                         attempt: attempt)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failImageSearchPreparation(error, rect: overlayRect, attempt: attempt)
            }
        }
    }

    private func finishImageSearchPreparation(payload: LensUploadPayload,
                                              thumbnail: CGImage?,
                                              rect: CGRect,
                                              attempt: Int) {
        guard phase == .overlayActive, lensAttempt == attempt,
              lastImageSearchRect == rect else { return }
        lensPreparationTask = nil
        lastLensThumbnail = thumbnail
        overlay.showResult(.lensUpload(payload), query: nil, queryImage: thumbnail)
    }

    private func failImageSearchPreparation(_ error: Error, rect: CGRect, attempt: Int) {
        guard phase == .overlayActive, lensAttempt == attempt,
              lastImageSearchRect == rect else { return }
        lensPreparationTask = nil
        let message = (error as? LocalizedError)?.errorDescription
            ?? L10n.t("error.image_search_failed", "图像搜索失败,请重试。")
        overlay.showResult(.error(message: message, retry: { [weak self] in
            self?.performImageSearch(overlayRect: rect)
        }, login: nil), query: nil, queryImage: lastLensThumbnail)
    }

    /// F9 二维码检测(切片一):在圈选裁剪图上跑 Vision,与 Lens 图搜并行,命中即回填
    /// 给覆盖层(工具条按钮行下方出卡片)。守卫 `lastImageSearchRect + phase`:迟到的
    /// 检测若选区已变(快速改框到别处)或已退出覆盖层一律丢弃,不串卡。
    private func detectBarcode(in image: CGImage, forRect rect: CGRect) {
        overlay.updateBarcode(nil) // 新选区:先撤旧卡
        barcodeTask?.cancel()
        let barcode = self.barcode
        barcodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = await barcode.detect(in: image)
            guard !Task.isCancelled else { return }
            await self?.applyBarcodeResult(result, forRect: rect)
        }
    }

    /// 检测回主线程:选区未变(且仍在覆盖层)才回填,否则丢弃(迟到 = 已被顶掉)。
    private func applyBarcodeResult(_ result: BarcodeResult?, forRect rect: CGRect) {
        guard phase == .overlayActive, lastImageSearchRect == rect else { return }
        overlay.updateBarcode(result)
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
        lastLensThumbnail = nil
        lensAttempt += 1
        let attempt = lensAttempt
        let image = cap.image
        lensPreparationTask?.cancel()
        overlay.showResult(.loading(query: q), query: q)
        lensPreparationTask = Task.detached(priority: .userInitiated) { [weak self] in
            let thumbnail = LensService.downscaled(image, maxDimension: 240)
            do {
                let payload = try LensService().uploadPayload(for: image, attempt: attempt)
                guard !Task.isCancelled else { return }
                await self?.finishScreenQuestionPreparation(payload: payload,
                                                            thumbnail: thumbnail,
                                                            query: q,
                                                            attempt: attempt)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failScreenQuestionPreparation(error, query: q, attempt: attempt)
            }
        }
    }

    private func finishScreenQuestionPreparation(payload: LensUploadPayload,
                                                 thumbnail: CGImage?,
                                                 query: String,
                                                 attempt: Int) {
        guard phase == .overlayActive, lensAttempt == attempt,
              lastImageSearchRect == nil else { return }
        lensPreparationTask = nil
        lastLensThumbnail = thumbnail
        overlay.showResult(.lensUpload(payload), query: query, queryImage: thumbnail)
    }

    private func failScreenQuestionPreparation(_ error: Error, query: String, attempt: Int) {
        guard phase == .overlayActive, lensAttempt == attempt,
              lastImageSearchRect == nil else { return }
        lensPreparationTask = nil
        let message = (error as? LocalizedError)?.errorDescription
            ?? L10n.t("error.image_search_failed", "图像搜索失败,请重试。")
        overlay.showResult(.error(message: message, retry: { [weak self] in
            self?.askAboutScreen(query)
        }, login: nil), query: query, queryImage: lastLensThumbnail)
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

    /// F24 迷你工具条「📸 截图」(spec S8):当前选区落成完整截图产物
    /// (剪贴板 + 托盘 + 按设置落盘),**覆盖层不退**(可能还要接着搜)。
    /// 与 ⌘C 的分工:⌘C = 只进剪贴板的轻动作;📸 = 完整产物(可标注、可钉)。
    private func shootSelection(overlayRect: CGRect) {
        guard let cap = currentCapture else { return }
        let px = cap.context.pixelRect(fromOverlay: overlayRect)
        guard !px.isNull, px.width >= 2, px.height >= 2,
              let cropped = cap.image.cropping(to: px) else { return }
        Haptics.confirm() // 轻快门反馈(无闪白:覆盖层还在,别打断)
        shotPipeline.deliver(.init(image: cropped, pointSize: overlayRect.size, forcePNG: false,
                                   originGlobal: cap.context.globalRect(fromOverlay: overlayRect)),
                             on: cap.context.screenFrame)
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
        alert.messageText = L10n.t("alert.hotkey_failed_title", "热键注册失败")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showCaptureError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.capture_failed_title", "无法截取屏幕")
        alert.alertStyle = .warning
        if let e = error as? CaptureService.CaptureError, case .noPermission = e {
            // TCC 既定行为:授权只对之后新启动的进程生效,已运行的进程必须重启
            alert.informativeText = L10n.t("alert.capture_no_permission_body",
                                           "请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 Ringgo。\n若已允许,需要重新启动 Ringgo 才会生效。")
            alert.addButton(withTitle: L10n.t("alert.open_system_settings", "打开系统设置"))
            alert.addButton(withTitle: L10n.t("common.restart_ringgo", "重新启动 Ringgo"))
            alert.addButton(withTitle: L10n.t("common.cancel", "取消"))
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
                    alert.messageText = L10n.t("alert.relaunch_failed_title", "无法重新启动 Ringgo")
                    alert.informativeText = error?.localizedDescription
                        ?? L10n.t("alert.relaunch_failed_body", "系统没有启动新的 Ringgo 实例，请手动退出后重新打开应用。")
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}
