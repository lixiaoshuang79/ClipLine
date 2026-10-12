import AppKit

/// 屏幕取字：全屏遮罩上拖框选，抓选区像素跑本机 OCR，文字进剪贴板与历史。
/// 对齐 Shottr 的做法：需要屏幕录制权限、选区有面积上限、识别结果给明确提示。
final class ScreenTextCapture {
    /// 选区面积上限（像素），同 Shottr 的 "Area is too large" 保护。
    private static let maxAreaPixels: CGFloat = 40_000_000

    private var overlay: OverlayPanel?
    private var toast: NSPanel?
    private let store: ClipStore

    init(store: ClipStore) {
        self.store = store
    }

    func begin() {
        guard overlay == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            guideToPermission()
            return
        }
        guard let screen = LinePanel.screenUnderPointer() ?? NSScreen.main else { return }
        let overlay = OverlayPanel(screen: screen)
        overlay.onFinish = { [weak self] rect in self?.finish(rect: rect, screen: screen) }
        overlay.onCancel = { [weak self] in self?.dismissOverlay() }
        self.overlay = overlay
        overlay.makeKeyAndOrderFront(nil)
    }

    private func dismissOverlay() {
        overlay?.orderOut(nil)
        overlay = nil
    }

    private func finish(rect: NSRect, screen: NSScreen) {
        guard let overlay else { return }
        let windowID = CGWindowID(overlay.windowNumber)
        // 先抓「遮罩下面」的屏幕内容（遮罩本身不入镜），再收起遮罩。
        let full = CGWindowListCreateImage(.null, .optionOnScreenBelowWindow, windowID, [.bestResolution])
        dismissOverlay()
        guard rect.width >= 4, rect.height >= 4, let full else { return }

        let scale = CGFloat(full.width) / screen.frame.width
        // 选区（窗口坐标，左下原点）→ 屏幕坐标 → 图像像素坐标（图像以主屏左上为原点）。
        let inScreen = NSRect(x: rect.minX + screen.frame.minX, y: rect.minY + screen.frame.minY,
                              width: rect.width, height: rect.height)
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let crop = CGRect(x: inScreen.minX * scale,
                          y: (mainHeight - inScreen.maxY) * scale,
                          width: inScreen.width * scale,
                          height: inScreen.height * scale)
        guard crop.width * crop.height <= Self.maxAreaPixels, let region = full.cropping(to: crop) else {
            showToast("选区太大，换个小的试试", near: rect, on: screen)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = Ocr.recognize(region)
            DispatchQueue.main.async {
                guard let self else { return }
                if let text, !text.isEmpty {
                    self.deliver(text, near: rect, on: screen)
                } else {
                    self.showToast("没识别到文字", near: rect, on: screen)
                }
            }
        }
    }

    private func deliver(_ text: String, near rect: NSRect, on screen: NSScreen) {
        let item = ClipItem(kind: .text(text), source: .screenText, copiedAt: Date(),
                            snapshot: [[.string: Data(text.utf8)]], fingerprint: "t:" + text)
        if let snapshot = item.snapshot { Paster.copyToPasteboard(snapshot) }
        store.ingestScreenText(item)
        let summary = text.count > 16 ? String(text.prefix(16)) + "…" : text
        showToast("已取字：\(summary)（已复制）", near: rect, on: screen)
    }

    private func guideToPermission() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "屏幕取字需要「屏幕录制」权限"
        alert.informativeText = "在 系统设置 → 隐私与安全性 → 屏幕录制 里勾选 ClipLine，然后重试。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 选区附近的轻提示，1.6 秒后自动消失。
    private func showToast(_ message: String, near rect: NSRect, on screen: NSScreen) {
        toast?.orderOut(nil)
        let width: CGFloat = 440
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 12, y: 7, width: width - 24, height: 18)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = 9
        content.addSubview(label)

        let x = min(max(screen.frame.minX + rect.minX, screen.frame.minX + 8),
                    screen.frame.maxX - width - 8)
        let y = min(screen.frame.minY + rect.minY + rect.height + 8, screen.frame.maxY - 40)
        let panel = NSPanel(contentRect: NSRect(x: x, y: y, width: width, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.orderFrontRegardless()
        toast = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.toast?.orderOut(nil)
            self?.toast = nil
        }
    }
}

/// 取字遮罩：暗底 + 镂空选区 + 尺寸提示；拖框即选，Esc 取消。
private final class OverlayPanel: NSPanel {
    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        let selection = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        selection.onFinish = { [weak self] rect in self?.onFinish?(rect) }
        selection.onCancel = { [weak self] in self?.onCancel?() }
        contentView = selection
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

private final class SelectionView: NSView {
    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var start: NSPoint?
    private var selection: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let now = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, now.x), y: min(start.y, now.y),
                           width: abs(now.x - start.x), height: abs(now.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil }
        guard selection.width >= 4, selection.height >= 4 else {
            onCancel?()
            return
        }
        onFinish?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 暗底 + 镂空选区（even-odd 挖洞）。
        let dim = NSBezierPath(rect: bounds)
        if selection.width > 0, selection.height > 0 {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        guard selection.width > 0, selection.height > 0 else { return }
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()

        // 尺寸提示贴在选区左上角外侧。
        let text = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let labelRect = NSRect(x: selection.minX, y: min(selection.maxY + 6, bounds.maxY - size.height - 4),
                               width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 2), withAttributes: attributes)
    }
}
