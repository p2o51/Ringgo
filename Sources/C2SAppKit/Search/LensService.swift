import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import C2SCore

/// F7 Lens 图搜(2026-07-02 改版)。
///
/// 原方案(URLSession multipart 直传 → 拦 302 → WebView 载结果)已被实测否定:
/// Lens 结果页与**上传会话绑定**,URLSession 与 WKWebView 是两个 cookie 世界,
/// 跨会话打开结果页显示 "Image not found";且风控网络下匿名 GET 结果页一律 403
/// (真 WebKit + 表单导航 + cookie 预热逐一验证,均 403;用户已登录的 Chrome 可过)。
///
/// 现方案:生成一张**自动提交的 multipart 上传表单**(内嵌 base64 图片,
/// DataTransfer 注入 File),交给结果面板的 WKWebView 做顶层 POST 导航(免 CORS),
/// WebView 自己跟随 303 落到结果页 —— 上传与查看天然同会话。
/// 面板 WebView 用持久 dataStore:用户在面板里登录过 Google 后,风控 403 即消失。
final class LensService {

    enum LensError: Error, LocalizedError {
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "图片编码失败。"
            }
        }
    }

    static let maxImageDimension: CGFloat = 1600
    static let jpegQuality: Double = 0.85

    /// 裁剪图 → 面板内上传载荷(降采样 ≤1600px → JPEG → 自动提交表单)。
    func uploadPayload(for image: CGImage, attempt: Int = 0) throws -> LensUploadPayload {
        guard let processed = Self.downscaled(image, maxDimension: Self.maxImageDimension),
              let jpeg = Self.jpegEncoded(processed, quality: Self.jpegQuality)
        else { throw LensError.encodingFailed }

        let html = Self.uploadHTML(
            jpegBase64: jpeg.base64EncodedString(),
            pixelSize: CGSize(width: processed.width, height: processed.height),
            languageCode: Locale.preferredLanguages.first ?? "en",
            timestampMillis: Int64(Date().timeIntervalSince1970 * 1000))
        // baseURL 决定表单提交的 Referer/Origin 语义(指向 google.com,与浏览器一致)
        return LensUploadPayload(html: html,
                                 baseURL: URL(string: "https://www.google.com/")!,
                                 attempt: attempt)
    }

    // MARK: - 纯函数(拆小便于单测)

    /// 长边 > maxDimension 时按比例 CGContext 重绘;不超限原样返回,失败 nil。
    static func downscaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longSide = max(w, h)
        guard longSide > maxDimension, longSide > 0 else { return image }

        let scale = maxDimension / longSide
        let newW = max(1, Int((w * scale).rounded()))
        let newH = max(1, Int((h * scale).rounded()))

        let space: CGColorSpace
        if let s = image.colorSpace, s.model == .rgb {
            space = s
        } else {
            space = CGColorSpaceCreateDeviceRGB()
        }
        guard let ctx = CGContext(data: nil,
                                  width: newW,
                                  height: newH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(newW), height: CGFloat(newH)))
        return ctx.makeImage()
    }

    static func jpegEncoded(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 自动提交的 multipart 上传表单。
    /// base64 只含 [A-Za-z0-9+/=],可安全嵌入单引号 JS 字符串;
    /// action URL 的 & 需转义为 &amp;(HTML 属性语境)。
    static func uploadHTML(jpegBase64: String,
                           pixelSize: CGSize,
                           languageCode: String,
                           timestampMillis: Int64) -> String {
        let action = SearchURLBuilder.lensUpload(timestampMillis: timestampMillis,
                                                 languageCode: languageCode,
                                                 viewport: pixelSize)?.absoluteString ?? "https://lens.google.com/v3/upload"
        let escapedAction = action.replacingOccurrences(of: "&", with: "&amp;")
        let dims = "\(Int(pixelSize.width)),\(Int(pixelSize.height))"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{background:transparent}</style></head><body>
        <form id="f" action="\(escapedAction)" method="post" enctype="multipart/form-data">
          <input type="file" name="encoded_image" id="fi" style="display:none">
          <input type="hidden" name="processed_image_dimensions" value="\(dims)">
        </form>
        <script>
          (function() {
            var b64 = '\(jpegBase64)';
            var bin = atob(b64);
            var bytes = new Uint8Array(bin.length);
            for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            var file = new File([bytes], 'image.jpg', {type: 'image/jpeg'});
            var dt = new DataTransfer();
            dt.items.add(file);
            document.getElementById('fi').files = dt.files;
            document.getElementById('f').submit();
          })();
        </script>
        </body></html>
        """
    }
}
