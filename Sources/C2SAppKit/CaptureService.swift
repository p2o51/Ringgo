import AppKit
import CoreVideo
@preconcurrency import ScreenCaptureKit
import C2SCore

/// F2 抓屏 + 冻结(机制 §2/§5):SCShareableContent 预热缓存 → 鼠标所在屏 →
/// SCScreenshotManager 单帧 → DisplayContext(废弃写死 ×2 与 displays.first)。
///
/// 整类 @MainActor:调用方(AppCoordinator)全在主线程,缓存读写天然串行;
/// 内容拉取与截屏均为 async,await 期间不阻塞主线程。
@MainActor
public final class CaptureService {

    public enum CaptureError: Error, LocalizedError {
        case noPermission
        case noDisplay
        case captureFailed(underlying: Error?)

        // nonisolated:错误可能在任意上下文被读取,不随外层类挂到 MainActor
        public nonisolated var errorDescription: String? {
            switch self {
            case .noPermission: return "没有屏幕录制权限。"
            case .noDisplay: return "找不到可用的显示器。"
            case .captureFailed(let e): return "截屏失败。" + (e.map { " (\($0.localizedDescription))" } ?? "")
            }
        }
    }

    public init() {}

    deinit {
        if let observer = screenParamsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 缓存的屏幕录制权限状态(启动查一次 + prewarm 刷新,权限检查移出热路径)。
    public private(set) var hasScreenRecordingPermission = false

    // MARK: - SCShareableContent 缓存

    private var cachedContent: SCShareableContent?
    private var pendingFetch: Task<SCShareableContent, Error>?
    /// 拉取代号:失效后使在途结果作废,防旧内容覆盖新缓存。
    private var fetchGeneration = 0
    private var screenParamsObserver: NSObjectProtocol?

    /// 启动/屏幕参数变化时调用:preflight 权限 + 缓存 SCShareableContent。
    /// 未授权时不得触发系统弹窗(只 preflight,真正申请留到首次抓屏)。
    public func prewarm() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        installScreenParamsObserverIfNeeded()
        // 未授权绝不碰 SCShareableContent(会触发 TCC 弹窗)
        guard hasScreenRecordingPermission else { return }
        if cachedContent == nil, pendingFetch == nil {
            refreshShareableContent()
        }
    }

    /// 抓「鼠标所在屏」单帧(无录屏红点),构建 DisplayContext。
    public func captureScreenUnderMouse() async throws -> CaptureResult {
        // 权限:preflight 失败才申请(仅此处允许系统弹窗),再失败即类型化报错
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            guard CGPreflightScreenCaptureAccess() else {
                hasScreenRecordingPermission = false
                throw CaptureError.noPermission
            }
        }
        hasScreenRecordingPermission = true

        // 鼠标所在屏(绝不用 displays.first)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else {
            throw CaptureError.noDisplay
        }
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.noDisplay
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)

        // SCDisplay:优先用缓存;缓存没有(可能过期)则失效后现拉一次再试
        var content = try await shareableContent()
        var matched = content.displays.first { $0.displayID == displayID }
        if matched == nil {
            invalidateCache()
            content = try await shareableContent()
            matched = content.displays.first { $0.displayID == displayID }
        }
        guard let display = matched else { throw CaptureError.noDisplay }

        // 尺寸 = 点 × 该屏真实 backingScaleFactor(坐标 P0:严禁写死 ×2)
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * scale)
        config.height = Int(screen.frame.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed(underlying: error)
        }

        // 坐标真源:pixelSize 用实际 CGImage 尺寸(不用 config 的期望值)
        let context = DisplayContext(displayID: displayID,
                                     screenFrame: screen.frame,
                                     pointSize: screen.frame.size,
                                     pixelSize: CGSize(width: image.width, height: image.height),
                                     scale: scale)
        return CaptureResult(image: image, context: context)
    }

    // MARK: - 缓存维护

    private func installScreenParamsObserverIfNeeded() {
        guard screenParamsObserver == nil else { return }
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screenParametersDidChange() }
        }
    }

    private func screenParametersDidChange() {
        invalidateCache()
        // 未授权保持沉默(不触发 TCC),留到首次抓屏再申请
        guard hasScreenRecordingPermission else { return }
        refreshShareableContent()
    }

    private func invalidateCache() {
        fetchGeneration += 1
        cachedContent = nil
        pendingFetch = nil
    }

    /// 后台拉一次 SCShareableContent 并缓存(只在已授权时调用)。
    private func refreshShareableContent() {
        fetchGeneration += 1
        let generation = fetchGeneration
        cachedContent = nil
        let task = Task {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        pendingFetch = task
        Task { [weak self] in
            let content = try? await task.value
            guard let self, self.fetchGeneration == generation else { return }
            self.pendingFetch = nil
            // 失败则留空,下次抓屏走现拉并带类型化错误
            self.cachedContent = content
        }
    }

    /// 取共享内容:缓存 → 在途拉取 → 现拉;拉取失败映射 captureFailed。
    private func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent { return cached }
        let generation = fetchGeneration
        if let pending = pendingFetch, let content = try? await pending.value {
            if fetchGeneration == generation { cachedContent = content }
            return content
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if fetchGeneration == generation { cachedContent = content }
            return content
        } catch {
            throw CaptureError.captureFailed(underlying: error)
        }
    }
}
