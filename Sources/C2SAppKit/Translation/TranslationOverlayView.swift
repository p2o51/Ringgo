import AppKit
import SwiftUI

/// 翻译盖板层:逐行盖住原文并显示译文,顶部小胶囊显示进度/错误。
/// 全屏铺在覆盖层视图树中(坐标 = 覆盖层点,左上原点)。
@available(macOS 15.0, *)
struct TranslationOverlayView: View {
    @ObservedObject var controller: TranslationController
    let reduceEffects: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var noMotion: Bool { reduceEffects || reduceMotion }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if controller.state == .shown {
                platesLayer
                    .transition(.opacity)
                    .allowsHitTesting(false) // 盖板纯视觉,不截手势
            }
            statusLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(noMotion ? nil : .easeOut(duration: 0.15), value: controller.state)
    }

    // MARK: 译文盖板

    private var platesLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(controller.plates) { plate in
                plateView(plate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func plateView(_ plate: TranslatedPlate) -> some View {
        // 外扩 1pt,盖净原文行边缘
        let box = plate.rect.insetBy(dx: -1, dy: -1)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return ZStack(alignment: .leading) {
            shape.fill(.thinMaterial)
            shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            Text(plate.text)
                .font(.system(size: plate.rect.height * 0.68))
                .minimumScaleFactor(0.35)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: box.width, height: box.height, alignment: .leading)
        .offset(x: box.minX, y: box.minY)
        .accessibilityLabel(plate.text)
    }

    // MARK: 顶部状态指示

    @ViewBuilder
    private var statusLayer: some View {
        Group {
            switch controller.state {
            case .preparing:
                progressCapsule(text: L10n.t("translate.translating", "翻译中…"))
            case .translating(let done, let total):
                progressCapsule(text: L10n.f("translate.translating_progress", "翻译中 %1$d/%2$d", done, total))
            case .failed(let message):
                failureCard(message: message)
            case .needsDownload(let desc):
                downloadCard(desc: desc)
            case .idle, .shown:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 16)
    }

    private func progressCapsule(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .toolbarGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func downloadCard(desc: String) -> some View {
        let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
            Text(L10n.f("translate.needs_download", "需要先下载 %@ 翻译模型", desc))
                .font(.callout)
                .foregroundStyle(.primary)
            Button(L10n.t("translate.download_button", "下载")) {
                controller.startDownload()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .toolbarGlass(in: card)
        .overlay(card.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func failureCard(message: String) -> some View {
        let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Button(L10n.t("common.retry", "重试")) {
                controller.retry()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbarGlass(in: card)
        .overlay(card.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
