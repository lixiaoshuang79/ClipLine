import AppKit
import UniformTypeIdentifiers

/// 把条目的原始剪贴板内容打包成拖拽载荷：文件走文件 URL、图片走 PNG/TIFF、文本走纯文本/RTF、
/// 颜色走字面值。拖出去只分享一份副本，绳上这条不动；拖不动的类型（无可用表示）会退成纯文本。
enum Dragging {
    static func provider(for item: ClipItem, store: ClipStore) -> NSItemProvider {
        let provider = NSItemProvider()
        let snapshot = store.snapshotForDrag(item)
        let first = snapshot?.first

        // 文件（含目录）：按粘贴板原格式给 public.file-url 数据表示——这是兼容面最大的做法：
        // loadItem / loadObject(URL) / 访达的粘贴板读取 / loadFileRepresentation（物化成临时文件）都能取到。
        // 注意：不要给同一类型再叠加 file representation——本系统上两种表示并存会让 loadItem 直接报"没有加载器"。
        // 已知限制：多文件时 NSItemProvider 只能取回最后一份表示。
        let fileURLs: [URL] = (snapshot ?? []).compactMap { map in
            guard let data = map[.fileURL],
                  let string = String(data: data, encoding: .utf8),
                  let url = URL(string: string), url.isFileURL else { return nil }
            return url
        }
        for url in fileURLs {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(Data(url.absoluteString.utf8), nil)
                return nil
            }
        }

        // 图片
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = first?[type] else { continue }
            let identifier = type == .png ? UTType.png.identifier : UTType.tiff.identifier
            provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }

        // 文本 / RTF
        if let data = first?[.string], let string = String(data: data, encoding: .utf8) {
            provider.registerObject(string as NSString, visibility: .all)
        }
        if let data = first?[.rtf] {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }

        // 链接：顺带挂一个 URL 表示（拖进浏览器地址栏等场景）。
        if case .link(let url, _) = item.kind {
            provider.registerObject(url as NSURL, visibility: .all)
        }
        // 颜色：挂字面值文本（颜色拖拽大多落在支持文本的地方）。
        if case .color(_, let literal) = item.kind {
            provider.registerObject(literal as NSString, visibility: .all)
        }

        // 兜底：什么表示都没注册上（罕见类型的快照）时，至少给一段可拖的纯文本。
        if provider.registeredTypeIdentifiers.isEmpty {
            provider.registerObject(item.footnote as NSString, visibility: .all)
        }
        return provider
    }
}
