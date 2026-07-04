import CoreGraphics
import Foundation
import Vision
import os
import C2SCore

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Ringgo", category: "OCRService")

/// F3 本地 OCR(机制 §4):单级 `.accurate` 全屏一次、词级框(boundingBox(for:))、
/// BlockClusterer 聚 block、同一 CGImage 实例缓存。调用方已在 detached Task 中执行。
///
/// actor:缓存读写天然串行(并发同图请求第二次直接命中缓存);
/// Vision `perform` 同步阻塞,就在本(后台)隔离域内跑,不再跳线程。
public actor OCRService {

    public init() {}

    /// 全量词级 OCR;返回覆盖层坐标(点,左上原点)的词框,id 恰为 0..<count。
    public func words(in image: CGImage, context: DisplayContext) async -> [OCRWord] {
        if let cached, cached.image === image, cached.context == context {
            return cached.words
        }
        let words = Self.recognize(image: image, context: context)
        cached = Cached(image: image, context: context, words: words)
        return words
    }

    /// 定向补刀 OCR(F17「改选文字」):整屏识别对小字/低对比字可能漏——
    /// Vision 对大图内部降采样;毛玻璃(如 Finder 侧栏)后面的背景一变
    /// (实测:台前调度侧条显隐),文字对比度跟着变,整屏识别时灵时不灵。
    /// 把框选区域裁出来、小图放大后单独识别,词框映射回覆盖层全屏坐标。
    /// 不进整屏缓存;id 从 0 起,由调用方经 OCRWordMerger 并表重排。
    ///
    /// nonisolated:不碰 actor 状态(缓存),不得排在整屏识别后面——
    /// 补刀最需要的时机恰是整屏 OCR 还在飞的时候,排队会让 chip 转圈数秒。
    nonisolated public func words(in image: CGImage,
                                  context: DisplayContext,
                                  focusOn overlayRect: CGRect) async -> [OCRWord] {
        // 裁剪区向外扩 16pt:框边缘切过的词识别成整词而不是半截
        // (半词与整屏全词框 IoU ≤ 0.5,去重不掉会污染词表);
        // 词框保留真实坐标,「选框内词」仍由调用方按词中心判定。
        let padded = overlayRect.insetBy(dx: -16, dy: -16)
        let px = context.pixelRect(fromOverlay: padded)
        guard !px.isNull, px.width >= 4, px.height >= 4,
              let crop = image.cropping(to: px) else { return [] }

        // 小裁剪区放大到 ~512px 档(上限 4×,高质量插值):Vision 对小图里的
        // 小字/低对比字命中率显著更高;放大只改 pixelSize,点坐标不受影响。
        let minDimension = CGFloat(min(crop.width, crop.height))
        let upscale = min(4, max(1, (512 / minDimension).rounded(.up)))
        let recognitionImage = upscale > 1 ? Self.scaled(crop, by: upscale) ?? crop : crop

        // 裁剪图的「迷你上下文」:点尺寸按整屏换算比缩回,recognize 输出的
        // 覆盖层坐标即为「相对裁剪区左上角」,再整体平移回全屏。
        let cropContext = DisplayContext(
            displayID: context.displayID,
            screenFrame: .zero,
            pointSize: CGSize(width: px.width / context.effectiveScaleX,
                              height: px.height / context.effectiveScaleY),
            pixelSize: CGSize(width: recognitionImage.width, height: recognitionImage.height),
            scale: context.scale
        )
        let dx = px.minX / context.effectiveScaleX
        let dy = px.minY / context.effectiveScaleY
        return Self.recognize(image: recognitionImage, context: cropContext).map {
            OCRWord(id: $0.id, text: $0.text,
                    rect: $0.rect.offsetBy(dx: dx, dy: dy), block: $0.block)
        }
    }

    /// 高质量整数倍放大(补刀 OCR 用;失败返回 nil,调用方退回原图)。
    private static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = Int(CGFloat(image.width) * factor)
        let height = Int(CGFloat(image.height) * factor)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - 识别(纯函数)

    private static func recognize(image: CGImage, context: DisplayContext) -> [OCRWord] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // 自动检测开启时仅作提示,不限定语言集
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // 签名不抛错:识别失败降级为"无词"(覆盖层自然走图搜路由),但留痕、不静默
            log.error("OCR 识别失败: \(error.localizedDescription, privacy: .public)")
            return []
        }

        // 每个 observation:词级框(byWords;中文自然按 ~2 字块切,不假设"词")
        // + 整行框(喂 BlockClusterer,行内所有词继承该行 block)
        var lineRects: [CGRect] = []
        var lineWords: [[(text: String, rect: CGRect)]] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let full = cand.string
            var collected: [(text: String, rect: CGRect)] = []
            full.enumerateSubstrings(in: full.startIndex..<full.endIndex,
                                     options: .byWords) { sub, range, _, _ in
                guard let sub, !sub.isEmpty,
                      let box = try? cand.boundingBox(for: range) else { return }
                let rect = context.overlayRect(fromNormalized: box.boundingBox)
                guard rect.width > 0, rect.height > 0 else { return }
                collected.append((sub, rect))
            }
            guard !collected.isEmpty else { continue }
            lineRects.append(context.overlayRect(fromNormalized: obs.boundingBox))
            lineWords.append(collected)
        }

        let blocks = BlockClusterer.assignBlocks(lineRects: lineRects)

        // id 必须与数组下标一致(SelectionEngine 的 precondition)
        var result: [OCRWord] = []
        for (line, ws) in lineWords.enumerated() {
            for w in ws {
                result.append(OCRWord(id: result.count, text: w.text, rect: w.rect, block: blocks[line]))
            }
        }
        return result
    }

    // MARK: - 同图缓存(只留最近一张)

    private struct Cached {
        /// 强引用保证实例身份在缓存生命周期内不会因地址复用产生假命中。
        let image: CGImage
        let context: DisplayContext
        let words: [OCRWord]
    }

    private var cached: Cached?
}
