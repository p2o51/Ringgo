import SwiftUI
import C2SCore

/// 覆盖层根视图(ui-style §4.1/4.3):冻结帧背景(显式 `.frame(点尺寸)`,
/// 禁止 `.aspectRatio(.fill)` —— 坐标 P0)+ scrim + 笔刷描边 + 词高亮 +
/// 泪滴手柄 + 可调矩形 + 底部结果面板。
struct OverlayRootView: View {
    let capture: CaptureResult
    @ObservedObject var viewModel: SelectionViewModel
    @ObservedObject var sheetModel: ResultSheetModel
    let reduceEffects: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let coordinateSpaceName = "c2s.overlay"

    var body: some View {
        let size = capture.context.pointSize
        ZStack(alignment: .topLeading) {
            background(size: size)
                // 出现涟漪(F14):以屏幕中心为源,一次 ~1.1s;减弱动态时禁用
                .rippleOnAppear(origin: CGPoint(x: size.width / 2, y: size.height / 2),
                                size: size,
                                enabled: !(reduceMotion || reduceEffects))
            scrim(size: size)
            // 四点渐变微光(F14):idle 全屏游走 → 笔刷时收敛笔尖 → 定格后 ambient
            ShimmerLayer(phase: shimmerPhase, size: size, reduceEffects: reduceEffects || reduceMotion)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            brushCanvas(size: size)
                .allowsHitTesting(false)
            hoverHint
                .allowsHitTesting(false)
            wordHighlights
                .allowsHitTesting(false)
            textHandles
                .allowsHitTesting(false)
            rectOverlay(size: size)
                .allowsHitTesting(false)
            interactionLayer(size: size)
            sheet
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.coordinateSpaceName)
    }

    /// 微光形态由选择状态派生(机制 §8 状态机:idle → tracking → ambient)。
    private var shimmerPhase: ShimmerPhase {
        switch viewModel.state {
        case .brushing:
            if let tip = viewModel.brushPoints.last { return .tracking(tip: tip) }
            return .idle
        case .textSelected, .rectSelection:
            return .ambient
        case .none:
            return .idle
        }
    }

    // MARK: - 背景(坐标 P0:像素与词框 1:1 对齐,靠显式点尺寸 frame)

    private func background(size: CGSize) -> some View {
        Image(decorative: capture.image, scale: capture.context.effectiveScaleX)
            .resizable()
            .frame(width: size.width, height: size.height)
    }

    // MARK: - scrim:黑 8% + 边缘极淡径向 vignette(合计 ~12%)

    private func scrim(size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.08)
            RadialGradient(colors: [.clear, Color.black.opacity(0.04)],
                           center: .center,
                           startRadius: min(size.width, size.height) * 0.35,
                           endRadius: max(size.width, size.height) * 0.7)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: - 笔刷描边:白芯 6pt + 双层柔光(accent 外晕 + 白内晕,呼应原版
    //          "中心偏白、边缘泛色"的荧光轨迹;用系统强调色而非写死蓝,保持 mac 生态)

    private func brushCanvas(size: CGSize) -> some View {
        let points = viewModel.brushPoints
        return Canvas { context, _ in
            guard let tip = points.last else { return }
            if points.count > 1 {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(Color.accentColor.opacity(0.16)),
                               style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(.white.opacity(0.22)),
                               style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(.white),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            // 笔尖:白点 + accent 光斑(bloom 感)
            context.fill(Path(ellipseIn: CGRect(x: tip.x - 9, y: tip.y - 9, width: 18, height: 18)),
                         with: .color(Color.accentColor.opacity(0.22)))
            context.fill(Path(ellipseIn: CGRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8)),
                         with: .color(.white))
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - 悬停预示(hover affordance,桌面端专属):
    //          指到词上 → 轻高亮预告「按下去选它」;比选中态淡一档,不喧宾

    @ViewBuilder private var hoverHint: some View {
        if let word = viewModel.hoveredWord {
            let r = word.rect.insetBy(dx: -2, dy: -2)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 1)
                )
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .animation((reduceMotion || reduceEffects) ? nil : .easeOut(duration: 0.08),
                           value: word.id)
        }
    }

    // MARK: - 词高亮:外扩 2pt、accent 35%、圆角 3、120ms ease 出现

    private var wordHighlights: some View {
        ZStack(alignment: .topLeading) {
            ForEach(viewModel.highlightedWords) { word in
                let r = word.rect.insetBy(dx: -2, dy: -2)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
        }
        .animation((reduceMotion || reduceEffects) ? nil : .easeOut(duration: 0.12),
                   value: viewModel.highlightedWords)
    }

    // MARK: - 泪滴手柄:首词左上朝上 / 末词右下朝下(命中检测在 ViewModel)

    @ViewBuilder private var textHandles: some View {
        if let anchors = viewModel.textHandleAnchors {
            ZStack(alignment: .topLeading) {
                TeardropHandle(pointsUp: true, anchor: anchors.start)
                TeardropHandle(pointsUp: false, anchor: anchors.end)
            }
            // 重选文字时手柄滑移到新位置;拖手柄本身时跟手零动画
            .animation((reduceMotion || reduceEffects || viewModel.isDraggingHandle)
                       ? nil
                       : .spring(response: 0.30, dampingFraction: 0.80),
                       value: viewModel.highlightedWords)
            .transition(.opacity)
        }
    }

    // MARK: - 可调矩形(2026-07-03 参照原版裁剪框重设计,ui-style §4.3):
    //          白色圆角四角括号 + 光谱辉光环(品牌时刻)+ 框外加重压暗聚焦

    private static let spectrum: [Color] = [
        Color(red: 0.259, green: 0.522, blue: 0.957),  // Blue
        Color(red: 0.918, green: 0.263, blue: 0.208),  // Red
        Color(red: 0.984, green: 0.737, blue: 0.020),  // Yellow
        Color(red: 0.204, green: 0.659, blue: 0.325),  // Green
        Color(red: 0.259, green: 0.522, blue: 0.957),  // 回到 Blue,角向渐变闭环
    ]

    @ViewBuilder private func rectOverlay(size: CGSize) -> some View {
        let motionReduced = reduceMotion || reduceEffects
        ZStack(alignment: .topLeading) {
            if let rect = viewModel.rectSelection {
                let bracket = rect.insetBy(dx: -3, dy: -3) // 括号略微外扩,不压住内容
                // 框外压暗(淡入即可,不参与弹入缩放)
                Canvas { context, _ in
                    var dim = Path()
                    dim.addRect(CGRect(origin: .zero, size: size))
                    dim.addRoundedRect(in: rect, cornerSize: CGSize(width: 10, height: 10))
                    context.fill(dim, with: .color(.black.opacity(0.16)), style: FillStyle(eoFill: true))
                }
                .frame(width: size.width, height: size.height)
                .transition(.opacity)

                // 光谱环 + 玻璃括号:生成时从框中心弹入(spring 缩放 + 淡入,原版"形态转化"一拍)
                ZStack(alignment: .topLeading) {
                    spectrumRing(bracket, motionReduced: motionReduced)
                    glassBrackets(bracket)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .transition(motionReduced
                            ? .opacity
                            : .asymmetric(
                                insertion: .scale(scale: 1.07,
                                                  anchor: UnitPoint(x: rect.midX / size.width,
                                                                    y: rect.midY / size.height))
                                    .combined(with: .opacity),
                                removal: .opacity))
            }
        }
        // 出现/消失:弹入/淡出(value = 是否有框)
        .animation(motionReduced ? .easeOut(duration: 0.12)
                                 : .spring(response: 0.28, dampingFraction: 0.78),
                   value: viewModel.rectSelection != nil)
        // 重选(轻点别处出新框):旧框滑移变形过去;拖角/拖边调整时跟手零动画
        .animation((motionReduced || viewModel.isResizingRect)
                   ? nil
                   : .spring(response: 0.30, dampingFraction: 0.80),
                   value: viewModel.rectSelection)
    }

    /// 光谱辉光环:颜色沿边框持续流转(角向渐变旋转)+ 轻微呼吸;减弱动态 → 静态。
    @ViewBuilder private func spectrumRing(_ bracket: CGRect, motionReduced: Bool) -> some View {
        if motionReduced {
            ringShape(bracket, angle: .zero).opacity(0.5)
        } else {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ringShape(bracket, angle: .degrees((t * 24).truncatingRemainder(dividingBy: 360)))
                    .opacity(0.45 + 0.10 * sin(t * 1.6))
            }
        }
    }

    private func ringShape(_ bracket: CGRect, angle: Angle) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                AngularGradient(gradient: Gradient(colors: Self.spectrum),
                                center: .center,
                                angle: angle),
                lineWidth: 10)
            .blur(radius: 14)
            .frame(width: bracket.width + 10, height: bracket.height + 10)
            .offset(x: bracket.minX - 5, y: bracket.minY - 5)
    }

    // MARK: - 手势层(可视层全部 allowsHitTesting(false),手势统一从这里进状态机)

    private func interactionLayer(size: CGSize) -> some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                    .onChanged { value in
                        viewModel.dragChanged(location: value.location, start: value.startLocation)
                    }
                    .onEnded { value in
                        viewModel.dragEnded(location: value.location, start: value.startLocation)
                    }
            )
            .onContinuousHover(coordinateSpace: .named(Self.coordinateSpaceName)) { phase in
                switch phase {
                case .active(let p): viewModel.hoverLocation = p
                case .ended: viewModel.hoverLocation = nil
                }
            }
    }

    // MARK: - 底部结果面板(hidden 时不拦点击;非 hidden 时其区域手势归面板)

    private var sheet: some View {
        let hidden: Bool = {
            if case .hidden = sheetModel.content { return true }
            return false
        }()
        return ResultSheetView(model: sheetModel, reduceEffects: reduceEffects)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(!hidden)
    }
}

extension OverlayRootView {
    /// 四角括号手柄:粗臂(7pt)+ Liquid Glass 本体(macOS 26+;旧系统回退薄材质),
    /// 外缘一圈 45% 白描边保证任意背景下可读,再垫极轻投影。
    @ViewBuilder func glassBrackets(_ rect: CGRect) -> some View {
        let stroked = StrokedBracketsShape(rect: rect, lineWidth: 7)
        Group {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: stroked)
            } else {
                stroked.fill(.ultraThinMaterial)
            }
        }
        .overlay(stroked.stroke(Color.white.opacity(0.45), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.28), radius: 3)
        .allowsHitTesting(false)
    }
}

/// 括号的描边轮廓面(粗臂圆头):把 L 形路径转成可填充/上玻璃的闭合形状。
private struct StrokedBracketsShape: Shape {
    let rect: CGRect
    let lineWidth: CGFloat

    func path(in r: CGRect) -> Path {
        CornerBracketsShape(rect: rect)
            .path(in: r)
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

/// 四角括号(原版裁剪框语汇):每角一条「臂-圆角-臂」的 L 形路径,
/// 臂长/圆角随选框尺寸自适应(小框不塌)。rect 为括号外接矩形(覆盖层坐标)。
private struct CornerBracketsShape: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        let arm = min(32, rect.width / 3.2, rect.height / 3.2)
        let r = min(15, arm * 0.55)
        var p = Path()
        // 左上
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + arm))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + arm, y: rect.minY))
        // 右上
        p.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // 右下
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - arm))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - arm, y: rect.maxY))
        // 左下
        p.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return p
    }
}

/// 泪滴手柄(ui-style §4.3):accent 实心,圆头半径 5、杆宽 2.5、总高 20。
/// anchor = 词角点;朝上时形状在锚点上方(圆头在顶),朝下时在锚点下方(圆头在底)。
private struct TeardropHandle: View {
    let pointsUp: Bool
    let anchor: CGPoint

    private static let width: CGFloat = 10
    private static let height: CGFloat = 20

    var body: some View {
        TeardropShape(pointsUp: pointsUp)
            .fill(Color.accentColor)
            .frame(width: Self.width, height: Self.height)
            .offset(x: anchor.x - Self.width / 2,
                    y: pointsUp ? anchor.y - Self.height : anchor.y)
    }

    private struct TeardropShape: Shape {
        let pointsUp: Bool

        func path(in rect: CGRect) -> Path {
            let headDiameter: CGFloat = 10
            let stemWidth: CGFloat = 2.5
            var p = Path()
            let stem = CGSize(width: stemWidth / 2, height: stemWidth / 2)
            if pointsUp {
                p.addEllipse(in: CGRect(x: rect.midX - headDiameter / 2, y: rect.minY,
                                        width: headDiameter, height: headDiameter))
                p.addRoundedRect(in: CGRect(x: rect.midX - stemWidth / 2, y: rect.minY + headDiameter / 2,
                                            width: stemWidth, height: rect.height - headDiameter / 2),
                                 cornerSize: stem)
            } else {
                p.addRoundedRect(in: CGRect(x: rect.midX - stemWidth / 2, y: rect.minY,
                                            width: stemWidth, height: rect.height - headDiameter / 2),
                                 cornerSize: stem)
                p.addEllipse(in: CGRect(x: rect.midX - headDiameter / 2, y: rect.maxY - headDiameter,
                                        width: headDiameter, height: headDiameter))
            }
            return p
        }
    }
}
