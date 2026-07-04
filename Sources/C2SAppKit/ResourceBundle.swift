import Foundation

/// 安全定位 SwiftPM 打进 .app 包里的资源 bundle(MenuBarIcon.pdf / default.metallib
/// 所在处),不依赖自动生成的 `Bundle.module`(它只认 `Bundle.main.bundleURL`
/// 即 .app 包根目录拼 bundle 名,不知道标准 macOS Contents/Resources 这层约定;
/// 另一条兜底路径是编译机写死的 `.build/...` 绝对路径,只在开发机上存在——两条
/// 都找不到时直接 fatalError,在任何非开发机上必现,且往往在 App 尚未完成启动
/// 前就把整个进程带走)。
enum C2SResourceBundle {
    static let shared: Bundle = {
        guard let resourceURL = Bundle.main.resourceURL,
              let bundle = Bundle(url: resourceURL.appendingPathComponent("C2S_C2SAppKit.bundle"))
        else { return .main }
        return bundle
    }()
}
