import CoreGraphics

/// 选词引擎(纯逻辑、可单测)。
///
/// 选择规则 v3(2026-07-03 用户拍板,完全对齐谷歌 Circle to Search):
///   全屏词按视觉行聚成**一条全局阅读链**(行序 → 行内 x 序),
///   最终选区 = 链上 **[首个触碰词 … 末个触碰词] 的连续区间**。
///   一笔对角线斜穿段落/表格/多栏 → 选中两端之间的全部内容。
///
/// 与 v2 的差异(权衡已明示并被接受):v2 的「区间不跨 block」防住了
/// 跨窗口斜划的过度选择,但把表格(每个单元格一个 block)撕成碎片 ——
/// 表格/多栏一笔全选是刚需,跨窗口对角线全选是谷歌同款的可预期行为。
/// block 字段保留(物体吸附/HitRegion 备用),选择不再使用。
///
/// 行聚类用**局部阈值**(候选词高与行均高的较小值 × 0.6):
/// 大字号区域不会把邻近小字行熔成一行(混合字号鲁棒)。
/// 手柄扩展与笔刷共用同一条全局链,语义一致。
public final class SelectionEngine {

    public struct Config: Sendable {
        public var brushRadius: CGFloat
        public var tapSlop: CGFloat
        public init(brushRadius: CGFloat = 16, tapSlop: CGFloat = 4) {
            self.brushRadius = brushRadius
            self.tapSlop = tapSlop
        }
    }

    public let words: [OCRWord]
    public let config: Config

    /// 视觉行(翻译原位盖板等按行消费;rect = 行内词框并集,text = 阅读序拼装)。
    public struct VisualLine: Sendable, Equatable {
        public let rect: CGRect
        public let text: String
    }

    /// 全局阅读链(词索引,行序 → 行内 minX 序)。
    private let chain: [Int]
    /// 词 idx → 链上位置。
    private let chainPos: [Int]
    /// 词 idx → 行号(visualLines 下标)。
    private let lineOfWord: [Int]
    /// 全部视觉行(行序)。
    public let visualLines: [VisualLine]
    /// 区域(block)→ x 范围(参与判定用;block 由 OCR 侧几何聚类,天然不跨栏)。
    private let blockXRange: [Int: ClosedRange<CGFloat>]
    private let grid: SpatialGrid
    /// 手柄「同行带」阈值(全局词高中位数 × 0.6)。
    private let handleBandThreshold: CGFloat

    public init(words: [OCRWord], config: Config = Config()) {
        precondition(words.enumerated().allSatisfy { $0.offset == $0.element.id },
                     "SelectionEngine 要求 words[i].id == i")
        self.words = words
        self.config = config

        // 全局行聚类:按 midY 扫描;并线阈值 = 0.6 × min(候选词高, 行均高),下限 4pt。
        // 局部阈值使混合字号安全:100pt 标题不会把相邻 10pt 两行熔成一行。
        let sorted = words.indices.sorted { words[$0].rect.midY < words[$1].rect.midY }
        var lines: [[Int]] = []
        var cur: [Int] = []
        var curMidY: CGFloat = 0
        var curMeanH: CGFloat = 0
        for i in sorted {
            let midY = words[i].rect.midY
            let h = words[i].rect.height
            if cur.isEmpty {
                cur = [i]; curMidY = midY; curMeanH = h
                continue
            }
            let thr = max(4, 0.6 * min(h, curMeanH))
            if abs(midY - curMidY) <= thr {
                cur.append(i)
                let n = CGFloat(cur.count)
                curMidY = (curMidY * (n - 1) + midY) / n
                curMeanH = (curMeanH * (n - 1) + h) / n
            } else {
                lines.append(cur)
                cur = [i]; curMidY = midY; curMeanH = h
            }
        }
        if !cur.isEmpty { lines.append(cur) }

        var chain: [Int] = []
        var chainPos = Array(repeating: -1, count: words.count)
        var lineOfWord = Array(repeating: -1, count: words.count)
        var visualLines: [VisualLine] = []
        for lineWords in lines {
            let line = lineWords.sorted { words[$0].rect.minX < words[$1].rect.minX }
            let lineIndex = visualLines.count
            for (offset, wi) in line.enumerated() {
                chainPos[wi] = chain.count + offset
                lineOfWord[wi] = lineIndex
            }
            chain.append(contentsOf: line)
            let rect = line.dropFirst().reduce(words[line[0]].rect) { $0.union(words[$1].rect) }
            visualLines.append(VisualLine(rect: rect, text: Self.text(for: line.map { words[$0] })))
        }
        self.chain = chain
        self.chainPos = chainPos
        self.lineOfWord = lineOfWord
        self.visualLines = visualLines
        var blockXRange: [Int: ClosedRange<CGFloat>] = [:]
        for w in words {
            if let r = blockXRange[w.block] {
                blockXRange[w.block] = min(r.lowerBound, w.rect.minX)...max(r.upperBound, w.rect.maxX)
            } else {
                blockXRange[w.block] = w.rect.minX...w.rect.maxX
            }
        }
        self.blockXRange = blockXRange
        self.handleBandThreshold = max(4, Geometry.median(words.map { $0.rect.height }) * 0.6)
        // 网格存「已按笔刷半径外扩」的词框,候选查询时同样外扩
        self.grid = SpatialGrid(rects: words.map { $0.rect.insetBy(dx: -config.brushRadius, dy: -config.brushRadius) })
    }

    // MARK: - 触碰集

    /// 折线路径触碰到的词 id 集(词框按 brushRadius 外扩;触碰词永不丢的输入)。
    public func touchedWordIDs(alongPath points: [CGPoint]) -> Set<Int> {
        guard !points.isEmpty, !words.isEmpty, let bb = Geometry.boundingBox(of: points) else { return [] }
        let r = config.brushRadius
        var out = Set<Int>()
        for i in grid.candidates(near: bb.insetBy(dx: -r, dy: -r)) {
            if Geometry.pathIntersectsRect(points, words[i].rect.insetBy(dx: -r, dy: -r)) {
                out.insert(i)
            }
        }
        return out
    }

    /// 网格候选(BrushSession 增量热路径用)。
    func candidateIndices(near rect: CGRect) -> Set<Int> { grid.candidates(near: rect) }

    // MARK: - 选择规则 v4:参与区域 × 锚点区间填充(Android 同款文本选择语义)

    /// 笔画横向带的余量(= brushRadius + 8)。
    private var bandMargin: CGFloat { config.brushRadius + 8 }
    /// 区域「被带扫到」所需的最小 x 重叠:防止笔画略微越过栏间沟就把邻栏拉进来。
    private static let minRegionBandOverlap: CGFloat = 16

    /// 由路径点算笔画横向带 [minX-余量, maxX+余量]。
    public func horizontalBand(of points: [CGPoint]) -> ClosedRange<CGFloat>? {
        guard let first = points.first else { return nil }
        var lo = first.x, hi = first.x
        for p in points.dropFirst() { lo = min(lo, p.x); hi = max(hi, p.x) }
        return (lo - bandMargin)...(hi + bandMargin)
    }

    /// v4(2026-07-03,用户以侧栏实测拍板):
    ///   1. **参与区域** = 触碰词所在 block ∪ 横向带扫过(x 重叠 ≥16pt)的 block
    ///      —— 带的用途是**圈定哪些栏参与**,不再按词裁剪;
    ///   2. 选区 = 参与区域词构成的阅读链上 **[首触碰 … 末触碰] 整段区间**
    ///      —— 锚点语义:首行选到行尾、中间行整行、末行从行首选起(Android 同款)。
    ///   侧栏内斜划 = 侧栏整行填充、正文不进;表格对角线 = 两列都被带扫到,整表全选;
    ///   三栏正文划字 = 只有正文区域参与。band = nil 时全部区域参与。
    public func selection(fromTouched touched: Set<Int>,
                          horizontalBand band: ClosedRange<CGFloat>? = nil) -> [OCRWord] {
        let valid = touched.filter { $0 >= 0 && $0 < words.count }
        guard !valid.isEmpty else { return [] }

        var participating = Set(valid.map { words[$0].block })
        if let band {
            for (block, range) in blockXRange where !participating.contains(block) {
                let overlap = min(range.upperBound, band.upperBound) - max(range.lowerBound, band.lowerBound)
                if overlap >= Self.minRegionBandOverlap { participating.insert(block) }
            }
        } else {
            participating.formUnion(blockXRange.keys)
        }

        // 参与区域的词按全局链顺序抽出 → 锚点区间整段填充
        let filtered = chain.filter { participating.contains(words[$0].block) }
        var lo = Int.max, hi = -1
        for (pos, wi) in filtered.enumerated() where valid.contains(wi) {
            lo = min(lo, pos); hi = max(hi, pos)
        }
        guard hi >= lo else { return [] }
        return filtered[lo...hi].map { words[$0] }
    }

    /// 一次性批量笔刷选择(增量路径请用 BrushSession)。
    public func brushSelection(path points: [CGPoint]) -> [OCRWord] {
        selection(fromTouched: touchedWordIDs(alongPath: points),
                  horizontalBand: horizontalBand(of: points))
    }

    // MARK: - 轻点选词

    /// 点落在哪个词框(含 tapSlop 容差)就选哪个;重叠时取面积最小者。
    public func tappedWord(at p: CGPoint) -> OCRWord? {
        let slop = config.tapSlop
        let probe = CGRect(x: p.x, y: p.y, width: 0.5, height: 0.5)
        let hits = grid.candidates(near: probe).filter {
            words[$0].rect.insetBy(dx: -slop, dy: -slop).contains(p)
        }
        let best = hits.min {
            words[$0].rect.width * words[$0].rect.height < words[$1].rect.width * words[$1].rect.height
        }
        return best.map { words[$0] }
    }

    // MARK: - 手柄扩展(与笔刷共用同一条全局链)

    /// 手柄扩展 = 与笔刷同一套 v4 语义:带 = 两锚词的 x 跨度,
    /// 参与区域随拖动自然增减(拖进邻栏才把邻栏拉进来)。
    public func extendedSelection(anchorID: Int, targetID: Int) -> [OCRWord]? {
        guard anchorID >= 0, targetID >= 0, anchorID < words.count, targetID < words.count else { return nil }
        let a = words[anchorID].rect, t = words[targetID].rect
        let band = (min(a.minX, t.minX) - bandMargin)...(max(a.maxX, t.maxX) + bandMargin)
        let result = selection(fromTouched: [anchorID, targetID], horizontalBand: band)
        return result.isEmpty ? nil : result
    }

    /// 手柄拖拽时找目标词:优先「与 p 同一行带」中水平最近;带空则全局最近。
    /// block 参数保留兼容旧调用方,v3 不再使用(全局链)。
    public func handleTarget(near p: CGPoint, inBlock block: Int = 0) -> OCRWord? {
        guard !words.isEmpty else { return nil }
        let band = words.indices.filter { abs(words[$0].rect.midY - p.y) <= handleBandThreshold * 1.5 }
        if band.isEmpty {
            return words.indices.min {
                hypot(words[$0].rect.midX - p.x, words[$0].rect.midY - p.y)
                    < hypot(words[$1].rect.midX - p.x, words[$1].rect.midY - p.y)
            }.map { words[$0] }
        }
        return band.min { abs(words[$0].rect.midX - p.x) < abs(words[$1].rect.midX - p.x) }.map { words[$0] }
    }

    // MARK: - 矩形选区

    /// 矩形内的词(词中心落在矩形内),按阅读序返回。
    /// 注:v3 起矩形选区一律路由图搜,此 API 保留给测试与未来用途。
    public func words(inRect r: CGRect) -> [OCRWord] {
        grid.candidates(near: r)
            .filter { r.contains(CGPoint(x: words[$0].rect.midX, y: words[$0].rect.midY)) }
            .sorted { chainPos[$0] < chainPos[$1] }
            .map { words[$0] }
    }

    // MARK: - 选区 → 行片段(选中文字翻译等按行消费)

    /// 把一组选中词按视觉行分组:每行返回「该行内选中片段」的并集框与阅读序文本。
    public func lineFragments(for selection: [OCRWord]) -> [VisualLine] {
        var byLine: [Int: [OCRWord]] = [:]
        for w in selection where w.id >= 0 && w.id < lineOfWord.count {
            byLine[lineOfWord[w.id], default: []].append(w)
        }
        return byLine.sorted { $0.key < $1.key }.map { _, ws in
            let ordered = ws.sorted { chainPos[$0.id] < chainPos[$1.id] }
            let rect = ordered.dropFirst().reduce(ordered[0].rect) { $0.union($1.rect) }
            return VisualLine(rect: rect, text: Self.text(for: ordered))
        }
    }

    // MARK: - 文本拼装

    /// 选区 → 查询串:空格连接;相邻两侧都是 CJK 时不插空格。
    public static func text(for selection: [OCRWord]) -> String {
        var out = ""
        for w in selection {
            if out.isEmpty { out = w.text; continue }
            let lastCJK = out.unicodeScalars.last.map(isCJK) ?? false
            let firstCJK = w.text.unicodeScalars.first.map(isCJK) ?? false
            out += (lastCJK && firstCJK) ? w.text : " " + w.text
        }
        return out
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2E80...0x303F,   // CJK 部首/符号
             0x3040...0x30FF,   // 假名
             0x3400...0x9FFF,   // CJK 统一表意
             0xF900...0xFAFF,   // 兼容表意
             0xFF00...0xFF60:   // 全角形式
            return true
        default:
            return false
        }
    }
}

/// 一次笔刷手势的增量会话:只测新增 path 段、缓存已触碰词,
/// 避免每帧 O(词×path段) 在长划后半程二次增长(机制 §6-6 热路径性能)。
public final class BrushSession {
    private let engine: SelectionEngine
    public private(set) var points: [CGPoint] = []
    public private(set) var touched: Set<Int> = []

    public init(engine: SelectionEngine) {
        self.engine = engine
    }

    /// 追加一批新点,增量更新触碰集;返回最新选区。
    @discardableResult
    public func append(_ newPoints: [CGPoint]) -> [OCRWord] {
        let r = engine.config.brushRadius
        for p in newPoints {
            let prev = points.last
            points.append(p)
            var segBB = CGRect(x: p.x, y: p.y, width: 0, height: 0)
            if let q = prev {
                segBB = segBB.union(CGRect(x: q.x, y: q.y, width: 0, height: 0))
            }
            for i in engine.candidateIndices(near: segBB.insetBy(dx: -r, dy: -r)) where !touched.contains(i) {
                let wordRect = engine.words[i].rect.insetBy(dx: -r, dy: -r)
                let hit: Bool
                if let q = prev {
                    hit = Geometry.segmentIntersectsRect(q, p, wordRect)
                } else {
                    hit = wordRect.contains(p)
                }
                if hit { touched.insert(i) }
            }
        }
        return selection
    }

    public var selection: [OCRWord] {
        engine.selection(fromTouched: touched, horizontalBand: engine.horizontalBand(of: points))
    }
}
