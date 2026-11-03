import Foundation
import CSQLite

/// Reads only Codex's index and session logs; never visits a repository or invokes Git.
public final class CodexReader: @unchecked Sendable {
    private let home: URL
    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let plain = ISO8601DateFormatter()
    private struct Cursor {
        var historyOffset: UInt64 = 0
        var historyEnd: UInt64 = 0
        var historyPending = Data()
        var historyDropping = false
        var liveOffset: UInt64 = 0
        var livePending = Data()
        var liveDropping = false
        var inode: UInt64 = 0
        var modified = Date.distantPast
        var taskNumber: Int64?
        var commandAt: Date?
        var commandPosition: UInt64 = 0
        var state = SessionStatus.unknown
        var stateAt = Date.distantPast
        var statePosition: UInt64 = 0
    }
    private var cursors: [String: Cursor] = [:]
    public private(set) var hasPendingReads = false
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.home = home.resolvingSymlinksInPath()
    }
    public func read(notBefore: Date = .distantPast, linkedSessionIDs: Set<String> = []) throws -> [ObservedSession] {
        lock.lock(); defer { lock.unlock() }
        let candidates = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let index = candidates.first else { throw LiteError.message("未找到本机 Codex 会话。启动 Codex 后可关联会话。") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw LiteError.message("暂时无法读取本机 Codex 会话索引。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var schema: OpaquePointer?, columns = Set<String>()
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK else { throw LiteError.message("无法读取 Codex 会话结构。") }
        while sqlite3_step(schema) == SQLITE_ROW {
            if let value = sqlite3_column_text(schema, 1) { columns.insert(String(cString: value)) }
        }
        sqlite3_finalize(schema)
        guard Set(["id", "title", "rollout_path", "updated_at"]).isSubset(of: columns) else { throw LiteError.message("Codex 会话索引格式已变化，需要更新读取组件。") }
        let title = columns.contains("name") ? "COALESCE(NULLIF(name,''),title)" : "title"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,\(title),rollout_path,updated_at FROM threads ORDER BY updated_at DESC,id", -1, &s, nil) == SQLITE_OK else { throw LiteError.message("无法读取 Codex 会话列表。") }
        defer { sqlite3_finalize(s) }
        func text(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        var result: [ObservedSession] = []
        var budget = 4 * 1024 * 1024
        hasPendingReads = false
        var code = sqlite3_step(s)
        while code == SQLITE_ROW {
            let id = text(0), rawTime = sqlite3_column_double(s, 3)
            // The desktop index has used both epoch seconds and milliseconds.
            let updated = Date(timeIntervalSince1970: rawTime > 100_000_000_000 ? rawTime / 1000 : rawTime)
            var observed = ObservedSession(id: id, title: text(1).isEmpty ? "Codex Session" : text(1), updatedAt: updated)
            let path = URL(fileURLWithPath: text(2)).resolvingSymlinksInPath().standardizedFileURL
            if isLog(path) && (updated >= notBefore || linkedSessionIDs.contains(id)) {
                do {
                    var cursor = cursors[path.path] ?? Cursor()
                    try readLog(path, cursor: &cursor, budget: &budget, includeHistory: updated >= notBefore)
                    cursors[path.path] = cursor
                    observed.taskNumber = cursor.taskNumber; observed.commandAt = cursor.commandAt
                    observed.status = cursor.state
                    if observed.status == .running && Date().timeIntervalSince(cursor.modified) > 180 { observed.status = .unknown }
                } catch {
                    // A missing/unreadable log must not turn a previously running session into a fake completion.
                    if let cursor = cursors[path.path] { observed.taskNumber = cursor.taskNumber; observed.commandAt = cursor.commandAt }
                    observed.status = .unknown
                }
            }
            result.append(observed)
            code = sqlite3_step(s)
        }
        guard code == SQLITE_DONE else { throw LiteError.message("Codex 会话索引读取未完成，将稍后重试。") }
        return result
    }
    private func isLog(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" && (url.path.hasPrefix(home.path + "/sessions/") || url.path.hasPrefix(home.path + "/archived_sessions/"))
    }
    private func readLog(_ url: URL, cursor: inout Cursor, budget: inout Int, includeHistory: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        if cursor.inode != inode || size < cursor.liveOffset || (size == cursor.liveOffset && modified != cursor.modified) {
            cursor = Cursor(); cursor.inode = inode
        }
        let needsLive = cursor.liveOffset < size
        let needsHistory = cursor.historyOffset < cursor.historyEnd
        guard needsLive || needsHistory else { cursor.modified = modified; return }
        guard budget > 0 else { hasPendingReads = true; return }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        // Read the live tail before filling older history so current state is available quickly.
        if needsLive {
            let count = min(budget, 512 * 1024)
            let start = max(cursor.liveOffset, size > UInt64(count) ? size - UInt64(count) : 0)
            if start > cursor.liveOffset {
                cursor.historyEnd = start
                cursor.livePending.removeAll(); cursor.liveDropping = true
            }
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(size - start)) ?? Data()
            budget -= data.count
            var pending = cursor.livePending, dropping = cursor.liveDropping
            consume(data, pending: &pending, dropping: &dropping, endingAt: start + UInt64(data.count), cursor: &cursor)
            cursor.livePending = pending; cursor.liveDropping = dropping
            cursor.liveOffset = start + UInt64(data.count)
        }
        if !includeHistory { cursor.historyOffset = cursor.historyEnd; cursor.historyPending.removeAll() }
        if cursor.historyOffset < cursor.historyEnd && budget > 0 {
            try handle.seek(toOffset: cursor.historyOffset)
            let count = Int(min(UInt64(min(budget, 256 * 1024)), cursor.historyEnd - cursor.historyOffset))
            let data = try handle.read(upToCount: count) ?? Data()
            cursor.historyOffset += UInt64(data.count); budget -= data.count
            var pending = cursor.historyPending, dropping = cursor.historyDropping
            consume(data, pending: &pending, dropping: &dropping, endingAt: cursor.historyOffset, cursor: &cursor)
            cursor.historyPending = pending; cursor.historyDropping = dropping
            if cursor.historyOffset == cursor.historyEnd {
                // Stitch the line split at the tail boundary without treating it as a separate event.
                try handle.seek(toOffset: cursor.historyEnd)
                let suffix = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if let newline = suffix.firstIndex(of: 10) {
                    var pending = cursor.historyPending, dropping = cursor.historyDropping
                    consume(Data(suffix[...newline]), pending: &pending, dropping: &dropping, endingAt: cursor.historyEnd + UInt64(newline + 1), cursor: &cursor)
                }
                cursor.historyPending.removeAll()
            }
        }
        cursor.modified = modified
        if cursor.historyOffset < cursor.historyEnd || cursor.liveOffset < size { hasPendingReads = true }
    }
    private func consume(_ data: Data, pending: inout Data, dropping: inout Bool, endingAt end: UInt64, cursor: inout Cursor) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let position = end - UInt64(pending.count) + UInt64(pending.distance(from: pending.startIndex, to: newline))
            if !dropping && pending.distance(from: pending.startIndex, to: newline) <= 1024 * 1024 {
                let line = Data(pending[..<newline])
                if let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { consume(record, position: position, cursor: &cursor) }
            }
            pending.removeSubrange(...newline); dropping = false
        }
        if pending.count > 1024 * 1024 { pending.removeAll(); dropping = true }
    }
    private func consume(_ record: [String: Any], position: UInt64, cursor: inout Cursor) {
        guard let payload = record["payload"] as? [String: Any], let timestamp = record["timestamp"] as? String,
              let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp) else { return }
        let type = record["type"] as? String
        if type == "response_item", payload["type"] as? String == "message", payload["role"] as? String == "user" {
            let content = payload["content"] as? [[String: Any]] ?? []
            command(content.compactMap { $0["text"] as? String }.joined(separator: "\n"), at: date, position: position, cursor: &cursor)
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
        if event == "user_message", let message = payload["message"] as? String { command(message, at: date, position: position, cursor: &cursor) }
        let status: SessionStatus?
        switch event {
        case "task_started": status = .running
        case "task_complete", "task_completed": status = .completed
        case "turn_aborted": status = .interrupted
        case "turn_failed", "task_failed": status = .failed
        default: status = nil
        }
        if let status, date > cursor.stateAt || (date == cursor.stateAt && position >= cursor.statePosition) {
            cursor.state = status; cursor.stateAt = date; cursor.statePosition = position
        }
    }
    private func command(_ text: String, at date: Date, position: UInt64, cursor: inout Cursor) {
        guard date > (cursor.commandAt ?? .distantPast) || (date == cursor.commandAt && position >= cursor.commandPosition) else { return }
        var fence: String?
        for line in text.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("```") || clean.hasPrefix("~~~") {
                let marker = String(clean.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil else { continue }
            let pattern = #"^(?:关联任务|关联Codex[ \t]+Task)[ \t]*[【\[][ \t]*T[#-]([0-9]+)[ \t]*[】\]][ \t]*$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
                  let range = Range(match.range(at: 1), in: clean), let number = Int64(clean[range]), number > 0 else { continue }
            cursor.taskNumber = number; cursor.commandAt = date; cursor.commandPosition = position
        }
    }
}
