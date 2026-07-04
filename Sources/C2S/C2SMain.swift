import SwiftUI
import C2SAppKit

@main
struct C2SApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 设置窗口不用 Settings 场景:macOS 26 上 accessory 应用的
        // SettingsLink/openSettings 会静默失败,由 SettingsWindowController 显式持有。
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appDelegate.coordinator)
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.welcome)
                .environmentObject(appDelegate.settingsWindow)
        } label: {
            Image(nsImage: C2SMenuBarIcon.image)
        }
    }
}
