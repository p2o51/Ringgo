import SwiftUI
import AppKit

/// 菜单栏菜单(ui-style §4.7):立即圈选 / 权限警示 / 设置… / 退出。
public struct MenuBarMenu: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var settings: SettingsStore

    public init() {}

    public var body: some View {
        // 快捷键仅作菜单展示;真实全局热键由 HotkeyManager(Carbon)注册
        Button("立即圈选") { coordinator.captureNow() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            // 菜单一打开就预热抓屏管线(features §F1 hover 预热)
            .onAppear { coordinator.prewarmCapture() }

        Divider()

        if !coordinator.capture.hasScreenRecordingPermission {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("需要屏幕录制权限…", systemImage: "exclamationmark.triangle")
            }
        }

        SettingsLink { Text("设置…") }

        Divider()

        Button("退出 C2S") { NSApplication.shared.terminate(nil) }
    }
}
