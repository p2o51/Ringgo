import SwiftUI

/// 选区迷你工具条(features/ui-style:选中文字/图片后出现在选区尾部附近)。
/// 无输入框——搜索编辑在结果面板里;这里只有动作按钮:
/// .text → [翻译][可视化],.image → [翻译][可视化][编辑](复制统一走 ⌘C)。
/// 视觉:横排胶囊 + Liquid Glass 背板 + hairline 描边 + 轻投影;中性色,不用光谱色。
/// 摆位:调用方用 `estimatedSize(for:)` + `placement(selection:canvas:size:)` 计算
/// top-left origin(覆盖层点坐标,左上原点)后直接放置;出现动画在组件内部。
/// 触觉(Haptics.confirm)由调用方在回调里做,组件只回调。
struct SelectionMiniToolbar: View {
    let kind: MiniToolbarKind
    /// 当前 prompt 模式(= 面板 chip 的模式):对应按钮高亮(再点退出/重发)。
    /// v3 起两键并存,整胶囊 accent 高亮会指代不明 → 改为按钮级 accent 前景高亮。
    var activeMode: QueryPromptMode?
    let reduceEffects: Bool
    /// nil = 不显示对应按钮。
    var onTranslate: (() -> Void)?
    var onVisualize: (() -> Void)?
    /// 图片选区「编辑」内联输入的展开状态。容器持有(参与尺寸估算与摆位):
    /// 点「编辑」→ 按钮旁展开指令输入框(自动聚焦),回车才发起编辑(v4,2026-07-03)。
    var editExpanded: Binding<Bool> = .constant(false)
    /// 编辑指令提交(nano banana);nil = 不显示编辑按钮。
    var onEditSubmit: ((String) -> Void)?

    /// 「改选」chip(独立小胶囊,与动作胶囊隔开——语义是切换选区类型,不是操作):
    /// .text → 「改选图片」(图上文字被误选时改回框选);nil = 不显示。
    var onSwitchToImage: (() -> Void)?
    /// .image → 「改选文字」(async:框内无已知词时会裁剪选区补刀 OCR)。
    /// .noText = 确实没有文字,chip 原地摇头 + 浮出「未识别到文字」说明
    /// (选区不动);.superseded = 结果作废,完全静默。nil = 不显示。
    var onSwitchToText: (() async -> TextSwitchOutcome)?

    /// 指令草稿(提交后保留,再次展开可微调重发)。
    @State private var editText = ""
    @FocusState private var editFieldFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// onAppear 驱动一次的入场标记(scale 0.92→1 + 淡入;减弱动态 → 纯淡入)。
    @State private var appeared = false
    /// 摇头动画相位(+1 = 三个来回;整数静止位无位移)。
    @State private var shakePhase: CGFloat = 0
    /// 「未识别到文字」浮出说明(1.6s 后自动隐去)。
    @State private var noTextCaptionVisible = false
    @State private var captionTask: Task<Void, Never>?
    /// 「改选文字」进行中(补刀 OCR 在飞):图标位转圈,防重复点击。
    @State private var switchingToText = false
    /// 在飞的切换任务:用户转去编辑/翻译/可视化(意图已变)或工具条卸载时取消,
    /// 晚到的结果经 VM 的 Task.isCancelled 检查静默作废。
    @State private var switchTask: Task<Void, Never>?

    // MARK: - 尺寸常量(estimatedSize 与 body 共用,保持一致)

    private enum Metrics {
        static let height: CGFloat = 36
        static let paddingH: CGFloat = 12        // 胶囊内容水平内边距
        static let buttonPaddingH: CGFloat = 10  // 单按钮左右内边距
        static let iconTextSpacing: CGFloat = 5
        static let fontSize: CGFloat = 12
        static let hairline: CGFloat = 0.5
        static let gap: CGFloat = 10             // 工具条与选区的间隙
        static let screenMargin: CGFloat = 8     // 屏幕边缘留白
        /// 单按钮内容估算宽:SF 图标 ~14pt + 间距 5 + 两个汉字(12pt medium)~25pt。
        static let estimatedButtonContentWidth: CGFloat = 44
        /// 三字按钮(可视化)的内容估算宽:多一个汉字 ~13pt。
        static let estimatedWideButtonContentWidth: CGFloat = 57
        /// 编辑内联输入框宽 / 提交按钮区宽(图标 16 + 左右 padding)。
        static let editFieldWidth: CGFloat = 210
        static let editSubmitWidth: CGFloat = 26
        static let editFieldLeadingGap: CGFloat = 8
        /// 「改选」chip 与动作胶囊的间隔(独立胶囊,视觉隔开)。
        static let switchChipGap: CGFloat = 8
        /// chip 内容估算宽:SF 图标 ~14 + 间距 5 + 四个汉字(12pt medium)~50。
        static let switchChipContentWidth: CGFloat = 69
    }

    private var motionReduced: Bool { reduceEffects || reduceMotion }

    // MARK: - Body

    var body: some View {
        // 「改选」chip(独立小胶囊)在前 + 动作胶囊在后;整体一起入场。
        // placement 右对齐选区右缘 → 动作胶囊位置与无 chip 时基本一致,chip 向左伸出。
        HStack(alignment: .center, spacing: Metrics.switchChipGap) {
            switchChip
            actionCapsule
        }
        .scaleEffect(motionReduced || appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            let animation: Animation = motionReduced
                ? .easeOut(duration: 0.15)
                : .spring(response: 0.25, dampingFraction: 0.8)
            withAnimation(animation) { appeared = true }
        }
        .onDisappear {
            switchTask?.cancel()
            captionTask?.cancel()
        }
        // 展开编辑 = 意图转向图片编辑:取消在飞的「改选文字」,并收掉可能
        // 残留的失败气泡(chip 隐藏期间它无处渲染,重挂载时会凭空闪现)
        .onChange(of: editExpanded.wrappedValue) { _, expanded in
            guard expanded else { return }
            switchTask?.cancel()
            captionTask?.cancel()
            noTextCaptionVisible = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("minitoolbar.a11y", "选区工具条"))
    }

    private var actionCapsule: some View {
        // v3(2026-07-03):.text = [翻译][可视化],.image = [翻译][可视化][编辑];
        // 复制按钮仍不回归(⌘C 直接复制文字/图片)
        HStack(spacing: 0) {
            switch kind {
            case .text:
                if let onTranslate {
                    toolbarButton(icon: "translate", title: L10n.t("common.translate", "翻译"),
                                  action: onTranslate, highlighted: activeMode == .translate)
                }
                if onTranslate != nil, onVisualize != nil { divider }
                if let onVisualize {
                    toolbarButton(icon: "chart.bar.xaxis", title: L10n.t("common.visualize", "可视化"),
                                  action: onVisualize, highlighted: activeMode == .visualize)
                }
            case .image:
                if editExpanded.wrappedValue, onEditSubmit != nil {
                    // 编辑输入态:[编辑(高亮,点击收起)][指令输入][↑ 提交]
                    toolbarButton(icon: "wand.and.stars", title: L10n.t("common.edit", "编辑"),
                                  action: { editExpanded.wrappedValue = false },
                                  highlighted: true)
                    divider
                    editField
                } else {
                    // 图片动作 = 用户意图明确留在图片:顶掉在飞的「改选文字」,
                    // 防补刀晚到把工具条翻成文字面、清掉 Lens 挂起/编辑草稿
                    if let onTranslate {
                        toolbarButton(icon: "translate", title: L10n.t("common.translate", "翻译"),
                                      action: supersedingSwitch(onTranslate),
                                      highlighted: activeMode == .translate)
                    }
                    if onTranslate != nil, onVisualize != nil { divider }
                    if let onVisualize {
                        toolbarButton(icon: "chart.bar.xaxis", title: L10n.t("common.visualize", "可视化"),
                                      action: supersedingSwitch(onVisualize),
                                      highlighted: activeMode == .visualize)
                    }
                    if onVisualize != nil, onEditSubmit != nil { divider }
                    if onEditSubmit != nil {
                        toolbarButton(icon: "wand.and.stars", title: L10n.t("common.edit", "编辑"),
                                      action: supersedingSwitch { editExpanded.wrappedValue = true },
                                      highlighted: activeMode == .editImage)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.paddingH)
        .frame(height: Metrics.height)
        // v3:两键并存,整胶囊 accent 实底(v2 单键开关语义)已不可用 ——
        // 高亮改为按钮级 accent 前景(玻璃胶囊常驻;胶囊内塞小胶囊依旧不做,双层药丸难看)。
        .toolbarGlass(in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color(nsColor: .separatorColor),
                                   lineWidth: Metrics.hairline)
        )
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        .animation(motionReduced ? nil : .easeOut(duration: 0.12), value: activeMode)
    }

    // MARK: - 「改选」chip(切换选区类型;编辑输入展开时让位隐藏)

    @ViewBuilder private var switchChip: some View {
        let config: (icon: String, title: String, action: () -> Void)? = {
            switch kind {
            case .text:
                guard let onSwitchToImage else { return nil }
                return ("photo", L10n.t("minitoolbar.switch_to_image", "改选图片"), onSwitchToImage)
            case .image:
                guard onSwitchToText != nil, !editExpanded.wrappedValue else { return nil }
                return ("text.viewfinder", L10n.t("minitoolbar.switch_to_text", "改选文字"), switchToTextTapped)
            }
        }()
        if let config {
            Button(action: config.action) {
                HStack(spacing: Metrics.iconTextSpacing) {
                    if switchingToText {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                            .frame(width: Metrics.fontSize + 2, height: Metrics.fontSize + 2)
                    } else {
                        Image(systemName: config.icon)
                            .font(.system(size: Metrics.fontSize, weight: .medium))
                    }
                    Text(config.title)
                        .font(.system(size: Metrics.fontSize, weight: .medium))
                }
                // 次要前景:与动作按钮(.primary)拉开一档,强调这是「换选法」不是「做事情」
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.paddingH)
                .frame(height: Metrics.height)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .toolbarGlass(in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color(nsColor: .separatorColor),
                                       lineWidth: Metrics.hairline)
            )
            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
            .modifier(ShakeEffect(phase: shakePhase))
            .overlay(alignment: .top) { noTextCaption }
            .accessibilityLabel(config.title)
            .accessibilityValue(noTextCaptionVisible ? L10n.t("minitoolbar.no_text", "未识别到文字") : "")
        }
    }

    /// 包装图片动作:先取消在飞的「改选文字」再执行(意图被新动作顶掉)。
    private func supersedingSwitch(_ action: @escaping () -> Void) -> () -> Void {
        {
            switchTask?.cancel()
            action()
        }
    }

    /// 「改选文字」点击:框内无已知词时后台补刀 OCR(图标位转圈);
    /// .noText(确实没字)→ 摇头 + 浮出说明,选区不动;.superseded → 完全静默。
    private func switchToTextTapped() {
        guard let onSwitchToText, !switchingToText else { return }
        switchingToText = true
        switchTask = Task { @MainActor in
            let outcome = await onSwitchToText()
            switchingToText = false
            guard outcome == .noText else { return }
            if !motionReduced {
                withAnimation(.easeInOut(duration: 0.45)) { shakePhase += 1 }
            }
            captionTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { noTextCaptionVisible = true }
            captionTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { noTextCaptionVisible = false }
            }
        }
    }

    /// 浮出说明:chip 上方 8pt 的小玻璃气泡,不参与布局(不会挤动工具条摆位)。
    @ViewBuilder private var noTextCaption: some View {
        if noTextCaptionVisible {
            Text(L10n.t("minitoolbar.no_text", "未识别到文字"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .toolbarGlass(in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color(nsColor: .separatorColor),
                                           lineWidth: Metrics.hairline)
                )
                .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
                .fixedSize()
                .offset(y: -(Metrics.height - 6))
                .transition(motionReduced
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
                .accessibilityHidden(true) // 语义由 chip 的 accessibilityValue 承担
        }
    }

    // MARK: - 子视图

    /// 按钮 = SF 图标 + 小字,plain 风格;平时中性前景色(克制),
    /// 模式进行中 = accent 前景 + semibold(按钮级高亮,见 body 注释)。
    private func toolbarButton(icon: String, title: String,
                               action: @escaping () -> Void,
                               highlighted: Bool = false) -> some View {
        Button(action: action) {
            HStack(spacing: Metrics.iconTextSpacing) {
                Image(systemName: icon)
                    .font(.system(size: Metrics.fontSize, weight: highlighted ? .semibold : .medium))
                Text(title)
                    .font(.system(size: Metrics.fontSize, weight: highlighted ? .semibold : .medium))
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            .padding(.horizontal, Metrics.buttonPaddingH)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle()) // 整个按钮区域可点,不只文字
        }
        .buttonStyle(.plain)
        .accessibilityLabel(highlighted ? L10n.f("minitoolbar.button_active", "%@(进行中,点按退出)", title) : title)
    }

    /// 编辑指令内联输入:自动聚焦,回车/↑ 提交(空指令不发);草稿保留可微调重发。
    private var editField: some View {
        HStack(spacing: 4) {
            TextField(L10n.t("common.edit_placeholder", "描述要怎么改这张图…"), text: $editText)
                .textFieldStyle(.plain)
                .font(.system(size: Metrics.fontSize + 1))
                .frame(width: Metrics.editFieldWidth)
                .focused($editFieldFocused)
                .onSubmit(submitEdit)
                .onAppear {
                    // 异步一拍等字段挂进视图树再要焦点(展开当帧要不到)
                    DispatchQueue.main.async { editFieldFocused = true }
                }
            Button(action: submitEdit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(canSubmitEdit
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitEdit)
            .accessibilityLabel(L10n.t("minitoolbar.submit_edit_a11y", "提交编辑指令"))
        }
        .padding(.leading, Metrics.editFieldLeadingGap)
    }

    private var canSubmitEdit: Bool {
        !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        editExpanded.wrappedValue = false
        onEditSubmit?(text)
    }

    /// 按钮之间的 hairline 竖分隔线(留出上下空隙,不顶到胶囊边)。
    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Metrics.hairline)
            .padding(.vertical, 10)
    }

    // MARK: - 摆位(纯静态函数,调用方定位用)

    /// 估算尺寸:按 kind 的完整按钮集合估算(含「改选」chip;编辑展开时 chip 让位)。
    /// 若某回调为 nil,实际渲染会窄于估算——工具条右缘略缩进,
    /// 只是视觉右对齐略松,不影响「不相交/不出屏」保证。
    static func estimatedSize(for kind: MiniToolbarKind, editExpanded: Bool = false) -> CGSize {
        let narrow = Metrics.estimatedButtonContentWidth + Metrics.buttonPaddingH * 2
        let wide = Metrics.estimatedWideButtonContentWidth + Metrics.buttonPaddingH * 2
        let chip = Metrics.switchChipContentWidth + Metrics.paddingH * 2 + Metrics.switchChipGap
        let width: CGFloat
        switch kind {
        case .text:  // [改选图片] [翻译][可视化]
            width = chip + Metrics.paddingH * 2 + narrow + Metrics.hairline + wide
        case .image where editExpanded: // [编辑][指令输入][↑](chip 隐藏)
            width = Metrics.paddingH * 2 + narrow + Metrics.hairline
                + Metrics.editFieldLeadingGap + Metrics.editFieldWidth + Metrics.editSubmitWidth
        case .image: // [改选文字] [翻译][可视化][编辑]
            width = chip + Metrics.paddingH * 2 + narrow * 2 + Metrics.hairline * 2 + wide
        }
        return CGSize(width: width, height: Metrics.height)
    }

    /// 摆位纯函数。坐标系 = 覆盖层点坐标(左上原点),返回工具条 top-left origin。
    ///
    /// 候选顺序:
    /// 1. 选区**右下外侧**:gap 10pt,右对齐选区右缘,水平 clamp 进屏(margin 8)。
    ///    框体整体在选区之下,水平 clamp 不会造成相交。
    /// 2. 垂直放不下 → **翻到上方外侧**(同样右对齐 + 水平 clamp)。
    /// 3. 上下都放不下(高选区贴满上下,垂直 clamp 必然相交)→ 退化到
    ///    **选区右侧外**(gap 10,垂直居中,垂直 clamp 进屏)。
    /// 4. 右侧也出屏(高选区又贴右缘)→ 镜像到**左侧外**。
    /// 5. 全屏级大选区四个方向都无处可放,「不相交」与「不出屏」数学上不可兼得;
    ///    以**不出屏**为最高优先,压在选区右下角内侧(完整可见、可点)。
    static func placement(selection: CGRect, canvas: CGSize, size: CGSize) -> CGPoint {
        let gap = Metrics.gap
        let margin = Metrics.screenMargin

        // clamp 进屏(margin 8);画布比工具条还小的极端情形退到 margin,绝不为负出屏。
        func clampedX(_ x: CGFloat) -> CGFloat {
            let maxX = canvas.width - margin - size.width
            guard maxX >= margin else { return margin }
            return min(max(x, margin), maxX)
        }
        func clampedY(_ y: CGFloat) -> CGFloat {
            let maxY = canvas.height - margin - size.height
            guard maxY >= margin else { return margin }
            return min(max(y, margin), maxY)
        }

        // 右对齐选区右缘,再水平 clamp 进屏(候选 1/2 共用)。
        let alignedX = clampedX(selection.maxX - size.width)

        // 候选 1:选区下方外侧。y >= selection.maxY + gap,任何水平位置都不会与选区相交。
        let belowY = selection.maxY + gap
        if belowY + size.height <= canvas.height - margin {
            return CGPoint(x: alignedX, y: belowY)
        }

        // 候选 2:翻到选区上方外侧。整体在选区之上,同样不可能相交。
        let aboveY = selection.minY - gap - size.height
        if aboveY >= margin {
            return CGPoint(x: alignedX, y: aboveY)
        }

        // 候选 3:选区右侧外,垂直居中(垂直 clamp;框体在选区之右,不相交)。
        let sideY = clampedY(selection.midY - size.height / 2)
        let rightX = selection.maxX + gap
        if rightX + size.width <= canvas.width - margin {
            return CGPoint(x: rightX, y: sideY)
        }

        // 候选 4:镜像到选区左侧外。
        let leftX = selection.minX - gap - size.width
        if leftX >= margin {
            return CGPoint(x: leftX, y: sideY)
        }

        // 兜底:全屏级大选区,无法不相交;保证不出屏,贴选区右下角内侧。
        return CGPoint(x: clampedX(selection.maxX - size.width - margin),
                       y: clampedY(selection.maxY - size.height - margin))
    }
}

/// 摇头动画(经典「密码错误」水平抖动):phase 每 +1 摇三个来回(±5pt),
/// 整数静止位 sin = 0,动画结束自动归位无残余位移。
private struct ShakeEffect: GeometryEffect {
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(phase * .pi * 6) * 5, y: 0))
    }
}
