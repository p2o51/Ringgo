import AppKit
import SwiftUI
import Combine
import ServiceManagement

/// F13 设置持久化(UserDefaults,键统一前缀 "c2s.")。
/// 登录项不进 UserDefaults:以 SMAppService 系统状态为真源,避免两处状态打架。
@MainActor
public final class SettingsStore: ObservableObject {

    public enum Appearance: String, CaseIterable, Identifiable {
        case system, dark, light
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .system: return L10n.t("appearance.system", "跟随系统")
            case .dark: return L10n.t("appearance.dark", "深色")
            case .light: return L10n.t("appearance.light", "浅色")
            }
        }
    }

    /// F20 截图落盘格式(窗口截图强制 PNG 留 alpha,此设置只管区域/全屏)。
    public enum ShotFormat: String, CaseIterable, Identifiable {
        case png, jpg
        public var id: String { rawValue }
        public var label: String { rawValue.uppercased() }
    }

    /// F21 托盘停靠角(spec §6:默认左下,可选右下)。
    public enum ShotTrayCorner: String, CaseIterable, Identifiable {
        case bottomLeft, bottomRight
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .bottomLeft: return L10n.t("settings.shot.tray_bottom_left", "左下角")
            case .bottomRight: return L10n.t("settings.shot.tray_bottom_right", "右下角")
            }
        }
    }

    private enum Keys {
        static let hotkeyKeyCode = "c2s.hotkeyKeyCode"
        static let hotkeyModifiers = "c2s.hotkeyModifiers"
        static let chargeEnabled = "c2s.chargeEnabled"
        static let doubleShiftEnabled = "c2s.doubleShiftEnabled"
        static let multitouchEnabled = "c2s.multitouchEnabled"
        static let appearance = "c2s.appearance"
        static let reduceEffects = "c2s.reduceEffects"
        static let translationTarget = "c2s.translationTarget"
        static let shotHotkeyKeyCode = "c2s.shotHotkeyKeyCode"
        static let shotHotkeyModifiers = "c2s.shotHotkeyModifiers"
        static let shotCopyToClipboard = "c2s.shotCopyToClipboard"
        static let shotAutoSave = "c2s.shotAutoSave"
        static let shotSaveDirectory = "c2s.shotSaveDirectory"
        static let shotFilenameTemplate = "c2s.shotFilenameTemplate"
        static let shotImageFormat = "c2s.shotImageFormat"
        static let shotWindowShadow = "c2s.shotWindowShadow"
        static let shotShutterSound = "c2s.shotShutterSound"
        static let shotTrayCorner = "c2s.shotTrayCorner"
        static let shotTrayAutoDismiss = "c2s.shotTrayAutoDismiss"
        static let shotTrayAutoDismissSeconds = "c2s.shotTrayAutoDismissSeconds"
    }

    @Published public var hotkeyKeyCode: UInt32 = 1 {        // kVK_ANSI_S
        didSet { persist(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode) }
    }
    @Published public var hotkeyModifiers: UInt32 = 768 {    // cmd | shift(Carbon)
        didSet { persist(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers) }
    }
    // 2026-07-03 默认改关:普通 ⌘⇧ 前缀快捷键按慢即误触发,opt-in 更合理
    @Published public var chargeEnabled: Bool = false {
        didSet { persist(chargeEnabled, forKey: Keys.chargeEnabled) }
    }
    @Published public var doubleShiftEnabled: Bool = false { // 默认关:开启才申请 AX 权限
        didSet { persist(doubleShiftEnabled, forKey: Keys.doubleShiftEnabled) }
    }
    /// Developer ID 直发版实验能力：私有 MultitouchSupport，全局三指双击。
    @Published public var multitouchEnabled: Bool = false {
        didSet { persist(multitouchEnabled, forKey: Keys.multitouchEnabled) }
    }
    @Published public var appearance: Appearance = .system {
        didSet {
            persist(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }
    @Published public var reduceEffects: Bool = false {
        didSet { persist(reduceEffects, forKey: Keys.reduceEffects) }
    }

    /// 翻译目标语言(BCP-47;空 = 跟随系统首选语言)。F10。
    @Published public var translationTargetCode: String = "" {
        didSet { persist(translationTargetCode, forKey: Keys.translationTarget) }
    }

    // MARK: - F20/F21 截图(spec §6)

    @Published public var shotHotkeyKeyCode: UInt32 = 7 {     // kVK_ANSI_X
        didSet { persist(Int(shotHotkeyKeyCode), forKey: Keys.shotHotkeyKeyCode) }
    }
    @Published public var shotHotkeyModifiers: UInt32 = 768 { // cmd | shift(Carbon)
        didSet { persist(Int(shotHotkeyModifiers), forKey: Keys.shotHotkeyModifiers) }
    }
    /// 拍后自动复制进剪贴板(PNG + TIFF 双 representation)。
    @Published public var shotCopyToClipboard: Bool = true {
        didSet { persist(shotCopyToClipboard, forKey: Keys.shotCopyToClipboard) }
    }
    /// 拍后自动按模板落盘。
    @Published public var shotAutoSave: Bool = true {
        didSet { persist(shotAutoSave, forKey: Keys.shotAutoSave) }
    }
    /// 落盘目录(空 = 默认 ~/Pictures/Ringgo,避开 Desktop 等 TCC 保护目录,spec §7)。
    @Published public var shotSaveDirectory: String = "" {
        didSet { persist(shotSaveDirectory, forKey: Keys.shotSaveDirectory) }
    }
    @Published public var shotFilenameTemplate: String = "Ringgo {date} at {time}" {
        didSet { persist(shotFilenameTemplate, forKey: Keys.shotFilenameTemplate) }
    }
    @Published public var shotImageFormat: ShotFormat = .png {
        didSet { persist(shotImageFormat.rawValue, forKey: Keys.shotImageFormat) }
    }
    /// 窗口截图合成投影(关 = 仍透明圆角,只去投影)。
    @Published public var shotWindowShadow: Bool = true {
        didSet { persist(shotWindowShadow, forKey: Keys.shotWindowShadow) }
    }
    @Published public var shotShutterSound: Bool = true {
        didSet { persist(shotShutterSound, forKey: Keys.shotShutterSound) }
    }
    @Published public var shotTrayCorner: ShotTrayCorner = .bottomLeft {
        didSet { persist(shotTrayCorner.rawValue, forKey: Keys.shotTrayCorner) }
    }
    /// 托盘自动收起(默认关;开 = N 秒无交互后托盘项消失,悬停暂停计时)。
    @Published public var shotTrayAutoDismiss: Bool = false {
        didSet { persist(shotTrayAutoDismiss, forKey: Keys.shotTrayAutoDismiss) }
    }
    @Published public var shotTrayAutoDismissSeconds: Int = 5 {
        didSet { persist(shotTrayAutoDismissSeconds, forKey: Keys.shotTrayAutoDismissSeconds) }
    }

    /// 落盘目录真源:设置为空时回落 ~/Pictures/Ringgo。
    public var shotSaveDirectoryURL: URL {
        if !shotSaveDirectory.isEmpty {
            return URL(fileURLWithPath: (shotSaveDirectory as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("Ringgo", isDirectory: true)
    }

    /// 登录时启动(SMAppService)。注册/注销失败会自动拨回开关,
    /// 并把原因写进 `launchAtLoginError` 供界面展示——绝不静默吞错。
    @Published public var launchAtLogin: Bool = false {
        didSet {
            guard !isLoading, !isRevertingLaunchAtLogin, launchAtLogin != oldValue else { return }
            applyLaunchAtLogin(enable: launchAtLogin, revertTo: oldValue)
        }
    }
    /// 登录项操作的用户可见提示(nil = 无异常)。
    @Published public var launchAtLoginError: String?

    private let defaults = UserDefaults.standard
    /// init 读取期间抑制 didSet 回写与登录项副作用。
    private var isLoading = true
    private var isRevertingLaunchAtLogin = false

    public init() {
        if defaults.object(forKey: Keys.hotkeyKeyCode) != nil {
            hotkeyKeyCode = UInt32(clamping: defaults.integer(forKey: Keys.hotkeyKeyCode))
        }
        if defaults.object(forKey: Keys.hotkeyModifiers) != nil {
            hotkeyModifiers = UInt32(clamping: defaults.integer(forKey: Keys.hotkeyModifiers))
        }
        if defaults.object(forKey: Keys.chargeEnabled) != nil {
            chargeEnabled = defaults.bool(forKey: Keys.chargeEnabled)
        }
        if defaults.object(forKey: Keys.doubleShiftEnabled) != nil {
            doubleShiftEnabled = defaults.bool(forKey: Keys.doubleShiftEnabled)
        }
        if defaults.object(forKey: Keys.multitouchEnabled) != nil {
            multitouchEnabled = defaults.bool(forKey: Keys.multitouchEnabled)
        }
        if let raw = defaults.string(forKey: Keys.appearance),
           let restored = Appearance(rawValue: raw) {
            appearance = restored
        }
        if defaults.object(forKey: Keys.reduceEffects) != nil {
            reduceEffects = defaults.bool(forKey: Keys.reduceEffects)
        }
        if let code = defaults.string(forKey: Keys.translationTarget) {
            translationTargetCode = code
        }
        if defaults.object(forKey: Keys.shotHotkeyKeyCode) != nil {
            shotHotkeyKeyCode = UInt32(clamping: defaults.integer(forKey: Keys.shotHotkeyKeyCode))
        }
        if defaults.object(forKey: Keys.shotHotkeyModifiers) != nil {
            shotHotkeyModifiers = UInt32(clamping: defaults.integer(forKey: Keys.shotHotkeyModifiers))
        }
        if defaults.object(forKey: Keys.shotCopyToClipboard) != nil {
            shotCopyToClipboard = defaults.bool(forKey: Keys.shotCopyToClipboard)
        }
        if defaults.object(forKey: Keys.shotAutoSave) != nil {
            shotAutoSave = defaults.bool(forKey: Keys.shotAutoSave)
        }
        if let dir = defaults.string(forKey: Keys.shotSaveDirectory) {
            shotSaveDirectory = dir
        }
        if let template = defaults.string(forKey: Keys.shotFilenameTemplate), !template.isEmpty {
            shotFilenameTemplate = template
        }
        if let raw = defaults.string(forKey: Keys.shotImageFormat),
           let restored = ShotFormat(rawValue: raw) {
            shotImageFormat = restored
        }
        if defaults.object(forKey: Keys.shotWindowShadow) != nil {
            shotWindowShadow = defaults.bool(forKey: Keys.shotWindowShadow)
        }
        if defaults.object(forKey: Keys.shotShutterSound) != nil {
            shotShutterSound = defaults.bool(forKey: Keys.shotShutterSound)
        }
        if let raw = defaults.string(forKey: Keys.shotTrayCorner),
           let restored = ShotTrayCorner(rawValue: raw) {
            shotTrayCorner = restored
        }
        if defaults.object(forKey: Keys.shotTrayAutoDismiss) != nil {
            shotTrayAutoDismiss = defaults.bool(forKey: Keys.shotTrayAutoDismiss)
        }
        if defaults.object(forKey: Keys.shotTrayAutoDismissSeconds) != nil {
            shotTrayAutoDismissSeconds = defaults.integer(forKey: Keys.shotTrayAutoDismissSeconds)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isLoading = false
        applyAppearance()
    }

    var triggerConfig: TriggerConfig {
        TriggerConfig(keyCode: hotkeyKeyCode,
                      carbonModifiers: hotkeyModifiers,
                      chargeEnabled: chargeEnabled,
                      chargeThresholdMs: 250,
                      doubleShiftEnabled: doubleShiftEnabled,
                      shotKeyCode: shotHotkeyKeyCode,
                      shotCarbonModifiers: shotHotkeyModifiers)
    }

    /// 跟随系统 = 置回 nil(还原系统外观)。
    public func applyAppearance() {
        switch appearance {
        case .system: NSApplication.shared.appearance = nil
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }
    }

    private func persist(_ value: Any, forKey key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    private func applyLaunchAtLogin(enable: Bool, revertTo previous: Bool) {
        launchAtLoginError = nil
        let service = SMAppService.mainApp
        do {
            if enable {
                guard service.status != .enabled else { return }
                try service.register()
                // 注册成功但被系统拦在「登录项」待批状态时,给出指引而不拨回。
                if service.status == .requiresApproval {
                    launchAtLoginError = L10n.t("settings.launch.requires_approval",
                                                "已申请，请在「系统设置 → 通用 → 登录项」中允许 Ringgo。")
                }
            } else {
                guard service.status == .enabled else { return }
                try service.unregister()
            }
        } catch {
            isRevertingLaunchAtLogin = true
            launchAtLogin = previous
            isRevertingLaunchAtLogin = false
            launchAtLoginError = enable
                ? L10n.f("settings.launch.enable_failed", "无法开启「登录时启动」:%@", error.localizedDescription)
                : L10n.f("settings.launch.disable_failed", "无法关闭「登录时启动」:%@", error.localizedDescription)
        }
    }
}
