import AppKit

/// 屏幕取字的结果面板：识别完成后把文字内容摆在选区旁，供核对与再复制。
/// 交互对齐 Shottr 的确认气泡惯例：屏幕取字结束自动进剪贴板，面板只是可见的确认 + 内容回看；
/// 点面板外、Esc、或按钮都关闭；不抢前台 App 的焦点（nonactivating，仅在点击内容时才取键盘）。
final class OcrResultPanel: NSPanel {
    private let text: String
    private var outsideMonitor: Any?

    init(text: String, near rect: NSRect, on screen: NSScreen) {
        self.text = text
        let width: CGFloat = 460
        let inset: CGFloat = 14
        let textWidth = width - inset * 2
        let font = NSFont.systemFont(ofSize: 13)
        let header: CGFloat = 15
        let footer: CGFloat = 26
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let textHeight = min(max(ceil(bounding.height) + 2, 20), 300)
        let height = inset + header + 6 + textHeight + 10 + footer + inset

        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        let label = NSTextField(labelWithString: "已复制到剪贴板 · \(text.count) 字")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: inset, y: height - inset - header, width: textWidth, height: header)
        effect.addSubview(label)

        let scroll = NSScrollView(frame: NSRect(x: inset, y: 10 + footer + inset,
                                                width: textWidth, height: textHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: textHeight))
        textView.string = text
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        scroll.documentView = textView
        effect.addSubview(scroll)

        let closeButton = FirstMouseButton(title: "关闭", target: self, action: #selector(closeTapped(_:)))
        let copyButton = FirstMouseButton(title: "全部复制", target: self, action: #selector(copyAllTapped(_:)))
        for button in [closeButton, copyButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11.5)
            button.sizeToFit()
        }
        let buttonY = inset + (footer - closeButton.frame.height) / 2
        closeButton.setFrameOrigin(NSPoint(x: width - inset - closeButton.frame.width, y: buttonY))
        copyButton.setFrameOrigin(NSPoint(x: closeButton.frame.minX - 8 - copyButton.frame.width, y: buttonY))
        effect.addSubview(closeButton)
        effect.addSubview(copyButton)

        contentView = effect

        // 默认贴在选区下方 8pt；下方放不下翻到上方；左右夹在屏幕内。
        var x = screen.frame.minX + rect.minX
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - width - 8)
        var y = screen.frame.minY + rect.minY - height - 8
        if y < screen.frame.minY + 8 {
            y = screen.frame.minY + rect.maxY + 8
            if y + height > screen.frame.maxY - 8 { y = screen.frame.maxY - height - 8 }
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 上屏并挂"点外面关闭"的全局监视。
    func present() {
        orderFrontRegardless()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss() }
        }
    }

    func dismiss() {
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    @objc private func closeTapped(_ sender: Any?) {
        dismiss()
    }

    @objc private func copyAllTapped(_ sender: Any?) {
        let rep: [NSPasteboard.PasteboardType: Data] = [.string: Data(text.utf8)]
        Paster.copyToPasteboard([rep])
        dismiss()
    }

    // MARK: 调试

    /// 调试：CLIPLINE_OCR_RESULT_SNAPSHOT=<png> 时展示示例面板、自捕获该窗口后退出
    /// （抓自己的窗口不需要屏幕录制权限）。
    static func snapshotDemoIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CLIPLINE_OCR_RESULT_SNAPSHOT"] else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { NSApp.terminate(nil); return }
            let rect = NSRect(x: (screen.frame.width - 400) / 2, y: screen.frame.height / 2 - 100,
                              width: 400, height: 80)
            let panel = OcrResultPanel(text: demoText, near: rect, on: screen)
            panel.present()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                let windowID = CGWindowID(panel.windowNumber)
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                       [.boundsIgnoreFraming, .bestResolution]),
                   let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    FileHandle.standardError.write("ocr-result snapshot: \(path)\n".data(using: .utf8)!)
                }
                NSApp.terminate(nil)
            }
        }
        return true
    }

    private static let demoText = """
    生成「ClipLine Dev」自签名证书导入登录钥匙串（私钥只存在钥匙串里，不
    你能感受到别人没有说出口的情绪，这是一份珍贵的敏锐。你不必负责让每一片阴云立刻散开，温柔地问一句，然后陪在旁边，就已经足够。
    OCR result panel demo — ClipLine 2026-10-12
    """
}

/// 非激活面板里的按钮：第一次点击就直达按钮，不先吞掉去激活窗口。
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
