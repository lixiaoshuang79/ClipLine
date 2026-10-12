import AppKit

/// 剪贴板面板的窗口基类：透明、浮在所有普通窗口之上、跨 Space、点击不激活本 App。
/// 结构改编自 Tendedero（MIT）；差异：可成为 key window 以接收键盘，击键默认进搜索框。
/// 具体样式由子类决定：`LinePanel`（顶部晾衣绳）、`PastePanel`（底部卡片）。
class ClipPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onEnter: (() -> Void)?
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    private(set) weak var searchField: NSTextField?
    private var wantsSearchFocus = false

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

    // MARK: 搜索框焦点

    func adopt(searchField field: NSTextField) {
        searchField = field
        if wantsSearchFocus { focusSearch() }
    }

    /// 让搜索框成为第一响应者（光标放到末尾），击键与输入法都进它。搜索框还没建好时，建好后再补上。
    func focusSearch() {
        guard let field = searchField else {
            wantsSearchFocus = true
            return
        }
        wantsSearchFocus = false
        guard field.currentEditor() == nil else { return }
        makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }

    /// 点过卡片之类的地方后，焦点回到搜索框。
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseUp, isVisible, isKeyWindow { focusSearch() }
    }

    /// 没有主菜单的 accessory App 收不到编辑快捷键，这里直接转给搜索框的字段编辑器。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let shift = flags.contains(.shift)
            let action: Selector? = {
                switch key {
                case "a" where !shift: return #selector(NSText.selectAll(_:))
                case "c" where !shift: return #selector(NSText.copy(_:))
                case "v" where !shift: return #selector(NSText.paste(_:))
                case "x" where !shift: return #selector(NSText.cut(_:))
                case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
                default: return nil
                }
            }()
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 搜索框不在编辑时的兜底：方向键/回车/Esc 照旧，可打印字符交回搜索框。
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()            // esc
        case 36, 76: onEnter?()         // return / enter
        case 123: onLeft?()             // ←
        case 124: onRight?()            // →
        default:
            if searchField != nil, event.modifierFlags.intersection([.command, .control]).isEmpty {
                focusSearch()
                searchField?.currentEditor()?.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// 绳挂在指针所在的屏幕上。
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 默认（晾衣绳）：挂在指针所在的屏幕顶部。
    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let visible = (screen ?? LinePanel.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}

/// 顶部晾衣绳面板（默认样式）。
final class LinePanel: ClipPanel {}

/// 「底部卡片」面板：贴屏幕底边（同 Paste 层级 24 → 浮在 Dock 之上）、带投影，其余行为与晾衣绳共用基类。
final class PastePanel: ClipPanel {
    override init(content: NSView) {
        super.init(content: content)
        hasShadow = true
        // 浮在 Dock 之上（Dock 层 ≈ 20）：面板下缘与 Dock 区域重叠，卡片要盖在 Dock 上沿。
        level = .mainMenu
    }

    /// 版式按 Paste 快捷面板实拍：全屏宽减左右 6pt、**贴屏幕底边**（不是 visibleFrame，
    /// 底部与 Dock 重叠、卡片下沿在 Dock 之上）；见 ~/claude/projects/common/2026-10-12/paste样式逆向/。
    override func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let target = screen ?? LinePanel.screenUnderPointer() else { return }
        let frame = target.frame
        let rect = NSRect(x: frame.minX + PastePanelView.sideMargin, y: frame.minY,
                          width: frame.width - PastePanelView.sideMargin * 2,
                          height: PastePanelView.panelHeight)
        if self.frame != rect { setFrame(rect, display: true) }
    }
}
