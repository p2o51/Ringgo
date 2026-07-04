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
