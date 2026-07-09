import AppKit
import SwiftUI

/// 底部工具条 v2(2026-07-03 参照 Spotlight 形态重做):
/// 左 = 玻璃搜索药丸(放大镜 + 输入框 + 听写麦克风),右 = **独立圆形翻译按钮**。
/// 呼出即聚焦输入框(Spotlight 同款;用户点别处自然让位);
/// hover 翻译圆钮 → 上方弹语言菜单(离开有 180ms 宽限,菜单本体也算 hover 区)。
struct BottomToolbar: View {
    let containerWidth: CGFloat
    let languages: [TranslationLanguageOption]
    let currentTarget: TranslationLanguageOption
    let translationAvailable: Bool
    let reduceEffects: Bool
    var onSubmitQuestion: (String) -> Void
    var onPickTarget: (TranslationLanguageOption) -> Void
    var onTranslate: () -> Void
    var onStartDictation: () -> Void

    @State private var question = ""
    @FocusState private var fieldFocused: Bool
    @State private var menuVisible = false
    @State private var hideTask: Task<Void, Never>?

    private static let barHeight: CGFloat = 52

    private var pillWidth: CGFloat {
        max(260, min(480, containerWidth - 220))
    }

    var body: some View {
        // 菜单挂在工具条整体的右上方(ZStack 底对齐 + 底部内边距把它顶上去);
        // alignmentGuide 方案在 transition 下会失效朝下开,弃用。
        ZStack(alignment: .bottomTrailing) {
            HStack(alignment: .center, spacing: 14) {
                searchPill
                translateButton
            }
            if menuVisible {
                languageMenu
                    .padding(.bottom, Self.barHeight + 8)
                    .transition(reduceEffects
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(reduceEffects ? .easeInOut(duration: 0.15)
                                 : .spring(response: 0.28, dampingFraction: 0.82),
                   value: menuVisible)
        .onAppear {
            // 呼出即聚焦(异步一拍等覆盖层窗口成 key)
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onDisappear { hideTask?.cancel() }
    }

    // MARK: - 搜索药丸

    private var searchPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L10n.t("bottombar.search_placeholder", "搜索屏幕内容,或直接提问…"), text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .onSubmit(submit)
            Button(action: onStartDictation) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("bottombar.dictation_help", "听写(需在系统设置开启)"))
            .accessibilityLabel(L10n.t("bottombar.dictation_a11y", "开始听写"))
        }
        .padding(.horizontal, 16)
        .frame(width: pillWidth, height: Self.barHeight)
        .toolbarGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func submit() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        onSubmitQuestion(text)
    }

    // MARK: - 圆形翻译按钮(参考图的独立圆钮形态)

    private var translateButton: some View {
        Button(action: onTranslate) {
            Image(systemName: "translate")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(translationAvailable ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: Self.barHeight, height: Self.barHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .toolbarGlass(in: Circle())
        .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .disabled(!translationAvailable)
        .help(translationAvailable
              ? L10n.f("bottombar.translate_help", "翻译整屏(%@);悬停可切换目标语言", currentTarget.displayName)
              : L10n.t("common.needs_macos15", "需要 macOS 15 或更高版本"))
        .accessibilityLabel(L10n.f("bottombar.translate_a11y", "翻译整屏为%@", currentTarget.displayName))
        .onHover(perform: hoverChanged)
    }

    // MARK: - 语言菜单(hover 弹出)

    private var languageMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(languages.prefix(8)) { option in
                languageRow(option)
            }
            if languages.count > 8 {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(languages.dropFirst(8))) { option in
                            languageRow(option)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(6)
        .frame(width: 200)
        .toolbarGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .onHover(perform: hoverChanged)
    }

    private func languageRow(_ option: TranslationLanguageOption) -> some View {
        Button {
            onPickTarget(option)
            menuVisible = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(option.id == currentTarget.id ? 1 : 0)
                Text(option.displayName)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func hoverChanged(_ hovering: Bool) {
        guard translationAvailable else { return }
        hideTask?.cancel()
        if hovering {
            menuVisible = true
        } else {
            // 离开宽限:给指针跨过按钮与菜单之间的空隙留时间
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                menuVisible = false
            }
        }
    }
}
