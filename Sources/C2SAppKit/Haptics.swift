import AppKit

/// 触控板触觉反馈(Force Touch 触控板才有输出,鼠标/旧触控板安全无操作)。
/// 原则:只在「状态确认的瞬间」给一下,绝不在拖动过程中连发。
enum Haptics {
    /// 通用确认:选区定格、新框落定。
    static func confirm() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// 对齐类:轻点选词、手柄/矩形调整落点。
    static func align() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// 跨过阈值:蓄力到点触发。
    static func fire() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
