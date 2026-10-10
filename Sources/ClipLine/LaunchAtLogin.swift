import AppKit

/// 登录自启：写一个 LaunchAgent 交给 launchd。
/// 不用 SMAppService：它要求更完整的签名链，本 App 是 ad-hoc 签名，LaunchAgent 更直接可控。
enum LaunchAtLogin {
    static let label = "com.ashuang.clipline"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// 打开自启：写 plist 并交给 launchd（重复开启时先卸掉旧的）。
    static func enable() throws {
        let bundlePath = Bundle.main.bundlePath
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>\(bundlePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
        _ = run(["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"])
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        let status = run(["/bin/launchctl", "bootstrap", "gui/\(getuid())", plistURL.path])
        guard status == 0 else {
            throw Failure(description: "launchctl bootstrap 失败（退出码 \(status)）")
        }
    }

    /// 关闭自启。
    static func disable() {
        _ = run(["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
