import CoreGraphics
import Foundation

/// F22 标注颜色(纯值类型,零 AppKit;UI 侧与 NSColor/Color 互转)。
public struct AnnotationColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// 色板预设(spec S4:品牌四色 + 黑白;默认红)。
    public static let presetRed = AnnotationColor(red: 0.918, green: 0.263, blue: 0.208)
    public static let presetYellow = AnnotationColor(red: 0.984, green: 0.737, blue: 0.020)
    public static let presetGreen = AnnotationColor(red: 0.204, green: 0.659, blue: 0.325)
    public static let presetBlue = AnnotationColor(red: 0.259, green: 0.522, blue: 0.957)
    public static let presetBlack = AnnotationColor(red: 0, green: 0, blue: 0)
    public static let presetWhite = AnnotationColor(red: 1, green: 1, blue: 1)
}

/// F22 单笔标注(spec S4 矢量对象模型)。
///
/// **坐标真源 = 图像像素空间、左上原点**(spec「导出保真」):线宽、字号、
/// 马赛克块、圆角一律以原图像素定义,预览按缩放比显示——否则 5K 图导出
/// 会和预览不一致(马赛克粒度最明显)。
public struct AnnotationObject: Identifiable, Sendable, Equatable {

    public enum Shape: Sendable, Equatable {
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        /// filled = 实心框(否则空心描边)。
        case rect(CGRect, filled: Bool)
        case ellipse(CGRect)
        /// 自由画笔(已抽稀折线)。
        case pen([CGPoint])
        /// origin = 文本框左上角(像素);fontSize 像素。
        case text(String, origin: CGPoint, fontSize: CGFloat)
        /// 马赛克矩形(块大小随线宽档,渲染器决定)。
        case mosaic(CGRect)
        /// 聚光高亮:全图压暗、本矩形保持原亮(多枚取并集)。
        case spotlight(CGRect)
        /// 自增序号圆标。
        case counter(center: CGPoint, number: Int)
    }

    public let id: UUID
    public var shape: Shape
    public var color: AnnotationColor
    /// 像素线宽(粗细三档 × 图像 scale 后的值)。
    public var lineWidth: CGFloat

    public init(id: UUID = UUID(), shape: Shape, color: AnnotationColor, lineWidth: CGFloat) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// F22 标注文档(纯模型,可单测;UndoManager/工具状态在 AppKit 侧包装)。
public struct AnnotationDocument: Sendable, Equatable {
    public var objects: [AnnotationObject] = []
    /// 非破坏裁剪(像素;nil = 全图)。
    public var cropRect: CGRect?
    /// 原图像素尺寸(几何钳制与压平画布)。
    public let pixelSize: CGSize

    public init(pixelSize: CGSize) {
        self.pixelSize = pixelSize
    }

    // MARK: 增删改

    public mutating func add(_ object: AnnotationObject) {
        objects.append(object)
    }

    @discardableResult
    public mutating func remove(id: UUID) -> AnnotationObject? {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return nil }
        return objects.remove(at: index)
    }

    public mutating func update(_ object: AnnotationObject) {
        guard let index = objects.firstIndex(where: { $0.id == object.id }) else { return }
        objects[index] = object
    }

    public func object(id: UUID) -> AnnotationObject? {
        objects.first { $0.id == id }
    }

    /// 下一枚序号(自增:现存最大 + 1)。
    public var nextCounterNumber: Int {
        let numbers = objects.compactMap { obj -> Int? in
            if case .counter(_, let n) = obj.shape { return n }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: 命中(选择工具;从最上层——最后画的——往下找)

    /// tolerance:命中容差(像素;UI 按当前缩放换算传入,保证屏幕手感一致)。
    public func hitTest(at p: CGPoint, tolerance: CGFloat) -> UUID? {
        for object in objects.reversed() where hits(object, at: p, tolerance: tolerance) {
            return object.id
        }
        return nil
    }

    private func hits(_ object: AnnotationObject, at p: CGPoint, tolerance: CGFloat) -> Bool {
        let tol = max(tolerance, object.lineWidth / 2 + tolerance / 2)
        switch object.shape {
        case .line(let a, let b), .arrow(let a, let b):
            return Geometry.distance(from: p, toSegment: (a, b)) <= tol
        case .rect(let r, let filled):
            if filled { return r.insetBy(dx: -tol, dy: -tol).contains(p) }
            return nearRectBorder(r, point: p, tolerance: tol)
        case .ellipse(let r):
            return nearRectBorder(r, point: p, tolerance: tol) // 椭圆按外接框近似(手感足够)
        case .pen(let points):
            guard points.count > 1 else {
                return points.first.map { hypot(p.x - $0.x, p.y - $0.y) <= tol } ?? false
            }
            for i in 1..<points.count
            where Geometry.distance(from: p, toSegment: (points[i - 1], points[i])) <= tol {
                return true
            }
            return false
        case .text(let string, let origin, let fontSize):
            let size = AnnotationTextMetrics.size(of: string, fontSize: fontSize)
            return CGRect(origin: origin, size: size).insetBy(dx: -tol, dy: -tol).contains(p)
        case .mosaic(let r), .spotlight(let r):
            return r.insetBy(dx: -tol, dy: -tol).contains(p)
        case .counter(let center, _):
            let radius = AnnotationRenderer.counterRadius(lineWidth: object.lineWidth)
            return hypot(p.x - center.x, p.y - center.y) <= radius + tol
        }
    }

    private func nearRectBorder(_ r: CGRect, point p: CGPoint, tolerance: CGFloat) -> Bool {
        let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
        let inner = r.insetBy(dx: tolerance, dy: tolerance)
        if inner.width <= 0 || inner.height <= 0 { return outer.contains(p) }
        return outer.contains(p) && !inner.contains(p)
    }

    // MARK: 位移(选择工具拖动)

    public mutating func move(id: UUID, by delta: CGVector) {
        guard var object = object(id: id) else { return }
        object.shape = Self.translated(object.shape, by: delta)
        update(object)
    }

    static func translated(_ shape: AnnotationObject.Shape, by d: CGVector) -> AnnotationObject.Shape {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        func t(_ r: CGRect) -> CGRect { r.offsetBy(dx: d.dx, dy: d.dy) }
        switch shape {
        case .line(let a, let b): return .line(from: t(a), to: t(b))
        case .arrow(let a, let b): return .arrow(from: t(a), to: t(b))
        case .rect(let r, let filled): return .rect(t(r), filled: filled)
        case .ellipse(let r): return .ellipse(t(r))
        case .pen(let points): return .pen(points.map(t))
        case .text(let s, let origin, let size): return .text(s, origin: t(origin), fontSize: size)
        case .mosaic(let r): return .mosaic(t(r))
        case .spotlight(let r): return .spotlight(t(r))
        case .counter(let c, let n): return .counter(center: t(c), number: n)
        }
    }

    /// 对象外接框(选中描边用;文本按实测尺寸)。
    public func boundingBox(of object: AnnotationObject) -> CGRect {
        switch object.shape {
        case .line(let a, let b), .arrow(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -object.lineWidth, dy: -object.lineWidth)
        case .rect(let r, _), .ellipse(let r), .mosaic(let r), .spotlight(let r):
            return r.insetBy(dx: -object.lineWidth / 2, dy: -object.lineWidth / 2)
        case .pen(let points):
            return (Geometry.boundingBox(of: points) ?? .zero)
                .insetBy(dx: -object.lineWidth, dy: -object.lineWidth)
        case .text(let s, let origin, let fontSize):
            return CGRect(origin: origin, size: AnnotationTextMetrics.size(of: s, fontSize: fontSize))
        case .counter(let center, _):
            let radius = AnnotationRenderer.counterRadius(lineWidth: object.lineWidth)
            return CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        }
    }
}
