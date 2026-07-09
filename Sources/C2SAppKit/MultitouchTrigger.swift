import Foundation
import C2SMultitouchShim

/// 三指双击的纯状态机。私有框架只提供逐帧手指数；这里把一次短促的三指接触
/// 视为 tap，再组合成 double tap。移动距离不读取 MTTouch 内存布局，以换取跨版本安全。
struct ThreeFingerDoubleTapRecognizer {
    enum Event: Equatable {
        case firstTap
        case doubleTap
    }

    var maximumTapDuration: TimeInterval = 0.26
    var maximumInterTapGap: TimeInterval = 0.34
    var minimumInterTapGap: TimeInterval = 0.025

    private var contactStart: TimeInterval?
    private var lastThreeTimestamp: TimeInterval?
    private var invalidContact = false
    private var previousTapEnd: TimeInterval?

    mutating func process(fingerCount: Int, timestamp: TimeInterval) -> Event? {
        if contactStart != nil {
            if fingerCount == 3 {
                lastThreeTimestamp = timestamp
                if let contactStart,
                   timestamp - contactStart > maximumTapDuration {
                    invalidContact = true
                }
                return nil
            }

            if fingerCount > 3 {
                invalidContact = true
                return nil
            }

            // 三根手指往往不是同一微秒离开；降到 2/1/0 都视作本拍结束。
            return finishCurrentContact()
        }

        guard fingerCount == 3 else { return nil }
        contactStart = timestamp
        lastThreeTimestamp = timestamp
        invalidContact = false
        return nil
    }

    /// 某些系统在全部抬手后不再补 n=0 尾帧；由静默计时器调用此入口收尾。
    mutating func finishAfterSilence() -> Event? {
        finishCurrentContact()
    }

    mutating func reset() {
        contactStart = nil
        lastThreeTimestamp = nil
        invalidContact = false
        previousTapEnd = nil
    }

    private mutating func finishCurrentContact() -> Event? {
        guard let start = contactStart, let end = lastThreeTimestamp else {
            clearCurrentContact()
            return nil
        }

        let duration = max(0, end - start)
        let valid = !invalidContact && duration <= maximumTapDuration
        clearCurrentContact()
        guard valid else {
            previousTapEnd = nil
            return nil
        }

        if let previousTapEnd {
            let gap = start - previousTapEnd
            if gap >= minimumInterTapGap && gap <= maximumInterTapGap {
                self.previousTapEnd = nil
                return .doubleTap
            }
        }

        previousTapEnd = end
        return .firstTap
    }

    private mutating func clearCurrentContact() {
        contactStart = nil
        lastThreeTimestamp = nil
        invalidContact = false
    }
}

public enum MultitouchTriggerStatus: Equatable {
    case disabled
    case active(deviceCount: Int)
    case sleeping
    case unavailable(String)
}

/// Developer ID 直发版的实验性全局三指双击触发器。
///
/// C shim 负责 dlopen 私有 MultitouchSupport 并只转发手指数/时间戳；所有识别状态
/// 都在串行队列里，回调到 AppCoordinator 时再回主线程。
public final class MultitouchTrigger {
    public var onFirstTap: (() -> Void)?
    public var onDoubleTap: (() -> Void)?

    private let frameQueue = DispatchQueue(
        label: "dev.ringgo.multitouch.frames",
        qos: .userInteractive
    )
    private var recognizer = ThreeFingerDoubleTapRecognizer()
    private var quietWorkItem: DispatchWorkItem?
    private var callbackContext: UnsafeMutableRawPointer?
    private var activeDeviceCount = 0
    private(set) var isRunning = false

    public init() {}

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> MultitouchTriggerStatus {
        if isRunning {
            return .active(deviceCount: activeDeviceCount)
        }

        let context = Unmanaged.passRetained(self).toOpaque()
        let deviceCount = C2SMTStart(multitouchFrameCallback, context)
        guard deviceCount > 0 else {
            Unmanaged<MultitouchTrigger>.fromOpaque(context).release()
            let error = String(cString: C2SMTLastError())
            return .unavailable(error.isEmpty ? L10n.t("multitouch.err.init_failed", "三指触控初始化失败。") : error)
        }

        callbackContext = context
        activeDeviceCount = Int(deviceCount)
        isRunning = true
        return .active(deviceCount: Int(deviceCount))
    }

    public func stop() {
        guard callbackContext != nil || isRunning else { return }
        C2SMTStop()
        isRunning = false
        activeDeviceCount = 0

        frameQueue.sync {
            quietWorkItem?.cancel()
            quietWorkItem = nil
            recognizer.reset()
        }

        if let callbackContext {
            Unmanaged<MultitouchTrigger>.fromOpaque(callbackContext).release()
            self.callbackContext = nil
        }
    }

    fileprivate func receiveFrame(fingerCount: Int, timestamp: TimeInterval) {
        frameQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            let event = self.recognizer.process(
                fingerCount: fingerCount,
                timestamp: timestamp
            )
            self.handle(event)

            self.quietWorkItem?.cancel()
            self.quietWorkItem = nil
            if fingerCount == 3 {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.quietWorkItem = nil
                    self.handle(self.recognizer.finishAfterSilence())
                }
                self.quietWorkItem = work
                self.frameQueue.asyncAfter(deadline: .now() + 0.075, execute: work)
            }
        }
    }

    private func handle(_ event: ThreeFingerDoubleTapRecognizer.Event?) {
        guard let event else { return }
        DispatchQueue.main.async { [weak self] in
            switch event {
            case .firstTap:
                self?.onFirstTap?()
            case .doubleTap:
                self?.onDoubleTap?()
            }
        }
    }
}

private let multitouchFrameCallback: C2SMTFrameHandler = {
    fingerCount, timestamp, context in
    guard let context else { return }
    let trigger = Unmanaged<MultitouchTrigger>.fromOpaque(context)
        .takeUnretainedValue()
    trigger.receiveFrame(fingerCount: Int(fingerCount), timestamp: timestamp)
}
