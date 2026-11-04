import Foundation

/// CLIPLINE_DEBUG=1 时把粘贴关键路径写进 /tmp/clipline-paste-debug.log（与 `Paster.debugLog` 同一份）。
/// 只在排查「点某张卡却贴出另一张」时用：一次复现就能看出点中的条目、它在列表里的位置、
/// 以及真正写进剪贴板的那份快照指纹。
enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["CLIPLINE_DEBUG"] == "1"

    static func write(_ line: String) {
        guard enabled else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        let path = "/tmp/clipline-paste-debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
