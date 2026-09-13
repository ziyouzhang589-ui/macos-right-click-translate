import ApplicationServices
import AppKit
import Carbon
import Combine
import SwiftUI
import Translation

private let defaultWindowSize = NSSize(width: 760, height: 440)
private let minimumWindowSize = NSSize(width: 640, height: 360)
private let hotKeyIdentifier = EventHotKeyID(signature: 0x5A485954, id: 1)

struct TranslationRequest: Equatable {
    let id: UUID
    let text: String
    let direction: TranslationDirection
}

@MainActor
final class TranslatorModel: ObservableObject {
    static let shared = TranslatorModel()

    enum Activity: Equatable {
        case idle
        case waiting
        case downloading
        case translating
        case copied
        case error(String)
    }

    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var direction: TranslationDirection = .chineseToEnglish
    @Published var activity: Activity = .idle
    @Published private(set) var pendingRequest: TranslationRequest?

    private var debounceTask: Task<Void, Never>?
    private var copiedResetTask: Task<Void, Never>?
    private var requestHandler: ((TranslationRequest) -> Void)?
    private var suppressNextAutomaticTranslation = false

    var canTranslate: Bool {
        TranslationTextClassifier.hasTranslatableContent(sourceText)
    }

    var canCopy: Bool {
        !translatedText.isEmpty
    }

    var statusText: String {
        switch activity {
        case .idle:
            return canTranslate ? "停止输入后自动翻译" : "请输入中文或英文"
        case .waiting:
            return "准备翻译…"
        case .downloading:
            return "首次使用，正在准备中英文语言包…"
        case .translating:
            return "翻译中…"
        case .copied:
            return "已复制"
        case let .error(message):
            return message
        }
    }

    var isBusy: Bool {
        activity == .downloading || activity == .translating
    }

    func installRequestHandler(_ handler: @escaping (TranslationRequest) -> Void) {
        requestHandler = handler
    }

    func sourceTextDidChange() {
        debounceTask?.cancel()
        copiedResetTask?.cancel()

        if suppressNextAutomaticTranslation {
            suppressNextAutomaticTranslation = false
            return
        }

        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranslationTextClassifier.hasTranslatableContent(trimmed) else {
            pendingRequest = nil
            translatedText = ""
            activity = .idle
            return
        }

        // Invalidate any in-flight result immediately. The next request is
        // intentionally delayed, but an older translation must never appear
        // during that debounce window.
        pendingRequest = nil
        translatedText = ""
        direction = TranslationTextClassifier.direction(for: trimmed)
        activity = .waiting
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.requestTranslation()
        }
    }

    func requestTranslation() {
        debounceTask?.cancel()
        copiedResetTask?.cancel()

        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranslationTextClassifier.hasTranslatableContent(trimmed) else {
            pendingRequest = nil
            translatedText = ""
            activity = .idle
            return
        }

        let request = TranslationRequest(
            id: UUID(),
            text: sourceText,
            direction: direction
        )
        pendingRequest = request
        activity = .translating
        requestHandler?(request)
    }

    /// 由「服务」菜单等外部来源送入文本，跳过输入防抖直接翻译。
    func acceptExternalText(_ text: String) {
        debounceTask?.cancel()
        copiedResetTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        suppressNextAutomaticTranslation = true
        sourceText = text
        translatedText = ""
        pendingRequest = nil

        guard TranslationTextClassifier.hasTranslatableContent(trimmed) else {
            activity = .error("没有可翻译的文字")
            return
        }

        direction = TranslationTextClassifier.direction(for: trimmed)
        requestTranslation()
    }

    func paste() {
        guard let clipboardText = NSPasteboard.general.string(forType: .string) else {
            activity = .error("剪贴板中没有文字")
            return
        }
        sourceText = clipboardText
    }

    func clear() {
        debounceTask?.cancel()
        copiedResetTask?.cancel()
        pendingRequest = nil
        sourceText = ""
        translatedText = ""
        direction = .chineseToEnglish
        activity = .idle
    }

    func swap() {
        guard !translatedText.isEmpty else { return }
        debounceTask?.cancel()
        copiedResetTask?.cancel()

        suppressNextAutomaticTranslation = true
        sourceText = translatedText
        translatedText = ""
        direction = direction.reversed
        requestTranslation()
    }

    func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
        activity = .copied

        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.activity = .idle
        }
    }

    func beginLanguageDownload(for request: TranslationRequest) {
        guard pendingRequest?.id == request.id else { return }
        activity = .downloading
    }

    func beginTranslation(for request: TranslationRequest) {
        guard pendingRequest?.id == request.id else { return }
        activity = .translating
    }

    func finish(_ result: String, for request: TranslationRequest) {
        guard pendingRequest?.id == request.id else { return }
        translatedText = result
        activity = .idle
    }

    func fail(_ message: String, for request: TranslationRequest) {
        guard pendingRequest?.id == request.id else { return }
        translatedText = ""
        activity = .error(message)
    }
}

private struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.textColor = .labelColor
    }
}

private struct TranslatorView: View {
    @StateObject private var model = TranslatorModel.shared
    @State private var configuration: TranslationSession.Configuration?
    @FocusState private var sourceIsFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            header
            languageBar
            editorArea
            footer
        }
        .padding(18)
        .frame(minWidth: minimumWindowSize.width, minHeight: minimumWindowSize.height)
        .background(.ultraThinMaterial)
        .onAppear {
            model.installRequestHandler { request in
                TranslationRunner.refresh(&configuration, for: request)
            }
            sourceIsFocused = true
        }
        .onChange(of: model.sourceText) {
            model.sourceTextDidChange()
        }
        .translationTask(configuration) { session in
            await TranslationRunner.run(session: session, model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed.fill")
                .foregroundStyle(.tint)
                .font(.title2)
            Text("中英快译")
                .font(.title2.weight(.semibold))
            Spacer()
            Text("⌃⌥T")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.10), in: Capsule())
        }
        .padding(.horizontal, 4)
    }

    private var languageBar: some View {
        HStack(spacing: 14) {
            languageLabel(title: "自动识别", language: model.direction.sourceDisplayName)
                .frame(maxWidth: .infinity)

            Button {
                model.swap()
                sourceIsFocused = true
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.translatedText.isEmpty)
            .help("交换原文和译文")

            languageLabel(title: "译为", language: model.direction.targetDisplayName)
                .frame(maxWidth: .infinity)
        }
    }

    private func languageLabel(title: String, language: String) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(language)
                .fontWeight(.semibold)
        }
        .font(.subheadline)
    }

    private var editorArea: some View {
        HStack(spacing: 12) {
            sourceEditor
            translatedEditor
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.82))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(sourceIsFocused ? Color.accentColor.opacity(0.65) : .secondary.opacity(0.18))
                }

            TextEditor(text: $model.sourceText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(7)
                .focused($sourceIsFocused)
                .accessibilityLabel("原文")

            if model.sourceText.isEmpty {
                Text("粘贴或输入中文、英文…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var translatedEditor: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.secondary.opacity(0.14))
                }

            SelectableTextView(text: model.translatedText)
                .padding(4)
                .accessibilityLabel("译文")

            if model.translatedText.isEmpty && !model.isBusy {
                Text("翻译结果")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button {
                model.paste()
                sourceIsFocused = true
            } label: {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }

            Button(role: .destructive) {
                model.clear()
                sourceIsFocused = true
            } label: {
                Label("清空", systemImage: "xmark.circle")
            }
            .disabled(model.sourceText.isEmpty && model.translatedText.isEmpty)

            Button {
                model.requestTranslation()
            } label: {
                Label("重新翻译", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canTranslate || model.isBusy)
            .keyboardShortcut(.return, modifiers: .command)

            Spacer(minLength: 10)

            statusLabel

            Button {
                model.copyTranslation()
            } label: {
                Label("复制译文", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCopy)
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var statusLabel: some View {
        HStack(spacing: 6) {
            if model.isBusy {
                ProgressView()
                    .controlSize(.mini)
            }
            if case .copied = model.activity {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if case .error = model.activity {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(model.statusText)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

}

private final class TranslatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let running = RightClickWatcher.shared.isRunning
            gestureStatusItem?.title = running
                ? "右键翻译  已启用"
                : "右键翻译  未授权，点此开启"
            gestureStatusItem?.isEnabled = !running
            launchAtLoginItem?.state = LaunchAtLogin.isEnabled ? .on : .off
        }
    }
}

/// 接收系统「服务」菜单送来的选中文本（Info.plist 中的 NSServices 声明）。
private final class TranslationServiceProvider: NSObject {
    var handler: (@MainActor (String) -> Void)?

    @objc func translateSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "没有选中可翻译的文字。" as NSString
            return
        }

        DispatchQueue.main.async { [handler] in
            MainActor.assumeIsolated {
                handler?(text)
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: TranslatorPanel?
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private let serviceProvider = TranslationServiceProvider()
    private var hasPromptedForAccessibility = false
    private var didShowQuickResult = false
    private var accessibilityWatchTimer: Timer?
    private var gestureStatusItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicateInstance() else {
            NSApp.terminate(nil)
            return
        }

        // 菜单栏常驻工具：不占程序坞与 Cmd+Tab，主窗口仍可从菜单栏打开。
        NSApp.setActivationPolicy(.accessory)

        // 没有窗口的后台应用会被系统自动回收，右键监听随之失效。
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("菜单栏常驻，需持续监听右键")
        if let iconURL = Bundle.main.url(forResource: "BilingualTranslator", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        createPanel()
        createStatusItem()
        registerGlobalHotKey()
        registerTextService()
        registerRightClickGesture()

        // 被「服务」菜单唤起时只弹浮层；用户主动打开应用才显示主窗口。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.didShowQuickResult else { return }
            self.showPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    @MainActor
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            showPanel()
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func createPanel() {
        let panel = TranslatorPanel(
            contentRect: NSRect(origin: .zero, size: defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "中英快译"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.minSize = minimumWindowSize
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TranslatorView())
        self.panel = panel
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "character.book.closed.fill",
                accessibilityDescription: "中英快译"
            )
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "打开中英快译",
            action: #selector(showPanelFromMenu),
            keyEquivalent: ""
        )
        let shortcutItem = NSMenuItem(title: "快捷键  ⌃⌥T", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        let launchItem = NSMenuItem(
            title: "开机时自动启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        menu.addItem(launchItem)
        launchAtLoginItem = launchItem

        let gestureItem = NSMenuItem(
            title: "",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        menu.addItem(gestureItem)
        gestureStatusItem = gestureItem
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出中英快译",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        menu.autoenablesItems = false
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr, identifier.id == hotKeyIdentifier.id else {
                    return OSStatus(eventNotHandledErr)
                }

                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    delegate.handleHotKey()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )

        guard handlerStatus == noErr else {
            NSLog("中英快译：无法安装全局快捷键事件处理器（%d）", handlerStatus)
            return
        }

        let modifiers = UInt32(controlKey | optionKey)
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            modifiers,
            hotKeyIdentifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registrationStatus != noErr {
            NSLog("中英快译：快捷键 ⌃⌥T 注册失败（%d），仍可从菜单栏打开。", registrationStatus)
        }
    }

    @MainActor
    private func registerTextService() {
        serviceProvider.handler = { text in
            QuickResultController.shared.show(text: text)
        }
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        QuickResultController.shared.onShow = { [weak self] in
            self?.didShowQuickResult = true
            self?.hideUnusedPanel()
        }

        QuickResultController.shared.openInMainWindow = { [weak self] text in
            TranslatorModel.shared.acceptExternalText(text)
            self?.showPanel()
        }
    }

    @MainActor
    @objc private func showPanelFromMenu() {
        showPanel()
    }

    @MainActor
    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
    }

    @MainActor
    @objc private func openAccessibilitySettings() {
        guard !RightClickWatcher.shared.isRunning else { return }
        SelectionCapture.requestTrust()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApplication() {
        LaunchAtLogin.suspendUntilNextLogin()
        NSApp.terminate(nil)
    }

    /// 热键按下：优先抓取前台应用中选中的文字并直接翻译。
    ///
    /// 本应用已在前台时保持原有的显示/隐藏行为，避免打断正在窗口里的编辑。
    @MainActor
    private func handleHotKey() {
        guard !NSApp.isActive else {
            togglePanel()
            return
        }

        guard SelectionCapture.isTrusted else {
            promptForAccessibilityAccess()
            return
        }

        Task { @MainActor in
            guard let selection = await SelectionCapture.capture() else {
                togglePanel()
                return
            }
            QuickResultController.shared.show(text: selection)
        }
    }

    /// 未授权辅助功能时，引导用户去系统设置开启。每次运行只提示一次。
    @MainActor
    private func promptForAccessibilityAccess() {
        guard !hasPromptedForAccessibility else { return }
        hasPromptedForAccessibility = true

        let alert = NSAlert()
        alert.messageText = "开启「辅助功能」后即可右键翻译"
        alert.informativeText = """
        授权后，在任何应用里选中文字再点右键，即可就地看到译文，\
        包括 Claude、VS Code 这类自绘右键菜单、系统无法插入条目的应用。

        在系统设置中勾选「中英快译」即可生效，不需要重启本应用。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "以后再说")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SelectionCapture.requestTrust()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// launchd 托管与手动打开可能同时发生，重复实例直接退出。
    @MainActor
    private func isDuplicateInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return false }
        Diagnostics.log("已有实例在运行，本次启动退出")
        return true
    }

    /// 睡眠唤醒后事件抽头常被系统停用，醒来后确认一次。
    @MainActor
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            RightClickWatcher.shared.revalidate()
        }
    }

    /// 装上右键手势；尚未授权辅助功能时，等待用户授权后自动生效。
    @MainActor
    private func registerRightClickGesture() {
        RightClickWatcher.shared.onTrigger = { [weak self] selection, location in
            self?.translateGestureSelection(selection, at: location)
        }

        Diagnostics.log("—— 应用启动 ——")
        LaunchAtLogin.enableOnFirstRun()
        observeWake()
        let started = RightClickWatcher.shared.start()
        guard !started else { return }
        waitForAccessibilityAccess()
        promptForAccessibilityAccess()
    }

    /// 右键触发：优先用辅助功能读到的选中文字，读不到再退回模拟拷贝。
    @MainActor
    private func translateGestureSelection(_ selection: String?, at location: CGPoint) {
        if let selection {
            QuickResultController.shared.show(text: selection)
            return
        }

        Task { @MainActor in
            // 焦点刚变化时辅助功能可能暂时读不到，短暂等待后再试一次。
            try? await Task.sleep(for: .milliseconds(60))
            if let retried = AccessibilitySelection.read() {
                Diagnostics.log("弹出浮层（辅助功能重试成功）")
                QuickResultController.shared.show(text: retried)
                return
            }

            guard let captured = await SelectionCapture.capture() else {
                // 判定有选中文字但实际没有，把右键还给应用。
                RightClickWatcher.shared.replayRightClick(at: location)
                return
            }
            Diagnostics.log("弹出浮层（模拟拷贝，\(captured.count) 字）")
            QuickResultController.shared.show(text: captured)
        }
    }

    /// 授权面板中勾选后无需重启应用，这里轮询到权限即刻启用手势。
    @MainActor
    private func waitForAccessibilityAccess() {
        guard accessibilityWatchTimer == nil else { return }
        accessibilityWatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            Task { @MainActor in
                guard RightClickWatcher.shared.start() else { return }
                timer.invalidate()
                self.accessibilityWatchTimer = nil
            }
        }
    }

    /// 浮层弹出时收起主窗口，但保留用户已经输入过内容的窗口。
    @MainActor
    private func hideUnusedPanel() {
        guard let panel, panel.isVisible else { return }
        guard TranslatorModel.shared.sourceText.isEmpty else { return }
        panel.orderOut(nil)
    }

    @MainActor
    private func togglePanel() {
        guard let panel else { return }
        panel.isVisible ? panel.orderOut(nil) : showPanel()
    }

    @MainActor
    private func showPanel() {
        guard let panel else { return }
        center(panel, on: screenContainingMouse())
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        window.setFrameOrigin(origin)
    }
}

@main
private enum BilingualTranslatorMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        _ = delegate
    }
}
