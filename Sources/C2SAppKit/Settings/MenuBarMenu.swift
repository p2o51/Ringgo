import SwiftUI
import AppKit

/// 菜单栏菜单(ui-style §4.7):立即圈选 / 权限警示 / 设置… / 退出。
public struct MenuBarMenu: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var welcome: WelcomeWindowController
    @EnvironmentObject var settingsWindow: SettingsWindowController

    public init() {}

    public var body: some View {
        // 快捷键仅作菜单展示;真实全局热键由 HotkeyManager(Carbon)注册
        Button(L10n.t("menu.capture_now", "立即圈选")) { coordinator.captureNow() }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            // 菜单一打开就预热抓屏管线(features §F1 hover 预热)
            .onAppear { coordinator.prewarmCapture() }

        Divider()

        if !coordinator.capture.hasScreenRecordingPermission {
            Button {
                welcome.show(step: .setup)
            } label: {
                Label(L10n.t("menu.needs_screen_permission", "需要屏幕录制权限…"),
                      systemImage: "exclamationmark.triangle")
            }
        }

        Button(L10n.t("menu.settings", "设置…")) { settingsWindow.show() }
        Button(L10n.t("menu.welcome_guide", "欢迎引导…")) { welcome.show() }

        Divider()

        Button(L10n.t("menu.quit", "退出 Ringgo")) { NSApplication.shared.terminate(nil) }
    }
}
