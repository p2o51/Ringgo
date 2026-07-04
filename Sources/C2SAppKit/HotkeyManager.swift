import AppKit
import ApplicationServices
import Carbon

/// F1 触发/唤起:Carbon 主热键(免辅助功能权限)+ ⌘⇧ 蓄力手势(flagsChanged 计时,免权限)
/// + 可选双击 Shift(默认关,开启才申请 AX 权限)。
/// 实现要点:docs/features.md §F1、docs/circle2search-core-mechanisms.md §1。
@MainActor
public final class HotkeyManager {

    public var onEvent: ((TriggerEvent) -> Void)?
    /// 热键注册失败等需要用户感知的错误(原项目静默失败 → 必须反馈)。
    public var onError: ((String) -> Void)?

    public init() {}

    /// 按配置注册热键与手势监听;可重复调用(内部先清干净旧注册/旧 monitor)。
    public func apply(config: TriggerConfig) {
        self.config = config
        guard isRunning, !isSuspended else { return } // 暂停时只存配置,resume() 统一激活
        deactivate()
        activate()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        HotkeyManager.current = self
        if !isSuspended { activate() }
    }

    /// 热键录制期间临时让出 Carbon 热键与 flagsChanged 监听。
    /// 否则当前组合会被系统级注册先消费，录制器收不到 keyDown。
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        if isRunning { deactivate() }
    }

    /// 按最后一次 apply 的配置恢复全局触发。
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if isRunning { activate() }
    }

    /// 注销热键、移除所有 monitor(global + local 引用都必须保存并移除,防泄漏)。
    public func stop() {
        guard isRunning else { return }
        deactivate()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        if HotkeyManager.current === self { HotkeyManager.current = nil }
        isRunning = false
        isSuspended = false
    }

    // MARK: - 状态

    /// Carbon C 回调不能捕获上下文 → 经此静态引用转回实例(应用内仅一个实例,后 start 者生效)。
    fileprivate static weak var current: HotkeyManager?

    private var config = TriggerConfig()
    private var isRunning = false
    private var isSuspended = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    /// global + local monitor 引用都必须保存,停用时逐个移除(原项目泄漏 monitor)。
    private var flagsMonitors: [Any] = []

    /// 蓄力:恰好按住 ⌘⇧ → charging;到阈值 → fired(松开修饰键前不重入)。
    private enum ChargeState { case idle, charging, fired }
    private var chargeState: ChargeState = .idle
    private var chargeWorkItem: DispatchWorkItem?

    /// 上一次「只按 Shift」的 event.timestamp;夹杂其他修饰键即作废。
    private var lastShiftOnlyTimestamp: TimeInterval?
    private var warnedDoubleShiftAX = false

    private static let doubleShiftWindow: TimeInterval = 0.4

    // MARK: - 激活/停用

    private func activate() {
        registerHotKey()
        if config.chargeEnabled || config.doubleShiftEnabled {
            installFlagsMonitors()
        }
        warnDoubleShiftPermissionIfNeeded()
    }

    private func deactivate() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        for monitor in flagsMonitors {
            NSEvent.removeMonitor(monitor)
        }
        flagsMonitors.removeAll()
        cancelCharge() // 蓄力途中被重配/停止 → 发 .chargeCancelled 让上游收尾
        chargeState = .idle
        lastShiftOnlyTimestamp = nil
    }

    // MARK: - Carbon 主热键

    private func registerHotKey() {
        installCarbonHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(config.keyCode,
                                         config.carbonModifiers,
                                         EventHotKeyID(signature: hotKeySignature, id: hotKeyIDNumber),
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
        } else {
            hotKeyRef = nil
            onError?("热键注册失败(OSStatus \(status)),可能已被其他应用占用,请在设置中更换快捷键。")
        }
    }

    private func installCarbonHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         hotKeyEventHandler,
                                         1,
                                         &eventType,
                                         nil,
                                         &eventHandlerRef)
        if status != noErr {
            eventHandlerRef = nil
            onError?("热键事件回调安装失败(OSStatus \(status))。")
        }
    }

    fileprivate func hotkeyPressed() {
        // ⌘⇧S 与蓄力共享 ⌘⇧ 前缀:热键先落地就取消蓄力计时,避免阈值到点后重复触发
        if chargeState == .charging {
            chargeWorkItem?.cancel()
            chargeWorkItem = nil
            chargeState = .fired // 本次按住已被热键消费,松开前不重入蓄力
            onEvent?(.chargeCancelled)
        }
        onEvent?(.hotkey)
    }

    // MARK: - flagsChanged 双路监听(蓄力 + 双击 Shift 共用)

    private func installFlagsMonitors() {
        // 其他 App 前台走 global、自己前台(如 overlay 已弹出)走 local,两路互补
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleFlagsChanged(event)
            }
        }) {
            flagsMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleFlagsChanged(event)
            }
            return event // 不吞事件
        }) {
            flagsMonitors.append(local)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // capsLock 常亮不算「按住修饰键」,剔除后再精确匹配
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if config.chargeEnabled { updateCharge(flags: flags) }
        if config.doubleShiftEnabled { updateDoubleShift(flags: flags, timestamp: event.timestamp) }
    }

    // MARK: - 蓄力手势

    private func updateCharge(flags: NSEvent.ModifierFlags) {
        if flags == [.command, .shift] {
            guard chargeState == .idle else { return }
            chargeState = .charging
            onEvent?(.chargeBegan)
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.chargeState == .charging else { return }
                    self.chargeWorkItem = nil
                    self.chargeState = .fired
                    self.onEvent?(.chargeFired)
                }
            }
            chargeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, config.chargeThresholdMs)),
                                          execute: work)
        } else {
            switch chargeState {
            case .charging:
                cancelCharge() // 阈值前松开/加按其他修饰键 → 取消(天然防误触)
            case .fired:
                chargeState = .idle // 已触发,松开只复位、不再发事件
            case .idle:
                break
            }
        }
    }

    /// 仅 charging 态生效:取消计时并发 .chargeCancelled。
    private func cancelCharge() {
        guard chargeState == .charging else { return }
        chargeWorkItem?.cancel()
        chargeWorkItem = nil
        chargeState = .idle
        onEvent?(.chargeCancelled)
    }

    // MARK: - 双击 Shift(可选,默认关)

    private func updateDoubleShift(flags: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        if flags == [.shift] {
            if let last = lastShiftOnlyTimestamp, timestamp - last <= Self.doubleShiftWindow {
                lastShiftOnlyTimestamp = nil
                onEvent?(.doubleShift)
            } else {
                lastShiftOnlyTimestamp = timestamp
            }
        } else if !flags.isEmpty {
            lastShiftOnlyTimestamp = nil // 夹杂其他修饰键 → 本轮作废(松开到全空不清,等第二拍)
        }
    }

    /// 双击 Shift 需要辅助功能权限:只提示、不弹系统授权窗(设置页负责申请);去重防止每次 apply 重复弹。
    private func warnDoubleShiftPermissionIfNeeded() {
        guard config.doubleShiftEnabled else {
            warnedDoubleShiftAX = false
            return
        }
        if AXIsProcessTrusted() {
            warnedDoubleShiftAX = false
        } else if !warnedDoubleShiftAX {
            warnedDoubleShiftAX = true
            onError?("「双击 Shift」触发需要辅助功能权限：请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 Ringgo。")
        }
    }
}

// MARK: - Carbon 常量与 C 回调(文件级:C 回调必须是不捕获上下文的函数指针)

private extension OSType {
    /// FourCharCode:"C2SH" → 32 位签名(EventHotKeyID 要求)。
    init(fourCharString string: String) {
        self = string.utf16.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

private let hotKeySignature = OSType(fourCharString: "C2SH")
private let hotKeyIDNumber: UInt32 = 1

/// 不捕获任何上下文;校验签名后经 HotkeyManager.current 静态转发 + 主线程派发。
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(event,
                                EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID),
                                nil,
                                MemoryLayout<EventHotKeyID>.size,
                                nil,
                                &hotKeyID)
    guard err == noErr,
          hotKeyID.signature == hotKeySignature,
          hotKeyID.id == hotKeyIDNumber else {
        return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            guard let manager = HotkeyManager.current else { return }
            manager.hotkeyPressed()
        }
    }
    return noErr
}
