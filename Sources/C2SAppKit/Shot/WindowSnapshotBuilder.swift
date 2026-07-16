import AppKit
import ScreenCaptureKit
import C2SCore

/// F20/F24 会话级窗口快照(spec S1/§8):热键按下时现拉、会话结束丢弃——
/// **不许**读 CaptureService 的长寿命 SCShareableContent 缓存(窗口 frame 与
/// z-order 会陈旧,整窗高亮/命中会对不上冻结帧)。
///
/// 两个信息源各取所长:
/// - `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`:**文档保证** front-to-back
///   顺序 + 几何(点,CG 全局坐标),做命中真源;不赌 SCShareableContent.windows
///   的无文档数组顺序(spec §8)。
/// - `SCShareableContent`(现拉):按 windowID 对齐,供整窗实抓用 SCWindow。
enum WindowSnapshotBuilder {

    /// 可命中窗口列表(front-to-back,覆盖层本地坐标)。同步、便宜(~ms),
    /// 在覆盖层出现时调用。过滤:普通层(layer==0)、排除自家 PID、alpha>0、
    /// 最小尺寸、与抓取屏相交。
    @MainActor
    static func pickables(for context: DisplayContext) -> [PickableWindow] {
        let mainHeight = mainDisplayHeightPoints()
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let viewport = CGRect(origin: .zero, size: context.pointSize)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var result: [PickableWindow] = []
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let number = entry[kCGWindowNumber as String] as? Int
            else { continue }
            // 透明幽灵窗不参与命中(SCWindow 不暴露 alpha,只有这里拿得到)
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgBounds.width >= 40, cgBounds.height >= 40
            else { continue }
            let overlayFrame = context.overlayRect(fromCGGlobal: cgBounds,
                                                   mainDisplayHeight: mainHeight)
            guard overlayFrame.intersects(viewport) else { continue }
            result.append(PickableWindow(windowID: UInt32(clamping: number),
                                         frame: overlayFrame,
                                         title: entry[kCGWindowName as String] as? String,
                                         ownerPID: pid))
        }
        return result
    }

    /// 现拉一份 windowID → SCWindow(整窗实抓用);慢(几十 ms),与抓屏并行发起。
    static func freshSCWindows() async -> [UInt32: SCWindow] {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return [:] }
        var map: [UInt32: SCWindow] = [:]
        for window in content.windows { map[window.windowID] = window }
        return map
    }

    /// CG↔AppKit 全局系互翻的基准轴 = 主屏(NSScreen.screens.first)点高度。
    @MainActor
    static func mainDisplayHeightPoints() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }
}
