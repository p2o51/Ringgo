import CoreGraphics

/// 词框空间网格索引:笔刷热路径的候选剔除(机制 §6 性能不变式)。
public struct SpatialGrid: Sendable {
    private let cellSize: CGFloat
    private let cells: [Int64: [Int]]

    public init(rects: [CGRect], cellSize: CGFloat = 96) {
        self.cellSize = cellSize
        var map: [Int64: [Int]] = [:]
        for (i, r) in rects.enumerated() where !r.isNull && !r.isInfinite {
            let x0 = Int((r.minX / cellSize).rounded(.down)), x1 = Int((r.maxX / cellSize).rounded(.down))
            let y0 = Int((r.minY / cellSize).rounded(.down)), y1 = Int((r.maxY / cellSize).rounded(.down))
            guard x1 >= x0, y1 >= y0 else { continue }
            for cx in x0...x1 {
                for cy in y0...y1 {
                    map[Self.key(cx, cy), default: []].append(i)
                }
            }
        }
        self.cells = map
    }

    private static func key(_ cx: Int, _ cy: Int) -> Int64 {
        (Int64(cx) << 32) | Int64(UInt32(bitPattern: Int32(cy)))
    }

    /// 与给定矩形可能相交的候选索引(超集;调用方再做精判)。
    public func candidates(near rect: CGRect) -> Set<Int> {
        guard !rect.isNull, !rect.isInfinite, rect.minX.isFinite, rect.minY.isFinite else { return [] }
        let x0 = Int((rect.minX / cellSize).rounded(.down)), x1 = Int((rect.maxX / cellSize).rounded(.down))
        let y0 = Int((rect.minY / cellSize).rounded(.down)), y1 = Int((rect.maxY / cellSize).rounded(.down))
        guard x1 >= x0, y1 >= y0 else { return [] }
        var out = Set<Int>()
        for cx in x0...x1 {
            for cy in y0...y1 {
                if let list = cells[Self.key(cx, cy)] { out.formUnion(list) }
            }
        }
        return out
    }
}
