import AppKit
import ScreenCaptureKit

/// 屏幕取字（交互照 Shottr）：按热键的一刻把各块屏定格，遮罩铺上定格画面（不压暗），
/// 截图式准星框选；松手即裁定格画面跑本机 OCR，文字进剪贴板与历史，顶部弹确认卡。
///
/// 为什么先定格再框选：所见即所识别——框的是哪张画面就识别哪张，松手后不必再等抓屏；
/// 而且抓在激活本 App 之前，别的 App 的菜单、悬停浮层还在画面里。
final class ScreenTextCapture {
    /// 选区面积上限（像素），同 Shottr 的 "Area is too large" 保护。
    private static let maxAreaPixels = 40_000_000
    /// 系统授权请求（CGRequestScreenCaptureAccess 会弹系统窗）每次启动最多发一次：
    /// 权限失效期间用户连按热键时，不再反复弹系统授权窗。
    private static var requestedScreenCaptureOnce = false
    /// 识别超过这么久才先亮「正在识别」：小选区几十毫秒就出结果，直接给结果卡更干净。
    private static let workingCardDelay: TimeInterval = 0.12

    private let store: ClipStore
    private let pasteboard: NSPasteboard
    private var overlays: [SelectionOverlay] = []
    private var frozen: [CGImage] = []
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var resignObserver: Any?
    private var becomeObserver: Any?
    private var activatedThisSession = false
    /// 正在异步定格（SCK 抓屏）中：期间忽略热键重入，防止连按触发两轮定格。
    private var freezing = false
    private var card: OcrResultPanel?
    private var lastItem: ClipItem?
    private var lastText = ""
    /// 每次取字递增；迟到的识别结果对不上号就丢弃（用户已经开始下一次了）。
    private var generation = 0

    private var selecting: Bool { !overlays.isEmpty }

    init(store: ClipStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
    }

    /// 调试：CLIPLINE_DEBUG=1 时把取字流程的关键事件追加到 /tmp/clipline-ocr-debug.log。
    static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["CLIPLINE_DEBUG"] == "1" else { return }
        let url = URL(fileURLWithPath: "/tmp/clipline-ocr-debug.log")
        let line = String(format: "%.3f ", Date().timeIntervalSince1970) + message + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: 开始

    func begin() {
        // 取字/定格进行中再按热键 = 什么都不做（做成"再按=取消"会让连按两下的用户看到遮罩闪一下就没了）。
        guard !selecting, !freezing else {
            Self.debug("begin(): 正在框选或定格，忽略重复触发")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            if !Self.requestedScreenCaptureOnce {
                Self.requestedScreenCaptureOnce = true
                _ = CGRequestScreenCaptureAccess()
            }
            guideToPermission()
            return
        }
        // 上一张确认卡还在就先撤掉，否则会被定格进这次的画面。
        if let card, card.isVisible {
            card.dismiss(animated: false)
            self.card = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.freezeAndSelect() }
        } else {
            card = nil
            freezeAndSelect()
        }
    }

    private func freezeAndSelect() {
        guard !selecting else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.selecting else { return }
            self.freezing = true
            defer { self.freezing = false }
            let started = CACurrentMediaTime()
            let screens = NSScreen.screens
            guard let shots = await Self.freeze(screens) else {
                self.guideToPermission()
                return
            }
            let captured = CACurrentMediaTime()
            let front = NSWorkspace.shared.frontmostApplication
            self.previousApp = (front?.processIdentifier == getpid()) ? nil : front
            self.generation += 1
            self.frozen = shots
            self.overlays = zip(screens, shots).map { screen, image in
                let overlay = SelectionOverlay(screen: screen, backdrop: image)
                overlay.onFinish = { [weak self, weak overlay] rect in
                    guard let overlay else { return }
                    self?.finish(rect: rect, on: overlay)
                }
                overlay.onCancel = { [weak self] in self?.cancel(reason: "用户取消") }
                return overlay
            }
            let pointer = NSEvent.mouseLocation
            let home = self.overlays.first { NSMouseInRect(pointer, $0.targetScreen.frame, false) } ?? self.overlays.first
            for overlay in self.overlays where overlay !== home { overlay.orderFrontRegardless() }
            home?.makeKeyAndOrderFront(nil)
            // 截图工具通例（Shottr 也如此）：框选期间本 App 做前台，十字准星与 Esc 才稳；结束后把原 App 请回来。
            NSApp.activate()
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            self.overlays.forEach { $0.syncPointer() }
            self.installSessionMonitors()
            if NSApp.isActive { self.ensureCrosshair(generation: self.generation) }
            Self.debug(String(format: "begin(): 定格 %d 块屏（抓屏 %.0fms），热键→遮罩上屏 %.0fms；前台=%@ active=%@",
                              screens.count, (captured - started) * 1000, (CACurrentMediaTime() - started) * 1000,
                              self.previousApp?.localizedName ?? "本 App", NSApp.isActive ? "是" : "否"))
        }
    }

    /// 启动后预热一次抓屏通路：首次抓屏要多花几十毫秒做初始化，别让它落在第一次按热键上。
    /// 没有屏幕录制权限时什么都不做（不在启动时弹授权）。
    static func warmUp() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard CGPreflightScreenCaptureAccess() else { return }
            Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        }
    }

    /// 各屏依次抓一帧（显示器原生像素）。任何一块抓不到就视为没有屏幕录制权限。
    /// 走 ScreenCaptureKit 而不是旧的 CGDisplayCreateImage：新系统对旧采集通道的授权校验
    /// 更不稳定（已授权仍可能被反复弹授权窗），SCK 的授权一次即持久、也非废弃接口。
    private static func freeze(_ screens: [NSScreen]) async -> [CGImage]? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var shots: [CGImage] = []
            for screen in screens {
                guard let display = content.displays.first(where: { $0.displayID == displayID(screen) }) else {
                    return nil
                }
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.showsCursor = false
                config.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
                shots.append(image)
            }
            return shots
        } catch {
            debug("freeze(SCK) 失败：\(error)")
            return nil
        }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// 两帧的分块灰度平均绝对差，取第 90 百分位：大面积不同才算不同（时钟跳秒之类的小块差异不计）。
    /// 自检用它核对"遮罩上的定格画面与真实屏幕一致"。
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

    // MARK: 框选期间

    private func installSessionMonitors() {
        // 键盘统一在这里接：Esc 取消；拖动中按住空格挪动选区（同系统截图）。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.selecting else { return event }
            switch (event.type, event.keyCode) {
            case (.keyDown, 53):
                self.cancel(reason: "Esc")
                return nil
            case (_, 49):
                let moving = event.type == .keyDown
                self.overlays.filter(\.isDragging).forEach { $0.setMoving(moving) }
                return nil
            default:
                return event
            }
        }
        // 兜底：框选中用户把本 App 切走（⌘Tab 等）就收场，不留定格画面挡在屏上。
        // 只认"本次已经成为前台之后"的失去前台：激活过渡期里系统可能先补发一次 resign，
        // 照单全收就是遮罩一上屏就被撤掉（"闪一下就没了"）。
        activatedThisSession = NSApp.isActive
        becomeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self, self.selecting else { return }
            self.activatedThisSession = true
            Self.debug("session: 已成为前台")
            self.overlays.forEach { $0.syncPointer() }
            self.ensureCrosshair(generation: self.generation)
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self, self.selecting else { return }
            guard self.activatedThisSession else {
                Self.debug("session: 激活过渡期的 resign，忽略")
                return
            }
            self.cancel(reason: "App 被切走")
        }
    }

    /// 不动鼠标也要立刻是准星。激活后的几百毫秒里系统还会把光标重置回箭头（实测在 0.05～0.3 秒间出现一次），
    /// 所以前 1.5 秒以系统当前光标为准每 30ms 校验一次，被改回就再换；之后用户一动鼠标，光标矩形自然接管。
    private func ensureCrosshair(generation: Int, tick: Int = 0, wasCrosshair: Bool? = nil) {
        guard selecting, self.generation == generation, tick < 50 else { return }
        let crosshair = SelectionOverlay.crosshair
        let system = NSCursor.currentSystem
        let isCrosshair = system?.hotSpot == crosshair.hotSpot && system?.image.size == crosshair.image.size
        if isCrosshair != wasCrosshair { Self.debug("cursor: tick \(tick) 准星=\(isCrosshair)") }
        if !isCrosshair { SelectionOverlay.applyCursorNow(crosshair) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.ensureCrosshair(generation: generation, tick: tick + 1, wasCrosshair: isCrosshair)
        }
    }

    private func endSession() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for observer in [resignObserver, becomeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        resignObserver = nil
        becomeObserver = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        frozen = []
        // 准星不能留到下一次动鼠标：松手后用户常停着看确认卡，残留的十字像是还在框选。
        if NSApp.isActive { SelectionOverlay.applyCursorNow(.arrow) }
        restoreFocus()
    }

    private func cancel(reason: String) {
        guard selecting else { return }
        Self.debug("cancel: \(reason)")
        endSession()
    }

    /// 把取字前的前台 App 请回来（我们是主动让出前台，系统允许）。
    private func restoreFocus() {
        guard let app = previousApp else { return }
        previousApp = nil
        guard !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.selecting, NSApp.isActive, !app.isTerminated else { return }
            Self.debug("restoreFocus: 协作式交还被拒，改直接激活 \(app.localizedName ?? "?")")
            app.activate(options: [])
        }
    }

    // MARK: 识别

    private func finish(rect: NSRect, on overlay: SelectionOverlay) {
        guard let index = overlays.firstIndex(where: { $0 === overlay }) else { return }
        let image = frozen[index]
        let screen = overlay.targetScreen
        let pixel = SelectionGeometry.pixelRect(for: rect, viewSize: screen.frame.size,
                                                imageSize: CGSize(width: image.width, height: image.height))
        // 先收遮罩、还前台（手感利落）；识别全在定格画面上做，不再依赖屏幕此刻的样子。
        endSession()
        Self.debug("finish: rect=\(rect) pixel=\(pixel)")
        guard !pixel.isNull, pixel.width >= 4, pixel.height >= 4, let crop = image.cropping(to: pixel) else { return }
        guard Int(pixel.width * pixel.height) <= Self.maxAreaPixels else {
            present(.tooLarge, on: screen)
            return
        }
        let token = generation
        let started = CACurrentMediaTime()
        var done = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.workingCardDelay) { [weak self] in
            guard let self, !done, self.generation == token, !self.selecting else { return }
            self.present(.working, on: screen)
        }
        let scale = screen.backingScaleFactor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = Ocr.recognize(crop, minimumTextHeightPixels: 6 * scale)
            DispatchQueue.main.async {
                done = true
                guard let self, self.generation == token else { return }
                Self.debug(String(format: "ocr: %.0fms，%d 字", (CACurrentMediaTime() - started) * 1000, text?.count ?? 0))
                if let text, !text.isEmpty {
                    self.deliver(text, replacing: nil)
                    self.present(.copied(text), on: screen)
                } else {
                    self.present(.empty, on: screen)
                }
            }
        }
    }

    /// 文字进剪贴板 + 剪贴板绳历史（来源记为「屏幕取字」）。replacing：去换行时顶掉刚才那条，历史里只留最终版。
    private func deliver(_ text: String, replacing old: ClipItem?) {
        let item = ClipItem(kind: .text(text), source: .screenText, copiedAt: Date(),
                            snapshot: [[.string: Data(text.utf8)]], fingerprint: "t:" + text)
        if let snapshot = item.snapshot { Paster.copyToPasteboard(snapshot, to: pasteboard) }
        if let old { store.remove(old) }
        store.ingestScreenText(item)
        lastItem = item
        lastText = text
    }

    private func present(_ state: OcrResultPanel.State, on screen: NSScreen) {
        // 用户已经在框下一次了就不打扰——内容照样在剪贴板与剪贴板绳里。
        guard !selecting else { return }
        let panel: OcrResultPanel
        if let card, card.isVisible {
            panel = card
        } else {
            panel = OcrResultPanel(screen: screen)
            card = panel
        }
        panel.onCutBreaks = { [weak self, weak panel] in
            guard let self, let panel, case .copied = panel.state else { return }
            let joined = Ocr.joinLines(self.lastText)
            self.deliver(joined, replacing: self.lastItem)
            panel.show(.copiedWithoutBreaks(joined))
        }
        panel.show(state)
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

    // MARK: 自检接口（ScreenTextSelfTest 用）

    var debugOverlays: [SelectionOverlay] { overlays }
    var debugFrozen: [CGImage] { frozen }
    var debugCard: OcrResultPanel? { card }
    var debugPasteboard: NSPasteboard { pasteboard }
    static func debugDisplayID(_ screen: NSScreen) -> CGDirectDisplayID { displayID(screen) }
}
