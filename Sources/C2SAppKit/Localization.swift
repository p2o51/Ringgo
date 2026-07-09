import Foundation

/// 运行时本地化查表。所有面向用户的字符串统一走这里:
///   - key : 语义点分键,对应 Resources/*.lproj/Localizable.strings 里的条目;
///   - zh  : 中文基线,同时作为「无 .lproj 上下文」(裸 SPM 二进制 / 单元测试)时的兜底值。
///
/// 组装后的 .app 会在 Contents/Resources/{zh-Hans,en,ja}.lproj 里查表
/// (Scripts/build-app.sh 从仓库 Resources/*.lproj 拷入);语言按系统首选语言 /
/// 「系统设置 → App 语言」偏好自动选择,基线区域 = zh-Hans(见 Info.plist)。
///
/// 刻意走 Bundle.main(= .app 包)而非 Bundle.module:后者由 SwiftPM 生成的
/// 访问器在非开发机上定位不稳(见 ResourceBundle.swift 注释);.lproj 直接放在
/// .app 的 Contents/Resources 下,Bundle.main 查表最稳。
enum L10n {
    /// 普通字符串:命中语言表则返回译文,否则返回中文基线 `zh`。
    static func t(_ key: String, _ zh: String) -> String {
        Bundle.main.localizedString(forKey: key, value: zh, table: nil)
    }

    /// 带参数的格式化字符串:格式串本身也在语言表里,占位符(%@/%d/%1$@…)
    /// 与中文基线严格一一对应(由 l10n.json 生成时校验),`String(format:)` 不会错位。
    static func f(_ key: String, _ zh: String, _ args: CVarArg...) -> String {
        String(format: t(key, zh), arguments: args)
    }
}
