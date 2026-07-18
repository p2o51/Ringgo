import SwiftUI
import C2SCore

/// F22 标注编辑器主视图(spec S4,版式对齐 CleanShot、材质走 Ringgo 玻璃语言):
/// 顶部工具行(工具 · 色板 · 粗细 · Save as/Done)/ 画布(预览 = 导出同一支笔)/
/// 底部栏(缩放 · Drag Me · 拷贝/分享)。
struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let reduceEffects: Bool
    var onDone: () -> Void = {}
    var onSaveAs: () -> Void = {}
    var onCopy: () -> Void = {}
    var onShare: (CGRect) -> Void = { _ in }
    /// Drag Me:拖出前现场压平写临时文件(nil = 压平失败)。
    var provideDragFileURL: () -> URL? = { nil }
    /// F23 钉图:当前画布(含未 Done 标注)钉成置顶浮窗。
    var onPin: () -> Void = {}
    /// S5 AI 一次性动作(翻译整图/可视化):压平画布进共享搜索面板。
    var onAIPrompt: (EditorAIPrompt) -> Void = { _ in }
    /// S5 提问:整图 + 问题(F11 整屏提问同机制)。
    var onAsk: (String) -> Void = { _ in }

    /// S5 提问框(「提问」chip = 聚焦它)。
    @State private var askText = ""
    @FocusState private var askFocused: Bool

    /// 文本编辑态焦点(中途插入的 TextField 不会自动成 first responder,
    /// 不管焦点的话「打字无处可去」,2026-07-17 审查)。
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            aiRow
            Divider().opacity(0.4)
            canvasArea
            Divider().opacity(0.4)
            bottomBar
        }
        .disabled(model.isExporting)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.editingTextID) { _, editing in
            if editing != nil {
                // 异步一拍等输入框挂进视图树再要焦点(呼出当帧要不到)
                DispatchQueue.main.async { textFieldFocused = true }
            } else {
                textFieldFocused = false
            }
        }
    }

    // MARK: - 顶部工具行

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(model.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    toolButton(tool)
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            colorSwatches
            strokePicker

            Spacer(minLength: 4)

            Button(L10n.t("editor.save_as", "另存为…")) { onSaveAs() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(action: onDone) {
                if model.isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.t("editor.done", "完成"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        let active = model.tool == tool
        return Button {
            model.commitTextEditing()
            model.tool = tool
            if tool != .select { model.selectedID = nil }
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .background(active ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tool.label)
        .accessibilityLabel(tool.label)
    }

    // MARK: - S5 AI 行(工具栏下细行,Ringgo 灵魂位:发出去的是含标注压平的当前画布)

    private var aiRow: some View {
        HStack(spacing: 6) {
            aiChip(icon: "translate",
                   label: L10n.t("editor.ai.translate", "翻译整图")) { onAIPrompt(.translate) }
            aiChip(icon: "bubble.left.and.text.bubble.right",
                   label: L10n.t("editor.ai.ask", "提问")) { askFocused = true }
            aiChip(icon: "chart.bar.xaxis",
                   label: L10n.t("common.visualize", "可视化")) { onAIPrompt(.visualize) }

            TextField(L10n.t("editor.ai.placeholder", "问点什么,图和问题一起发出去…"),
                      text: $askText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($askFocused)
                .onSubmit {
                    let text = askText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    onAsk(text)
                    askText = ""
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.background.opacity(0.5), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func aiChip(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private static let palette: [AnnotationColor] = [
        .presetRed, .presetYellow, .presetGreen, .presetBlue, .presetBlack, .presetWhite,
    ]

    private var colorSwatches: some View {
        HStack(spacing: 5) {
            ForEach(Array(Self.palette.enumerated()), id: \.offset) { _, preset in
                let selected = model.color == preset
                Button {
                    model.color = preset
                    applyStyleToSelection()
                } label: {
                    Circle()
                        .fill(Color(red: preset.red, green: preset.green, blue: preset.blue))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
                        .overlay {
                            if selected {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    private var strokePicker: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { level in
                let selected = model.strokeLevel == level
                Button {
                    model.strokeLevel = level
                    applyStyleToSelection()
                } label: {
                    Circle()
                        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.7))
                        .frame(width: CGFloat(4 + level * 3), height: CGFloat(4 + level * 3))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(L10n.t("editor.stroke", "粗细"))
            }
        }
    }

    /// 改色/改粗细即时应用到当前选中对象(CleanShot 手感)。
    /// 文字的可见大小由 shape 内 fontSize 决定 → 粗细档同步改字号(审查修正)。
    private func applyStyleToSelection() {
        guard let id = model.selectedID, var object = model.document.object(id: id) else { return }
        object.color = model.color
        object.lineWidth = model.lineWidthPixels
        if case .text(let s, let origin, _) = object.shape {
            object.shape = .text(s, origin: origin, fontSize: model.fontSizePixels)
        }
        var doc = model.document
        doc.update(object)
        model.apply(doc, actionName: L10n.t("editor.undo.style", "修改样式"))
    }

    // MARK: - 画布

    private var pixelSize: CGSize { model.document.pixelSize }

    /// 视图点 / 图像像素(缩放状态在 model 上:⌘+/-/0 由窗口键盘监听触达)。
    private var zoom: CGFloat {
        ((model.zoomPercent ?? model.fitPercent) / 100) / model.pixelsPerPoint
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            let fit = fitZoomPercent(available: geo.size)
            ScrollView([.horizontal, .vertical]) {
                canvasContent
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .onAppear { model.fitPercent = fit }
            .onChange(of: geo.size) { _, newSize in
                model.fitPercent = fitZoomPercent(available: newSize)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func fitZoomPercent(available: CGSize) -> CGFloat {
        let margin: CGFloat = 48
        let w = max(100, available.width - margin)
        let h = max(100, available.height - margin)
        let pointW = pixelSize.width / model.pixelsPerPoint
        let pointH = pixelSize.height / model.pixelsPerPoint
        let scale = min(w / max(pointW, 1), h / max(pointH, 1), 1)
        return max(10, scale * 100)
    }

    private var canvasContent: some View {
        let width = pixelSize.width * zoom
        let height = pixelSize.height * zoom
        return ZStack(alignment: .topLeading) {
            annotationCanvas
            cropOverlay
            selectionChrome
            textEditingOverlay
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.001)) // 稳定命中区
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(24)
        .contentShape(Rectangle())
        .gesture(canvasGesture)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// 预览 = 导出同一支笔(spec S4 导出保真):标注层经 withCGContext 调
    /// AnnotationRenderer.drawAnnotations,只差一个缩放矩阵。
    /// 底图走 SwiftUI Image(AppKit 缓存纹理)——拖动每帧用 CG 重画 5K 底图
    /// 必掉帧(spec §10「画布渲染按需降采样预览」,审查修正)。
    private var annotationCanvas: some View {
        let renderDoc = renderDocument
        let width = pixelSize.width * zoom
        let height = pixelSize.height * zoom
        return ZStack(alignment: .topLeading) {
            Image(decorative: model.source, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: height)
            Canvas(rendersAsynchronously: false) { ctx, _ in
                ctx.withCGContext { cg in
                    cg.saveGState()
                    cg.scaleBy(x: zoom, y: zoom)
                    AnnotationRenderer.drawAnnotations(renderDoc, source: model.source, in: cg)
                    cg.restoreGState()
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 渲染文档 = 文档 + 未落笔草稿;正在文字编辑的对象隐去(输入框顶替显示)。
    private var renderDocument: AnnotationDocument {
        var doc = model.document
        doc.cropRect = nil // 编辑时永远显示全图,裁剪由 cropOverlay 表达
        if let editing = model.editingTextID {
            doc.objects.removeAll { $0.id == editing }
        }
        if let draft = model.draft {
            doc.add(draft)
        }
        return doc
    }

    /// 裁剪表达:框外压暗 + 白框(编辑器内非破坏,导出才真裁,spec S4)。
    @ViewBuilder private var cropOverlay: some View {
        if let crop = model.cropDraft ?? model.document.cropRect {
            let r = CGRect(x: crop.minX * zoom, y: crop.minY * zoom,
                           width: crop.width * zoom, height: crop.height * zoom)
            Canvas { ctx, size in
                var path = Path(CGRect(origin: .zero, size: size))
                path.addRect(r)
                ctx.fill(path, with: .color(.black.opacity(0.42)), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false)
        }
    }

    /// 选中描边(accent 虚线外接框)。
    @ViewBuilder private var selectionChrome: some View {
        if let id = model.selectedID, let object = model.document.object(id: id),
           model.editingTextID != id {
            let box = model.document.boundingBox(of: object)
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor,
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: max(8, box.width * zoom + 8), height: max(8, box.height * zoom + 8))
                .offset(x: box.minX * zoom - 4, y: box.minY * zoom - 4)
                .allowsHitTesting(false)
        }
    }

    /// 文本编辑态:画布对应位置叠输入框(spec S4:Canvas 只能绘不能编)。
    @ViewBuilder private var textEditingOverlay: some View {
        if let id = model.editingTextID, let object = model.document.object(id: id),
           case .text(_, let origin, let fontSize) = object.shape {
            TextField(L10n.t("editor.text_placeholder", "输入文字…"),
                      text: Binding(get: { model.editingText },
                                    set: { model.editingText = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: max(9, fontSize * zoom)))
                .foregroundStyle(Color(red: object.color.red, green: object.color.green,
                                       blue: object.color.blue))
                .frame(minWidth: 120, maxWidth: 420)
                .fixedSize()
                .padding(2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                .offset(x: origin.x * zoom - 4, y: origin.y * zoom - 4)
                .focused($textFieldFocused)
                .onSubmit { model.commitTextEditing() }
                .onExitCommand { model.cancelTextEditing() }
        }
    }

    // MARK: - 画布手势(视图点 → 图像像素;全部工具统一入口)

    @State private var dragStartPixel: CGPoint?
    @State private var moveBaseline: AnnotationDocument?
    @State private var lastMovePixel: CGPoint?

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = pixelPoint(value.location)
                let start = pixelPoint(value.startLocation)
                handleDragChanged(at: p, start: start)
            }
            .onEnded { value in
                let p = pixelPoint(value.location)
                let start = pixelPoint(value.startLocation)
                handleDragEnded(at: p, start: start)
            }
    }

    /// 画布 padding(24)内的手势坐标 → 图像像素(钳进图内)。
    private func pixelPoint(_ location: CGPoint) -> CGPoint {
        let x = (location.x - 24) / zoom
        let y = (location.y - 24) / zoom
        return CGPoint(x: min(max(0, x), pixelSize.width),
                       y: min(max(0, y), pixelSize.height))
    }

    private func handleDragChanged(at p: CGPoint, start: CGPoint) {
        if dragStartPixel == nil {
            dragStartPixel = start
            beginGesture(at: start)
        }
        let movedEnough = hypot(p.x - start.x, p.y - start.y) >= 3 / max(zoom, 0.01)
        switch model.tool {
        case .select:
            guard movedEnough, model.selectedID != nil, moveBaseline != nil else { return }
            let from = lastMovePixel ?? start
            var doc = model.document
            doc.move(id: model.selectedID!, by: CGVector(dx: p.x - from.x, dy: p.y - from.y))
            model.document = doc // 拖动中直改,松手一次性入撤销栈
            lastMovePixel = p
        case .crop:
            guard movedEnough else { return }
            model.cropDraft = normalizedRect(start, p)
        case .rectHollow, .rectFilled, .ellipse, .mosaic, .spotlight:
            guard movedEnough else { return }
            model.draft = AnnotationObject(shape: shapeForRectTool(normalizedRect(start, p)),
                                           color: model.color, lineWidth: model.lineWidthPixels)
        case .line, .arrow:
            guard movedEnough else { return }
            let shape: AnnotationObject.Shape = model.tool == .line
                ? .line(from: start, to: p) : .arrow(from: start, to: p)
            model.draft = AnnotationObject(shape: shape, color: model.color,
                                           lineWidth: model.lineWidthPixels)
        case .pen:
            var points: [CGPoint]
            if case .pen(let existing)? = model.draft?.shape { points = existing } else { points = [start] }
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 2 / max(zoom, 0.01) { return }
            points.append(p)
            model.draft = AnnotationObject(shape: .pen(points), color: model.color,
                                           lineWidth: model.lineWidthPixels)
        case .text, .counter:
            break // 点击型工具,松手处理
        }
    }

    private func beginGesture(at start: CGPoint) {
        model.commitTextEditing()
        if model.tool == .select {
            let hit = model.document.hitTest(at: start, tolerance: model.hitTolerance(zoom: zoom))
            if let hit {
                if model.selectedID == hit,
                   let object = model.document.object(id: hit),
                   case .text(let s, _, _) = object.shape {
                    // 点已选中的文字 = 进入编辑(CleanShot 手感)
                    model.beginTextEditing(id: hit, existing: s)
                    return
                }
                model.selectedID = hit
                moveBaseline = model.document
                lastMovePixel = nil
            } else {
                model.selectedID = nil
                moveBaseline = nil
            }
        }
    }

    private func handleDragEnded(at p: CGPoint, start: CGPoint) {
        defer {
            dragStartPixel = nil
            moveBaseline = nil
            lastMovePixel = nil
            model.draft = nil
        }
        let movedEnough = hypot(p.x - start.x, p.y - start.y) >= 3 / max(zoom, 0.01)
        switch model.tool {
        case .select:
            if let base = moveBaseline, movedEnough, model.selectedID != nil {
                model.commitMove(from: base)
            }
        case .crop:
            model.cropDraft = nil
            if movedEnough {
                let rect = normalizedRect(start, p)
                if rect.width >= 8, rect.height >= 8 { model.setCrop(rect) }
            } else {
                model.setCrop(nil) // 轻点 = 清除裁剪
            }
        case .rectHollow, .rectFilled, .ellipse, .mosaic, .spotlight:
            guard movedEnough else { return }
            let rect = normalizedRect(start, p)
            guard rect.width >= 3 || rect.height >= 3 else { return }
            model.addObject(AnnotationObject(shape: shapeForRectTool(rect),
                                             color: model.color,
                                             lineWidth: model.lineWidthPixels))
        case .line, .arrow:
            guard movedEnough else { return }
            let shape: AnnotationObject.Shape = model.tool == .line
                ? .line(from: start, to: p) : .arrow(from: start, to: p)
            model.addObject(AnnotationObject(shape: shape, color: model.color,
                                             lineWidth: model.lineWidthPixels))
        case .pen:
            if case .pen(let points)? = model.draft?.shape, points.count > 1 {
                model.addObject(AnnotationObject(shape: .pen(points), color: model.color,
                                                 lineWidth: model.lineWidthPixels))
            }
        case .counter:
            let object = AnnotationObject(
                shape: .counter(center: p, number: model.document.nextCounterNumber),
                color: model.color, lineWidth: model.lineWidthPixels)
            model.addObject(object)
        case .text:
            // 静默插入(不入撤销栈):提交非空文本时 commitTextEditing 才注册
            // 一条完整「添加标注」——否则 Esc/空文本给撤销链留死步(审查修正)
            let object = AnnotationObject(
                shape: .text("", origin: p, fontSize: model.fontSizePixels),
                color: model.color, lineWidth: model.lineWidthPixels)
            var doc = model.document
            doc.add(object)
            model.document = doc
            model.selectedID = object.id
            model.beginTextEditing(id: object.id, existing: "")
        }
    }

    private func shapeForRectTool(_ rect: CGRect) -> AnnotationObject.Shape {
        switch model.tool {
        case .rectFilled: return .rect(rect, filled: true)
        case .ellipse: return .ellipse(rect)
        case .mosaic: return .mosaic(rect)
        case .spotlight: return .spotlight(rect)
        default: return .rect(rect, filled: false)
        }
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - 底部栏

    private var bottomBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { model.stepZoom(-1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                Text(verbatim: "\(Int((model.zoomPercent ?? model.fitPercent).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 44)
                Button { model.stepZoom(1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                Button(L10n.t("editor.zoom_fit", "适应")) { model.zoomToFit() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }

            if model.document.cropRect != nil {
                Button(L10n.t("editor.crop_reset", "取消裁剪")) { model.setCrop(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }

            Spacer()

            EditorDragMePill(provideFileURL: provideDragFileURL)

            Spacer()

            // 角标顺序对齐 spec S4:📤 分享 · 📌 钉图 · ⧉ 拷贝
            GeometryReader { geo in
                Button {
                    onShare(geo.frame(in: .global))
                } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                    .help(L10n.t("editor.share", "分享…"))
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 24, height: 24)
            Button {
                onPin()
            } label: { Image(systemName: "pin") }
                .buttonStyle(.borderless)
                .help(L10n.t("editor.pin", "钉在屏幕上"))
            Button {
                onCopy()
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(L10n.t("editor.copy", "拷贝"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

/// 「≡ Drag Me ≡」拖出胶囊(spec S4:机制同托盘拖出——压平写临时文件拖 URL)。
private struct EditorDragMePill: View {
    let provideFileURL: () -> URL?

    var body: some View {
        EditorDragSurface(provideFileURL: provideFileURL) {
            Text(L10n.t("editor.drag_me", "≡ 拖我 ≡"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .fixedSize()
    }
}

/// AppKit 拖出层(SwiftUI .onDrag 拖不出文件;复用 TrayDragNSView)。
private struct EditorDragSurface<Content: View>: NSViewRepresentable {
    let provideFileURL: () -> URL?
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView {
        let container = TrayDragNSView()
        container.provideFileURL = provideFileURL
        container.interceptsAllHits = true // 胶囊是被动展示,整块归拖拽层
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrayDragNSView)?.provideFileURL = provideFileURL
    }
}
