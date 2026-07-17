import CoreGraphics
import CoreText
import Foundation

/// F22 文本测量(命中/外接框/编辑态定位共用;CoreText,零 AppKit)。
public enum AnnotationTextMetrics {
    public static func font(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// 多行文本尺寸(按 \n 分行;不做自动折行——标注文本短,自由换行归用户)。
    public static func size(of text: String, fontSize: CGFloat) -> CGSize {
        let font = font(size: fontSize)
        let lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        var width: CGFloat = 0
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            width = max(width, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
        }
        return CGSize(width: ceil(width) + 2, height: ceil(lineHeight * CGFloat(lines.count)) + 2)
    }
}

/// F22 标注渲染器(spec S4「导出保真」):**预览与导出走同一支画笔**——
/// UI 侧经 GraphicsContext.withCGContext 调 `draw`,导出经 `flatten`,
/// 全部以图像像素空间为规格真源,杜绝「预览一个样、导出另一个样」。
public enum AnnotationRenderer {

    // MARK: 常量(像素空间;线宽已含 scale)

    public static func counterRadius(lineWidth: CGFloat) -> CGFloat {
        max(18, lineWidth * 3.6)
    }

    static func mosaicBlockSize(lineWidth: CGFloat) -> CGFloat {
        min(64, max(8, lineWidth * 3))
    }

    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat {
        max(14, lineWidth * 3.4)
    }

    /// 聚光压暗程度(spec S4)。
    static let spotlightDimAlpha: CGFloat = 0.55

    // MARK: 压平导出

    /// 源图 + 文档 → 压平位图(含非破坏裁剪)。任何导出面都走这里
    /// (保存/拷贝/拖出/发搜索/钉图/系统分享,spec S4)。
    public static func flatten(_ document: AnnotationDocument, source: CGImage) -> CGImage? {
        let crop = (document.cropRect ?? CGRect(origin: .zero, size: document.pixelSize)).integral
        let width = max(1, Int(crop.width))
        let height = max(1, Int(crop.height))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // 统一翻到「左上原点、y 向下」的模型坐标,再平移进裁剪窗
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        drawFlipped(document, source: source, in: ctx)
        return ctx.makeImage()
    }

    /// 在**已翻转为左上原点**(y 向下)的 CGContext 上绘制:底图 + 全部标注。
    /// 预览侧:GraphicsContext.withCGContext 天然就是这个朝向,直接调。
    public static func drawFlipped(_ document: AnnotationDocument, source: CGImage, in ctx: CGContext) {
        let full = CGRect(origin: .zero, size: document.pixelSize)
        // 底图(CGContext.draw 期望左下原点 → 局部翻回去画)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: full.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(source, in: full)
        ctx.restoreGState()

        drawAnnotations(document, source: source, in: ctx)
    }

    /// 只画标注层(不画底图):预览侧底图由 SwiftUI Image 显示,标注层单独叠。
    public static func drawAnnotations(_ document: AnnotationDocument, source: CGImage, in ctx: CGContext) {
        // 聚光:先整图压暗一层,再逐枚把原图区域重画回来——重叠区重画幂等,
        // 天然并集语义。~~even-odd 一次填充~~ 对重叠矩形是 XOR:两枚相交时
        // 交集覆盖数为奇 → 被重新压暗(审查实测否定,2026-07-17)。
        let spotlights = document.objects.compactMap { obj -> CGRect? in
            if case .spotlight(let r) = obj.shape { return r }
            return nil
        }
        if !spotlights.isEmpty {
            ctx.saveGState()
            ctx.setFillColor(CGColor(gray: 0, alpha: spotlightDimAlpha))
            ctx.fill(CGRect(origin: .zero, size: document.pixelSize))
            ctx.restoreGState()
            for r in spotlights { redrawSource(in: r, source: source, in: ctx) }
        }

        for object in document.objects {
            draw(object, source: source, in: ctx)
        }
    }

    // MARK: 单对象

    private static func draw(_ object: AnnotationObject, source: CGImage, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(object.color.cgColor)
        ctx.setFillColor(object.color.cgColor)
        ctx.setLineWidth(object.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch object.shape {
        case .line(let a, let b):
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, lineWidth: object.lineWidth, in: ctx)

        case .rect(let r, let filled):
            let radius = min(3 * object.lineWidth / 2, min(r.width, r.height) / 4)
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            filled ? ctx.fillPath() : ctx.strokePath()

        case .ellipse(let r):
            ctx.strokeEllipse(in: r)

        case .pen(let points):
            guard let first = points.first else { break }
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()

        case .text(let string, let origin, let fontSize):
            drawText(string, origin: origin, fontSize: fontSize, color: object.color, in: ctx)

        case .mosaic(let r):
            drawMosaic(in: r, source: source, blockSize: mosaicBlockSize(lineWidth: object.lineWidth), in: ctx)

        case .spotlight:
            break // 已在 drawAnnotations 统一压暗

        case .counter(let center, let number):
            drawCounter(center: center, number: number, lineWidth: object.lineWidth,
                        color: object.color, in: ctx)
        }
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, in ctx: CGContext) {
        let head = arrowHeadLength(lineWidth: lineWidth)
        let angle = atan2(to.y - from.y, to.x - from.x)
        // 线段缩到箭头底,避免圆头戳出三角
        let lineEnd = CGPoint(x: to.x - cos(angle) * head * 0.6,
                              y: to.y - sin(angle) * head * 0.6)
        ctx.move(to: from)
        ctx.addLine(to: lineEnd)
        ctx.strokePath()
        let spread: CGFloat = .pi / 7
        let p1 = CGPoint(x: to.x - cos(angle - spread) * head, y: to.y - sin(angle - spread) * head)
        let p2 = CGPoint(x: to.x - cos(angle + spread) * head, y: to.y - sin(angle + spread) * head)
        ctx.move(to: to)
        ctx.addLine(to: p1)
        ctx.addLine(to: p2)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ string: String, origin: CGPoint, fontSize: CGFloat,
                                 color: AnnotationColor, in ctx: CGContext) {
        let font = AnnotationTextMetrics.font(size: fontSize)
        let ascent = CTFontGetAscent(font)
        let lineHeight = ascent + CTFontGetDescent(font) + CTFontGetLeading(font)
        // 上下文当前是左上原点(y 向下),CoreText 要左下原点 → 逐行局部翻转
        for (index, line) in string.components(separatedBy: "\n").enumerated() {
            guard !line.isEmpty else { continue }
            let attributed = NSAttributedString(string: line, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color.cgColor,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            ctx.saveGState()
            ctx.textMatrix = .identity
            let baselineY = origin.y + lineHeight * CGFloat(index) + ascent
            ctx.translateBy(x: origin.x, y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }

    /// 马赛克:源图对应区域缩小再放大(禁插值),只处理对象矩形、不整图跑
    /// (spec S4 省内存;块大小随线宽档,像素空间定义 → 任何导出尺寸一致)。
    private static func drawMosaic(in rect: CGRect, source: CGImage,
                                   blockSize: CGFloat, in ctx: CGContext) {
        let clamped = rect.intersection(CGRect(x: 0, y: 0,
                                               width: CGFloat(source.width),
                                               height: CGFloat(source.height))).integral
        guard clamped.width >= 1, clamped.height >= 1,
              let cropped = source.cropping(to: clamped) else { return }
        let smallW = max(1, Int((clamped.width / blockSize).rounded(.up)))
        let smallH = max(1, Int((clamped.height / blockSize).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let small = CGContext(data: nil, width: smallW, height: smallH,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        small.interpolationQuality = .low
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(smallW), height: CGFloat(smallH)))
        guard let pixelated = small.makeImage() else { return }

        ctx.saveGState()
        ctx.clip(to: clamped)
        ctx.interpolationQuality = .none
        // 当前上下文 y 向下,draw 期望左下原点 → 局部翻回
        ctx.translateBy(x: 0, y: clamped.minY + clamped.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(pixelated, in: CGRect(x: clamped.minX, y: 0,
                                       width: clamped.width, height: clamped.height))
        ctx.restoreGState()
    }

    /// 把原图某矩形原样画回当前(左上原点)上下文——聚光提亮用。
    private static func redrawSource(in rect: CGRect, source: CGImage, in ctx: CGContext) {
        let clamped = rect.intersection(CGRect(x: 0, y: 0,
                                               width: CGFloat(source.width),
                                               height: CGFloat(source.height))).integral
        guard clamped.width >= 1, clamped.height >= 1,
              let cropped = source.cropping(to: clamped) else { return }
        ctx.saveGState()
        ctx.clip(to: clamped)
        ctx.translateBy(x: 0, y: clamped.minY + clamped.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cropped, in: CGRect(x: clamped.minX, y: 0,
                                     width: clamped.width, height: clamped.height))
        ctx.restoreGState()
    }

    private static func drawCounter(center: CGPoint, number: Int, lineWidth: CGFloat,
                                    color: AnnotationColor, in ctx: CGContext) {
        let radius = counterRadius(lineWidth: lineWidth)
        let circle = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)
        ctx.setShadow(offset: .zero, blur: radius * 0.25, color: CGColor(gray: 0, alpha: 0.3))
        ctx.fillEllipse(in: circle)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        let text = "\(number)"
        let fontSize = radius * (text.count > 1 ? 0.9 : 1.1)
        let font = AnnotationTextMetrics.font(size: fontSize)
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: center.x - width / 2, y: center.y + (ascent - descent) / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }
}
