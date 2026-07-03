import XCTest
import CoreGraphics
@testable import C2SCore

final class SearchURLBuilderTests: XCTestCase {

    func testGoogleSearchURL() throws {
        let url = try XCTUnwrap(SearchURLBuilder.googleSearch(query: "hello 世界",
                                                              viewport: CGSize(width: 1512, height: 982)))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "www.google.com")
        XCTAssertEqual(comps.path, "/search")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["q"], "hello 世界")
        XCTAssertEqual(items["cs"], "1", "深色参数")
        XCTAssertEqual(items["biw"], "1512")
        XCTAssertEqual(items["bih"], "982")
    }

    func testGoogleSearchQueryIsPercentEncoded() throws {
        let url = try XCTUnwrap(SearchURLBuilder.googleSearch(query: "a&b=c 中文"))
        let s = url.absoluteString
        XCTAssertFalse(s.contains("a&b=c"), "特殊字符必须被编码: \(s)")
        XCTAssertTrue(s.contains("q=a%26b%3Dc%20%E4%B8%AD%E6%96%87") || s.contains("q=a%26b%3Dc+%E4%B8%AD%E6%96%87"))
    }

    func testGoogleSearchAIMode() throws {
        let url = try XCTUnwrap(SearchURLBuilder.googleSearch(query: "将下面的文字翻译成日语:hello", aiMode: true))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["udm"], "50", "AI Mode 参数")
        // 普通搜索不得带 udm
        let plain = try XCTUnwrap(SearchURLBuilder.googleSearch(query: "hello"))
        XCTAssertFalse(plain.absoluteString.contains("udm="))
    }

    // MARK: - Lens multisearch(图+文,F11 v2)

    func testLensMultisearchReplacesQueryOnVsridURL() throws {
        let base = try XCTUnwrap(URL(string:
            "https://www.google.com/search?vsrid=ABC&vsint=DEF&udm=26&gsessionid=G1&q=old"))
        let url = try XCTUnwrap(SearchURLBuilder.lensMultisearch(currentResultURL: base, text: "红色 版本"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["q"], "红色 版本", "q 被替换")
        XCTAssertEqual(items["vsrid"], "ABC", "图片会话参数必须原样保留(图不被顶掉)")
        XCTAssertEqual(items["gsessionid"], "G1")
        XCTAssertEqual((comps.queryItems ?? []).filter { $0.name == "q" }.count, 1, "只留一个 q")
    }

    func testLensMultisearchRejectsNonLensSessionURL() throws {
        // 无 vsrid 的普通文字搜索页 → nil(调用方降级为纯文字搜索)
        let plain = try XCTUnwrap(URL(string: "https://www.google.com/search?q=hello"))
        XCTAssertNil(SearchURLBuilder.lensMultisearch(currentResultURL: plain, text: "x"))
        // 非 google 域 → nil
        let other = try XCTUnwrap(URL(string: "https://example.com/search?vsrid=ABC"))
        XCTAssertNil(SearchURLBuilder.lensMultisearch(currentResultURL: other, text: "x"))
        // google 非 /search 路径 → nil
        let login = try XCTUnwrap(URL(string: "https://accounts.google.com/ServiceLogin?vsrid=ABC"))
        XCTAssertNil(SearchURLBuilder.lensMultisearch(currentResultURL: login, text: "x"))
    }

    func testLensUploadURL() throws {
        let url = try XCTUnwrap(SearchURLBuilder.lensUpload(timestampMillis: 1_700_000_000_123,
                                                            languageCode: "zh-CN",
                                                            viewport: CGSize(width: 1512, height: 982)))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.host, "lens.google.com")
        XCTAssertEqual(comps.path, "/v3/upload")
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["st"], "1700000000123")
        XCTAssertEqual(items["hl"], "zh-CN")
        XCTAssertEqual(items["vpw"], "1512")
        XCTAssertEqual(items["vph"], "982")
    }
}
