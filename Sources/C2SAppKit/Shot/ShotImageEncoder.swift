import AppKit
import ImageIO
import UniformTypeIdentifiers

/// F20 产物编码(spec S2):PNG(默认/窗口截图强制)+ TIFF(剪贴板兼容老应用)
/// + JPG(可选,q0.9)。全部写入像素密度元数据(Retina 2× 帧标 144 DPI),
/// 否则粘进 Pages/Word 会以 2× 物理尺寸呈现——系统截图/CleanShot 同款行为。
/// 纯函数,拆小便于替换与单测。
enum ShotImageEncoder {

    static func pngData(_ image: CGImage, pointSize: CGSize) -> Data? {
        encode(image, type: UTType.png, options: dpiOptions(for: image, pointSize: pointSize))
    }

    static func jpegData(_ image: CGImage, pointSize: CGSize, quality: Double = 0.9) -> Data? {
        var options = dpiOptions(for: image, pointSize: pointSize)
        options[kCGImageDestinationLossyCompressionQuality] = quality
        return encode(image, type: UTType.jpeg, options: options)
    }

    /// 一批 Office/Java/Electron 系应用只认 TIFF(spec S2:剪贴板 PNG+TIFF 双 representation);
    /// alpha 同样保留。rep.size = 点尺寸 ⇒ TIFF 自带正确物理尺寸。
    static func tiffData(_ image: CGImage, pointSize: CGSize) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        if pointSize.width > 0, pointSize.height > 0 { rep.size = pointSize }
        return rep.tiffRepresentation
    }

    /// 像素密度:72 × (像素/点)。pointSize 缺失时不写(等效 72 DPI)。
    private static func dpiOptions(for image: CGImage, pointSize: CGSize) -> [CFString: Any] {
        guard pointSize.width > 0, pointSize.height > 0 else { return [:] }
        return [
            kCGImagePropertyDPIWidth: 72.0 * Double(image.width) / Double(pointSize.width),
            kCGImagePropertyDPIHeight: 72.0 * Double(image.height) / Double(pointSize.height),
        ]
    }

    private static func encode(_ image: CGImage, type: UTType, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData,
                                                          type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, options.isEmpty ? nil : options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
