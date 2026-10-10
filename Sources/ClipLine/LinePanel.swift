import AppKit

/// 屏幕顶部的透明条：浮在所有普通窗口之上、跨 Space、点击不激活本 App。
/// 结构改编自 Tendedero（MIT）；差异：可成为 key window 以接收键盘。
final class LinePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onEnter: (() -> Void)?
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        // 调试：降到普通窗口层，便于外部截图工具找到这个浮层窗口。
        if ProcessInfo.processInfo.environment["CLIPLINE_PANEL_LEVEL"] == "normal" { level = .normal }
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = true          // 收起时点击穿透；展开时由 AppDelegate 打开
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()            // esc
        case 36, 76: onEnter?()         // return / enter
        case 123: onLeft?()             // ←
        case 124: onRight?()            // →
        default: super.keyDown(with: event)
        }
    }

    /// 绳挂在指针所在的屏幕上。
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
