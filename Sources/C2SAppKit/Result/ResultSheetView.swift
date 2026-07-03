import AppKit
import SwiftUI
import Foundation

/// 结果面板数据模型(OverlayWindowController 持有并驱动)。
@MainActor
public final class ResultSheetModel: ObservableObject {
    @Published public var content: ResultContent = .hidden
    /// 搜索条药丸里展示的查询串。
    @Published public var query: String?
    /// 图搜时药丸里展示的裁剪缩略图(查询上下文,与文字 query 对等)。
    @Published public var queryImage: CGImage?
    /// 搜索框提交(F11 v2):文字模式 = 整条查询(可编辑替换);
    /// 图搜模式 = 追加条件(multisearch,图不被顶掉)。由 coordinator 按上下文路由。
    public var onQuerySubmit: ((String) -> Void)?
    /// 面板 WebView 当前主 frame URL(multisearch 需要带 vsrid 的结果页 URL)。
    public var currentPageURL: URL?
    /// 面板 WebView 报告 Lens 被风控拦截(参数 = 用户可读原因)。
    public var onLensBlocked: ((String) -> Void)?
    /// 面板 WebView 报告 Lens 导航失败(参数 = 用户可读原因)。
    public var onLensFailure: ((String) -> Void)?
    /// 每次 showResult 递增:同 URL 的「新一次搜索」也要强制重新加载
    /// (只挡 SwiftUI 重绘风暴,不挡用户重复搜索)。
    @Published public var loadToken = 0
    /// 面板右上 × 的动作:与 Esc 同义,退出整个覆盖层(不是只收面板)。
    public var onDismiss: (() -> Void)?
    public init() {}
}

/// ui-style §4.6(v3,2026-07-03):**手机屏幕比例的独立悬浮面板**。
/// 宽 390pt、高 ≈ 宽 × 19.5/9(受屏高约束),默认停靠屏幕右侧垂直居中;
/// 顶部抓手条可拖到任意位置(夹在屏内),右上 × 关闭。
/// 谷歌移动版页面在此宽度渲染最佳;取代 v2 底部三段 detent 上滑面板(全宽利用率低)。
struct ResultSheetView: View {
    @ObservedObject var model: ResultSheetModel
    let reduceEffects: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 搜索框内容 = 可编辑的查询(圈选文字直接进框;图搜时为追加条件)。
    @State private var editText = ""
    @State private var webLoading = true
    /// 面板中心(nil = 默认停靠右侧居中);拖抓手移动后记住位置(本次覆盖层会话内)。
    @State private var panelCenter: CGPoint?
    /// 拖拽起点的面板中心(非 nil = 拖拽进行中,位置更新不加动画、跟手)。
    @State private var dragStartCenter: CGPoint?

    private static let phoneWidth: CGFloat = 390     // 手机逻辑宽度(iPhone 15 同款)
    private static let phoneAspect: CGFloat = 19.5 / 9
    private static let edgeMargin: CGFloat = 24
    private static let clampInset: CGFloat = 8

    // MARK: - 派生状态

    private var isHidden: Bool {
        if case .hidden = model.content { return true }
        return false
    }

    private var webSource: WebSource? {
        switch model.content {
        case .web(let url):
            return .url(url, token: model.loadToken)
        case .lensUpload(let payload):
            return .lensUpload(html: payload.html, baseURL: payload.baseURL, token: payload.attempt)
        default:
            return nil
        }
    }

    private var isLensContent: Bool {
        if case .lensUpload = model.content { return true }
        return false
    }

    /// 同步进搜索框的查询串:model.query 优先,loading 的乐观预填兜底。
    private var syncedQuery: String? {
        if let q = model.query, !q.isEmpty { return q }
        if case .loading(let q) = model.content { return q }
        return nil
    }

    private var motionReduced: Bool {
        reduceMotion || reduceEffects
    }

    var body: some View {
        GeometryReader { geo in
            let panelSize = Self.panelSize(in: geo.size)
            let center = Self.clamped(currentCenter(in: geo.size, panel: panelSize),
                                      in: geo.size, panel: panelSize)
            panel(container: geo.size, size: panelSize)
                .position(center)
                .offset(x: (isHidden && !motionReduced) ? 24 : 0) // 隐藏时轻微右滑 + 淡出
                .opacity(isHidden ? 0 : 1)
                .animation(dragStartCenter != nil ? nil
                           : (motionReduced ? .easeInOut(duration: 0.15)
                                            : .spring(response: 0.4, dampingFraction: 0.85)),
                           value: isHidden)
                .allowsHitTesting(!isHidden) // 隐藏时绝不挡覆盖层手势
                .disabled(isHidden)          // 并释放键盘焦点,防止盲打进隐形输入框
        }
        .onChange(of: isHidden) { _, hidden in
            if hidden { editText = "" } else { editText = syncedQuery ?? "" }
        }
        .onChange(of: syncedQuery) { _, q in
            // coordinator 发起新搜索时把查询同步进可编辑框(圈选文字直接进框)
            editText = q ?? ""
        }
        .onChange(of: webSource) { _, source in
            if source != nil { webLoading = true }
        }
    }

    // MARK: - 尺寸/位置(纯函数,便于推理)

    /// 手机比例:宽优先 390,高 = 宽 × 19.5/9,两者都夹进屏内。
    static func panelSize(in container: CGSize) -> CGSize {
        let w = min(phoneWidth, max(300, container.width - 2 * edgeMargin))
        let h = min(w * phoneAspect, max(320, container.height - 2 * edgeMargin))
        return CGSize(width: w, height: h)
    }

    static func clamped(_ center: CGPoint, in container: CGSize, panel: CGSize) -> CGPoint {
        let minX = panel.width / 2 + clampInset
        let maxX = max(minX, container.width - panel.width / 2 - clampInset)
        let minY = panel.height / 2 + clampInset
        let maxY = max(minY, container.height - panel.height / 2 - clampInset)
        return CGPoint(x: min(max(center.x, minX), maxX),
                       y: min(max(center.y, minY), maxY))
    }

    private func currentCenter(in container: CGSize, panel: CGSize) -> CGPoint {
        panelCenter ?? CGPoint(x: container.width - panel.width / 2 - Self.edgeMargin,
                               y: container.height / 2)
    }

    // MARK: - 面板

    private func panel(container: CGSize, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(spacing: 0) {
            dragStrip(container: container, panel: size)
            searchPill
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .panelGlass(in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 8)
    }

    /// 抓手条:拖动移动面板;右侧 × 关闭。
    /// 拖拽手势只挂在这条上(不挂药丸,避免与 TextField 抢事件)。
    private func dragStrip(container: CGSize, panel: CGSize) -> some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
            HStack {
                Spacer()
                Button {
                    // 与 Esc 同义:退出整个覆盖层,不是只收面板(2026-07-03 用户拍板)
                    model.onDismiss?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .accessibilityLabel("退出圈选")
            }
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(moveDrag(container: container, panel: panel))
        .accessibilityHint("拖动可移动面板")
    }

    /// 拖动坐标系必须用 .global:手势挂在「跟着拖拽移动的视图」上,
    /// .local 的坐标系会随视图一起动,translation 读数与已应用位移互咬 → 抖动。
    /// 位移是增量量,global 与容器 local 同尺度,可直接叠加。
    private func moveDrag(container: CGSize, panel: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if dragStartCenter == nil {
                    dragStartCenter = currentCenter(in: container, panel: panel)
                }
                guard let start = dragStartCenter else { return }
                let clamped = Self.clamped(
                    CGPoint(x: start.x + value.translation.width,
                            y: start.y + value.translation.height),
                    in: container, panel: panel)
                // 对齐整数点位,避免亚像素渲染的细微闪动
                panelCenter = CGPoint(x: clamped.x.rounded(), y: clamped.y.rounded())
            }
            .onEnded { _ in
                dragStartCenter = nil
            }
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if let thumb = model.queryImage {
                // 图搜查询上下文:圈出的图的缩略图(与文字 query 对等)
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            // 可编辑的查询框:圈选文字直接进框可改;图搜时为「添加到搜索」追加条件。
            // 不用 @FocusState 自动聚焦:面板出现时不抢覆盖层键盘焦点。
            TextField(model.queryImage != nil ? "添加到搜索" : "搜索", text: $editText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .frame(minWidth: 80)
                .onSubmit(submitQuery)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(.quaternary))
    }

    private func submitQuery() {
        // 面板隐藏时输入框不得凭空触发搜索重开面板
        guard !isHidden else { editText = ""; return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.onQuerySubmit?(text)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentArea: some View {
        switch model.content {
        case .hidden:
            Color.clear
        case .loading:
            ResultSkeletonView(reduceEffects: reduceEffects)
        case .web, .lensUpload:
            ZStack {
                if let source = webSource {
                    // 风控 403 / 网络失败只对 Lens 链路走恢复路径;普通网页照常
                    ResultWebView(source: source,
                                  isLoading: $webLoading,
                                  onBlocked: isLensContent ? { model.onLensBlocked?($0) } : nil,
                                  onFailure: isLensContent ? { model.onLensFailure?($0) } : nil,
                                  onURLChange: { model.currentPageURL = $0 })
                }
                if webLoading {
                    // 加载中骨架盖在 WebView 上,didFinish 后 120ms 淡出无缝换入
                    ResultSkeletonView(reduceEffects: reduceEffects)
                        .background(.ultraThinMaterial)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: webLoading)
        case .error(let message, let retry, let login):
            errorCard(message: message, retry: retry, login: login)
        }
    }

    /// 原生错误卡(features §8:绝不把错误串塞进搜索)。
    private func errorCard(message: String, retry: (() -> Void)?, login: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let retry {
                    Button("重试", action: retry)
                        .buttonStyle(.borderedProminent)
                }
                if let login {
                    Button("登录 Google", action: login)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .padding(16)
    }
}

/// 加载骨架:几条圆角占位条 + 轻微 opacity 脉动(减弱动态 → 静态)。
private struct ResultSkeletonView: View {
    let reduceEffects: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private static let rows: [(fraction: CGFloat, height: CGFloat)] = [
        (0.55, 14), (0.92, 12), (0.86, 12), (0.90, 12), (0.62, 12),
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.rows.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: geo.size.width * Self.rows[i].fraction,
                               height: Self.rows[i].height)
                }
            }
            .opacity(motionReduced ? 0.55 : (pulsing ? 0.35 : 0.7))
            .onAppear {
                guard !motionReduced else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .accessibilityHidden(true)
    }

    private var motionReduced: Bool {
        reduceMotion || reduceEffects
    }
}

private extension View {
    /// 面板底:macOS 26+ 用 Liquid Glass(系统级质感,2026-07-03 用户点名),
    /// 旧系统回退 ultraThinMaterial;两个分支都由调用方再 clipShape。
    @ViewBuilder
    func panelGlass(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial)
        }
    }
}
