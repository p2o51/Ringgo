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

    /// F20 URL scheme(spec S1;Raycast/Stream Deck/BTT 绑定用):
    /// `c2s://capture` = 圈选;`c2s://shot` = 截图覆盖层;`c2s://shot?mode=full` = 直拍全屏。
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "c2s" {
            switch url.host?.lowercased() {
            case "capture":
                coordinator.captureNow()
            case "shot":
                let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "mode" })?.value
                if mode == "full" {
                    coordinator.shotFullScreenNow()
                } else {
                    coordinator.shotNow()
                }
            default:
                break
            }
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
