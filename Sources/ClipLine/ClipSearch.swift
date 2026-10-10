import AppKit
import SwiftUI

/// 搜索词：按空白切成若干检索词，每个都命中才算匹配；每个词是大小写、全半角不敏感的子串。
struct SearchQuery: Equatable {
    let raw: String
    /// 原样的检索词，高亮时在展示文字里做不敏感查找。
    let terms: [String]
    /// 折叠后的检索词，在 `ClipItem.searchText` 里做字面查找（逐键过滤走这条快路径）。
    /// 只差大小写、全半角的两个搜索词，这一项相同。
    let folded: [String]

    static let none = SearchQuery("")
    /// 单条参与检索的正文上限（UTF-16 单位），超长文本不拖慢逐键过滤。
    static let haystackLimit = 200_000
    private static let options: NSString.CompareOptions = [.caseInsensitive, .widthInsensitive]

    init(_ raw: String) {
        self.raw = raw
        terms = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        folded = terms.map(Self.fold)
    }

    var isEmpty: Bool { terms.isEmpty }

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// 参与匹配的文字：文本/代码正文、链接（原串、解码后的串、标题）、颜色字面值、文件名、来源 App 名。图片不做 OCR。
    static func haystack(kind: ClipItem.Kind, source: ClipSource) -> NSString {
        var parts: [String] = []
        switch kind {
        case .text(let string), .code(let string):
            parts.append(string.utf16.count > haystackLimit ? String(string.prefix(haystackLimit)) : string)
        case .link(let url, let title):
            let string = url.absoluteString
            parts.append(string)
            if let decoded = string.removingPercentEncoding, decoded != string { parts.append(decoded) }
            if let title { parts.append(title) }
        case .color(_, let literal):
            parts.append(literal)
        case .image:
            break
        case .files(let paths):
            for path in paths {
                parts.append((path as NSString).lastPathComponent)
                parts.append(FileFacts.name(path))
            }
        }
        if let name = source.searchName { parts.append(name) }
        return fold(parts.joined(separator: "\n")) as NSString
    }

    func matches(_ item: ClipItem) -> Bool {
        let primary = item.searchText
        let ocr = item.ocrFolded
        return folded.allSatisfy { term in
            if primary.range(of: term, options: .literal).location != NSNotFound { return true }
            guard let ocr else { return false }
            return ocr.range(of: term, options: .literal).location != NSNotFound
        }
    }

    /// 任一检索词出现在 `string` 里。
    func hits(_ string: String) -> Bool {
        let ns = string as NSString
        return terms.contains { ns.range(of: $0, options: Self.options).location != NSNotFound }
    }

    /// 每个检索词都出现在 `string` 里。
    func hitsAll(_ string: String) -> Bool {
        let ns = string as NSString
        return !isEmpty && terms.allSatisfy { ns.range(of: $0, options: Self.options).location != NSNotFound }
    }

    /// 最靠前的一处命中。
    func firstHit(in string: String) -> NSRange? {
        let ns = string as NSString
        return terms.map { ns.range(of: $0, options: Self.options) }
            .filter { $0.location != NSNotFound }
            .min { $0.location < $1.location }
    }

    /// 全部命中位置（每个词最多 32 处，只用于卡上那几行展示文字）。
    func ranges(in string: String) -> [NSRange] {
        guard !isEmpty, !string.isEmpty else { return [] }
        let ns = string as NSString
        var found: [NSRange] = []
        for term in terms {
            var location = 0
            for _ in 0..<32 {
                let hit = ns.range(of: term, options: Self.options,
                                   range: NSRange(location: location, length: ns.length - location))
                guard hit.location != NSNotFound, hit.length > 0 else { break }
                found.append(hit)
                location = NSMaxRange(hit)
                if location >= ns.length { break }
            }
        }
        return found
    }

    /// 命中片段涂上荧光笔底色；`ink` 给次级文字里的命中提一档墨色。
    func marked(_ string: String, mark: Color, ink: Color? = nil) -> AttributedString {
        var attributed = AttributedString(string)
        for range in ranges(in: string) {
            guard let r = Range(range, in: attributed) else { continue }
            attributed[r].swiftUI.backgroundColor = mark
            if let ink { attributed[r].swiftUI.foregroundColor = ink }
        }
        return attributed
    }

    /// 第一处命中前后的一段原文：空白折叠成单个空格，前面被截掉时加省略号。
    func snippet(in text: String, lead: Int = 14, length: Int = 160) -> String? {
        guard let hit = firstHit(in: text) else { return nil }
        let ns = text as NSString
        let start = ns.rangeOfComposedCharacterSequence(at: max(0, hit.location - lead)).location
        var end = min(ns.length, max(start + length, NSMaxRange(hit)))
        if end < ns.length { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: end - 1)) }
        let piece = ns.substring(with: NSRange(location: start, length: end - start))
        let collapsed = piece.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > 0 ? "…" : "") + collapsed
    }
}

private struct SearchQueryKey: EnvironmentKey {
    static let defaultValue = SearchQuery.none
}

extension EnvironmentValues {
    /// 当前搜索词，卡面据此高亮命中片段。
    var searchQuery: SearchQuery {
        get { self[SearchQueryKey.self] }
        set { self[SearchQueryKey.self] = newValue }
    }
}
