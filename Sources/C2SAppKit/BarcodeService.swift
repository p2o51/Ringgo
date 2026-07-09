import CoreGraphics
import Foundation
import Vision
import os
import C2SCore

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Ringgo", category: "BarcodeService")

/// F9 二维码检测(切片一):在圈选裁剪出的图上跑 `VNDetectBarcodesRequest`,与 OCR 并行。
/// 只认 2D 码族(QR/Aztec/DataMatrix/PDF417 等,承载 URL/文本);一维商品码不做
/// 「跳内容」(payload 是数字,无意义)。取包围盒**面积最大**的观测 —— 裁剪偶尔框到
/// 两个码时,选用户真正圈住的那个。
///
/// actor 天然离主线程;不做同图缓存 —— crop 每次都是新 `CGImage` 实例
/// (`cap.image.cropping(to:)`),`===` 缓存永不命中,小图检测本就快。
public actor BarcodeService {

    public init() {}

    /// 检测裁剪图里的二维码,返回分类后的结果;无码 / 无字符串 payload → nil。
    public func detect(in image: CGImage) -> BarcodeResult? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = Self.symbologies
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // 签名不抛错:检测失败降级为「无码」(选区照常图搜),但留痕、不静默
            log.error("二维码检测失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // 面积最大的码 = 用户圈住的主体(裁剪偶含多码时的取舍)
        let best = (request.results ?? []).max {
            Self.area($0.boundingBox) < Self.area($1.boundingBox)
        }
        guard let payload = best?.payloadStringValue, !payload.isEmpty else { return nil }
        return BarcodePayload.classify(payload)
    }

    /// 只认 2D 码族(承载 URL/文本);全部在 macOS 14 无条件可用,无需 `@available`。
    private static let symbologies: [VNBarcodeSymbology] = [
        .qr, .microQR, .aztec, .dataMatrix, .pdf417, .microPDF417
    ]

    private static func area(_ box: CGRect) -> CGFloat { box.width * box.height }
}
