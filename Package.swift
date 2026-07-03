// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "C2S",
    platforms: [.macOS(.v14)],
    targets: [
        // 纯逻辑核心:选词引擎/坐标/几何/multipart 等,零 AppKit 依赖,可单测
        .target(
            name: "C2SCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 应用层库:AppKit/Vision/SCK/WebKit 服务与 UI(可被测试 target 导入)
        .target(
            name: "C2SAppKit",
            dependencies: ["C2SCore"],
            // 命令行 SwiftPM 不编 Metal(只有 Xcode 会)→ 预编译 default.metallib 进仓库,
            // .metal 源仅存档;改 shader 后跑 Scripts/build-shaders.sh 重新生成。
            exclude: ["Shaders/OverlayEffects.metal"],
            resources: [.copy("Shaders/default.metallib")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 可执行入口(@main,越薄越好)
        .executableTarget(
            name: "C2S",
            dependencies: ["C2SAppKit", "C2SCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "C2SCoreTests",
            dependencies: ["C2SCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "C2SAppKitTests",
            dependencies: ["C2SAppKit", "C2SCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
