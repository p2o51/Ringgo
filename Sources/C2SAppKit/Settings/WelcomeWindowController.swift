import AppKit
import Combine
import SwiftUI

enum WelcomeStateKeys {
    static let completedVersion = "c2s.welcomeCompletedVersion"
    static let resumeSetup = "c2s.welcomeResumeSetup"
    static let screenPromptShown = "c2s.screenPromptShown"
    static let currentVersion = 1
}

public enum WelcomeStep {
    case introduction
    case setup
}

/// accessory 菜单栏应用不能依赖普通 WindowGroup 抢前台，因此欢迎页由 AppKit
/// 显式持有。窗口可从菜单栏和「关于」反复打开，首次启动只自动出现一次。
@MainActor
public final class WelcomeWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let coordinator: AppCoordinator
    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?
    private var suppressCloseCompletion = false

    public init(settings: SettingsStore, coordinator: AppCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
        super.init()
    }

    public func showForFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: WelcomeStateKeys.resumeSetup) {
            defaults.removeObject(forKey: WelcomeStateKeys.resumeSetup)
            show(step: .setup)
        } else if defaults.integer(forKey: WelcomeStateKeys.completedVersion)
                    < WelcomeStateKeys.currentVersion {
            show(step: .introduction)
        }
    }

    public func show(step: WelcomeStep = .introduction) {
        let content = WelcomeView(
            initialStep: step,
            onClose: { [weak self] in self?.dismiss(markCompleted: true, beginCapture: false) },
            onFinish: { [weak self] beginCapture in
                self?.dismiss(markCompleted: true, beginCapture: beginCapture)
            }
        )
        .environmentObject(settings)
        .environmentObject(coordinator)

        let host = NSHostingController(rootView: AnyView(content))
        hostingController = host

        let window: NSWindow
        if let existing = self.window {
            window = existing
            window.contentViewController = host
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 590),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "欢迎使用 Ringgo"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentMinSize = NSSize(width: 500, height: 590)
            window.contentMaxSize = NSSize(width: 500, height: 590)
            window.delegate = self
            window.contentViewController = host
            self.window = window
        }

        window.setContentSize(NSSize(width: 500, height: 590))
        window.center()
        window.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Tahoe 协作式激活可能拒绝 accessory 应用抢前台(尤其首次启动无用户
        // 交互令牌时),强制提前,避免欢迎页被别家窗口盖住像"没打开"。
        window.orderFrontRegardless()
    }

    public func windowWillClose(_ notification: Notification) {
        guard !suppressCloseCompletion else { return }
        markCompleted()
    }

    private func dismiss(markCompleted: Bool, beginCapture: Bool) {
        if markCompleted { self.markCompleted() }
        guard let window else { return }

        suppressCloseCompletion = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    window.orderOut(nil)
                    window.alphaValue = 1
                    self?.suppressCloseCompletion = false
                    if beginCapture {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            self?.coordinator.captureNow()
                        }
                    }
                }
            }
        }
    }

    private func markCompleted() {
        UserDefaults.standard.set(WelcomeStateKeys.currentVersion,
                                  forKey: WelcomeStateKeys.completedVersion)
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: WelcomeStep
    @State private var screenGranted = false
    @AppStorage(WelcomeStateKeys.screenPromptShown) private var screenPromptShown = false

    let onClose: () -> Void
    let onFinish: (Bool) -> Void

    private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(initialStep: WelcomeStep,
         onClose: @escaping () -> Void,
         onFinish: @escaping (Bool) -> Void) {
        _step = State(initialValue: initialStep)
        self.onClose = onClose
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            Group {
                switch step {
                case .introduction:
                    introduction
                        .transition(reduceMotion ? .opacity : .push(from: .leading))
                case .setup:
                    setup
                        .transition(reduceMotion ? .opacity : .push(from: .trailing))
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 34)
            .padding(.bottom, 30)
        }
        .frame(width: 500, height: 590)
        .onAppear { refreshPermission() }
        .onReceive(refreshTimer) { _ in
            if !screenGranted { refreshPermission() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermission()
        }
        .onExitCommand(perform: onClose)
    }

    private var introduction: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)

            Text("欢迎使用 Ringgo")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 14)

            Text("圈选屏幕上的任何内容，立即搜索。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(spacing: 17) {
                WelcomeFeatureRow(
                    icon: "hand.draw",
                    title: "随手一圈",
                    detail: "画个圈、划一下或轻点，选中屏幕上的文字与图片。"
                )
                WelcomeFeatureRow(
                    icon: "sparkle.magnifyingglass",
                    title: "即刻搜索",
                    detail: "结果在悬浮面板里展开，不打断手头的工作。"
                )
                WelcomeFeatureRow(
                    icon: "wand.and.stars",
                    title: "翻译与更多",
                    detail: "选中即译、内容可视化与图片编辑，都在圈选里完成。"
                )
            }
            .padding(.top, 28)
            .frame(maxWidth: 370)

            Spacer()

            Button("继续") {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                                           : .spring(response: 0.35, dampingFraction: 0.86)) {
                    step = .setup
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(width: 180)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("完成设置")
                .font(.system(size: 22, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            Text("授权屏幕录制，再确认两项常用偏好。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
                .padding(.bottom, 22)

            permissionCard

            preferencesCard
                .padding(.top, 12)

            Spacer()

            HStack {
                Button("返回") {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                                               : .spring(response: 0.35, dampingFraction: 0.86)) {
                        step = .introduction
                    }
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("开始使用") {
                    onFinish(screenGranted)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var permissionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 11) {
                    SettingsPermissionIcon(systemName: "rectangle.dashed.badge.record")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("屏幕录制权限")
                            .font(.system(size: 13, weight: .semibold))
                        Text("仅在你主动唤起时截取一帧；不录像，也不会自动上传。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if screenGranted {
                        Label("已授权", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.green)
                    } else if !screenPromptShown {
                        Button("授权…", action: requestScreenPermission)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }

                if !screenGranted && screenPromptShown {
                    Divider()
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: .systemYellow))
                        Text("在系统设置中允许后，需要重新启动 Ringgo 才会生效。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("打开系统设置…", action: openScreenSettings)
                            .controlSize(.small)
                        Button("重新启动", action: restartForPermission)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(4)
        }
    }

    private var preferencesCard: some View {
        GroupBox {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("唤起热键")
                            .font(.system(size: 13, weight: .medium))
                        Text("稍后可在「设置 → 通用」中修改。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HotkeyKeycaps(parts: HotkeySymbols.parts(
                        keyCode: settings.hotkeyKeyCode,
                        carbonModifiers: settings.hotkeyModifiers
                    ))
                }

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Toggle("登录时自动启动 Ringgo", isOn: $settings.launchAtLogin)
                    if let error = settings.launchAtLoginError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .padding(4)
        }
    }

    private func refreshPermission() {
        screenGranted = coordinator.capture.hasScreenRecordingPermission
    }

    private func requestScreenPermission() {
        screenPromptShown = true
        _ = CGRequestScreenCaptureAccess()
        refreshPermission()
    }

    private func openScreenSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func restartForPermission() {
        UserDefaults.standard.set(true, forKey: WelcomeStateKeys.resumeSetup)
        coordinator.relaunch { succeeded in
            if !succeeded {
                UserDefaults.standard.removeObject(forKey: WelcomeStateKeys.resumeSetup)
            }
        }
    }
}

private struct WelcomeFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}

struct SettingsPermissionIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .systemBlue))
            )
            .accessibilityHidden(true)
    }
}
