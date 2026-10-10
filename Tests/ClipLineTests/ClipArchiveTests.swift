import AppKit
import SQLite3
import XCTest
@testable import ClipLine

final class ClipArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipline-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 往返

    func testRoundTripKeepsMetadataAndSnapshot() throws {
        let png = Self.png(width: 40, height: 30)
        let gone = ClipSource(bundleID: "com.example.uninstalled", name: "Gone App", icon: nil, kind: .app)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let originals: [ClipItem] = [
            ClipItem(kind: .text("你好\u{0}World"), source: .unknown, copiedAt: base + 5,
                     snapshot: [[.string: Data("你好\u{0}World".utf8), .rtf: Data("{\\rtf1 hi}".utf8)]],
                     fingerprint: "t:你好"),
            ClipItem(kind: .link(URL(string: "https://example.com/%E4%B8%AD?q=1#x")!, title: "示例"), source: gone,
                     copiedAt: base + 4,
                     snapshot: [[.string: Data("https://example.com/%E4%B8%AD?q=1#x".utf8),
                                 NSPasteboard.PasteboardType("public.url-name"): Data("示例".utf8)]],
                     fingerprint: "t:https://example.com"),
            ClipItem(kind: .files(["/tmp/a b.txt", "/tmp/换行\n名.txt"]), source: .continuity, copiedAt: base + 3,
                     snapshot: [[.fileURL: Data("file:///tmp/a%20b.txt".utf8)], [.fileURL: Data("file:///tmp/c".utf8)], [:]],
                     fingerprint: "f:/tmp/a b.txt|/tmp/换行\n名.txt"),
            ClipItem(kind: .image(NSImage(), pixelSize: CGSize(width: 40, height: 30)), source: .unknown,
                     copiedAt: base + 2, snapshot: [[.png: png, .tiff: Data([1, 2, 3])]], fingerprint: "i:png"),
            ClipItem(kind: .color(.red, literal: "#FF7A59"), source: .unknown, copiedAt: base + 1,
                     snapshot: [[.string: Data("#FF7A59".utf8)]], fingerprint: "c:#FF7A59"),
            ClipItem(kind: .code("let a = 1\nlet b = 2"), source: .unknown, copiedAt: base,
                     snapshot: [[.string: Data("let a = 1\nlet b = 2".utf8), .init("empty"): Data()]],
                     fingerprint: "t:let"),
        ]
        do {
            let archive = try ClipArchive(directory: directory)
            for item in originals.shuffled() { try archive.insert(XCTUnwrap(item.record)) }
            archive.close()
        }

        let archive = try ClipArchive(directory: directory)
        let records = try archive.loadRecords()
        XCTAssertEqual(records.map(\.id), originals.map(\.id), "按复制时间新→旧")
        for (record, original) in zip(records, originals) {
            XCTAssertEqual(record.fingerprint, original.fingerprint)
            XCTAssertEqual(record.copiedAt, original.copiedAt)
            XCTAssertEqual(record.bytes, original.bytes)
            XCTAssertEqual(try archive.snapshot(id: record.id), original.snapshot, original.fingerprint)

            let image = record.preview.flatMap(ClipItem.cardImage(from:))
            let restored = try XCTUnwrap(ClipItem(record: record, image: image), original.fingerprint)
            XCTAssertNil(restored.snapshot, "读回的条目不常驻快照")
            XCTAssertEqual(restored.source.kind, original.source.kind)
            XCTAssertEqual(restored.source.name, original.source.name)
            XCTAssertEqual(restored.source.bundleID, original.source.bundleID)
        }

        let kinds = try records.map { try XCTUnwrap(ClipItem(record: $0, image: $0.preview.flatMap(ClipItem.cardImage(from:)))).kind }
        guard case .text(let text) = kinds[0] else { return XCTFail("text") }
        XCTAssertEqual(text, "你好\u{0}World")
        guard case .link(let url, let title) = kinds[1] else { return XCTFail("link") }
        XCTAssertEqual(url.absoluteString, "https://example.com/%E4%B8%AD?q=1#x")
        XCTAssertEqual(title, "示例")
        guard case .files(let paths) = kinds[2] else { return XCTFail("files") }
        XCTAssertEqual(paths, ["/tmp/a b.txt", "/tmp/换行\n名.txt"])
        guard case .image(_, let pixelSize) = kinds[3] else { return XCTFail("image") }
        XCTAssertEqual(pixelSize, CGSize(width: 40, height: 30))
        XCTAssertEqual(records[3].preview, png, "缩略图优先取 PNG")
        guard case .color(_, let literal) = kinds[4] else { return XCTFail("color") }
        XCTAssertEqual(literal, "#FF7A59")
        guard case .code = kinds[5] else { return XCTFail("code") }
    }

    func testPermissions() throws {
        let archive = try ClipArchive(directory: directory)
        try archive.insert(XCTUnwrap(Self.text("x").record))
        let fm = FileManager.default
        func mode(_ path: String) throws -> Int {
            try XCTUnwrap(fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try mode(directory.path), 0o700)
        XCTAssertEqual(try mode(archive.fileURL.path), 0o600)
        let wal = archive.fileURL.path + "-wal"
        if fm.fileExists(atPath: wal) { XCTAssertEqual(try mode(wal), 0o600) }
    }

    func testSchemaVersionAndNewerSchemaIsLeftAlone() throws {
        do {
            let archive = try ClipArchive(directory: directory)
            XCTAssertEqual(try archive.userVersion(), ClipArchive.schemaVersion)
            archive.close()
        }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try ClipArchive(directory: directory))
    }

    // MARK: 增删

    func testSameFingerprintReplacesOldRow() throws {
        let archive = try ClipArchive(directory: directory)
        let first = Self.text("same", ago: 10)
        let second = Self.text("same", ago: 0)
        try archive.insert(XCTUnwrap(first.record))
        try archive.insert(XCTUnwrap(second.record))
        XCTAssertEqual(try archive.count(), 1)
        XCTAssertEqual(try archive.loadRecords().first?.id, second.id)
        XCTAssertNil(try archive.snapshot(id: first.id))
    }

    func testDeleteAndClear() throws {
        let archive = try ClipArchive(directory: directory)
        let items = (0..<5).map { Self.text("item \($0)", ago: Double($0)) }
        for item in items { try archive.insert(XCTUnwrap(item.record)) }
        try archive.delete(ids: [items[1].id, items[3].id])
        XCTAssertEqual(try archive.loadRecords().map(\.id), [items[0].id, items[2].id, items[4].id])
        XCTAssertNil(try archive.snapshot(id: items[1].id))
        try archive.deleteAll()
        XCTAssertEqual(try archive.count(), 0)
        XCTAssertEqual(try archive.loadRecords().count, 0)
    }

    func testRefusesConcealedSnapshots() throws {
        let archive = try ClipArchive(directory: directory)
        let secret = ClipItem(kind: .text("hunter2"), source: .unknown, copiedAt: Date(),
                              snapshot: [[.string: Data("hunter2".utf8),
                                          .init("org.nspasteboard.ConcealedType"): Data()]],
                              fingerprint: "t:hunter2")
        XCTAssertThrowsError(try archive.insert(XCTUnwrap(secret.record)))
        XCTAssertEqual(try archive.count(), 0)
    }

    // MARK: 与 ClipStore 联动

    func testStoreEvictsOldestAndPersistsIncrementally() throws {
        let archive = try ClipArchive(directory: directory)
        let store = ClipStore(archive: archive, retention: Retention(maxItems: 3, imageBudget: .max, maxStoredBytes: .max))
        let items = (0..<5).map { Self.text("clip \($0)", ago: Double(10 - $0)) }
        for item in items { store.ingest(item) }
        XCTAssertEqual(store.items.map(\.id), [items[4].id, items[3].id, items[2].id])
        XCTAssertTrue(store.items.allSatisfy { $0.snapshot == nil }, "写盘后内存不留快照")
        store.flush()

        let reader = try ClipArchive(directory: directory)
        XCTAssertEqual(try reader.loadRecords().map(\.id), [items[4].id, items[3].id, items[2].id])

        store.remove(store.items[1])
        store.flush()
        XCTAssertEqual(try reader.loadRecords().map(\.id), [items[4].id, items[2].id])

        store.clearHistory()
        store.flush()
        XCTAssertEqual(try reader.count(), 0)
    }

    func testOversizedClipStaysInMemoryOnly() throws {
        let archive = try ClipArchive(directory: directory)
        let store = ClipStore(archive: archive, retention: Retention(maxItems: 10, imageBudget: .max, maxStoredBytes: 4))
        let big = Self.text("too large for disk")
        store.ingest(big)
        store.flush()
        XCTAssertNotNil(store.items.first?.snapshot)
        XCTAssertEqual(try archive.count(), 0)
    }

    // MARK: 工具

    static func text(_ string: String, ago: TimeInterval = 0) -> ClipItem {
        ClipItem(kind: .text(string), source: .unknown, copiedAt: Date() - ago,
                 snapshot: [[.string: Data(string.utf8)]], fingerprint: "t:" + string)
    }

    static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
}
