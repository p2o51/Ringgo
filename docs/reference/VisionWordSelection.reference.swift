import Foundation
import AppKit
import Vision
import CoreGraphics
import CoreText

// ============================================================
// 0. 渲染一张已知内容的测试图(标题 + 长段落 + 中文 + 无字图片区)
//    坐标用 CG(左下原点,y 向上)绘制,最终得到正立的位图。
// ============================================================
let W = 1000, H = 760

func makeContext() -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)) // 白底
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    return ctx
}

func drawLine(_ ctx: CGContext, _ text: String, x: CGFloat, yFromBottom: CGFloat, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attr))
    ctx.textPosition = CGPoint(x: x, y: yFromBottom)
    CTLineDraw(line, ctx)
}

func drawParagraph(_ ctx: CGContext, _ text: String, rect: CGRect, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)]
    let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attr))
    let path = CGMutablePath(); path.addRect(rect)
    let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
    CTFrameDraw(frame, ctx)
}

let ctx = makeContext()
// 标题(1 行)
drawLine(ctx, "Circle to Search", x: 60, yFromBottom: 690, size: 40)
// 长段落(多行,自动换行)
let PARAGRAPH = "The quick brown fox jumps over the lazy dog while machine learning models recognize printed text inside images using on device neural networks for privacy and speed."
drawParagraph(ctx, PARAGRAPH, rect: CGRect(x: 60, y: 380, width: 880, height: 240), size: 30)
// 中文一行
drawLine(ctx, "本地文字识别测试", x: 60, yFromBottom: 330, size: 34)
// 无文字的"图片"区(蓝色方块)
ctx.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1))
ctx.fill(CGRect(x: 60, y: 60, width: 300, height: 200))

let image = ctx.makeImage()!

// ============================================================
// 1. OCR → 词级框(测试 ②:boundingBox(for:))
//    Vision 返回归一化、左下原点;转成"左上原点像素"给引擎。
// ============================================================
struct Word { let text: String; let rect: CGRect; var globalIndex: Int }   // rect: 左上原点像素
func center(_ w: Word) -> CGPoint { CGPoint(x: w.rect.midX, y: w.rect.midY) }

func ocrWords(_ img: CGImage) -> [Word] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.automaticallyDetectsLanguage = true
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    try? handler.perform([req])
    guard let obs = req.results as? [VNRecognizedTextObservation] else { return [] }
    var words: [Word] = []
    for o in obs {
        guard let cand = o.topCandidates(1).first else { continue }
        let s = cand.string
        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: [.byWords]) { sub, range, _, _ in
            guard let sub = sub, let rectObs = try? cand.boundingBox(for: range) else { return }
            let nb = rectObs.boundingBox   // 归一化 左下
            let px = CGRect(x: nb.origin.x * CGFloat(W),
                            y: (1 - nb.origin.y - nb.height) * CGFloat(H),  // 翻 Y → 左上
                            width: nb.width * CGFloat(W),
                            height: nb.height * CGFloat(H))
            words.append(Word(text: sub, rect: px, globalIndex: 0))
        }
    }
    return words
}

// ============================================================
// 2. SelectionEngine —— 纯逻辑(测试 ③ + 提议的改进)
// ============================================================

// 阅读顺序:按 y 分行 → 行内按 x → 重排 index
func readingOrder(_ words: [Word]) -> [Word] {
    guard !words.isEmpty else { return [] }
    let heights = words.map { $0.rect.height }.sorted()
    let median = heights[heights.count/2]
    let thr = max(4, median * 0.6)
    let byY = words.sorted { $0.rect.minY < $1.rect.minY }
    var lines: [[Word]] = []; var cur: [Word] = []; var curMidY: CGFloat = 0
    for w in byY {
        let midY = w.rect.midY
        if cur.isEmpty { cur = [w]; curMidY = midY; continue }
        if abs(midY - curMidY) <= thr {
            cur.append(w); curMidY = (curMidY*CGFloat(cur.count-1)+midY)/CGFloat(cur.count)
        } else { lines.append(cur); cur = [w]; curMidY = midY }
    }
    if !cur.isEmpty { lines.append(cur) }
    let ordered = lines.flatMap { $0.sorted { $0.rect.minX < $1.rect.minX } }
    return ordered.enumerated().map { i, w in Word(text: w.text, rect: w.rect, globalIndex: i) }
}

// 几何:线段-矩形相交
func cross(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint) -> CGFloat { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
func segInter(_ p1: CGPoint,_ p2: CGPoint,_ p3: CGPoint,_ p4: CGPoint) -> Bool {
    let d1=cross(p3,p4,p1), d2=cross(p3,p4,p2), d3=cross(p1,p2,p3), d4=cross(p1,p2,p4)
    return ((d1>0 && d2<0)||(d1<0 && d2>0)) && ((d3>0 && d4<0)||(d3<0 && d4>0))
}
func pathHitsRect(_ pts: [CGPoint], _ r: CGRect) -> Bool {
    for p in pts where r.contains(p) { return true }
    guard pts.count > 1 else { return false }
    let tl=CGPoint(x:r.minX,y:r.minY), tr=CGPoint(x:r.maxX,y:r.minY), br=CGPoint(x:r.maxX,y:r.maxY), bl=CGPoint(x:r.minX,y:r.maxY)
    for i in 0..<pts.count-1 {
        let a=pts[i], b=pts[i+1]
        if segInter(a,b,tl,tr)||segInter(a,b,tr,br)||segInter(a,b,br,bl)||segInter(a,b,bl,tl) { return true }
    }
    return false
}
func bbox(_ pts: [CGPoint]) -> CGRect {
    var minX=pts[0].x, maxX=pts[0].x, minY=pts[0].y, maxY=pts[0].y
    for p in pts { minX=min(minX,p.x);maxX=max(maxX,p.x);minY=min(minY,p.y);maxY=max(maxY,p.y) }
    return CGRect(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
}

// 笔刷划词 → 命中词的连续区间 [min...max]
func brushSelect(path pts: [CGPoint], words: [Word], radius: CGFloat = 14) -> [Word] {
    guard !pts.isEmpty, !words.isEmpty else { return [] }
    let bounds = bbox(pts).insetBy(dx: -radius, dy: -radius)
    var touched: [Int] = []
    for w in words where bounds.intersects(w.rect) {
        if pathHitsRect(pts, w.rect.insetBy(dx: -radius, dy: -radius)) { touched.append(w.globalIndex) }
    }
    guard let lo = touched.min(), let hi = touched.max() else { return [] }
    return words.filter { $0.globalIndex >= lo && $0.globalIndex <= hi }
}

// 真·圈选(改进):点在多边形内 → 选中中心被圈住的词(ray casting)
func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
    var inside = false; var j = poly.count - 1
    for i in 0..<poly.count {
        let a = poly[i], b = poly[j]
        if ((a.y > p.y) != (b.y > p.y)) && (p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x) { inside.toggle() }
        j = i
    }
    return inside
}
func lassoSelect(polygon poly: [CGPoint], words: [Word]) -> [Word] {
    words.filter { pointInPolygon(center($0), poly) }
}

// ============================================================
// 3. 跑 + 断言
// ============================================================
func find(_ words: [Word], _ text: String) -> Word? { words.first { $0.text.lowercased() == text.lowercased() } }

let raw = ocrWords(image)
let words = readingOrder(raw)

print("========== ② 词级 OCR 结果 ==========")
print("识别到词数:", words.count)
print("前 40 个词(index: '文本' @ x,y):")
for w in words.prefix(40) {
    print(String(format: "  %2d: '%@'  @ (%.0f,%.0f) %.0fx%.0f", w.globalIndex, w.text, w.rect.minX, w.rect.minY, w.rect.width, w.rect.height))
}
let hasCJK = words.contains { $0.text.unicodeScalars.contains { $0.value > 0x2E00 } }
print("含中文词?", hasCJK, " —", words.filter { $0.text.unicodeScalars.contains { $0.value > 0x2E00 } }.map { $0.text })

var pass = 0, fail = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "  ✅ PASS " : "  ❌ FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
    if cond { pass += 1 } else { fail += 1 }
}

print("\n========== ③-A 选“单词/短语”(笔刷划过 3 个相邻词) ==========")
if let a = find(words,"quick"), let b = find(words,"brown"), let c = find(words,"fox") {
    let stroke = [center(a), center(b), center(c)]
    let sel = brushSelect(path: stroke, words: words)
    let text = sel.map{$0.text}.joined(separator:" ")
    print("  笔刷经过 quick→brown→fox,选中:", text)
    check("选中恰好是 quick brown fox", sel.map{$0.text.lowercased()} == ["quick","brown","fox"], "实际: \(text)")
} else { check("找到 quick/brown/fox", false, "OCR 没识别到这几个词") }

print("\n========== ③-B 选“长段”(一笔从段首扫到段尾,跨多行) ==========")
if let a = find(words,"quick"), let b = find(words,"models"), let c = find(words,"speed") {
    let stroke = [center(a), center(b), center(c)]   // 快速一划,只碰 3 个远隔的词
    let sel = brushSelect(path: stroke, words: words)
    let idx = sel.map{$0.globalIndex}
    let contiguous = idx == Array(idx.first!...idx.last!)
    // 判断是否跨行:选区里出现多个不同的 y 行
    let lineYs = Set(sel.map { Int($0.rect.midY / 20) })
    print("  选中词数:", sel.count, " 跨行数≈:", lineYs.count)
    print("  选中文本:", sel.map{$0.text}.joined(separator:" "))
    check("min…max 自动补全为连续区间", contiguous)
    check("长段跨越多行(≥3 行)", lineYs.count >= 3, "跨 \(lineYs.count) 行")
    check("一次快划即选中一大段(≥12 词)", sel.count >= 12, "选中 \(sel.count) 词")
} else { check("找到 quick/models/speed", false) }

print("\n========== ③-C 真·圈选(画圈,选中被圈住的词 — 我提议的改进) ==========")
if let a = find(words,"lazy"), let b = find(words,"dog") {   // 同一行相邻两词,画个合理的小圈
    let u = a.rect.union(b.rect).insetBy(dx: -18, dy: -12)
    var poly: [CGPoint] = []
    for k in 0..<32 { let t = CGFloat(k)/32*2*CGFloat.pi
        poly.append(CGPoint(x: u.midX + cos(t)*u.width/2, y: u.midY + sin(t)*u.height/2)) }
    let sel = lassoSelect(polygon: poly, words: words)
    print("  在 “lazy dog” 周围画圈,选中:", sel.map{$0.text}.joined(separator:" "))
    check("圈选精确命中 lazy 且 dog", sel.contains{$0.text.lowercased()=="lazy"} && sel.contains{$0.text.lowercased()=="dog"})
    check("圈选没有误选圈外的词(≤3 个)", sel.count <= 3, "选中 \(sel.count) 个: \(sel.map{$0.text})")
} else { check("找到 lazy/dog", false) }

print("\n========== ③-D 选“图片”(划过无文字的蓝色区 → 应 0 命中 → 走图搜) ==========")
// 蓝色方块在 CG 左下 (60,60,300x200) → 左上像素 y = H-60-200 = 500 → rect (60,500,300,200)
let imageBoxTopLeft = CGRect(x: 60, y: CGFloat(H)-60-200, width: 300, height: 200)
let strokeOverImage = [CGPoint(x: imageBoxTopLeft.minX+30, y: imageBoxTopLeft.midY),
                       CGPoint(x: imageBoxTopLeft.maxX-30, y: imageBoxTopLeft.midY)]
let hitInImage = brushSelect(path: strokeOverImage, words: words)
print("  蓝色区里命中词数:", hitInImage.count)
check("无文字区 → 0 命中(据此路由到 Lens 图搜)", hitInImage.isEmpty, "命中 \(hitInImage.count)")
// 确认蓝色区确实没有词(OCR 没在里面识别出东西)
let wordsInsideImage = words.filter { imageBoxTopLeft.contains(center($0)) }
check("OCR 未在图片区识别出文字", wordsInsideImage.isEmpty, "里面有 \(wordsInsideImage.count) 词")

print("\n========== 小结 ==========")
print("PASS \(pass)  /  FAIL \(fail)")
