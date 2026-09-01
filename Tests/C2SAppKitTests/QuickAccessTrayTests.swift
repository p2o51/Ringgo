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

    @MainActor
    func testGlobalHoverResumeDoesNotRestartIndividuallyPausedItem() {
        let settings = SettingsStore()
        settings.shotTrayAutoDismiss = true
        settings.shotTrayAutoDismissSeconds = 300
        let tray = QuickAccessTray(settings: settings)
        let editingItem = makeItem(byte: 1)
        let idleItem = makeItem(byte: 2)
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        tray.add(editingItem, on: screen)
        tray.add(idleItem, on: screen)

        tray.pauseAutoDismiss(for: editingItem.id)
        tray.panelHovered = true
        XCTAssertTrue(tray.scheduledAutoDismissItemIDs.isEmpty)

        tray.panelHovered = false

        XCTAssertEqual(tray.scheduledAutoDismissItemIDs, [idleItem.id])
        tray.resumeAutoDismiss(for: editingItem.id)
        XCTAssertEqual(tray.scheduledAutoDismissItemIDs, [editingItem.id, idleItem.id])
        tray.removeAll()
    }

    @MainActor
    func testContextMenuOffersBatchActionsForMultipleItems() {
        let settings = SettingsStore()
        settings.shotTrayAutoDismiss = false
        let tray = QuickAccessTray(settings: settings)
        let first = makeItem(byte: 1)
        let second = makeItem(byte: 2)
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        tray.add(first, on: screen)
        tray.add(second, on: screen)

        let titles = tray.contextMenu(for: first).items.map(\.title)

        XCTAssertTrue(titles.contains(L10n.f("tray.menu.copy_all", "复制全部 %d 个文件", 2)))
        XCTAssertTrue(titles.contains(L10n.t("tray.menu.reveal_all", "在 Finder 中显示全部")))
        XCTAssertTrue(titles.contains(L10n.t("tray.menu.close_all", "全部关闭")))
        tray.removeAll()
    }

    @MainActor
    private func makeItem(byte: UInt8) -> TrayShotItem {
        TrayShotItem(thumbnail: makeImage(), pointSize: CGSize(width: 2, height: 2),
                     data: Data(repeating: byte, count: 32), ext: "png", fileURL: nil)
    }

    private func makeImage() -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 2,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
