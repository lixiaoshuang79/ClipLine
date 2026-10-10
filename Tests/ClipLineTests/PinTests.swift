import AppKit
import SQLite3
import XCTest
@testable import ClipLine

final class PinTests: XCTestCase {
    private static func textItem(_ text: String, at seconds: TimeInterval, pinned: Bool = false) -> ClipItem {
        ClipItem(kind: .text(text), source: .unknown, copiedAt: Date(timeIntervalSince1970: seconds),
                 snapshot: [[.string: Data(text.utf8)]], fingerprint: "t:" + text, pinned: pinned)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clipline-pin-tests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: 淘汰豁免

    func testPinnedSurvivesCountCap() {
        var list = (0..<7).map { _ in Retention.Entry(id: UUID(), bytes: 10, isImage: false) }
        list[5].pinned = true
        let evicted = Retention(maxItems: 5, imageBudget: .max, maxStoredBytes: .max).evictions(list)
        XCTAssertFalse(evicted.contains(list[5].id), "置顶条目不参与条数淘汰")
        XCTAssertEqual(evicted, [list[6].id], "非置顶的按最旧淘汰")
    }

    func testPinnedImageIgnoredByBudget() {
        var list = [
            Retention.Entry(id: UUID(), bytes: 80, isImage: true),
            Retention.Entry(id: UUID(), bytes: 5, isImage: false),
            Retention.Entry(id: UUID(), bytes: 50, isImage: true),
            Retention.Entry(id: UUID(), bytes: 50, isImage: true),
        ]
        list[0].pinned = true
        let evicted = Retention(maxItems: 100, imageBudget: 60, maxStoredBytes: .max).evictions(list)
        XCTAssertFalse(evicted.contains(list[0].id), "置顶图不占预算")
        XCTAssertEqual(evicted, [list[3].id])
    }

    // MARK: 存储往返

    func testPinRoundTripAndSetPinned() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = Self.textItem("置顶我", at: 1_800_000_000, pinned: true)
        let archive = try ClipArchive(directory: directory)
        try archive.insert(XCTUnwrap(item.record))
        var records = try archive.loadRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].pinned)
        try archive.setPinned(id: item.id, pinned: false)
        records = try archive.loadRecords()
        XCTAssertFalse(records[0].pinned)
        archive.close()
    }

    func testClearKeepingPinned() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ClipArchive(directory: directory)
        let keep = Self.textItem("keep", at: 2, pinned: true)
        let drop = Self.textItem("drop", at: 1)
        try archive.insert(XCTUnwrap(keep.record))
        try archive.insert(XCTUnwrap(drop.record))
        try archive.deleteAll(keepingPinned: true)
        var records = try archive.loadRecords()
        XCTAssertEqual(records.map(\.fingerprint), ["t:keep"])
        XCTAssertTrue(records[0].pinned)
        try archive.deleteAll()
        records = try archive.loadRecords()
        XCTAssertTrue(records.isEmpty)
        archive.close()
    }

    // MARK: v1 → v2 迁移

    func testMigratesV1Database() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
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
            bytes INTEGER NOT NULL
        );
        CREATE INDEX clips_by_time ON clips(copied_at);
        CREATE TABLE representations (
            clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
            item_index INTEGER NOT NULL,
            type TEXT NOT NULL,
            data BLOB NOT NULL,
            PRIMARY KEY (clip_id, item_index, type)
        );
        PRAGMA user_version = 1;
        INSERT INTO clips VALUES ('11111111-1111-1111-1111-111111111111','t:hi','text','hi',NULL,1800000000,'unknown',NULL,'未知来源',1,2);
        INSERT INTO representations VALUES ('11111111-1111-1111-1111-111111111111',0,'public.utf8-plain-text',X'6869');
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let archive = try ClipArchive(directory: directory)
        XCTAssertEqual(try archive.userVersion(), 2)
        let records = try archive.loadRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertFalse(records[0].pinned)
        XCTAssertNil(records[0].ocrText)
        XCTAssertEqual(try archive.snapshot(id: records[0].id)?.first?[.string], Data("hi".utf8))
        archive.close()
    }

    // MARK: Store 行为

    func testStoreOrdersPinnedFirst() {
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("ccc", at: 1))
        store.ingest(Self.textItem("bbb", at: 2))
        store.ingest(Self.textItem("aaa", at: 3))
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:aaa", "t:bbb", "t:ccc"])

        store.togglePin(store.shown[2])   // 置顶最旧的 ccc
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:ccc", "t:aaa", "t:bbb"])
        XCTAssertTrue(store.shown[0].pinned)

        store.togglePin(store.shown[0])   // 取消
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:aaa", "t:bbb", "t:ccc"])
    }

    func testRecopyKeepsPin() {
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("hello", at: 1))
        store.togglePin(store.shown[0])
        store.ingest(Self.textItem("other", at: 2))
        XCTAssertEqual(store.shown.map(\.fingerprint), ["t:hello", "t:other"], "置顶的排最前")

        store.ingest(Self.textItem("hello", at: 3))   // 同内容再复制一次
        XCTAssertEqual(store.shown.count, 2)
        XCTAssertEqual(store.shown.first?.fingerprint, "t:hello")
        XCTAssertTrue(store.shown[0].pinned, "置顶状态跟着新副本走")
    }

    func testClearHistoryKeepsPinnedInMemory() {
        let store = ClipStore(archive: nil)
        store.ingest(Self.textItem("keep", at: 1))
        store.ingest(Self.textItem("drop", at: 2))
        let keep = store.items.first { $0.fingerprint == "t:keep" }!
        store.togglePin(keep)
        store.clearHistory()
        XCTAssertEqual(store.items.map(\.fingerprint), ["t:keep"])
        XCTAssertTrue(store.items[0].pinned)
    }
}
