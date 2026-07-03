import CoreGraphics

/// 把 OCR「行」(observation 级矩形,覆盖层坐标)几何聚类成 block。
///
/// 规则:两行属于同一 block ⇔ 存在一条链,链上相邻两行「垂直间距 ≤ ~1 行高」
/// 且「水平范围有实际重叠」。同 y 的左右两栏因水平不重叠而被物理隔离(修 ADV-8 双栏桥接)。
public enum BlockClusterer {

    /// - Parameter lineRects: 每个 OCR observation(一视觉行)的矩形,左上原点点坐标。
    /// - Returns: 与输入等长的 block 编号(按阅读顺序从 0 稳定编号)。
    public static func assignBlocks(lineRects: [CGRect],
                                    verticalGapFactor: CGFloat = 0.9,
                                    minHorizontalOverlapRatio: CGFloat = 0.25) -> [Int] {
        let n = lineRects.count
        guard n > 0 else { return [] }

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let medianH = Geometry.median(lineRects.map(\.height))

        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = lineRects[i], b = lineRects[j]
                // 垂直间距(相互重叠时为负,天然满足)
                let vGap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                let vThresh = max(4, verticalGapFactor * max(medianH, min(a.height, b.height)))
                guard vGap <= vThresh else { continue }
                // 水平重叠比例(相对较窄的一行);同 y 两栏 overlap<0 → 隔离
                let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                let minW = max(1, min(a.width, b.width))
                guard overlap / minW >= minHorizontalOverlapRatio else { continue }
                union(i, j)
            }
        }

        // block 编号按阅读顺序(y 优先、再 x)稳定化
        var idOfRoot: [Int: Int] = [:]
        let order = (0..<n).sorted {
            lineRects[$0].minY != lineRects[$1].minY
                ? lineRects[$0].minY < lineRects[$1].minY
                : lineRects[$0].minX < lineRects[$1].minX
        }
        for idx in order {
            let r = find(idx)
            if idOfRoot[r] == nil { idOfRoot[r] = idOfRoot.count }
        }
        return (0..<n).map { idOfRoot[find($0)]! }
    }
}
