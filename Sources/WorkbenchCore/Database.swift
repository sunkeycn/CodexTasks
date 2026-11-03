import Foundation
import CSQLite

final class Database {
    private var connection: OpaquePointer?
    private let lock = NSRecursiveLock()
    let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let reason = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库无法打开"
            if let connection { sqlite3_close(connection) }
            connection = nil
            throw WorkbenchError.persistence(reason)
        }
        do {
            sqlite3_busy_timeout(connection, 5000)
            let version = try scalar("PRAGMA user_version")
            guard version <= 2 else { throw WorkbenchError.persistence("数据库来自更新版本（\(version)），请使用新版工作台；原数据未改动。") }
            if version == 0 {
                let tables = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                if tables > 0 {
                    let backup = url.deletingLastPathComponent().appendingPathComponent("before-migration-\(UUID().uuidString).sqlite")
                    try self.backup(to: backup)
                    throw WorkbenchError.persistence("检测到未知旧版数据结构，已备份但未迁移。请先明确来源格式。")
                }
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE document (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, payload BLOB NOT NULL)")
                    try write(WorkbenchSnapshot(), insert: true)
                    try execute("PRAGMA user_version=1")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            if version < 2 {
                let backupURL = url.deletingLastPathComponent().appendingPathComponent("before-cicd-v2-\(UUID().uuidString).sqlite")
                try backup(to: backupURL)
                // Additive optional CICD payload; all task/workspace data remains intact.
                try execute("BEGIN IMMEDIATE")
                do {
                    _ = try read()
                    try execute("PRAGMA user_version=2")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            _ = try read()
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }
    deinit { if let connection { sqlite3_close(connection) } }

    func snapshot() throws -> WorkbenchSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try read()
    }
    func transaction<T>(_ body: (inout WorkbenchSnapshot) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            var snapshot = try read()
            let previous = snapshot
            let result = try body(&snapshot)
            if snapshot != previous { try write(snapshot, insert: false) }
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    func backup(to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw WorkbenchError.invalid("备份目标已存在，请使用新文件名。") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var target: OpaquePointer?
        guard sqlite3_open(destination.path, &target) == SQLITE_OK, let target else {
            if let target { sqlite3_close(target) }
            throw WorkbenchError.persistence("无法创建备份文件。")
        }
        defer { sqlite3_close(target) }
        guard let handle = sqlite3_backup_init(target, "main", connection, "main") else { throw WorkbenchError.persistence("无法开始一致性备份。") }
        let result = sqlite3_backup_step(handle, -1)
        let finish = sqlite3_backup_finish(handle)
        guard result == SQLITE_DONE, finish == SQLITE_OK else {
            try? FileManager.default.removeItem(at: destination)
            throw WorkbenchError.persistence("备份未完成，请稍后重试。")
        }
    }
    private func read() throws -> WorkbenchSnapshot {
        let stmt = try prepare("SELECT payload FROM document WHERE id=1")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw failure("任务数据缺失") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
        do { return try decoder.decode(WorkbenchSnapshot.self, from: data) }
        catch { throw WorkbenchError.persistence("任务数据无法解析。请保留数据库并从备份恢复；工作台不会覆盖原数据。") }
    }
    private func write(_ snapshot: WorkbenchSnapshot, insert: Bool) throws {
        let data = try encoder.encode(snapshot)
        let stmt = try prepare(insert ? "INSERT INTO document(id, revision, payload) VALUES(1, 1, ?)" : "UPDATE document SET revision=revision+1, payload=? WHERE id=1")
        defer { sqlite3_finalize(stmt) }
        let status = data.withUnsafeBytes { raw in sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), transient) }
        guard status == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw failure("保存失败，显示状态未提交") }
        guard sqlite3_changes(connection) == 1 else { throw failure("保存未生效") }
    }
    private func scalar(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure("数据库检查失败") }
        return Int(sqlite3_column_int(stmt, 0))
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure("数据库操作失败") }
        return stmt
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure("数据库操作失败") }
    }
    private func failure(_ prefix: String) -> WorkbenchError {
        .persistence("\(prefix)：\(String(cString: sqlite3_errmsg(connection)))")
    }
}
