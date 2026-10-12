import AppKit
import ScreenCaptureKit

/// 调试：CLIPLINE_OCR_RUN_DEBUG=script 无人值守走完一遍屏幕取字真实流程，逐状态截图存进输出目录：
/// 自开一扇测试文字窗 → begin()（与热键同一入口）→ 应用内合成鼠标事件框选（不动系统指针）→
/// 识别 → 确认卡 → 去换行 → 自动收起 → 再开一次，试空格挪选区、Esc 取消。
/// 剪贴板用私有板、历史用 CLIPLINE_STORE_DIR 指的临时库，不碰用户数据。结论写进 report.txt。
@MainActor
final class ScreenTextSelfTest {
    private let capture: ScreenTextCapture
    private let store: ClipStore
    private let directory: String
    private var report: [String] = []

    init(capture: ScreenTextCapture, store: ClipStore, directory: String) {
        self.capture = capture
        self.store = store
        self.directory = directory
    }

    func run() async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let screen = LinePanel.screenUnderPointer() ?? NSScreen.main else { return }
        await warmUpVision()
        // 等启动后的抓屏预热跑完，测到的 begin 耗时才接近常驻后台时按热键的真实情况。
        await sleep(2.2)

        let lines = ["ClipLine 屏幕取字示例", "把最近复制的内容挂在菜单栏下面的一条绳上。", "Everything stays local. No account, no network."]
        let fixture = makeFixture(lines, on: screen)
        let shotArea = fixture.frame.insetBy(dx: -90, dy: -70)
        let cardArea = NSRect(x: screen.frame.midX - 300, y: screen.visibleFrame.maxY - 110, width: 600, height: 110)
        let local = fixture.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let from = NSPoint(x: local.minX + 12, y: local.maxY - 12)
        let mid = NSPoint(x: local.midX, y: local.midY)
        let to = NSPoint(x: local.maxX - 12, y: local.minY + 12)
        await sleep(0.6)

        // 1. 开始：与按热键同一入口。
        note("前台（取字前）: \(frontName)")
        let started = CACurrentMediaTime()
        capture.begin()
        note(String(format: "begin() 同步耗时 %.0fms，遮罩 %d 扇", (CACurrentMediaTime() - started) * 1000,
                    capture.debugOverlays.count))
        guard let overlay = capture.debugOverlays.first(where: { $0.targetScreen == screen }) else {
            note("FAIL: 没有遮罩上屏")
            return finish()
        }
        await sleep(0.5)
        note("激活: isActive=\(NSApp.isActive) 遮罩是 key=\(overlay.isKeyWindow) 前台=\(frontName)")
        await checkCursor("0a-cursor-in-session", expectCrosshair: true)
        if let index = capture.debugOverlays.firstIndex(where: { $0 === overlay }),
           let composite = CGWindowListCreateImage(CGDisplayBounds(ScreenTextCapture.debugDisplayID(screen)),
                                                   .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) {
            note(String(format: "定格保真（屏上合成 vs 定格帧，P90 分块灰度差，0 = 一致）: %.2f",
                        ScreenTextCapture.blockDelta(composite, capture.debugFrozen[index])))
        }

        // 2. 准星读数 → 拖框。
        overlay.debugMove(to: from)
        shoot("1-idle", shotArea)
        overlay.debugMouse(.leftMouseDown, at: from)
        overlay.debugMouse(.leftMouseDragged, at: NSPoint(x: (from.x + mid.x) / 2, y: (from.y + mid.y) / 2))
        overlay.debugMouse(.leftMouseDragged, at: mid)
        await sleep(0.15)
        shoot("2-drag-mid", shotArea)
        overlay.debugMouse(.leftMouseDragged, at: to)
        await sleep(0.15)
        shoot("3-drag-full", shotArea)

        // 3. 松手 → 识别 → 确认卡。
        let released = CACurrentMediaTime()
        overlay.debugMouse(.leftMouseUp, at: to)
        note("松手后: 遮罩已收=\(capture.debugOverlays.isEmpty)")
        await sleep(0.05)
        await checkCursor("0b-cursor-after-release", expectCrosshair: false)
        await sleep(0.1)
        shoot("4a-card-early", cardArea)
        var card: OcrResultPanel?
        for _ in 0..<60 {
            card = capture.debugCard
            if let state = card?.state, state != .working { break }
            await sleep(0.1)
        }
        note(String(format: "松手→卡片出结果 %.0fms", (CACurrentMediaTime() - released) * 1000))
        await sleep(0.3)
        shoot("4b-card", cardArea)
        let copied = capture.debugPasteboard.string(forType: .string) ?? ""
        note("前台（交还后）: \(frontName)")
        note("卡片: \(String(describing: card?.state)) visible=\(card?.isVisible ?? false) frame=\(card?.frame ?? .zero)")
        note("剪贴板: \(copied.debugDescription)")
        let squash = { (text: String) in text.filter { !$0.isWhitespace } }
        let hits = lines.filter { squash(copied).contains(squash($0)) }.count
        note("识别整行命中 \(hits)/\(lines.count)")
        note("历史首条来源=屏幕取字: \(store.items.first?.source.kind == .screenText)，内容与剪贴板一致: \(store.items.first?.fingerprint == "t:" + copied)")

        // 4. 去换行。
        card?.onCutBreaks?()
        await sleep(0.5)
        shoot("5-cut-breaks", cardArea)
        note("去换行后: 卡片=\(String(describing: card?.state)) 剪贴板=\((capture.debugPasteboard.string(forType: .string) ?? "").debugDescription)")
        note("历史里屏幕取字条数（应为 1，去换行版顶掉原版）: \(store.items.filter { $0.source.kind == .screenText }.count)")

        // 5. 自动收起。
        let waitStart = CACurrentMediaTime()
        for _ in 0..<80 where card?.isVisible == true { await sleep(0.1) }
        note(String(format: "自动收起: %@（去换行后 %.1fs）", card?.isVisible == false ? "是" : "否",
                    CACurrentMediaTime() - waitStart + 0.5))

        // 6. 再开一次：空格挪选区 + Esc 取消（走真实的按键事件队列与本地监视器）。
        fixture.orderOut(nil)
        await sleep(0.3)
        capture.begin()
        await sleep(0.4)
        if let again = capture.debugOverlays.first(where: { $0.targetScreen == screen }) {
            again.debugMouse(.leftMouseDown, at: from)
            again.debugMouse(.leftMouseDragged, at: mid)
            let before = again.debugSelection
            post(keyCode: 49, characters: " ", down: true, to: again)
            await sleep(0.1)
            again.debugMouse(.leftMouseDragged, at: NSPoint(x: mid.x + 40, y: mid.y - 25))
            post(keyCode: 49, characters: " ", down: false, to: again)
            await sleep(0.1)
            let moved = again.debugSelection
            note("空格挪选区: 前 \(before) → 后 \(moved)（应整体平移 +40,-25、尺寸不变）")
            post(keyCode: 53, characters: "\u{1b}", down: true, to: again)
            await sleep(0.4)
            note("Esc 取消: 遮罩已收=\(capture.debugOverlays.isEmpty) 前台=\(frontName)")
        }
        note("DONE")
        finish()
    }

    // MARK: 工具

    private var frontName: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

    private func note(_ line: String) {
        report.append(line)
        ScreenTextCapture.debug("selftest: " + line)
        try? (report.joined(separator: "\n") + "\n").write(toFile: directory + "/report.txt", atomically: true, encoding: .utf8)
    }

    private func finish() {
        NSApp.terminate(nil)
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// 常驻的 App 早已预热过 Vision；自检刚启动，先预热，量到的才是日常耗时。
    private func warmUpVision() async {
        let image = NSImage(size: NSSize(width: 200, height: 60), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("预热 warm up" as NSString).draw(at: NSPoint(x: 10, y: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
            return true
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Ocr.recognize(cg)
                continuation.resume()
            }
        }
    }

    private func makeFixture(_ lines: [String], on screen: NSScreen) -> NSWindow {
        let size = NSSize(width: 520, height: 170)
        let frame = NSRect(x: (screen.frame.midX - size.width / 2).rounded(),
                           y: (screen.frame.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .white
        let label = NSTextField(labelWithString: lines.joined(separator: "\n"))
        label.font = .systemFont(ofSize: 22)
        label.textColor = .black
        label.frame = NSRect(x: 24, y: 24, width: size.width - 48, height: size.height - 48)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        return window
    }

    /// 抓屏上真实合成画面（含遮罩与卡片，不含光标）。
    private func shoot(_ name: String, _ rect: NSRect) {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgRect = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        if let image = CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) {
            write(image, name)
        }
    }

    private func write(_ image: CGImage, _ name: String) {
        if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
        }
    }

    /// 光标核验：AppKit 报告的系统光标 + 用 ScreenCaptureKit 带光标抓指针周围一小块（眼见为实）。
    private func checkCursor(_ name: String, expectCrosshair: Bool) async {
        let system = NSCursor.currentSystem
        let crosshair = SelectionOverlay.crosshair
        let isCrosshair = system?.hotSpot == crosshair.hotSpot && system?.image.size == crosshair.image.size
        note("[\(name)] 系统光标是准星: \(isCrosshair)（期望 \(expectCrosshair)）\(isCrosshair == expectCrosshair ? "OK" : "FAIL")")
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let id = ScreenTextCapture.debugDisplayID(screen)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return }
            let config = SCStreamConfiguration()
            config.showsCursor = true
            let side: CGFloat = 60
            let x = pointer.x - screen.frame.minX, y = screen.frame.maxY - pointer.y
            config.sourceRect = CGRect(x: max(0, x - side / 2), y: max(0, y - side / 2), width: side, height: side)
            config.width = Int(side * screen.backingScaleFactor)
            config.height = Int(side * screen.backingScaleFactor)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            write(image, name)
            note("[\(name)] 指针 \(pointer) 周围带光标截图已存")
        } catch {
            note("带光标截图失败: \(error)")
        }
    }

    /// 走真实事件队列（NSApp.postEvent → 本地监视器），与用户按键同路径。
    private func post(keyCode: UInt16, characters: String, down: Bool, to window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false,
                                           keyCode: keyCode) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}
