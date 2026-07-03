import CoreGraphics

/// F8 物体吸附纯逻辑:候选框过滤 → IoU 去重 → 轻点吸附。
/// 输入输出均为覆盖层坐标(点,左上原点);本类型不关心坐标来源,坐标换算在调用方完成。
public enum ObjectSnap {

    /// 标准 IoU(交集面积 / 并集面积);不相交或并集无面积时为 0。
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    /// IoU 去重:重叠度 ≥ threshold 的框只留面积较小者(更贴物体);输出按面积升序。
    ///
    /// 实现:按面积升序贪心——小框先入选,与已留框高度重叠的大框被淘汰;
    /// 升序遍历顺带保证了输出天然按面积升序。
    public static func dedupe(_ boxes: [CGRect], iouThreshold: CGFloat = 0.8) -> [CGRect] {
        let ascending = boxes.sorted { $0.width * $0.height < $1.width * $1.height }
        var kept: [CGRect] = []
        for box in ascending where kept.allSatisfy({ iou($0, box) < iouThreshold }) {
            kept.append(box)
        }
        return kept
    }

    /// 吸附:含 point 的框中面积最小者;无 → nil(调用方回退默认框)。
    public static func snap(point: CGPoint, boxes: [CGRect]) -> CGRect? {
        boxes.filter { $0.contains(point) }
            .min { $0.width * $0.height < $1.width * $1.height }
    }

    /// 圈选闭合 → 贴合轮廓(原版"手绘圈瞬间转化为贴合裁剪框"):
    /// 优先取「大部分(≥ coverage)落在包围盒内」的候选中**面积最大**者(松圈小物体时,
    /// 圈的主体就是被包住的最大检测框;IoU 在这种场景会因面积悬殊而失效);
    /// 无被包候选时退而取与包围盒 IoU ≥ iouFloor 的最相近者;都没有 → nil(维持手绘框)。
    public static func bestMatch(for enclosure: CGRect, boxes: [CGRect],
                                 coverage: CGFloat = 0.85, iouFloor: CGFloat = 0.45) -> CGRect? {
        let enclosed = boxes.filter { box in
            let inter = box.intersection(enclosure)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { return false }
            let area = box.width * box.height
            guard area > 0 else { return false }
            return (inter.width * inter.height) / area >= coverage
        }
        if let best = enclosed.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return best
        }
        return boxes
            .map { ($0, iou($0, enclosure)) }
            .filter { $0.1 >= iouFloor }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// 过滤明显无用的框:任一边 < minSide(碎屑),或面积 > 屏幕面积 × maxAreaRatio(近全屏,
    /// 吸附它等于没吸附)。保留原始顺序。
    public static func filtered(_ boxes: [CGRect], canvas: CGSize,
                                minSide: CGFloat = 24, maxAreaRatio: CGFloat = 0.9) -> [CGRect] {
        let maxArea = canvas.width * canvas.height * maxAreaRatio
        return boxes.filter {
            $0.width >= minSide && $0.height >= minSide && $0.width * $0.height <= maxArea
        }
    }
}
