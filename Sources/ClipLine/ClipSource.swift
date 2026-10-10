import AppKit

/// 一条剪贴板历史的来源 App，在复制被捕获的那一刻记录。
struct ClipSource {
    enum Kind { case app, continuity, unknown }

    let bundleID: String?
    let name: String
    let icon: NSImage?
    let kind: Kind
    /// 名字的其他写法（如本地化名是"微信"时的"WeChat"），只参与搜索。
    var aliases: [String] = []

    static let unknown = ClipSource(bundleID: nil, name: "未知来源", icon: nil, kind: .unknown)
    static let continuity = ClipSource(bundleID: nil, name: "接力", icon: nil, kind: .continuity)

    /// 悬停时页脚左侧显示的来源说明。
    var footnote: String {
        switch kind {
        case .app: return "来自 \(name)"
        case .continuity: return "来自 iPhone"
        case .unknown: return "来源未知"
        }
    }

    var help: String {
        switch kind {
        case .app: return name
        case .continuity: return "接力（通用剪贴板）"
        case .unknown: return "来源未知"
        }
    }

    /// 搜索时参与匹配的来源名；未知来源不参与。
    var searchName: String? {
        switch kind {
        case .app: return ([name] + aliases).joined(separator: " ")
        case .continuity: return "接力 iPhone"
        case .unknown: return nil
        }
    }

    var storageKind: String {
        switch kind {
        case .app: return "app"
        case .continuity: return "continuity"
        case .unknown: return "unknown"
        }
    }

    /// 从存储重建：图标按 bundle id 重新取；App 已卸载时沿用存下的名字、不带图标。
    static func restore(kind: String, bundleID: String?, name: String) -> ClipSource {
        switch kind {
        case "continuity": return .continuity
        case "app":
            guard let bundleID else { return ClipSource(bundleID: nil, name: name, icon: nil, kind: .app) }
            return app(bundleID: bundleID, runningName: name.isEmpty ? bundleID : name)
                ?? ClipSource(bundleID: bundleID, name: name, icon: nil, kind: .app)
        default: return .unknown
        }
    }

    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static let remoteType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    /// 先认 nspasteboard.org 的来源标注，其次用前台 App；接力内容单独标记。
    static func capture(from pb: NSPasteboard) -> ClipSource {
        if pb.types?.contains(remoteType) == true { return .continuity }
        if let id = pb.string(forType: sourceType)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty, let source = app(bundleID: id) {
            return source
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
           let id = front.bundleIdentifier, let source = app(bundleID: id, runningName: front.localizedName) {
            return source
        }
        return .unknown
    }

    private static var directory: [String: (name: String, aliases: [String], icon: NSImage?)] = [:]

    /// 名字与图标按 bundle id 缓存，渲染时不再重新取。名字优先用系统语言下的本地化名。
    static func app(bundleID: String, runningName: String? = nil) -> ClipSource? {
        if let hit = directory[bundleID] {
            return ClipSource(bundleID: bundleID, name: hit.name, icon: hit.icon, kind: .app, aliases: hit.aliases)
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard url != nil || runningName != nil else { return nil }
        let displayName = url.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        let name = url.flatMap(localizedAppName(at:)) ?? displayName ?? runningName ?? bundleID
        var aliases: [String] = []
        for alias in [displayName, runningName].compactMap({ $0 }) where alias != name && !aliases.contains(alias) {
            aliases.append(alias)
        }
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        directory[bundleID] = (name, aliases, icon)
        return ClipSource(bundleID: bundleID, name: name, icon: icon, kind: .app, aliases: aliases)
    }

    /// App 在用户首选语言下的名字（如"微信""备忘录"）。
    /// ClipLine 自己没有本地化资源，系统接口会按英文给名字，所以直接读目标 App 的 InfoPlist.strings / .loctable。
    static func localizedAppName(at url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        func name(in dict: [String: Any]?) -> String? {
            (dict?["CFBundleDisplayName"] as? String ?? dict?["CFBundleName"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        for localization in Bundle.preferredLocalizations(from: bundle.localizations,
                                                          forPreferences: Locale.preferredLanguages) {
            if let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil,
                                      forLocalization: localization),
               let found = name(in: NSDictionary(contentsOfFile: path) as? [String: Any]) {
                return found
            }
        }
        if let path = bundle.path(forResource: "InfoPlist", ofType: "loctable"),
           let table = NSDictionary(contentsOfFile: path) as? [String: [String: Any]] {
            for localization in Bundle.preferredLocalizations(from: Array(table.keys),
                                                              forPreferences: Locale.preferredLanguages) {
                if let found = name(in: table[localization]) { return found }
            }
        }
        return nil
    }
}
