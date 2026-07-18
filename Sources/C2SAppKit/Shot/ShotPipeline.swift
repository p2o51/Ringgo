import AppKit
import C2SCore

/// F20 产物管线(spec S2):快门 → 快门声 → 编码(后台,5K PNG 数百 ms 不占主线程)
/// → 剪贴板(PNG+TIFF)→ 命名模板落盘 → 托盘投递。落盘失败原生报错但产物保留
/// 在剪贴板与托盘,不丢图。
///
/// 内存纪律:托盘项只拿「已编码 Data + 降采样缩略图」,**绝不持有原始 CGImage**
/// ——区域裁剪(CGImage.cropping)共享整张 5K 冻结帧的后备存储,拿住它 = 每个
/// 托盘项钉 ~50MB(参照 OverlayWindowController.releaseContentAfterDismiss 的先例)。
@MainActor
public final class ShotPipeline {

    public struct Product {
        let image: CGImage
        /// 点尺寸(保留 Retina 密度:DPI 元数据与托盘显示用)。
        let pointSize: CGSize
        /// 窗口截图强制 PNG(透明 alpha,阴影开关只控投影,spec §6)。
        let forcePNG: Bool
        /// 截取区域的 AppKit 全局原位(F23 钉图「原位」;nil = 不可知)。
        let originGlobal: CGRect?

        init(image: CGImage, pointSize: CGSize, forcePNG: Bool, originGlobal: CGRect? = nil) {
            self.image = image
            self.pointSize = pointSize
            self.forcePNG = forcePNG
            self.originGlobal = originGlobal
        }
    }

    private let settings: SettingsStore
    private let tray: QuickAccessTray

    /// 自带音效(系统截图音无公共 API,spec S2);缺资源时静默降级。
    private lazy var shutterSound: NSSound? = {
        guard let url = C2SResourceBundle.shared.url(forResource: "shutter", withExtension: "aiff")
        else { return nil }
        return NSSound(contentsOf: url, byReference: true)
    }()

    init(settings: SettingsStore, tray: QuickAccessTray) {
        self.settings = settings
        self.tray = tray
    }

    /// 交付一件产物:`screenFrame` = 快门所在屏(托盘停靠该屏,spec §10)。
    /// 快门声立即响(与闪白同拍);编码在后台跑完再回主线程写剪贴板/落盘/进托盘。
    func deliver(_ product: Product, on screenFrame: CGRect) {
        if settings.shotShutterSound {
            shutterSound?.stop() // 连拍时重头播
            shutterSound?.play()
        }

        let usePNG = product.forcePNG || settings.shotImageFormat == .png
        let copyEnabled = settings.shotCopyToClipboard
        let saveEnabled = settings.shotAutoSave
        let image = product.image
        let pointSize = product.pointSize
        let originGlobal = product.originGlobal
        let saveDirectory = settings.shotSaveDirectoryURL
        let filenameTemplate = settings.shotFilenameTemplate

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return } // @MainActor 类隐式 Sendable,绑成 let 消除并发捕获警告
            // 降采样也会在 5K 首次读取时占一帧以上；与编码一并移出 MainActor。
            let thumbnail = LensService.downscaled(image, maxDimension: 480) ?? image
            let pngData = (copyEnabled || usePNG)
                ? ShotImageEncoder.pngData(image, pointSize: pointSize) : nil
            let tiffData = copyEnabled
                ? ShotImageEncoder.tiffData(image, pointSize: pointSize) : nil
            let deliveryData = usePNG
                ? pngData : ShotImageEncoder.jpegData(image, pointSize: pointSize)
            var fileURL: URL?
            var saveError: Error?
            if saveEnabled, let deliveryData {
                do {
                    fileURL = try Self.writeData(deliveryData, ext: usePNG ? "png" : "jpg",
                                                 directory: saveDirectory,
                                                 template: filenameTemplate)
                } catch {
                    saveError = error
                }
            }
            // 冻结可变局部量再跨 actor，兼容 Swift 6 的并发捕获规则。
            let completedFileURL = fileURL
            let completedSaveError = saveError
            await self.finishDelivery(deliveryData: deliveryData, pngData: pngData,
                                      tiffData: tiffData, thumbnail: thumbnail,
                                      pointSize: pointSize, usePNG: usePNG,
                                      copyEnabled: copyEnabled, fileURL: completedFileURL,
                                      saveError: completedSaveError,
                                      saveDirectory: saveDirectory,
                                      originGlobal: originGlobal,
                                      screenFrame: screenFrame)
        }
    }

    private func finishDelivery(deliveryData: Data?, pngData: Data?, tiffData: Data?,
                                thumbnail: CGImage, pointSize: CGSize, usePNG: Bool,
                                copyEnabled: Bool, fileURL: URL?, saveError: Error?,
                                saveDirectory: URL,
                                originGlobal: CGRect?, screenFrame: CGRect) {
        if copyEnabled {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            if let pngData { pasteboard.setData(pngData, forType: .png) }
            if let tiffData { pasteboard.setData(tiffData, forType: .tiff) }
        }

        guard let deliveryData else {
            // 编码失败(极罕见):剪贴板可能已有 PNG/TIFF,如实报错、不进托盘
            Self.presentSaveError(ShotDeliveryError.encodingFailed, directory: saveDirectory)
            return
        }

        let ext = usePNG ? "png" : "jpg"
        if let saveError {
            Self.presentSaveError(saveError, directory: saveDirectory)
        }

        tray.add(TrayShotItem(thumbnail: thumbnail, pointSize: pointSize,
                              data: deliveryData, ext: ext, fileURL: fileURL,
                              originGlobal: originGlobal),
                 on: screenFrame)
    }

    enum ShotDeliveryError: LocalizedError {
        case encodingFailed
        var errorDescription: String? {
            L10n.t("error.shot_encode_failed", "图像编码失败。")
        }
    }

    /// 命名模板落盘(托盘 💾/拖出共用):建目录 → 展开模板 → 冲突加序号 → 原子写。
    nonisolated static func writeData(_ data: Data, ext: String,
                                      directory: URL, template: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = FilenameTemplate.expand(template, date: Date())
        let name = FilenameTemplate.resolveCollision(base: base, ext: ext) { candidate in
            fm.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 目录不可写/磁盘满 → 原生提示;产物仍在剪贴板与托盘(spec §10 不丢图)。
    /// 托盘 💾 的失败也走这里——绝不静默吞错(仓库纪律)。
    static func presentSaveError(_ error: Error, directory: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.shot_save_failed_title", "截图没能保存")
        alert.informativeText = L10n.f("alert.shot_save_failed_body",
                                       "写入 %1$@ 失败:%2$@\n图还在剪贴板和托盘里。",
                                       directory.path, error.localizedDescription)
        alert.alertStyle = .warning
        // F24 📸 覆盖层不退:报错窗必须压在覆盖层(.screenSaver)与托盘(+1)之上,
        // 否则模态循环藏在冻结帧背后,整机表现为假死(点不动、Esc 到不了 key monitor)
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        alert.runModal()
    }
}
