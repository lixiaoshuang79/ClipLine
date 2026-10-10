import Foundation

/// 历史容量：条数上限 + 图片总体积预算，超出时按最旧淘汰；单条快照过大时只留在内存里、不写盘。
struct Retention {
    var maxItems: Int
    var imageBudget: Int
    var maxStoredBytes: Int

    static let standard = Retention(maxItems: 500, imageBudget: 256 << 20, maxStoredBytes: 64 << 20)

    struct Entry {
        let id: UUID
        let bytes: Int
        let isImage: Bool
    }

    /// `entries` 按新→旧排列，返回要淘汰的 id。最新一条永远保留，哪怕它自己就超了预算。
    func evictions(_ entries: [Entry]) -> Set<UUID> {
        let limit = max(maxItems, 1)
        var evicted = Set(entries.dropFirst(limit).map(\.id))
        let kept = entries.prefix(limit)
        var total = kept.reduce(0) { $1.isImage ? $0 + $1.bytes : $0 }
        for entry in kept.dropFirst().reversed() where entry.isImage && total > imageBudget {
            evicted.insert(entry.id)
            total -= entry.bytes
        }
        return evicted
    }
}
