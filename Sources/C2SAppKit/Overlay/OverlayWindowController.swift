import AppKit
import QuartzCore
import SwiftUI
import C2SCore

/// borderless 窗口默认拿不到键盘焦点,必须重写这两个属性(机制 §3)。
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 让 SwiftUI 内容可成为第一响应者(接键盘事件)。
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
}

/// 工具条共享状态(翻译目标语言等,选择后即时反映到底部工具条)。
@MainActor
final class OverlayToolbarState: ObservableObject {
    /// BCP-47;空 = 跟随系统首选语言。
    @Published var targetCode: String = ""
    let languages = TranslationLanguageOption.menuOptions()
    var currentTarget: TranslationLanguageOption {
        let code = targetCode.isEmpty ? (languages.first?.id ?? "en") : targetCode
        return TranslationLanguageOption.option(for: code)
    }
}

/// 覆盖层窗口控制器(机制 §3):borderless + canBecomeKey 的复用窗口、
/// `.screenSaver` 层级、盖全屏 App、ESC 取消(local monitor 吃掉事件)。
@MainActor
public final class OverlayWindowController {

    public struct Callbacks {
        public var onTextSearch: (String) -> Void = { _ in }
        /// 覆盖层点坐标的图搜选区(coordinator 负责换算像素并裁剪)。
        public var onImageSearch: (CGRect) -> Void = { _ in }
        /// 搜索框提交:(文字, 面板当前页 URL)。coordinator 按上下文路由:
        /// 图搜会话 → multisearch(在带 vsrid 的 URL 上加 q);否则整条文字查询。
        public var onQuerySubmit: (String, URL?) -> Void = { _, _ in }
        /// 面板 WebView 报告 Lens 被风控拦截(参数 = 用户可读原因)。
        public var onLensBlocked: (String) -> Void = { _ in }
        /// 面板 WebView 报告 Lens 导航失败(离线、DNS、TLS 等)。
        public var onLensFailure: (String) -> Void = { _ in }
        /// 底部工具条:整屏提问(整张截图发 Lens + 配上文字,安卓同款)。
        public var onAskAboutScreen: (String) -> Void = { _ in }
        /// 迷你工具条:复制图片选区(coordinator 裁剪并写剪贴板)。
        public var onCopyImage: (CGRect) -> Void = { _ in }
        /// 面板页面 URL 变化(整屏提问等待带 vsrid 的结果页就绪)。
        public var onLensPageURL: (URL?) -> Void = { _ in }
        public var onDismiss: () -> Void = {}
        public init() {}
    }

    public init() {
        self.sheetModel = ResultSheetModel()
        self.viewModel = SelectionViewModel()
    }

    public private(set) var isPresenting = false

    private var window: OverlayWindow?
    private var hostingView: OverlayHostingView<OverlayRootView>?
    private let sheetModel: ResultSheetModel
    private let viewModel: SelectionViewModel
    private var keyMonitor: Any?
    private var callbacks = Callbacks()
    private var context: DisplayContext?
    private var reduceEffects = false
    private let toolbarState = OverlayToolbarState()
    /// TranslationController(macOS 15+;旧系统 nil)。Any 盒装避免类型层面的可用性传染。
    private var translationBox: Any? = {
        if #available(macOS 15.0, *) { return TranslationController() }
        return nil
    }()
    private var onPickTranslationTarget: (String) -> Void = { _ in }

    /// 当前覆盖层视口点尺寸(= capture.context.pointSize;未展示时 .zero)。
    public var viewportSize: CGSize {
        context?.pointSize ?? .zero
    }

    /// 在 capture.context.screenFrame 对应屏幕上展示冻结覆盖层。
    public func present(capture: CaptureResult,
                        callbacks: Callbacks,
                        reduceEffects: Bool,
                        translationTargetCode: String = "",
                        onPickTranslationTarget: @escaping (String) -> Void = { _ in }) {
        self.callbacks = callbacks
        self.context = capture.context
        self.reduceEffects = reduceEffects
        self.toolbarState.targetCode = translationTargetCode
        self.onPickTranslationTarget = onPickTranslationTarget
        if #available(macOS 15.0, *), let tc = translationBox as? TranslationController {
            tc.dismiss() // 上一次会话的盖板不得串场
        }

        // 状态复位 + 接线(选择状态机的出口全部指向 coordinator 的回调)
        viewModel.reset()
        viewModel.prepare(viewport: capture.context.pointSize)
        viewModel.onTextSearch = callbacks.onTextSearch
        viewModel.onImageSearch = callbacks.onImageSearch
        viewModel.onDismiss = callbacks.onDismiss
        sheetModel.content = .hidden
        sheetModel.query = nil
        sheetModel.queryImage = nil
        sheetModel.currentPageURL = nil
        sheetModel.onQuerySubmit = { [weak self] text in
            guard let self else { return }
            self.callbacks.onQuerySubmit(text, self.sheetModel.currentPageURL)
        }
        sheetModel.onLensBlocked = callbacks.onLensBlocked
        sheetModel.onLensFailure = callbacks.onLensFailure
        sheetModel.onDismiss = callbacks.onDismiss
        sheetModel.onPageURLChanged = callbacks.onLensPageURL
        sheetModel.userMovedPanel = false
        sheetModel.dockTrailing = true

        let root = OverlayRootView(capture: capture,
                                   viewModel: viewModel,
                                   sheetModel: sheetModel,
                                   toolbarState: toolbarState,
                                   translationBox: translationBox,
                                   reduceEffects: reduceEffects,
                                   onAskAboutScreen: callbacks.onAskAboutScreen,
                                   onCopyImage: callbacks.onCopyImage,
                                   onPickTranslationTarget: { [weak self] code in
                                       self?.toolbarState.targetCode = code
                                       self?.onPickTranslationTarget(code)
                                   })
        let window = ensureWindow()
        if let hostingView {
            hostingView.rootView = root
        } else {
            let hv = OverlayHostingView(rootView: root)
            hostingView = hv
            window.contentView = hv
        }
        // 覆盖层与抓屏同屏(坐标 P0)
        window.setFrame(capture.context.screenFrame, display: true)

        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let hostingView { window.makeFirstResponder(hostingView) }
        installKeyMonitor()
        if !isPresenting { NSCursor.crosshair.push() }
        isPresenting = true

        if shouldReduceMotion {
            window.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    /// OCR 完成后发布词框(主线程调用)。
    public func updateWords(_ words: [OCRWord]) {
        guard isPresenting else { return }
        viewModel.updateWords(words)
    }

    /// 驱动结果面板(query/queryImage = 药丸里的查询上下文:文字或图搜缩略图)。
    public func showResult(_ content: ResultContent, query: String?, queryImage: CGImage? = nil) {
        guard isPresenting else { return }
        // 自动换边:选区在右半屏 → 面板停靠左侧(手动拖过则尊重手动位置)
        if !sheetModel.userMovedPanel,
           let bounds = viewModel.selectionBounds,
           let context {
            sheetModel.dockTrailing = bounds.midX <= context.pointSize.width / 2
        }
        sheetModel.loadToken &+= 1 // 同 URL 的新搜索也要强制重新加载
        sheetModel.content = content
        sheetModel.query = query
        sheetModel.queryImage = queryImage
    }

    /// 关闭覆盖层。幂等;内部不得再回调 onDismiss(防递归)。
    public func dismiss() {
        guard isPresenting else { return }
        isPresenting = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        NSCursor.pop()
        if #available(macOS 15.0, *), let tc = translationBox as? TranslationController {
            tc.dismiss()
        }
        viewModel.reset()
        sheetModel.content = .hidden
        sheetModel.query = nil
        sheetModel.queryImage = nil
        context = nil

        guard let window else { return }
        if shouldReduceMotion {
            window.alphaValue = 0
            window.orderOut(nil)
            releaseContentAfterDismiss()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // 淡出期间被重新 present 则不收窗口
                    guard let self, !self.isPresenting else { return }
                    self.window?.orderOut(nil)
                    self.releaseContentAfterDismiss()
                }
            })
        }
    }

    /// 空闲期不持有整屏截图:rootView 里的 CGImage 在 5K Retina 上 ~50MB,
    /// 收窗后必须连 hostingView 一起放掉(present 会按需重建)。
    private func releaseContentAfterDismiss() {
        guard !isPresenting else { return }
        window?.contentView = nil
        hostingView = nil
    }

    // MARK: - 窗口(懒创建一次,之后复用)

    private func ensureWindow() -> OverlayWindow {
        if let window { return window }
        let w = OverlayWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        window = w
        return w
    }

    private var shouldReduceMotion: Bool {
        reduceEffects || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - 键盘:ESC 取消、⌘C 复制选中文本(均吃掉事件防蜂鸣)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            var consume = false
            MainActor.assumeIsolated {
                guard let self, self.isPresenting else { return }
                if event.keyCode == 53 { // ESC
                    self.callbacks.onDismiss()
                    consume = true
                    return
                }
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.charactersIgnoringModifiers?.lowercased() == "c" {
                    // 面板/工具条输入框聚焦时放行系统复制,不劫持
                    if self.window?.firstResponder is NSTextView {
                        return
                    }
                    if let text = self.viewModel.selectedText {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        Haptics.confirm()
                        consume = true
                    } else if let rect = self.viewModel.rectSelection {
                        // 图片选区:coordinator 按坐标真源裁剪写剪贴板(v2,复制按钮已移除)
                        self.callbacks.onCopyImage(rect)
                        consume = true
                    }
                }
            }
            return consume ? nil : event
        }
    }
}
