import Foundation

/// 截图落盘文件名模板(F20,spec §6):
/// 默认 `Ringgo {date} at {time}` → `Ringgo 2026-07-16 at 14.22.33.png`。
/// `{date}` = yyyy-MM-dd,`{time}` = HH.mm.ss(点号避开冒号,跨文件系统安全);
/// 格式与 locale 无关(文件名是契约,不跟随系统区域设置)。
public enum FilenameTemplate {
    /// 展开模板变量并清洗文件名非法字符。空结果回落 "Ringgo"。
    public static func expand(_ template: String, date: Date, timeZone: TimeZone = .current) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = timeZone
        df.dateFormat = "yyyy-MM-dd"
        let dateText = df.string(from: date)
        df.dateFormat = "HH.mm.ss"
        let timeText = df.string(from: date)

        let expanded = template
            .replacingOccurrences(of: "{date}", with: dateText)
            .replacingOccurrences(of: "{time}", with: timeText)
        return sanitize(expanded)
    }

    /// 同名冲突追加 ` (n)`(spec §6):`exists` 由调用方提供(文件系统或测试桩),
    /// 传入参数为**含扩展名**的完整文件名。
    public static func resolveCollision(base: String, ext: String, exists: (String) -> Bool) -> String {
        let first = "\(base).\(ext)"
        if !exists(first) { return first }
        var n = 2
        while true {
            let candidate = "\(base) (\(n)).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// 文件名清洗:HFS+/APFS 的 `:` 与 POSIX 的 `/` 替换为 `-`,去首尾空白与前导点。
    static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Ringgo" : cleaned
    }
}
