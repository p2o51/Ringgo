import AppKit
import SwiftUI
import C2SCore

// MARK: - 托盘项

/// F21 托盘项(运行期状态,重启不恢复;「截图历史」列后续,spec S3)。
/// 内存纪律:只持有「已编码 Data + 降采样缩略图」,绝不拿原始 CGImage
/// (区域裁剪与整张 5K 冻结帧共享后备存储,拿住 = 每项钉 ~50MB)。
@MainActor
public final class TrayShotItem: ObservableObject, Identifiable {
    public let id = UUID()
    /// 降采样缩略图(≤480px,重绘所得,与原帧解耦)。
    let thumbnail: CGImage
    let pointSize: CGSize
    /// 交付格式的完整编码数据(💾/拖出直接写它,不再重编码)。
    let data: Data
    /// "png" / "jpg"(交付时按设置与 forcePNG 定死,spec §6)。
    let ext: String
    /// 已落盘路径(nil = 未落盘;💾 或拖出时现场写)。
    @Published var fileURL: URL?
    /// 拖出用临时文件(未落盘项拖拽开始时现场写入,spec S3)。
    var dragTempURL: URL?

    init(thumbnail: CGImage, pointSize: CGSize, data: Data, ext: String, fileURL: URL?) {
        self.thumbnail = thumbnail
        self.pointSize = pointSize
        self.data = data
        self.ext = ext
        self.fileURL = fileURL
    }
}

// MARK: - 托盘控制器

/// F21 Quick Access 托盘(spec S3):快门所在屏左下角、不抢焦点、最新在上堆叠、
/// 悬停出动作、拖出即移除、点「+n」展开纵列。单实例:多屏连拍时整叠迁移。
@MainActor
public final class QuickAccessTray: ObservableObject {

    @Published private(set) var items: [TrayShotItem] = [] // 最新在前
    @Published var expanded = false
    /// 悬停托盘 = 暂停所有自动收起计时(spec S3)。
    @Published var panelHovered = false {
        didSet { panelHovered ? pauseAutoDismiss() : resumeAutoDismiss() }
    }

    static let visibleStackCount = 5

    private let settings: SettingsStore
    private var panel: NSPanel?
    private var hostingView: NSHostingView<TrayRootView>?
    /// 当前停靠屏(AppKit 全局 frame;新快门迁移,spec S3 单实例)。
    private var screenFrame: CGRect?
    private var hiddenForCapture = false
    private var dismissWorkItems: [UUID: DispatchWorkItem] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: 增删

    func add(_ item: TrayShotItem, on screenFrame: CGRect) {
        items.insert(item, at: 0)
        self.screenFrame = screenFrame // 整叠迁移到快门所在屏
        scheduleAutoDismiss(for: item)
        layoutPanel()
    }

    func remove(_ item: TrayShotItem) {
        dismissWorkItems.removeValue(forKey: item.id)?.cancel()
        items.removeAll { $0.id == item.id }
        if items.count <= Self.visibleStackCount { expanded = false }
        layoutPanel()
    }

    /// 💾:未落盘 = 立即按模板落盘(失败原生报错,不静默吞);已落盘 = 在 Finder 中显示。
    func saveOrReveal(_ item: TrayShotItem) {
        if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let directory = settings.shotSaveDirectoryURL
        do {
            item.fileURL = try ShotPipeline.writeData(item.data, ext: item.ext,
                                                      directory: directory,
                                                      template: settings.shotFilenameTemplate)
        } catch {
            ShotPipeline.presentSaveError(error, directory: directory)
        }
    }

    func setExpanded(_ value: Bool) {
        expanded = value
        layoutPanel()
    }

    // MARK: 拖出(spec S3:拖走就是拿走)

    /// 拖拽开始:保证有可拖的文件 URL(未落盘 → 现场写临时文件,
    /// 比 NSFilePromiseProvider 兼容面广)。失败报错并返回 nil(不启动拖拽)。
    func fileURLForDrag(_ item: TrayShotItem) -> URL? {
        if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) { return url }
        if let url = item.dragTempURL, FileManager.default.fileExists(atPath: url.path) { return url }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinggoDrag", isDirectory: true)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        do {
            item.dragTempURL = try ShotPipeline.writeData(item.data, ext: item.ext,
                                                          directory: dir,
                                                          template: settings.shotFilenameTemplate)
            return item.dragTempURL
        } catch {
            ShotPipeline.presentSaveError(error, directory: dir)
            return nil
        }
    }

    func dragEnded(_ item: TrayShotItem, completed: Bool) {
        if completed { remove(item) }
    }

    // MARK: 自动收起(spec S3:默认关;开 = N 秒后托盘项消失,悬停暂停)

    private func scheduleAutoDismiss(for item: TrayShotItem) {
        guard settings.shotTrayAutoDismiss, !panelHovered else { return }
        let seconds = max(1, settings.shotTrayAutoDismissSeconds)
        let work = DispatchWorkItem { [weak self, weak item] in
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                self.remove(item)
            }
        }
        dismissWorkItems[item.id]?.cancel()
        dismissWorkItems[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func pauseAutoDismiss() {
        for (_, work) in dismissWorkItems { work.cancel() }
        dismissWorkItems.removeAll()
    }

    private func resumeAutoDismiss() {
        guard settings.shotTrayAutoDismiss else { return }
        for item in items { scheduleAutoDismiss(for: item) }
    }

    // MARK: 抓屏避让(spec §10:冻结帧不含托盘)

    func hideForCapture() {
        guard !hiddenForCapture else { return }
        hiddenForCapture = true
        panel?.orderOut(nil)
    }

    func restoreAfterCapture() {
        guard hiddenForCapture else { return }
        hiddenForCapture = false
        layoutPanel()
    }

    // MARK: 面板(spec S3 checklist:AppKit 暗坑都在这)

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.hidesOnDeactivate = false          // 默认 true:app 失活托盘会凭空消失
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        // 必须最后设 level 且不碰 isFloatingPanel(它会把 level 重置回 .floating):
        // 托盘要高于覆盖层(.screenSaver)——圈选 📸 后托盘得盖在覆盖层上(spec §10),
        // 同级靠 order 压层不可靠。
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        assert(p.level.rawValue == NSWindow.Level.screenSaver.rawValue + 1)
        panel = p
        return p
    }

    private func layoutPanel() {
        guard !items.isEmpty else {
            panel?.orderOut(nil)
            expanded = false
            return
        }
        let panel = ensurePanel()
        let root = TrayRootView(tray: self)
        if let hostingView {
            hostingView.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hostingView = hv
            panel.contentView = hv
        }
        guard let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        // 停靠在可见区(visibleFrame):托盘层级高于 Dock,用整屏 frame 会压住 Dock 角落图标
        let frame = screenFrame ?? NSScreen.main?.frame ?? .zero
        let anchor = NSScreen.screens.first(where: { $0.frame == frame })?.visibleFrame ?? frame
        let margin: CGFloat = 16
        let x: CGFloat
        switch settings.shotTrayCorner {
        case .bottomLeft: x = anchor.minX + margin
        case .bottomRight: x = anchor.maxX - margin - size.width
        }
        panel.setFrame(CGRect(x: x, y: anchor.minY + margin,
                              width: size.width, height: size.height),
                       display: true)
        if !hiddenForCapture {
            panel.orderFrontRegardless()
        }
    }
}

// MARK: - SwiftUI 内容

/// 托盘根视图:折叠 = 错位堆叠(最新在上)+「+n」徽标;展开 = 可滚动纵列。
struct TrayRootView: View {
    @ObservedObject var tray: QuickAccessTray

    private static let cardWidth: CGFloat = 192
    private static let cardHeight: CGFloat = 122
    private static let stackOffset: CGFloat = 9

    var body: some View {
        Group {
            if tray.expanded {
                expandedList
            } else {
                collapsedStack
            }
        }
        .padding(12)
        .onHover { tray.panelHovered = $0 }
    }

    private var collapsedStack: some View {
        let visible = Array(tray.items.prefix(QuickAccessTray.visibleStackCount))
        let hiddenCount = tray.items.count - visible.count
        return ZStack(alignment: .bottom) {
            ForEach(Array(visible.enumerated().reversed()), id: \.element.id) { index, item in
                TrayCardView(item: item, tray: tray, interactive: index == 0)
                    .scaleEffect(1 - CGFloat(index) * 0.03, anchor: .bottom)
                    .offset(y: -CGFloat(index) * Self.stackOffset)
                    .allowsHitTesting(index == 0)
            }
        }
        .frame(width: Self.cardWidth,
               height: Self.cardHeight + CGFloat(max(0, visible.count - 1)) * Self.stackOffset,
               alignment: .bottom)
        .overlay(alignment: .topTrailing) {
            if hiddenCount > 0 {
                Button {
                    tray.setExpanded(true)
                } label: {
                    Text("+\(hiddenCount)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.t("tray.expand", "展开全部"))
                .offset(x: 6, y: -6)
            }
        }
    }

    private var expandedList: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                tray.setExpanded(false)
            } label: {
                Label(L10n.t("tray.collapse", "收起"), systemImage: "chevron.down")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tray.items) { item in
                        TrayCardView(item: item, tray: tray, interactive: true)
                    }
                }
            }
            .frame(width: Self.cardWidth,
                   height: min(CGFloat(tray.items.count) * (Self.cardHeight + 8), 520))
        }
    }
}

/// 单张托盘卡:缩略图 + 悬停动作(💾 / ×)+ 整卡拖出。
/// 命中链:动作按钮区由 TrayDragNSView.hitTest 主动放行(exclusion),
/// 否则 AppKit 会把点击全喂给拖拽层,SwiftUI 按钮永远点不到。
private struct TrayCardView: View {
    @ObservedObject var item: TrayShotItem
    let tray: QuickAccessTray
    let interactive: Bool

    @State private var hovering = false

    /// 底部动作条在卡片(SwiftUI 左上原点)里的矩形;拖拽层按它放行点击。
    static let actionsRect = CGRect(x: (192 - 80) / 2, y: 122 - 44, width: 80, height: 40)

    var body: some View {
        ZStack {
            Image(decorative: item.thumbnail, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(width: 176, height: 100)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            if interactive {
                TrayDragSurface(item: item, tray: tray, actionsVisible: hovering)
            }
            if interactive && hovering {
                actions
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 192, height: 122)
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                tray.saveOrReveal(item)
            } label: {
                Image(systemName: item.fileURL == nil ? "square.and.arrow.down" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(item.fileURL == nil
                  ? L10n.t("tray.save", "保存")
                  : L10n.t("tray.reveal", "在 Finder 中显示"))

            Button {
                tray.remove(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("tray.remove", "移除(不删除已保存文件)"))
        }
    }
}

// MARK: - AppKit 拖出层(纯 SwiftUI .onDrag 在 macOS 上拖不出文件,spec S3)

private struct TrayDragSurface: NSViewRepresentable {
    let item: TrayShotItem
    let tray: QuickAccessTray
    let actionsVisible: Bool

    func makeNSView(context: Context) -> TrayDragNSView {
        let view = TrayDragNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TrayDragNSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: TrayDragNSView) {
        let item = self.item
        let tray = self.tray
        view.provideFileURL = { tray.fileURLForDrag(item) }
        view.dragPreview = NSImage(cgImage: item.thumbnail,
                                   size: fittedPreviewSize(for: item))
        view.onDragEnded = { completed in tray.dragEnded(item, completed: completed) }
        view.actionsVisible = actionsVisible
        view.actionsRectTopLeft = TrayCardView.actionsRect
    }

    private func fittedPreviewSize(for item: TrayShotItem) -> CGSize {
        let maxSide: CGFloat = 160
        let w = max(item.pointSize.width, 1)
        let h = max(item.pointSize.height, 1)
        let scale = min(1, maxSide / max(w, h))
        return CGSize(width: w * scale, height: h * scale)
    }
}

final class TrayDragNSView: NSView, NSDraggingSource {
    var provideFileURL: () -> URL? = { nil }
    var dragPreview: NSImage?
    var onDragEnded: (Bool) -> Void = { _ in }
    /// 悬停中(动作按钮可见)才对按钮区放行点击。
    var actionsVisible = false
    /// 动作按钮区(SwiftUI 左上原点坐标;hitTest 内换算)。
    var actionsRectTopLeft: CGRect = .zero

    private var mouseDownEvent: NSEvent?

    /// 按钮区放行:返回 nil 让事件落回 NSHostingView,由 SwiftUI Button 接住。
    /// 不放行的话 AppKit hitTest 会命中本视图,叠在上方的 SwiftUI 按钮永远点不到。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), hit === self else { return super.hitTest(point) }
        if actionsVisible {
            let local = convert(point, from: superview)
            // 非 flipped NSView:y 从底往上;换算 SwiftUI 顶原点矩形
            let flippedY = bounds.height - local.y
            if actionsRectTopLeft.contains(CGPoint(x: local.x, y: flippedY)) {
                return nil
            }
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) >= 4 else { return }
        mouseDownEvent = nil
        guard let url = provideFileURL() else { return }

        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = dragPreview
        let frame = previewFrame(for: preview)
        draggingItem.setDraggingFrame(frame, contents: preview)
        beginDraggingSession(with: [draggingItem], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil // 单击暂无动作(点开进编辑器 = 切片③)
    }

    private func previewFrame(for image: NSImage?) -> CGRect {
        guard let image else { return bounds }
        return CGRect(x: bounds.midX - image.size.width / 2,
                      y: bounds.midY - image.size.height / 2,
                      width: image.size.width, height: image.size.height)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        let completed = operation != []
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onDragEnded(completed) }
        }
    }
}
