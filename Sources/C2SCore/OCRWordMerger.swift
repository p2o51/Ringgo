import CoreGraphics

/// 合并整屏 OCR 与定向补刀 OCR 的词表(F17 小框改选文字):
/// 整屏识别对小字可能漏(Vision 对大图内部降采样),补刀 = 裁剪选区单独重识别。
public enum OCRWordMerger {

    /// 补刀词与既有词框重复的丢弃,其余追加到尾部;
    /// 全表重排 id(SelectionEngine 要求 id == 下标),补刀词的 block
    /// 整体偏移到既有 block 之后,不与整屏聚类混淆。
    ///
    /// 重复判定 = IoU > 0.5 **或 交叠占补刀词面积 > 0.6**:
    /// 后者兜住「同文异框」——裁剪截断的半词对整屏全词 IoU 数学上 ≤ 0.5,
    /// CJK 二字块两次识别切分错位也常 < 0.5,但它们都几乎整个落在既有
    /// 词框里;只按 IoU 去重会把重复词当新词追加,选区/搜索串出现
    /// 「Documents Docum」式重复拼接。
    public static func merge(base: [OCRWord], extra: [OCRWord]) -> [OCRWord] {
        let fresh = extra.filter { candidate in
            !base.contains { isDuplicate(of: $0.rect, candidate: candidate.rect) }
        }
        guard !fresh.isEmpty else { return base }

        let blockOffset = (base.map(\.block).max() ?? -1) + 1
        var merged = base
        for word in fresh {
            merged.append(OCRWord(id: merged.count,
                                  text: word.text,
                                  rect: word.rect,
                                  block: blockOffset + word.block))
        }
        return merged
    }

    /// 把旧词表上的选区映射进新词表(引擎重建后按词框找回等价词):
    /// 每个旧词取新表中 IoU 最大且 > 0.5 者;任一词找不到对应 → 整体失败
    /// 返回 nil(调用方按旧语义清选区),绝不返回残缺选区。
    public static func matching(_ selection: [OCRWord], in table: [OCRWord]) -> [OCRWord]? {
        var mapped: [OCRWord] = []
        mapped.reserveCapacity(selection.count)
        for old in selection {
            let best = table
                .map { (word: $0, overlap: iou($0.rect, old.rect)) }
                .max { $0.overlap < $1.overlap }
            guard let best, best.overlap > 0.5 else { return nil }
            mapped.append(best.word)
        }
        return mapped
    }

    /// 重复判定(merge 用):IoU > 0.5,或候选词面积的 60% 以上被既有词覆盖。
    static func isDuplicate(of base: CGRect, candidate: CGRect) -> Bool {
        if iou(base, candidate) > 0.5 { return true }
        let inter = base.intersection(candidate)
        guard !inter.isNull else { return false }
        let candidateArea = candidate.width * candidate.height
        guard candidateArea > 0 else { return false }
        return (inter.width * inter.height) / candidateArea > 0.6
    }

    /// 交并比(IoU);任一面积为零返回 0。
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }
}
