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
