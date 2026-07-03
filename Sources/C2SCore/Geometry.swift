import CoreGraphics

/// 纯几何工具。所有坐标均为「覆盖层点坐标,左上原点」。
/// 与 docs/reference/SelectionEngine.reference.swift 中已验证实现保持一致。
public enum Geometry {

    @inlinable
    public static func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }

    /// 线段 ab 与线段 cd 是否相交(严格相交;共线端点接触不算,与参考实现一致)。
    @inlinable
    public static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let d1 = cross(c, d, a), d2 = cross(c, d, b)
        let d3 = cross(a, b, c), d4 = cross(a, b, d)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }

    /// 单条线段是否触碰矩形(端点在矩形内,或与四边任一相交)。
    public static func segmentIntersectsRect(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> Bool {
        if r.contains(a) || r.contains(b) { return true }
        let tl = CGPoint(x: r.minX, y: r.minY), tr = CGPoint(x: r.maxX, y: r.minY)
        let br = CGPoint(x: r.maxX, y: r.maxY), bl = CGPoint(x: r.minX, y: r.maxY)
        return segmentsIntersect(a, b, tl, tr) || segmentsIntersect(a, b, tr, br)
            || segmentsIntersect(a, b, br, bl) || segmentsIntersect(a, b, bl, tl)
    }

    /// 折线是否触碰矩形(任一顶点在矩形内,或任一线段与矩形相交)。
    public static func pathIntersectsRect(_ points: [CGPoint], _ r: CGRect) -> Bool {
        for p in points where r.contains(p) { return true }
        guard points.count > 1 else { return false }
        for i in 0..<(points.count - 1) {
            if segmentIntersectsRect(points[i], points[i + 1], r) { return true }
        }
        return false
    }

    /// 中位数(与参考实现相同的取法:sorted()[count/2])。
    public static func median(_ values: [CGFloat]) -> CGFloat {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    public static func boundingBox(of points: [CGPoint]) -> CGRect? {
        guard let f = points.first else { return nil }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
