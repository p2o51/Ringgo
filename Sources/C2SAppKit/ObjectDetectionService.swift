import CoreGraphics
import Foundation
import Vision
import os
import C2SCore

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "C2S", category: "ObjectDetectionService")

/// F8:抓屏后预跑物体/矩形检测,产出覆盖层坐标候选框(轻点吸附 + hover 提示用)。
///
/// 三路检测合并(与已验证原型 docs/reference/ObjectSnap.reference.swift 一致):
///   ① objectness 显著物体框(图片分区主力)
///   ② attention 注意力显著框(补充)
///   ③ 矩形区检测(卡片/缩略图)
/// TODO: VNGenerateForegroundInstanceMaskRequest(苹果"抠主体"同款)本轮不做——
///       掩膜转 bbox 需逐像素扫 CVPixelBuffer,成本高;后续切片再评估。
///
/// actor:缓存读写天然串行(并发同图请求第二次直接命中缓存);
/// Vision `perform` 同步阻塞,就在本(后台)隔离域内跑,不再跳线程。
/// 调用方与 OCR 并发(detached)调用。
public actor ObjectDetectionService {

    public init() {}

    /// 检测候选框;返回覆盖层坐标(点,左上原点),已经 filtered + IoU 去重、按面积升序。
    /// 失败/无结果返回 [](不抛错,os.Logger 留痕;轻点自然回退默认框)。
    public func regions(in image: CGImage, context: DisplayContext) async -> [CGRect] {
        if let cached, cached.image === image, cached.context == context {
            return cached.boxes
        }
        let boxes = Self.detect(image: image, context: context)
        cached = Cached(image: image, context: context, boxes: boxes)
        return boxes
    }

    // MARK: - 检测(纯函数)

    private static func detect(image: CGImage, context: DisplayContext) -> [CGRect] {
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 12
        rectangles.minimumConfidence = 0.2
        rectangles.minimumAspectRatio = 0.05
        rectangles.minimumSize = 0.05

        // 一个 handler 一次 perform 三个 request(单次图像解码,三路共享)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([objectness, attention, rectangles])
        } catch {
            // 签名不抛错:检测失败降级为"无候选框",但留痕、不静默
            log.error("物体检测失败: \(error.localizedDescription, privacy: .public)")
            return []
        }

        // 三路归一化框(左下原点)合并
        var normalized: [CGRect] = []
        normalized.append(contentsOf: salientBoxes(objectness))
        normalized.append(contentsOf: salientBoxes(attention))
        normalized.append(contentsOf: (rectangles.results ?? []).map(\.boundingBox))
        guard !normalized.isEmpty else { return [] }

        // 归一化左下 → 覆盖层点(左上):唯一一次翻 Y,只走 DisplayContext
        let overlay = normalized.map { context.overlayRect(fromNormalized: $0) }
        let usable = ObjectSnap.filtered(overlay, canvas: context.pointSize)
        return ObjectSnap.dedupe(usable)
    }

    /// 显著性 observation → salientObjects 各自的归一化框(左下原点)。
    private static func salientBoxes(_ request: VNImageBasedRequest) -> [CGRect] {
        guard let obs = request.results?.first as? VNSaliencyImageObservation,
              let objects = obs.salientObjects else { return [] }
        return objects.map(\.boundingBox)
    }

    // MARK: - 同图缓存(只留最近一张,与 OCRService 同思路)

    private struct Cached {
        /// 强引用保证实例身份在缓存生命周期内不会因地址复用产生假命中。
        let image: CGImage
        let context: DisplayContext
        let boxes: [CGRect]
    }

    private var cached: Cached?
}
