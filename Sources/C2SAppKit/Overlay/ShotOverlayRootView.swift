import SwiftUI
import C2SCore

/// F20 截图模式覆盖层根视图(spec S1,与 OverlayRootView 平行的精简版):
/// 冻结帧 → 压暗(悬停窗口/marquee 挖亮)→ 白框 + W×H 像素标签 → 底部提示 → 闪白。
/// 手势范式与圈选一致:可视层全部 allowsHitTesting(false),手势统一走 interactionLayer。
struct ShotOverlayRootView: View {
    let capture: CaptureResult
    @ObservedObject var viewModel: ShotSelectionViewModel
    let reduceEffects: Bool

    @State private var flashOpacity: Double = 0

    private static let coordinateSpaceName = "c2s.shotOverlay"

    var body: some View {
        let size = capture.context.pointSize
        ZStack(alignment: .topLeading) {
            background(size: size)
            dimLayer(size: size)
                .allowsHitTesting(false)
            selectionChrome(size: size)
                .allowsHitTesting(false)
            interactionLayer(size: size)
            hintPill(size: size)
                .allowsHitTesting(false)
            Color.white
                .opacity(flashOpacity)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onChange(of: viewModel.flashing) { _, isFlashing in
            guard isFlashing else { return }
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.22)) { flashOpacity = 0 }
        }
    }

    private func background(size: CGSize) -> some View {
        Image(decorative: capture.image, scale: capture.context.effectiveScaleX)
            .resizable()
            .frame(width: size.width, height: size.height)
    }

    /// 压暗 + 挖亮:even-odd 填充,亮区 = marquee(优先)或悬停窗口。
    private func dimLayer(size: CGSize) -> some View {
        Canvas { ctx, _ in
            var path = Path(CGRect(origin: .zero, size: size))
            if let cutout = activeCutout {
                path.addRoundedRect(in: cutout,
                                    cornerSize: CGSize(width: cutoutRadius, height: cutoutRadius))
            }
            ctx.fill(path, with: .color(.black.opacity(0.32)), style: FillStyle(eoFill: true))
        }
        .frame(width: size.width, height: size.height)
    }

    private var activeCutout: CGRect? {
        viewModel.marquee ?? viewModel.hoveredWindowDisplayFrame
    }

    private var cutoutRadius: CGFloat {
        viewModel.marquee != nil ? 2 : 9
    }

    /// 白框 + 阴影 + 尺寸标签(像素,按 DisplayContext 真实比值换算)。
    @ViewBuilder
    private func selectionChrome(size: CGSize) -> some View {
        if let rect = activeCutout {
            RoundedRectangle(cornerRadius: cutoutRadius, style: .continuous)
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
                .offset(x: rect.minX, y: rect.minY)

            let px = Int((rect.width * capture.context.effectiveScaleX).rounded())
            let py = Int((rect.height * capture.context.effectiveScaleY).rounded())
            Text(verbatim: "\(px) × \(py)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.65), in: Capsule())
                .offset(x: max(4, min(rect.maxX - 64, size.width - 88)),
                        y: min(rect.maxY + 8, size.height - 26))
        }
    }

    /// 底部操作提示(拖拽中隐藏)。
    @ViewBuilder
    private func hintPill(size: CGSize) -> some View {
        if viewModel.marquee == nil && !viewModel.flashing {
            Text(L10n.t("shot.hint", "拖拽截取区域 · 点击截取窗口 · ⏎ 全屏 · Esc 取消"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.55), in: Capsule())
                .frame(width: size.width, alignment: .center)
                .offset(y: size.height - 56)
        }
    }

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
                case .active(let p): viewModel.hoverPoint = p
                case .ended: viewModel.hoverPoint = nil
                }
            }
    }
}
