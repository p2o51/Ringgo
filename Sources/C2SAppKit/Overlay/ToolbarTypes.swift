import SwiftUI

/// 迷你工具条的选区类型(决定按钮集合:文字有「翻译」,图片只有「复制」)。
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
    private static func normalized(_ raw: String) -> String {
        let locale = Locale(identifier: raw)
        let lang = locale.language
        if let script = lang.script?.identifier, let code = lang.languageCode?.identifier {
            return "\(code)-\(script)"
        }
        return lang.languageCode?.identifier ?? raw
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
