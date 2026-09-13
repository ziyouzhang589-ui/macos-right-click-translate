import AppKit
import ApplicationServices

/// 监听右键，在有选中文字时接管并就地弹出译文。
///
/// Electron、Java 等应用的右键菜单由应用自己绘制，系统无法向其中插入条目，
/// 因此改为自己捕获鼠标事件。仅在判定「当前有选中文字」时拦截右键，
/// 否则原样放行，应用自己的右键菜单不受影响。
///
/// 判定分两层：先用辅助功能接口直接读；读不到时（Chromium 系应用常见）
/// 退而依据最近的鼠标动作——划选或双击会留下选中迹象，普通单击则清除它。
///
/// 事件抽头运行在独立线程上：系统对回调有严格的超时限制，一旦超时就会停用
/// 抽头，而主线程随时可能正忙于界面渲染或翻译，无法保证及时响应。
final class RightClickWatcher: @unchecked Sendable {
    static let shared = RightClickWatcher()

    /// 捕获到手势时在主线程回调：读到的选中文字（读不到为 nil）与事件位置。
    var onTrigger: ((String?, CGPoint) -> Void)?

    private let lock = NSLock()
    /// 以下状态只在事件抽头线程上读写。
    ///
    /// 已接管当前这一轮右键，配对的抬起必须一并吞掉。
    private var swallowingRightSequence = false
    /// 最近一次左键按下的位置，用于判断是划选还是普通单击。
    private var lastLeftDownLocation: CGPoint = .zero
    /// 最近一次留下选中迹象的时刻。
    private var selectionSignalAt: CFAbsoluteTime = 0
    private var eventTap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var thread: Thread?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventTap != nil
    }

    /// 选中迹象的有效期，超过则认为用户只是想用应用自己的菜单。
    private static let selectionSignalWindow: CFAbsoluteTime = 90
    /// 标记由自己补发的事件，避免再次被拦截。
    private static let replayMarker: Int64 = 0x5A48_5954
    /// 这些应用里选中的多是文件而非文字，只信任辅助功能读取，不做猜测。
    private static let fileManagerBundleIDs: Set<String> = ["com.apple.finder"]

    /// 前台应用的 bundle id，由主线程通知更新，抽头线程读取。
    private var frontmostBundleID: String?

    private init() {
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self else { return }
            self.lock.lock()
            self.frontmostBundleID = app?.bundleIdentifier
            self.lock.unlock()
        }
    }

    /// - Returns: 是否成功装上监听。未授予辅助功能权限时返回 `false`。
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard AXIsProcessTrusted() else {
            Diagnostics.log("监听未装上：尚未获得辅助功能授权")
            return false
        }

        let ready = DispatchSemaphore(value: 0)
        let outcome = Outcome()

        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }
            outcome.succeeded = self.installTap()
            ready.signal()
            guard outcome.succeeded else { return }
            CFRunLoopRun()
            Diagnostics.log("事件抽头线程已退出")
        }
        thread.name = "com.local.bilingual-translator.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        self.thread = thread
        Diagnostics.log(outcome.succeeded ? "监听已装上（独立线程）" : "监听装载失败：无法创建事件抽头")
        return outcome.succeeded
    }

    /// 睡眠唤醒后事件抽头可能已被系统停用，这里确认并恢复。
    func revalidate() {
        lock.lock()
        let tap = eventTap
        lock.unlock()

        guard let tap else {
            // 抽头整个没了，重新装一次。
            Diagnostics.log("唤醒检查：监听已丢失，重新装载")
            _ = start()
            return
        }

        guard !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        Diagnostics.log("唤醒检查：抽头被停用，已重新启用")
    }

    func stop() {
        lock.lock()
        let tap = eventTap
        let runLoop = tapRunLoop
        eventTap = nil
        tapRunLoop = nil
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        thread = nil
    }

    /// 在当前线程创建事件抽头并挂到该线程的 run loop 上。
    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let watcher = Unmanaged<RightClickWatcher>.fromOpaque(userInfo).takeUnretainedValue()
            return watcher.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lock.lock()
        eventTap = tap
        tapRunLoop = CFRunLoopGetCurrent()
        lock.unlock()
        return true
    }

    /// 在事件抽头线程上运行，必须尽快返回。
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let reason = type == .tapDisabledByTimeout ? "超时" : "输入过多"
            Diagnostics.log("抽头被系统停用（\(reason)），已重新启用")
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            lastLeftDownLocation = event.location
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            noteSelectionSignal(from: event)
            return Unmanaged.passUnretained(event)

        case .rightMouseUp:
            // 用户往往先松修饰键再松鼠标，因此按序列而非按修饰键判断。
            guard swallowingRightSequence else {
                return Unmanaged.passUnretained(event)
            }
            swallowingRightSequence = false
            return nil

        case .rightMouseDown:
            break

        default:
            return Unmanaged.passUnretained(event)
        }

        // 取不到文字时由我们补发的右键，直接放行给应用。
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }

        // 辅助功能能直接读到选中内容时最可靠。
        if let text = AccessibilitySelection.read() {
            swallowingRightSequence = true
            Diagnostics.log("接管右键：辅助功能读到 \(text.count) 字")
            deliver(text, at: event.location)
            return nil
        }

        // 访达里框选的是文件：猜测会把文件名当文字翻译并吞掉原生菜单
        // （移到废纸篓、拷贝等），读不到文字就直接交还。
        lock.lock()
        let frontmost = frontmostBundleID
        lock.unlock()
        if let frontmost, Self.fileManagerBundleIDs.contains(frontmost) {
            Diagnostics.log("右键放行：访达中未读到文字")
            return Unmanaged.passUnretained(event)
        }

        // 读不到就看最近有没有划选或双击的迹象，没有则说明用户
        // 只是想用应用自己的右键菜单。
        let elapsed = CFAbsoluteTimeGetCurrent() - selectionSignalAt
        guard elapsed < Self.selectionSignalWindow else {
            Diagnostics.log("右键放行：无选中迹象")
            return Unmanaged.passUnretained(event)
        }

        swallowingRightSequence = true
        Diagnostics.log("接管右键：有选中迹象（\(String(format: "%.1f", elapsed))秒前），改用模拟拷贝")
        deliver(nil, at: event.location)
        return nil
    }

    /// 划选或双击留下选中迹象；普通单击会取消选中，随之清除迹象。
    private func noteSelectionSignal(from event: CGEvent) {
        let location = event.location
        let distance = hypot(
            location.x - lastLeftDownLocation.x,
            location.y - lastLeftDownLocation.y
        )
        let clickState = event.getIntegerValueField(.mouseEventClickState)

        if distance > 3 || clickState >= 2 {
            selectionSignalAt = CFAbsoluteTimeGetCurrent()
        } else {
            selectionSignalAt = 0
        }
    }

    private func deliver(_ text: String?, at location: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?(text, location)
        }
    }

    /// 判定失误时把右键还给应用，让它弹出自己的菜单。
    func replayRightClick(at location: CGPoint) {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseDown,
            mouseCursorPosition: location,
            mouseButton: .right
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseUp,
            mouseCursorPosition: location,
            mouseButton: .right
        ) else {
            return
        }

        down.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        Diagnostics.log("补发右键，交还给应用")
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// 记录后台线程的安装结果，供 `start()` 同步等待。
private final class Outcome: @unchecked Sendable {
    var succeeded = false
}

/// 通过辅助功能接口直接读取当前选中的文字，无需经过剪贴板。
enum AccessibilitySelection {
    static func read() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
            let focusedValue = focused,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selected
        ) == .success,
            let text = selected as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}
