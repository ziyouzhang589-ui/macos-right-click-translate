import AppKit

/// 开机自启与常驻守护。
///
/// 用 launchd 托管而非登录项：登录项只在登录时启动一次，睡眠唤醒不重新登录，
/// 进程一旦被系统收掉就再也不会回来。`KeepAlive` 能在异常退出后自动拉起，
/// 同时保留用户从菜单主动退出的能力。
enum LaunchAtLogin {
    static let label = "com.local.bilingual-translator"

    private static var plistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 首次运行时默认开启：右键翻译依赖本应用常驻后台。
    static func enableOnFirstRun() {
        let key = "LaunchAgentConfigured"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        setEnabled(true)
    }

    /// 用户主动退出前调用：解除本次会话的托管，避免刚退就被拉起。
    /// plist 仍保留，下次登录照常自启。
    static func suspendUntilNextLogin() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        Diagnostics.log("用户主动退出，已解除本次会话的托管")
    }

    static func setEnabled(_ enabled: Bool) {
        enabled ? install() : uninstall()
    }

    private static func install() {
        let executable = Bundle.main.executableURL?.path ?? ""
        guard !executable.isEmpty else { return }

        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // 无条件重启：系统在睡眠期间是以「正常退出」的方式收掉它的，
            // 只认异常退出会让进程一去不回。用户主动退出时先解除托管。
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "ThrottleInterval": 10,
        ]

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(
                fromPropertyList: job,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL)
            runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
            runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            Diagnostics.log("已交给 launchd 托管（异常退出会自动拉起）")
        } catch {
            Diagnostics.log("安装 launchd 任务失败：\(error.localizedDescription)")
        }
    }

    private static func uninstall() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        Diagnostics.log("已取消 launchd 托管")
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
