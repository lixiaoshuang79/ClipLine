import SwiftUI

/// OKLCH：OKLab（Björn Ottosson）的极坐标形式。转颜色时超出 sRGB 色域只降彩度，不动明度和色相。
struct OKLCH: Hashable {
    var l: Double, c: Double, h: Double

    init(_ l: Double, _ c: Double, _ h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    /// 线性 sRGB → OKLab → OKLCH。
    init(linearRed r: Double, green g: Double, blue b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let hue = atan2(B, A) * 180 / .pi
        self.init(L, hypot(A, B), hue < 0 ? hue + 360 : hue)
    }

    init(hex: UInt32) {
        let s = Swatch(hex: hex)
        self.init(linearRed: s.r, green: s.g, blue: s.b)
    }

    func color(_ opacity: Double = 1) -> Color { swatch(opacity).color }

    func swatch(_ opacity: Double = 1) -> Swatch {
        var chroma = max(c, 0)
        if !Self.inGamut(Self.linear(l, chroma, h)) {
            var lo = 0.0, hi = chroma
            for _ in 0..<20 {
                let mid = (lo + hi) / 2
                if Self.inGamut(Self.linear(l, mid, h)) { lo = mid } else { hi = mid }
            }
            chroma = lo
        }
        let (r, g, b) = Self.linear(l, chroma, h)
        return Swatch(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1), a: opacity)
    }

    private static func linear(_ L: Double, _ C: Double, _ h: Double) -> (Double, Double, Double) {
        let a = C * cos(h * .pi / 180), b = C * sin(h * .pi / 180)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return ( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    private static func inGamut(_ v: (Double, Double, Double)) -> Bool {
        [v.0, v.1, v.2].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
    }
}

/// 线性 sRGB + 不透明度：既能转成 `Color`，也能算 WCAG 对比度。
struct Swatch: Hashable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(hex: UInt32, a: Double = 1) {
        self.init(r: Self.decode(Double((hex >> 16) & 0xFF) / 255),
                  g: Self.decode(Double((hex >> 8) & 0xFF) / 255),
                  b: Self.decode(Double(hex & 0xFF) / 255), a: a)
    }

    static let white = Swatch(r: 1, g: 1, b: 1)

    var color: Color { Color(.sRGBLinear, red: r, green: g, blue: b, opacity: a) }

    func opacity(_ value: Double) -> Swatch { Swatch(r: r, g: g, b: b, a: value) }

    /// 相对亮度（WCAG）。
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// 叠到不透明底色上；在 gamma 编码空间混合，与窗口合成一致。
    func over(_ base: Swatch) -> Swatch {
        func mix(_ f: Double, _ b: Double) -> Double {
            Self.decode(Self.encode(f) * a + Self.encode(b) * (1 - a))
        }
        return Swatch(r: mix(r, base.r), g: mix(g, base.g), b: mix(b, base.b))
    }

    static func contrast(_ foreground: Swatch, on background: Swatch) -> Double {
        let f = foreground.over(background).luminance, b = background.luminance
        return (max(f, b) + 0.05) / (min(f, b) + 0.05)
    }

    static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func encode(_ v: Double) -> Double {
        let v = min(max(v, 0), 1)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}

/// 一张卡的全部色板 token（数值形式，单元测试直接检查它）。
struct PaletteTones {
    var cuffTop: Swatch?            // nil = 未染色：色头露出卡身
    var cuffBottom: Swatch?
    var secondary: Swatch?          // 次色相过渡的右端色
    var cuffInk: Swatch
    var cuffInkShadow: Bool
    var bodyTop: Swatch
    var bodyBottom: Swatch
    var ink: Swatch
    var ink2: Swatch
    var ink3: Swatch
    var rim: Swatch
    var glow: Swatch?               // nil = 只用中性阴影
    var ring: Swatch?               // nil = 系统强调色
    var codeBase: Swatch
    var codeText: Swatch
    var codeGutter: Swatch
}

struct CardPalette {
    let cuff: (top: Color, bottom: Color)?
    let secondary: Color?
    let cuffInk: Color
    let cuffInkShadow: Bool
    let bodyTop: Color
    let bodyBottom: Color
    let ink: Color
    let ink2: Color
    let ink3: Color
    let rim: Color
    let glow: Color?
    let ring: Color
    let codeBase: Color
    let codeText: Color
    let codeGutter: Color

    init(_ t: PaletteTones) {
        if let top = t.cuffTop, let bottom = t.cuffBottom { cuff = (top.color, bottom.color) } else { cuff = nil }
        secondary = t.secondary?.color
        cuffInk = t.cuffInk.color
        cuffInkShadow = t.cuffInkShadow
        bodyTop = t.bodyTop.color
        bodyBottom = t.bodyBottom.color
        ink = t.ink.color
        ink2 = t.ink2.color
        ink3 = t.ink3.color
        rim = t.rim.color
        glow = t.glow?.color
        ring = t.ring?.color ?? .accentColor
        codeBase = t.codeBase.color
        codeText = t.codeText.color
        codeGutter = t.codeGutter.color
    }

    /// 搜索命中的荧光笔底色：沿用本卡的 ring 色相，像在吊牌上划了一道记号笔。
    func mark(_ scheme: ColorScheme) -> Color {
        ring.opacity(scheme == .dark ? 0.42 : 0.32)
    }

    private struct Key: Hashable {
        let tint: SourceTint
        let dark: Bool
    }

    private static var cache: [Key: CardPalette] = [:]

    static func of(_ source: ClipSource, scheme: ColorScheme) -> CardPalette {
        let key = Key(tint: SourceTint.of(source), dark: scheme == .dark)
        if let hit = cache[key] { return hit }
        let palette = CardPalette(key.tint.tones(for: scheme))
        cache[key] = palette
        return palette
    }
}

extension SourceTint {
    func tones(for scheme: ColorScheme) -> PaletteTones {
        let dark = scheme == .dark
        switch style {
        case .chromatic, .yellow: return chromaticTones(dark: dark)
        case .graphite: return neutralTones(dark: dark, dyed: true)
        case .unknown: return neutralTones(dark: dark, dyed: false)
        }
    }

    private func chromaticTones(dark: Bool) -> PaletteTones {
        var top: OKLCH, bottom: OKLCH
        let cuffInk: Swatch
        if style == .yellow {
            top = OKLCH(dark ? 0.82 : 0.90, min(c, 0.14), h - 4)
            bottom = OKLCH(dark ? 0.74 : 0.83, min(c, 0.16), h + 4)
            cuffInk = OKLCH(dark ? 0.24 : 0.30, dark ? 0.06 : 0.07, h).swatch()
        } else {
            top = dark ? OKLCH(0.58, 0.95 * c, h - 6) : OKLCH(0.66, c, h - 6)
            bottom = dark ? OKLCH(0.47, 0.95 * c, h + 6) : OKLCH(0.55, 1.05 * c, h + 6)
            cuffInk = Swatch.white.opacity(0.96)
        }
        // §3.5：色头文字对比度不达标时，每次把色头明度推 0.02（白字压暗、深字提亮）直到通过。
        let step = style == .yellow ? 0.02 : -0.02
        for _ in 0..<40 {
            if Swatch.contrast(cuffInk, on: bottom.swatch()) >= 4.5,
               Swatch.contrast(cuffInk, on: top.swatch()) >= 3.0 { break }
            top.l = min(max(top.l + step, 0), 1)
            bottom.l = min(max(bottom.l + step, 0), 1)
        }

        let bodyTop = OKLCH(dark ? 0.28 : 0.99, dark ? 0.022 : 0.008, h).swatch()
        let bodyBottom = OKLCH(dark ? 0.23 : 0.96, dark ? 0.030 : 0.025, h).swatch()
        return PaletteTones(
            cuffTop: top.swatch(),
            cuffBottom: bottom.swatch(),
            secondary: h2.map { OKLCH((top.l + bottom.l) / 2, c, $0).swatch() },
            cuffInk: cuffInk,
            cuffInkShadow: style != .yellow,
            bodyTop: bodyTop,
            bodyBottom: bodyBottom,
            ink: OKLCH(dark ? 0.96 : 0.25, dark ? 0.010 : min(c, 0.035), h).swatch(),
            ink2: OKLCH(dark ? 0.80 : 0.45, dark ? 0.020 : 0.035, h).swatch(),
            ink3: OKLCH(dark ? 0.64 : 0.58, dark ? 0.020 : 0.030, h).swatch(),
            rim: OKLCH(dark ? 0.80 : 0.55, c, h).swatch(dark ? 0.18 : 0.22),
            glow: OKLCH(dark ? 0.70 : 0.68, c, h).swatch(),
            ring: dark ? OKLCH(0.74, c, h).swatch() : OKLCH(0.62, 1.1 * c, h).swatch(),
            codeBase: OKLCH(dark ? 0.16 : 0.22, dark ? 0.012 : 0.015, h).swatch(),
            codeText: OKLCH(0.92, 0.01, h).swatch(),
            codeGutter: OKLCH(0.60, 0.01, h).swatch())
    }

    /// 石墨（已知来源、图标是中性色）与未染色（来源未知）共用的中性色板。
    private func neutralTones(dark: Bool, dyed: Bool) -> PaletteTones {
        let h = 260.0, c = 0.006
        let ink2 = OKLCH(dark ? 0.80 : 0.45, c, h).swatch()
        return PaletteTones(
            cuffTop: dyed ? Swatch(hex: dark ? 0x56595E : 0x66696E) : nil,
            cuffBottom: dyed ? Swatch(hex: dark ? 0x3F4247 : 0x4F5257) : nil,
            secondary: nil,
            cuffInk: dyed ? Swatch.white.opacity(0.96) : ink2,
            cuffInkShadow: dyed,
            bodyTop: Swatch(hex: dark ? 0x292A2D : 0xFCFCFD),
            bodyBottom: Swatch(hex: dark ? 0x1D1E21 : 0xF1F1F3),
            ink: Swatch(hex: dark ? 0xF1F1F3 : 0x212226),
            ink2: ink2,
            ink3: OKLCH(dark ? 0.64 : 0.58, c, h).swatch(),
            rim: OKLCH(dark ? 0.80 : 0.55, c, h).swatch(dark ? 0.18 : 0.22),
            glow: nil,
            ring: nil,
            codeBase: OKLCH(dark ? 0.16 : 0.22, dark ? 0.012 : 0.015, h).swatch(),
            codeText: OKLCH(0.92, 0.01, h).swatch(),
            codeGutter: OKLCH(0.60, 0.01, h).swatch())
    }
}
