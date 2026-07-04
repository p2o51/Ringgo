import AppKit
import Carbon
import SwiftUI

/// System Settings / Raycast 风格的全局热键录制器。
///
/// 录制期间会暂停 Carbon 热键与蓄力监听，否则按下当前组合时事件会先被全局
/// 热键消费，反而唤起覆盖层，设置窗口收不到这次 keyDown。
@MainActor
struct HotkeyRecorderRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator

    @State private var isRecording = false
    @State private var modifierPreview: NSEvent.ModifierFlags = []
    @State private var monitor: Any?
    @State private var validationMessage: String?
    @State private var validationTask: Task<Void, Never>?

    private let defaultKeyCode: UInt32 = 1
    private let defaultModifiers: UInt32 = 768

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("圈选热键") {
                HStack(spacing: 8) {
                    Button(action: toggleRecording) {
                        recorderWell
                    }
                    .buttonStyle(.plain)
                    .help(isRecording ? "按 Esc 取消录制" : "点按以更改快捷键")
                    .accessibilityLabel("圈选热键")
                    .accessibilityValue(isRecording
                                        ? "正在录制"
                                        : HotkeySymbols.spokenDescription(
                                            keyCode: settings.hotkeyKeyCode,
                                            carbonModifiers: settings.hotkeyModifiers))
                    .accessibilityHint(isRecording ? "按下新的组合键" : "按下以录制新快捷键")

                    if !isDefault {
                        Button {
                            settings.hotkeyKeyCode = defaultKeyCode
                            settings.hotkeyModifiers = defaultModifiers
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("还原为 ⌘⇧S")
                        .transition(.opacity)
                    }
                }
            }

            Text(helperText)
                .font(.caption)
                .foregroundStyle(validationMessage == nil ? AnyShapeStyle(.secondary)
                                                          : AnyShapeStyle(Color.red))
        }
        .animation(.easeOut(duration: 0.15), value: isDefault)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
        .onDisappear { stopRecording() }
    }

    private var recorderWell: some View {
        Group {
            if isRecording {
                if modifierPreview.intersection(.deviceIndependentFlagsMask).isEmpty {
                    Text("输入新快捷键…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 112, minHeight: 26)
                } else {
                    HotkeyKeycaps(parts: HotkeySymbols.modifierParts(from: modifierPreview),
                                  pressed: true)
                        .frame(minWidth: 112, minHeight: 26)
                }
            } else {
                HotkeyKeycaps(
                    parts: HotkeySymbols.parts(keyCode: settings.hotkeyKeyCode,
                                               carbonModifiers: settings.hotkeyModifiers)
                )
                .frame(minWidth: 112, minHeight: 26)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isRecording ? Color.accentColor
                                          : Color(nsColor: .separatorColor),
                              lineWidth: isRecording ? 2 : 0.5)
        )
        .background {
            if isRecording {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 3)
                    .padding(-2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var helperText: String {
        if let validationMessage { return validationMessage }
        if isRecording { return "按下新的组合键；Esc 取消。" }
        return "在任何应用中按下即可开始圈选。"
    }

    private var isDefault: Bool {
        settings.hotkeyKeyCode == defaultKeyCode
            && settings.hotkeyModifiers == defaultModifiers
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard monitor == nil else { return }
        validationTask?.cancel()
        validationMessage = nil
        modifierPreview = []
        isRecording = true
        coordinator.beginHotkeyRecording()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let eventType = event.type
            let eventFlags = event.modifierFlags
            let eventKeyCode = event.keyCode
            MainActor.assumeIsolated {
                switch eventType {
                case .flagsChanged:
                    modifierPreview = eventFlags
                case .keyDown:
                    handleRecorded(keyCode: eventKeyCode, modifierFlags: eventFlags)
                default:
                    break
                }
            }
            // 修饰键状态必须继续交给系统；普通按键在录制期间不再触发窗口控件。
            return eventType == .keyDown ? nil : event
        }
    }

    private func stopRecording() {
        guard isRecording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        modifierPreview = []
        isRecording = false
        coordinator.endHotkeyRecording()
    }

    private func handleRecorded(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        if keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        let carbon = HotkeySymbols.carbonModifiers(from: modifierFlags)
        guard carbon != 0 else {
            NSSound.beep()
            showValidation("全局热键需包含至少一个修饰键（⌘⌥⌃⇧）。")
            return
        }

        settings.hotkeyKeyCode = UInt32(keyCode)
        settings.hotkeyModifiers = carbon
        stopRecording()
    }

    private func showValidation(_ message: String) {
        validationTask?.cancel()
        validationMessage = message
        validationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            validationMessage = nil
        }
    }
}

/// 可在设置页与欢迎页复用的只读键帽组。
struct HotkeyKeycaps: View {
    let parts: [String]
    var pressed = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, part.count > 2 ? 4 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(pressed ? Color.accentColor.opacity(0.14)
                                          : Color(nsColor: .controlColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            }
        }
        .fixedSize()
    }
}

enum HotkeySymbols {
    // Carbon 修饰键位：cmd=256、shift=512、option=2048、control=4096。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= 256 }
        if flags.contains(.shift) { bits |= 512 }
        if flags.contains(.option) { bits |= 2048 }
        if flags.contains(.control) { bits |= 4096 }
        return bits
    }

    static func parts(keyCode: UInt32, carbonModifiers: UInt32) -> [String] {
        var result: [String] = []
        if carbonModifiers & 4096 != 0 { result.append("⌃") }
        if carbonModifiers & 2048 != 0 { result.append("⌥") }
        if carbonModifiers & 512 != 0 { result.append("⇧") }
        if carbonModifiers & 256 != 0 { result.append("⌘") }
        result.append(keyName(keyCode))
        return result
    }

    static func modifierParts(from flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.control) { result.append("⌃") }
        if flags.contains(.option) { result.append("⌥") }
        if flags.contains(.shift) { result.append("⇧") }
        if flags.contains(.command) { result.append("⌘") }
        return result
    }

    static func spokenDescription(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var result: [String] = []
        if carbonModifiers & 4096 != 0 { result.append("Control") }
        if carbonModifiers & 2048 != 0 { result.append("Option") }
        if carbonModifiers & 512 != 0 { result.append("Shift") }
        if carbonModifiers & 256 != 0 { result.append("Command") }
        result.append(keyName(keyCode))
        return result.joined(separator: " ")
    }

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 76: "⌤",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15",
    ]

    static func keyName(_ code: UInt32) -> String {
        names[code] ?? "键\(code)"
    }
}
