import AppKit
import Combine

final class ClipStore: ObservableObject {
    struct ScrollRequest: Equatable {
        enum Target: Equatable {
            case start
            case item(UUID)
        }

        let target: Target
        let serial: Int
    }

    /// 全部历史，新→旧。
    @Published private(set) var items: [ClipItem] = []
    /// 绳上实际挂着的卡：不在搜索时就是 `items`，搜索时是命中的子集（顺序不变）。
    @Published private(set) var shown: [ClipItem] = []
    @Published private(set) var search = SearchQuery.none
    @Published var revealed = false
    @Published var selectedID: UUID?
    @Published var gust = 0
    /// 上次展开面板之后新进来的卡：下次展开时播放入场高光，播完移除。
    @Published var freshIDs: Set<UUID> = []
    /// 刚复制进来、还没在绳上出现过的卡：第一次出现时播放落绳动画。
    @Published var landingIDs: Set<UUID> = []
    /// 搜索框里有字（含输入法还没上屏的拼音）。
    @Published private(set) var fieldHasText = false
    /// 搜索词被外部改写（清除、调试预填）时递增，通知搜索框同步文字。
    @Published private(set) var fieldRevision = 0
    @Published private(set) var scrollRequest: ScrollRequest?

    /// 由 AppDelegate 注入：卡片上的动作要走它的收尾逻辑（隐藏面板、合成 ⌘V）。
    var onRequestTuck: (() -> Void)?
    var onRequestPaste: ((ClipItem) -> Void)?

    /// 自己写回剪贴板后同步，避免把自己的粘贴又抓成一条新历史。
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// nil = 只在内存里（演示模式或存储打不开）。
    private let archive: ClipArchive?
    private let archiveNote: String
    private let retention: Retention
    /// 所有磁盘读写串行地跑在这条队列上，主线程不碰 SQLite。
    private let io = DispatchQueue(label: "com.ashuang.clipline.archive", qos: .utility)
    private var scrollSerial = 0

    init(archive: ClipArchive?, note: String = "memory only", retention: Retention = .standard) {
        self.archive = archive
        archiveNote = note
        self.retention = retention
    }

    var query: String { search.raw }

    func start() {
        loadArchive()

        let poll = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(poll, forMode: .common)

        let breeze = Timer(timeInterval: 7, repeats: true) { [weak self] _ in
            guard let self, self.revealed else { return }
            self.gust &+= 1
        }
        RunLoop.main.add(breeze, forMode: .common)

        poll.fire()
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let item = ClipItem.capture(from: pb) else { return }
        ingest(item)
    }

    /// 新捕获的一条：放到最前、去重、写盘（写盘后内存里只留缩略信息，快照按需从磁盘读回）。
    func ingest(_ captured: ClipItem) {
        if items.first?.fingerprint == captured.fingerprint { return }
        var item = captured
        if let archive, item.bytes <= retention.maxStoredBytes, let record = item.record {
            item.snapshot = nil
            io.async { [weak self] in
                do {
                    try archive.insert(record)
                } catch {
                    Self.log("store: insert failed, keeping clip in memory: \(error)")
                    DispatchQueue.main.async { self?.keepInMemory(record) }
                }
            }
        }
        freshIDs.insert(item.id)
        landingIDs.insert(item.id)
        commit([item] + items.filter { $0.fingerprint != item.fingerprint })
    }

    func remove(_ item: ClipItem) {
        commit(items.filter { $0.id != item.id })
    }

    func clearHistory() {
        items = []
        freshIDs = []
        landingIDs = []
        replaceQuery("")
        refilter(queryChanged: false)
        persist { try $0.deleteAll() }
    }

    /// 把新的完整列表定下来：执行容量淘汰，被移走的条目同步从磁盘删除。
    private func commit(_ next: [ClipItem]) {
        let evicted = retention.evictions(next.map { Retention.Entry(id: $0.id, bytes: $0.bytes, isImage: $0.isImage) })
        let kept = evicted.isEmpty ? next : next.filter { !evicted.contains($0.id) }
        let keptIDs = Set(kept.map(\.id))
        let doomed = Set(items.map(\.id)).union(evicted).subtracting(keptIDs)
        items = kept
        freshIDs.formIntersection(keptIDs)
        landingIDs.formIntersection(keptIDs)
        refilter(queryChanged: false)
        if !doomed.isEmpty { persist { try $0.delete(ids: Array(doomed)) } }
    }

    private func keepInMemory(_ record: ClipRecord) {
        guard let index = items.firstIndex(where: { $0.id == record.id }) else { return }
        items[index].snapshot = record.snapshot
    }

    // MARK: 选择

    func select(offset: Int) {
        guard !shown.isEmpty else { return }
        let index = selectedID.flatMap { id in shown.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + offset, 0), shown.count - 1) } ?? 0
        selectedID = shown[next].id
        requestScroll(.item(shown[next].id))
    }

    var selectedItem: ClipItem? {
        guard let selectedID else { return nil }
        return shown.first { $0.id == selectedID }
    }

    func pasteSelected() {
        if let item = selectedItem { onRequestPaste?(item) }
    }

    /// Esc：先清搜索词，没有搜索词时才收起面板。
    func escape() {
        if fieldHasText || !search.raw.isEmpty {
            replaceQuery("")
        } else {
            onRequestTuck?()
        }
    }

    private func requestScroll(_ target: ScrollRequest.Target) {
        scrollSerial &+= 1
        scrollRequest = ScrollRequest(target: target, serial: scrollSerial)
    }

    // MARK: 搜索

    /// 搜索框的文字变了（只含已上屏的部分；输入法组字中的拼音不参与过滤）。
    func fieldChanged(committed: String, hasText: Bool) {
        if fieldHasText != hasText { fieldHasText = hasText }
        if committed != search.raw { applyQuery(committed) }
    }

    /// 从外部改写搜索词，并让搜索框跟着改。
    func replaceQuery(_ text: String) {
        fieldHasText = !text.isEmpty
        fieldRevision &+= 1
        if text != search.raw { applyQuery(text) }
    }

    private func applyQuery(_ text: String) {
        let next = SearchQuery(text)
        let changed = next.folded != search.folded
        search = next
        if changed { refilter(queryChanged: true) }
    }

    /// 重新算绳上挂哪些卡。换了搜索词时选中第一张命中并滚回开头；清掉搜索词时滚到仍选中的那张。
    private func refilter(queryChanged: Bool) {
        shown = search.isEmpty ? items : items.filter(search.matches)
        let selectionVisible = selectedID.map { id in shown.contains { $0.id == id } } ?? false
        if queryChanged, !search.isEmpty {
            selectedID = shown.first?.id
            requestScroll(.start)
        } else {
            if !selectionVisible { selectedID = shown.first?.id }
            if queryChanged, let selectedID { requestScroll(.item(selectedID)) }
        }
    }

    // MARK: 存储

    /// 粘贴：内存里有快照就用，否则从磁盘读回。读不到时返回 false。
    @discardableResult
    func writeToPasteboard(_ item: ClipItem) -> Bool {
        var snapshot = items.first(where: { $0.id == item.id })?.snapshot ?? item.snapshot
        if snapshot == nil, let archive {
            snapshot = io.sync {
                do { return try archive.snapshot(id: item.id) } catch {
                    Self.log("store: snapshot read failed: \(error)")
                    return nil
                }
            }
        }
        guard let snapshot, !snapshot.isEmpty else { return false }
        Paster.copyToPasteboard(snapshot)
        lastChangeCount = NSPasteboard.general.changeCount
        return true
    }

    /// 后台读库、解缩略图，回主线程并入历史。
    private func loadArchive() {
        guard let archive else {
            Self.log("loaded 0 items from store (\(archiveNote))")
            return
        }
        io.async { [weak self] in
            var records: [ClipRecord] = []
            do { records = try archive.loadRecords() } catch { Self.log("store: load failed: \(error)") }
            var images: [UUID: (thumb: NSImage, pixelSize: CGSize)] = [:]
            for record in records where record.kind == "image" {
                if let data = record.preview, let image = ClipItem.cardImage(from: data) { images[record.id] = image }
            }
            DispatchQueue.main.async { self?.adopt(records, images: images) }
        }
    }

    private func adopt(_ records: [ClipRecord], images: [UUID: (thumb: NSImage, pixelSize: CGSize)]) {
        let present = Set(items.map(\.fingerprint))
        var loaded: [ClipItem] = []
        var broken: [UUID] = []
        for record in records {
            guard let item = ClipItem(record: record, image: images[record.id]) else {
                broken.append(record.id)
                continue
            }
            guard !present.contains(item.fingerprint) else { continue }
            _ = SourceTint.of(item.source)
            loaded.append(item)
        }
        commit(items + loaded)
        if !broken.isEmpty { persist { try $0.delete(ids: broken) } }
        let kept = Set(items.map(\.id))
        Self.log("loaded \(loaded.filter { kept.contains($0.id) }.count) items from store")
    }

    private func persist(_ work: @escaping (ClipArchive) throws -> Void) {
        guard let archive else { return }
        io.async {
            do { try work(archive) } catch { Self.log("store: \(error)") }
        }
    }

    /// 等写盘队列排空。
    func flush() {
        io.sync {}
    }

    /// 退出前调用：排空写盘队列并关库（WAL 在关库时合并回主文件）。
    func close() {
        guard let archive else { return }
        io.sync { archive.close() }
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: 演示数据（CLIPLINE_DEMO=1 时注入：覆盖全部卡型与色板分支，便于目测浅色/深色）

    func seedDemo() {
        let now = Date()
        func app(_ bundleIDs: String...) -> ClipSource {
            bundleIDs.lazy.compactMap { ClipSource.app(bundleID: $0) }.first ?? .unknown
        }
        func text(_ string: String, from source: ClipSource, ago: TimeInterval,
                  extra: [NSPasteboard.PasteboardType: Data] = [:], title: String? = nil) -> ClipItem {
            var map = extra
            map[.string] = Data(string.utf8)
            return ClipItem(kind: ClipClassifier.kind(for: string, source: source, title: title),
                            source: source, copiedAt: now - ago, snapshot: [map], fingerprint: "t:" + string)
        }
        func files(_ paths: [String], ago: TimeInterval) -> ClipItem? {
            let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existing.isEmpty else { return nil }
            return ClipItem(kind: .files(existing), source: app("com.apple.finder"), copiedAt: now - ago,
                            snapshot: existing.map { [.fileURL: Data(URL(fileURLWithPath: $0).absoluteString.utf8)] },
                            fingerprint: "f:" + existing.joined(separator: "|"))
        }

        let docTitle = "Layout | Apple Developer Documentation"
        let docURL = "https://developer.apple.com/documentation/swiftui/layout"
        let note = """
        这是 ClipLine 的原型演示：复制过的内容会挂在这根绳上。

        点卡片 = 复制并粘贴回你刚才的 App；← → 选择，回车粘贴，Esc 或点空白处收起；悬停时点 × 把它摘下来。
        """
        let snippet = """
            func reveal() {
                panel.placeOnScreen()
                if store.selectedItem == nil {
                    store.selectedID = store.items.first?.id
                }
                store.revealed = true
                panel.orderFrontRegardless()
            }
        """

        var seeded: [ClipItem?] = [
            text(docURL, from: app("com.apple.Safari"), ago: 8,
                 extra: [NSPasteboard.PasteboardType("public.url-name"): Data(docTitle.utf8)], title: docTitle),
            text(note, from: app("com.tencent.xinWeChat"), ago: 3 * 60),
            text("周三 14:00 牙医复诊", from: app("com.apple.Notes"), ago: 17 * 60),
            text("git log --oneline --graph -n 20 | grep -i fix", from: app("com.apple.Terminal"), ago: 64 * 60),
            nil,   // 未知来源的图片，见下方
            text("#FF7A59", from: app("com.figma.Desktop"), ago: 2 * 3600),
            text(snippet, from: app("com.apple.dt.Xcode", "com.microsoft.VSCode", "com.google.android.studio",
                                    "com.todesktop.230313mzl4w4u92"), ago: 3 * 3600),
            files(["/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic"], ago: 26 * 3600),
            text("https://github.com/alejandrobujan/tendedero?tab=readme-ov-file#tendedero",
                 from: app("com.google.Chrome"), ago: 30 * 3600),
            text("刚在手机上复制的一句话，通过接力过来。", from: .continuity, ago: 50 * 3600),
            files(["/System/Applications/Calculator.app", "/System/Applications/Notes.app",
                   "/System/Applications/Preview.app"], ago: 4 * 86400),
        ]

        let image = NSImage(size: NSSize(width: 960, height: 600))
        image.lockFocus()
        if let gradient = NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.66, blue: 0.42, alpha: 1),
                                              NSColor(srgbRed: 0.52, green: 0.40, blue: 0.94, alpha: 1)]) {
            gradient.draw(in: NSRect(origin: .zero, size: image.size), angle: -32)
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let card = ClipItem.cardImage(from: tiff) {
            seeded[4] = ClipItem(kind: .image(card.thumb, pixelSize: card.pixelSize), source: .unknown,
                                 copiedAt: now - 100 * 60, snapshot: [[.tiff: tiff]], fingerprint: "i:demo-gradient")
        }

        let demo = seeded.compactMap { $0 }
        freshIDs.formUnion(demo.map(\.id))
        landingIDs.formUnion(demo.map(\.id))
        commit(demo + items)
    }
}
