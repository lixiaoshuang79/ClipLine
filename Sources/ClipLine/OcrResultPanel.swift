import AppKit

/// 屏幕取字完成后的顶部确认卡片——形态对齐 Shottr 的 OCR 确认弹窗：
/// 顶部居中一张深色小卡（HUD 材质）：App 图标 +「已识别并复制到剪贴板」+ 右侧「去换行」按钮
/// （同 Shottr 的 Cut Breaks，仅当文本里还有换行时出现；点了重拷去换行版本）。
/// 点卡片外 / Esc 收起；不抢前台 App 的焦点；识别文本照旧自动进剪贴板与剪贴板绳历史。
final class OcrResultPanel: NSPanel {
    private var text: String
    private var outsideMonitor: Any?
    private var iconView: NSImageView!
    private var messageLabel: NSTextField!
    private var breaksButton: NSButton?
    private let screenVisibleFrame: NSRect

    private static let pad: CGFloat = 14
    private static let iconSide: CGFloat = 36
    private static let cardHeight: CGFloat = 64

    init(text: String, on screen: NSScreen) {
        self.text = text
        self.screenVisibleFrame = screen.visibleFrame

        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: Self.cardHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true

        // 跟随系统明暗的半透明卡（同 Shottr 的确认卡：浅色下近白、深色下深灰），大圆角 + 软阴影。
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: Self.cardHeight))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        // 左边 App 图标（同 Shottr 放自家 logo 的做法）。
        iconView = NSImageView(frame: .zero)
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(iconView)

        messageLabel = NSTextField(labelWithString: "已识别并复制到剪贴板")
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        effect.addSubview(messageLabel)

        // 文本里还有换行时才给「去换行」——同 Shottr 的 Cut Breaks。
        if text.contains("\n") {
            let button = FirstMouseButton(title: "去换行", target: self, action: #selector(cutBreaksTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 13)
            button.sizeToFit()
            breaksButton = button
            effect.addSubview(button)
        }

        contentView = effect
        applyLayout()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 宽度随内容收放，窗口保持顶部居中。
    private func applyLayout() {
        let height = Self.cardHeight
        // 用 sizeToFit 实测宽度——按字体度量手算会短一截，文字被截断。
        messageLabel.sizeToFit()
        let textWidth = messageLabel.frame.width
        var width = Self.pad * 2 + Self.iconSide + 12 + textWidth
        if let button = breaksButton { width += 12 + button.frame.width }
        width = max(ceil(width), 260)
        setContentSize(NSSize(width: width, height: height))

        iconView.frame = NSRect(x: Self.pad, y: (height - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
        messageLabel.frame.origin = NSPoint(x: Self.pad + Self.iconSide + 12,
                                            y: (height - messageLabel.frame.height) / 2)
        if let button = breaksButton {
            button.setFrameOrigin(NSPoint(x: width - Self.pad - button.frame.width,
                                          y: (height - button.frame.height) / 2))
        }

        let visible = screenVisibleFrame
        let y = max(visible.maxY - height - 8, visible.minY + 8)
        setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: y))
    }

    /// 上屏并挂「点外面关闭」的全局监视。
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

    /// 同 Shottr 的 Cut Breaks：把当前识别文本去掉换行再复制一份，卡片就地更新。
    @objc private func cutBreaksTapped(_ sender: Any?) {
        let stripped = Ocr.removeBreaks(text)
        let rep: [NSPasteboard.PasteboardType: Data] = [.string: Data(stripped.utf8)]
        Paster.copyToPasteboard([rep])
        text = stripped
        messageLabel.stringValue = "已复制去换行文本"
        breaksButton?.removeFromSuperview()
        breaksButton = nil
        applyLayout()
    }

    // MARK: 调试

    /// 调试：CLIPLINE_OCR_RESULT_SNAPSHOT=<png> 时展示示例卡片、自捕获该窗口后退出
    /// （抓自己的窗口不需要屏幕录制权限）。
    static func snapshotDemoIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CLIPLINE_OCR_RESULT_SNAPSHOT"] else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { NSApp.terminate(nil); return }
            let panel = OcrResultPanel(text: demoText, on: screen)
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
    你能感受到别人没有说出口的情绪，这是一份珍贵的敏锐。
    OCR result panel demo — ClipLine 2026-10-12
    """
}

/// 非激活面板里的按钮：第一次点击就直达按钮，不先吞掉去激活窗口。
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
