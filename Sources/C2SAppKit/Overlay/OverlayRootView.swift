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
            scrim(size: size)
            brushCanvas(size: size)
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

    // MARK: - 笔刷描边:白 6pt round + 外圈 +6pt 白 20% 柔光 + 笔尖 8pt 白点

    private func brushCanvas(size: CGSize) -> some View {
        let points = viewModel.brushPoints
        return Canvas { context, _ in
            guard let tip = points.last else { return }
            if points.count > 1 {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(.white.opacity(0.2)),
                               style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                context.stroke(path, with: .color(.white),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8)),
                         with: .color(.white))
        }
        .frame(width: size.width, height: size.height)
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
        }
    }

    // MARK: - 可调矩形:accent 1.5pt 边框 + 四角把手 + 框外 10% 压暗

    @ViewBuilder private func rectOverlay(size: CGSize) -> some View {
        if let rect = viewModel.rectSelection {
            Canvas { context, _ in
                var dim = Path()
                dim.addRect(CGRect(origin: .zero, size: size))
                dim.addRect(rect)
                context.fill(dim, with: .color(.black.opacity(0.10)), style: FillStyle(eoFill: true))
                context.stroke(Path(rect), with: .color(Color.accentColor), lineWidth: 1.5)
                let corners = [
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                ]
                for c in corners {
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                                 with: .color(Color.accentColor))
                }
            }
            .frame(width: size.width, height: size.height)
        }
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
