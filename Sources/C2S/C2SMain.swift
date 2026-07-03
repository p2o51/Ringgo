import SwiftUI
import C2SAppKit

@main
struct C2SApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appDelegate.coordinator)
                .environmentObject(appDelegate.settings)
        } label: {
            Image(systemName: "circle.dashed")
        }

        // Settings 场景必须注入所需环境对象(原项目漏了 → 一开设置就崩)
        Settings {
            SettingsView()
                .environmentObject(appDelegate.coordinator)
                .environmentObject(appDelegate.settings)
        }
    }
}
