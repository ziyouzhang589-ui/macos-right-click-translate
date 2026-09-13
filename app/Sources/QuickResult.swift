import AppKit
import SwiftUI
import Translation

private let quickResultWidth: CGFloat = 380

/// 在鼠标位置就地弹出译文的浮层。
///
/// 与主窗口相互独立：右键「服务」或取词热键都只弹出这个浮层，
/// 看完按 `Esc` 或点击别处即可消失，不打断用户当前所在的应用。
@MainActor
final class QuickResultController {
    static let shared = QuickResultController()

    /// 需要更大的编辑空间时，把文本交回主窗口。
    var openInMainWindow: ((String) -> Void)?

    /// 浮层即将显示时的通知，用于收起多余的主窗口。
    var onShow: (() -> Void)?

    private var panel: QuickResultPanel?
    private var outsideClickMonitor: Any?
    private let model = TranslatorModel()

    private init() {}

    func show(text: String) {
        let panel = panel ?? makePanel()
        self.panel = panel

        onShow?()
        model.acceptExternalText(text)
        panel.layoutIfNeeded()
        ensureContentSize(panel)
        anchorNearMouse(panel)
        panel.makeKeyAndOrderFront(nil)
        startWatchingOutsideClicks()

        let frame = panel.frame
        let screen = NSScreen.screens.firstIndex { $0.frame.intersects(frame) }
        Diagnostics.log(
            "浮层显示：可见=\(panel.isVisible) key=\(panel.isKeyWindow) "
            + "位置=(\(Int(frame.minX)),\(Int(frame.minY))) 尺寸=\(Int(frame.width))×\(Int(frame.height)) "
            + "屏幕=\(screen.map(String.init) ?? "不在任何屏幕内")"
        )
    }

    func dismiss(reason: String = "未标注") {
        guard panel?.isVisible == true else { return }
        Diagnostics.log("浮层关闭：\(reason)")
        stopWatchingOutsideClicks()
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickResultPanel {
        let panel = QuickResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: quickResultWidth, height: 160),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // 需要盖在全屏应用之上，菜单级窗口并允许出现在任意 Space。
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let root = QuickResultView(
            model: model,
            onOpenInWindow: { [weak self] text in
                self?.dismiss(reason: "在窗口中打开")
                self?.openInMainWindow?(text)
            },
            onClose: { [weak self] in
                self?.dismiss(reason: "点了关闭按钮")
            }
        )
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        return panel
    }

    /// 首次显示时 SwiftUI 尚未完成布局，窗口尺寸会是 0，
    /// 结果是窗口「可见」却什么都看不到。这里补一次强制布局。
    private func ensureContentSize(_ panel: QuickResultPanel) {
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()

        let fitting = view.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return }
        guard panel.frame.width < 1 || panel.frame.height < 1 else { return }
        panel.setContentSize(fitting)
    }

    /// 把浮层挂在鼠标下方，越界时翻转到另一侧。
    private func anchorNearMouse(_ panel: QuickResultPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = panel.frame.size
        let gap: CGFloat = 14

        var topLeft = NSPoint(x: mouse.x + gap, y: mouse.y - gap)
        if topLeft.x + size.width > visible.maxX {
            topLeft.x = max(visible.minX + 8, mouse.x - gap - size.width)
        }
        if topLeft.y - size.height < visible.minY {
            topLeft.y = min(visible.maxY - 8, mouse.y + gap + size.height)
        }
        panel.anchorTopLeft = topLeft
        panel.setFrameTopLeftPoint(topLeft)
    }

    private func startWatchingOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor in
                self?.dismiss(reason: "外部点击 \(event.type.rawValue)")
            }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }
}

/// 浮层窗口：可在不激活应用的前提下接收键盘，并在高度变化时保持顶部不动。
final class QuickResultPanel: NSPanel {
    var anchorTopLeft: NSPoint?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        Diagnostics.log("浮层关闭：按了 Esc")
        orderOut(sender)
    }

    override func setContentSize(_ size: NSSize) {
        super.setContentSize(size)
        // 译文异步到达会撑高窗口，顶部固定才不会在鼠标下方跳动。
        if let anchorTopLeft {
            setFrameTopLeftPoint(anchorTopLeft)
        }
    }
}

private struct QuickResultView: View {
    @ObservedObject var model: TranslatorModel
    @State private var configuration: TranslationSession.Configuration?

    let onOpenInWindow: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            source
            Divider()
            result
            footer
        }
        .padding(16)
        .frame(width: quickResultWidth, alignment: .leading)
        .onChange(of: model.pendingRequest, initial: true) { _, request in
            guard let request else { return }
            TranslationRunner.refresh(&configuration, for: request)
        }
        .translationTask(configuration) { session in
            await TranslationRunner.run(session: session, model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.book.closed")
                .foregroundStyle(.tint)
            Text(model.direction.sourceDisplayName)
            Image(systemName: "arrow.right")
                .font(.caption2)
            Text(model.direction.targetDisplayName)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭（Esc）")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var source: some View {
        Text(model.sourceText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var result: some View {
        switch model.activity {
        case .downloading, .translating, .waiting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .error(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .copied:
            ScrollView(.vertical) {
                Text(model.translatedText)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 220)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.copyTranslation()
            } label: {
                Label(
                    model.activity == .copied ? "已拷贝" : "拷贝译文",
                    systemImage: model.activity == .copied ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(model.translatedText.isEmpty)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.sourceText, forType: .string)
            } label: {
                Label("拷贝原文", systemImage: "doc.on.clipboard")
            }
            .disabled(model.sourceText.isEmpty)

            Button("在窗口中打开") {
                onOpenInWindow(model.sourceText)
            }

            Spacer()
        }
        .font(.callout)
        .controlSize(.small)
    }
}
