import CoreGraphics
import Foundation
import Vision
import os
import C2SCore

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Ringgo", category: "OCRService")

/// F3 本地 OCR(机制 §4):`.accurate` 全屏**分块识别**、词级框(boundingBox(for:))、
/// BlockClusterer 聚 block、同一 CGImage 实例缓存。调用方已在 detached Task 中执行。
///
/// 分块(F18,2026-07-04):整屏一次识别时 Vision 对大图内部降采样,小字
/// (Finder 侧栏一类)在部分机器/系统版本上**补丁式漏词**——同一栏同字号
/// 「图片/影片」认得出、「桌面/文稿/下载」认不出,笔刷选区中间开洞。
/// 大图切 ≤2048px 瓦片(重叠 128px 防切词)并发识别,词级跨瓦片去重后
/// 全局聚 block,小字召回率恢复到"小图"水平。
public actor OCRService {

    public init() {}

    /// 全量词级 OCR;返回覆盖层坐标(点,左上原点)的词框,id 恰为 0..<count。
    /// (actor 有重入:同图并发请求可能重复识别,结果一致、后写覆盖,无害。)
    public func words(in image: CGImage, context: DisplayContext) async -> [OCRWord] {
        if let cached, cached.image === image, cached.context == context {
            return cached.words
        }
        let words = await Self.recognizeTiled(image: image, context: context)
        // 被取消的会话结果残缺,不得进缓存(旧 image 也不会再被请求)
        guard !Task.isCancelled else { return words }
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
        return Self.recognizeSinglePass(image: recognitionImage, context: cropContext).map {
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

    // MARK: - 识别(纯函数族)

    /// 一行识别结果(覆盖层坐标);tile = 来源瓦片(跨瓦片去重用,单 pass 恒 0)。
    struct RecognizedLine {
        let tile: Int
        let rect: CGRect
        var words: [(text: String, rect: CGRect)]
    }

    /// 单次 Vision pass → 行级结果(坐标 = 给定 context 的覆盖层坐标)。
    private static func recognizeLines(image: CGImage,
                                       context: DisplayContext,
                                       tile: Int = 0) -> [RecognizedLine] {
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
        var lines: [RecognizedLine] = []
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
            lines.append(RecognizedLine(tile: tile,
                                        rect: context.overlayRect(fromNormalized: obs.boundingBox),
                                        words: collected))
        }
        return lines
    }

    /// 行级结果 → 词表(BlockClusterer 聚 block,id == 下标)。
    private static func assemble(_ lines: [RecognizedLine]) -> [OCRWord] {
        let kept = lines.filter { !$0.words.isEmpty }
        let blocks = BlockClusterer.assignBlocks(lineRects: kept.map(\.rect))
        var result: [OCRWord] = []
        for (line, entry) in kept.enumerated() {
            for w in entry.words {
                result.append(OCRWord(id: result.count, text: w.text, rect: w.rect, block: blocks[line]))
            }
        }
        return result
    }

    /// 单 pass 全流程(补刀 OCR 与小图用)。
    private static func recognizeSinglePass(image: CGImage, context: DisplayContext) -> [OCRWord] {
        assemble(recognizeLines(image: image, context: context))
    }

    /// 一片瓦:crop = 送识别的裁剪区(带重叠),territory = 本片专属领地
    /// (无重叠的基础网格单元;词的归属判定用)。
    struct Tile: Equatable {
        let crop: CGRect
        let territory: CGRect
    }

    /// 瓦片划分(像素坐标):列/行数按**有效步距 maxTile − 2×overlap** 计算,
    /// 保证每片 crop 严格 ≤ maxTile(F18 审查 #4:按 maxTile 定列数再加重叠
    /// 会让 4K/6K 屏的内部片超标,Vision 降采样在屏幕中部条带静默复发)。
    /// 相邻 crop 互相重叠 2×overlap,词宽 ≤ 2×overlap 的骑缝词必在某片完整。
    /// 小图恰返回一整片。internal 供单测(覆盖性/上限/领地无缝)。
    static func tiles(pixelSize: CGSize,
                      maxTile: CGFloat = 2048,
                      overlap: CGFloat = 256) -> [Tile] {
        let full = CGRect(origin: .zero, size: pixelSize)
        let step = maxTile - 2 * overlap
        let cols = max(1, Int((pixelSize.width / step).rounded(.up)))
        let rows = max(1, Int((pixelSize.height / step).rounded(.up)))
        guard pixelSize.width > maxTile || pixelSize.height > maxTile else {
            return [Tile(crop: full, territory: full)]
        }
        let baseW = pixelSize.width / CGFloat(cols)
        let baseH = pixelSize.height / CGFloat(rows)
        var result: [Tile] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let territory = CGRect(x: CGFloat(col) * baseW,
                                       y: CGFloat(row) * baseH,
                                       width: baseW, height: baseH)
                let crop = territory.insetBy(dx: -overlap, dy: -overlap)
                    .intersection(full).integral.intersection(full)
                result.append(Tile(crop: crop, territory: territory))
            }
        }
        return result
    }

    /// 领地归属过滤(代替"识别后去重",F18 审查 #1/#3/#5/#6 的根治):
    /// 每片只保留 ① 词框**不触内侧裁剪边**(触边 = 必被切,残词一律不要;
    /// 相邻片对该词有完整视野)且 ② 词中心落在本片领地内的词——每个词恰有
    /// 一个归属,无需跨片去重,也没有"保留哪份"的启发式可选错。
    /// 已知限制:宽 > 2×overlap(即 512px)的巨型词横跨整条重叠带时两片都触边,
    /// 整词丢失(留残词更糟;F17 补刀路径可救)。坐标均为覆盖层点坐标。
    static func ownedWords(_ lines: [RecognizedLine],
                           tile: Tile,
                           fullPixelSize: CGSize,
                           scaleX: CGFloat,
                           scaleY: CGFloat) -> [RecognizedLine] {
        // 内侧裁剪边(点坐标):crop 边不贴图像外边界的才算
        let cropPt = CGRect(x: tile.crop.minX / scaleX, y: tile.crop.minY / scaleY,
                            width: tile.crop.width / scaleX, height: tile.crop.height / scaleY)
        let territoryPt = CGRect(x: tile.territory.minX / scaleX, y: tile.territory.minY / scaleY,
                                 width: tile.territory.width / scaleX, height: tile.territory.height / scaleY)
        let hasLeftEdge = tile.crop.minX > 0.5
        let hasRightEdge = tile.crop.maxX < fullPixelSize.width - 0.5
        let hasTopEdge = tile.crop.minY > 0.5
        let hasBottomEdge = tile.crop.maxY < fullPixelSize.height - 0.5
        let edgeSlop: CGFloat = 1.5 // 触边判定容差(点)

        func owned(_ rect: CGRect) -> Bool {
            if hasLeftEdge, rect.minX <= cropPt.minX + edgeSlop { return false }
            if hasRightEdge, rect.maxX >= cropPt.maxX - edgeSlop { return false }
            if hasTopEdge, rect.minY <= cropPt.minY + edgeSlop { return false }
            if hasBottomEdge, rect.maxY >= cropPt.maxY - edgeSlop { return false }
            // 领地边界上的词中心归属唯一化:左闭右开(相邻领地无缝不重叠)
            return rect.midX >= territoryPt.minX && rect.midX < territoryPt.maxX
                && rect.midY >= territoryPt.minY && rect.midY < territoryPt.maxY
        }

        return lines.compactMap { line in
            let kept = line.words.filter { owned($0.rect) }
            guard !kept.isEmpty else { return nil }
            // 行框重算 = 保留词框并集(丢弃部分不再撑大行框,聚类几何才真实)
            let rect = kept.dropFirst().reduce(kept[0].rect) { $0.union($1.rect) }
            return RecognizedLine(tile: line.tile, rect: rect, words: kept)
        }
    }

    /// 骑缝行段合并(F18 审查 #7):同一视觉行被竖缝切成左右两段行观察,
    /// 各自过滤词后 x 交叠可能为零,BlockClusterer 会把满宽段落聚成两个
    /// block(选择参与区域被缝截断)。把「同一行带(y 中心差 < 行高 0.6)且
    /// x 间隙 < 2×行高」的段合并回一条行(词按 minX 排序)。internal 供单测。
    static func mergeRowSegments(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        var merged: [RecognizedLine] = []
        for line in lines.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            if let i = merged.firstIndex(where: { existing in
                let hLimit = min(existing.rect.height, line.rect.height)
                // 只合并**跨瓦片**的段:同瓦片的分离行是 Vision 自己的分段判断
                // (如菜单栏相邻项),不是缝造成的,不得瞎并
                return existing.tile != line.tile
                    && abs(existing.rect.midY - line.rect.midY) < hLimit * 0.6
                    && line.rect.minX - existing.rect.maxX < max(existing.rect.height, line.rect.height) * 2
                    && line.rect.minX >= existing.rect.minX
            }) {
                let combined = (merged[i].words + line.words).sorted { $0.rect.minX < $1.rect.minX }
                merged[i] = RecognizedLine(tile: merged[i].tile,
                                           rect: merged[i].rect.union(line.rect),
                                           words: combined)
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    /// 全屏分块识别:瓦片并发(≤2 路在飞——Vision 同步 perform 会占住协作
    /// 线程,3 路会在低核机上挤掉补刀 OCR 的执行机会)→ 领地归属过滤 →
    /// 骑缝行段合并 → 全局聚 block。**响应取消**:Esc 退出覆盖层后不再调度
    /// 剩余瓦片(在飞的 Vision pass 无法中断,只能跑完当片)。
    private static func recognizeTiled(image: CGImage, context: DisplayContext) async -> [OCRWord] {
        let tileList = tiles(pixelSize: context.pixelSize)
        guard tileList.count > 1 else {
            return recognizeSinglePass(image: image, context: context)
        }

        let sx = context.effectiveScaleX
        let sy = context.effectiveScaleY
        let pixelSize = context.pixelSize
        var results: [[RecognizedLine]] = Array(repeating: [], count: tileList.count)
        await withTaskGroup(of: (Int, [RecognizedLine]).self) { group in
            var next = 0
            func addNext(_ group: inout TaskGroup<(Int, [RecognizedLine])>) {
                guard next < tileList.count, !Task.isCancelled else { return }
                let index = next
                let tile = tileList[index]
                next += 1
                group.addTask {
                    guard !Task.isCancelled,
                          let crop = image.cropping(to: tile.crop) else { return (index, []) }
                    // 瓦片迷你上下文(同补刀 OCR):识别结果先落瓦片本地点坐标,再平移回全屏
                    let tileContext = DisplayContext(
                        displayID: context.displayID,
                        screenFrame: .zero,
                        pointSize: CGSize(width: tile.crop.width / sx, height: tile.crop.height / sy),
                        pixelSize: tile.crop.size,
                        scale: context.scale
                    )
                    let dx = tile.crop.minX / sx
                    let dy = tile.crop.minY / sy
                    let lines = recognizeLines(image: crop, context: tileContext, tile: index).map {
                        RecognizedLine(tile: $0.tile,
                                       rect: $0.rect.offsetBy(dx: dx, dy: dy),
                                       words: $0.words.map { w in
                                           (w.text, w.rect.offsetBy(dx: dx, dy: dy))
                                       })
                    }
                    return (index, ownedWords(lines, tile: tile, fullPixelSize: pixelSize,
                                              scaleX: sx, scaleY: sy))
                }
            }
            for _ in 0..<min(2, tileList.count) { addNext(&group) }
            while let (index, lines) = await group.next() {
                results[index] = lines
                addNext(&group)
            }
        }
        guard !Task.isCancelled else { return [] }

        return assemble(mergeRowSegments(results.flatMap { $0 }))
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
