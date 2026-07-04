import AppKit

/// 状态栏模板图标(Figma「Ringgo 单色」矢量 PDF,模板渲染随菜单栏明暗自动着色)
public enum C2SMenuBarIcon {
    public static let image: NSImage = {
        guard let url = C2SResourceBundle.shared.url(forResource: "MenuBarIcon", withExtension: "pdf"),
              let source = NSImage(contentsOf: url) else {
            // 资源缺失时退回系统符号,保证状态栏可见可点
            let fallback = NSImage(
                systemSymbolName: "circle.dashed",
                accessibilityDescription: "Ringgo"
            ) ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }

        // 菜单栏里 18pt 原稿会显得占满且细。以 20×16pt 画布缩到 15pt 视觉高度，
        // 再用四个 0.25pt 偏移副本扩一圈 alpha：保持 PDF 的圆润轮廓，同时让小尺寸
        // 笔画比直接缩放更扎实，和相邻的 SF Symbols / 实心状态图标站在一起不发虚。
        let canvasSize = NSSize(width: 20, height: 16)
        let visualHeight: CGFloat = 15
        let visualWidth = visualHeight * source.size.width / source.size.height
        let baseRect = NSRect(
            x: (canvasSize.width - visualWidth) / 2,
            y: (canvasSize.height - visualHeight) / 2,
            width: visualWidth,
            height: visualHeight
        )
        let weightOffsets: [NSPoint] = [
            NSPoint(x: -0.25, y: 0),
            NSPoint(x: 0.25, y: 0),
            NSPoint(x: 0, y: -0.25),
            NSPoint(x: 0, y: 0.25),
            .zero,
        ]
        let icon = NSImage(size: canvasSize, flipped: false) { _ in
            for offset in weightOffsets {
                source.draw(
                    in: baseRect.offsetBy(dx: offset.x, dy: offset.y),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            }
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Ringgo"
        return icon
    }()
}
