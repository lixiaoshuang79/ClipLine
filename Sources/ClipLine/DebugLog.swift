import AppKit

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

/// 调试取证：记录最近一次落在面板里的**鼠标按下**——事件自己的坐标、面板原点，以及当时卡片行的滚动偏移。
/// 必须用事件坐标而不是 `NSEvent.mouseLocation`：探针用 `NSApp.postEvent` 合成点击，真实光标不动，
/// 读光标会把「点了第 1 张」记成「点了第 3 列」，正好伪造出要排查的那种错位。
enum ClickDebug {
    struct Sample {
        let screenPoint: NSPoint
        let panelOrigin: NSPoint
        let scrollOffset: CGFloat
        let isPastePanel: Bool
    }

    static var last: Sample?

    static func capture(window: NSWindow, pointInWindow: NSPoint, isPastePanel: Bool) {
        guard DebugLog.enabled else { return }
        last = Sample(screenPoint: window.convertPoint(toScreen: pointInWindow),
                      panelOrigin: window.frame.origin,
                      scrollOffset: cardRowOffset(in: window) ?? 0,
                      isPastePanel: isPastePanel)
    }

    /// 卡片行那根横向滚动条的当前偏移：窗口里文档最宽的 NSScrollView（顶栏那根窄得多）。
    private static func cardRowOffset(in window: NSWindow) -> CGFloat? {
        guard let content = window.contentView else { return nil }
        var widest: NSScrollView?
        func walk(_ view: NSView) {
            if view is NSTextView { return }
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.width ?? 0) > (widest?.documentView?.frame.width ?? 0) {
                widest = scroll
            }
            for child in view.subviews { walk(child) }
        }
        walk(content)
        return widest?.contentView.bounds.origin.x
    }
}
