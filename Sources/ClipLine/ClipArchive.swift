import AppKit
import SQLite3

/// 一条历史在磁盘上的样子。图标与缩略图不存，加载时重建。
struct ClipRecord {
    var id: UUID
    var fingerprint: String
    /// `text` / `link` / `code` / `color` / `image` / `files`
    var kind: String
    /// 重建卡面用的文字：正文、URL、颜色字面值、文件路径（JSON 数组）；图片为 nil。
    var payload: String?
    var title: String?
    var copiedAt: Date
    /// `app` / `continuity` / `unknown`
    var sourceKind: String
    var sourceBundleID: String?
    var sourceName: String
    var itemCount: Int
    var bytes: Int
    /// 写入时带完整快照；读出时为 nil（粘贴时再按 id 取）。
    var snapshot: [[NSPasteboard.PasteboardType: Data]]?
    /// 置顶：不会被容量淘汰，「清空历史」时保留，展示排最前。
    var pinned: Bool = false
    /// 图片条目的离线 OCR 原文（检索用）。
    var ocrText: String?
    /// 读出时附带的一份图片数据，只给图片条目重建缩略图。
    var preview: Data?
}

/// 剪贴板历史的磁盘存储：系统 SQLite3、WAL 日志，每次增删都是一个事务（崩溃时要么整条在、要么整条不在）。
/// 快照按「剪贴板项序号 × 类型」拆行存 BLOB：粘贴时整条取回，图片缩略图只读一种表示。
/// 不做线程同步：调用方必须串行使用（`ClipStore` 把它关在一条串行队列上）。
final class ClipArchive {
    static let schemaVersion: Int32 = 2

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipLine", isDirectory: true)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let fileURL: URL
    private var db: OpaquePointer?

    init(directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        fileURL = directory.appendingPathComponent("history.sqlite")
        // 先以 0600 建好库文件：SQLite 建 -wal / -shm 时沿用主库的权限位。
        if !fm.fileExists(atPath: fileURL.path),
           !fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            throw Failure(description: "cannot create \(fileURL.path)")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        guard sqlite3_open_v2(fileURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            close()
            throw Failure(description: message)
        }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA secure_delete = ON")   // 删掉的内容在库文件里清零，不留残页
        try migrate()
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: 版本与迁移

    func userVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int(stmt, 0)
    }

    private func migrate() throws {
        let version = try userVersion()
        guard version <= Self.schemaVersion else {
            throw Failure(description: "history schema v\(version) is newer than this build (v\(Self.schemaVersion)); not touching it")
        }
        if version < 1 {
            try exec("PRAGMA auto_vacuum = INCREMENTAL")   // 只能在建表前设置
            try transaction {
                try exec("""
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
                    """)
            }
        }
        if version < 2 {
            try transaction {
                try exec("""
                    ALTER TABLE clips ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
                    ALTER TABLE clips ADD COLUMN ocr_text TEXT;
                    PRAGMA user_version = 2;
                    """)
            }
        }
        // 以后的结构变化在这里逐级追加：if version < 3 { … PRAGMA user_version = 3 }
    }

    // MARK: 增删

    /// 写入一条（同指纹的旧条目在同一事务里删掉）。含敏感类型的快照一律拒绝。
    func insert(_ record: ClipRecord) throws {
        guard let snapshot = record.snapshot else { throw Failure(description: "record has no snapshot") }
        guard !ClipItem.isSensitive(snapshot.flatMap(\.keys)) else {
            throw Failure(description: "refusing to store a concealed/transient clip")
        }
        let id = record.id.uuidString
        try transaction {
            try run("DELETE FROM clips WHERE id = ? OR fingerprint = ?", [.text(id), .text(record.fingerprint)])
            try run("""
                INSERT INTO clips (id, fingerprint, kind, payload, title, copied_at,
                                   source_kind, source_bundle_id, source_name, item_count, bytes,
                                   pinned, ocr_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(id), .text(record.fingerprint), .text(record.kind), .text(record.payload),
                      .text(record.title), .real(record.copiedAt.timeIntervalSince1970),
                      .text(record.sourceKind), .text(record.sourceBundleID), .text(record.sourceName),
                      .int(snapshot.count), .int(record.bytes),
                      .int(record.pinned ? 1 : 0), .text(record.ocrText)])
            let stmt = try prepare("INSERT INTO representations (clip_id, item_index, type, data) VALUES (?, ?, ?, ?)")
            defer { sqlite3_finalize(stmt) }
            for (index, map) in snapshot.enumerated() {
                for (type, data) in map {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bind(stmt, [.text(id), .int(index), .text(type.rawValue), .blob(data)])
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
                }
            }
        }
    }

    func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids { try run("DELETE FROM clips WHERE id = ?", [.text(id.uuidString)]) }
        }
        try exec("PRAGMA incremental_vacuum")
    }

    /// 置顶 / 取消置顶。
    func setPinned(id: UUID, pinned: Bool) throws {
        try run("UPDATE clips SET pinned = ? WHERE id = ?", [.int(pinned ? 1 : 0), .text(id.uuidString)])
    }

    /// 写入（或清除）某条的 OCR 文字。
    func setOcr(id: UUID, text: String?) throws {
        try run("UPDATE clips SET ocr_text = ? WHERE id = ?", [.text(text), .text(id.uuidString)])
    }

    /// 清空历史：默认全清；`keepingPinned` 时保留置顶条目。旧内容不留在磁盘上。
    func deleteAll(keepingPinned: Bool = false) throws {
        try transaction {
            if keepingPinned {
                try run("DELETE FROM representations WHERE clip_id IN (SELECT id FROM clips WHERE pinned = 0)")
                try run("DELETE FROM clips WHERE pinned = 0")
            } else {
                try run("DELETE FROM representations")
                try run("DELETE FROM clips")
            }
        }
        try exec("PRAGMA incremental_vacuum")
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: 读取

    func count() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM clips")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 全部条目（新→旧），不带快照；图片条目附带一份 `previewTypes` 里最先找到的数据。
    func loadRecords(previewTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]) throws -> [ClipRecord] {
        let stmt = try prepare("""
            SELECT id, fingerprint, kind, payload, title, copied_at,
                   source_kind, source_bundle_id, source_name, item_count, bytes, pinned, ocr_text
            FROM clips ORDER BY copied_at DESC
            """)
        defer { sqlite3_finalize(stmt) }
        var records: [ClipRecord] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let id = text(stmt, 0).flatMap(UUID.init(uuidString:)) {
                records.append(ClipRecord(
                    id: id, fingerprint: text(stmt, 1) ?? "", kind: text(stmt, 2) ?? "",
                    payload: text(stmt, 3), title: text(stmt, 4),
                    copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    sourceKind: text(stmt, 6) ?? "unknown", sourceBundleID: text(stmt, 7),
                    sourceName: text(stmt, 8) ?? "", itemCount: Int(sqlite3_column_int64(stmt, 9)),
                    bytes: Int(sqlite3_column_int64(stmt, 10)),
                    pinned: sqlite3_column_int64(stmt, 11) != 0, ocrText: text(stmt, 12)))
            }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw failure() }

        let preview = try prepare("SELECT data FROM representations WHERE clip_id = ? AND item_index = 0 AND type = ?")
        defer { sqlite3_finalize(preview) }
        for index in records.indices where records[index].kind == "image" {
            for type in previewTypes {
                sqlite3_reset(preview)
                try bind(preview, [.text(records[index].id.uuidString), .text(type.rawValue)])
                if sqlite3_step(preview) == SQLITE_ROW {
                    records[index].preview = blob(preview, 0)
                    break
                }
            }
        }
        return records
    }

    /// 某条的完整快照；条目不存在时为 nil。
    func snapshot(id: UUID) throws -> [[NSPasteboard.PasteboardType: Data]]? {
        let head = try prepare("SELECT item_count FROM clips WHERE id = ?")
        defer { sqlite3_finalize(head) }
        try bind(head, [.text(id.uuidString)])
        guard sqlite3_step(head) == SQLITE_ROW else { return nil }
        var maps = [[NSPasteboard.PasteboardType: Data]](repeating: [:], count: max(Int(sqlite3_column_int64(head, 0)), 1))

        let stmt = try prepare("SELECT item_index, type, data FROM representations WHERE clip_id = ?")
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, [.text(id.uuidString)])
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let index = Int(sqlite3_column_int64(stmt, 0))
            if maps.indices.contains(index), let type = text(stmt, 1) {
                maps[index][NSPasteboard.PasteboardType(type)] = blob(stmt, 2)
            }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw failure() }
        return maps
    }

    // MARK: SQLite 小工具

    private enum Value {
        case text(String?)
        case real(Double)
        case int(Int)
        case blob(Data)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func failure() -> Failure {
        Failure(description: db.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ values: [Value]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .text(let string?):
                let bytes = Array(string.utf8)
                rc = bytes.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress.map { base in
                        base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                            sqlite3_bind_text64(stmt, index, $0, sqlite3_uint64(buffer.count), Self.transient,
                                                UInt8(SQLITE_UTF8))
                        }
                    } ?? sqlite3_bind_text(stmt, index, "", 0, Self.transient)
                }
            case .text(nil): rc = sqlite3_bind_null(stmt, index)
            case .real(let number): rc = sqlite3_bind_double(stmt, index, number)
            case .int(let number): rc = sqlite3_bind_int64(stmt, index, Int64(number))
            case .blob(let data):
                rc = data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return sqlite3_bind_zeroblob(stmt, index, 0) }
                    return sqlite3_bind_blob64(stmt, index, base, sqlite3_uint64(raw.count), Self.transient)
                }
            }
            guard rc == SQLITE_OK else { throw failure() }
        }
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, values)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL, let pointer = sqlite3_column_text(stmt, column) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    private func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0, let pointer = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}
