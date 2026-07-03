import SwiftUI
import AppKit
import Combine
import ApplicationServices

/// F13 设置窗口(ui-style §4.7):通用/外观/搜索/权限/关于。
/// 注意:Settings 场景的环境对象由 @main 注入(原项目漏注入 → 一开就崩)。
public struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var coordinator: AppCoordinator

    public init() {}

    public var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AppearanceTab()
                .tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            SearchTab()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            PermissionsTab()
                .tabItem { Label("权限", systemImage: "lock.shield") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - 通用

@MainActor
private struct GeneralTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("触发") {
                HotkeyRecorderRow()
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("蓄力唤起", isOn: $settings.chargeEnabled)
                    Text("按住 ⌘⇧ 约 250 毫秒唤起;阈值前松开即取消。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("双击 Shift 唤起", isOn: $settings.doubleShiftEnabled)
                    Text("可选能力,需要辅助功能权限;开启时才会向系统申请。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("启动") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("登录时启动", isOn: $settings.launchAtLogin)
                    if let hint = settings.launchAtLoginError {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.doubleShiftEnabled) { _, isOn in
            if isOn { requestAccessibilityPrompt() }
        }
    }

    /// 双击 Shift 是唯一需要 AX 权限的可选能力(features §F1),开启时才申请。
    private func requestAccessibilityPrompt() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}

/// 热键录制:点「录制」进入监听态,local monitor 抓下一次 keyDown 写回 store;Esc 取消。
@MainActor
private struct HotkeyRecorderRow: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent("圈选热键") {
                HStack(spacing: 8) {
                    Text(isRecording
                         ? "按下新组合…"
                         : HotkeySymbols.string(keyCode: settings.hotkeyKeyCode,
                                                carbonModifiers: settings.hotkeyModifiers))
                        .foregroundStyle(isRecording ? .secondary : .primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button(isRecording ? "取消" : "录制") {
                        if isRecording { stopRecording() } else { startRecording() }
                    }
                }
            }
            if isRecording {
                Text("需包含至少一个修饰键(⌘⌥⌃⇧);按 Esc 取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopRecording() } // monitor 必须移除,防泄漏
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handleRecorded(event) }
            return nil // 录制期间吞掉按键,避免误触其他快捷键
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handleRecorded(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc
            stopRecording()
            return
        }
        let carbon = HotkeySymbols.carbonModifiers(from: event.modifierFlags)
        guard carbon != 0 else { return } // 无修饰键不收,继续监听
        settings.hotkeyKeyCode = UInt32(event.keyCode)
        settings.hotkeyModifiers = carbon
        stopRecording()
    }
}

/// NSEvent 修饰键 → Carbon 位,以及组合展示(如 ⌘⇧S)。
private enum HotkeySymbols {
    // Carbon 修饰键位:cmd=256、shift=512、option=2048、control=4096
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= 256 }
        if flags.contains(.shift) { bits |= 512 }
        if flags.contains(.option) { bits |= 2048 }
        if flags.contains(.control) { bits |= 4096 }
        return bits
    }

    static func string(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var s = ""
        if carbonModifiers & 4096 != 0 { s += "⌃" }
        if carbonModifiers & 2048 != 0 { s += "⌥" }
        if carbonModifiers & 512 != 0 { s += "⇧" }
        if carbonModifiers & 256 != 0 { s += "⌘" }
        return s + keyName(keyCode)
    }

    // ANSI(美式)布局近似表;查不到的键码退化为 "键N"。
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 76: "⌤",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]

    static func keyName(_ code: UInt32) -> String {
        names[code] ?? "键\(code)"
    }
}

// MARK: - 外观

@MainActor
private struct AppearanceTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                // 选中即由 SettingsStore.didSet 设 NSApp.appearance 并持久化
                Picker("外观", selection: $settings.appearance) {
                    ForEach(SettingsStore.Appearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("减弱动态效果", isOn: $settings.reduceEffects)
                    Text("关闭微光游走、涟漪等装饰性动画,面板改用淡入淡出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 搜索

@MainActor
private struct SearchTab: View {
    var body: some View {
        Form {
            Section("搜索引擎") {
                // 目前仅支持 Google,占位禁用
                Picker("默认引擎", selection: .constant("google")) {
                    Text("Google").tag("google")
                }
                .disabled(true)
            }
            Section("识别语言") {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("OCR 语言", value: "自动检测")
                    Text("由 Apple Vision 端上识别,自动检测语言,支持中、英、日、韩等。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 权限

@MainActor
private struct PermissionsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var screenGranted = false
    @State private var axTrusted = false

    var body: some View {
        Form {
            Section("屏幕录制") {
                LabeledContent("状态") { PermissionStatusText(granted: screenGranted) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("圈选需要屏幕录制权限来截取当前屏幕。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("打开系统设置") {
                        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    }
                }
            }
            if settings.doubleShiftEnabled {
                Section("辅助功能") {
                    LabeledContent("状态") { PermissionStatusText(granted: axTrusted) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("仅「双击 Shift 唤起」这项可选能力需要辅助功能权限;主热键与蓄力唤起不需要。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开系统设置") {
                            openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        // 从系统设置授权后切回来时刷新状态
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        screenGranted = coordinator.capture.hasScreenRecordingPermission
        axTrusted = AXIsProcessTrusted()
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionStatusText: View {
    let granted: Bool

    var body: some View {
        Text(granted ? "● 已授权" : "○ 未授权")
            .foregroundStyle(granted ? Color.green : Color.secondary)
    }
}

// MARK: - 关于

private struct AboutTab: View {
    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "开发构建"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("C2S")
                .font(.title2.weight(.semibold))
            Text("版本 \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("净室自研,零第三方依赖。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
