import AppKit

/// 屏幕取字：全屏遮罩上拖框选，抓选区像素跑本机 OCR，文字进剪贴板与历史。
/// 对齐 Shottr 的做法：需要屏幕录制权限、选区有面积上限、识别结果给明确提示。
final class ScreenTextCapture {
    /// 选区面积上限（像素），同 Shottr 的 "Area is too large" 保护。
    private static let maxAreaPixels: CGFloat = 40_000_000

    private var overlay: OverlayPanel?
    private var toast: NSPanel?
    private var resultPanel: OcrResultPanel?
    /// 取字前的前台 App；取字结束/取消后请回来。
    private var previousApp: NSRunningApplication?
    private let store: ClipStore

    init(store: ClipStore) {
        self.store = store
    }

    func begin() {
        // 开始新一次取字先收起上次的结果面板——否则它会被拍进这次的选区。
        resultPanel?.dismiss()
        resultPanel = nil
        // 取字进行中再按一次热键 = 取消本次框选。
        if overlay != nil {
            dismissOverlay()
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            guideToPermission()
            return
        }
        guard let screen = LinePanel.screenUnderPointer() ?? NSScreen.main else { return }
        // 取字期间把自己变成前台（截图工具通例，Shottr 也如此）：只有这样十字光标才起得来、
        // Esc 才稳；结束或取消后把原前台 App 请回去。
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == getpid()) ? nil : front
        NSApp.activate()
        if !NSApp.isActive {
            // 合作式激活可能被拒（无点击上下文的激活请求）；框选必须拿到光标与键盘，强制激活兜底。
            NSApp.activate(ignoringOtherApps: true)
        }
        let overlay = OverlayPanel(screen: screen)
        overlay.onFinish = { [weak self] rect in self?.finish(rect: rect, screen: screen) }
        overlay.onCancel = { [weak self] in self?.dismissOverlay() }
        self.overlay = overlay
        overlay.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    private func dismissOverlay() {
        overlay?.orderOut(nil)
        overlay = nil
        // 取字期间我们短暂做过前台，把原 App 请回来。
        previousApp?.activate(options: [])
        previousApp = nil
    }

    private func finish(rect: NSRect, screen: NSScreen) {
        guard overlay != nil else { return }
        guard rect.width >= 4, rect.height >= 4 else {
            dismissOverlay()
            return
        }
        // 选区（遮罩窗口坐标，左下原点）→ Cocoa 全局坐标 → CG 显示坐标（左上原点，主屏为原点）。
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let inScreen = NSRect(x: rect.minX + screen.frame.minX, y: rect.minY + screen.frame.minY,
                              width: rect.width, height: rect.height)
        let cgRect = CGRect(x: inScreen.minX, y: mainHeight - inScreen.maxY,
                            width: inScreen.width, height: inScreen.height)
        let scale = screen.backingScaleFactor
        // 拖完立即收起遮罩（手感利落）；抓稳定帧放后台，此时是普通在屏抓取，遮罩已不在。
        dismissOverlay()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            usleep(60_000)   // 让 WindowServer 走一帧，别抓到遮罩残影
            let region = Self.captureStable(cgRect: cgRect)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let region else {
                    self.guideToPermission()
                    return
                }
                guard region.width * region.height <= Int(Self.maxAreaPixels) else {
                    self.showToast("选区太大，换个小的试试", near: rect, on: screen)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let text = Ocr.recognize(region, minimumTextHeightPixels: 6 * scale)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let text, !text.isEmpty {
                            self.deliver(text, on: screen)
                        } else {
                            self.showToast("没识别到文字", near: rect, on: screen)
                        }
                    }
                }
            }
        }
    }

    /// 抓「稳定帧」：连抓两帧做分块灰度比对，画面还在动（流式文字的渐入动画、滚动惯性）就等一拍重抓，最多三轮。
    /// 治的坑：抓在动画中间帧上，字被半透明中间态糊掉，Vision 会把「温柔」识别成「泪柔」这类形近字。
    static func captureStable(cgRect: CGRect) -> CGImage? {
        func grab() -> CGImage? {
            CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        }
        var latest = grab()
        for _ in 0..<2 {
            guard let a = latest else { return nil }
            usleep(180_000)
            guard let b = grab() else { return a }
            latest = b
            if blockDelta(a, b) < 1.0 { return b }
            usleep(360_000)
        }
        return latest
    }

    /// 两帧的分块灰度平均绝对差，取第 90 百分位：局部在动才算动（时钟跳秒之类的小块干扰不计）。
    static func blockDelta(_ a: CGImage, _ b: CGImage) -> Double {
        let w = 128
        let h = max(1, Int((Double(a.height) / Double(max(a.width, 1)) * 128).rounded()))
        guard a.width > 0, b.width > 0 else { return 0 }
        func gray(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h)
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.interpolationQuality = .low
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return buf
        }
        let pa = gray(a), pb = gray(b)
        var deltas: [Double] = []
        var y = 0
        while y + 8 <= h {
            var x = 0
            while x + 8 <= w {
                var sum = 0
                for yy in y..<(y + 8) {
                    for xx in x..<(x + 8) { sum += abs(Int(pa[yy * w + xx]) - Int(pb[yy * w + xx])) }
                }
                deltas.append(Double(sum) / 64)
                x += 8
            }
            y += 8
        }
        guard !deltas.isEmpty else { return 0 }
        deltas.sort()
        return deltas[min(deltas.count - 1, Int(Double(deltas.count) * 0.9))]
    }

    private func deliver(_ text: String, on screen: NSScreen) {
        let item = ClipItem(kind: .text(text), source: .screenText, copiedAt: Date(),
                            snapshot: [[.string: Data(text.utf8)]], fingerprint: "t:" + text)
        if let snapshot = item.snapshot { Paster.copyToPasteboard(snapshot) }
        store.ingestScreenText(item)
        // 顶部确认卡片（同 Shottr）。
        // 用户已经在做下一次取字（遮罩在场）时不打扰——内容仍在剪贴板与剪贴板绳里。
        guard overlay == nil else { return }
        resultPanel?.dismiss()
        let panel = OcrResultPanel(text: text, on: screen)
        resultPanel = panel
        panel.present()
    }

    private func guideToPermission() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "屏幕取字需要「屏幕录制」权限"
        alert.informativeText = """
        在 系统设置 → 隐私与安全性 → 屏幕录制 里勾选 ClipLine，然后重新启动本应用。

        若列表里已有 ClipLine 但仍报没权限：先选中它点减号移除，再重新添加（旧授权可能已失效）。
        """
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 调试：CLIPLINE_SELECTION_SNAPSHOT=<png> 展示取字遮罩的提示态，抓屏幕顶部一条后退出
    /// （普通在屏抓取，需要屏幕录制权限；App 自身已授）。
    static func snapshotHintIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["CLIPLINE_SELECTION_SNAPSHOT"] else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let screen = LinePanel.screenUnderPointer() ?? NSScreen.main else { NSApp.terminate(nil); return }
            let overlay = OverlayPanel(screen: screen)
            overlay.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
                let strip = CGRect(x: screen.frame.midX - 460,
                                   y: mainHeight - screen.frame.maxY + 10,
                                   width: 920, height: 150)
                if let image = CGWindowListCreateImage(strip, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]),
                   let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
        return true
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
        acceptsMouseMovedEvents = true
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
    private var cursorTracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        // 非激活窗口里 resetCursorRects 不生效（macOS 只给前台 App 应用光标 rect），
        // 系统随后会把光标打回原形。.activeAlways 的跟踪区是官方给"后台窗口也要管光标"
        // 的机制：每次光标更新都回调 cursorUpdate，我们在那里强制十字。
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
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
        // 还没开始拖框：给一句提示——不压暗屏幕，需要说明已进入取字模式（同 Shottr 的框选提示）。
        if start == nil {
            let hint = "拖框选住要识别的文字 · Esc 取消" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = hint.size(withAttributes: attrs)
            let pill = NSRect(x: (bounds.width - size.width) / 2 - 14, y: bounds.height - 72,
                              width: size.width + 28, height: size.height + 11)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            hint.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 5.5), withAttributes: attrs)
            return
        }
        // 拖框中：不遮暗屏幕（对齐 Shottr 的框选观感），只画选区框线——外深内白两圈，深浅底色都看得清。
        guard selection.width > 0, selection.height > 0 else { return }
        NSColor.black.withAlphaComponent(0.5).setStroke()
        let outer = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 3.5
        outer.stroke()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()

        // 尺寸提示贴在选区左上角外侧（像素数，同 Shottr 的 px 标注）。
        let pixelScale = window?.backingScaleFactor ?? 2
        let text = "\(Int(selection.width * pixelScale)) × \(Int(selection.height * pixelScale)) px" as NSString
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
