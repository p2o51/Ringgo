import AppKit
import SwiftUI

/// 设置窗口由 AppKit 显式持有,不走 SwiftUI `Settings` 场景:
/// macOS 26 上 accessory 应用的 SettingsLink/openSettings 在没有其他窗口
/// 提供场景上下文时会静默失败(菜单动作发出、窗口从不实体化)。
/// 机制与 WelcomeWindowController 一致,后者已在签名分发版上验证可用。
@MainActor
public final class SettingsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let coordinator: AppCoordinator
    private let welcome: WelcomeWindowController
    private var window: NSWindow?

    public init(settings: SettingsStore,
                coordinator: AppCoordinator,
                welcome: WelcomeWindowController) {
        self.settings = settings
        self.coordinator = coordinator
        self.welcome = welcome
        super.init()
    }

    public func show() {
        let content = SettingsView()
            .environmentObject(settings)
            .environmentObject(coordinator)
            .environmentObject(welcome)
        let host = NSHostingController(rootView: AnyView(content))

        let window: NSWindow
        if let existing = self.window {
            window = existing
            window.contentViewController = host
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Ringgo 设置"
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.delegate = self
            window.contentViewController = host
            window.setFrameAutosaveName("c2s.settingsWindow")
            if !window.setFrameUsingName("c2s.settingsWindow") {
                window.center()
            }
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Tahoe 协作式激活可能拒绝 accessory 应用抢前台,强制把窗口提到最前,
        // 否则窗口只在本应用的 z 序内排前,仍被别家窗口盖住。
        window.orderFrontRegardless()
    }

    public func windowWillClose(_ notification: Notification) {
        // orderOut 不会触发 SwiftUI onDisappear;显式卸掉内容视图,
        // 让 HotkeyRecorder 之类依赖 onDisappear 的清理逻辑(恢复全局热键)执行。
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentViewController = nil
        }
    }
}
