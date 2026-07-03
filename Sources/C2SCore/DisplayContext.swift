import CoreGraphics

/// 单一坐标真源(P0):贯穿 抓屏 → 覆盖层 → OCR → 裁剪 全流程。
///
/// 三套坐标系:
///  - 覆盖层:点,左上原点(SwiftUI 视图坐标,窗口 = 抓取屏)
///  - Vision:归一化 0..1,左下原点
///  - CGImage:像素,左上原点
///
/// 纪律(核心机制 §5/§6):缩放只认这里的真实比值(废弃写死 ×2);
/// 活动屏只认一块(抓屏、覆盖层、换算全部同源)。
public struct DisplayContext: Sendable, Equatable {
    /// CGDirectDisplayID(用于 SCDisplay ↔ NSScreen 匹配与调试)。
    public let displayID: UInt32
    /// 抓取屏的全局 frame(AppKit 坐标,左下原点)——用于摆放覆盖层窗口。
    public let screenFrame: CGRect
    /// 屏幕点尺寸(= 该屏 NSScreen.frame.size)。
    public let pointSize: CGSize
    /// 截图像素尺寸(= 实际 CGImage 尺寸)。
    public let pixelSize: CGSize
    /// 该屏 backingScaleFactor(仅作记录;实际换算一律用 pixelSize/pointSize 真实比值)。
    public let scale: CGFloat

    public init(displayID: UInt32, screenFrame: CGRect, pointSize: CGSize, pixelSize: CGSize, scale: CGFloat) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        self.scale = scale
    }

    /// 实际横向换算比(以真实图像为准,不信任任何写死值)。
    public var effectiveScaleX: CGFloat {
        pointSize.width > 0 ? pixelSize.width / pointSize.width : scale
    }
    /// 实际纵向换算比。
    public var effectiveScaleY: CGFloat {
        pointSize.height > 0 ? pixelSize.height / pointSize.height : scale
    }

    /// Vision 归一化(左下原点)→ 覆盖层点(左上原点):唯一一次翻 Y。
    public func overlayRect(fromNormalized nb: CGRect) -> CGRect {
        CGRect(x: nb.origin.x * pointSize.width,
               y: (1 - nb.origin.y - nb.height) * pointSize.height,
               width: nb.width * pointSize.width,
               height: nb.height * pointSize.height)
    }

    /// 覆盖层点(左上)→ 图像像素(左上):纯缩放,无翻转;
    /// 夹进图像边界并取整,可直接用于 `CGImage.cropping(to:)`。
    /// 完全在图像外时返回 `.null`(调用方需检查)。
    public func pixelRect(fromOverlay r: CGRect) -> CGRect {
        let px = CGRect(x: r.origin.x * effectiveScaleX,
                        y: r.origin.y * effectiveScaleY,
                        width: r.width * effectiveScaleX,
                        height: r.height * effectiveScaleY)
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let clipped = px.intersection(bounds)
        return clipped.isNull ? .null : clipped.integral.intersection(bounds)
    }

    /// 全局点(AppKit 坐标,左下原点,如 NSEvent.mouseLocation)→ 覆盖层本地点(左上原点)。
    public func overlayPoint(fromGlobal p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX, y: screenFrame.maxY - p.y)
    }
}
