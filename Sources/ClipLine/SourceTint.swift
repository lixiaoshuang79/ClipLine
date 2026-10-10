import AppKit

/// 来源 App 的色相：只取色相与彩度，明度由色板统一规定。
struct SourceTint: Hashable {
    enum Style: Hashable { case chromatic, yellow, graphite, unknown }

    var h: Double
    var c: Double
    var h2: Double?
    var style: Style

    static let graphite = SourceTint(h: 260, c: 0.006, h2: nil, style: .graphite)
    static let unknown = SourceTint(h: 260, c: 0.006, h2: nil, style: .unknown)
    static let continuity = normalized(h: 250, c: 0.12, h2: nil)

    /// 规范化彩度；色相落在 70°–120° 的走黄色带特例（亮色头 + 深棕字）。
    static func normalized(h: Double, c: Double, h2: Double?) -> SourceTint {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return SourceTint(h: hue, c: min(max(c, 0.07), 0.16), h2: h2,
                          style: (70...120).contains(hue) ? .yellow : .chromatic)
    }

    // MARK: 缓存与品牌修正

    private static var cache: [String: SourceTint] = [:]

    /// 多色图标取色不准时的修正（≤ 20 条）。
    private static let brandHex: [String: UInt32] = [
        "com.google.Chrome": 0x1A73E8,
        "com.microsoft.edgemac": 0x0C8CE9,
        "com.tinyspeck.slackmacgap": 0x611F69,
        "com.figma.Desktop": 0xA259FF,
    ]

    private static let forcedGraphite: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.todesktop.230313mzl4w4u92",   // Cursor
    ]

    static func of(_ source: ClipSource) -> SourceTint {
        switch source.kind {
        case .continuity: return .continuity
        case .unknown: return .unknown
        case .app:
            guard let id = source.bundleID else { return .graphite }
            if let hit = cache[id] { return hit }
            let tint: SourceTint
            if forcedGraphite.contains(id) {
                tint = .graphite
            } else if let hex = brandHex[id] {
                let brand = OKLCH(hex: hex)
                tint = normalized(h: brand.h, c: brand.c, h2: nil)
            } else if let icon = source.icon {
                tint = extract(from: icon)
            } else {
                tint = .graphite
            }
            cache[id] = tint
            return tint
        }
    }

    // MARK: 取色（§3.2）

    static func extract(from icon: NSImage) -> SourceTint {
        let side = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .graphite
        }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return .graphite }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = context.data else { return .graphite }
        let px = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // 只采样中间 80%，避开图标自带的留白和投影。
        let margin = Int((Double(side) * 0.1).rounded())
        var samples: [(h: Double, c: Double)] = []
        var opaque = 0
        for y in margin..<(side - margin) {
            for x in margin..<(side - margin) {
                let i = (y * side + x) * 4
                let alpha = Double(px[i + 3]) / 255
                guard alpha >= 0.6 else { continue }
                opaque += 1
                func channel(_ v: UInt8) -> Double { Swatch.decode(min(Double(v) / 255 / alpha, 1)) }
                let lch = OKLCH(linearRed: channel(px[i]), green: channel(px[i + 1]), blue: channel(px[i + 2]))
                if lch.c >= 0.05, (0.25...0.95).contains(lch.l) { samples.append((lch.h, lch.c)) }
            }
        }
        guard opaque > 0, Double(samples.count) / Double(opaque) >= 0.10 else { return .graphite }

        let bins = 36
        func bin(_ hue: Double) -> Int { min(Int(hue / 10), bins - 1) }
        var histogram = [Double](repeating: 0, count: bins)
        for s in samples { histogram[bin(s.h)] += s.c }
        let smooth = (0..<bins).map {
            0.25 * histogram[($0 + bins - 1) % bins] + 0.5 * histogram[$0] + 0.25 * histogram[($0 + 1) % bins]
        }
        func binDistance(_ a: Int, _ b: Int) -> Int { let d = abs(a - b); return min(d, bins - d) }
        func near(_ peak: Int) -> [(h: Double, c: Double)] { samples.filter { binDistance(bin($0.h), peak) <= 1 } }

        guard let peak = smooth.indices.max(by: { smooth[$0] < smooth[$1] }) else { return .graphite }
        let main = near(peak)
        let h = circularMean(main)
        let chromas = main.map(\.c).sorted()
        let c = chromas[Int(Double(chromas.count - 1) * 0.75)]

        var h2: Double?
        let rivals = smooth.indices.filter { i in
            binDistance(i, peak) >= 4
                && smooth[i] >= smooth[(i + bins - 1) % bins]
                && smooth[i] >= smooth[(i + 1) % bins]
        }
        if let second = rivals.max(by: { smooth[$0] < smooth[$1] }), smooth[second] >= 0.4 * smooth[peak] {
            let candidate = circularMean(near(second))
            let gap = abs(candidate - h).truncatingRemainder(dividingBy: 360)
            if min(gap, 360 - gap) >= 45 { h2 = candidate }
        }
        return normalized(h: h, c: c, h2: h2)
    }

    /// 以彩度为权重的环形平均色相。
    private static func circularMean(_ samples: [(h: Double, c: Double)]) -> Double {
        var x = 0.0, y = 0.0
        for s in samples {
            x += s.c * cos(s.h * .pi / 180)
            y += s.c * sin(s.h * .pi / 180)
        }
        let hue = atan2(y, x) * 180 / .pi
        return hue < 0 ? hue + 360 : hue
    }
}
