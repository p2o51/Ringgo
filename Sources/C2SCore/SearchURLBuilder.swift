import Foundation
import CoreGraphics

/// 搜索/Lens URL 构造(纯函数,可单测)。
public enum SearchURLBuilder {

    /// 文本搜索:`https://www.google.com/search?q=…&gsc=2&cs=1&biw=&bih=`(cs=1 深色)。
    public static func googleSearch(query: String, viewport: CGSize? = nil, darkMode: Bool = true) -> URL? {
        guard var comps = URLComponents(string: "https://www.google.com/search") else { return nil }
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "gsc", value: "2")]
        if darkMode { items.append(URLQueryItem(name: "cs", value: "1")) }
        if let v = viewport, v.width > 0, v.height > 0 {
            items.append(URLQueryItem(name: "biw", value: String(Int(v.width))))
            items.append(URLQueryItem(name: "bih", value: String(Int(v.height))))
        }
        comps.queryItems = items
        return comps.url
    }

    /// Lens multisearch(图+文,features F11):在**当前结果页 URL**上追加/替换 `q=<text>`。
    /// 结果页 URL 里的 vsrid/gsessionid 等参数承载图片会话 —— 保留它们、只动 q,
    /// 图就不会被顶掉(与谷歌移动版「添加更多搜索条件」同机制)。
    /// 非 Lens 会话 URL(无 vsrid / 非 google /search)返回 nil,调用方降级为纯文字搜索。
    public static func lensMultisearch(currentResultURL: URL, text: String) -> URL? {
        guard var comps = URLComponents(url: currentResultURL, resolvingAgainstBaseURL: false),
              let host = comps.host?.lowercased(),
              host == "google.com" || host.hasSuffix(".google.com"),
              comps.path == "/search"
        else { return nil }
        var items = comps.queryItems ?? []
        guard items.contains(where: { $0.name == "vsrid" }) else { return nil }
        items.removeAll { $0.name == "q" }
        items.append(URLQueryItem(name: "q", value: text))
        comps.queryItems = items
        return comps.url
    }

    /// Lens 直传端点:`https://lens.google.com/v3/upload?ep=…&st=<毫秒>&hl=<语言>&vpw=&vph=`。
    /// 端点是逆向的、可能失效;调用方需备好错误态与降级(features F7)。
    public static func lensUpload(timestampMillis: Int64,
                                  languageCode: String,
                                  viewport: CGSize,
                                  entryPoint: String = "ccm") -> URL? {
        guard var comps = URLComponents(string: "https://lens.google.com/v3/upload") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "ep", value: entryPoint),
            URLQueryItem(name: "re", value: "dcsp"),
            URLQueryItem(name: "s", value: "4"),
            URLQueryItem(name: "st", value: String(timestampMillis)),
            URLQueryItem(name: "hl", value: languageCode),
            URLQueryItem(name: "vpw", value: String(Int(viewport.width))),
            URLQueryItem(name: "vph", value: String(Int(viewport.height))),
        ]
        return comps.url
    }
}
