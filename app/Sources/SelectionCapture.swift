import AppKit
import ApplicationServices
import Carbon

/// 通过模拟一次拷贝，抓取前台应用中选中的文字。
///
/// 系统的「服务」菜单只存在于使用原生菜单的应用中，Electron、Java 等
/// 自绘右键菜单的应用（Claude、VS Code、Slack 等）无法通过服务菜单调用。
/// 取词不依赖菜单，因此在这些应用中同样可用，代价是需要「辅助功能」权限。
enum SelectionCapture {
    /// 等待剪贴板更新的轮询间隔与总超时。
    private static let pollInterval = Duration.milliseconds(15)
    private static let timeout = Duration.milliseconds(450)

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统的辅助功能授权提示。
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 抓取当前选中的文字。
    ///
    /// 取词会短暂占用剪贴板，结束后无论成功与否都会还原用户原有的内容。
    /// - Returns: 选中的文字；未选中内容、无权限或超时均返回 `nil`。
    static func capture() async -> String? {
        guard isTrusted else { return nil }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        // 手势本身带着 ⇧，若此时发出 ⌘C 会被目标应用当成 ⇧⌘C，
        // 先等用户松开修饰键再模拟拷贝。
        await waitForModifiersRelease()

        postCopyKeystroke()
        let captured = await waitForChange(on: pasteboard, from: changeCountBefore)
        snapshot.restore(to: pasteboard)

        guard let captured,
              !captured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return captured
    }

    /// 发送一次 ⌘C。
    ///
    /// 事件源使用 `.privateState`，因此不会把触发热键时仍按着的
    /// ⌃⌥ 合并进来，前台应用收到的是干净的 ⌘C。
    private static func postCopyKeystroke() {
        let source = CGEventSource(stateID: .privateState)
        let keyCode = CGKeyCode(kVK_ANSI_C)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// 等待用户松开会干扰 ⌘C 的修饰键，超时后照常继续。
    private static func waitForModifiersRelease() async {
        let blocking: CGEventFlags = [.maskShift, .maskControl, .maskAlternate]
        var waited = Duration.zero
        while waited < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            guard !flags.intersection(blocking).isEmpty else { return }
            try? await Task.sleep(for: pollInterval)
            waited += pollInterval
        }
    }

    private static func waitForChange(
        on pasteboard: NSPasteboard,
        from changeCount: Int
    ) async -> String? {
        var waited = Duration.zero
        while waited < timeout {
            try? await Task.sleep(for: pollInterval)
            waited += pollInterval
            if pasteboard.changeCount != changeCount {
                // 拷到的是文件（如打开/存储对话框里选中了文件），不是文字。
                if pasteboard.types?.contains(.fileURL) == true {
                    Diagnostics.log("模拟拷贝得到的是文件，放弃翻译")
                    return nil
                }
                return pasteboard.string(forType: .string)
            }
        }
        return nil
    }
}

/// 剪贴板内容的快照，用于取词后还原用户原有的剪贴板。
private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                stored[type] = item.data(forType: type)
            }
            return stored
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restored = items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
