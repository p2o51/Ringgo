import AppKit
import SwiftUI

/// App 生命周期:菜单栏代理(.accessory + Info.plist LSUIElement)。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    public let settings = SettingsStore()
    public private(set) lazy var coordinator = AppCoordinator(settings: settings)
    public private(set) lazy var welcome =
        WelcomeWindowController(settings: settings, coordinator: coordinator)
    public private(set) lazy var settingsWindow =
        SettingsWindowController(settings: settings, coordinator: coordinator, welcome: welcome)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
        // 等菜单栏场景完成挂载后再抢前台，避免首次启动窗口一闪即失焦。
        DispatchQueue.main.async { [weak self] in
            self?.welcome.showForFirstLaunchIfNeeded()
        }
    }

    /// 用户在 Finder/Launchpad 再次打开 app(菜单栏图标不显眼时的自救路径):
    /// 没有可见窗口就弹欢迎引导或设置,而不是看起来毫无反应。
    public func applicationShouldHandleReopen(_ sender: NSApplication,
                                              hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }
        if UserDefaults.standard.integer(forKey: WelcomeStateKeys.completedVersion)
            < WelcomeStateKeys.currentVersion {
            welcome.show()
        } else {
            settingsWindow.show()
        }
        return false
    }
}
