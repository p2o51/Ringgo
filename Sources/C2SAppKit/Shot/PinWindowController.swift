import AppKit
import SwiftUI
import C2SCore

/// F23 钉图(spec S6):无边框置顶浮窗显示压平图。
/// 初始位置 = 原截取区域屏幕原位(可知时),否则鼠标屏中心;
/// 初始尺寸 = 原尺寸但 ≤ 所在屏 50%;边角拖拽等比缩放 10%–200%;
/// 整窗可拖;双击 = 回编辑器;hover × 关闭;右键 = 标注/拷贝/保存/关闭。
@MainActor
final class PinManager {

    private let settings: SettingsStore
    private var pins: [UUID: PinWindowController] = [:]
    /// 双击/右键「标注」→ 打开编辑器(coordinator 注入;item 已不在时无操作)。
    var onAnnotate: ((TrayShotItem) -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// 托盘 📌:钉当前交付版(item.data)。
    func pin(item: TrayShotItem) {
        guard let image = AnnotationEditorManager.decodeImage(item.data) else { return }
        pin(image: image, pointSize: item.pointSize, origin: item.originGlobal, item: item)
    }

    /// 编辑器 📌:钉当前画布(含未 Done 的标注)。
    func pin(image: CGImage, pointSize: CGSize, origin: CGRect?, item: TrayShotItem?) {
        let id = UUID()
        let controller = PinWindowController(
            image: image,
            pointSize: pointSize,
            origin: origin,
            onClose: { [weak self] in
                // 延后一拍拆窗:回调发自钉图自己的 SwiftUI 栈,同步释放
                // hostingView 是已知的 AttributeGraph use-after-free 模式(审查)
                guard let controller = self?.pins.removeValue(forKey: id) else { return }
                DispatchQueue.main.async { controller.tearDown() }
            },
            onAnnotate: item.map { trayItem in
                { [weak self] in self?.onAnnotate?(trayItem) }
            },
            onCopy: { [weak self] in self?.copy(image: image, pointSize: pointSize) },
            onSave: { [weak self] in self?.save(image: image, pointSize: pointSize) })
        pins[id] = controller
        controller.show()
    }

    private func copy(image: CGImage, pointSize: CGSize) {
        Task.detached(priority: .userInitiated) {
            let png = ShotImageEncoder.pngData(image, pointSize: pointSize)
            let tiff = ShotImageEncoder.tiffData(image, pointSize: pointSize)
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.declareTypes([.png, .tiff], owner: nil)
                if let png { pasteboard.setData(png, forType: .png) }
                if let tiff { pasteboard.setData(tiff, forType: .tiff) }
                Haptics.confirm()
            }
        }
    }

    private func save(image: CGImage, pointSize: CGSize) {
        let directory = settings.shotSaveDirectoryURL
        let template = settings.shotFilenameTemplate
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let data = ShotImageEncoder.pngData(image, pointSize: pointSize) else { return }
            do {
                let url = try ShotPipeline.writeData(data, ext: "png", directory: directory,
                                                     template: template)
                await self?.finishSave(url: url)
            } catch {
                await self?.failSave(error, directory: directory)
            }
        }
    }

    private func finishSave(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func failSave(_ error: Error, directory: URL) {
        ShotPipeline.presentSaveError(error, directory: directory)
    }
}

// MARK: - 单枚钉图窗

@MainActor
final class PinWindowController {

    /// borderless 默认拿不到键盘/按钮焦点,与 OverlayWindow 同款重写。
    /// 拖动/双击在 AppKit 层处理:SwiftUI 手势会让 NSHostingView 把
    /// mouseDownCanMoveWindow 置 false,isMovableByWindowBackground 名存实亡(审查)。
    private final class PinWindow: NSWindow {
        var onDoubleClick: (() -> Void)?

        override var canBecomeKey: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
                return
            }
            performDrag(with: event) // 整窗可拖(spec S6)
        }
    }

    private let window: PinWindow
    private let onClose: () -> Void

    init(image: CGImage, pointSize: CGSize, origin: CGRect?,
         onClose: @escaping () -> Void,
         onAnnotate: (() -> Void)?,
         onCopy: @escaping () -> Void,
         onSave: @escaping () -> Void) {
        self.onClose = onClose

        // 兜底屏 = 鼠标所在屏(spec S6),不是键窗屏
        let mouseLocation = NSEvent.mouseLocation
        let fallbackScreen = NSScreen.screens
            .first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        let screen = NSScreen.screens.first(where: { origin.map($0.frame.intersects) ?? false })
            ?? fallbackScreen
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        // 初始尺寸 = 原尺寸,超过所在屏 50% 等比缩小(spec S6)。
        // 上限/下限都是**单一缩放因子**:两轴独立取 max 会把细长截图拉变形,
        // 还与 window.aspectRatio 打架(审查)。
        let ps = CGSize(width: max(pointSize.width, 1), height: max(pointSize.height, 1))
        let capScale = min(1, visible.width * 0.5 / ps.width, visible.height * 0.5 / ps.height)
        let floorScale = min(1, max(60 / ps.width, 45 / ps.height))
        let scale = max(capScale, floorScale)
        let size = CGSize(width: ps.width * scale, height: ps.height * scale)

        // 初始位置 = 原位(保视觉左上角;缩过则对齐原区域左上),否则鼠标屏中心;
        // 原位所在显示器已断开/坐标失效 → 同样回落中心(离屏的钉图关都关不掉,审查)
        var frame: CGRect
        if let origin {
            frame = CGRect(x: origin.minX, y: origin.maxY - size.height,
                           width: size.width, height: size.height)
        } else {
            frame = .zero
        }
        if origin == nil || !NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            frame = CGRect(x: visible.midX - size.width / 2,
                           y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        }

        let w = PinWindow(contentRect: frame,
                          styleMask: [.borderless, .resizable],
                          backing: .buffered, defer: false)
        w.level = .floating
        w.collectionBehavior = [.fullScreenAuxiliary]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = false // 拖动/双击统一在 PinWindow.mouseDown
        w.isReleasedWhenClosed = false
        // 等比缩放 10%–200%(spec S6):锁纵横比 + 上下限(下限同为单一因子,保比例)
        w.aspectRatio = ps
        let minScale = min(1, max(0.1, 40 / ps.width, 30 / ps.height))
        w.contentMinSize = CGSize(width: ps.width * minScale, height: ps.height * minScale)
        w.contentMaxSize = CGSize(width: ps.width * 2, height: ps.height * 2)
        window = w
        w.onDoubleClick = onAnnotate.map { annotate in
            { [weak self] in
                annotate()
                self?.requestClose() // 回编辑器 = 钉图使命结束(spec S6)
            }
        }

        let view = PinView(image: image,
                           onClose: { [weak self] in self?.requestClose() },
                           onAnnotate: onAnnotate.map { annotate in
                               { [weak self] in
                                   annotate()
                                   self?.requestClose() // 右键「标注」同双击语义
                               }
                           },
                           onCopy: onCopy,
                           onSave: onSave)
        w.contentView = NSHostingView(rootView: view)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    private func requestClose() {
        onClose() // manager 移除引用后 tearDown 收窗
    }

    func tearDown() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

// MARK: - 内容视图

private struct PinView: View {
    let image: CGImage
    let onClose: () -> Void
    var onAnnotate: (() -> Void)?
    let onCopy: () -> Void
    let onSave: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help(L10n.t("pin.close", "关闭钉图"))
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            // 双击不走 SwiftUI 手势:会把整图区域标记为交互内容,拖动就死了;
            // 双击/拖动统一由 PinWindow.mouseDown 处理(审查)
            .contextMenu {
                if let onAnnotate {
                    Button(L10n.t("pin.annotate", "标注…")) { onAnnotate() }
                }
                Button(L10n.t("pin.copy", "拷贝")) { onCopy() }
                Button(L10n.t("pin.save", "保存文件")) { onSave() }
                Divider()
                Button(L10n.t("pin.close", "关闭钉图")) { onClose() }
            }
    }
}
