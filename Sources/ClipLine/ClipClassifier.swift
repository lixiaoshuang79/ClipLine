import AppKit

/// 纯文本内容的细分：颜色字面值 → 整串 URL → 代码 → 普通文本。
enum ClipClassifier {
    static func kind(for string: String, source: ClipSource, title: String?) -> ClipItem.Kind {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let color = parseColor(trimmed) { return .color(color, literal: trimmed) }
        if let url = wholeURL(trimmed) { return .link(url, title: title) }
        if isCode(string, source: source) { return .code(string) }
        return .text(string)
    }

    // MARK: 链接

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func wholeURL(_ string: String) -> URL? {
        guard !string.isEmpty, !string.contains(where: \.isWhitespace) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = linkDetector?.firstMatch(in: string, options: [], range: range),
              match.range == range else { return nil }
        return match.url
    }

    // MARK: 代码

    private static let codeApps: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    static func isCode(_ string: String, source: ClipSource) -> Bool {
        let lines = string.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        guard lines.count >= 2 else { return false }
        if let id = source.bundleID, codeApps.contains(id) || id.hasPrefix("com.jetbrains.") { return true }
        let visible = string.filter { !$0.isWhitespace }
        let symbols = visible.filter { "{}();=<>[]".contains($0) }
        if Double(symbols.count) / Double(max(visible.count, 1)) > 0.06 { return true }
        return lines.contains { line in
            guard let firstVisible = line.firstIndex(where: { !$0.isWhitespace }) else { return false }
            let indent = line[..<firstVisible]
            return indent.contains("\t") || indent.filter { $0 == " " }.count >= 2
        }
    }

    // MARK: 颜色

    /// `#RGB` / `#RRGGBB` / `#RRGGBBAA` / `rgb()` / `rgba()` / `hsl()` / `hsla()` / `oklch()`。
    static func parseColor(_ string: String) -> NSColor? {
        let s = string.lowercased()
        if s.hasPrefix("#") { return hexColor(String(s.dropFirst())) }
        guard s.hasSuffix(")"), let open = s.firstIndex(of: "(") else { return nil }
        let function = s[..<open].trimmingCharacters(in: .whitespaces)
        let args = s[s.index(after: open)..<s.index(before: s.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace })
            .map(String.init)
        guard args.count == 3 || args.count == 4 else { return nil }
        let alpha = args.count == 4 ? fraction(args[3]) : 1
        guard let alpha else { return nil }

        switch function {
        case "rgb", "rgba":
            let channels = args.prefix(3).map { arg -> Double? in
                arg.hasSuffix("%") ? fraction(arg) : Double(arg).map { $0 / 255 }
            }
            guard let r = channels[0], let g = channels[1], let b = channels[2],
                  [r, g, b].allSatisfy({ (0...1).contains($0) }) else { return nil }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        case "hsl", "hsla":
            guard let h = angle(args[0]), let sat = fraction(args[1]), let light = fraction(args[2]) else { return nil }
            let (r, g, b) = hslToRGB(h, sat, light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
        case "oklch":
            guard let l = fraction(args[0]), let h = angle(args[2]) else { return nil }
            let chroma = args[1].hasSuffix("%") ? fraction(args[1]).map { $0 * 0.4 } : Double(args[1])
            guard let chroma else { return nil }
            let swatch = OKLCH(l, chroma, h).swatch()
            return NSColor(srgbRed: Swatch.encode(swatch.r), green: Swatch.encode(swatch.g),
                           blue: Swatch.encode(swatch.b), alpha: alpha)
        default:
            return nil
        }
    }

    /// 页脚左侧显示的格式名。
    static func colorFormat(_ literal: String) -> String {
        let s = literal.lowercased()
        if s.hasPrefix("rgb") { return "RGB" }
        if s.hasPrefix("hsl") { return "HSL" }
        if s.hasPrefix("oklch") { return "OKLCH" }
        return "HEX"
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    private static func hexColor(_ digits: String) -> NSColor? {
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits
        guard let full = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let rgb = hasAlpha ? full >> 8 : full
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255,
                       alpha: hasAlpha ? CGFloat(full & 0xFF) / 255 : 1)
    }

    /// `50%` → 0.5；`0.5` → 0.5。
    private static func fraction(_ arg: String) -> Double? {
        if arg.hasSuffix("%") { return Double(arg.dropLast()).map { $0 / 100 } }
        return Double(arg)
    }

    private static func angle(_ arg: String) -> Double? {
        Double(arg.hasSuffix("deg") ? String(arg.dropLast(3)) : arg)
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let chroma = (1 - abs(2 * l - 1)) * s
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - chroma / 2
        let (r, g, b): (Double, Double, Double)
        switch hue {
        case ..<60: (r, g, b) = (chroma, x, 0)
        case ..<120: (r, g, b) = (x, chroma, 0)
        case ..<180: (r, g, b) = (0, chroma, x)
        case ..<240: (r, g, b) = (0, x, chroma)
        case ..<300: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}
