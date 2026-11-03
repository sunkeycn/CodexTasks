import Foundation
import CSQLite

/// The lite database owns only tasks and sessions. It never opens or migrates the full database.
public final class TaskStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw LiteError.message("无法打开轻量版任务数据库。")
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            let version = try scalar("PRAGMA user_version")
            let applicationID = try scalar("PRAGMA application_id")
            guard (version == 0 && applicationID == 0) || ((1...3).contains(version) && applicationID == 0x43544C54) else {
                throw LiteError.message("该文件不是受支持的轻量版数据库，已停止读取。")
            }
            if version == 0 {
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                    throw LiteError.message("检测到旧版或未知数据库，请使用独立的轻量版数据目录。")
                }
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE tasks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL CHECK(length(trim(title)) > 0),
                    status TEXT NOT NULL CHECK(status IN ('todo','doing','done')) DEFAULT 'todo',
                    created_at REAL NOT NULL
                );
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('idle','running','completed','interrupted','failed','unknown')),
                    updated_at REAL NOT NULL,
                    bound_at REAL NOT NULL
                );
                CREATE INDEX sessions_by_task ON sessions(task_id, updated_at DESC);
                PRAGMA application_id=1129598036;
                PRAGMA user_version=1;
                COMMIT;
                """)
            }
            // Additive migration: existing tasks, IDs, statuses and associations stay intact.
            // Recheck under the write lock so simultaneous openers cannot migrate twice.
            try transaction {
                if try scalar("PRAGMA user_version") == 1 {
                    try execute("""
                    ALTER TABLE tasks ADD COLUMN parent_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL;
                    CREATE INDEX tasks_by_parent ON tasks(parent_id,id);
                    CREATE TRIGGER tasks_single_level_insert BEFORE INSERT ON tasks
                    WHEN NEW.parent_id IS NOT NULL AND
                      (NEW.parent_id = NEW.id OR NOT EXISTS (SELECT 1 FROM tasks WHERE id=NEW.parent_id AND parent_id IS NULL))
                    BEGIN SELECT RAISE(ABORT, 'Only one level of subtasks is supported'); END;
                    CREATE TRIGGER tasks_single_level_update BEFORE UPDATE OF parent_id ON tasks
                    WHEN NEW.parent_id IS NOT NULL AND
                      (NEW.parent_id = NEW.id OR NOT EXISTS (SELECT 1 FROM tasks WHERE id=NEW.parent_id AND parent_id IS NULL)
                       OR EXISTS (SELECT 1 FROM tasks WHERE parent_id=NEW.id))
                    BEGIN SELECT RAISE(ABORT, 'Only one level of subtasks is supported'); END;
                    PRAGMA user_version=2;
                    """)
                }
                if try scalar("PRAGMA user_version") == 2 {
                    try execute("""
                    ALTER TABLE tasks ADD COLUMN unread_completion INTEGER NOT NULL DEFAULT 0 CHECK(unread_completion IN (0,1));
                    PRAGMA user_version=3;
                    """)
                }
            }
            try execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        } catch {
            sqlite3_close(db); db = nil; throw error
        }
    }
    deinit { sqlite3_close(db) }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw databaseError() }
        return result
    }
    private func databaseError() -> LiteError {
        .message("任务数据库操作失败：" + String(cString: sqlite3_errmsg(db)))
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        let s = try statement(sql); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw databaseError() }
        return sqlite3_column_int64(s, 0)
    }
    private func text(_ s: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(s, index).map { String(cString: $0) } ?? ""
    }
    private func bind(_ value: String, _ s: OpaquePointer, _ index: Int32) { sqlite3_bind_text(s, index, value, -1, transient) }
    private func finish(_ s: OpaquePointer) throws {
        guard sqlite3_step(s) == SQLITE_DONE else { throw databaseError() }
    }
    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let value = try operation(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func snapshot() throws -> TaskSnapshot {
        // One read transaction keeps the two tables consistent across connections.
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN")
        do {
            var tasks: [TaskItem] = [], sessions: [SessionItem] = []
            let t = try statement("SELECT id,title,status,created_at,parent_id,unread_completion FROM tasks ORDER BY id ASC")
            defer { sqlite3_finalize(t) }
            var code = sqlite3_step(t)
            while code == SQLITE_ROW {
                tasks.append(TaskItem(id: sqlite3_column_int64(t, 0), title: text(t, 1), status: TaskStatus(rawValue: text(t, 2)) ?? .todo, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(t, 3)), parentID: sqlite3_column_type(t, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(t, 4), hasUnreadCompletion: sqlite3_column_int(t, 5) != 0))
                code = sqlite3_step(t)
            }
            guard code == SQLITE_DONE else { throw databaseError() }
            let s = try statement("SELECT id,task_id,title,status,updated_at,bound_at FROM sessions ORDER BY bound_at ASC,id")
            defer { sqlite3_finalize(s) }
            code = sqlite3_step(s)
            while code == SQLITE_ROW {
                sessions.append(SessionItem(id: text(s, 0), taskID: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 1), title: text(s, 2), status: SessionStatus(rawValue: text(s, 3)) ?? .unknown, updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 4)), boundAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 5))))
                code = sqlite3_step(s)
            }
            guard code == SQLITE_DONE else { throw databaseError() }
            try execute("COMMIT")
            return TaskSnapshot(tasks: tasks, sessions: sessions)
        } catch { try? execute("ROLLBACK"); throw error }
    }
    @discardableResult public func createTask(title: String, parentID: Int64? = nil, at date: Date = Date()) throws -> Int64 {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LiteError.message("请先输入任务内容。") }
        return try transaction {
            if let parentID {
                let parent = try statement("SELECT parent_id FROM tasks WHERE id=?"); defer { sqlite3_finalize(parent) }
                sqlite3_bind_int64(parent, 1, parentID)
                guard sqlite3_step(parent) == SQLITE_ROW else { throw LiteError.message("父任务不存在，无法创建子任务。") }
                guard sqlite3_column_type(parent, 0) == SQLITE_NULL else { throw LiteError.message("只支持一层子任务，不能在子任务下继续创建。") }
            }
            let s = try statement("INSERT INTO tasks(title,created_at,parent_id) VALUES (?,?,?)"); defer { sqlite3_finalize(s) }
            bind(clean, s, 1); sqlite3_bind_double(s, 2, date.timeIntervalSince1970)
            if let parentID { sqlite3_bind_int64(s, 3, parentID) } else { sqlite3_bind_null(s, 3) }
            try finish(s)
            return sqlite3_last_insert_rowid(db)
        }
    }
    public func markTaskRead(_ id: Int64) throws {
        try transaction {
            let s = try statement("UPDATE tasks SET unread_completion=0 WHERE id=?"); defer { sqlite3_finalize(s) }
            sqlite3_bind_int64(s, 1, id); try finish(s)
        }
    }
    public func renameTask(_ id: Int64, title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LiteError.message("任务名称不能为空。") }
        try transaction {
            let s = try statement("UPDATE tasks SET title=? WHERE id=?"); defer { sqlite3_finalize(s) }
            bind(clean, s, 1); sqlite3_bind_int64(s, 2, id); try finish(s)
        }
    }
    public func setStatus(_ id: Int64, _ status: TaskStatus) throws {
        try transaction {
            let s = try statement("UPDATE tasks SET status=? WHERE id=?"); defer { sqlite3_finalize(s) }
            bind(status.rawValue, s, 1); sqlite3_bind_int64(s, 2, id); try finish(s)
        }
    }
    public func deleteTask(_ id: Int64, at date: Date = Date()) throws {
        try transaction {
            // Keep an unbound session tombstone so older commands cannot undo a manual deletion.
            let unbind = try statement("UPDATE sessions SET task_id=NULL,bound_at=MAX(bound_at,?) WHERE task_id=?")
            defer { sqlite3_finalize(unbind) }
            sqlite3_bind_double(unbind, 1, date.timeIntervalSince1970); sqlite3_bind_int64(unbind, 2, id); try finish(unbind)
            let s = try statement("DELETE FROM tasks WHERE id=?"); defer { sqlite3_finalize(s) }
            sqlite3_bind_int64(s, 1, id); try finish(s)
        }
    }
    public func attach(_ observed: ObservedSession, to taskID: Int64, at date: Date = Date()) throws {
        try transaction { try upsert(observed, taskID: taskID, boundAt: date) }
    }
    public func detach(_ sessionID: String, at date: Date = Date()) throws {
        try transaction {
            let s = try statement("UPDATE sessions SET task_id=NULL,bound_at=? WHERE id=?"); defer { sqlite3_finalize(s) }
            sqlite3_bind_double(s, 1, date.timeIntervalSince1970); bind(sessionID, s, 2); try finish(s)
        }
    }
    private func upsert(_ observed: ObservedSession, taskID: Int64?, boundAt: Date) throws {
        let s = try statement("""
        INSERT INTO sessions(id,task_id,title,status,updated_at,bound_at) VALUES (?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET task_id=excluded.task_id,
        title=CASE WHEN excluded.updated_at>=sessions.updated_at THEN excluded.title ELSE sessions.title END,
        status=CASE WHEN excluded.updated_at>=sessions.updated_at THEN excluded.status ELSE sessions.status END,
        updated_at=MAX(sessions.updated_at,excluded.updated_at),bound_at=excluded.bound_at
        """)
        defer { sqlite3_finalize(s) }
        bind(observed.id, s, 1)
        if let taskID { sqlite3_bind_int64(s, 2, taskID) } else { sqlite3_bind_null(s, 2) }
        bind(observed.title.isEmpty ? "Codex Session" : observed.title, s, 3)
        bind(observed.status.rawValue, s, 4)
        sqlite3_bind_double(s, 5, observed.updatedAt.timeIntervalSince1970)
        sqlite3_bind_double(s, 6, boundAt.timeIntervalSince1970)
        try finish(s)
    }
    /// Newer explicit user commands may reassign one session. Other sessions on that task stay attached.
    public func reconcile(_ observations: [ObservedSession]) throws {
        try transaction {
            var tasks: [Int64: Date] = [:], bindings: [String: (Int64?, Date, SessionStatus, Date)] = [:]
            let t = try statement("SELECT id,created_at FROM tasks"); defer { sqlite3_finalize(t) }
            while sqlite3_step(t) == SQLITE_ROW { tasks[sqlite3_column_int64(t, 0)] = Date(timeIntervalSince1970: sqlite3_column_double(t, 1)) }
            let s = try statement("SELECT id,task_id,bound_at,status,updated_at FROM sessions"); defer { sqlite3_finalize(s) }
            while sqlite3_step(s) == SQLITE_ROW {
                bindings[text(s, 0)] = (sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 1), Date(timeIntervalSince1970: sqlite3_column_double(s, 2)), SessionStatus(rawValue: text(s, 3)) ?? .unknown, Date(timeIntervalSince1970: sqlite3_column_double(s, 4)))
            }
            for observed in observations {
                let previous = bindings[observed.id]
                var binding: (Int64?, Date)? = previous.map { ($0.0, $0.1) }
                if let number = observed.taskNumber, let commandAt = observed.commandAt,
                   let createdAt = tasks[number], commandAt >= createdAt,
                   binding == nil || commandAt > binding!.1 {
                    binding = (number, commandAt)
                }
                guard let binding else { continue }
                if let taskID = binding.0, let previous, previous.0 == taskID,
                   previous.2 == .running, observed.status == .completed, observed.updatedAt >= previous.3 {
                    let unread = try statement("UPDATE tasks SET unread_completion=1 WHERE id=?")
                    defer { sqlite3_finalize(unread) }
                    sqlite3_bind_int64(unread, 1, taskID); try finish(unread)
                }
                try upsert(observed, taskID: binding.0, boundAt: binding.1)
                if let previous, previous.3 > observed.updatedAt {
                    bindings[observed.id] = (binding.0, binding.1, previous.2, previous.3)
                } else {
                    bindings[observed.id] = (binding.0, binding.1, observed.status, observed.updatedAt)
                }
            }
        }
    }
}
