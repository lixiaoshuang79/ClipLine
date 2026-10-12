import AppKit

/// 屏幕取字完成后的顶部确认卡片（对齐 Shottr 的 OCR 确认弹窗习惯）：
/// 屏幕顶部居中一张小卡片——青色图标 +「已识别并复制到剪贴板 · N 字」+ 识别文本前两行（放不下就底部渐隐），
/// 文本里还有换行时给一个「去换行」按钮（同 Shottr 的 Cut Breaks，点了重拷去换行版本）。
/// 点卡片外 / Esc / × 收起；不抢前台 App 的焦点；识别文本照旧自动进剪贴板与剪贴板绳历史。
final class OcrResultPanel: NSPanel {
    private var text: String
    private var outsideMonitor: Any?
    private var statusLabel: NSTextField!
    private var previewLabel: NSTextField!
    private var breaksButton: NSButton?

    private static let cardWidth: CGFloat = 440
    private static let pad: CGFloat = 12
    private static let previewMaxHeight: CGFloat = 34   // 两行 12pt
    private static let statusHeight: CGFloat = 17

    init(text: String, on screen: NSScreen) {
        self.text = text

        let textX = Self.pad + 18 + 10
        let hasBreaks = text.contains("\n")
        let rightZone: CGFloat = 26 + (hasBreaks ? 74 : 0)
        let previewWidth = Self.cardWidth - textX - Self.pad - rightZone
        let font = NSFont.systemFont(ofSize: 12)
        let measured = ceil((text as NSString).boundingRect(
            with: NSSize(width: previewWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height)
        let previewHeight = min(max(measured, 15), Self.previewMaxHeight)
        let truncated = measured > Self.previewMaxHeight + 0.5
        let rowHeight = max(previewHeight, hasBreaks ? 22 : 0)
        let height = Self.pad + Self.statusHeight + 4 + rowHeight + Self.pad

        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.cardWidth, height: height)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: height))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        // 图标：屏幕取字的青色标识（对齐卡片体系里 .screenText 的色相）。
        let icon = NSImageView(frame: NSRect(x: Self.pad, y: height - Self.pad - 18, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        icon.contentTintColor = NSColor(calibratedHue: 195.0 / 360, saturation: 0.42, brightness: 0.62, alpha: 1)
        effect.addSubview(icon)

        statusLabel = NSTextField(labelWithString: "已识别并复制到剪贴板 · \(text.count) 字")
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: textX, y: height - Self.pad - Self.statusHeight,
                                   width: previewWidth, height: Self.statusHeight)
        effect.addSubview(statusLabel)

        let close = FirstMouseButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")!,
                                     target: self, action: #selector(closeTapped(_:)))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: Self.cardWidth - Self.pad - 18, y: height - Self.pad - 16.5, width: 18, height: 18)
        effect.addSubview(close)

        // 预览：最多两行，超高底部渐隐（不用省略号）；超长部分靠容器裁切，标签按顶部对齐摆放。
        let container = NSView(frame: NSRect(x: textX, y: Self.pad + (rowHeight - previewHeight) / 2,
                                             width: previewWidth, height: previewHeight))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        previewLabel = NSTextField(wrappingLabelWithString: text)
        previewLabel.font = font
        previewLabel.textColor = .labelColor
        previewLabel.frame = NSRect(x: 0, y: previewHeight - measured, width: previewWidth, height: measured)
        container.addSubview(previewLabel)
        if truncated {
            let fade = CAGradientLayer()
            fade.frame = container.bounds
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.locations = [0, 0.72, 1]
            container.layer?.mask = fade
        }
        effect.addSubview(container)

        if hasBreaks {
            let button = FirstMouseButton(title: "去换行", target: self, action: #selector(cutBreaksTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11.5)
            button.sizeToFit()
            button.setFrameOrigin(NSPoint(x: Self.cardWidth - Self.pad - button.frame.width,
                                          y: Self.pad + (rowHeight - button.frame.height) / 2))
            breaksButton = button
            effect.addSubview(button)
        }

        contentView = effect

        // 顶部居中（菜单栏之下，同 Shottr 的位置）。
        let visible = screen.visibleFrame
        let y = max(visible.maxY - height - 8, visible.minY + 8)
        setFrameOrigin(NSPoint(x: visible.midX - Self.cardWidth / 2, y: y))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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

    @objc private func closeTapped(_ sender: Any?) {
        dismiss()
    }

    /// 同 Shottr 的 Cut Breaks：把当前识别文本去掉换行再复制一份（卡片保留，预览同步换掉）。
    @objc private func cutBreaksTapped(_ sender: Any?) {
        let stripped = Ocr.removeBreaks(text)
        let rep: [NSPasteboard.PasteboardType: Data] = [.string: Data(stripped.utf8)]
        Paster.copyToPasteboard([rep])
        text = stripped
        statusLabel.stringValue = "已复制去换行文本 · \(stripped.count) 字"
        previewLabel.stringValue = stripped
        breaksButton?.isHidden = true
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
    你能感受到别人没有说出口的情绪，这是一份珍贵的敏锐。你不必负责让每一片阴云立刻散开，温柔地问一句，然后陪在旁边，就已经足够。
    OCR result panel demo — ClipLine 2026-10-12
    """
}

/// 非激活面板里的按钮：第一次点击就直达按钮，不先吞掉去激活窗口。
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
