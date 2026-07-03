import CoreGraphics
import Foundation
import C2SCore

/// F5/F7 检索门面:文本查询 URL + Lens 直传图搜。
public final class SearchService {

    private let lens = LensService()

    public init() {}

    public func textSearchURL(query: String, viewport: CGSize?) -> URL? {
        SearchURLBuilder.googleSearch(query: query, viewport: viewport)
    }

    /// 裁剪图 → 面板内 Lens 上传载荷(上传必须与展示同 WebView 会话,见 LensService 注释)。
    public func lensUploadPayload(for image: CGImage, attempt: Int = 0) throws -> LensUploadPayload {
        try lens.uploadPayload(for: image, attempt: attempt)
    }
}
