import SwiftUI

/// 微光形态(由覆盖层根视图从选择状态派生;机制 §8 状态机)。
enum ShimmerPhase: Equatable {
    case idle                    // 全屏四点渐变游走
    case tracking(tip: CGPoint)  // 收敛为笔尖辉光(弹簧跟随)
    case ambient                 // 定格选区后:降饱和、降亮度
}

/// 全屏微光层(ui-style §4.2 品牌招牌):叠在截图与 scrim 之上,
/// `allowsHitTesting(false)` 由调用方加。单个 colorEffect shader 承担三态,
/// uniform 逐帧平滑过渡;tip/tipPoint 均为覆盖层点坐标(左上原点)。
struct ShimmerLayer: View {
    let phase: ShimmerPhase
    let size: CGSize
    /// 减弱动态:静态四点渐变(time 冻结、无 bloom、无跟随),纯透明度存在感。
    let reduceEffects: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 出现时刻:驱动 200ms 渐显 + 800ms bloom(ui-style §5)。
    @State private var appearedAt: Date?
    /// 每帧平滑器(引用类型:body 求值中更新不触发视图失效,由 TimelineView 供帧)。
    @State private var smoother = Smoother()

    /// 静态渐变时间冻结点(取一处四点分布均匀、观感舒服的时刻)。
    private static let frozenTime: Double = 6.0

    private var isStatic: Bool { reduceEffects || reduceMotion }

    var body: some View {
        // 尺寸退化(窗口尚未布局)时不渲染,避免 shader 除零
        if size.width >= 1, size.height >= 1 {
            TimelineView(.animation(paused: isStatic)) { context in
                shimmerRect(at: context.date)
            }
            .onAppear { appearedAt = Date() }
        }
    }

    // MARK: - 渲染

    private func shimmerRect(at date: Date) -> some View {
        let u = uniforms(at: date)
        return Rectangle()
            .fill(Color.white) // 画布底色无意义:shader 只取其 alpha
            .colorEffect(
                ShaderLibrary.bundle(.module).c2s_fourPointGradient(
                    .float2(size),
                    .float(u.time),
                    .float(u.tracking),
                    .float2(u.tip),
                    .float(u.saturation),
                    .float(u.opacity)
                )
            )
            .blendMode(.plusLighter)
            .frame(width: size.width, height: size.height)
    }

    // MARK: - uniform 派生

    private struct Uniforms {
        var time: Double
        var tracking: Double
        var tip: CGPoint
        var saturation: Double
        var opacity: Double
    }

    private func uniforms(at date: Date) -> Uniforms {
        // 各形态目标值(整体 opacity 全部 ≤ 0.5,叠在截图上要透)
        let targetTip: CGPoint?
        let targetTracking: Double
        let targetSaturation: Double
        let targetOpacity: Double
        switch phase {
        case .idle:
            targetTip = nil; targetTracking = 0; targetSaturation = 1.0; targetOpacity = 0.55
        case .tracking(let tip):
            targetTip = tip; targetTracking = 1; targetSaturation = 1.0; targetOpacity = 0.50
        case .ambient:
            targetTip = nil; targetTracking = 0; targetSaturation = 0.35; targetOpacity = 0.25
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        if isStatic {
            // 减弱动态:time 冻结、无 bloom、无跟随;仅按形态给饱和度与透明度
            return Uniforms(time: Self.frozenTime,
                            tracking: 0,
                            tip: center,
                            saturation: targetSaturation,
                            opacity: targetOpacity)
        }

        let elapsed = max(0, appearedAt.map { date.timeIntervalSince($0) } ?? 0)

        // 指数平滑(≈0.2/帧,按 60fps 归一)模拟弹簧跟随
        let s = smoother.step(now: date,
                              targetTip: targetTip,
                              fallbackTip: center,
                              targetTracking: targetTracking,
                              targetSaturation: targetSaturation,
                              targetOpacity: targetOpacity)

        // 200ms ease-out 渐显
        let ramp = min(elapsed / 0.2, 1)
        let fadeIn = 1 - (1 - ramp) * (1 - ramp)
        // 出现后 ~0.8s 的 bloom 亮度脉冲(正弦包络,峰值 +30%),并入 opacity 交给 shader
        let bloom = elapsed < 0.8 ? sin(.pi * elapsed / 0.8) * 0.3 : 0

        return Uniforms(time: elapsed,
                        tracking: s.tracking,
                        tip: s.tip,
                        saturation: s.saturation,
                        opacity: s.opacity * fadeIn * (1 + bloom))
    }
}

/// 每帧指数平滑(模拟弹簧跟随)。引用类型:在 body 求值中原地更新,
/// 不经 @State setter,避免「渲染中改状态」告警;帧节奏由 TimelineView 保证。
private final class Smoother {
    struct Values {
        var tip: CGPoint
        var tracking: Double
        var saturation: Double
        var opacity: Double
    }

    private var tip: CGPoint?
    private var tracking: Double = 0
    private var saturation: Double = 1.0
    private var opacity: Double = 0.55
    private var lastStep: Date?

    func step(now: Date,
              targetTip: CGPoint?,
              fallbackTip: CGPoint,
              targetTracking: Double,
              targetSaturation: Double,
              targetOpacity: Double) -> Values {
        // lerp 系数 ~0.2/帧,按实际帧间隔对 60fps 归一(高刷/掉帧下手感一致)
        let dt = max(0, lastStep.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0))
        lastStep = now
        let k = 1 - pow(1 - 0.2, dt * 60)

        // 无跟随目标(idle/ambient)时 tip 原地保留,让辉光在原处展开/收拢
        var t = tip ?? targetTip ?? fallbackTip
        if let target = targetTip {
            t.x += (target.x - t.x) * k
            t.y += (target.y - t.y) * k
        }
        tip = t

        tracking += (targetTracking - tracking) * k
        saturation += (targetSaturation - saturation) * k
        opacity += (targetOpacity - opacity) * k
        return Values(tip: t, tracking: tracking, saturation: saturation, opacity: opacity)
    }
}
