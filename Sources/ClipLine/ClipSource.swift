import AppKit

/// 一条剪贴板历史的来源 App，在复制被捕获的那一刻记录。
struct ClipSource {
    enum Kind { case app, continuity, unknown }

    let bundleID: String?
    let name: String
    let icon: NSImage?
    let kind: Kind

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

    private static var directory: [String: (name: String, icon: NSImage?)] = [:]

    /// 名字与图标按 bundle id 缓存，渲染时不再重新取。
    static func app(bundleID: String, runningName: String? = nil) -> ClipSource? {
        if let hit = directory[bundleID] {
            return ClipSource(bundleID: bundleID, name: hit.name, icon: hit.icon, kind: .app)
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard url != nil || runningName != nil else { return nil }
        let displayName = url.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        let name = displayName ?? runningName ?? bundleID
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        directory[bundleID] = (name, icon)
        return ClipSource(bundleID: bundleID, name: name, icon: icon, kind: .app)
    }
}
