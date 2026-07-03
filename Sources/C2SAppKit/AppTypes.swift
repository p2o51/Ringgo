import CoreGraphics
import Foundation
import C2SCore

/// 触发事件(HotkeyManager → AppCoordinator)。
public enum TriggerEvent: Sendable, Equatable {
    case hotkey
    case menuBar
    case doubleShift
    /// 按住 ⌘⇧ 开始蓄力(coordinator 借这 ~250ms 并行预抓屏,松手即冻结零空窗)。
    case chargeBegan
    case chargeFired
    case chargeCancelled
}

/// 触发配置(SettingsStore → HotkeyManager)。
public struct TriggerConfig: Equatable, Sendable {
    /// Carbon 虚拟键码(默认 1 = kVK_ANSI_S)。
    public var keyCode: UInt32
    /// Carbon 修饰键(默认 768 = cmdKey(256) | shiftKey(512))。
    public var carbonModifiers: UInt32
    public var chargeEnabled: Bool
    public var chargeThresholdMs: Int
    /// 双击 Shift:默认关(需要辅助功能权限,开启才申请)。
    public var doubleShiftEnabled: Bool

    public init(keyCode: UInt32 = 1,
                carbonModifiers: UInt32 = 768,
                chargeEnabled: Bool = false,
                chargeThresholdMs: Int = 250,
                doubleShiftEnabled: Bool = false) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.chargeEnabled = chargeEnabled
        self.chargeThresholdMs = chargeThresholdMs
        self.doubleShiftEnabled = doubleShiftEnabled
    }
}

/// 一次抓屏结果:静帧 + 唯一坐标真源(P0)。
public struct CaptureResult: @unchecked Sendable {
    public let image: CGImage
    public let context: DisplayContext
    public init(image: CGImage, context: DisplayContext) {
        self.image = image
        self.context = context
    }
}

/// Lens 图搜的「面板内表单上传」载荷。
///
/// 为什么不是 URL:实测(2026-07-02)Lens 结果页与**上传会话绑定**
/// (跨会话打开显示 "Image not found … not associated with your account"),
/// 且风控网络下匿名客户端一律 403。所以上传必须发生在展示它的同一个
/// WKWebView 会话里 —— 用自动提交的 multipart 表单做顶层 POST 导航(免 CORS),
/// WebView 跟随 303 直接落在结果页。
public struct LensUploadPayload {
    /// 自动提交的上传表单(内嵌 base64 图片)。
    public let html: String
    /// loadHTMLString 的 baseURL(决定 Referer/Origin 语义)。
    public let baseURL: URL
    /// 重试计数:变化时 WebView 重新提交同一张图。
    public let attempt: Int

    public init(html: String, baseURL: URL, attempt: Int) {
        self.html = html
        self.baseURL = baseURL
        self.attempt = attempt
    }
}

/// prompt 包装型查询的模式(F10 选区翻译 / F15 可视化与图片编辑):
/// 真实查询 = prompt 包装 + Google AI Mode,药丸显示用户可编辑的原文/指令,
/// 提交时由 coordinator 按模式重新包装;新普通搜索一律退出模式。
public enum QueryPromptMode: Equatable, Sendable {
    case translate
    case visualize
    case editImage
}

/// 结果面板药丸里的模式 chip(nil = 普通搜索,无 chip)。
public struct QueryModeChip: Equatable, Sendable {
    public let mode: QueryPromptMode
    /// SF Symbol 名。
    public let icon: String
    public let label: String

    public init(mode: QueryPromptMode, icon: String, label: String) {
        self.mode = mode
        self.icon = icon
        self.label = label
    }
}

/// 底部结果面板内容状态(ui-style §4.6)。
public enum ResultContent {
    case hidden
    /// 骨架 +(可选)乐观预填的 query。
    case loading(query: String?)
    case web(URL)
    /// Lens 图搜:面板 WebView 内表单上传(见 LensUploadPayload 注释)。
    case lensUpload(LensUploadPayload)
    /// 原生错误卡;绝不把错误串当搜索词(features §8)。
    /// login:被 Google 风控(403)时的恢复动作 —— 在面板里登录 Google 一次。
    case error(message: String, retry: (() -> Void)?, login: (() -> Void)?)
}
