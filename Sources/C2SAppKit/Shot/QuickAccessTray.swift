import AppKit
import SwiftUI
import C2SCore

// MARK: - 托盘项

/// F21 托盘项(运行期状态,重启不恢复;「截图历史」列后续,spec S3)。
/// 内存纪律:只持有「已编码 Data + 降采样缩略图」,绝不拿原始 CGImage。
/// 托盘累计超过常驻预算后，旧 Data 会异步落到专用临时文件并按需映射读取。
@MainActor
public final class TrayShotItem: ObservableObject, Identifiable {
    public let id = UUID()
    /// 降采样缩略图(≤480px,重绘所得,与原帧解耦)。Done 后更新为标注版。
    @Published private(set) var thumbnail: CGImage
    private(set) var pointSize: CGSize
    /// 交付格式的完整编码数据(💾/拖出/编辑器解码都用它,不持原始 CGImage)。
    /// 已溢写的旧项通过 mmap 风格读取，不重新永久驻留在托盘模型中。
    private var residentData: Data?
    private var spillURL: URL?
    private var storageRevision = 0
    private var spillPending = false

    var data: Data {
        if let residentData { return residentData }
        guard let spillURL else { return Data() }
        return (try? Data(contentsOf: spillURL, options: .mappedIfSafe)) ?? Data()
    }

    var residentByteCount: Int { residentData?.count ?? 0 }

    struct SpillRequest {
        let revision: Int
        let data: Data
        let url: URL
    }
    /// "png" / "jpg"(交付时按设置与 forcePNG 定死,spec §6)。
    let ext: String
    /// 已落盘路径(nil = 未落盘;💾 或拖出时现场写)。
    @Published var fileURL: URL?
    /// 拖出用临时文件(未落盘项拖拽开始时现场写入,spec S3)。
    var dragTempURL: URL?
    /// 截取区域的 AppKit 全局原位(F23 钉图「原位」;nil = 不可知)。
    let originGlobal: CGRect?
    /// F22 关窗后保留的编辑状态(spec S4:重开回到同一文档继续编辑)。
    /// 只存纯值文档 + 原始编码 Data——**不存 EditorModel/解码位图**
    /// (5K 位图 ~56MB,关窗必须释放;内存纪律同上)。
    struct EditorState {
        var document: AnnotationDocument
        var committedDocument: AnnotationDocument
        /// 第一次打开编辑器时的原始编码图(Done 会把 item.data 覆盖为压平版,
        /// 续编必须回到未压平的底图)。
        let sourceData: Data
        let sourcePointSize: CGSize
    }
    var editorState: EditorState?

    init(thumbnail: CGImage, pointSize: CGSize, data: Data, ext: String, fileURL: URL?,
         originGlobal: CGRect? = nil) {
        self.thumbnail = thumbnail
        self.pointSize = pointSize
        self.residentData = data
        self.ext = ext
        self.fileURL = fileURL
        self.originGlobal = originGlobal
    }

    /// Done 交付后同步(spec S4:托盘缩略图更新为标注后版本;裁剪会改 pointSize)。
    func updateFlattened(data: Data, thumbnail: CGImage, pointSize: CGSize) {
        storageRevision &+= 1
        spillPending = false
        discardSpillFile()
        residentData = data
        self.thumbnail = thumbnail
        self.pointSize = pointSize
        dragTempURL = nil // 旧临时文件内容已过期
    }

    func beginSpill() -> SpillRequest? {
        guard !spillPending, spillURL == nil, let residentData else { return nil }
        spillPending = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RinggoTray", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("image.\(ext)")
        return SpillRequest(revision: storageRevision, data: residentData, url: url)
    }

    func completeSpill(_ request: SpillRequest, succeeded: Bool) {
        spillPending = false
        guard succeeded, request.revision == storageRevision else {
            if succeeded {
                try? FileManager.default.removeItem(at: request.url.deletingLastPathComponent())
            }
            return
        }
        spillURL = request.url
        residentData = nil
    }

    func discardTemporaryStorage() {
        storageRevision &+= 1
        spillPending = false
        discardSpillFile()
    }

    private func discardSpillFile() {
        guard let spillURL else { return }
        try? FileManager.default.removeItem(at: spillURL.deletingLastPathComponent())
        self.spillURL = nil
    }
}

// MARK: - 托盘控制器

/// F21 Quick Access 托盘(spec S3):快门所在屏左下角、不抢焦点、最新在上堆叠、
/// 悬停出动作、拖出即移除、点「+n」展开纵列。单实例:多屏连拍时整叠迁移。
@MainActor
public final class QuickAccessTray: ObservableObject {

    @Published private(set) var items: [TrayShotItem] = [] // 最新在前
    @Published var expanded = false
    /// 悬停托盘 = 暂停所有自动收起计时(spec S3)+ 堆叠扇开(v2)。
    @Published var panelHovered = false {
        didSet { panelHovered ? pauseAutoDismiss() : resumeAutoDismiss() }
    }
    /// v2(2026-07-17 用户拍板):悬停中的卡片升到最上层——被压住的图也点得到。
    @Published var hoveredCardID: UUID?

    static let visibleStackCount = 5
    /// 完整编码图累计常驻上限；超限时保留托盘项与缩略图，只把较旧原图溢写磁盘。
    static let maxResidentDataBytes = 256 * 1_024 * 1_024

    /// F22:点卡片/✏️ = 打开编辑器(coordinator 注入,spec S3)。
    var onOpenItem: ((TrayShotItem) -> Void)?
    /// F23:📌 = 钉图(coordinator 注入)。
    var onPinItem: ((TrayShotItem) -> Void)?

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
        enforceResidentDataBudget()
        layoutPanel()
    }

    func remove(_ item: TrayShotItem) {
        dismissWorkItems.removeValue(forKey: item.id)?.cancel()
        items.removeAll { $0.id == item.id }
        item.discardTemporaryStorage()
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

    func item(id: UUID) -> TrayShotItem? {
        items.first { $0.id == id }
    }

    /// 外部(编辑器 Done)改了缩略图/尺寸后重排面板。
    func refreshLayout() {
        enforceResidentDataBudget()
        layoutPanel()
    }

    /// 不驱逐用户仍能看见的托盘项；只把旧项的完整编码 Data 异步溢写到临时目录。
    /// 后续保存、拖出、编辑时由 TrayShotItem 按需映射读取。
    private func enforceResidentDataBudget() {
        var projectedBytes = items.reduce(0) { $0 + $1.residentByteCount }
        guard projectedBytes > Self.maxResidentDataBytes else { return }
        for item in items.reversed() where projectedBytes > Self.maxResidentDataBytes {
            guard let request = item.beginSpill() else { continue }
            projectedBytes -= request.data.count
            // 强持有到写入回主线程收尾：用户若在写入中移除卡片，revision 门会
            // 删除迟到文件，避免临时目录遗留一份无人引用的大图。
            Task.detached(priority: .utility) { [item] in
                var succeeded = false
                do {
                    try FileManager.default.createDirectory(
                        at: request.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try request.data.write(to: request.url, options: .atomic)
                    succeeded = true
                } catch {
                    try? FileManager.default.removeItem(
                        at: request.url.deletingLastPathComponent())
                }
                await item.completeSpill(request, succeeded: succeeded)
            }
        }
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

    /// F22:编辑器打开期间暂停该项的自动收起——编辑中托盘项凭空消失会连
    /// 文档一起丢(spec S4「不保存仍可重开继续」的前提是项还在)。
    func pauseAutoDismiss(for id: UUID) {
        dismissWorkItems.removeValue(forKey: id)?.cancel()
    }

    /// 编辑器关窗后恢复计时(设置开着才会真排)。
    func resumeAutoDismiss(for id: UUID) {
        guard let item = item(id: id) else { return }
        scheduleAutoDismiss(for: item)
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
        let root = TrayRootView(tray: self, reduceEffects: settings.reduceEffects)
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
/// v2 堆叠交互(2026-07-17 用户拍板):鼠标进托盘 → 扇开(每张露出一条可指的边),
/// 悬停哪张哪张升到最上层 + 微放大——被压住的图也能点/拖/出动作;弹簧动画,
/// 减弱动态一律直切。
struct TrayRootView: View {
    @ObservedObject var tray: QuickAccessTray
    let reduceEffects: Bool

    private static let cardWidth: CGFloat = 192
    private static let cardHeight: CGFloat = 122
    /// 平时紧凑 / 悬停扇开 的错位间距(v2.1 用户反馈:平时也要看得出层数)。
    private static let idleOffset: CGFloat = 18
    private static let fanOffset: CGFloat = 34

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var motionReduced: Bool { reduceEffects || reduceMotion }
    private var spring: Animation? {
        motionReduced ? nil : .spring(response: 0.32, dampingFraction: 0.8)
    }

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
        let spacing = tray.panelHovered ? Self.fanOffset : Self.idleOffset
        // 高度按扇开状态预留(空白区不吃点击,SwiftUI 命中测试放行):
        // 窗口 frame 不用随悬停伸缩,动画只发生在内容层
        let reservedHeight = Self.cardHeight
            + CGFloat(max(0, QuickAccessTray.visibleStackCount - 1)) * Self.fanOffset
        return ZStack(alignment: .bottom) {
            ForEach(Array(visible.enumerated().reversed()), id: \.element.id) { index, item in
                let hovered = tray.hoveredCardID == item.id
                TrayCardView(item: item, tray: tray, interactive: true)
                    .scaleEffect(hovered ? 1.05
                                 : 1 - CGFloat(index) * (tray.panelHovered ? 0.015 : 0.03),
                                 anchor: .bottom)
                    .offset(y: -CGFloat(index) * spacing)
                    // 悬停升顶:默认新图在上(index 小 z 大),被指到的直接拔到 100
                    .zIndex(hovered ? 100 : Double(visible.count - index))
                    .transition(motionReduced
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .bottom)
                                        .combined(with: .scale(scale: 0.88, anchor: .bottom))
                                        .combined(with: .opacity),
                                    removal: .scale(scale: 0.85).combined(with: .opacity)))
            }
        }
        .frame(width: Self.cardWidth, height: reservedHeight, alignment: .bottom)
        .animation(spring, value: tray.panelHovered)
        .animation(spring, value: tray.hoveredCardID)
        .animation(spring, value: tray.items.map(\.id))
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
                LazyVStack(spacing: 8) {
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
    /// (四键 ✏️💾📌× = 24×4 + 6×3 间距 = 114,留余量取 128)
    static let actionsRect = CGRect(x: (192 - 128) / 2, y: 122 - 44, width: 128, height: 40)

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
                // 双层软投影(v2.2 用户反馈「阴影很硬」):贴地一层浅的 + 弥散一层大的
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
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
        .onHover { isHovering in
            hovering = isHovering
            // 升顶信号(v2):进 = 记我;出 = 只清自己(别把别张刚设的清掉)
            if isHovering {
                tray.hoveredCardID = item.id
            } else if tray.hoveredCardID == item.id {
                tray.hoveredCardID = nil
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                tray.onOpenItem?(item)
            } label: {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("tray.annotate", "标注"))

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
                tray.onPinItem?(item)
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("tray.pin", "钉在屏幕上"))

            Button {
                tray.remove(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("tray.remove", "移除(文件不动)"))
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
        view.onClick = { tray.onOpenItem?(item) } // 点卡片 = 打开编辑器(spec S3)
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
    /// 拖起时现算预览(编辑器 Drag Me 用:压平昂贵,拖之前不做)。
    var providePreview: (() -> NSImage?)?
    var onDragEnded: (Bool) -> Void = { _ in }
    /// 单击(未拖动)回调(托盘卡点击 = 打开编辑器,spec S3)。
    var onClick: (() -> Void)?
    /// 悬停中(动作按钮可见)才对按钮区放行点击。
    var actionsVisible = false
    /// 动作按钮区(SwiftUI 左上原点坐标;hitTest 内换算)。
    var actionsRectTopLeft: CGRect = .zero
    /// 编辑器 Drag Me:内容是被动展示,整块都归拖拽层(子 NSHostingView 不抢事件)。
    var interceptsAllHits = false

    private var mouseDownEvent: NSEvent?

    /// 按钮区放行:返回 nil 让事件落回 NSHostingView,由 SwiftUI Button 接住。
    /// 不放行的话 AppKit hitTest 会命中本视图,叠在上方的 SwiftUI 按钮永远点不到。
    override func hitTest(_ point: NSPoint) -> NSView? {
        if interceptsAllHits {
            let local = convert(point, from: superview)
            return bounds.contains(local) ? self : nil
        }
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
        // 预览兜底链:显式闭包 → 预置图 → 现读刚写的文件(编辑器 Drag Me 走这条)
        let preview = providePreview?() ?? dragPreview ?? NSImage(contentsOf: url)
        let frame = previewFrame(for: preview)
        draggingItem.setDraggingFrame(frame, contents: preview)
        beginDraggingSession(with: [draggingItem], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { onClick?() } // 单击(未升级为拖拽)
        mouseDownEvent = nil
    }

    private func previewFrame(for image: NSImage?) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return bounds }
        // 统一压到 ≤180pt(文件兜底预览是全尺寸图,不缩会拖出一张巨图)
        let maxSide: CGFloat = 180
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2,
                      y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
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
