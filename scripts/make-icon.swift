// 画出 ClipLine 的 App 图标：深色圆角底 + 一条晾衣绳 + 衣夹 + 挂着的小卡片（色头呼应应用里的染色吊牌）。
// 用法: swift scripts/make-icon.swift <输出.png>（1024×1024）
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// ── 底板：macOS 风格的圆角方 ──────────────────────────────
let inset: CGFloat = 100
let box = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [rgb(0.16, 0.16, 0.20), rgb(0.08, 0.08, 0.11)])!.draw(in: box, angle: -90)
// 顶部微光
NSGradient(colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)])!
    .draw(in: NSRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 底板内描边
NSGraphicsContext.saveGraphicsState()
NSColor.white.withAlphaComponent(0.10).setStroke()
let innerEdge = NSBezierPath(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
innerEdge.lineWidth = 3
innerEdge.stroke()
NSGraphicsContext.restoreGraphicsState()

// ── 绳：微微下坠的一根细线 ────────────────────────────────
let ropeY: CGFloat = 700
let sag: CGFloat = 70
let rope = NSBezierPath()
rope.move(to: NSPoint(x: box.minX + 10, y: ropeY))
rope.curve(to: NSPoint(x: box.maxX - 10, y: ropeY),
           controlPoint1: NSPoint(x: 360, y: ropeY - sag),
           controlPoint2: NSPoint(x: 664, y: ropeY - sag))
NSGraphicsContext.saveGraphicsState()
let ropeShadow = NSShadow()
ropeShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
ropeShadow.shadowBlurRadius = 16
ropeShadow.shadowOffset = NSSize(width: 0, height: -8)
ropeShadow.set()
NSColor.white.withAlphaComponent(0.92).setStroke()
rope.lineWidth = 15
rope.lineCapStyle = .round
rope.stroke()
NSGraphicsContext.restoreGraphicsState()

// ── 卡片：白色吊牌，色头用珊瑚→紫的渐变（呼应演示数据）────
let cardW: CGFloat = 400
let cardH: CGFloat = 470
let cardTop: CGFloat = 596
let cardX = (size - cardW) / 2
let cardRect = NSRect(x: cardX, y: cardTop - cardH, width: cardW, height: cardH)
let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 48, yRadius: 48)

NSGraphicsContext.saveGraphicsState()
// 以卡片顶边中点为轴，轻轻旋转
let t = NSAffineTransform()
t.translateX(by: size / 2, yBy: cardTop)
t.rotate(byDegrees: -4)
t.translateX(by: -size / 2, yBy: -cardTop)
t.concat()

let cardShadow = NSShadow()
cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
cardShadow.shadowBlurRadius = 34
cardShadow.shadowOffset = NSSize(width: -6, height: -16)
cardShadow.set()

rgb(0.97, 0.975, 0.985).setFill()
cardPath.fill()

// 色头
NSGraphicsContext.saveGraphicsState()
cardPath.addClip()
NSGradient(colors: [rgb(0.99, 0.55, 0.36), rgb(0.55, 0.42, 0.94)])!
    .draw(in: NSRect(x: cardX, y: cardTop - 112, width: cardW, height: 112), angle: -35)
NSGraphicsContext.restoreGraphicsState()

// 卡身上的“文字行”
let lineColor = rgb(0.78, 0.80, 0.84)
let lines: [(CGFloat, CGFloat)] = [(300, 0), (300, 0), (236, 0), (268, 0)]
var lineY = cardTop - 112 - 62
for (width, _) in lines {
    let bar = NSBezierPath(roundedRect: NSRect(x: cardX + 50, y: lineY - 24, width: width, height: 24),
                           xRadius: 12, yRadius: 12)
    lineColor.setFill()
    bar.fill()
    lineY -= 58
}
NSGraphicsContext.restoreGraphicsState()

// ── 衣夹：夹在绳上，压住卡片顶边 ───────────────────────────
let pegW: CGFloat = 84
let pegH: CGFloat = 300
let pegX = size / 2 - pegW / 2
let pegRect = NSRect(x: pegX, y: ropeY - pegH + 118, width: pegW, height: pegH)
let pegPath = NSBezierPath(roundedRect: pegRect, xRadius: 34, yRadius: 34)

NSGraphicsContext.saveGraphicsState()
let pegShadow = NSShadow()
pegShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
pegShadow.shadowBlurRadius = 26
pegShadow.shadowOffset = NSSize(width: -4, height: -10)
pegShadow.set()
NSGradient(colors: [rgb(0.98, 0.98, 0.99), rgb(0.78, 0.80, 0.84), rgb(0.66, 0.68, 0.73)])!
    .draw(in: pegPath, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// 夹身描边
rgb(0.45, 0.47, 0.52, 0.8).setStroke()
pegPath.lineWidth = 3
pegPath.stroke()

// 绳穿过的槽
let slot = NSBezierPath(roundedRect: NSRect(x: pegRect.minX + 16, y: ropeY - 7, width: pegW - 32, height: 14),
                        xRadius: 7, yRadius: 7)
rgb(0.20, 0.21, 0.25, 0.85).setFill()
slot.fill()

// 夹子底部的高光棱线
let edge = NSBezierPath()
edge.move(to: NSPoint(x: pegRect.minX + 10, y: pegRect.minY + 46))
edge.line(to: NSPoint(x: pegRect.maxX - 10, y: pegRect.minY + 46))
rgb(1, 1, 1, 0.35).setStroke()
edge.lineWidth = 3
edge.stroke()

image.unlockFocus()

// 写 PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("icon written: \(outPath)")
