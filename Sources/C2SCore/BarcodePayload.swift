import Foundation

/// 二维码 payload 的意图分类(纯逻辑,可单测)。
/// URL 只认 http/https;其余(mailto/tel/WIFI/vCard/纯文本…)一律归文本,
/// 由调用方截断显示 + 复制全文。
public enum BarcodeContent: Equatable {
    case url(URL)
    case text(String)
}

/// 二维码解码结果:`payload` 保留**完整原文**(截断只在视图层做,复制复制全文),
/// `content` 是分类后的意图。
public struct BarcodeResult: Equatable {
    public let payload: String
    public let content: BarcodeContent

    public init(payload: String, content: BarcodeContent) {
        self.payload = payload
        self.content = content
    }
}

public enum BarcodePayload {
    /// 可「直接打开」的 scheme —— 本切片只跳网址。
    private static let openableSchemes: Set<String> = ["http", "https"]

    /// 分类 payload。**必须显式判 scheme + host**:macOS 14 起 `URL(string:)` 对垃圾串
    /// 也不返回 nil(宽松解析、按需百分号转义),靠「解析成功」判 URL 会把
    /// `hello world` 也当成链接。URL 分支:trim 后 scheme ∈ {http,https} 且 host 非空。
    /// 裸域(如 `example.com`,scheme 为 nil)按文本处理,符合「只跳明确网址」的约定。
    public static func classify(_ raw: String) -> BarcodeResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           openableSchemes.contains(scheme),
           let host = url.host, !host.isEmpty {
            return BarcodeResult(payload: raw, content: .url(url))
        }
        return BarcodeResult(payload: raw, content: .text(raw))
    }
}
