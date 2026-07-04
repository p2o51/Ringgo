import SwiftUI

/// 迷你工具条的选区类型(决定按钮集合:文字 = 翻译/可视化,图片 = 翻译/可视化/编辑)。
enum MiniToolbarKind: Equatable {
    case text
    case image
}

/// 翻译目标语言选项(BCP-47 code + 本地化显示名)。
struct TranslationLanguageOption: Identifiable, Equatable {
    let id: String          // BCP-47,如 "zh-Hans" / "en" / "ja"
    let displayName: String

    /// 语言菜单(UX 排序):系统语言 → 用户偏好语言序列 → 常用语言,去重。
    /// 默认目标 = 上次选择(persisted)∨ 系统首选语言。
    static func menuOptions() -> [TranslationLanguageOption] {
        var codes: [String] = []
        // 1) 用户偏好语言(系统语言即其首位)
        for raw in Locale.preferredLanguages {
            let code = normalized(raw)
            if !codes.contains(code) { codes.append(code) }
        }
        // 2) 常用语言兜底
        for code in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "ru", "pt"]
        where !codes.contains(code) {
            codes.append(code)
        }
        return codes.map { option(for: $0) }
    }

    static func option(for code: String) -> TranslationLanguageOption {
        let name = Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
        return TranslationLanguageOption(id: code, displayName: name)
    }

    /// "zh-Hans-CN" → "zh-Hans","en-US" → "en"(脚本保留,地区去掉)。
    static func normalized(_ raw: String) -> String {
        let locale = Locale(identifier: raw)
        let lang = locale.language
        if let script = lang.script?.identifier, let code = lang.languageCode?.identifier {
            return "\(code)-\(script)"
        }
        return lang.languageCode?.identifier ?? raw
    }
}

/// 两段式「在默认浏览器打开」按钮(2026-07-03 用户拍板):
/// 点一下 → accent 药丸「确认打开」(2.5s 未确认自动还原);再点 → 打开浏览器
/// 并退出覆盖层(否则浏览器在全屏覆盖层背后打开,毫无动静,非常怪)。
struct ConfirmOpenButton: View {
    /// 点击时求值,保证拿到的是当前页面(而非按钮创建时的旧 URL)。
    let urlProvider: () -> URL?
    /// 非 nil = 禁用 + 悬停说明(如 Lens 会话绑定)。
    var disabledReason: String?
    /// 打开成功后调用(退出覆盖层)。
    var onOpened: () -> Void

    @State private var armed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        Button(action: tap) {
            if armed {
                Text("确认打开")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .fixedSize()
            } else {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabledReason != nil)
        .opacity(disabledReason != nil ? 0.3 : 1)
        .help(disabledReason ?? (armed ? "再点一次:打开并退出圈选" : "在默认浏览器中打开"))
        .accessibilityLabel(armed ? "确认在浏览器中打开" : "在浏览器中打开")
        .animation(.easeOut(duration: 0.12), value: armed)
        .onDisappear { disarmTask?.cancel() }
    }

    private func tap() {
        if armed {
            disarmTask?.cancel()
            armed = false
            guard let url = urlProvider() else { return }
            NSWorkspace.shared.open(url)
            Haptics.confirm()
            onOpened()
        } else {
            armed = true
            disarmTask?.cancel()
            disarmTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                armed = false
            }
        }
    }
}

/// Liquid Glass 背板(macOS 26+;旧系统薄材质)。工具条族共用。
extension View {
    @ViewBuilder
    func toolbarGlass(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
