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
    /// 计算可见角标:`windows` front-to-back;逐窗裁进视口、右下角内缩 inset;
    /// 角标命中区(hitSize 方块)与任何**更前**窗口的 frame 相交 = 被遮挡,剔除。
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
            let occluded = windows[..<index].contains { $0.frame.intersects(hitRect) }
            guard !occluded else { continue }
            result.append(WindowCornerHandle(windowID: window.windowID,
                                             frame: clipped, corner: corner))
        }
        return result
    }
}
