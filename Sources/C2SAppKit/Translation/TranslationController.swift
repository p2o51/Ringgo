import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import os

let translationLog = Logger(subsystem: "dev.ringgo.Ringgo", category: "translation")

// MARK: - 纯数据类型(不 gate,低版本代码可引用)

/// 单行译文盖板:rect 为覆盖层坐标(左上原点),盖在原文行上。
struct TranslatedPlate: Identifiable, Equatable {
    let id: Int
    let rect: CGRect
    let text: String
}

/// 翻译覆盖层状态机。
enum TranslationOverlayState: Equatable {
    case idle
    case preparing
    case translating(done: Int, total: Int)
    case shown
    case failed(String)
    /// 语言对受支持但模型未下载:提示 + 「下载模型」按钮(desc 如 "英语 → 日语")。
    case needsDownload(String)
}

// MARK: - 控制器

@available(macOS 15.0, *)
@MainActor
final class TranslationController: ObservableObject {

    @Published private(set) var state: TranslationOverlayState = .idle
    @Published private(set) var plates: [TranslatedPlate] = []
    /// 由 TranslationHostView 的 .translationTask 消费;赋新值或 invalidate 即触发翻译任务。
    @Published var sessionConfiguration: TranslationSession.Configuration?

    var isActive: Bool { state != .idle }

    /// 最近一次请求的行与目标语言(失败重试用;已过滤空白行)。
    private var pendingLines: [(rect: CGRect, text: String)] = []
    private var pendingTarget: String = ""
    /// 探测出的源语言(显式给 Configuration;nil = 交给框架自动检测)。
    private var pendingSource: Locale.Language?
    private var downloadWindow: NSWindow?
    /// 代数票据:dismiss / 新请求之后,旧任务的迟到结果一律作废。
    private var generation = 0

    // MARK: 对外入口

    /// 全屏翻译开关:idle→启动翻译;非 idle→dismiss(同一按钮开↔关)。
    func toggle(lines: [(rect: CGRect, text: String)], targetCode: String) {
        translationLog.info("toggle: state=\(String(describing: self.state)) lines=\(lines.count) target=\(targetCode)")
        if state == .idle {
            translate(lines: lines, targetCode: targetCode)
        } else {
            dismiss()
        }
    }

    /// 选区翻译:直接(重新)翻译给定行,盖板只覆盖这些行。
    func translate(lines: [(rect: CGRect, text: String)], targetCode: String) {
        generation &+= 1
        // 空行/纯空白行跳过
        let usable = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        pendingLines = usable
        pendingTarget = targetCode
        plates = []
        guard !usable.isEmpty else {
            state = .failed("所选内容没有可翻译的文字")
            return
        }
        state = .preparing
        translationLog.info("translate: usable=\(usable.count) target=\(targetCode)")

        // 1) 自己探测源语言(prepareTranslation 配 source=nil 不知道该下哪个模型,是失败常因)
        let source = Self.detectSourceLanguage(of: usable.map(\.text))
        pendingSource = source
        let target = Locale.Language(identifier: targetCode)
        translationLog.info("translate: detected source=\(source?.minimalIdentifier ?? "nil")")

        if let source, source.minimalIdentifier.hasPrefix(target.minimalIdentifier)
            || target.minimalIdentifier.hasPrefix(source.minimalIdentifier) {
            state = .failed("内容看起来已经是\(Self.displayName(of: target)),换个目标语言试试")
            return
        }

        // 2) 可用性预检:模型未装时走独立下载窗(覆盖层窗口无法承载系统下载弹窗)
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            let status: LanguageAvailability.Status
            if let source {
                status = await LanguageAvailability().status(from: source, to: target)
            } else {
                status = .supported // 源未识别:直接交给框架自动检测碰一次
            }
            guard self.generation == gen else { return }
            translationLog.info("translate: availability=\(String(describing: status))")
            switch status {
            case .installed:
                self.activateConfiguration(source: source, target: target)
            case .supported:
                if let source {
                    let desc = "\(Self.displayName(of: source)) → \(Self.displayName(of: target))"
                    self.state = .needsDownload(desc)
                } else {
                    self.activateConfiguration(source: nil, target: target)
                }
            case .unsupported:
                self.state = .failed("暂不支持 \(Self.displayName(of: source ?? target)) → \(Self.displayName(of: target)) 的翻译")
            @unknown default:
                self.activateConfiguration(source: source, target: target)
            }
        }
    }

    private func activateConfiguration(source: Locale.Language?, target: Locale.Language) {
        if var config = sessionConfiguration, config.target == target, config.source == source {
            // 同配置再次翻译:必须 invalidate,否则 translationTask 视为同值不重跑。
            config.invalidate()
            sessionConfiguration = config
        } else {
            sessionConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// NLLanguageRecognizer 探测主导源语言(采样前 40 行 / 1000 字符)。
    static func detectSourceLanguage(of texts: [String]) -> Locale.Language? {
        let sample = String(texts.prefix(40).joined(separator: "\n").prefix(1000))
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    static func displayName(of language: Locale.Language) -> String {
        let id = language.maximalIdentifier
        return Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? Locale.current.localizedString(forIdentifier: id)
            ?? id
    }

    // MARK: 模型下载(独立普通小窗:覆盖层是 borderless+screenSaver 层级,系统下载弹窗无处安放)

    func startDownload() {
        guard case .needsDownload = state, let source = pendingSource else { return }
        let target = Locale.Language(identifier: pendingTarget)
        let desc = "\(Self.displayName(of: source)) → \(Self.displayName(of: target))"

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "下载翻译模型"
        window.level = .screenSaver // 得压过覆盖层,不然弹在冻结屏底下
        window.isReleasedWhenClosed = false
        window.center()
        let host = TranslationDownloadView(source: source, target: target, desc: desc) { [weak self] success in
            guard let self else { return }
            self.downloadWindow?.orderOut(nil)
            self.downloadWindow = nil
            if success {
                self.retry() // 模型已装,重跑会走 installed 直翻
            } else {
                self.state = .failed("模型下载未完成")
            }
        }
        window.contentView = NSHostingView(rootView: host)
        downloadWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 失败重试:用存下的 pendingLines / 目标语言重跑。
    func retry() {
        translate(lines: pendingLines, targetCode: pendingTarget)
    }

    func dismiss() {
        generation &+= 1
        state = .idle
        plates = []
        pendingLines = []
        sessionConfiguration = nil
        downloadWindow?.orderOut(nil)
        downloadWindow = nil
    }

    // MARK: 翻译执行(宿主视图 .translationTask 回调转入)

    /// session 只在 translationTask 闭包存活期内有效,不得存储。
    func run(session: TranslationSession) async {
        translationLog.info("run: translationTask fired, pending=\(self.pendingLines.count)")
        let gen = generation
        let lines = pendingLines
        guard !lines.isEmpty else { return }

        do {
            // 若目标语言模型未下载,这里会触发系统下载 UI
            try await session.prepareTranslation()
            translationLog.info("run: prepareTranslation ok")
            guard generation == gen else { return }

            let requests = lines.enumerated().map { index, line in
                TranslationSession.Request(sourceText: line.text,
                                           clientIdentifier: String(index))
            }
            state = .translating(done: 0, total: requests.count)

            // 分批整包丢给框架(批内由框架自行并行),批间刷进度。
            var results: [Int: String] = [:]
            let batchSize = 40
            var done = 0
            var start = 0
            while start < requests.count {
                let batch = Array(requests[start ..< min(start + batchSize, requests.count)])
                let responses = try await session.translations(from: batch)
                guard generation == gen else { return }
                for response in responses {
                    // clientIdentifier 是我们自赋的行号;缺失/畸形即管线被破坏,报错不吞
                    guard let idString = response.clientIdentifier,
                          let index = Int(idString),
                          lines.indices.contains(index) else {
                        throw TranslationPlumbingError.identifierMismatch
                    }
                    results[index] = response.targetText
                }
                done += batch.count
                state = .translating(done: done, total: requests.count)
                start += batchSize
            }

            // 映射回盖板(rect 用原行框)
            plates = lines.indices.compactMap { index in
                guard let text = results[index] else { return nil }
                return TranslatedPlate(id: index, rect: lines[index].rect, text: text)
            }
            state = .shown
        } catch is CancellationError {
            // 任务被更新的配置或 dismiss 取代:非错误,状态由接替方负责
            return
        } catch {
            translationLog.error("run: failed \(error.localizedDescription)")
            guard generation == gen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

/// run(session:) 内部管线错误(理论上不可达,但绝不静默)。
private enum TranslationPlumbingError: LocalizedError {
    case identifierMismatch

    var errorDescription: String? {
        switch self {
        case .identifierMismatch:
            return "翻译结果缺少行标识,无法回贴原文位置"
        }
    }
}

// MARK: - 不可见宿主(挂在覆盖层视图树上,承载 .translationTask)

@available(macOS 15.0, *)
struct TranslationHostView: View {
    @ObservedObject var controller: TranslationController

    var body: some View {
        // 1×1 而非 0×0:零尺寸视图上的 task 修饰器可能不被 SwiftUI 安装
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .translationTask(controller.sessionConfiguration) { session in
                await controller.run(session: session)
            }
    }
}


// MARK: - 模型下载小窗内容(普通窗口里跑 prepareTranslation,系统下载 UI 有锚点)

@available(macOS 15.0, *)
private struct TranslationDownloadView: View {
    let source: Locale.Language
    let target: Locale.Language
    let desc: String
    let onDone: (Bool) -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var message = "正在请求下载…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("正在准备 \(desc) 翻译模型")
                .font(.callout)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 380, height: 150)
        .onAppear {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
        .translationTask(configuration) { session in
            do {
                // 普通窗口承载:模型缺失时系统下载确认框在这里弹出
                try await session.prepareTranslation()
                translationLog.info("download: prepareTranslation ok")
                onDone(true)
            } catch {
                translationLog.error("download: \(error.localizedDescription)")
                message = error.localizedDescription
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                onDone(false)
            }
        }
    }
}
