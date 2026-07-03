import SwiftUI

/// 选区迷你工具条(features/ui-style:选中文字/图片后出现在选区尾部附近)。
/// 无输入框——搜索编辑在结果面板里;这里只有动作按钮:
/// .text → [复制][翻译],.image → [复制]。
/// 视觉:横排胶囊 + Liquid Glass 背板 + hairline 描边 + 轻投影;中性色,不用光谱色。
/// 摆位:调用方用 `estimatedSize(for:)` + `placement(selection:canvas:size:)` 计算
/// top-left origin(覆盖层点坐标,左上原点)后直接放置;出现动画在组件内部。
/// 触觉(Haptics.confirm)由调用方在回调里做,组件只回调。
struct SelectionMiniToolbar: View {
    let kind: MiniToolbarKind
    /// 选区翻译模式进行中 → 「翻译」按钮高亮(再点退出,面板回普通搜索)。
    var translateActive: Bool = false
    let reduceEffects: Bool
    var onCopy: () -> Void
    /// nil 或 kind == .image 时不显示翻译按钮。
    var onTranslate: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// onAppear 驱动一次的入场标记(scale 0.92→1 + 淡入;减弱动态 → 纯淡入)。
    @State private var appeared = false

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
    }

    private var motionReduced: Bool { reduceEffects || reduceMotion }

    // MARK: - Body

    var body: some View {
        // v2(2026-07-03):复制按钮移除(⌘C 直接复制文字/图片),只剩翻译
        HStack(spacing: 0) {
            if kind == .text, let onTranslate {
                toolbarButton(icon: "translate", title: "翻译",
                              action: onTranslate, highlighted: translateActive)
            }
        }
        .padding(.horizontal, Metrics.paddingH)
        .frame(height: Metrics.height)
        // 高亮 = 整个胶囊变 accent 实底(选中态语义);平时 = Liquid Glass。
        // 不在玻璃胶囊内部再塞高亮小胶囊 —— 双层药丸难看(2026-07-03 实测)。
        .background {
            if translateActive {
                Capsule().fill(Color.accentColor)
            }
        }
        .modifier(GlassWhenInactive(active: translateActive))
        .overlay(
            Capsule().strokeBorder(
                translateActive ? Color.white.opacity(0.25) : Color(nsColor: .separatorColor),
                lineWidth: Metrics.hairline)
        )
        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        .animation(motionReduced ? nil : .easeOut(duration: 0.12), value: translateActive)
        .scaleEffect(motionReduced || appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            let animation: Animation = motionReduced
                ? .easeOut(duration: 0.15)
                : .spring(response: 0.25, dampingFraction: 0.8)
            withAnimation(animation) { appeared = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("选区工具条")
    }

    // MARK: - 子视图

    /// 按钮 = SF 图标 + 小字,plain 风格,中性前景色(不着 accent,克制)。
    private func toolbarButton(icon: String, title: String,
                               action: @escaping () -> Void,
                               highlighted: Bool = false) -> some View {
        Button(action: action) {
            HStack(spacing: Metrics.iconTextSpacing) {
                Image(systemName: icon)
                    .font(.system(size: Metrics.fontSize, weight: .medium))
                Text(title)
                    .font(.system(size: Metrics.fontSize, weight: .medium))
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, Metrics.buttonPaddingH)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle()) // 整个按钮区域可点,不只文字
        }
        .buttonStyle(.plain)
        .accessibilityLabel(highlighted ? "\(title)(进行中,点按退出)" : title)
    }

    /// 按钮之间的 hairline 竖分隔线(留出上下空隙,不顶到胶囊边)。
    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Metrics.hairline)
            .padding(.vertical, 10)
    }

    // MARK: - 摆位(纯静态函数,调用方定位用)

    /// 估算尺寸:按 kind 的完整按钮集合估算(.text 含翻译按钮)。
    /// 若 .text 且 onTranslate == nil,实际渲染会窄于估算——工具条右缘略缩进,
    /// 只是视觉右对齐略松,不影响「不相交/不出屏」保证。
    static func estimatedSize(for kind: MiniToolbarKind) -> CGSize {
        let buttonWidth = Metrics.estimatedButtonContentWidth + Metrics.buttonPaddingH * 2
        let width: CGFloat
        switch kind {
        case .text:
            width = Metrics.paddingH * 2 + buttonWidth // v2:仅「翻译」一个按钮
        case .image:
            width = 0 // v2:图片选区无迷你条(复制走 ⌘C)
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


/// 非激活时才上玻璃背板(激活时是 accent 实底,叠玻璃会发灰)。
private struct GlassWhenInactive: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
        } else {
            content.toolbarGlass(in: Capsule())
        }
    }
}
