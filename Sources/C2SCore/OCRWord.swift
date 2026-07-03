import CoreGraphics

/// 一个可选择的词:文本 + 覆盖层坐标(点,左上原点)矩形 + 所属 block。
/// `id` 在同一批 OCR 结果中稳定唯一(SelectionEngine 以它为索引,要求恰为 0..<count)。
public struct OCRWord: Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let rect: CGRect
    public let block: Int

    public init(id: Int, text: String, rect: CGRect, block: Int) {
        self.id = id
        self.text = text
        self.rect = rect
        self.block = block
    }
}

extension OCRWord: Hashable {
    public static func == (lhs: OCRWord, rhs: OCRWord) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
