import AppKit
import SwiftUI
import C2SCore

/// F22 编辑器工具(spec S4 工具集,顺序即工具栏顺序)。
enum EditorTool: String, CaseIterable, Identifiable {
    case select, crop
    case rectHollow, rectFilled, ellipse, line, arrow
    case text, mosaic, spotlight, counter, pen

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .rectHollow: return "rectangle"
        case .rectFilled: return "rectangle.fill"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .mosaic: return "checkerboard.rectangle"
        case .spotlight: return "rectangle.center.inset.filled"
        case .counter: return "1.circle"
        case .pen: return "scribble"
        }
    }

    var label: String {
        switch self {
        case .select: return L10n.t("editor.tool.select", "选择")
        case .crop: return L10n.t("editor.tool.crop", "裁剪")
        case .rectHollow: return L10n.t("editor.tool.rect", "空心框")
        case .rectFilled: return L10n.t("editor.tool.rect_filled", "实心框")
        case .ellipse: return L10n.t("editor.tool.ellipse", "椭圆")
        case .line: return L10n.t("editor.tool.line", "直线")
        case .arrow: return L10n.t("editor.tool.arrow", "箭头")
        case .text: return L10n.t("editor.tool.text", "文字")
        case .mosaic: return L10n.t("editor.tool.mosaic", "马赛克")
        case .spotlight: return L10n.t("editor.tool.spotlight", "聚光高亮")
        case .counter: return L10n.t("editor.tool.counter", "序号")
        case .pen: return L10n.t("editor.tool.pen", "画笔")
        }
    }
}

/// F22 编辑器状态模型:包一层 AnnotationDocument(纯值)+ UndoManager
/// (值快照式撤销:每次落笔/移动/删除记录整份旧文档,简单可靠)+ 工具状态。
/// 生命周期:托盘项运行期持有(spec S4——重开编辑器回到同一文档继续编辑)。
@MainActor
final class EditorModel: ObservableObject {

    let source: CGImage
    /// 像素/点(线宽字号档 × 它 = 像素值,规格真源=像素空间)。
    let pixelsPerPoint: CGFloat
    let displayName: String

    @Published var document: AnnotationDocument
    @Published var tool: EditorTool = .arrow // 打开就能画(箭头 = 截图标注第一高频)
    @Published var color: AnnotationColor = .presetRed
    /// 粗细三档索引(0/1/2;默认中档,spec S4)。
    @Published var strokeLevel = 1
    @Published var selectedID: UUID?
    /// 画中的草稿(未落笔;渲染时叠加在文档之上)。
    @Published var draft: AnnotationObject?
    /// 裁剪工具的草稿框(像素;松手即提交 cropRect)。
    @Published var cropDraft: CGRect?
    /// 文本编辑态(spec S4:Canvas 只能绘不能编 → 叠临时输入框)。
    @Published var editingTextID: UUID?
    @Published var editingText = ""

    let undoManager = UndoManager()
    /// 最后一次「交付」(打开/Done)时的文档快照;脏 = 当前 ≠ 快照。
    private var committedDocument: AnnotationDocument

    /// 缩放(spec S4:25%–400%,⌘0 适应):nil = 适应;100 = 点尺寸原大。
    /// 放模型层是为了 manager 的键盘监听(⌘+/-/0)可触达。
    @Published var zoomPercent: CGFloat?
    /// 适应窗口时的百分比(视图按几何回填)。
    var fitPercent: CGFloat = 100
    static let zoomSteps: [CGFloat] = [25, 50, 75, 100, 150, 200, 300, 400]

    init(source: CGImage, pointSize: CGSize, displayName: String,
         document: AnnotationDocument? = nil,
         committed: AnnotationDocument? = nil) {
        self.source = source
        self.pixelsPerPoint = pointSize.width > 0
            ? CGFloat(source.width) / pointSize.width : 2
        self.displayName = displayName
        let doc = document ?? AnnotationDocument(
            pixelSize: CGSize(width: source.width, height: source.height))
        self.document = doc
        self.committedDocument = committed ?? doc
    }

    var isDirty: Bool { document != committedDocument }

    func markCommitted() { committedDocument = document }

    /// 关窗时把交付基线一并存回托盘项(重开后脏判定不丢,spec S4 生命周期)。
    var committedSnapshot: AnnotationDocument { committedDocument }

    func stepZoom(_ direction: Int) {
        let current = zoomPercent ?? fitPercent
        if direction > 0 {
            zoomPercent = Self.zoomSteps.first(where: { $0 > current + 0.5 }) ?? Self.zoomSteps.last
        } else {
            zoomPercent = Self.zoomSteps.last(where: { $0 < current - 0.5 }) ?? Self.zoomSteps.first
        }
    }

    func zoomToFit() { zoomPercent = nil }

    // MARK: 粗细档 → 像素线宽/字号

    private static let strokePointWidths: [CGFloat] = [2, 4, 7]
    private static let fontPointSizes: [CGFloat] = [14, 19, 26]

    var lineWidthPixels: CGFloat {
        Self.strokePointWidths[max(0, min(2, strokeLevel))] * pixelsPerPoint
    }

    var fontSizePixels: CGFloat {
        Self.fontPointSizes[max(0, min(2, strokeLevel))] * pixelsPerPoint
    }

    /// 命中容差:屏幕 6pt 手感换算到像素(随缩放变化,由视图传缩放)。
    func hitTolerance(zoom: CGFloat) -> CGFloat {
        6 / max(zoom, 0.01)
    }

    // MARK: 文档变更(全部走这里 → 值快照撤销)

    func apply(_ newDocument: AnnotationDocument, actionName: String) {
        let old = document
        guard newDocument != old else { return }
        document = newDocument
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.apply(old, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    func addObject(_ object: AnnotationObject) {
        var doc = document
        doc.add(object)
        apply(doc, actionName: L10n.t("editor.undo.add", "添加标注"))
    }

    func removeSelected() {
        guard let id = selectedID else { return }
        var doc = document
        doc.remove(id: id)
        selectedID = nil
        apply(doc, actionName: L10n.t("editor.undo.remove", "删除标注"))
    }

    /// 拖动结束时一次性入撤销栈(拖动过程直接改 document,不记账)。
    func commitMove(from oldDocument: AnnotationDocument) {
        let new = document
        guard new != oldDocument else { return }
        document = oldDocument
        apply(new, actionName: L10n.t("editor.undo.move", "移动标注"))
    }

    func setCrop(_ rect: CGRect?) {
        var doc = document
        doc.cropRect = rect
        apply(doc, actionName: L10n.t("editor.undo.crop", "裁剪"))
    }

    // MARK: 文本编辑态

    func beginTextEditing(id: UUID, existing: String) {
        editingTextID = id
        editingText = existing
    }

    /// 提交文本编辑。新建对象(落点时**静默**插入,不入撤销栈)在这里才作为
    /// 一条完整「添加标注」注册撤销——否则 Esc/空文本会给撤销链留死步
    /// (⌘Z 按了没反应,redo 配对断裂;2026-07-17 审查)。
    func commitTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        defer { editingText = "" }
        guard var object = document.object(id: id),
              case .text(let originalText, let origin, let fontSize) = object.shape else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)

        if originalText.isEmpty {
            // 新建:先静默回到「无此对象」的基线
            var base = document
            base.remove(id: id)
            document = base
            guard !trimmed.isEmpty else { return } // 空文本:当从未存在过
            object.shape = .text(trimmed, origin: origin, fontSize: fontSize)
            var withNew = base
            withNew.add(object)
            apply(withNew, actionName: L10n.t("editor.undo.add", "添加标注"))
            return
        }
        var doc = document
        if trimmed.isEmpty {
            doc.remove(id: id)
            apply(doc, actionName: L10n.t("editor.undo.remove", "删除标注"))
        } else if trimmed != originalText {
            object.shape = .text(trimmed, origin: origin, fontSize: fontSize)
            doc.update(object)
            apply(doc, actionName: L10n.t("editor.undo.text", "编辑文字"))
        }
    }

    func cancelTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        // 新建即取消且从未有内容 → 移除空对象
        if let object = document.object(id: id),
           case .text(let s, _, _) = object.shape, s.isEmpty {
            var doc = document
            doc.remove(id: id)
            document = doc // 不进撤销栈(从未真正存在过)
        }
        editingText = ""
    }

    // MARK: 导出

    /// 压平当前画布(任何导出面共用,spec S4)。
    func flatten() -> CGImage? {
        AnnotationRenderer.flatten(document, source: source)
    }

    /// 压平后的点尺寸(裁剪会变小;NSImage/托盘用)。
    var flattenedPointSize: CGSize {
        let crop = document.cropRect ?? CGRect(origin: .zero, size: document.pixelSize)
        return CGSize(width: crop.width / pixelsPerPoint,
                      height: crop.height / pixelsPerPoint)
    }
}
