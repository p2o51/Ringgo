import SwiftUI
import C2SCore

/// 选择交互状态机(features F4/F6):笔刷(BrushSession 增量)/轻点选词/
/// 手柄扩展(同 block 链)/可调矩形。持有 SelectionEngine,发布高亮与选区。
@MainActor
final class SelectionViewModel: ObservableObject {

    // MARK: - 状态

    enum SelectionState {
        case none
        case brushing
        /// words 按阅读序;anchorID/endID 供手柄拖拽定位两端。
        case textSelected(words: [OCRWord], anchorID: Int, endID: Int)
        case rectSelection(rect: CGRect)
    }

    /// 可调矩形的把手(四角 + 四边)。
    enum RectHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
    }

    @Published private(set) var state: SelectionState = .none
    /// 笔刷折线(已抽稀,覆盖层点坐标)。
    @Published private(set) var brushPoints: [CGPoint] = []
    /// 当前高亮词(笔刷实时选区与定格选中共用)。
    @Published private(set) var highlightedWords: [OCRWord] = []

    // MARK: - 回调(OverlayWindowController 接线)

    var onTextSearch: (String) -> Void = { _ in }
    var onImageSearch: (CGRect) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    // MARK: - 内部

    private var engine: SelectionEngine?
    private var session: BrushSession?
    private var viewport: CGSize = .zero

    /// 一次拖动手势的角色,按起点命中决定,途中不变。
    private enum DragMode {
        /// 位移未过 tap 阈值,可能是轻点。
        case undecided
        case brush
        /// anchorID = 未被拖动那端的词(extendedSelection 的锚)。
        case handle(anchorID: Int)
        case rectResize(handle: RectHandle, original: CGRect)
    }
    private var dragMode: DragMode?

    private let tapThreshold: CGFloat = 4
    private let handleHitRadius: CGFloat = 20
    private let thinningDistance: CGFloat = 2
    private let tapRectSide: CGFloat = 160
    private let minRectSide: CGFloat = 40

    /// OCR 尚未完成时落地的手势:记下原始意图,词框到达后再定夺
    /// (点在词上 → 选词;划过词 → 文本选择;否则矩形 → 图搜)。
    /// 用户一旦手动调整矩形即视为「框」意图,pending 作废、永远图搜(v3)。
    private enum PendingGesture {
        case tap(CGPoint)
        case brush([CGPoint])
    }
    private var pendingGesture: PendingGesture?

    // MARK: - 生命周期(OverlayWindowController 调用)

    func prepare(viewport: CGSize) {
        self.viewport = viewport
    }

    /// 全量清理(present/dismiss 时)。engine 一并清空,防上一次抓屏的旧词串场。
    func reset() {
        state = .none
        brushPoints = []
        highlightedWords = []
        engine = nil
        session = nil
        dragMode = nil
        pendingGesture = nil
    }

    /// OCR 词框到达 → 重建引擎;若正在笔刷中,在新引擎上重放完整 path(= 全量重算)。
    func updateWords(_ words: [OCRWord]) {
        let newEngine = SelectionEngine(words: words)
        engine = newEngine
        switch state {
        case .brushing:
            let s = BrushSession(engine: newEngine)
            highlightedWords = s.append(brushPoints)
            session = s
        case .textSelected:
            // 旧选区的词 id 随旧引擎失效,清掉防串
            if case .handle = dragMode { dragMode = nil }
            clearSelection()
        case .rectSelection(let rect):
            // OCR 完成前落地的手势按原始意图定夺;已手动调整过矩形(pending 已清)则不再动
            resolvePendingGesture(fallbackRect: rect, engine: newEngine)
        case .none:
            break
        }
    }

    /// 词框到达后,把 OCR 期间落地的手势按真实词框重新定夺(v3):
    /// 点在词上 → 选词;划过词 → 文本选择;其余 → 维持矩形(图搜已/将由 route 发出)。
    private func resolvePendingGesture(fallbackRect: CGRect, engine: SelectionEngine) {
        guard let pending = pendingGesture else { return } // 无 pending = 矩形已定,不重复路由
        pendingGesture = nil
        switch pending {
        case .tap(let p):
            if let word = engine.tappedWord(at: p) {
                let selection = [word]
                state = .textSelected(words: selection, anchorID: word.id, endID: word.id)
                highlightedWords = selection
                onTextSearch(SelectionEngine.text(for: selection))
            } else {
                route(rect: fallbackRect)
            }
        case .brush(let path):
            let selection = engine.brushSelection(path: path)
            if let first = selection.first, let last = selection.last {
                state = .textSelected(words: selection, anchorID: first.id, endID: last.id)
                highlightedWords = selection
                onTextSearch(SelectionEngine.text(for: selection))
            } else {
                route(rect: fallbackRect)
            }
        }
    }

    /// 选中的文本(⌘C 复制用);仅文本选中态返回非空。
    var selectedText: String? {
        guard case .textSelected(let words, _, _) = state else { return nil }
        let text = SelectionEngine.text(for: words)
        return text.isEmpty ? nil : text
    }

    // MARK: - 视图取用的派生量

    /// 泪滴手柄锚点:首词左上 / 末词右下(选中态才有)。
    var textHandleAnchors: (start: CGPoint, end: CGPoint)? {
        guard case .textSelected(let words, _, _) = state,
              let first = words.first, let last = words.last else { return nil }
        return (CGPoint(x: first.rect.minX, y: first.rect.minY),
                CGPoint(x: last.rect.maxX, y: last.rect.maxY))
    }

    var rectSelection: CGRect? {
        guard case .rectSelection(let rect) = state else { return nil }
        return rect
    }

    // MARK: - 手势入口(OverlayRootView 的 DragGesture,覆盖层点坐标)

    func dragChanged(location: CGPoint, start: CGPoint) {
        if dragMode == nil {
            dragMode = beginDrag(at: start)
        }
        guard let mode = dragMode else { return }
        switch mode {
        case .undecided:
            guard hypot(location.x - start.x, location.y - start.y) >= tapThreshold else { return }
            // 一旦越过阈值，本次手势永久升级为笔刷；否则 dragEnded 仍会把它当轻点。
            dragMode = .brush
            beginBrush(from: start)
            appendBrushPoint(location)
        case .brush:
            appendBrushPoint(location)
        case .handle(let anchorID):
            updateHandleDrag(anchorID: anchorID, to: location)
        case .rectResize(let handle, let original):
            state = .rectSelection(rect: resize(original, handle: handle, to: clamp(location)))
        }
    }

    func dragEnded(location: CGPoint, start: CGPoint) {
        let mode = dragMode ?? .undecided
        dragMode = nil
        switch mode {
        case .undecided:
            handleTap(at: start)
        case .brush:
            finishBrush(at: location)
        case .handle:
            // 松手重发搜索
            if case .textSelected(let words, _, _) = state {
                onTextSearch(SelectionEngine.text(for: words))
            }
        case .rectResize:
            // 手动调整过 = 明确的「框」意图:pending 作废,永远图搜(v3 用户拍板)
            pendingGesture = nil
            if case .rectSelection(let rect) = state {
                route(rect: rect)
            }
        }
    }

    // MARK: - 起手判定

    private func beginDrag(at p: CGPoint) -> DragMode {
        switch state {
        case .textSelected(let words, _, _):
            guard let first = words.first, let last = words.last else { return .undecided }
            let startAnchor = CGPoint(x: first.rect.minX, y: first.rect.minY)
            let endAnchor = CGPoint(x: last.rect.maxX, y: last.rect.maxY)
            let dStart = hypot(p.x - startAnchor.x, p.y - startAnchor.y)
            let dEnd = hypot(p.x - endAnchor.x, p.y - endAnchor.y)
            if dStart <= handleHitRadius || dEnd <= handleHitRadius {
                // 拖起手柄 → 锚定末词;拖末手柄 → 锚定首词
                return dStart <= dEnd ? .handle(anchorID: last.id) : .handle(anchorID: first.id)
            }
            return .undecided
        case .rectSelection(let rect):
            if let handle = rectHandle(at: p, rect: rect) {
                return .rectResize(handle: handle, original: rect)
            }
            return .undecided
        case .none, .brushing:
            return .undecided
        }
    }

    // MARK: - 轻点

    /// 轻点语义(对齐原版 Circle to Search):轻点**永不退出覆盖层**,且**点哪都直接重新搜索**——
    /// 点文字 = 重新选区;点空白/图片 = 直接出新框(与点文字对称,无「先关面板」缓冲)。
    /// 退出只走 Esc / 再按一次热键;只想收面板用下拉或面板上的 ×。
    private func handleTap(at p: CGPoint) {
        if let word = engine?.tappedWord(at: p) {
            // 点到已选中的词:不新建搜索 —— 查询已在面板搜索框里,由用户编辑(F11 v2)
            if case .textSelected(let words, _, _) = state,
               words.contains(where: { $0.id == word.id }) {
                return
            }
            clearSelection()
            let selection = [word]
            state = .textSelected(words: selection, anchorID: word.id, endID: word.id)
            highlightedWords = selection
            onTextSearch(SelectionEngine.text(for: selection))
            return
        }
        // 空白/图片:以点为中心的可调矩形(夹进屏内)并按矩形路由
        clearSelection()
        let half = tapRectSide / 2
        let rect = clampRect(CGRect(x: p.x - half, y: p.y - half, width: tapRectSide, height: tapRectSide))
        state = .rectSelection(rect: rect)
        if engine == nil {
            pendingGesture = .tap(p) // OCR 未完成:词框到达后先看是否点在词上
        } else {
            route(rect: rect)
        }
    }

    // MARK: - 笔刷

    private func beginBrush(from start: CGPoint) {
        // 开始新笔刷:清旧选择/矩形(结果面板不动)
        clearSelection()
        state = .brushing
        brushPoints = [start]
        if let engine {
            let s = BrushSession(engine: engine)
            highlightedWords = s.append([start])
            session = s
        }
    }

    private func appendBrushPoint(_ p: CGPoint) {
        if let last = brushPoints.last,
           hypot(p.x - last.x, p.y - last.y) < thinningDistance { return } // 抽稀
        brushPoints.append(p)
        if let session {
            highlightedWords = session.append([p])
        }
    }

    private func finishBrush(at p: CGPoint) {
        appendBrushPoint(p)
        let path = brushPoints
        session = nil
        // 结束时用完整 path 重算(词框可能在笔刷中途更新过)
        let selection = engine?.brushSelection(path: path) ?? []
        brushPoints = []
        if let first = selection.first, let last = selection.last {
            state = .textSelected(words: selection, anchorID: first.id, endID: last.id)
            highlightedWords = selection
            onTextSearch(SelectionEngine.text(for: selection))
        } else {
            // 空触碰 → 笔画包围盒(外扩 8pt,最小 40×40)转可调矩形
            highlightedWords = []
            var rect = Geometry.boundingBox(of: path) ?? CGRect(origin: p, size: .zero)
            rect = atLeast(rect.insetBy(dx: -8, dy: -8), minW: minRectSide, minH: minRectSide)
            rect = clampRect(rect)
            state = .rectSelection(rect: rect)
            if engine == nil {
                pendingGesture = .brush(path) // OCR 未完成:词框到达后按真实触碰定夺
            } else {
                route(rect: rect)
            }
        }
    }

    // MARK: - 手柄拖拽(限定同 block 阅读链,由引擎保证)

    private func updateHandleDrag(anchorID: Int, to p: CGPoint) {
        guard let engine, anchorID >= 0, anchorID < engine.words.count else { return }
        let anchor = engine.words[anchorID]
        guard let target = engine.handleTarget(near: p, inBlock: anchor.block),
              let selection = engine.extendedSelection(anchorID: anchorID, targetID: target.id),
              !selection.isEmpty else { return }
        state = .textSelected(words: selection, anchorID: anchorID, endID: target.id)
        highlightedWords = selection
    }

    // MARK: - 矩形路由与调整

    /// 矩形选区一律图搜(2026-07-03 用户拍板,对齐原版 Circle to Search):
    /// 框一旦出现,不管怎么调整都是搜图 —— 框里有字也交给 Lens 自己识别,
    /// 绝不中途翻转成文字搜索(想搜文字用笔刷划词)。
    private func route(rect: CGRect) {
        onImageSearch(rect)
    }

    private func rectHandle(at p: CGPoint, rect: CGRect) -> RectHandle? {
        let corners: [(RectHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        var best: (handle: RectHandle, distance: CGFloat)?
        for (handle, corner) in corners {
            let d = hypot(p.x - corner.x, p.y - corner.y)
            if d <= handleHitRadius && d < (best?.distance ?? .infinity) {
                best = (handle, d)
            }
        }
        if let best { return best.handle }
        // 四边(角优先):距边 ≤ 命中半径且落在该边跨度内
        let r = handleHitRadius
        let inX = p.x >= rect.minX - r && p.x <= rect.maxX + r
        let inY = p.y >= rect.minY - r && p.y <= rect.maxY + r
        if abs(p.y - rect.minY) <= r && inX { return .top }
        if abs(p.y - rect.maxY) <= r && inX { return .bottom }
        if abs(p.x - rect.minX) <= r && inY { return .left }
        if abs(p.x - rect.maxX) <= r && inY { return .right }
        return nil
    }

    private func resize(_ rect: CGRect, handle: RectHandle, to p: CGPoint) -> CGRect {
        let minSide: CGFloat = 20 // 调整期间防翻转;松手路由不受影响
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .topLeft:
            minX = min(p.x, maxX - minSide); minY = min(p.y, maxY - minSide)
        case .topRight:
            maxX = max(p.x, minX + minSide); minY = min(p.y, maxY - minSide)
        case .bottomLeft:
            minX = min(p.x, maxX - minSide); maxY = max(p.y, minY + minSide)
        case .bottomRight:
            maxX = max(p.x, minX + minSide); maxY = max(p.y, minY + minSide)
        case .top:
            minY = min(p.y, maxY - minSide)
        case .bottom:
            maxY = max(p.y, minY + minSide)
        case .left:
            minX = min(p.x, maxX - minSide)
        case .right:
            maxX = max(p.x, minX + minSide)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - 小工具

    private func clearSelection() {
        state = .none
        highlightedWords = []
        brushPoints = []
        session = nil
    }

    private func atLeast(_ rect: CGRect, minW: CGFloat, minH: CGFloat) -> CGRect {
        var r = rect
        if r.width < minW { r = r.insetBy(dx: -(minW - r.width) / 2, dy: 0) }
        if r.height < minH { r = r.insetBy(dx: 0, dy: -(minH - r.height) / 2) }
        return r
    }

    private func clampRect(_ rect: CGRect) -> CGRect {
        guard viewport.width > 0, viewport.height > 0 else { return rect }
        var r = rect
        r.size.width = min(r.width, viewport.width)
        r.size.height = min(r.height, viewport.height)
        r.origin.x = min(max(0, r.origin.x), viewport.width - r.width)
        r.origin.y = min(max(0, r.origin.y), viewport.height - r.height)
        return r
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0 else { return p }
        return CGPoint(x: min(max(0, p.x), viewport.width),
                       y: min(max(0, p.y), viewport.height))
    }
}
