import AppKit

/// 选区几何：纯函数，便于单测。坐标均为遮罩视图坐标（点，左下原点）。
enum SelectionGeometry {
    /// 两点张成的矩形，钳在 bounds 内、对齐到设备像素。
    static func rect(from a: NSPoint, to b: NSPoint, within bounds: NSRect, scale: CGFloat) -> NSRect {
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let minX = snap(max(bounds.minX, min(a.x, b.x)))
        let maxX = snap(min(bounds.maxX, max(a.x, b.x)))
        let minY = snap(max(bounds.minY, min(a.y, b.y)))
        let maxY = snap(min(bounds.maxY, max(a.y, b.y)))
        return NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// 选区（视图点坐标）→ 定格画面里的像素矩形（左上原点），越界部分裁掉。
    static func pixelRect(for selection: NSRect, viewSize: NSSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .null }
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        let rect = CGRect(x: selection.minX * sx, y: (viewSize.height - selection.maxY) * sy,
                          width: selection.width * sx, height: selection.height * sy).integral
        return rect.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// 准星旁读数的左下角：默认贴在准星右下；靠近右/下边缘时翻到另一侧，始终留在屏内。
    static func readoutOrigin(pointer: NSPoint, size: NSSize, bounds: NSRect) -> NSPoint {
        let gap: CGFloat = 10
        var x = pointer.x + gap
        var y = pointer.y - gap - size.height
        if x + size.width > bounds.maxX - 2 { x = pointer.x - gap - size.width }
        if y < bounds.minY + 2 { y = pointer.y + gap }
        return NSPoint(x: max(bounds.minX + 2, x), y: min(bounds.maxY - size.height - 2, y))
    }
}

/// 取字遮罩：一块屏一扇窗，铺满按热键那一刻的定格画面（不压暗）。
/// 交互同 Shottr / 系统截图：截图式准星 + 坐标读数，拖框出半透明灰选区，读数换成宽高；
/// 拖动中按住空格可整体挪动选区；松手即完成，单击、右键、Esc 取消。
final class SelectionOverlay: NSWindow {
    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    let targetScreen: NSScreen
    private let canvas: OverlayCanvas

    init(screen: NSScreen, backdrop: CGImage) {
        targetScreen = screen
        canvas = OverlayCanvas(frame: NSRect(origin: .zero, size: screen.frame.size),
                               scale: screen.backingScaleFactor)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        canvas.setBackdrop(backdrop)
        canvas.onFinish = { [weak self] rect in self?.onFinish?(rect) }
        canvas.onCancel = { [weak self] in self?.onCancel?() }
        contentView = canvas
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 上屏后按当前指针位置摆好读数（还没动鼠标时也要有）。
    func syncPointer() {
        canvas.pointerMoved(to: mouseLocationOutsideOfEventStream)
        invalidateCursorRects(for: canvas)
    }

    /// 空格：拖动中按住 = 挪动选区（同系统截图）。
    func setMoving(_ moving: Bool) { canvas.moving = moving }
    var isDragging: Bool { canvas.isDragging }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // MARK: 调试（自检脚本用：在应用内投递合成鼠标事件，不碰系统指针）

    func debugMove(to point: NSPoint) { canvas.pointerMoved(to: point) }
    var debugSelection: NSRect { canvas.debugSelection }

    func debugMouse(_ type: NSEvent.EventType, at point: NSPoint) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        sendEvent(event)
    }

    /// 立刻换光标。光 set() 不够：窗口服务器要等鼠标真动一下才把光标交给新的前台 App，
    /// 不动鼠标就一直是原 App 的箭头（"按了热键光标不变"）。原地定位一次指针即可立刻生效；
    /// 再恢复鼠标与指针的关联，免得定位后鼠标被冻住 0.25 秒。
    static func applyCursorNow(_ cursor: NSCursor) {
        cursor.set()
        guard let location = CGEvent(source: nil)?.location else { return }
        CGWarpMouseCursorPosition(location)
        CGAssociateMouseAndMouseCursorPosition(1)
        cursor.set()
    }

    /// 截图式准星（仿系统 ⌘⇧4 / Shottr）：白边黑线十字 + 中心半透明灰圈，深浅底上都看得清。
    static let crosshair: NSCursor = {
        let side: CGFloat = 27
        let c = side / 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: c, y: 1.5))
            cross.line(to: NSPoint(x: c, y: side - 1.5))
            cross.move(to: NSPoint(x: 1.5, y: c))
            cross.line(to: NSPoint(x: side - 1.5, y: c))
            cross.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.92).setStroke()
            cross.lineWidth = 3
            cross.stroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: c - 5.5, y: c - 5.5, width: 11, height: 11))
            NSColor(white: 0.55, alpha: 0.4).setFill()
            ring.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 1
            ring.stroke()
            NSColor.black.withAlphaComponent(0.9).setStroke()
            cross.lineWidth = 1
            cross.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: c, y: c))
    }()
}

/// 遮罩画布：全部用图层合成（定格画面一层、选区一层、读数一层），拖动时只改小图层，不重绘整屏。
private final class OverlayCanvas: NSView {
    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    var moving = false

    private let scale: CGFloat
    private let backdrop = CALayer()
    private let fill = CAShapeLayer()
    private let outerEdge = CAShapeLayer()
    private let innerEdge = CAShapeLayer()
    private let readout = CALayer()
    private var anchor: NSPoint?
    private var current: NSPoint = .zero
    private var selection: NSRect = .zero
    private var tracking: NSTrackingArea?

    var isDragging: Bool { anchor != nil }
    var debugSelection: NSRect { selection }

    init(frame: NSRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let quiet: [String: CAAction] = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                         "path": NSNull(), "hidden": NSNull(), "frame": NSNull()]
        backdrop.frame = bounds
        backdrop.contentsGravity = .resize
        backdrop.magnificationFilter = .nearest
        backdrop.actions = quiet
        // 选区：50% 灰的薄填充（白底上显灰、黑底上显亮）+ 外黑内白两道发丝线。
        fill.fillColor = NSColor(white: 0.5, alpha: 0.24).cgColor
        outerEdge.fillColor = nil
        outerEdge.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        outerEdge.lineWidth = 1
        innerEdge.fillColor = nil
        innerEdge.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        innerEdge.lineWidth = 1
        for shape in [fill, outerEdge, innerEdge] {
            shape.contentsScale = scale
            shape.actions = quiet
            shape.isHidden = true
        }
        readout.actions = quiet
        readout.contentsScale = scale
        readout.isHidden = true
        for sub in [backdrop, fill, outerEdge, innerEdge, readout] { layer?.addSublayer(sub) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setBackdrop(_ image: CGImage) { backdrop.contents = image }

    // MARK: 光标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: SelectionOverlay.crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        SelectionOverlay.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) {
        // 多屏：指针移到哪块屏，哪块屏的遮罩接管键盘（Esc / 空格）。
        if window?.isKeyWindow == false { window?.makeKey() }
        SelectionOverlay.crosshair.set()
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard anchor == nil else { return }
        readout.isHidden = true
    }

    override func mouseMoved(with event: NSEvent) {
        SelectionOverlay.crosshair.set()
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    func pointerMoved(to point: NSPoint) {
        current = point
        guard anchor == nil else { return }
        guard bounds.contains(point) else {
            readout.isHidden = true
            return
        }
        // 读数按屏幕左上原点、单位点（同系统截图）。
        showReadout(["\(Int(point.x.rounded(.down)))", "\(Int((bounds.height - point.y).rounded(.down)))"], at: point)
    }

    // MARK: 框选

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        anchor = point
        current = point
        selection = .zero
        moving = false
        ScreenTextCapture.debug("selection mouseDown \(point)")
    }

    override func mouseDragged(with event: NSEvent) {
        guard var start = anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        if moving {
            start.x += point.x - current.x
            start.y += point.y - current.y
            anchor = start
        }
        current = point
        selection = SelectionGeometry.rect(from: start, to: point, within: bounds, scale: scale)
        renderSelection()
        showReadout(["\(Int(selection.width.rounded()))", "\(Int(selection.height.rounded()))"], at: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        anchor = nil
        moving = false
        let rect = selection
        ScreenTextCapture.debug("selection mouseUp rect=\(rect)")
        // 单击（几乎没拖）= 取消，同系统截图的"点一下就退出"。
        if rect.width * scale < 4 || rect.height * scale < 4 {
            onCancel?()
        } else {
            onFinish?(rect)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    private func renderSelection() {
        let visible = selection.width > 0 && selection.height > 0
        fill.path = CGPath(rect: selection, transform: nil)
        outerEdge.path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        innerEdge.path = CGPath(rect: selection.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        for shape in [fill, outerEdge, innerEdge] { shape.isHidden = !visible }
    }

    // MARK: 读数

    private static let readoutFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    /// 两行数字，深色字 + 白色描边光晕（同系统截图的读数），任何底色上都清楚。
    private func showReadout(_ lines: [String], at point: NSPoint) {
        let text = lines.joined(separator: "\n") as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = -1
        let base: [NSAttributedString.Key: Any] = [.font: Self.readoutFont, .paragraphStyle: paragraph]
        let textSize = text.boundingRect(with: NSSize(width: 200, height: 100),
                                         options: [.usesLineFragmentOrigin], attributes: base).size
        let size = NSSize(width: ceil(textSize.width) + 6, height: ceil(textSize.height) + 4)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 3, y: 2, width: textSize.width + 1, height: textSize.height)
        var halo = base
        halo[.strokeColor] = NSColor.white.withAlphaComponent(0.95)
        halo[.strokeWidth] = 28   // 正值 = 只描边；单位是字号的百分比
        text.draw(with: rect, options: [.usesLineFragmentOrigin], attributes: halo)
        var ink = base
        ink[.foregroundColor] = NSColor(white: 0.08, alpha: 1)
        text.draw(with: rect, options: [.usesLineFragmentOrigin], attributes: ink)
        NSGraphicsContext.restoreGraphicsState()
        let origin = SelectionGeometry.readoutOrigin(pointer: point, size: size, bounds: bounds)
        readout.contents = rep.cgImage
        readout.frame = NSRect(origin: NSPoint(x: (origin.x * scale).rounded() / scale,
                                               y: (origin.y * scale).rounded() / scale), size: size)
        readout.isHidden = false
    }
}
