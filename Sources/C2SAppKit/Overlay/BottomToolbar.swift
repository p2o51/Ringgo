import SwiftUI

/// 底部工具条:居中悬浮胶囊(对标 Android Circle to Search 底部栏,mac 化)。
/// 结构:mic 按钮 → 提问输入框 → 翻译按钮(hover 在上方弹语言菜单)。
/// 视觉:Liquid Glass 背板(toolbarGlass)+ hairline 描边 + 柔和投影;中性色 + accent。
struct BottomToolbar: View {
    let containerWidth: CGFloat                    // 覆盖层宽度
    let languages: [TranslationLanguageOption]     // 语言菜单(已排序)
    let currentTarget: TranslationLanguageOption   // 当前目标语言(按钮副标签展示)
    let translationAvailable: Bool                 // false(<macOS 15)→ 翻译按钮 disabled + help 提示
    let reduceEffects: Bool
    var onSubmitQuestion: (String) -> Void         // 回车提交:整屏问 Lens(调用方负责)
    var onPickTarget: (TranslationLanguageOption) -> Void  // 菜单选择(仅更新默认目标)
    var onTranslate: () -> Void                    // 点按翻译主按钮(用当前目标全屏翻译)
    var onStartDictation: () -> Void               // 麦克风按钮

    // 自包含状态:输入文本、菜单显隐、hover 追踪(不自动抢焦点,无 @FocusState)
    @State private var query = ""
    @State private var isMenuShown = false
    @State private var hideMenuTask: Task<Void, Never>?
    @State private var hoveredLanguageID: String?
    @State private var isMicHovered = false
    @State private var isTranslateHovered = false

    // MARK: - 尺寸

    private let barHeight: CGFloat = 52
    private let menuWidth: CGFloat = 200
    private let menuRowHeight: CGFloat = 28
    private let menuRowSpacing: CGFloat = 2
    private let maxVisibleMenuRows = 8
    private let hideGraceNanoseconds: UInt64 = 150_000_000   // 指针移向菜单途中的离开宽限

    private var barWidth: CGFloat {
        // 极窄容器下兜底,避免非法负宽 frame
        max(180, min(560, containerWidth - 48))
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 10) {
            micButton
            queryField
            translateButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(width: barWidth, height: barHeight)
        .toolbarGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 6)
        .overlay(alignment: .topTrailing) {
            if isMenuShown {
                languageMenu
                    .padding(.trailing, 6)                    // 与翻译按钮大致对齐
                    .alignmentGuide(.top) { $0[.bottom] + 8 } // 菜单底边悬于条顶上方 8pt
                    .transition(menuTransition)
            }
        }
    }

    // MARK: - 左:麦克风

    private var micButton: some View {
        Button(action: onStartDictation) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Color.primary.opacity(isMicHovered ? 0.08 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isMicHovered = $0 }
        .help("听写提问")
        .accessibilityLabel(Text("开始听写"))
    }

    // MARK: - 中:提问输入框

    private var queryField: some View {
        TextField("搜索屏幕内容,或直接提问…", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .onSubmit(submitQuery)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text("搜索屏幕内容,或直接提问"))
    }

    private func submitQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmitQuestion(trimmed)
        query = ""
    }

    // MARK: - 右:翻译按钮

    private var translateButton: some View {
        Button(action: onTranslate) {
            HStack(spacing: 7) {
                Image(systemName: "translate")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(translationAvailable
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 0) {
                    Text("翻译")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(translationAvailable
                                         ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(.tertiary))
                    Text(currentTarget.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(translationAvailable
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(.quaternary))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isTranslateHovered ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!translationAvailable)
        .onHover(perform: translateHoverChanged)
        .help(translationAvailable
              ? "以\(currentTarget.displayName)翻译整屏;悬停可切换目标语言"
              : "需要 macOS 15 或更高版本")
        .accessibilityLabel(Text("翻译为\(currentTarget.displayName)"))
    }

    // MARK: - 语言菜单(hover 弹出于按钮上方)

    private var languageMenu: some View {
        Group {
            if languages.count > maxVisibleMenuRows {
                ScrollView(showsIndicators: true) { menuRows }
                    .frame(height: scrollAreaHeight)
            } else {
                menuRows
            }
        }
        .padding(4)
        .frame(width: menuWidth)
        .toolbarGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .onHover(perform: menuHoverChanged)   // 菜单本体也算 hover 区
        .accessibilityLabel(Text("翻译目标语言"))
    }

    private var menuRows: some View {
        VStack(alignment: .leading, spacing: menuRowSpacing) {
            ForEach(languages) { option in
                menuRow(for: option)
            }
        }
    }

    private func menuRow(for option: TranslationLanguageOption) -> some View {
        let isCurrent = option.id == currentTarget.id
        let isHovered = hoveredLanguageID == option.id
        return Button {
            onPickTarget(option)
            dismissMenu()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(isCurrent ? 1 : 0)   // 占位对齐,当前项打勾
                    .frame(width: 14)
                Text(option.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: menuRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(isHovered ? 1 : 0))
            )
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredLanguageID = option.id
            } else if hoveredLanguageID == option.id {
                hoveredLanguageID = nil
            }
        }
        .accessibilityLabel(Text(isCurrent ? "\(option.displayName),当前目标" : option.displayName))
    }

    private var scrollAreaHeight: CGFloat {
        CGFloat(maxVisibleMenuRows) * menuRowHeight
            + CGFloat(maxVisibleMenuRows - 1) * menuRowSpacing
    }

    // MARK: - Hover 显隐逻辑(150ms 离开宽限)

    private func translateHoverChanged(_ hovering: Bool) {
        isTranslateHovered = hovering && translationAvailable
        guard translationAvailable else { return }   // 不可用 → 不弹菜单
        if hovering {
            revealMenu()
        } else {
            scheduleMenuHide()
        }
    }

    private func menuHoverChanged(_ hovering: Bool) {
        if hovering {
            cancelPendingHide()   // 指针已抵达菜单,取消待隐藏
        } else {
            scheduleMenuHide()
        }
    }

    private func revealMenu() {
        cancelPendingHide()
        guard !isMenuShown else { return }
        withAnimation(menuAnimation) { isMenuShown = true }
    }

    private func scheduleMenuHide() {
        cancelPendingHide()
        hideMenuTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hideGraceNanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(menuAnimation) { isMenuShown = false }
            hoveredLanguageID = nil
        }
    }

    private func dismissMenu() {
        cancelPendingHide()
        withAnimation(menuAnimation) { isMenuShown = false }
        hoveredLanguageID = nil
    }

    private func cancelPendingHide() {
        hideMenuTask?.cancel()
        hideMenuTask = nil
    }

    // MARK: - 动效(reduceEffects → 纯淡入淡出)

    private var menuAnimation: Animation {
        reduceEffects
            ? .easeInOut(duration: 0.15)
            : .spring(response: 0.28, dampingFraction: 0.82)
    }

    private var menuTransition: AnyTransition {
        reduceEffects
            ? .opacity
            : .opacity
                .combined(with: .scale(scale: 0.94, anchor: .bottomTrailing))
                .combined(with: .offset(y: 4))
    }
}
