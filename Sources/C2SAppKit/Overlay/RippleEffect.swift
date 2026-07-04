import SwiftUI

extension View {
    /// 出现时以 origin(覆盖层点坐标、左上原点)为中心播放一次涟漪(~1.1s);
    /// enabled=false 恒等返回(减弱动态下由调用方关闭)。
    func rippleOnAppear(origin: CGPoint, size: CGSize, enabled: Bool) -> some View {
        modifier(RippleOnAppear(origin: origin, size: size, enabled: enabled))
    }
}

/// 一次性出现涟漪(ui-style §5:1.0–1.2s 线性衰减,极轻,作用在截图上)。
private struct RippleOnAppear: ViewModifier {
    let origin: CGPoint
    let size: CGSize
    let enabled: Bool

    @State private var progress: Double = 0
    @State private var finished = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .modifier(RippleShader(progress: progress,
                                       origin: origin,
                                       amplitude: Self.amplitude(for: size),
                                       active: !finished))
                .onAppear {
                    // 线性驱动 0→1;播完置 finished,停用 layerEffect(恒等,不再采样)
                    withAnimation(.linear(duration: 1.1)) {
                        progress = 1
                    } completion: {
                        finished = true
                    }
                }
        } else {
            content
        }
    }

    /// 建议 ~12px;极小视图按短边 2% 收敛,避免位移比例失衡(上限受 maxSampleOffset=14 约束)
    private static func amplitude(for size: CGSize) -> Double {
        min(12.0, 0.02 * Double(min(size.width, size.height)))
    }
}

/// Animatable 载体:withAnimation 逐帧插值 animatableData,再喂给 shader uniform
/// (shader 浮点参数本身不参与 SwiftUI 动画插值,必须经 animatableData 驱动)。
private struct RippleShader: ViewModifier, Animatable {
    var progress: Double
    let origin: CGPoint
    let amplitude: Double
    let active: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.bundle(C2SResourceBundle.shared).c2s_ripple(
                .float2(origin),
                .float(progress),
                .float(amplitude),
                .float(14.0), // frequency:全程 ~2.2 个波峰
                .float(9.0)   // decay:progress=1 时 e⁻⁹ ≈ 0,自然收尾
            ),
            maxSampleOffset: CGSize(width: 14, height: 14),
            isEnabled: active && progress < 1
        )
    }
}
