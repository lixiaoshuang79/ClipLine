import AppKit

/// 屏幕取字的顶部确认卡——照 Shottr 的 OCR 吐司做：屏幕顶部居中一张浅色小卡（跟随系统明暗），
/// 左侧 App 图标，两行字（标题 + 识别文字预览），右侧灰色圆角「去换行」（= Shottr 的 Cut Breaks，
/// 仅当文本含换行时出现）。约 4 秒后自动淡出，指针停在卡上时暂停计时；点卡片本体即收起。
/// 不抢前台 App 的焦点。松手即亮「正在识别」，识别完原地换成结果。
final class OcrResultPanel: NSPanel {
    enum State: Equatable {
        case working
        case copied(String)
        case copiedWithoutBreaks(String)
        case empty
        case engineBusy
        case tooLarge
    }

    var onCutBreaks: (() -> Void)?
    private(set) var state: State = .working

    private let screenFrame: NSRect
    private let screenVisibleFrame: NSRect
    private let card = ToastBackground()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private lazy var breaksButton = PillButton(title: "去换行", target: self, action: #selector(cutBreaksTapped))
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    private var presented = false

    // 尺寸取自 Shottr 实机截图的量测（1512pt 宽屏上卡高 ≈54pt、图标 24pt、按钮高 28pt、卡顶距菜单栏 ≈22pt）。
    private static let height: CGFloat = 54
    private static let padding: CGFloat = 15
    private static let iconSide: CGFloat = 24
    private static let topGap: CGFloat = 22
    private static let maxTextWidth: CGFloat = 250

    init(screen: NSScreen) {
        screenFrame = screen.frame
        screenVisibleFrame = screen.visibleFrame
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        // 截断不用省略号（会被当成识别出来的字），改成尾部渐隐。
        detailLabel.lineBreakMode = .byClipping
        detailLabel.maximumNumberOfLines = 1
        detailLabel.wantsLayer = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [iconView, titleLabel, detailLabel, spinner, breaksButton] as [NSView] { card.addSubview(view) }
        card.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        card.onClick = { [weak self] in self?.dismiss() }
        contentView = card
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 进入某个状态：首次上屏带淡入下滑，之后原地更新、保持顶部居中。
    func show(_ next: State) {
        state = next
        switch next {
        case .working:
            setTexts("正在识别文字…", nil)
        case .copied(let text):
            setTexts("文字已复制到剪贴板", Self.preview(text))
        case .copiedWithoutBreaks(let text):
            setTexts("已复制去掉换行的文字", Self.preview(text))
        case .empty:
            setTexts("没有识别到文字", "换个区域再试一次")
        case .engineBusy:
            setTexts("识别引擎暂时不可用", "稍等片刻再试一次")
        case .tooLarge:
            setTexts("选区太大", "缩小一些再试")
        }
        if case .working = next { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if case .copied(let text) = next, text.contains("\n") {
            breaksButton.isHidden = false
        } else {
            breaksButton.isHidden = true
        }
        layoutCard()
        // 只淡入不动窗口框：窗口框动画会吞掉紧随其后的尺寸更新（识别中 → 已复制时卡片变宽）。
        if !presented {
            presented = true
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
        scheduleHide()
    }

    func dismiss(animated: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        guard isVisible else { return }
        guard animated else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }

    /// 预览行：换行压成空格、去首尾空白；卡片按单行截尾显示。
    static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(flat.prefix(200))
    }

    // MARK: 布局

    private func setTexts(_ title: String, _ detail: String?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
    }

    private func layoutCard() {
        let height = Self.height
        titleLabel.sizeToFit()
        detailLabel.sizeToFit()
        let titleWidth = ceil(titleLabel.frame.width)
        let detailWidth = detailLabel.isHidden ? 0 : ceil(detailLabel.frame.width)
        let textWidth = min(max(titleWidth, detailWidth), max(Self.maxTextWidth, titleWidth))
        let textX = Self.padding + Self.iconSide + 10

        var trailing: CGFloat = 0
        if !breaksButton.isHidden {
            breaksButton.sizeToFit()
            trailing = 24 + breaksButton.frame.width
        } else if case .working = state {
            trailing = 14 + 16
        }
        let width = max(220, ceil(textX + textWidth + trailing + Self.padding + 1))
        setContentSize(NSSize(width: width, height: height))
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)

        iconView.frame = NSRect(x: Self.padding, y: (height - Self.iconSide) / 2,
                                width: Self.iconSide, height: Self.iconSide)
        let titleHeight = ceil(titleLabel.frame.height)
        if detailLabel.isHidden {
            titleLabel.frame = NSRect(x: textX, y: (height - titleHeight) / 2, width: textWidth, height: titleHeight)
        } else {
            let detailHeight = ceil(detailLabel.frame.height)
            let block = titleHeight + detailHeight
            let bottom = (height - block) / 2
            detailLabel.frame = NSRect(x: textX, y: bottom, width: textWidth, height: detailHeight)
            titleLabel.frame = NSRect(x: textX, y: bottom + detailHeight, width: textWidth, height: titleHeight)
        }
        if detailWidth > textWidth {
            let fade = CAGradientLayer()
            fade.frame = NSRect(origin: .zero, size: detailLabel.frame.size)
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.locations = [0, NSNumber(value: Double(max(0, (textWidth - 36) / textWidth))), 1]
            detailLabel.layer?.mask = fade
        } else {
            detailLabel.layer?.mask = nil
        }
        if !breaksButton.isHidden {
            breaksButton.setFrameOrigin(NSPoint(x: width - Self.padding - breaksButton.frame.width,
                                                y: (height - breaksButton.frame.height) / 2))
        }
        spinner.frame = NSRect(x: width - Self.padding - 16, y: (height - 16) / 2, width: 16, height: 16)

        let top = min(screenVisibleFrame.maxY, screenFrame.maxY)
        let origin = NSPoint(x: (screenFrame.midX - width / 2).rounded(), y: top - Self.topGap - height)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        invalidateShadow()
    }

    // MARK: 自动收起

    private func scheduleHide() {
        hideWork?.cancel()
        hideWork = nil
        if case .working = state { return }
        guard !hovering else { return }
        let delay: TimeInterval
        switch state {
        case .empty, .tooLarge: delay = 2.5
        default: delay = 4
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        if inside {
            hideWork?.cancel()
            hideWork = nil
        } else {
            scheduleHide()
        }
    }

    @objc private func cutBreaksTapped() {
        onCutBreaks?()
    }

    // MARK: 调试

    /// 调试：CLIPLINE_OCR_RESULT_SNAPSHOT=<目录> 依次展示各状态、自捕获卡片窗口存 card-<状态>.png 后退出
    /// （抓自己的窗口不需要屏幕录制权限；配 CLIPLINE_APPEARANCE=dark 看深色）。
    static func snapshotDemoIfRequested() -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["CLIPLINE_OCR_RESULT_SNAPSHOT"] else { return false }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let states: [(String, State)] = [
            ("working", .working),
            ("copied", .copied(demoText)),
            ("cut-breaks", .copiedWithoutBreaks(Ocr.joinLines(demoText))),
            ("empty", .empty),
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { NSApp.terminate(nil); return }
            let panel = OcrResultPanel(screen: screen)
            func step(_ index: Int) {
                guard index < states.count else {
                    NSApp.terminate(nil)
                    return
                }
                panel.show(states[index].1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let windowID = CGWindowID(panel.windowNumber)
                    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.bestResolution]),
                       let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        let path = "\(directory)/card-\(states[index].0).png"
                        try? data.write(to: URL(fileURLWithPath: path))
                        FileHandle.standardError.write("ocr-card snapshot: \(path) frame=\(panel.frame)\n".data(using: .utf8)!)
                    }
                    step(index + 1)
                }
            }
            step(0)
        }
        return true
    }

    private static let demoText = """
    把最近复制过的内容挂在菜单栏下面的一条绳上：
    文本、链接、图片都在，卡片按来源 App 的色系染色。
    Everything stays local — no account, no network.
    """
}

/// 卡片底：跟随明暗的近乎不透明底色（浅色近白、深色近黑，同 Shottr 实测）+ 发丝边；负责悬停与单击。
/// 不用毛玻璃：它随背后内容漂移，深色网页上浅色卡会发灰发闷。
private final class ToastBackground: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 0.975, alpha: 0.97)).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1)).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// Shottr 式灰底圆角按钮：浅灰填充、次级文字色，悬停/按下加深。第一次点击直达（非激活面板）。
private final class PillButton: NSButton {
    private var hovering = false
    private var tracking: NSTrackingArea?

    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = .systemFont(ofSize: 13)
        focusRingType = .none
    }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)])
        return NSSize(width: ceil(text.width) + 28, height: 28)
    }

    override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let strength: CGFloat = isHighlighted ? 0.16 : (hovering ? 0.1 : 0.06)
        (dark ? NSColor.white.withAlphaComponent(strength + 0.04) : NSColor.black.withAlphaComponent(strength)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
