import AppKit
import ScreenCaptureKit

/// F20 整窗实抓(spec S2 技术定案):快门时刻对活窗口单窗抓取——透明圆角与
/// 被遮挡内容只有实抓给得了(冻结帧裁不出)。阴影**不赌系统默认值**:显式
/// `ignoreShadowsSingleWindow = true` 拿无阴影透明位图,再自绘合成投影
/// (固定常量,效果稳定可控,不依赖已弃用的 CGWindowList 截图 API)。
enum WindowCaptureService {

    struct Output {
        let image: CGImage
        /// 点尺寸(含阴影边距;NSImage(size:) / 托盘缩略图用)。
        let pointSize: CGSize
        /// 阴影合成的外扩边距(点;未合成 = .zero)。
        /// F23 钉图「按窗口框对齐原位」要用它把 origin 反向外扩,否则内容整体偏 36pt。
        let shadowInsets: NSEdgeInsets
    }

    /// 阴影参数(点;spec S2「固定 radius/offset/opacity 常量」)。
    private static let shadowBlur: CGFloat = 24
    private static let shadowOffsetY: CGFloat = -10 // CG 坐标 y 向上,负 = 投影朝下
    private static let shadowAlpha: CGFloat = 0.38

    static func capture(window: SCWindow, includeShadow: Bool) async throws -> Output {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let contentRect = filter.contentRect

        let config = SCStreamConfiguration()
        // 尺寸真源 = filter.contentRect × pointPixelScale(macOS 14.0 可用,spec S2)
        config.width = max(2, Int(contentRect.width * scale))
        config.height = max(2, Int(contentRect.height * scale))
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        config.showsCursor = false
        if #available(macOS 14.2, *) {
            // sheet/附着面板/popover 一起抓(14.0/14.1 系统限制:不含,spec §10 如实接受)。
            // 注意:开启后 contentRect 可能随子窗口联合外接框扩大 → §11 原型验证项。
            config.includeChildWindows = true
        }

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: config)
        let effectiveScale = scale > 0 ? scale : 2
        guard includeShadow, let composed = composeShadow(on: image, scale: effectiveScale) else {
            return Output(image: image,
                          pointSize: CGSize(width: CGFloat(image.width) / effectiveScale,
                                            height: CGFloat(image.height) / effectiveScale),
                          shadowInsets: NSEdgeInsets())
        }
        // 与 composeShadow 的 margin 计算保持同源(点值 = 像素 margin / scale)
        let blur = shadowBlur * effectiveScale
        let marginX = ceil(blur * 1.5) / effectiveScale
        let marginTop = ceil(blur * 1.5) / effectiveScale
        let marginBottom = ceil(blur * 1.5 + abs(shadowOffsetY * effectiveScale)) / effectiveScale
        return Output(image: composed,
                      pointSize: CGSize(width: CGFloat(composed.width) / effectiveScale,
                                        height: CGFloat(composed.height) / effectiveScale),
                      shadowInsets: NSEdgeInsets(top: marginTop, left: marginX,
                                                 bottom: marginBottom, right: marginX))
    }

    /// 无阴影透明位图 → 更大的透明画布 + CGContext.setShadow 合成投影
    /// (投影由窗口自身 alpha 生成,圆角天然贴合)。
    private static func composeShadow(on image: CGImage, scale: CGFloat) -> CGImage? {
        let blur = shadowBlur * scale
        let offsetY = shadowOffsetY * scale
        let marginX = ceil(blur * 1.5)
        let marginTop = ceil(blur * 1.5)
        let marginBottom = ceil(blur * 1.5 + abs(offsetY))
        let width = image.width + Int(marginX) * 2
        let height = image.height + Int(marginTop) + Int(marginBottom)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setShadow(offset: CGSize(width: 0, height: offsetY),
                      blur: blur,
                      color: CGColor(gray: 0, alpha: shadowAlpha))
        ctx.draw(image, in: CGRect(x: marginX, y: marginBottom,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }
}
