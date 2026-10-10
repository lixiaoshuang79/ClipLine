import AppKit
import CryptoKit

struct ClipItem: Identifiable {
    enum Kind {
        case text(String)
        case link(URL, title: String?)
        case code(String)
        case color(NSColor, literal: String)
        case image(NSImage, pixelSize: CGSize)   // 缩略图 + 原图像素；原图在 snapshot 里
        case files([String])
    }

    let id = UUID()
    let kind: Kind
    let source: ClipSource
    let copiedAt: Date
    /// 原始剪贴板快照（每项：类型 → 数据），粘贴时原样写回，保真。
    let snapshot: [[NSPasteboard.PasteboardType: Data]]
    let fingerprint: String
    let tilt = Double.random(in: -1.4 ... 1.4)
}

extension ClipItem {
    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    /// 类型判定顺序：文件 → 图片 → 颜色 → 链接 → 代码 → 文本（RTF 按文本处理）。
    static func capture(from pb: NSPasteboard) -> ClipItem? {
        guard let pbItems = pb.pasteboardItems, !pbItems.isEmpty else { return nil }
        if let types = pb.types, types.contains(where: { type in
            ClipStore.ignoredTypes.contains(type.rawValue) || type.rawValue.hasPrefix("dyn.")
        }) {
            return nil
        }

        var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pbItems {
            var map: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { map[type] = data }
            }
            snapshot.append(map)
        }
        guard let first = snapshot.first, !first.isEmpty else { return nil }

        let source = ClipSource.capture(from: pb)
        _ = SourceTint.of(source)   // 取色在捕获时做完，渲染只查缓存
        func make(_ kind: Kind, _ fingerprint: String) -> ClipItem {
            ClipItem(kind: kind, source: source, copiedAt: Date(), snapshot: snapshot, fingerprint: fingerprint)
        }

        let filePaths: [String] = snapshot.compactMap { map in
            guard let data = map[.fileURL],
                  let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL else { return nil }
            return url.path
        }
        if !filePaths.isEmpty {
            return make(.files(filePaths), "f:" + filePaths.joined(separator: "|"))
        }

        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            if let data = first[type], let image = cardImage(from: data) {
                return make(.image(image.thumb, pixelSize: image.pixelSize), "i:" + sha256(data))
            }
        }

        if first[.color] != nil, let color = NSColor(from: pb) {
            let hex = ClipClassifier.hex(color)
            return make(.color(color, literal: hex), "c:" + hex)
        }

        let title = first[urlNameType]
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = first[.string], let string = String(data: data, encoding: .utf8),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let kind = ClipClassifier.kind(for: string, source: source, title: title?.isEmpty == false ? title : nil)
            return make(kind, "t:" + string)
        }

        // 只有 RTF 的复制（Word / Pages 等）：取纯文本展示，粘贴仍是原始 RTF。
        if let data = first[.rtf],
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil),
           !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let string = attributed.string
            return make(ClipClassifier.kind(for: string, source: source, title: nil), "t:" + string)
        }

        return nil
    }

    /// 卡片用缩略图：按铺满 168 × 120（@2x）所需的尺寸取，长截图也不糊；同时给出原图像素。
    static func cardImage(from data: Data) -> (thumb: NSImage, pixelSize: CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var pixelSize = CGSize.zero
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let h = props[kCGImagePropertyPixelHeight] as? CGFloat {
            pixelSize = CGSize(width: w, height: h)
        }
        var maxPixel: CGFloat = 420
        if pixelSize.width > 0, pixelSize.height > 0 {
            let long = max(pixelSize.width, pixelSize.height)
            let fill = max(Layout.cardWidth * 2 / pixelSize.width, (Layout.cardHeight - Layout.cuffHeight) * 2 / pixelSize.height)
            maxPixel = min(long, min(max(long * fill, 240), 1600))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        if pixelSize == .zero { pixelSize = CGSize(width: cgImage.width, height: cgImage.height) }
        let thumb = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (thumb, pixelSize)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
