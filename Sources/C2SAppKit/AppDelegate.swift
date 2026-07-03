import AppKit
import SwiftUI

/// App 生命周期:菜单栏代理(.accessory + Info.plist LSUIElement)。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    public let settings = SettingsStore()
    public private(set) lazy var coordinator = AppCoordinator(settings: settings)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }
}
