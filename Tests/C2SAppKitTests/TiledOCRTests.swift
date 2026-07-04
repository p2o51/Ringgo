import XCTest
import CoreGraphics
import AppKit
import C2SCore
@testable import C2SAppKit

/// F18 分块整屏 OCR:瓦片划分、领地归属、骑缝行段合并、真实 Vision 端到端。
final class TiledOCRTests: XCTestCase {

    // MARK: - 瓦片划分(纯几何)

    /// 小图恰一整片,领地 = 裁剪区 = 全图。
    func testSmallImageIsSingleTile() {
        let tiles = OCRService.tiles(pixelSize: CGSize(width: 1728, height: 1117))
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0].crop, CGRect(x: 0, y: 0, width: 1728, height: 1117))
        XCTAssertEqual(tiles[0].territory, tiles[0].crop)
    }

    /// 大图:crop 严格 ≤ maxTile(审查 #4:含重叠也不得超,否则 Vision 降采样
    /// 在内部片复发)、领地无缝拼满全图、相邻 crop 重叠 ≥ 2×overlap。
    func testTileCropsRespectMaxAndTerritoriesTile() {
        for size in [CGSize(width: 5120, height: 2880),
                     CGSize(width: 6016, height: 3384),   // Pro Display XDR
                     CGSize(width: 4096, height: 2304),
                     CGSize(width: 3456, height: 2234)] { // 16" MBP
            let tiles = OCRService.tiles(pixelSize: size)
            for t in tiles {
                XCTAssertLessThanOrEqual(t.crop.width, 2048, "\(size): crop 超上限 \(t.crop)")
                XCTAssertLessThanOrEqual(t.crop.height, 2048, "\(size): crop 超上限 \(t.crop)")
                XCTAssertTrue(t.crop.contains(t.territory.insetBy(dx: 0.5, dy: 0.5)),
                              "\(size): 领地必须在 crop 内")
            }
            // 领地无缝无重叠拼满全图:面积和 = 全图面积,且随机点恰属一片
            let area = tiles.reduce(CGFloat(0)) { $0 + $1.territory.width * $1.territory.height }
            XCTAssertEqual(area, size.width * size.height, accuracy: 1)
            for _ in 0..<100 {
                let p = CGPoint(x: CGFloat.random(in: 0..<size.width),
                                y: CGFloat.random(in: 0..<size.height))
                XCTAssertEqual(tiles.filter { $0.territory.contains(p) }.count, 1)
            }
        }
    }

    // MARK: - 领地归属(纯几何;点坐标 = 像素坐标,scale 1)

    private func line(tile: Int, words: [(String, CGRect)]) -> OCRService.RecognizedLine {
        let rect = words.map(\.1).reduce(words[0].1) { $0.union($1) }
        return OCRService.RecognizedLine(tile: tile, rect: rect, words: words)
    }

    /// 触内侧裁剪边的残词丢弃;领地内不触边的词保留。
    func testOwnedWordsDropsEdgeClippedWords() {
        let full = CGSize(width: 4000, height: 1000)
        let tile = OCRService.Tile(crop: CGRect(x: 0, y: 0, width: 2048, height: 1000),
                                   territory: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let lines = [line(tile: 0, words: [
            ("完好", CGRect(x: 500, y: 100, width: 60, height: 16)),
            ("残词", CGRect(x: 1990, y: 100, width: 57, height: 16)), // 尾贴 crop 右缘 2047
        ])]
        let kept = OCRService.ownedWords(lines, tile: tile, fullPixelSize: full,
                                         scaleX: 1, scaleY: 1)
        XCTAssertEqual(kept.flatMap(\.words).map(\.0), ["完好"], "贴内侧裁剪边的残词必须丢弃")
    }

    /// 词中心在领地外(重叠带里帮邻片看到的完整词)不归本片。
    func testOwnedWordsRespectTerritory() {
        let full = CGSize(width: 4000, height: 1000)
        let tile = OCRService.Tile(crop: CGRect(x: 0, y: 0, width: 2048, height: 1000),
                                   territory: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let lines = [line(tile: 0, words: [
            ("邻片词", CGRect(x: 2005, y: 100, width: 30, height: 16)), // 中心 2020 > 2000
        ])]
        let kept = OCRService.ownedWords(lines, tile: tile, fullPixelSize: full,
                                         scaleX: 1, scaleY: 1)
        XCTAssertTrue(kept.isEmpty, "中心在邻片领地的词由邻片负责")
    }

    /// 图像外边界不算内侧裁剪边(整屏最左词照常保留)。
    func testImageBoundaryIsNotAnInnerEdge() {
        let full = CGSize(width: 4000, height: 1000)
        let tile = OCRService.Tile(crop: CGRect(x: 0, y: 0, width: 2048, height: 1000),
                                   territory: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let lines = [line(tile: 0, words: [
            ("最左", CGRect(x: 0, y: 100, width: 40, height: 16)), // 贴图像左缘
        ])]
        let kept = OCRService.ownedWords(lines, tile: tile, fullPixelSize: full,
                                         scaleX: 1, scaleY: 1)
        XCTAssertEqual(kept.flatMap(\.words).count, 1)
    }

    // MARK: - 骑缝行段合并

    /// 跨瓦片同行两段合并成一条(词按 x 序),BlockClusterer 才能看到整行。
    func testRowSegmentsAcrossTilesMerge() {
        let left = line(tile: 0, words: [
            ("左段", CGRect(x: 100, y: 100, width: 40, height: 16)),
        ])
        let right = line(tile: 1, words: [
            ("右段", CGRect(x: 150, y: 100, width: 40, height: 16)),
        ])
        let merged = OCRService.mergeRowSegments([left, right])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].words.map(\.0), ["左段", "右段"])
    }

    /// 同瓦片的分离行(Vision 自己的分段,如菜单栏相邻项)不合并。
    func testSameTileSegmentsUntouched() {
        let a = line(tile: 0, words: [("项一", CGRect(x: 100, y: 100, width: 40, height: 16))])
        let b = line(tile: 0, words: [("项二", CGRect(x: 150, y: 100, width: 40, height: 16))])
        XCTAssertEqual(OCRService.mergeRowSegments([a, b]).count, 2)
    }

    /// 不同行(y 差大)或间隙过大的不合并。
    func testDistantSegmentsUntouched() {
        let a = line(tile: 0, words: [("上行", CGRect(x: 100, y: 100, width: 40, height: 16))])
        let b = line(tile: 1, words: [("下行", CGRect(x: 100, y: 140, width: 40, height: 16))])
        let c = line(tile: 1, words: [("远词", CGRect(x: 400, y: 100, width: 40, height: 16))])
        XCTAssertEqual(OCRService.mergeRowSegments([a, b, c]).count, 3)
    }

    // MARK: - 真实 Vision 端到端(强制多瓦片)

    /// 4000×2400 四象限 + 竖缝上一词:全部识别、各恰一次、坐标归位。
    func testTiledRecognitionFindsAllWordsExactlyOnce() async {
        let sizePx = CGSize(width: 4000, height: 2400)
        let tiles = OCRService.tiles(pixelSize: sizePx)
        XCTAssertGreaterThan(tiles.count, 1, "该尺寸必须触发分块")
        // 找一条竖直领地边界,把骑缝词放上去
        let seamX = tiles.first(where: { $0.territory.minX > 0 })!.territory.minX

        let ctx = CGContext(data: nil, width: 4000, height: 2400,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(origin: .zero, size: sizePx))
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let placements: [(String, CGPoint)] = [
            ("Quadrant", CGPoint(x: 600, y: 500)),
            ("Sidebar", CGPoint(x: 3000, y: 500)),
            ("Desktop", CGPoint(x: 600, y: 1900)),
            ("Download", CGPoint(x: 3000, y: 1900)),
            ("Seamword", CGPoint(x: seamX - 100, y: 1200)), // 骑领地边界
        ]
        for (text, p) in placements {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 40, weight: .medium),
                .foregroundColor: NSColor.black,
            ]).draw(at: NSPoint(x: p.x, y: sizePx.height - p.y - 52))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = ctx.makeImage()!

        let context = DisplayContext(displayID: 1,
                                     screenFrame: CGRect(origin: .zero, size: sizePx),
                                     pointSize: sizePx, pixelSize: sizePx, scale: 1)
        let words = await OCRService().words(in: image, context: context)

        for (text, p) in placements {
            let hits = words.filter { $0.text.localizedCaseInsensitiveContains(text) }
            XCTAssertEqual(hits.count, 1, "\(text) 应恰好识别一次,实际 \(hits.count):\(hits.map(\.rect))")
            if let hit = hits.first {
                XCTAssertTrue(abs(hit.rect.midY - (p.y + 26)) < 40,
                              "\(text) 词框应映射回原位,实际 \(hit.rect)")
            }
        }
        XCTAssertEqual(words.map(\.id), Array(0..<words.count))
    }
}
