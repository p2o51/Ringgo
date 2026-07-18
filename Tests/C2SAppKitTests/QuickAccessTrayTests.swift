import CoreGraphics
import XCTest
@testable import C2SAppKit

final class QuickAccessTrayTests: XCTestCase {
    @MainActor
    func testSpilledDataRemainsReadableAndReleasesResidentCopy() throws {
        let image = makeImage()
        let original = Data(repeating: 0x5a, count: 4_096)
        let item = TrayShotItem(thumbnail: image, pointSize: CGSize(width: 2, height: 2),
                                data: original, ext: "png", fileURL: nil)
        let request = try XCTUnwrap(item.beginSpill())
        try FileManager.default.createDirectory(at: request.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try request.data.write(to: request.url, options: .atomic)

        item.completeSpill(request, succeeded: true)

        XCTAssertEqual(item.residentByteCount, 0)
        XCTAssertEqual(item.data, original)
        item.discardTemporaryStorage()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: request.url.deletingLastPathComponent().path))
    }

    @MainActor
    func testLateSpillCannotReplaceNewFlattenedData() throws {
        let image = makeImage()
        let item = TrayShotItem(thumbnail: image, pointSize: CGSize(width: 2, height: 2),
                                data: Data([1, 2, 3]), ext: "png", fileURL: nil)
        let request = try XCTUnwrap(item.beginSpill())
        try FileManager.default.createDirectory(at: request.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try request.data.write(to: request.url, options: .atomic)
        let replacement = Data([4, 5, 6, 7])

        item.updateFlattened(data: replacement, thumbnail: image,
                             pointSize: CGSize(width: 2, height: 2))
        item.completeSpill(request, succeeded: true)

        XCTAssertEqual(item.residentByteCount, replacement.count)
        XCTAssertEqual(item.data, replacement)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: request.url.deletingLastPathComponent().path))
    }

    private func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 2,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
