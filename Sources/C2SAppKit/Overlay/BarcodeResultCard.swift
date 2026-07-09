import AppKit
import LinkPresentation
import SwiftUI
import C2SCore

/// F9 二维码结果卡片(ui-style §4.5):挂在选区迷你工具条按钮行**下方**。
/// - URL:书签样式(预览图 + 标题 + host),**整卡单击 → 默认浏览器打开并退出圈选**。
///   单击(非两段确认):点卡片同时退出覆盖层、露出浏览器,不存在「浏览器在覆盖层背后」的迷失。
/// - 文本(Wi-Fi/名片/纯文本…):截断解码原文 + 「复制」(复制全文)。
/// 固定尺寸(≤ 工具条宽)以稳定摆位;`.toolbarGlass` 玻璃底,呼应工具条族。
struct BarcodeResultCard: View {
    let result: BarcodeResult
    let reduceEffects: Bool
    /// URL 卡打开浏览器后调用(退出覆盖层)。
    var onOpened: () -> Void = {}

    /// 固定宽 ≤ 图片工具条宽(约 330pt):组合摆位时不撑宽、不左移右对齐基准。
    static let cardWidth: CGFloat = 300
    static let urlHeight: CGFloat = 62
    static let textHeight: CGFloat = 46

    /// 当前卡片高度(供 OverlayRootView 组合摆位估算)。
    static func height(for result: BarcodeResult) -> CGFloat {
        if case .url = result.content { return urlHeight }
        return textHeight
    }

    var body: some View {
        switch result.content {
        case .url(let url): URLCard(url: url, reduceEffects: reduceEffects, onOpened: onOpened)
        case .text(let text): TextCard(payload: text)
        }
    }
}

// MARK: - URL 书签卡

private struct URLCard: View {
    let url: URL
    let reduceEffects: Bool
    var onOpened: () -> Void

    @StateObject private var preview = LinkPreviewLoader()

    private var host: String { url.host ?? url.absoluteString }
    /// 标题优先用抓到的 og:title,取不到退化到 host —— 卡片无需联网就完整可用。
    private var title: String { preview.title ?? host }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(width: BarcodeResultCard.cardWidth, height: BarcodeResultCard.urlHeight)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .cardChrome()
        .onAppear { preview.load(url) }
        .onDisappear { preview.cancel() }
        .accessibilityLabel(L10n.f("barcode.card_a11y", "二维码:%@", host))
        .accessibilityHint(L10n.t("common.open_in_browser", "在默认浏览器中打开"))
    }

    /// 预览图:加载中骨架 → 有图显示图 → 无图退化到链接图标。
    @ViewBuilder private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let image = preview.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if !preview.isLoading {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 38, height: 38)
        .animation(reduceEffects ? nil : .easeOut(duration: 0.15), value: preview.image != nil)
    }

    private func open() {
        NSWorkspace.shared.open(url)
        Haptics.confirm()
        onOpened()
    }
}

// MARK: - 文本卡

private struct TextCard: View {
    let payload: String

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "qrcode")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(payload)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyButton
        }
        .padding(.horizontal, 12)
        .frame(width: BarcodeResultCard.cardWidth, height: BarcodeResultCard.textHeight)
        .cardChrome()
        .onDisappear { resetTask?.cancel() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.f("barcode.card_a11y", "二维码:%@", payload))
    }

    private var copyButton: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                Text(copied ? L10n.t("barcode.copied", "已复制") : L10n.t("barcode.copy", "复制"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.accentColor))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? L10n.t("barcode.copied", "已复制") : L10n.t("barcode.copy", "复制"))
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string) // 复制全文(非截断)
        Haptics.confirm()
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

// MARK: - 卡片外观(玻璃底 + hairline 描边 + 轻投影,呼应工具条族)

private extension View {
    func cardChrome() -> some View {
        self
            .toolbarGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
    }
}

// MARK: - 链接预览抓取(LinkPresentation)

/// 抓 URL 的书签元数据(标题 + 预览图)。**一次真实联网请求**:向二维码指向的
/// 服务器发请求 —— 只对 http/https 发起(分类已保证)、超时 8s、离场即取消。
/// completion 与图片加载回调都在**后台线程**,必须 hop 回主线程再写 @Published。
@MainActor
final class LinkPreviewLoader: ObservableObject {
    @Published var title: String?
    @Published var image: NSImage?
    @Published var isLoading = true

    private var provider: LPMetadataProvider?

    /// 一次性:LPMetadataProvider 同实例重复 startFetching 会崩,故 provider 非 nil 即跳过。
    func load(_ url: URL) {
        guard provider == nil else { return }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        self.provider = provider
        provider.startFetchingMetadata(for: url) { metadata, error in
            guard let metadata, error == nil else {
                Task { @MainActor [weak self] in self?.isLoading = false }
                return
            }
            let title = metadata.title
            let imageProvider = metadata.imageProvider ?? metadata.iconProvider
            Task { @MainActor [weak self] in self?.title = title }
            guard let imageProvider, imageProvider.canLoadObject(ofClass: NSImage.self) else {
                Task { @MainActor [weak self] in self?.isLoading = false }
                return
            }
            imageProvider.loadObject(ofClass: NSImage.self) { object, _ in
                let image = object as? NSImage
                Task { @MainActor [weak self] in
                    self?.image = image
                    self?.isLoading = false
                }
            }
        }
    }

    func cancel() {
        provider?.cancel()
        provider = nil
    }
}
