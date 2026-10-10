// ClipLine 的 App 图标：夜色底板上一根下垂的麻绳，三张染色吊牌被铝夹夹在绳上，
// 两侧那张被图标边缘裁掉——绳子在画框外继续延伸。
// 用法: swift scripts/make-icon.swift <输出.png>（1024×1024）
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                          space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// 之后一律用左上角原点、y 向下的坐标；阴影偏移不受 CTM 影响，向下要写负 y。
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// MARK: - 颜色

/// OKLCH → sRGB；超出色域时只降彩度。
func oklch(_ L: Double, _ C: Double, _ h: Double, _ a: CGFloat = 1) -> CGColor {
    func linear(_ c: Double) -> (Double, Double, Double) {
        let A = c * cos(h * .pi / 180), B = c * sin(h * .pi / 180)
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }
    func inGamut(_ v: (Double, Double, Double)) -> Bool {
        [v.0, v.1, v.2].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
    }
    var c = C
    if !inGamut(linear(c)) {
        var lo = 0.0, hi = c
        for _ in 0..<24 { let mid = (lo + hi) / 2; if inGamut(linear(mid)) { lo = mid } else { hi = mid } }
        c = lo
    }
    func encode(_ x: Double) -> CGFloat {
        let v = min(max(x, 0), 1)
        return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }
    let (r, g, b) = linear(c)
    return CGColor(colorSpace: srgb, components: [encode(r), encode(g), encode(b), a])!
}

func white(_ a: CGFloat) -> CGColor { CGColor(colorSpace: srgb, components: [1, 1, 1, a])! }
func black(_ a: CGFloat) -> CGColor { CGColor(colorSpace: srgb, components: [0, 0, 0, a])! }

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil,
                    from p0: CGPoint, to p1: CGPoint) {
    let g = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radialGradient(_ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [.drawsBeforeStartLocation])
}

func withState(_ body: () -> Void) {
    ctx.saveGState(); body(); ctx.restoreGState()
}

/// 整组内容作为一个剪影投影（阴影只算一次，内部元素不各自带影）。
func shadowed(_ offsetDown: CGFloat, _ blur: CGFloat, _ color: CGColor, _ body: () -> Void) {
    withState {
        ctx.setShadow(offset: CGSize(width: 0, height: -offsetDown), blur: blur, color: color)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
    }
}

// MARK: - 形状

/// 连续曲率圆角矩形（iOS/macOS 的 squircle 圆角，每个角由三段贝塞尔组成）。
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let rad = min(radius, min(r.width, r.height) / 2 / 1.52866483)
    // 一个角的控制点，以“离开角点的距离 / 半径”表示：(沿当前边, 沿下一条边)
    let seg: [[(CGFloat, CGFloat)]] = [
        [(1.08849296, 0), (0.86840694, 0), (0.66993427, 0.06549600)],
        [(0.37282392, 0.17360024), (0.17360024, 0.37282392), (0.06549600, 0.66993427)],
        [(0, 0.86840694), (0, 1.08849296), (0, 1.52866483)],
    ]
    // 顺时针（屏幕坐标）：右上、右下、左下、左上；u = 沿来路边回退方向，v = 沿去路边前进方向
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    func pt(_ c: (CGPoint, CGVector, CGVector), _ a: CGFloat, _ b: CGFloat) -> CGPoint {
        CGPoint(x: c.0.x + (c.1.dx * a + c.2.dx * b) * rad, y: c.0.y + (c.1.dy * a + c.2.dy * b) * rad)
    }
    let p = CGMutablePath()
    for (i, c) in corners.enumerated() {
        let start = pt(c, 1.52866483, 0)
        i == 0 ? p.move(to: start) : p.addLine(to: start)
        for s in seg {
            p.addCurve(to: pt(c, s[2].0, s[2].1), control1: pt(c, s[0].0, s[0].1), control2: pt(c, s[1].0, s[1].1))
        }
    }
    p.closeSubpath()
    return p
}

/// macOS 图标外形：824 见方的连续圆角方。
func squirclePath(_ r: CGRect) -> CGPath { rounded(r, r.width * 0.2237) }

func clipped(to path: CGPath, _ body: () -> Void) {
    withState { ctx.addPath(path); ctx.clip(); body() }
}

// MARK: - 场景参数

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileShape = squirclePath(tile)

let ropeEdgeY: CGFloat = 304   // 绳在图标左右边缘的高度
let ropeSag: CGFloat = 44      // 中点下垂量
func ropeY(_ x: CGFloat) -> CGFloat {
    let u = (x - S / 2) / (tile.width / 2)
    return ropeEdgeY + ropeSag * (1 - u * u)
}

let cardW: CGFloat = 300
let cardH: CGFloat = 364
let cuffH: CGFloat = 88
let cardRadius: CGFloat = 36
let cardGap: CGFloat = 46
let hue: Double = 282          // 底板色相：偏紫的靛蓝夜色

struct Tag {
    let x: CGFloat             // 衣夹所在 x
    let tilt: CGFloat          // 绕衣夹的摆角（度）
    let hue: Double
    let cuffTop: CGColor
    let cuffBottom: CGColor
    let lines: [CGFloat]       // 卡身文字行宽（占内容宽的比例），第一行是导语
}

let tags: [Tag] = [
    Tag(x: S / 2 - cardW - cardGap, tilt: 2.0, hue: 160,
        cuffTop: oklch(0.72, 0.14, 156), cuffBottom: oklch(0.60, 0.15, 162), lines: [0.8, 1, 0.9, 0.55]),
    Tag(x: S / 2 + cardW + cardGap, tilt: -2.2, hue: 88,
        cuffTop: oklch(0.90, 0.14, 94), cuffBottom: oklch(0.83, 0.16, 84), lines: [0.66, 1, 0.78, 0.92]),
    Tag(x: S / 2, tilt: -1.5, hue: 34,
        cuffTop: oklch(0.72, 0.15, 38), cuffBottom: oklch(0.61, 0.17, 30), lines: [0.74, 1, 0.88, 0.6]),
]

// MARK: - 底板

withState {
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: black(0.32))
    ctx.addPath(tileShape)
    ctx.setFillColor(oklch(0.30, 0.08, hue))
    ctx.fillPath()
}

ctx.saveGState()
ctx.addPath(tileShape)
ctx.clip()

linearGradient([oklch(0.44, 0.10, hue - 10), oklch(0.29, 0.09, hue + 4), oklch(0.19, 0.06, hue + 12)],
               [0, 0.55, 1], from: CGPoint(x: 0, y: tile.minY), to: CGPoint(x: 0, y: tile.maxY))
// 绳后的一层天光，让吊牌从底色里浮出来
withState {
    ctx.setBlendMode(.screen)
    radialGradient([oklch(0.66, 0.08, hue - 20, 0.32), oklch(0.40, 0.08, hue, 0)],
                   center: CGPoint(x: S / 2, y: 360), radius: 560)
}

// MARK: - 绳

func ropePath(from x0: CGFloat, to x1: CGFloat) -> CGPath {
    let p = CGMutablePath()
    var x = x0
    p.move(to: CGPoint(x: x, y: ropeY(x)))
    while x < x1 { x += 4; p.addLine(to: CGPoint(x: x, y: ropeY(x))) }
    return p
}

let rope = ropePath(from: tile.minX - 20, to: tile.maxX + 20)
let ropeWidth: CGFloat = 15

// 绳投在底板上的影子
withState {
    ctx.translateBy(x: 0, y: 16)
    ctx.addPath(rope)
    ctx.setLineWidth(ropeWidth)
    ctx.setShadow(offset: .zero, blur: 20, color: black(0.5))
    ctx.setStrokeColor(black(0.22))
    ctx.strokePath()
}

func drawRope() {
    withState {
        ctx.addPath(rope)
        ctx.setLineWidth(ropeWidth)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        // 圆柱明暗：上亮下暗
        let top = ropeEdgeY - 30, bottom = ropeEdgeY + ropeSag + 30
        ctx.setFillColor(oklch(0.93, 0.02, 80))
        ctx.fill(CGRect(x: 0, y: top, width: S, height: bottom - top))
        // 麻绳的捻纹
        ctx.setStrokeColor(oklch(0.62, 0.04, 70, 0.55))
        ctx.setLineWidth(3.2)
        var x = tile.minX - 20
        while x < tile.maxX + 20 {
            let y = ropeY(x)
            ctx.move(to: CGPoint(x: x - 7, y: y + ropeWidth / 2 + 1))
            ctx.addLine(to: CGPoint(x: x + 7, y: y - ropeWidth / 2 - 1))
            x += 11
        }
        ctx.strokePath()
        // 下缘阴影 + 上缘高光
        withState {
            ctx.translateBy(x: 0, y: ropeWidth * 0.42)
            ctx.addPath(rope)
            ctx.setLineWidth(ropeWidth * 0.5)
            ctx.setStrokeColor(oklch(0.35, 0.04, 60, 0.35))
            ctx.strokePath()
        }
        withState {
            ctx.translateBy(x: 0, y: -ropeWidth * 0.3)
            ctx.addPath(rope)
            ctx.setLineWidth(ropeWidth * 0.22)
            ctx.setStrokeColor(white(0.7))
            ctx.strokePath()
        }
    }
}

// MARK: - 吊牌

func drawTag(_ tag: Tag) {
    withTilt(tag) { _, cardTop in
        let card = CGRect(x: tag.x - cardW / 2, y: cardTop, width: cardW, height: cardH)
        let shape = rounded(card, cardRadius)

        // 投影：接触影 + 环境影
        shadowed(30, 60, black(0.38)) {
            shadowed(4, 6, black(0.25)) {
                ctx.addPath(shape)
                ctx.setFillColor(white(1))
                ctx.fillPath()
            }
        }

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()

        // 纸身：极淡的暖白
        linearGradient([oklch(0.995, 0.005, tag.hue), oklch(0.955, 0.014, tag.hue)],
                       from: CGPoint(x: 0, y: card.minY), to: CGPoint(x: 0, y: card.maxY))

        // 色头
        let cuff = CGRect(x: card.minX, y: card.minY, width: cardW, height: cuffH)
        clipped(to: CGPath(rect: cuff, transform: nil)) {
            linearGradient([tag.cuffTop, tag.cuffBottom],
                           from: CGPoint(x: 0, y: cuff.minY), to: CGPoint(x: 0, y: cuff.maxY))
        }
        ctx.setFillColor(white(0.45))
        ctx.fill(CGRect(x: card.minX, y: card.minY, width: cardW, height: 2.5))
        ctx.setFillColor(black(0.10))
        ctx.fill(CGRect(x: card.minX, y: cuff.maxY - 1.5, width: cardW, height: 1.5))

        drawBody(tag, in: CGRect(x: card.minX, y: cuff.maxY, width: cardW, height: cardH - cuffH))
        ctx.restoreGState()

        // 纸边：上亮下暗的细描边
        withState {
            ctx.addPath(rounded(card.insetBy(dx: 1, dy: 1), cardRadius - 1))
            ctx.setLineWidth(2)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            linearGradient([white(0.55), black(0.10)],
                           from: CGPoint(x: 0, y: card.minY), to: CGPoint(x: 0, y: card.maxY))
        }

    }
}

func withTilt(_ tag: Tag, _ body: (_ pinY: CGFloat, _ cardTop: CGFloat) -> Void) {
    let pinY = ropeY(tag.x)
    withState {
        ctx.translateBy(x: tag.x, y: pinY)
        ctx.rotate(by: tag.tilt * .pi / 180)
        ctx.translateBy(x: -tag.x, y: -pinY)
        body(pinY, pinY + 12)
    }
}

func drawBody(_ tag: Tag, in r: CGRect) {
    let pad: CGFloat = 38
    var y = r.minY + 48
    for (i, f) in tag.lines.enumerated() {
        let h: CGFloat = i == 0 ? 28 : 18
        ctx.setFillColor(i == 0 ? oklch(0.32, 0.035, tag.hue) : oklch(0.76, 0.025, tag.hue))
        ctx.addPath(rounded(CGRect(x: r.minX + pad, y: y, width: (r.width - pad * 2) * f, height: h), h / 2))
        ctx.fillPath()
        y += h + (i == 0 ? 30 : 22)
    }
}

// MARK: - 铝夹

func drawPeg(atX x: CGFloat, ropeY ry: CGFloat, cuffTop: CGFloat) {
    let w: CGFloat = 46
    let top = ry - 40
    let bottom = cuffTop + 58
    let peg = CGRect(x: x - w / 2, y: top, width: w, height: bottom - top)
    let shape = rounded(peg, 15)

    // 咬合阴影：落在色头上
    withState {
        ctx.setShadow(offset: .zero, blur: 10, color: black(0.45))
        ctx.addEllipse(in: CGRect(x: x - 30, y: bottom - 8, width: 60, height: 14))
        ctx.setFillColor(black(0.25))
        ctx.fillPath()
    }

    shadowed(10, 18, black(0.40)) {
        ctx.addPath(shape)
        ctx.setFillColor(white(1))
        ctx.fillPath()
    }
    withState {
        ctx.addPath(shape)
        ctx.clip()
        // 拉丝铝：横向圆柱明暗
        linearGradient([oklch(0.70, 0.01, 250), oklch(0.97, 0.005, 250), oklch(0.86, 0.008, 250),
                        oklch(0.62, 0.012, 250)], [0, 0.32, 0.62, 1],
                       from: CGPoint(x: peg.minX, y: 0), to: CGPoint(x: peg.maxX, y: 0))
        // 顶部高光、底部收暗
        linearGradient([white(0.5), white(0), black(0), black(0.18)], [0, 0.18, 0.7, 1],
                       from: CGPoint(x: 0, y: peg.minY), to: CGPoint(x: 0, y: peg.maxY))
        // 夹口：上下两片铝合拢处的一道折缝（绳就压在这里）
        ctx.setFillColor(oklch(0.38, 0.015, 250, 0.55))
        ctx.fill(CGRect(x: peg.minX, y: ry + 2, width: w, height: 3))
        ctx.setFillColor(white(0.75))
        ctx.fill(CGRect(x: peg.minX, y: ry + 5, width: w, height: 2))
    }
    withState {
        ctx.addPath(shape)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(oklch(0.40, 0.02, 250, 0.6))
        ctx.strokePath()
    }
}

// 吊牌 → 绳 → 铝夹（绳从夹子的槽里穿过）
for tag in tags { drawTag(tag) }
drawRope()
for tag in tags {
    withTilt(tag) { pinY, cardTop in drawPeg(atX: tag.x, ropeY: pinY, cuffTop: cardTop) }
}

ctx.restoreGState()

// 底板边缘：上沿一道细高光，下沿略收暗
withState {
    ctx.addPath(squirclePath(tile.insetBy(dx: 1.5, dy: 1.5)))
    ctx.setLineWidth(3)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linearGradient([white(0.28), white(0.04), black(0.25)], [0, 0.5, 1],
                   from: CGPoint(x: 0, y: tile.minY), to: CGPoint(x: 0, y: tile.maxY))
}

// MARK: - 输出

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("icon written: \(outPath)")
