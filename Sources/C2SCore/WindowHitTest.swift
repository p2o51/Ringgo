import CoreGraphics

/// 覆盖层窗口命中的纯模型(F20 整窗截图 / F24 窗口手柄)。
///
/// frame 已经是**覆盖层本地坐标**(左上原点)——换算在快照构建时经
/// `DisplayContext.overlayRect(fromCGGlobal:mainDisplayHeight:)` 一次完成,
/// 命中阶段只做纯几何。过滤规则(windowLayer==0、排除自家 PID、最小尺寸、
/// alpha>0)同样归快照构建方,这里只认给到的列表。
public struct PickableWindow: Sendable, Equatable {
    /// CGWindowID(与 SCWindow.windowID 对齐)。
    public let windowID: UInt32
    /// 覆盖层本地 frame(左上原点)。
    public let frame: CGRect
    public let title: String?
    public let ownerPID: Int32

    public init(windowID: UInt32, frame: CGRect, title: String?, ownerPID: Int32) {
        self.windowID = windowID
        self.frame = frame
        self.title = title
        self.ownerPID = ownerPID
    }
}

public enum WindowHitTest {
    /// 命中最上层窗口:`windows` 必须按 **front-to-back** 排序
    /// (真源 = CGWindowListCopyWindowInfo(.optionOnScreenOnly) 的文档保证序,
    /// 不赌 SCShareableContent.windows 的数组顺序,spec §8)。
    public static func topmost(at point: CGPoint, in windows: [PickableWindow]) -> PickableWindow? {
        windows.first { $0.frame.contains(point) }
    }
}

/// F24 v2(2026-07-17 用户拍板):**所有**可见窗口右下角常驻一枚「角标」手柄,
/// 不再只给悬停窗。被更前窗口遮住角的不画(角标会浮在别人内容上)。
public struct WindowCornerHandle: Sendable, Equatable {
    public let windowID: UInt32
    /// 窗口 frame 裁进视口后的矩形(覆盖层坐标;点角标 = 以它为选区)。
    public let frame: CGRect
    /// 角标锚点 = 裁剪后 frame 右下角**内缩 inset**(角形的外角顶点落在这)。
    public let corner: CGPoint

    public init(windowID: UInt32, frame: CGRect, corner: CGPoint) {
        self.windowID = windowID
        self.frame = frame
        self.corner = corner
    }
}

public enum WindowCornerHandles {
    /// 「够可见」门槛:窗口本体的可见占比低于它就不给角标。
    /// 2026-07-17 Ghostty 幽灵角标实测:窗口 97% 被盖住、只在别的窗口底边与
    /// Dock 之间露一条细缝时,「角没被挡」仍成立,角标看起来凭空浮着——
    /// 用户根本认不出那条缝属于谁。
    static let minVisibleFraction: CGFloat = 0.12

    /// 计算可见角标:`windows` front-to-back;逐窗裁进视口、右下角内缩 inset。
    /// 两道门槛:① 角标命中区(hitSize 方块)不被任何**更前**窗口盖住;
    /// ② 窗口本体可见占比 ≥ minVisibleFraction(8×6 网格采样)。
    public static func visible(in windows: [PickableWindow],
                               viewport: CGSize,
                               inset: CGFloat = 10,
                               hitSize: CGFloat = 22) -> [WindowCornerHandle] {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        let viewportRect = CGRect(origin: .zero, size: viewport)
        var result: [WindowCornerHandle] = []
        for (index, window) in windows.enumerated() {
            let clipped = window.frame.intersection(viewportRect)
            guard !clipped.isNull, clipped.width >= 60, clipped.height >= 44 else { continue }
            let corner = CGPoint(x: clipped.maxX - inset, y: clipped.maxY - inset)
            let hitRect = CGRect(x: corner.x - hitSize / 2, y: corner.y - hitSize / 2,
                                 width: hitSize, height: hitSize)
            let front = windows[..<index]
            guard !front.contains(where: { $0.frame.intersects(hitRect) }) else { continue }
            guard visibleFraction(of: clipped, front: front) >= Self.minVisibleFraction
            else { continue }
            result.append(WindowCornerHandle(windowID: window.windowID,
                                             frame: clipped, corner: corner))
        }
        return result
    }

    /// 可见占比近似:8×6 网格样点,不落在任何更前窗口内的算可见。
    /// 精确解要做矩形并集裁剪,采样对「残条 vs 半露」的分辨绰绰有余。
    static func visibleFraction(of rect: CGRect, front: ArraySlice<PickableWindow>) -> CGFloat {
        let cols = 8, rows = 6
        guard rect.width > 0, rect.height > 0 else { return 0 }
        var visibleCount = 0
        for i in 0..<cols {
            for j in 0..<rows {
                let p = CGPoint(x: rect.minX + rect.width * (CGFloat(i) + 0.5) / CGFloat(cols),
                                y: rect.minY + rect.height * (CGFloat(j) + 0.5) / CGFloat(rows))
                if !front.contains(where: { $0.frame.contains(p) }) {
                    visibleCount += 1
                }
            }
        }
        return CGFloat(visibleCount) / CGFloat(cols * rows)
    }
}
