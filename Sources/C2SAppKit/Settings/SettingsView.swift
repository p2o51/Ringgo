import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Ringgo 设置内容：TabView + grouped Form,宿主为 SettingsWindowController
/// 显式持有的 AppKit 窗口(macOS 26 上 Settings 场景对 accessory 应用不可靠)。
public struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var welcome: WelcomeWindowController

    public init() {}

    public var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(L10n.t("settings.tab.general", "通用"), systemImage: "gearshape") }
            AppearanceTab()
                .tabItem { Label(L10n.t("settings.tab.appearance", "外观"), systemImage: "circle.lefthalf.filled") }
            SearchTab()
                .tabItem { Label(L10n.t("settings.tab.search", "搜索"), systemImage: "magnifyingglass") }
            ScreenshotTab()
                .tabItem { Label(L10n.t("settings.tab.screenshot", "截图"), systemImage: "camera.viewfinder") }
            PermissionsTab()
                .tabItem { Label(L10n.t("settings.tab.permissions", "权限"), systemImage: "lock.shield") }
            AboutTab()
                .tabItem { Label(L10n.t("settings.tab.about", "关于"), systemImage: "info.circle") }
        }
        .frame(width: 560, height: 430)
    }
}

// MARK: - 截图(F20/F21,spec §6)

@MainActor
private struct ScreenshotTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section(L10n.t("settings.shot.section.trigger", "截图")) {
                HotkeyRecorderRow(
                    label: L10n.t("settings.shot.hotkey_label", "截图热键"),
                    helperIdle: L10n.t("settings.shot.hotkey_caption",
                                       "拖拽 = 区域、点击 = 整窗、⏎ = 全屏,松手即拍。"),
                    keyCode: $settings.shotHotkeyKeyCode,
                    modifiers: $settings.shotHotkeyModifiers,
                    defaultKeyCode: 7,
                    defaultModifiers: 768,
                    resetHelp: L10n.t("settings.shot.hotkey_reset", "还原为 ⌘⇧X"),
                    conflictCheck: { keyCode, modifiers in
                        (keyCode == settings.hotkeyKeyCode && modifiers == settings.hotkeyModifiers)
                            ? L10n.t("settings.shot.hotkey_conflict", "与圈选热键相同,请换一个组合。")
                            : nil
                    })
            }

            Section(L10n.t("settings.shot.section.output", "产物")) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(L10n.t("settings.shot.copy_toggle", "拍后复制到剪贴板"),
                           isOn: $settings.shotCopyToClipboard)
                    Text(L10n.t("settings.shot.copy_caption", "以 PNG + TIFF 双格式写入,兼容各类应用粘贴。"))
                        .settingsCaption()
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle(L10n.t("settings.shot.save_toggle", "自动保存到磁盘"),
                           isOn: $settings.shotAutoSave)
                    HStack(spacing: 8) {
                        Text(displayDirectory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if !settings.shotSaveDirectory.isEmpty {
                            Button(L10n.t("settings.shot.dir_reset", "还原默认")) {
                                settings.shotSaveDirectory = ""
                            }
                            .controlSize(.small)
                        }
                        Button(L10n.t("settings.shot.dir_choose", "选择…")) { chooseDirectory() }
                            .controlSize(.small)
                    }
                    .disabled(!settings.shotAutoSave)
                    if isTCCProtectedDirectory {
                        Text(L10n.t("settings.shot.dir_tcc_caption",
                                    "桌面/文稿/下载受系统保护,首次写入会弹出授权窗口。"))
                            .settingsCaption()
                    }
                }

                LabeledContent(L10n.t("settings.shot.template_label", "文件名模板")) {
                    TextField("", text: $settings.shotFilenameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .disabled(!settings.shotAutoSave)
                }
                Text(L10n.t("settings.shot.template_caption",
                            "{date} = 2026-07-16,{time} = 14.22.33;同名自动追加 (2)。"))
                    .settingsCaption()

                VStack(alignment: .leading, spacing: 3) {
                    Picker(L10n.t("settings.shot.format_label", "图片格式"),
                           selection: $settings.shotImageFormat) {
                        ForEach(SettingsStore.ShotFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Text(L10n.t("settings.shot.format_caption", "窗口截图始终使用 PNG 以保留透明圆角。"))
                        .settingsCaption()
                }

                Toggle(L10n.t("settings.shot.shadow_toggle", "窗口截图带阴影"),
                       isOn: $settings.shotWindowShadow)
                Toggle(L10n.t("settings.shot.sound_toggle", "快门声"),
                       isOn: $settings.shotShutterSound)
            }

            Section(L10n.t("settings.shot.section.tray", "托盘")) {
                Picker(L10n.t("settings.shot.tray_corner_label", "托盘位置"),
                       selection: $settings.shotTrayCorner) {
                    ForEach(SettingsStore.ShotTrayCorner.allCases) { corner in
                        Text(corner.label).tag(corner)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(L10n.t("settings.shot.tray_dismiss_toggle", "自动收起托盘"),
                           isOn: $settings.shotTrayAutoDismiss)
                    if settings.shotTrayAutoDismiss {
                        Picker(L10n.t("settings.shot.tray_dismiss_seconds", "收起延时"),
                               selection: $settings.shotTrayAutoDismissSeconds) {
                            ForEach([5, 10, 30, 60, 300], id: \.self) { seconds in
                                Text(seconds < 60
                                     ? L10n.f("settings.shot.tray_seconds", "%d 秒", seconds)
                                     : L10n.f("settings.shot.tray_minutes", "%d 分钟", seconds / 60))
                                    .tag(seconds)
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                    Text(L10n.t("settings.shot.tray_dismiss_caption",
                                "收起只是托盘项消失;截图仍在剪贴板与磁盘里。悬停托盘会暂停计时。"))
                        .settingsCaption()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var displayDirectory: String {
        (settings.shotSaveDirectoryURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Desktop/Documents/Downloads 受 TCC 文件夹保护(spec §7:如实告知)。
    private var isTCCProtectedDirectory: Bool {
        let path = settings.shotSaveDirectoryURL.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads"]
            .contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.shotSaveDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.shotSaveDirectory = url.path
        }
    }
}

// MARK: - 通用

@MainActor
private struct GeneralTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section(L10n.t("settings.general.section.capture", "圈选")) {
                HotkeyRecorderRow(
                    label: L10n.t("hotkey.label", "圈选热键"),
                    helperIdle: L10n.t("hotkey.helper_idle", "在任何应用中按下即可开始圈选。"),
                    keyCode: $settings.hotkeyKeyCode,
                    modifiers: $settings.hotkeyModifiers,
                    defaultKeyCode: 1,
                    defaultModifiers: 768,
                    resetHelp: L10n.t("hotkey.reset_help", "还原为 ⌘⇧S"),
                    conflictCheck: { keyCode, modifiers in
                        (keyCode == settings.shotHotkeyKeyCode && modifiers == settings.shotHotkeyModifiers)
                            ? L10n.t("settings.shot.hotkey_conflict_reverse", "与截图热键相同,请换一个组合。")
                            : nil
                    })
            }

            Section(L10n.t("settings.general.section.more_triggers", "更多唤起方式")) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(L10n.t("settings.charge.toggle", "蓄力唤起"), isOn: $settings.chargeEnabled)
                    Text(L10n.t("settings.charge.caption", "按住 ⌘⇧ 约 250 毫秒唤起；阈值前松开即取消。"))
                        .settingsCaption()
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle(L10n.t("settings.double_shift.toggle", "双击 Shift 唤起"), isOn: $settings.doubleShiftEnabled)
                    Text(L10n.t("settings.double_shift.caption", "可选能力，需要辅助功能权限；开启时才会向系统申请。"))
                        .settingsCaption()

                    if settings.doubleShiftEnabled && !axTrusted {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color(nsColor: .systemYellow))
                            Text(L10n.t("settings.double_shift.no_ax", "尚未授予辅助功能权限"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.t("common.go_authorize", "前往授权…")) {
                                openSystemSettings(
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                )
                            }
                            .controlSize(.small)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle(L10n.t("settings.multitouch.toggle", "三指双击触控板（实验性）"), isOn: $settings.multitouchEnabled)
                    Text(L10n.t("settings.multitouch.caption", "在任意 App 前台连续三指轻点两次。无需辅助功能权限；可能与系统三指手势冲突。"))
                        .settingsCaption()

                    if settings.multitouchEnabled {
                        MultitouchStatusRow(status: coordinator.multitouchStatus) {
                            coordinator.retryMultitouch()
                        }
                    }
                }
            }

            Section(L10n.t("settings.general.section.launch", "启动")) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(L10n.t("settings.launch_at_login.toggle", "登录时启动 Ringgo"), isOn: $settings.launchAtLogin)
                    Text(L10n.t("settings.launch_at_login.caption", "登录 Mac 时在菜单栏静默启动。"))
                        .settingsCaption()
                    if let hint = settings.launchAtLoginError {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.doubleShiftEnabled) { _, enabled in
            if enabled { requestAccessibilityPrompt() }
            axTrusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AXIsProcessTrusted()
        }
    }

    private func requestAccessibilityPrompt() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}

private struct MultitouchStatusRow: View {
    let status: MultitouchTriggerStatus
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            switch status {
            case .disabled:
                EmptyView()
            case .active(let deviceCount):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text(L10n.f("settings.multitouch.connected", "已连接 %d 个触控板", deviceCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .sleeping:
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("settings.multitouch.sleeping", "睡眠中，唤醒后自动重连"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .unavailable(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemYellow))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(L10n.t("common.retry", "重试"), action: retry)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 外观

@MainActor
private struct AppearanceTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section(L10n.t("settings.tab.appearance", "外观")) {
                HStack(spacing: 22) {
                    ForEach(SettingsStore.Appearance.allCases) { appearance in
                        Button {
                            settings.appearance = appearance
                        } label: {
                            VStack(spacing: 7) {
                                AppearancePreview(appearance: appearance,
                                                  selected: settings.appearance == appearance)
                                Text(appearance.label)
                                    .font(.system(size: 11,
                                                  weight: settings.appearance == appearance
                                                    ? .medium : .regular))
                                    .foregroundStyle(settings.appearance == appearance
                                                        ? AnyShapeStyle(Color.accentColor)
                                                        : AnyShapeStyle(.secondary))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(appearance.label)
                        .accessibilityAddTraits(settings.appearance == appearance
                                                    ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(L10n.t("settings.reduce_effects.toggle", "减弱动态效果"), isOn: $settings.reduceEffects)
                    Text(L10n.t("settings.reduce_effects.caption", "关闭微光游走、涟漪等装饰性动画，面板改用淡入淡出。"))
                        .settingsCaption()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearancePreview: View {
    let appearance: SettingsStore.Appearance
    let selected: Bool

    private var background: AnyShapeStyle {
        switch appearance {
        case .light:
            return AnyShapeStyle(Color.white)
        case .dark:
            return AnyShapeStyle(Color(red: 0.11, green: 0.12, blue: 0.15))
        case .system:
            return AnyShapeStyle(
                LinearGradient(colors: [.white, Color(red: 0.11, green: 0.12, blue: 0.15)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            )
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(rowColor.opacity(0.8)).frame(width: 36, height: 4)
                Capsule().fill(rowColor.opacity(0.55)).frame(width: 45, height: 4)
                Capsule().fill(rowColor.opacity(0.35)).frame(width: 28, height: 4)
            }
        }
        .frame(width: 68, height: 46)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                .padding(-4)
        )
    }

    private var rowColor: Color {
        appearance == .dark ? .white : .black
    }
}

// MARK: - 搜索

@MainActor
private struct SearchTab: View {
    @EnvironmentObject private var settings: SettingsStore

    private var systemLanguageCode: String {
        TranslationLanguageOption.normalized(Locale.preferredLanguages.first ?? "en")
    }

    private var systemLanguageName: String {
        TranslationLanguageOption.option(for: systemLanguageCode).displayName
    }

    private var languageOptions: [TranslationLanguageOption] {
        var options = TranslationLanguageOption.menuOptions()
        let selected = settings.translationTargetCode
        if !selected.isEmpty, !options.contains(where: { $0.id == selected }) {
            options.append(TranslationLanguageOption.option(for: selected))
        }
        return options
    }

    var body: some View {
        Form {
            Section(L10n.t("settings.tab.search", "搜索")) {
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent(L10n.t("settings.search.default_engine", "默认引擎"), value: "Google")
                    Text(L10n.t("settings.search.engine_caption", "目前支持 Google，更多引擎仍在计划中。"))
                        .settingsCaption()
                }
            }

            Section(L10n.t("settings.search.ocr_section", "文字识别")) {
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent(L10n.t("settings.search.ocr_language", "OCR 语言"),
                                   value: L10n.t("settings.search.ocr_auto", "自动检测"))
                    Text(L10n.t("settings.search.ocr_caption", "由 Apple Vision 在本机识别，支持中、英、日、韩等语言。"))
                        .settingsCaption()
                }
            }

            Section(L10n.t("settings.search.translation_section", "翻译")) {
                Picker(L10n.t("settings.search.translate_to", "翻译成"), selection: $settings.translationTargetCode) {
                    Text(L10n.f("settings.search.follow_system", "跟随系统（%@）", systemLanguageName)).tag("")
                    Divider()
                    ForEach(languageOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }

                Text(L10n.t("settings.search.translation_caption", "圈选文字或图片后的翻译目标；与圈选工具条保持同步。整屏翻译需要 macOS 15 或更高版本。"))
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 权限

@MainActor
private struct PermissionsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var screenGranted = false
    @State private var axTrusted = false
    @AppStorage(WelcomeStateKeys.screenPromptShown) private var screenPromptShown = false

    var body: some View {
        Form {
            Section(L10n.t("settings.perm.screen_section", "屏幕录制")) {
                PermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: L10n.t("settings.perm.screen_title", "屏幕录制"),
                    detail: L10n.t("settings.perm.screen_detail", "圈选时截取一帧当前屏幕；不录像，也不会自动上传。"),
                    granted: screenGranted,
                    actionTitle: L10n.t("common.go_authorize", "前往授权…")
                ) {
                    screenPromptShown = true
                    openSystemSettings(
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    )
                }

                if !screenGranted && screenPromptShown {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(nsColor: .systemYellow))
                        Text(L10n.t("settings.perm.screen_restart_hint", "允许后需要重新启动 Ringgo 才会生效。"))
                            .settingsCaption()
                        Spacer()
                        Button(L10n.t("common.restart_ringgo", "重新启动 Ringgo")) {
                            coordinator.relaunch()
                        }
                        .controlSize(.small)
                    }
                }
            }

            if settings.doubleShiftEnabled {
                Section(L10n.t("settings.perm.ax_section", "辅助功能")) {
                    PermissionRow(
                        icon: "accessibility",
                        title: L10n.t("settings.perm.ax_title", "辅助功能"),
                        detail: L10n.t("settings.perm.ax_detail", "仅「双击 Shift 唤起」需要；主热键与蓄力唤起不需要。"),
                        granted: axTrusted,
                        actionTitle: L10n.t("common.go_authorize", "前往授权…")
                    ) {
                        openSystemSettings(
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        screenGranted = coordinator.capture.hasScreenRecordingPermission
        axTrusted = AXIsProcessTrusted()
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            SettingsPermissionIcon(systemName: icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if granted {
                Label(L10n.t("common.granted", "已授权"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.green)
            } else {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 关于

@MainActor
private struct AboutTab: View {
    @EnvironmentObject private var welcome: WelcomeWindowController

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? L10n.t("settings.about.dev_build", "开发构建")
    }

    var body: some View {
        VStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)

            Text("Ringgo")
                .font(.title2.weight(.semibold))
            Text(L10n.f("settings.about.version", "版本 %@", version))
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(L10n.t("settings.about.show_welcome", "查看欢迎引导")) {
                welcome.show()
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Text {
    func settingsCaption() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func openSystemSettings(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
}
