// 画 ClipLine 的 DMG 安装窗口背景：把图标拖进 Applications，以及被 macOS 拦截时的 引导。
// 用法: swift scripts/make-dmg-background.swift out.png [scale]
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "background.png"
let scale = CGFloat(Double(CommandLine.arguments.dropFirst(2).first ?? "1") ?? 1)
let W: CGFloat = 600, H: CGFloat = 380   // 与 Finder 窗口内容区（600×408 减去标题栏）一致，避免底部被裁

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 应用同款柔光底：浅紫→浅粉，Finder 标签在浅底上清晰可读。
NSGradient(colors: [color(233, 238, 255), color(243, 236, 252), color(255, 239, 236)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)

// 顶部一根细绳，呼应应用。
let rope = NSBezierPath()
rope.move(to: NSPoint(x: -10, y: H - 40))
rope.curve(to: NSPoint(x: W + 10, y: H - 40),
           controlPoint1: NSPoint(x: W * 0.3, y: H - 74),
           controlPoint2: NSPoint(x: W * 0.7, y: H - 74))
rope.lineWidth = 1.4
color(130, 134, 150, 0.65).setStroke()
rope.stroke()

// 两根小铝夹挂在绳上，正中偏两边。
for cx in [W * 0.5 - 120, W * 0.5 + 120] {
    let peg = NSBezierPath(roundedRect: NSRect(x: cx - 4, y: H - 62, width: 8, height: 22), xRadius: 3, yRadius: 3)
    color(214, 216, 222).setFill()
    peg.fill()
    color(150, 154, 162, 0.8).setStroke()
    peg.lineWidth = 0.6
    peg.stroke()
}

let centered = NSMutableParagraphStyle()
centered.alignment = .center

// 箭头：App → Applications（两个图标都放在 y=150 那一行）。
let arrowY: CGFloat = H - 150
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 250, y: arrowY))
arrow.line(to: NSPoint(x: 344, y: arrowY))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
color(110, 116, 140, 0.5).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 334, y: arrowY + 9))
head.line(to: NSPoint(x: 347, y: arrowY))
head.line(to: NSPoint(x: 334, y: arrowY - 9))
head.lineWidth = 2.5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// 主提示：拖进 Applications（放在图标标签下方）。
NSAttributedString(string: "把 ClipLine 拖进 Applications 完成安装", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: color(72, 76, 92),
    .paragraphStyle: centered,
]).draw(in: NSRect(x: 0, y: 110, width: W, height: 22))

// 引导块：首次打开被 macOS 拦下怎么办（macOS 15+ 的正路是系统设置里的「仍要打开」）。
let guide = NSBezierPath(roundedRect: NSRect(x: 60, y: 26, width: W - 120, height: 76), xRadius: 12, yRadius: 12)
color(255, 255, 255, 0.62).setFill()
guide.fill()
color(150, 152, 165, 0.35).setStroke()
guide.lineWidth = 1
guide.stroke()

NSAttributedString(string: "首次打开若提示「无法验证开发者 / 无法检查是否包含恶意软件」：", attributes: [
    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
    .foregroundColor: color(92, 96, 112),
    .paragraphStyle: centered,
]).draw(in: NSRect(x: 60, y: 78, width: W - 120, height: 18))

NSAttributedString(string: "打开 系统设置 › 隐私与安全性 › 在「安全性」一栏点「仍要打开」", attributes: [
    .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
    .foregroundColor: color(64, 88, 160),
    .paragraphStyle: centered,
]).draw(in: NSRect(x: 60, y: 58, width: W - 120, height: 18))

NSAttributedString(string: "Open System Settings › Privacy & Security › \"Open Anyway\"", attributes: [
    .font: NSFont.systemFont(ofSize: 10.5),
    .foregroundColor: color(130, 134, 150),
    .paragraphStyle: centered,
]).draw(in: NSRect(x: 60, y: 37, width: W - 120, height: 16))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
