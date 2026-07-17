import AppKit
import SwiftUI
import UniformTypeIdentifiers
import C2SCore

/// F22 编辑器窗口管理(spec S4):每张截图一个文档窗口、可多开。
/// 生命周期与内存纪律:全分辨率解码位图**只在窗口打开期间存在**——
/// 关窗把纯值文档 + 原始编码 Data 存回托盘项(TrayShotItem.EditorState),
/// 释放 EditorModel/CGImage;重开再解码重建(spec S4「重开回到同一文档」)。
@MainActor
final class AnnotationEditorManager: NSObject {

    private let settings: SettingsStore
    private weak var tray: QuickAccessTray?
    private let pinManager: PinManager
    /// S5 共享搜索面板(单实例,跟随最近发起请求的编辑器窗口停靠)。
    private let searchPanel: EditorSearchPanelController
    private var windows: [UUID: EditorWindowBox] = [:]

    /// item 直接存进 box:脏关窗的「保存」不得回查托盘——编辑期间项可能已被
    /// 移除(拖出/×/自动收起),回查得 nil 会让保存静默失效(2026-07-17 审查)。
    private final class EditorWindowBox {
        let window: NSWindow
        let model: EditorModel
        let item: TrayShotItem
        var keyMonitor: Any?
        init(window: NSWindow, model: EditorModel, item: TrayShotItem) {
            self.window = window
            self.model = model
            self.item = item
        }
    }

    init(settings: SettingsStore, tray: QuickAccessTray, pinManager: PinManager) {
        self.settings = settings
        self.tray = tray
        self.pinManager = pinManager
        self.searchPanel = EditorSearchPanelController(
            reduceEffects: { [weak settings] in settings?.reduceEffects ?? false })
    }

    // MARK: 打开 / 关闭

    func open(_ item: TrayShotItem) {
        if let box = windows[item.id] {
            box.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 续编回原始底图(Done 后 item.data 已是压平版);首开即当前 data
        let sourceData = item.editorState?.sourceData ?? item.data
        let sourcePointSize = item.editorState?.sourcePointSize ?? item.pointSize
        guard let source = Self.decodeImage(sourceData) else { return }
        let model = EditorModel(source: source,
                                pointSize: sourcePointSize,
                                displayName: item.fileURL?.lastPathComponent
                                    ?? FilenameTemplate.expand(settings.shotFilenameTemplate,
                                                               date: Date()),
                                document: item.editorState?.document,
                                committed: item.editorState?.committedDocument)
        if item.editorState == nil {
            item.editorState = .init(document: model.document,
                                     committedDocument: model.committedSnapshot,
                                     sourceData: sourceData,
                                     sourcePointSize: sourcePointSize)
        }
        tray?.pauseAutoDismiss(for: item.id) // 编辑中项不许被自动收起(spec S4)

        let window = makeWindow(for: model, item: item)
        let box = EditorWindowBox(window: window, model: model, item: item)
        windows[item.id] = box
        installKeyMonitor(box: box)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close(itemID: UUID) {
        guard let box = windows[itemID] else { return }
        // 纯值状态回写托盘项;EditorModel(连同 5K 位图)随 box 释放
        box.item.editorState?.document = box.model.document
        box.item.editorState?.committedDocument = box.model.committedSnapshot
        if let monitor = box.keyMonitor { NSEvent.removeMonitor(monitor) }
        box.keyMonitor = nil
        windows[itemID] = nil
        box.window.delegate = nil
        box.window.orderOut(nil)
        tray?.resumeAutoDismiss(for: itemID)
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func makeWindow(for model: EditorModel, item: TrayShotItem) -> NSWindow {
        let root = EditorRootView(
            model: model,
            reduceEffects: settings.reduceEffects,
            onDone: { [weak self] in self?.finishDone(itemID: item.id) },
            onSaveAs: { [weak self] in self?.saveAs(itemID: item.id) },
            onCopy: { [weak self] in self?.copyFlattened(itemID: item.id) },
            onShare: { [weak self] anchor in self?.share(itemID: item.id, anchor: anchor) },
            provideDragFileURL: { [weak self] in self?.dragFileURL(itemID: item.id) },
            onPin: { [weak self] in self?.pinCurrent(itemID: item.id) },
            onAIPrompt: { [weak self] kind in self?.sendAIPrompt(itemID: item.id, kind: kind) },
            onAsk: { [weak self] text in self?.sendAsk(itemID: item.id, text: text) })

        let hosting = NSHostingView(rootView: root)
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let pointSize = CGSize(width: model.document.pixelSize.width / model.pixelsPerPoint,
                               height: model.document.pixelSize.height / model.pixelsPerPoint)
        let width = min(max(pointSize.width + 80, 760), visible.width * 0.85)
        let height = min(max(pointSize.height + 150, 520), visible.height * 0.85)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = model.displayName
        window.minSize = CGSize(width: 640, height: 420)
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    // MARK: 键盘(菜单栏代理无 Edit 菜单,快捷键不会自动路由 → 本地监听)

    private func installKeyMonitor(box: EditorWindowBox) {
        box.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak box] event in
            var consume = false
            MainActor.assumeIsolated {
                guard let self, let box, event.window === box.window else { return }
                let model = box.model
                // 前向删除/方向键等恒带 .function,不剥掉会让 keyCode 117 成死分支
                let flags = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting(.function)
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                // 文字编辑态放行一切(输入框自己的 ⌘Z/Delete)
                if model.editingTextID != nil { return }
                switch (flags, key, event.keyCode) {
                case ([.command], "z", _):
                    if model.undoManager.canUndo { model.undoManager.undo() }
                    consume = true
                case ([.command, .shift], "z", _):
                    if model.undoManager.canRedo { model.undoManager.redo() }
                    consume = true
                case ([.command], "c", _):
                    self.copyFlattened(itemID: box.item.id)
                    consume = true
                case ([.command], "s", _):
                    self.finishDone(itemID: box.item.id)
                    consume = true
                case ([.command, .shift], "s", _):
                    self.saveAs(itemID: box.item.id)
                    consume = true
                case ([.command], "=", _), ([.command], "+", _):
                    model.stepZoom(1) // spec S4:⌘+ 放大
                    consume = true
                case ([.command], "-", _):
                    model.stepZoom(-1)
                    consume = true
                case ([.command], "0", _):
                    model.zoomToFit()
                    consume = true
                case ([], _, 51), ([], _, 117): // Delete / 前向删除
                    if model.selectedID != nil {
                        model.removeSelected()
                        consume = true
                    }
                case ([], _, 53): // Esc:取消选中(不关窗,防误触丢工作)
                    if model.selectedID != nil {
                        model.selectedID = nil
                        consume = true
                    }
                default:
                    break
                }
            }
            return consume ? nil : event
        }
    }

    // MARK: 交付(spec S4 Done 矩阵)

    /// Done = 压平持久化 + 关窗:落盘开(或已有文件)→ **覆盖同一文件**;
    /// 剪贴板开 → 同步刷新;两开关全关 → 兜底写剪贴板。
    /// 写盘失败 → 原生报错、**不关窗不更新托盘**(绝不让用户误以为已保存)。
    private func finishDone(itemID: UUID) {
        guard let box = windows[itemID] else { return }
        let model = box.model
        let item = box.item
        model.commitTextEditing()
        guard let flattened = model.flatten() else { return }
        let pointSize = model.flattenedPointSize

        let usePNG = item.ext == "png"
        guard let data = usePNG
            ? ShotImageEncoder.pngData(flattened, pointSize: pointSize)
            : ShotImageEncoder.jpegData(flattened, pointSize: pointSize) else { return }

        // 落盘:覆盖原文件(对齐 CleanShot);未落盘且设置开 → 按模板写新文件
        var wroteToDisk = false
        do {
            if let url = item.fileURL {
                try data.write(to: url, options: .atomic)
                wroteToDisk = true
            } else if settings.shotAutoSave {
                item.fileURL = try ShotPipeline.writeData(data, ext: item.ext,
                                                          directory: settings.shotSaveDirectoryURL,
                                                          template: settings.shotFilenameTemplate)
                wroteToDisk = true
            }
        } catch {
            ShotPipeline.presentSaveError(
                error,
                directory: item.fileURL?.deletingLastPathComponent()
                    ?? settings.shotSaveDirectoryURL)
            return // 交付未完成:窗口留着,用户可另存/重试
        }
        // 剪贴板:开 → 刷新;没写成盘 → 兜底写(产物必须有去处,spec S4)
        if settings.shotCopyToClipboard || !wroteToDisk {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            if let png = ShotImageEncoder.pngData(flattened, pointSize: pointSize) {
                pasteboard.setData(png, forType: .png)
            }
            if let tiff = ShotImageEncoder.tiffData(flattened, pointSize: pointSize) {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
        // 托盘项同步(缩略图 = 标注后版本,spec S4)
        let thumbnail = LensService.downscaled(flattened, maxDimension: 480) ?? flattened
        item.updateFlattened(data: data, thumbnail: thumbnail, pointSize: pointSize)
        tray?.refreshLayout()

        model.markCommitted()
        Haptics.confirm()
        close(itemID: itemID)
    }

    private func saveAs(itemID: UUID) {
        guard let box = windows[itemID] else { return }
        let model = box.model
        let item = box.item
        model.commitTextEditing()
        guard let flattened = model.flatten() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [item.ext == "png" ? .png : .jpeg]
        panel.nameFieldStringValue = model.displayName.isEmpty
            ? FilenameTemplate.expand(settings.shotFilenameTemplate, date: Date())
            : model.displayName
        panel.beginSheetModal(for: box.window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                let pointSize = model.flattenedPointSize
                let data = item.ext == "png"
                    ? ShotImageEncoder.pngData(flattened, pointSize: pointSize)
                    : ShotImageEncoder.jpegData(flattened, pointSize: pointSize)
                do {
                    try data?.write(to: url, options: .atomic)
                } catch {
                    ShotPipeline.presentSaveError(error, directory: url.deletingLastPathComponent())
                }
            }
        }
    }

    private func copyFlattened(itemID: UUID) {
        guard let box = windows[itemID] else { return }
        box.model.commitTextEditing()
        guard let flattened = box.model.flatten() else { return }
        let pointSize = box.model.flattenedPointSize
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png = ShotImageEncoder.pngData(flattened, pointSize: pointSize) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = ShotImageEncoder.tiffData(flattened, pointSize: pointSize) {
            pasteboard.setData(tiff, forType: .tiff)
        }
        Haptics.confirm()
    }

    /// anchor = 分享按钮的 frame(SwiftUI .global,顶左原点——与 flipped 的
    /// NSHostingView 同一坐标系,直接可用;审查修正:此前锚点算到右上角)。
    private func share(itemID: UUID, anchor: CGRect) {
        guard let box = windows[itemID] else { return }
        box.model.commitTextEditing()
        guard let flattened = box.model.flatten() else { return }
        let image = NSImage(cgImage: flattened, size: box.model.flattenedPointSize)
        guard let contentView = box.window.contentView else { return }
        let picker = NSSharingServicePicker(items: [image])
        let rect = anchor.isEmpty
            ? CGRect(x: contentView.bounds.maxX - 40,
                     y: contentView.bounds.maxY - 36, width: 24, height: 24)
            : anchor
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }

    // MARK: F23 钉图 / S5 AI chips(发出去的都是「含标注压平的当前画布」)

    private func pinCurrent(itemID: UUID) {
        guard let box = windows[itemID] else { return }
        box.model.commitTextEditing()
        guard let flattened = box.model.flatten() else { return }
        pinManager.pin(image: flattened,
                       pointSize: box.model.flattenedPointSize,
                       origin: box.item.originGlobal,
                       item: box.item)
    }

    /// 翻译整图 / 可视化:一次性动作,prompt 复用 F15(spec S5)。
    private func sendAIPrompt(itemID: UUID, kind: EditorAIPrompt) {
        guard let box = windows[itemID] else { return }
        box.model.commitTextEditing()
        guard let flattened = box.model.flatten() else { return }
        switch kind {
        case .translate:
            let targetName = currentTranslationTargetName()
            let prompt = L10n.f("prompt.translate_image",
                                "请把这张图片里的所有文字翻译成%@,按原文的结构和顺序输出译文。", targetName)
            searchPanel.send(image: flattened, query: prompt, pillText: nil,
                             chip: QueryModeChip(mode: .translate, icon: "translate",
                                                 label: L10n.f("chip.translate", "翻译 · %@", targetName)),
                             aiMode: true, nextTo: box.window)
        case .visualize:
            let prompt = L10n.t("prompt.visualize_image",
                                "请可视化这张图片的内容:适合数据或结构就生成可视化图表(信息图/流程图/对比表等),更适合画面就用 nano banana 生成一张新图片来呈现。")
            searchPanel.send(image: flattened, query: prompt, pillText: nil,
                             chip: QueryModeChip(mode: .visualize, icon: "chart.bar.xaxis",
                                                 label: L10n.t("common.visualize", "可视化")),
                             aiMode: true, nextTo: box.window)
        }
    }

    /// 提问:整图 + 问题(每次发送 = 新会话重传当前画布,spec S5)。
    /// aiMode = true 按 spec S5 字面(multisearch + AI Mode,图+文问答);
    /// F11 覆盖层整屏提问现行为 false,两处分歧已在 spec 决策记录标注。
    private func sendAsk(itemID: UUID, text: String) {
        guard let box = windows[itemID] else { return }
        box.model.commitTextEditing()
        guard let flattened = box.model.flatten() else { return }
        searchPanel.send(image: flattened, query: text, pillText: text,
                         chip: nil, aiMode: true, nextTo: box.window)
    }

    /// F10 语言 UX 同源:目标 = 设置持久值 ∨ 系统首选。
    private func currentTranslationTargetName() -> String {
        let code = settings.translationTargetCode.isEmpty
            ? (TranslationLanguageOption.menuOptions().first?.id ?? "en")
            : settings.translationTargetCode
        return TranslationLanguageOption.option(for: code).displayName
    }

    /// Drag Me:拖起时现场压平写临时文件(spec S4,机制同托盘拖出)。
    private func dragFileURL(itemID: UUID) -> URL? {
        guard let box = windows[itemID] else { return nil }
        box.model.commitTextEditing()
        guard let flattened = box.model.flatten() else { return nil }
        let pointSize = box.model.flattenedPointSize
        guard let data = box.item.ext == "png"
            ? ShotImageEncoder.pngData(flattened, pointSize: pointSize)
            : ShotImageEncoder.jpegData(flattened, pointSize: pointSize) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinggoDrag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try? ShotPipeline.writeData(data, ext: box.item.ext, directory: dir,
                                           template: settings.shotFilenameTemplate)
    }
}

// MARK: - 关窗(× 脏检查,spec S4:问一次;「不保存」不丢矢量文档——纯值状态存回托盘项)

extension AnnotationEditorManager: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let (itemID, box) = windows.first(where: { $0.value.window === sender }) else {
            return true
        }
        box.model.commitTextEditing()
        guard box.model.isDirty else {
            close(itemID: itemID)
            return false // close() 自己收窗
        }
        let alert = NSAlert()
        alert.messageText = L10n.t("editor.close_title", "标注还没保存")
        alert.informativeText = L10n.t("editor.close_body",
                                       "保存:写进文件再关。不保存:标注留着,下次从托盘点开接着改。")
        alert.addButton(withTitle: L10n.t("editor.close_save", "保存"))
        alert.addButton(withTitle: L10n.t("editor.close_discard", "不保存"))
        alert.addButton(withTitle: L10n.t("common.cancel", "取消"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    self.finishDone(itemID: itemID) // box.item 直达,不回查托盘
                case .alertSecondButtonReturn:
                    self.close(itemID: itemID) // 文档存回 item.editorState,重开可续
                default:
                    break
                }
            }
        }
        return false
    }
}
