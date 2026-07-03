import Foundation
import AppKit
import Vision
import CoreGraphics

// 目标:验证"轻点图片 → 自动吸附到物体分区"在 macOS 原生 Vision 上能否实现。
// 候选原生能力:
//   ① VNGenerateObjectnessBasedSaliencyImageRequest  → 多个"显著物体"框(适合图片分区)
//   ② VNGenerateAttentionBasedSaliencyImageRequest   → 注意力显著框
//   ③ VNGenerateForegroundInstanceMaskRequest (14+)  → 前景实例(苹果"抠主体"同款)
//   ④ VNDetectRectanglesRequest                       → 矩形区(卡片/缩略图)

func loadImage(_ path: String?) -> (CGImage, Int, Int)? {
    guard let p = path, FileManager.default.fileExists(atPath: p),
          let img = NSImage(contentsOfFile: p),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return (cg, cg.width, cg.height)
}

func synthetic() -> (CGImage, Int, Int) {
    let W = 900, H = 600
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)); ctx.fill(CGRect(x:0,y:0,width:W,height:H))
    // 物体1:红色圆
    ctx.setFillColor(CGColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 120, y: 340, width: 180, height: 180))
    // 物体2:绿色圆角矩形(像一个缩略图卡片)
    ctx.setFillColor(CGColor(red: 0.15, green: 0.6, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 520, y: 360, width: 240, height: 150))
    // 物体3:蓝色三角(高对比小物体)
    ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.85, alpha: 1))
    ctx.move(to: CGPoint(x: 380, y: 120)); ctx.addLine(to: CGPoint(x: 500, y: 120)); ctx.addLine(to: CGPoint(x: 440, y: 240)); ctx.closePath(); ctx.fillPath()
    return (ctx.makeImage()!, W, H)
}

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let loaded = loadImage(arg)
let (image, W, H) = loaded ?? synthetic()
print("图像来源:", loaded != nil ? "真实照片 \(arg!)" : "合成图(红圆/绿卡/蓝三角)", " 尺寸 \(W)x\(H)")

func toTL(_ nb: CGRect) -> CGRect {   // 归一化左下 → 左上像素
    CGRect(x: nb.minX*CGFloat(W), y: (1 - nb.minY - nb.height)*CGFloat(H), width: nb.width*CGFloat(W), height: nb.height*CGFloat(H))
}
func fmt(_ r: CGRect) -> String { String(format: "(%.0f,%.0f) %.0fx%.0f", r.minX, r.minY, r.width, r.height) }

let obj = VNGenerateObjectnessBasedSaliencyImageRequest()
let att = VNGenerateAttentionBasedSaliencyImageRequest()
let rectReq = VNDetectRectanglesRequest()
rectReq.maximumObservations = 12; rectReq.minimumConfidence = 0.2; rectReq.minimumAspectRatio = 0.05; rectReq.minimumSize = 0.05
var reqs: [VNRequest] = [obj, att, rectReq]

var instanceReq: VNGenerateForegroundInstanceMaskRequest?
if #available(macOS 14.0, *) { let r = VNGenerateForegroundInstanceMaskRequest(); instanceReq = r; reqs.append(r) }

let handler = VNImageRequestHandler(cgImage: image, options: [:])
do { try handler.perform(reqs) } catch { print("perform 出错:", error) }

func salientBoxes(_ r: VNImageBasedRequest) -> [CGRect] {
    guard let obs = r.results?.first as? VNSaliencyImageObservation, let objs = obs.salientObjects else { return [] }
    return objs.map { toTL($0.boundingBox) }
}

print("\n① objectness 显著物体框(适合“图片分区”):")
let objBoxes = salientBoxes(obj)
print("   数量:", objBoxes.count); for b in objBoxes { print("     -", fmt(b)) }

print("\n② attention 注意力显著框:")
let attBoxes = salientBoxes(att)
print("   数量:", attBoxes.count); for b in attBoxes { print("     -", fmt(b)) }

print("\n③ 前景实例分割(苹果“抠主体”同款,可点选吸附):")
if #available(macOS 14.0, *), let ir = instanceReq {
    if let obs = ir.results?.first as? VNInstanceMaskObservation {
        print("   识别到前景实例数:", obs.allInstances.count, " (0 也正常:合成纯色图未必被判为“主体”)")
    } else { print("   无实例结果") }
} else { print("   需 macOS 14+") }

print("\n④ 矩形区检测(卡片/缩略图):")
if let rects = rectReq.results as? [VNRectangleObservation] {
    print("   数量:", rects.count); for r in rects.prefix(6) { print("     -", fmt(toTL(r.boundingBox)), String(format:"conf=%.2f", r.confidence)) }
}

// 模拟“轻点 → 吸附”:点一个位置,吸附到包含该点、面积最小的显著/矩形框
func snap(at tap: CGPoint) -> CGRect? {
    let all = objBoxes + attBoxes + ((rectReq.results as? [VNRectangleObservation])?.map { toTL($0.boundingBox) } ?? [])
    return all.filter { $0.contains(tap) }.min { $0.width*$0.height < $1.width*$1.height }
}
print("\n===== 模拟“轻点图片 → 吸附” =====")
for tap in [CGPoint(x: W/2, y: H/2), CGPoint(x: 210, y: 430), CGPoint(x: 640, y: 435)] {
    if let s = snap(at: tap) { print("   轻点 \(fmt(CGRect(origin: tap, size: .zero))) → 吸附到 \(fmt(s))") }
    else { print("   轻点 \(fmt(CGRect(origin: tap, size: .zero))) → 无框命中,回退默认框") }
}
