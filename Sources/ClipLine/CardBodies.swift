import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// 内容区底部 14pt 渐隐，代替省略号截断。
private let bottomFade = LinearGradient(stops: [
    .init(color: .black, location: 0),
    .init(color: .black, location: 0.83),
    .init(color: .clear, location: 1),
], startPoint: .top, endPoint: .bottom)

// MARK: 文本

struct TextBody: View {
    let text: String
    let palette: CardPalette

    var body: some View {
        let cleaned = Self.tidy(text)
        if Self.isShort(cleaned) {
            Text(cleaned)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            let (lead, rest) = Self.split(cleaned)
            VStack(alignment: .leading, spacing: 3) {
                Text(lead)
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(-0.1)
                    .lineLimit(2)
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !rest.isEmpty {
                    Text(rest)
                        .font(.system(size: 11))
                        .lineSpacing(2.5)
                        .foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: CardBody.contentSize.width, height: CardBody.contentSize.height, alignment: .topLeading)
            .clipped()
            .mask(bottomFade)
        }
    }

    /// 合并连续空行、去掉首尾空白；只留卡片放得下的前一段，避免排版超长文本。
    static func tidy(_ text: String) -> String {
        var lines: [Substring] = []
        for line in text.prefix(1200).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let blank = line.allSatisfy(\.isWhitespace)
            if blank, lines.last?.allSatisfy(\.isWhitespace) ?? true { continue }
            lines.append(blank ? "" : line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 单行且 ≤ 18 个字符（中文字符计 1）。
    static func isShort(_ cleaned: String) -> Bool {
        !cleaned.contains(where: \.isNewline) && cleaned.count <= 18
    }

    static func split(_ cleaned: String) -> (lead: String, rest: String) {
        guard let newline = cleaned.firstIndex(where: \.isNewline) else { return (cleaned, "") }
        let lead = cleaned[..<newline].trimmingCharacters(in: .whitespaces)
        let rest = cleaned[cleaned.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (lead, rest)
    }

    static func countLabel(_ text: String) -> String {
        let count = text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
        return count >= 1000 ? String(format: "%.1fk 字", Double(count) / 1000) : "\(count) 字"
    }
}

// MARK: 链接

struct LinkBody: View {
    let url: URL
    let title: String?
    let palette: CardPalette

    var body: some View {
        let parts = Self.parts(of: url)
        if let title {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(palette.ink)
                Text(parts.domain)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(palette.ink2)
                if !parts.path.isEmpty {
                    Text(parts.path)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(palette.ink3)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(parts.domain)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(palette.ink)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.ring)
                }
                if !parts.path.isEmpty {
                    Text(parts.path)
                        .font(.system(size: 10.5))
                        .lineLimit(3)
                        .foregroundStyle(palette.ink2)
                }
            }
        }
    }

    /// 域名去掉 `www.`；路径带上参数与锚点。没有主机名的链接（如 mailto:）整串当"域名"。
    static func parts(of url: URL) -> (domain: String, path: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            let raw = url.absoluteString
            let scheme = url.scheme.map { $0 + ":" } ?? ""
            return (raw.hasPrefix(scheme) ? String(raw.dropFirst(scheme.count)) : raw, "")
        }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath
        if path == "/" { path = "" }
        if let query = components.query, !query.isEmpty { path += "?" + query }
        if let fragment = components.fragment, !fragment.isEmpty { path += "#" + fragment }
        return (domain, path)
    }
}

// MARK: 代码

struct CodeBody: View {
    let code: String
    let palette: CardPalette

    private static let lineHeight: CGFloat = 13   // 10pt × 1.3
    private static let maxLines = 6
    private static let gutter: CGFloat = 16
    private static let gap: CGFloat = 5
    /// 底板宽（卡宽 − 两侧内缩 8）减去行号栏；定宽才能让超长行被裁掉而不是撑开布局。
    private static let textWidth = Layout.cardWidth - 16 - gutter - gap

    var body: some View {
        let lines = Array(Self.lines(of: code).prefix(Self.maxLines))
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(alignment: .top, spacing: Self.gap) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    Text("\(index + 1)")
                        .font(.system(size: 9, design: .monospaced))
                        .frame(height: Self.lineHeight)
                }
            }
            .frame(width: Self.gutter, alignment: .trailing)
            .foregroundStyle(palette.codeGutter)
            .opacity(0.6)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index].isEmpty ? " " : lines[index])
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: Self.lineHeight, alignment: .leading)
                }
            }
            .foregroundStyle(palette.codeText)
            .frame(width: Self.textWidth, alignment: .leading)
            .clipped()
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 1 - 16 / Self.textWidth),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.codeBase, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
    }

    /// tab 换成 2 个空格、去掉首尾空行和所有行共有的缩进。
    static func lines(of code: String) -> [String] {
        var lines = code.replacingOccurrences(of: "\t", with: "  ")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { String($0) }
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        let indent = lines.filter { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.prefix { $0 == " " }.count }
            .min() ?? 0
        return lines.map { $0.allSatisfy(\.isWhitespace) ? "" : String($0.dropFirst(indent)) }
    }
}

// MARK: 颜色

struct ColorBody: View {
    let color: NSColor
    let literal: String
    let palette: CardPalette

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if color.alphaComponent < 1 { Checkerboard() }
            Color(nsColor: color)
            Text(literal)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassFrame(capsule: true)
                .frame(maxWidth: Layout.cardWidth - 20, alignment: .leading)
                .padding(.leading, 10)
                .padding(.bottom, 9 + 13 + 6)   // 停在页脚上方
        }
        .clipShape(BleedShape())
    }

    /// 相对亮度；带透明度时按叠在白底上估算。
    static func luminance(of color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0.5 }
        let a = Double(c.alphaComponent)
        func channel(_ v: CGFloat) -> Double { Swatch.decode(Double(v) * a + (1 - a)) }
        return Swatch(r: channel(c.redComponent), g: channel(c.greenComponent), b: channel(c.blueComponent)).luminance
    }
}

/// 透明内容下面垫的 8pt 棋盘格。
struct Checkerboard: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(white: dark ? 0x2A / 255.0 : 1)))
            let alternate = dark ? Color(.sRGB, red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x27 / 255.0)
                                 : Color(white: 0xEB / 255.0)
            var path = Path()
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column) % 2 == 1 {
                    path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(path, with: .color(alternate))
        }
    }
}

// MARK: 图片

struct ImageBody: View {
    let image: NSImage
    let pixelSize: CGSize

    var body: some View {
        // 长截图的有效信息通常在上方：顶部对齐裁切。
        let tall = pixelSize.width > 0 && pixelSize.height / pixelSize.width > 1.6
        ZStack {
            Checkerboard()
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: Layout.cardWidth, height: Layout.cardHeight - Layout.cuffHeight,
                       alignment: tall ? .top : .center)
                .clipped()
        }
        .clipShape(BleedShape())
        .overlay(BleedShape().stroke(.white.opacity(0.12), lineWidth: 1).clipShape(BleedShape()))
    }
}

// MARK: 文件

struct FileBody: View {
    let paths: [String]
    let palette: CardPalette

    var body: some View {
        if paths.count == 1, let path = paths.first {
            HStack(alignment: .top, spacing: 10) {
                FileThumb(path: path)
                VStack(alignment: .leading, spacing: 4) {
                    Text(FileFacts.name(path))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .foregroundStyle(palette.ink)
                    HStack(spacing: 3) {
                        Image(systemName: "folder").font(.system(size: 9))
                        Text(FileFacts.folder(path))
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let stack = Array(paths.prefix(3))
            let angles: [Double] = [-8, 0, 8]
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    ForEach(stack.indices, id: \.self) { index in
                        Image(nsImage: FileFacts.icon(stack[index]))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 36, height: 36)
                            .rotationEffect(.degrees(angles[index]))
                            .offset(x: CGFloat(index) * 10, y: 4)
                    }
                }
                .frame(width: 36 + CGFloat(stack.count - 1) * 10, height: 44, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(paths.count) 个文件")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.ink)
                    ForEach(paths.prefix(2), id: \.self) { path in
                        Text(FileFacts.name(path))
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(palette.ink2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 44pt 文件缩略图：图片/PDF/视频异步生成 Quick Look 缩略图，回填前先显示系统图标。
struct FileThumb: View {
    let path: String

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            } else {
                Image(nsImage: FileFacts.icon(path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
            }
        }
        .task(id: path) { thumbnail = await FileFacts.thumbnail(path) }
    }
}

/// 文件名、目录、大小、图标与缩略图；全部按路径缓存（只在主线程访问）。
enum FileFacts {
    private static var icons: [String: NSImage] = [:]
    private static var thumbnails: [String: NSImage] = [:]
    private static var summaries: [String: String] = [:]

    static func name(_ path: String) -> String {
        FileManager.default.displayName(atPath: path)
    }

    static func folder(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }

    static func icon(_ path: String) -> NSImage {
        if let hit = icons[path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// 单个："PDF · 2.4 MB"；多个："共 12.6 MB"。
    static func summary(_ paths: [String]) -> String {
        let key = paths.joined(separator: "|")
        if let hit = summaries[key] { return hit }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let summary: String
        if paths.count == 1, let path = paths.first {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey])
            if url.pathExtension.lowercased() == "app" {
                summary = "应用"
            } else if values?.isDirectory == true, values?.isPackage != true {
                summary = "文件夹"
            } else {
                let ext = url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased()
                summary = values?.fileSize.map { "\(ext) · " + formatter.string(fromByteCount: Int64($0)) } ?? ext
            }
        } else {
            let total = paths.reduce(Int64(0)) { sum, path in
                let size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return sum + Int64(size)
            }
            summary = total > 0 ? "共 " + formatter.string(fromByteCount: total) : "\(paths.count) 项"
        }
        summaries[key] = summary
        return summary
    }

    @MainActor
    static func thumbnail(_ path: String) async -> NSImage? {
        if let hit = thumbnails[path] { return hit }
        let url = URL(fileURLWithPath: path)
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .movie) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 44, height: 44),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        thumbnails[path] = representation.nsImage
        return representation.nsImage
    }
}
