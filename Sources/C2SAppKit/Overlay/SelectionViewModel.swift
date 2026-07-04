import SwiftUI
import C2SCore

/// 「改选文字」的结果:工具条据此分级反馈——
/// noText 才摇头 + 气泡;superseded(选区已变/被取消/被别的动作顶掉)完全静默,
/// 绝不发「未识别到文字」语义的触觉或视觉(F17 审查 #8)。
enum TextSwitchOutcome: Equatable {
    case switched
    case noText
    case superseded
}

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
    /// 悬停位置(hover affordance 用,不进手势状态机)。
    @Published var hoverLocation: CGPoint?

    // MARK: - 回调(OverlayWindowController 接线)

    var onTextSearch: (String) -> Void = { _ in }
    var onImageSearch: (CGRect) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    /// 「改选文字」框内无已知词时的定向补刀 OCR(裁剪选区重识别,
    /// 返回覆盖层坐标词框;空 = 确实没字)。OverlayWindowController 接线。
    var onFocusedOCR: ((CGRect) async -> [OCRWord])?

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
    /// 定向补刀 OCR 认出的额外词(原始坐标):整屏词表晚到时必须重新并入,
    /// 否则慢机器上「改选文字」刚成功、整屏 OCR 一到就把选区连词一起冲掉。
    private var focusedExtras: [OCRWord] = []
    /// 触觉刻度节流(跨词哒哒感,≥60ms 一次;触觉只在手指仍按住时可感)。
    private var lastHapticTick = Date.distantPast
    private var lastBrushCount = 0

    // MARK: - 生命周期(OverlayWindowController 调用)

    func prepare(viewport: CGSize) {
        self.viewport = viewport
    }

    /// 全量清理(present/dismiss 时)。engine 一并清空,防上一次抓屏的旧词串场。
    func reset() {
        state = .none
        brushPoints = []
        highlightedWords = []
        hoverLocation = nil
        engine = nil
        session = nil
        dragMode = nil
        pendingGesture = nil
        focusedExtras = []
    }

    /// OCR 词框到达 → 重建引擎(补刀词并入,见 focusedExtras);
    /// 笔刷中 → 新引擎上重放完整 path;文字选中 → 按词框映射进新词表
    /// (映射不全才清,防止整屏 OCR 晚到冲掉刚定格的选区)。
    func updateWords(_ words: [OCRWord]) {
        let table = focusedExtras.isEmpty
            ? words
            : OCRWordMerger.merge(base: words, extra: focusedExtras)
        let newEngine = SelectionEngine(words: table)
        engine = newEngine
        switch state {
        case .brushing:
            let s = BrushSession(engine: newEngine)
            highlightedWords = s.append(brushPoints)
            session = s
        case .textSelected(let selection, _, _):
            // 旧词 id 随旧引擎失效;按词框找回等价词,原样保住选区(不重发搜索)
            if case .handle = dragMode { dragMode = nil }
            if let mapped = OCRWordMerger.matching(selection, in: table),
               let first = mapped.first, let last = mapped.last {
                state = .textSelected(words: mapped, anchorID: first.id, endID: last.id)
                highlightedWords = mapped
            } else {
                clearSelection()
            }
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

    /// 正在拖角/拖边调整矩形(此时矩形变化必须跟手,不加动画)。
    var isResizingRect: Bool {
        if case .rectResize = dragMode { return true }
        return false
    }

    /// 正在拖泪滴手柄(同上,选区变化跟手)。
    var isDraggingHandle: Bool {
        if case .handle = dragMode { return true }
        return false
    }

    /// 选区外接框(迷你工具条摆位/面板自动换边用)。
    var selectionBounds: CGRect? {
        switch state {
        case .textSelected(let words, _, _):
            guard let first = words.first else { return nil }
            return words.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        case .rectSelection(let rect):
            return rect
        case .none, .brushing:
            return nil
        }
    }

    /// 迷你工具条类型(nil = 不显示;拖拽进行中不显示,防跟手漂移)。
    var miniToolbarKind: MiniToolbarKind? {
        guard dragMode == nil else { return nil }
        switch state {
        case .textSelected: return .text
        case .rectSelection: return .image
        case .none, .brushing: return nil
        }
    }

    /// 选中文字的行片段(选区翻译按行盖板)。
    var selectedLineFragments: [SelectionEngine.VisualLine] {
        guard case .textSelected(let words, _, _) = state else { return [] }
        return engine?.lineFragments(for: words) ?? []
    }

    /// 全部视觉行(全屏翻译)。
    var allVisualLines: [SelectionEngine.VisualLine] {
        engine?.visualLines ?? []
    }

    /// 笔刷进行中(底部工具条隐藏,避免与笔迹抢注意力)。
    var isBrushing: Bool {
        if case .brushing = state { return true }
        return false
    }

    /// 悬停预示(hover affordance,桌面端专属):指到哪个词,就预告「按下去选它」。
    /// 手势进行中不提示;已在选区里的词不提示(点它不会新建搜索,在搜索框编辑)。
    var hoveredWord: OCRWord? {
        guard let p = hoverLocation, dragMode == nil,
              let word = engine?.tappedWord(at: p),
              !highlightedWords.contains(where: { $0.id == word.id })
        else { return nil }
        return word
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
                Haptics.align() // 手柄落点
                onTextSearch(SelectionEngine.text(for: words))
            }
        case .rectResize:
            // 手动调整过 = 明确的「框」意图:pending 作废,永远图搜(v3 用户拍板)
            pendingGesture = nil
            if case .rectSelection(let rect) = state {
                Haptics.align() // 调整落点
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
            Haptics.align() // 轻点吸中词
            onTextSearch(SelectionEngine.text(for: selection))
            return
        }
        // 空白/图片:以点为中心的默认可调矩形
        // (F8 显著性吸附已回退:桌面截图上候选框噪声大、吸附随机,2026-07-03 实测否定)
        clearSelection()
        let half = tapRectSide / 2
        let rect = clampRect(CGRect(x: p.x - half, y: p.y - half, width: tapRectSide, height: tapRectSide))
        state = .rectSelection(rect: rect)
        Haptics.confirm() // 新框落定
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
        lastBrushCount = 0
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
            // 跨到新词的「刻度」:此刻手指必然还按着,触觉可感(松手时机的反馈感不到)
            if highlightedWords.count > lastBrushCount { hapticTick() }
            lastBrushCount = highlightedWords.count
        }
    }

    /// 节流的对齐刻度(拖动中跨词才发,绝不按帧连发)。
    private func hapticTick() {
        let now = Date()
        guard now.timeIntervalSince(lastHapticTick) >= 0.06 else { return }
        lastHapticTick = now
        Haptics.align()
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
            Haptics.confirm() // 选区定格
            onTextSearch(SelectionEngine.text(for: selection))
        } else {
            // 空触碰 → 笔画包围盒(外扩 8pt,最小 40×40)转可调矩形
            highlightedWords = []
            var rect = Geometry.boundingBox(of: path) ?? CGRect(origin: p, size: .zero)
            rect = atLeast(rect.insetBy(dx: -8, dy: -8), minW: minRectSide, minH: minRectSide)
            rect = clampRect(rect)
            state = .rectSelection(rect: rect)
            Haptics.confirm() // 新框落定
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
        if case .textSelected(_, _, let previousEnd) = state, previousEnd != target.id {
            hapticTick() // 手柄跨到新词(手指仍按住,触觉可感)
        }
        state = .textSelected(words: selection, anchorID: anchorID, endID: target.id)
        highlightedWords = selection
    }

    // MARK: - 选区类型切换(迷你工具条「改选」chip,2026-07-04)

    /// 文字选区 → 图片框:选区外接框外扩 8pt 转可调矩形,立即图搜。
    /// 场景:图片上的文字被 OCR 吸走(用户其实想搜整张图),一键改回框选。
    func switchSelectionToImage() {
        guard case .textSelected = state, let bounds = selectionBounds else { return }
        pendingGesture = nil // 显式改图意图,不得再被 OCR 兜底翻回文字
        clearSelection()
        var rect = atLeast(bounds.insetBy(dx: -8, dy: -8), minW: minRectSide, minH: minRectSide)
        rect = clampRect(rect)
        state = .rectSelection(rect: rect)
        Haptics.confirm() // 新框落定
        route(rect: rect)
    }

    /// 图片框 → 文字选区:框内的词(词中心落框内,阅读序)整体选中并发文字搜索。
    /// 框内没有已知词 → **定向补刀 OCR**(F17):整屏识别对小字/低对比字可能漏,
    /// 裁剪选区重识别一遍再试;确实没有 → .noText(调用方摇头反馈,选区不动);
    /// await 期间选区变了/任务被取消(用户转去编辑等) → .superseded(完全静默)。
    ///
    /// 纪律(F17 审查):**绝不预清 pendingGesture**——OCR 未完成时轻点/空刷出的
    /// 矩形,其图搜路由完全寄存在 pendingGesture 上(handleTap/finishBrush 在
    /// engine==nil 时不 route);补刀失败必须让整屏 OCR 到达后照常兜底路由,
    /// 否则留下一个永远不发搜索的死框。切换成功时 applyTextSelection 才清。
    @discardableResult
    func switchSelectionToText() async -> TextSwitchOutcome {
        guard case .rectSelection(let rect) = state else { return .superseded }
        if let engine, applyTextSelection(engine.words(inRect: rect)) { return .switched }

        guard let onFocusedOCR else { return .noText }
        let extra = await onFocusedOCR(rect)
        // 任务被取消(工具条:用户点了编辑/翻译/可视化,意图已变)→ 静默作废
        guard !Task.isCancelled else { return .superseded }
        // await 期间用户重拖/调整/清除了选区 → 作废,绝不动现状
        guard case .rectSelection(let current) = state, current == rect else { return .superseded }
        // 整屏词表可能已在 await 期间到达:先用真词表重查,命中就不需要补刀词
        // (避免同一段文字整屏/补刀两套框并存,分词不一致时去重不掉,F17 审查 #1)
        if let engine, applyTextSelection(engine.words(inRect: rect)) { return .switched }
        guard !extra.isEmpty else { return .noText }
        // 改选文字就此落地:此刻才作废兜底手势,防下面 updateWords 触发
        // resolvePendingGesture 按旧轻点意图抢先改写选区/重复发搜索
        pendingGesture = nil
        // 记住补刀词:整屏词表(可能还在飞)晚到时 updateWords 会重新并入
        focusedExtras.append(contentsOf: extra)
        updateWords(engine?.words ?? [])
        guard let engine else { return .noText }
        return applyTextSelection(engine.words(inRect: rect)) ? .switched : .noText
    }

    /// 词表 → 文字选中态(空表返回 false 不动状态)。
    private func applyTextSelection(_ selection: [OCRWord]) -> Bool {
        guard let first = selection.first, let last = selection.last else { return false }
        pendingGesture = nil
        state = .textSelected(words: selection, anchorID: first.id, endID: last.id)
        highlightedWords = selection
        Haptics.confirm() // 选区定格
        onTextSearch(SelectionEngine.text(for: selection))
        return true
    }

    // MARK: - 矩形路由与调整

    /// 矩形选区一律图搜(2026-07-03 用户拍板,对齐原版 Circle to Search):
    /// 框一旦出现,不管怎么调整都是搜图 —— 框里有字也交给 Lens 自己识别,
    /// 绝不中途翻转成文字搜索(想搜文字用笔刷划词;明确的「改选文字」chip 除外)。
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
