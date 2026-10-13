import AppKit
import Combine
import UniformTypeIdentifiers

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
    /// 当前在看的标签板（nil = 剪贴板历史）。绳式样式不展示标签，应保持 nil。
    @Published var activeBoardID: UUID? = nil {
        didSet { if oldValue != activeBoardID { refilter(queryChanged: false) } }
    }
    /// 用户自建的标签板，按顶栏顺序排列。
    @Published private(set) var boards: [Pinboard] = []
    /// 每个板里的条目 id（新固定在前），板视图按它排序。
    private var boardMembers: [UUID: [UUID]] = [:]

    /// 由 AppDelegate 注入：卡片上的动作要走它的收尾逻辑（隐藏面板、合成 ⌘V）。
    var onRequestTuck: (() -> Void)?
    var onRequestPaste: ((ClipItem) -> Void)?

    /// 自己写回剪贴板后同步，避免把自己的粘贴又抓成一条新历史。
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// nil = 只在内存里（演示模式或存储打不开）。
    private let archive: ClipArchive?
    private let archiveNote: String
    private var retention: Retention
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
        // 重新复制一条已置顶或已归入标签的内容：状态跟着新副本走（同指纹旧行会被新行替换）。
        if let old = items.first(where: { $0.fingerprint == item.fingerprint }) {
            if old.pinned { item.pinned = true }
            if !old.boards.isEmpty {
                item.boards = old.boards
                for board in old.boards {
                    if let index = boardMembers[board]?.firstIndex(of: old.id) {
                        boardMembers[board]?[index] = item.id
                    }
                    persist { try $0.addMembership(pinboard: board, clip: item.id) }
                }
            }
        }
        // 图片先留一份数据，等落库后跑 OCR（快照随后会被清掉）。
        var ocrCandidate: Data?
        if item.isImage, archive != nil, let snapshot = item.snapshot {
            ocrCandidate = snapshot.first?[.tiff] ?? snapshot.first?[.png]
        }
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
            if let ocrCandidate {
                scheduleOcr(id: item.id, imageData: ocrCandidate, archive: archive)
            }
        }
        freshIDs.insert(item.id)
        landingIDs.insert(item.id)
        commit([item] + items.filter { $0.fingerprint != item.fingerprint })
    }

    func remove(_ item: ClipItem) {
        commit(items.filter { $0.id != item.id })
    }

    // MARK: 置顶

    /// 置顶上限，防止无限增长（置顶项不参与淘汰，必须自己封顶）。
    static let maxPinned = 100

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let next = !items[index].pinned
        if next, items.lazy.filter(\.pinned).count >= Self.maxPinned {
            Self.log("pin: 置顶已达上限 \(Self.maxPinned) 条，先取消几条")
            return
        }
        items[index].pinned = next
        persist { try $0.setPinned(id: item.id, pinned: next) }
        refilter(queryChanged: false)   // 置顶排最前，顺序会变
    }

    /// 清空历史（置顶条目与已归入标签的条目保留）。
    func clearHistory() {
        items = items.filter { $0.pinned || !$0.boards.isEmpty }
        let kept = Set(items.map(\.id))
        boardMembers = boardMembers.mapValues { $0.filter(kept.contains) }
        freshIDs = []
        landingIDs = []
        replaceQuery("")
        refilter(queryChanged: false)
        persist { try $0.deleteAll(keepingPinned: true) }
    }

    // MARK: 标签板（对齐 Paste 的 Pinboard：自建标签 + 条目归类）

    func board(id: UUID?) -> Pinboard? {
        id.flatMap { wanted in boards.first { $0.id == wanted } }
    }

    /// 顶栏「+」新建：空名落「未命名」；颜色按 8 色板顺延。新建后切到新板。
    @discardableResult
    func addBoard(name: String) -> Pinboard {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let palette = PinboardColor.allCases
        let board = Pinboard(id: UUID(),
                             name: trimmed.isEmpty ? "未命名" : trimmed,
                             color: palette[boards.count % palette.count],
                             position: (boards.map(\.position).max() ?? -1) + 1)
        boards.append(board)
        boardMembers[board.id] = []
        persist {
            try $0.insertPinboard(PinboardRecord(id: board.id, name: board.name,
                                                 color: board.color.rawValue, position: board.position))
        }
        activeBoardID = board.id
        return board
    }

    func renameBoard(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = boards.firstIndex(where: { $0.id == id }),
              boards[index].name != trimmed else { return }
        boards[index].name = trimmed
        persist { try $0.renamePinboard(id: id, name: trimmed) }
    }

    func setBoardColor(_ id: UUID, _ color: PinboardColor) {
        guard let index = boards.firstIndex(where: { $0.id == id }), boards[index].color != color else { return }
        boards[index].color = color
        persist { try $0.setPinboardColor(id: id, color: color.rawValue) }
    }

    /// 删除标签：只在这个板里的条目随它一起删除（对齐 Paste「删除 Pinboard 及其所有内容将无法恢复」）；
    /// 同时在别的板里的条目只是少一个归属。
    func deleteBoard(_ id: UUID) {
        guard boards.contains(where: { $0.id == id }) else { return }
        let sole = Set(items.filter { $0.boards == [id] }.map(\.id))
        var next = items.filter { !sole.contains($0.id) }
        for index in next.indices { next[index].boards.remove(id) }
        boards.removeAll { $0.id == id }
        boardMembers.removeValue(forKey: id)
        if activeBoardID == id { activeBoardID = nil }
        commit(next)
        persist { try $0.deletePinboard(id: id, soleClipIDs: Array(sole)) }
    }

    /// 把一条归入标签：离开剪贴板历史流转（完整保留在标签里），豁免容量淘汰、清空历史不删。
    func pin(_ item: ClipItem, to boardID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              boards.contains(where: { $0.id == boardID }),
              !items[index].boards.contains(boardID) else { return }
        items[index].boards.insert(boardID)
        boardMembers[boardID, default: []].removeAll { $0 == item.id }
        boardMembers[boardID, default: []].insert(item.id, at: 0)
        persist { try $0.addMembership(pinboard: boardID, clip: item.id) }
        refilter(queryChanged: false)
    }

    /// 从某个标签里取出：还留在别的标签里就只是少一个归属，全部取出后回到剪贴板历史。
    func unpin(_ item: ClipItem, from boardID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              items[index].boards.contains(boardID) else { return }
        items[index].boards.remove(boardID)
        boardMembers[boardID]?.removeAll { $0 == item.id }
        persist { try $0.removeMembership(pinboard: boardID, clip: item.id) }
        refilter(queryChanged: false)
    }

    /// 设置里改了容量：立即按新策略复评（超出的现在淘汰）。
    func updateRetention(_ next: Retention) {
        guard next.maxItems != retention.maxItems || next.imageBudget != retention.imageBudget else { return }
        retention = next
        commit(items)
    }

    /// 屏幕取字：文字刚被写入剪贴板（调用方负责），这里同步 changeCount 并收进历史。
    func ingestScreenText(_ item: ClipItem) {
        lastChangeCount = NSPasteboard.general.changeCount
        ingest(item)
    }

    /// 把新的完整列表定下来：执行容量淘汰，被移走的条目同步从磁盘删除。
    private func commit(_ next: [ClipItem]) {
        let evicted = retention.evictions(next.map {
            Retention.Entry(id: $0.id, bytes: $0.bytes, isImage: $0.isImage,
                            pinned: $0.pinned, boarded: !$0.boards.isEmpty)
        })
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

    /// Esc：先清搜索词，再看标签页，最后才收起面板。
    func escape() {
        if fieldHasText || !search.raw.isEmpty {
            replaceQuery("")
        } else if activeBoardID != nil {
            activeBoardID = nil
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
        let scoped: [ClipItem]
        if let boardID = activeBoardID, boards.contains(where: { $0.id == boardID }) {
            // 标签视图：按固定顺序（新固定的在前）。
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            scoped = (boardMembers[boardID] ?? []).compactMap { byID[$0] }
        } else {
            // 剪贴板历史：归入标签的条目不在其中流转；置顶的挂在最前面（组内保持既有时序）。
            let history = items.filter { $0.boards.isEmpty }
            scoped = history.filter(\.pinned) + history.filter { !$0.pinned }
        }
        let next = search.isEmpty ? scoped : scoped.filter(search.matches)
        shown = next
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

    /// 某条的完整快照：内存里没有就从磁盘读（同步，调用方在需要时用）。
    private func fullSnapshot(of item: ClipItem) -> [[NSPasteboard.PasteboardType: Data]]? {
        if let inMemory = items.first(where: { $0.id == item.id })?.snapshot { return inMemory }
        if let archive {
            return io.sync {
                do { return try archive.snapshot(id: item.id) } catch {
                    Self.log("store: snapshot read failed: \(error)")
                    return nil
                }
            }
        }
        return item.snapshot
    }

    /// 粘贴：内存里有快照就用，否则从磁盘读回。读不到时返回 false。
    @discardableResult
    func writeToPasteboard(_ item: ClipItem) -> Bool {
        guard let snapshot = fullSnapshot(of: item), !snapshot.isEmpty else { return false }
        Paster.copyToPasteboard(snapshot)
        lastChangeCount = NSPasteboard.general.changeCount
        return true
    }

    /// 拖拽载荷用：与粘贴取的是同一份完整快照。
    func snapshotForDrag(_ item: ClipItem) -> [[NSPasteboard.PasteboardType: Data]]? {
        fullSnapshot(of: item)
    }

    // MARK: 拖放进绳

    /// 面板收到拖放：把内容当成一次"复制"收进历史（来源记为当前前台 App）。
    func acceptDrop(_ providers: [NSItemProvider]) {
        for provider in providers { loadDropped(provider) }
    }

    private func loadDropped(_ provider: NSItemProvider) {
        let colorType = NSPasteboard.PasteboardType.color.rawValue
        if provider.hasItemConformingToTypeIdentifier(colorType) {
            provider.loadDataRepresentation(forTypeIdentifier: colorType) { [weak self] data, _ in
                guard let data,
                      let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return }
                self?.ingestDropped(snapshot: [[.color: data]], color: color)
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let url = Self.url(from: item), url.isFileURL else { return }
                self?.ingestDropped(snapshot: [[.fileURL: Data(url.absoluteString.utf8)]])
            }
            return
        }
        for type in [UTType.png, .tiff] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let key: NSPasteboard.PasteboardType = type == .png ? .png : .tiff
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { [weak self] item, _ in
                let data: Data? = (item as? Data) ?? (item as? NSImage)?.tiffRepresentation
                guard let data else { return }
                self?.ingestDropped(snapshot: [[key: data]])
            }
            return
        }
        for type in [UTType.utf8PlainText, .plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { [weak self] item, _ in
                let string: String? = (item as? String) ?? (item as? NSString).map { $0 as String }
                    ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let string, !string.isEmpty else { return }
                self?.ingestDropped(snapshot: [[.string: Data(string.utf8)]])
            }
            return
        }
    }

    /// 拖放里拿到的文件 URL 可能以 URL / 字符串 / 数据三种形态出现。
    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let string = item as? String { return URL(string: string) }
        if let data = item as? Data {
            if let string = String(data: data, encoding: .utf8), let url = URL(string: string) { return url }
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        return nil
    }

    private func ingestDropped(snapshot: [[NSPasteboard.PasteboardType: Data]], color: NSColor? = nil) {
        DispatchQueue.main.async {
            guard let item = ClipItem.make(snapshot: snapshot, source: ClipSource.frontmost(), color: color) else { return }
            self.ingest(item)
        }
    }

    /// 后台读库、解缩略图，回主线程并入历史。
    private func loadArchive() {
        guard let archive else {
            Self.log("loaded 0 items from store (\(archiveNote))")
            return
        }
        io.async { [weak self] in
            var records: [ClipRecord] = []
            var boardRecords: [PinboardRecord] = []
            var memberships: [(pinboard: UUID, clip: UUID, position: Int)] = []
            do {
                records = try archive.loadRecords()
                boardRecords = try archive.loadPinboards()
                memberships = try archive.loadMemberships()
            } catch { Self.log("store: load failed: \(error)") }
            var images: [UUID: (thumb: NSImage, pixelSize: CGSize)] = [:]
            for record in records where record.kind == "image" {
                if let data = record.preview, let image = ClipItem.cardImage(from: data) { images[record.id] = image }
            }
            DispatchQueue.main.async {
                self?.adopt(records, images: images, boards: boardRecords, memberships: memberships)
            }
        }
    }

    private func adopt(_ records: [ClipRecord], images: [UUID: (thumb: NSImage, pixelSize: CGSize)],
                       boards boardRecords: [PinboardRecord], memberships: [(pinboard: UUID, clip: UUID, position: Int)]) {
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

        // 标签板与归属：条目从磁盘带回来的标签在内存里补上（它们不参与历史流转）。
        let boardIDs = Set(boardRecords.map(\.id))
        boards = boardRecords.map {
            Pinboard(id: $0.id, name: $0.name, color: PinboardColor(rawValue: $0.color) ?? .gray, position: $0.position)
        }
        var byBoard: [UUID: [(id: UUID, position: Int)]] = [:]
        var byClip: [UUID: Set<UUID>] = [:]
        for row in memberships where boardIDs.contains(row.pinboard) {
            byBoard[row.pinboard, default: []].append((row.clip, row.position))
            byClip[row.clip, default: []].insert(row.pinboard)
        }
        boardMembers = byBoard.mapValues { $0.sorted { $0.position > $1.position }.map(\.id) }
        for index in loaded.indices { loaded[index].boards = byClip[loaded[index].id] ?? [] }

        commit(items + loaded)
        if !broken.isEmpty { persist { try $0.delete(ids: broken) } }
        let kept = Set(items.map(\.id))
        Self.log("loaded \(loaded.filter { kept.contains($0.id) }.count) items from store")

        // 旧图没有 OCR 记录的，加载后静默补跑（一张接一张，后台慢慢来）。
        if let archive {
            let keptIDs = Set(loaded.map(\.id)).intersection(kept)
            for record in records where record.kind == "image" && record.ocrText == nil
                && keptIDs.contains(record.id) {
                if let data = record.preview {
                    scheduleOcr(id: record.id, imageData: data, archive: archive)
                }
            }
        }
    }

    private func persist(_ work: @escaping (ClipArchive) throws -> Void) {
        guard let archive else { return }
        io.async {
            do { try work(archive) } catch { Self.log("store: \(error)") }
        }
    }

    /// 后台跑一次 OCR：识别到文字就写库，回主线程补进内存条目（正在进行的搜索立即受益）。
    /// 没识别到文字时写空串作标记，下次启动不再重复跑。
    private func scheduleOcr(id: UUID, imageData: Data, archive: ClipArchive) {
        io.async { [weak self] in
            let text = Ocr.recognize(imageData) ?? ""
            do { try archive.setOcr(id: id, text: text) } catch {
                Self.log("store: ocr write failed: \(error)")
            }
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { self?.adoptOcr(id: id, text: text) }
        }
    }

    private func adoptOcr(id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].setOcr(text)
        if !search.isEmpty { refilter(queryChanged: false) }
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
        这是 ClipLine 的演示：复制过的内容会挂在这根绳上。

        点卡片 = 复制并粘贴回你刚才的 App；← → 选择，回车粘贴，Esc 或点空白处收起；悬停时点 × 把它摘下来，点右上角图钉把它置顶。
        顶栏的 + 新建标签；右键卡片「固定到」把条目归进标签，它就不再跟着历史流转。
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

        var demo = seeded.compactMap { $0 }
        if demo.count > 2 { demo[2].pinned = true }   // 一张置顶卡：黄铜衣夹的目测位

        // 演示标签（对齐 Paste 顶栏的「实用链接」）：两条链接卡归进去，历史里不再出现。
        let demoBoard = Pinboard(id: UUID(), name: "实用链接", color: .red, position: 0)
        let linkIDs = demo.filter { if case .link = $0.kind { return true }; return false }.map(\.id)
        if !linkIDs.isEmpty {
            boards = [demoBoard]
            boardMembers = [demoBoard.id: linkIDs]
            for index in demo.indices where linkIDs.contains(demo[index].id) {
                demo[index].boards = [demoBoard.id]
            }
        }
        freshIDs.formUnion(demo.map(\.id))
        landingIDs.formUnion(demo.map(\.id))
        commit(demo + items)
    }
}
