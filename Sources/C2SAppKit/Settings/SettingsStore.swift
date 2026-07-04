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
            case .system: return "跟随系统"
            case .dark: return "深色"
            case .light: return "浅色"
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isLoading = false
        applyAppearance()
    }

    var triggerConfig: TriggerConfig {
        TriggerConfig(keyCode: hotkeyKeyCode,
                      carbonModifiers: hotkeyModifiers,
                      chargeEnabled: chargeEnabled,
                      chargeThresholdMs: 250,
                      doubleShiftEnabled: doubleShiftEnabled)
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
                    launchAtLoginError = "已申请，请在「系统设置 → 通用 → 登录项」中允许 Ringgo。"
                }
            } else {
                guard service.status == .enabled else { return }
                try service.unregister()
            }
        } catch {
            isRevertingLaunchAtLogin = true
            launchAtLogin = previous
            isRevertingLaunchAtLogin = false
            launchAtLoginError = (enable ? "无法开启「登录时启动」:" : "无法关闭「登录时启动」:")
                + error.localizedDescription
        }
    }
}
