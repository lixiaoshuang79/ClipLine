import AppKit
import QuartzCore

/// 开发用验证探针（CLIPLINE_OCR_PROBE=1）：
/// 造一个「流式文字渐入」的模拟窗口（透明度 0.25→1.0 渐入 + 静止，CA 动画由渲染服务驱动，
/// 主线程阻塞也不会停），分别用单帧抓取和稳定帧机制（captureStable）取图跑 OCR，验证：
/// ① 渐入中间帧确实是 Vision 大面积误识的来源；② 分块比对能识出"在动"；③ 稳定帧能拿到干净结果。
/// 报告与图片落到 /tmp/clipline-ocr-probe/。
enum OcrProbe {
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["CLIPLINE_OCR_PROBE"] == "1" else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Task { await run() } }
        return true
    }

    private static let dir = URL(fileURLWithPath: "/tmp/clipline-ocr-probe", isDirectory: true)
    private static var lines: [String] = []

    private static func note(_ s: String) {
        lines.append(s)
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    /// 与被抓出误识的素材同款句子（生成→牛成、温柔→泪柔、立刻→方刻 的对照真值）。
    private static let truth = """
    生成「ClipLine Dev」自签名证书导入登录钥匙串（私钥只存在钥匙串里）
    你能感受到别人没有说出口的情绪，这是一份珍贵的敏锐。
    你不必负责让每一片阴云立刻散开，温柔地问一句，然后陪在旁边，就已经足够。
    """

    /// 渐入周期：1.0s 从 0.25 升到 1.0，再静止 0.6s；CA 关键帧驱动渲染服务。
    private static let period: Double = 1.6
    private static let fadeEnd: Double = 1.0
    private static var t0 = Date()

    private static func phase() -> Double {
        Date().timeIntervalSince(t0).truncatingRemainder(dividingBy: period)
    }

    private static func waitPhase(_ lo: Double, _ hi: Double) async {
        // 必须 await（Task.sleep），不能 usleep 阻塞主线程——否则 AppKit 没机会把窗口刷上屏。
        while !(phase() >= lo && phase() <= hi) {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    @MainActor
    private static func run() async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let frame = screen.frame
        let size = NSSize(width: 780, height: 112)
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY + 140)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.level = .floating
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        let text = NSTextField(wrappingLabelWithString: truth)
        text.font = .systemFont(ofSize: 13)
        text.textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        text.frame = NSRect(x: 18, y: 14, width: size.width - 36, height: size.height - 28)
        container.addSubview(text)
        panel.contentView = container
        panel.orderFrontRegardless()

        t0 = Date()
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.25, 1.0, 1.0]
        anim.keyTimes = [0, NSNumber(value: fadeEnd / period), 1]
        anim.duration = period
        anim.repeatCount = .infinity
        container.layer?.add(anim, forKey: "fade")

        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let cgRect = CGRect(x: origin.x, y: mainHeight - (origin.y + size.height),
                            width: size.width, height: size.height)
        let minHeight = 6 * screen.backingScaleFactor
        note("scale=\(screen.backingScaleFactor) cgRect=\(cgRect)")

        // 1) 渐入中：单帧抓取（复刻现状路径的行为）
        await waitPhase(0.10, 0.30)
        if let a = grab(cgRect) {
            let opacity = (container.layer?.presentation()?.opacity).map { String(format: "%.2f", $0) } ?? "?"
            saveAndOcr(a, name: "mid-1", tag: "MID#1 phase=\(String(format: "%.2f", phase()))) opacity=\(opacity)", minHeight: minHeight)
        }
        await waitPhase(0.40, 0.65)
        if let c = grab(cgRect) {
            let opacity = (container.layer?.presentation()?.opacity).map { String(format: "%.2f", $0) } ?? "?"
            saveAndOcr(c, name: "mid-2", tag: "MID#2 phase=\(String(format: "%.2f", phase()))) opacity=\(opacity)", minHeight: minHeight)
        }

        // 2) 分块比对：渐入中对（应当判"在动"），静止段对（应当判"稳定"）
        await waitPhase(0.70, 0.90)
        if let a = grab(cgRect) {
            usleep(180_000)
            if let b = grab(cgRect) {
                note("fade pair delta=\(String(format: "%.2f", ScreenTextCapture.blockDelta(a, b))) (期望 > 1)")
            }
        }
        await waitPhase(1.10, 1.45)
        if let a = grab(cgRect) {
            usleep(180_000)
            if let b = grab(cgRect) {
                note("static pair delta=\(String(format: "%.2f", ScreenTextCapture.blockDelta(a, b))) (期望 ≈ 0)")
            }
        }

        // 3) 稳定帧机制（从渐入段开始，应当自己等到静止）
        await waitPhase(0.30, 0.50)
        if let stable = ScreenTextCapture.captureStable(cgRect: cgRect) {
            saveAndOcr(stable, name: "stable", tag: "STABLE(从 phase≈0.4 开始)", minHeight: minHeight)
        } else {
            note("STABLE: captureStable 返回 nil")
        }

        // 4) 静止段单帧（真值参照）
        await waitPhase(1.10, 1.45)
        if let d = grab(cgRect) {
            saveAndOcr(d, name: "reference", tag: "REFERENCE(静止段单帧)", minHeight: minHeight)
        }

        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"),
                                                 atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func grab(_ cgRect: CGRect) -> CGImage? {
        CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }

    @MainActor
    private static func saveAndOcr(_ image: CGImage, name: String, tag: String, minHeight: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
        let text = Ocr.recognize(image, minimumTextHeightPixels: minHeight) ?? "<no text>"
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        note("\(tag) \(name): \(image.width)x\(image.height) ocr: \(flat.prefix(130))")
    }
}
