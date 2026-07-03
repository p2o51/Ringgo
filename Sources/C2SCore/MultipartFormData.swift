import Foundation

/// 正确的 multipart/form-data 构造器。
///
/// 原项目教训(机制 §7):双反斜杠转义把 `\(boundary)` 和 `\r\n` 写成了字面量,
/// multipart body 损坏导致图搜全挂。这里:真 CRLF、单反斜杠插值、
/// header 里的 boundary 与 body 分隔符严格一致,并有字节级单测背书。
public struct MultipartFormData {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "c2s-" + UUID().uuidString) {
        self.boundary = boundary
    }

    /// 放进 `Content-Type` 请求头的完整值。
    public var contentTypeHeaderValue: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public mutating func appendField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public mutating func appendFile(name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// 追加收尾分隔符后的完整 HTTP body。
    public func finalizedBody() -> Data {
        var d = body
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }

    private mutating func append(_ s: String) {
        body.append(Data(s.utf8))
    }
}
