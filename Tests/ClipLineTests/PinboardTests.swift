import AppKit
import SQLite3
import XCTest
@testable import ClipLine

/// 标签板（对齐 Paste 的 Pinboard）：自建标签、条目归类、离开历史流转的存储与 store 行为。
final class PinboardTests: XCTestCase {
    private static func textItem(_ text: String, at seconds: TimeInterval) -> ClipItem {
        ClipItem(kind: .text(text), source: .unknown, copiedAt: Date(timeIntervalSince1970: seconds),
                 snapshot: [[.string: Data(text.utf8)]], fingerprint: "t:" + text)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clipline-board-tests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: 存储往返

    func testPinboardCRUDRoundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = PinboardRecord(id: UUID(), name: "实用链接", color: "red", position: 0)
        do {
            let archive = try ClipArchive(directory: directory)
            try archive.insertPinboard(board)
            try archive.renamePinboard(id: board.id, name: "工作")
            try archive.setPinboardColor(id: board.id, color: "blue")
            archive.close()
        }
        let archive = try ClipArchive(directory: directory)
        let boards = try archive.loadPinboards()
        XCTAssertEqual(boards.count, 1)
        XCTAssertEqual(boards[0].id, board.id)
        XCTAssertEqual(boards[0].name, "工作")
        XCTAssertEqual(boards[0].color, "blue")
        archive.close()
    }

    func testMembershipRoundTripOrdersByPosition() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = Self.textItem("甲", at: 1_800_000_000)
        let second = Self.textItem("乙", at: 1_800_000_001)
        let board = PinboardRecord(id: UUID(), name: "B", color: "green", position: 0)
        do {
            let archive = try ClipArchive(directory: directory)
            try archive.insert(XCTUnwrap(item.record))
            try archive.insert(XCTUnwrap(second.record))
            try archive.insertPinboard(board)
            try archive.addMembership(pinboard: board.id, clip: item.id)
            try archive.addMembership(pinboard: board.id, clip: item.id)   // 重复添加只留一行
            try archive.addMembership(pinboard: board.id, clip: second.id)
            archive.close()
        }
        let archive = try ClipArchive(directory: directory)
        var rows = try archive.loadMemberships()
        XCTAssertEqual(rows.count, 2)
        let byClip = Dictionary(uniqueKeysWithValues: rows.map { ($0.clip, $0.position) })
        XCTAssertLessThan(byClip[item.id]!, byClip[second.id]!, "后加入的序号更大")
        try archive.removeMembership(pinboard: board.id, clip: item.id)
        rows = try archive.loadMemberships()
        XCTAssertEqual(rows.map(\.clip), [second.id])
        archive.close()
    }

    func testDeletePinboardCascadesSoleItems() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sole = Self.textItem("只有一个标签", at: 1_800_000_000)
        let shared = Self.textItem("两个标签共有", at: 1_800_000_001)
        let a = PinboardRecord(id: UUID(), name: "A", color: "red", position: 0)
        let b = PinboardRecord(id: UUID(), name: "B", color: "blue", position: 1)
        let archive = try ClipArchive(directory: directory)
        try archive.insert(XCTUnwrap(sole.record))
        try archive.insert(XCTUnwrap(shared.record))
        try archive.insertPinboard(a)
        try archive.insertPinboard(b)
        try archive.addMembership(pinboard: a.id, clip: sole.id)
        try archive.addMembership(pinboard: a.id, clip: shared.id)
        try archive.addMembership(pinboard: b.id, clip: shared.id)

        try archive.deletePinboard(id: a.id, soleClipIDs: [sole.id])

        XCTAssertEqual(try archive.loadRecords().map(\.id), [shared.id], "专属条目随标签删除，共享条目保留")
        XCTAssertEqual(try archive.loadMemberships().map(\.clip), [shared.id], "删标签时级联清掉它的归属行")
        XCTAssertEqual(try archive.loadPinboards().map(\.id), [b.id])
        archive.close()
    }

    func testClearKeepsPinnedAndBoarded() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinned = Self.textItem("置顶", at: 1_800_000_000)
        let boarded = Self.textItem("在标签里", at: 1_800_000_001)
        let plain = Self.textItem("普通", at: 1_800_000_002)
        let board = PinboardRecord(id: UUID(), name: "B", color: "gray", position: 0)
        let archive = try ClipArchive(directory: directory)
        try archive.insert(XCTUnwrap(pinned.record))
        try archive.insert(XCTUnwrap(boarded.record))
        try archive.insert(XCTUnwrap(plain.record))
        try archive.setPinned(id: pinned.id, pinned: true)
        try archive.insertPinboard(board)
        try archive.addMembership(pinboard: board.id, clip: boarded.id)

        try archive.deleteAll(keepingPinned: true)

        XCTAssertEqual(Set(try archive.loadRecords().map(\.id)), [pinned.id, boarded.id],
                       "置顶与已归入标签的条目都不被清空")
        XCTAssertEqual(try archive.loadMemberships().map(\.clip), [boarded.id], "归属行保留")
        archive.close()
    }

    func testV2MigratesToV3() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.sqlite")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE clips (
            id TEXT PRIMARY KEY NOT NULL,
            fingerprint TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            payload TEXT,
            title TEXT,
            copied_at REAL NOT NULL,
            source_kind TEXT NOT NULL,
            source_bundle_id TEXT,
            source_name TEXT NOT NULL,
            item_count INTEGER NOT NULL,
            bytes INTEGER NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            ocr_text TEXT
        );
        CREATE INDEX clips_by_time ON clips(copied_at);
        CREATE TABLE representations (
            clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
            item_index INTEGER NOT NULL,
            type TEXT NOT NULL,
            data BLOB NOT NULL,
            PRIMARY KEY (clip_id, item_index, type)
        );
        PRAGMA user_version = 2;
        INSERT INTO clips VALUES ('11111111-1111-1111-1111-111111111111','t:hi','text','hi',NULL,1800000000,'unknown',NULL,'未知来源',1,2,0,NULL);
        INSERT INTO representations VALUES ('11111111-1111-1111-1111-111111111111',0,'public.utf8-plain-text',X'6869');
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let archive = try ClipArchive(directory: directory)
        XCTAssertEqual(try archive.userVersion(), 3)
        XCTAssertEqual(try archive.loadRecords().count, 1, "老数据还在")
        XCTAssertEqual(try archive.loadPinboards().count, 0)
        XCTAssertEqual(try archive.loadMemberships().count, 0)
        archive.close()
    }

    // MARK: 淘汰豁免

    func testBoardedSurvivesCountCap() {
        var list = (0..<7).map { _ in Retention.Entry(id: UUID(), bytes: 10, isImage: false) }
        list[3].boarded = true
        let evicted = Retention(maxItems: 5, imageBudget: .max, maxStoredBytes: .max).evictions(list)
        XCTAssertFalse(evicted.contains(list[3].id), "已归入标签的条目不参与淘汰")
        XCTAssertEqual(evicted, [list[6].id])
    }

    // MARK: Store 行为

    func testPinMovesItemOutOfHistory() {
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("甲", at: 1))
        store.ingest(Self.textItem("乙", at: 2))
        let board = store.addBoard(name: " 工作 ")
        XCTAssertEqual(board.name, "工作")
        XCTAssertEqual(store.activeBoardID, board.id, "新建后切到新标签")
        XCTAssertTrue(store.shown.isEmpty, "新标签是空的")
        store.activeBoardID = nil
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙", "t:甲"])

        let jia = store.items.first { $0.fingerprint == "t:甲" }!
        store.pin(jia, to: board.id)
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙"], "固定后离开剪贴板历史")

        store.activeBoardID = board.id
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:甲"], "标签里看得到")

        store.unpin(jia, from: board.id)
        XCTAssertTrue(store.shown.isEmpty, "取出来后标签空了")
        store.activeBoardID = nil
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙", "t:甲"], "回到剪贴板历史")
    }

    func testSwitchingBoardStartsFromFirstCard() {
        // 回归：换标签页只重新过滤、不滚动，停在上一页的滚动位置，选中的第一张可能在视口外。
        let store = ClipStore(archive: nil)
        for index in 0..<5 { store.ingest(Self.textItem("条目\(index)", at: TimeInterval(index))) }
        let board = store.addBoard(name: "B")
        store.pin(store.items[3], to: board.id)
        store.pin(store.items[4], to: board.id)
        store.activeBoardID = nil
        store.select(offset: 2)   // 历史里往右翻了几张
        let serial = store.scrollRequest?.serial

        store.activeBoardID = board.id
        XCTAssertEqual(store.selectedID, store.shown.first?.id, "选中标签里的第一张")
        XCTAssertEqual(store.scrollRequest?.target, .start, "滚回开头")
        XCTAssertNotEqual(store.scrollRequest?.serial, serial)

        store.select(offset: 1)
        store.activeBoardID = nil
        XCTAssertEqual(store.selectedID, store.shown.first?.id, "回到历史同样从头看")
        XCTAssertEqual(store.scrollRequest?.target, .start)
    }

    func testBoardViewOrdersNewestPinFirst() {
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("甲", at: 1))
        store.ingest(Self.textItem("乙", at: 2))
        let board = store.addBoard(name: "收集")
        let jia = store.items.first { $0.fingerprint == "t:甲" }!
        let yi = store.items.first { $0.fingerprint == "t:乙" }!
        store.pin(jia, to: board.id)
        store.pin(yi, to: board.id)
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙", "t:甲"], "后固定的排在前面")
    }

    func testDeleteBoardDeletesSoleItemsKeepsShared() {
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("甲", at: 1))
        store.ingest(Self.textItem("乙", at: 2))
        let a = store.addBoard(name: "A")
        let b = store.addBoard(name: "B")
        let jia = store.items.first { $0.fingerprint == "t:甲" }!
        let yi = store.items.first { $0.fingerprint == "t:乙" }!
        store.pin(jia, to: a.id)
        store.pin(yi, to: a.id)
        store.pin(yi, to: b.id)

        store.deleteBoard(a.id)
        XCTAssertEqual(store.boards.map(\.id), [b.id])
        XCTAssertEqual(store.activeBoardID, b.id, "删的不是当前标签时视图不动")
        XCTAssertEqual(store.items.map(\.fingerprint), ["t:乙"], "专属条目随标签删除，共享条目保留")
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙"])

        store.deleteBoard(b.id)
        XCTAssertNil(store.activeBoardID, "删的是当前标签时回到剪贴板历史")
        XCTAssertTrue(store.items.isEmpty, "乙只剩这一个标签，随它一起删")
    }

    func testClearHistoryKeepsBoardedItems() {
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("甲", at: 1))
        store.ingest(Self.textItem("乙", at: 2))
        let board = store.addBoard(name: "B")
        let jia = store.items.first { $0.fingerprint == "t:甲" }!
        store.pin(jia, to: board.id)
        store.activeBoardID = nil
        store.clearHistory()
        XCTAssertEqual(store.items.map(\.fingerprint), ["t:甲"], "清空历史保留标签里的条目")
        store.activeBoardID = board.id
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:甲"])
    }

    func testClearableCountMatchesClearHistory() {
        // 回归：清空确认框只按置顶计数，标签里的条目被算进「将删除」；只剩标签条目时菜单项仍可点却什么也不删。
        let store = ClipStore(archive: nil)
        for (offset, text) in ["甲", "乙", "丙"].enumerated() {
            store.ingest(Self.textItem(text, at: TimeInterval(offset)))
        }
        let board = store.addBoard(name: "B")
        store.pin(store.items.first { $0.fingerprint == "t:甲" }!, to: board.id)
        store.togglePin(store.items.first { $0.fingerprint == "t:乙" }!)
        XCTAssertEqual(store.clearableCount, 1, "置顶与标签条目都不算可清")

        store.clearHistory()
        XCTAssertEqual(store.items.count, 2, "删掉的正好是 clearableCount 条")
        XCTAssertEqual(store.clearableCount, 0)
    }

    func testRecopyKeepsBoardMembership() {
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("甲", at: 1))
        let board = store.addBoard(name: "B")
        let jia = store.items.first { $0.fingerprint == "t:甲" }!
        store.pin(jia, to: board.id)
        store.activeBoardID = nil

        store.ingest(Self.textItem("丙", at: 3))   // 中间复制点别的
        store.ingest(Self.textItem("甲", at: 4))   // 同一内容重新复制

        XCTAssertEqual(store.items.count, 2, "同指纹仍只留一条")
        let renewed = store.items.first { $0.fingerprint == "t:甲" }!
        XCTAssertEqual(renewed.boards, [board.id], "标签归属跟着新副本走")
        XCTAssertEqual(store.items[0].fingerprint, "t:甲", "新副本在历史列表最前")
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:丙"], "仍不回到历史显示")
        store.activeBoardID = board.id
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:甲"])
    }

    func testRecopyPersistsBoardMembership() throws {
        // 回归：归属重挂曾排在转存之前，撞 pinboard_items 的外键（新行还没落库），重启后归属丢失。
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ClipArchive(directory: directory)
        let store = ClipStore(archive: archive)
        store.ingest(Self.textItem("甲", at: 1))
        let board = store.addBoard(name: "B")
        let jia = store.items.first { $0.fingerprint == "t:甲" }!
        store.pin(jia, to: board.id)
        store.ingest(Self.textItem("丙", at: 3))
        store.flush()
        store.ingest(Self.textItem("甲", at: 4))   // 重新复制
        store.flush()

        let renewed = store.items.first { $0.fingerprint == "t:甲" }!
        XCTAssertNotEqual(renewed.id, jia.id, "换成了新副本")
        let check = try ClipArchive(directory: directory)
        let rows = try check.loadMemberships()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.pinboard, board.id)
        XCTAssertEqual(rows.first?.clip, renewed.id, "磁盘上的归属指向新行")
        XCTAssertEqual(try check.loadPinboards().count, 1)
        check.close()
        store.close()
    }

    func testRecopyKeepsBoardOrderAcrossRestart() throws {
        // 回归：重新复制标签里的条目，内存里新副本留在原位，磁盘上却按「最新固定」重挂（position = max+1），
        // 重启后它跳到了标签最前面。
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipStore(archive: try ClipArchive(directory: directory))
        store.ingest(Self.textItem("甲", at: 1))
        store.ingest(Self.textItem("乙", at: 2))
        let board = store.addBoard(name: "B")
        store.pin(store.items.first { $0.fingerprint == "t:甲" }!, to: board.id)
        store.pin(store.items.first { $0.fingerprint == "t:乙" }!, to: board.id)
        store.ingest(Self.textItem("甲", at: 3))   // 重新复制先固定的那条
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙", "t:甲"], "内存里新副本留在原位")
        store.close()

        let reopened = ClipStore(archive: try ClipArchive(directory: directory))
        reopened.loadArchive()
        let deadline = Date().addingTimeInterval(5)
        while reopened.boards.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        reopened.activeBoardID = board.id
        XCTAssertEqual(reopened.shown.map(\.fingerprint), ["t:乙", "t:甲"], "重启后标签内顺序不变")
        reopened.close()
    }

    func testCopyDuringLaunchKeepsPinAndBoardOfDiskCopy() throws {
        // 回归：启动读库期间又复制了磁盘上已有的内容——新副本转存时顶掉旧行（级联清掉归属），
        // 并入历史时旧行又被当成重复跳过，置顶与标签就都丢了。
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var old = Self.textItem("甲", at: 1)
        old.pinned = true
        let board = PinboardRecord(id: UUID(), name: "B", color: "red", position: 0)
        do {
            let archive = try ClipArchive(directory: directory)
            try archive.insert(XCTUnwrap(old.record))
            try archive.insertPinboard(board)
            try archive.addMembership(pinboard: board.id, clip: old.id)
            archive.close()
        }

        let store = ClipStore(archive: try ClipArchive(directory: directory))
        store.loadArchive()                        // 读库在 io 上排队，并入历史要回主线程
        store.ingest(Self.textItem("甲", at: 5))    // 加载窗口里重新复制了一遍
        let early = store.addBoard(name: "早建")    // 加载完成前新建的标签
        let renewedID = store.items[0].id
        let deadline = Date().addingTimeInterval(5)
        while store.boards.count < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        store.flush()

        XCTAssertEqual(Set(store.boards.map(\.id)), [board.id, early.id], "磁盘上的标签与加载前新建的标签都在")
        XCTAssertEqual(store.items.map(\.id), [renewedID], "同指纹仍只留新副本")
        XCTAssertTrue(store.items[0].pinned, "置顶跟着新副本走")
        XCTAssertEqual(store.items[0].boards, [board.id], "标签归属跟着新副本走")
        store.activeBoardID = board.id
        XCTAssertEqual(store.shown.map(\.id), [renewedID])

        let check = try ClipArchive(directory: directory)
        let records = try check.loadRecords()
        XCTAssertEqual(records.map(\.id), [renewedID])
        XCTAssertEqual(records.first?.pinned, true, "磁盘上的置顶补写到新行")
        XCTAssertEqual(try check.loadMemberships().map(\.clip), [renewedID], "磁盘上的归属指向新行")
        check.close()
        store.close()
    }

    func testEmptyHintWhenAllHistoryIsBoarded() {
        // 回归：条目全部归入标签后历史页是空的，空态却按 `items` 非空走成了「没有匹配「」 Esc 清除」。
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("甲", at: 1))
        let board = store.addBoard(name: "B")
        store.pin(store.items[0], to: board.id)
        store.activeBoardID = nil
        XCTAssertTrue(store.shown.isEmpty)
        var hint = PastePanelView.emptyHint(for: store)
        XCTAssertEqual(hint.text, "复制点什么，它就会出现在这里")
        XCTAssertNil(hint.detail)
        XCTAssertTrue(LineView.ropeIsBare(store), "绳式同样按空绳提示、收起搜索胶囊")

        store.replaceQuery("乙")
        hint = PastePanelView.emptyHint(for: store)
        XCTAssertEqual(hint.text, "没有匹配「乙」")
        XCTAssertEqual(hint.detail, "Esc 清除")
        XCTAssertFalse(LineView.ropeIsBare(store))

        store.activeBoardID = board.id
        store.replaceQuery("")
        XCTAssertEqual(store.shown.count, 1)
        store.unpin(store.items[0], from: board.id)
        XCTAssertEqual(PastePanelView.emptyHint(for: store).text, "「B」还是空的")
    }

    func testDefaultViewCanIncludeBoardedItems() {
        // 绳式默认「全部」：已归入标签的条目照常挂在绳上；底部面板默认不显示。
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("甲", at: 1))
        store.ingest(Self.textItem("乙", at: 2))
        let board = store.addBoard(name: "B")
        let jia = store.items.first { $0.fingerprint == "t:甲" }!
        store.pin(jia, to: board.id)
        store.activeBoardID = nil
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙"], "底部面板默认：标签条目不在历史里")
        store.defaultViewIncludesBoarded = true
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙", "t:甲"], "绳式默认「全部」：含已归标签的条目")
        store.activeBoardID = board.id
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:甲"], "切换控件选标签：只看它")
        store.activeBoardID = nil
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:乙", "t:甲"], "切回「全部」")
    }

    func testBoardColorCyclesPalette() {
        let store = ClipStore(archive: nil)
        XCTAssertEqual(store.addBoard(name: "一").color, .red)
        XCTAssertEqual(store.addBoard(name: "二").color, .orange)
        store.setBoardColor(store.boards[0].id, .purple)
        XCTAssertEqual(store.boards[0].color, .purple)
        XCTAssertEqual(store.addBoard(name: "三").color, .yellow, "颜色按已有数量顺延（改色不影响计数）")
    }
}
