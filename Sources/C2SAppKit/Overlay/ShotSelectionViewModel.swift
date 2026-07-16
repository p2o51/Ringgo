import AppKit
import SwiftUI
import C2SCore

/// F20 截图模式选取状态机(spec S1,与 SelectionViewModel **平行**、不塞 if):
/// 拖拽 = 区域(松手即拍);点击 = 整窗(落空不快门、覆盖层保持);⏎ = 全屏。
/// 阈值:位移 < 3pt 视为点击(spec 定值,非圈选的 4pt)。
@MainActor
final class ShotSelectionViewModel: ObservableObject {

    /// 拖拽中的 marquee(覆盖层点坐标;快门后保留到闪白结束)。
    @Published private(set) var marquee: CGRect?
    /// 悬停点(窗口高亮命中用)。
    @Published var hoverPoint: CGPoint?
    /// 会话级窗口快照(front-to-back;异步到达)。
    @Published var windows: [PickableWindow] = []
    /// 快门闪白触发信号(视图侧播放动画;减弱动态时不闪,spec §6)。
    @Published private(set) var flashing = false

    var onRegion: (CGRect) -> Void = { _ in }
    var onWindow: (PickableWindow) -> Void = { _ in }
    var onFullScreen: () -> Void = {}
    var reduceMotion = false

    private(set) var viewport: CGSize = .zero
    private var shutterFired = false

    /// spec S1:位移 < 3pt 视为点击。
    static let clickThreshold: CGFloat = 3

    func reset() {
        marquee = nil
        hoverPoint = nil
        windows = []
        flashing = false
        shutterFired = false
    }

    func prepare(viewport: CGSize) {
        self.viewport = viewport
    }

    /// 悬停窗口(拖拽中/快门后不再高亮)。
    var hoveredWindow: PickableWindow? {
        guard marquee == nil, !shutterFired, let p = hoverPoint else { return nil }
        return WindowHitTest.topmost(at: p, in: windows)
    }

    /// 高亮框显示用:窗口 frame 裁进视口。
    var hoveredWindowDisplayFrame: CGRect? {
        hoveredWindow?.frame.intersection(CGRect(origin: .zero, size: viewport))
    }

    // MARK: 手势(与圈选同一 interactionLayer 范式:视图层全部 hitTesting(false))

    func dragChanged(location: CGPoint, start: CGPoint) {
        guard !shutterFired else { return }
        hoverPoint = location
        if hypot(location.x - start.x, location.y - start.y) >= Self.clickThreshold {
            let rect = CGRect(x: min(start.x, location.x),
                              y: min(start.y, location.y),
                              width: abs(location.x - start.x),
                              height: abs(location.y - start.y))
            marquee = rect.intersection(CGRect(origin: .zero, size: viewport))
        }
    }

    func dragEnded(location: CGPoint, start: CGPoint) {
        guard !shutterFired else { return }
        if let rect = marquee, rect.width >= 1, rect.height >= 1 {
            fireShutter { [weak self] in self?.onRegion(rect) }
        } else if let win = WindowHitTest.topmost(at: location, in: windows) {
            fireShutter { [weak self] in self?.onWindow(win) }
        } else {
            // 点击落空(空桌面):不快门、覆盖层保持(spec S1,防误触)
            marquee = nil
        }
    }

    /// ⏎ = 当前屏全屏(键盘监听转发)。
    func fireFullScreen() {
        guard !shutterFired else { return }
        fireShutter { [weak self] in self?.onFullScreen() }
    }

    /// 快门时序:**立即交付**(产物参数当刻捕获,闪白期间按 Esc/热键也不丢图),
    /// 闪白只是视觉——覆盖层的延迟退场由 coordinator 负责;
    /// shutterFired 锁死一切再触发。
    private func fireShutter(_ deliver: @escaping () -> Void) {
        shutterFired = true
        if !reduceMotion { flashing = true }
        deliver()
    }
}
