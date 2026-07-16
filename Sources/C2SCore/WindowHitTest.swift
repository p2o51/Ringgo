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
