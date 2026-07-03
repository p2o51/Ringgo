import AppKit
import SwiftUI
import Translation
import os

let translationLog = Logger(subsystem: "dev.c2s.C2S", category: "translation")

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

        let target = Locale.Language(identifier: targetCode)
        if var config = sessionConfiguration, config.target == target {
            // 同目标语言再次翻译:必须 invalidate,否则 translationTask 视为同值不重跑。
            config.invalidate()
            sessionConfiguration = config
        } else {
            // source 为 nil = 自动检测源语言
            sessionConfiguration = TranslationSession.Configuration(source: nil, target: target)
        }
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
