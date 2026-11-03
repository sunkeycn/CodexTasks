import Foundation
import CryptoKit
import CSQLite

public struct ObservedWorkspace: Equatable, Sendable {
    public var path: String
    public var branch: String?
    public var sha: String?
    public var repositoryIdentity: String?
    public init(path: String, branch: String? = nil, sha: String? = nil) {
        self.path = path; self.branch = branch; self.sha = sha
    }
}

public struct ObservedTurn: Equatable, Sendable {
    public var id: String
    public var state: RunState
    public var updatedAt: Date
    public var source: String
    public init(id: String, state: RunState, updatedAt: Date = Date(), source: String = "本机 Codex 日志") {
        self.id = id; self.state = state; self.updatedAt = updatedAt; self.source = source
    }
}

public struct ObservedSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var cwd: String
    public var taskNumber: Int?
    public var commandAt: Date?
    public var workspaces: [ObservedWorkspace]
    public var turns: [ObservedTurn]
    public var warning: String?
    public init(id: String, name: String, cwd: String, taskNumber: Int? = nil, commandAt: Date? = nil, workspaces: [ObservedWorkspace] = [], turns: [ObservedTurn] = []) {
        self.id = id; self.name = name; self.cwd = cwd; self.taskNumber = taskNumber
        self.commandAt = commandAt; self.workspaces = workspaces; self.turns = turns
    }
}

/// Read-only adapter for local Codex storage. No commands, source files or prompts are persisted.
/// Storage formats are private: unsupported schemas and missing evidence are surfaced, never guessed.
public final class LocalCodexReader: @unchecked Sendable {
    private let lock = NSLock()
    private let home: URL
    public let allowedRoot: URL
    private struct Cursor {
        var offset: UInt64 = 0
        var pending = Data()
        var taskNumber: Int?
        var commandAt: Date?
        var paths: [String] = []
        var turns: [ObservedTurn] = []
        var activeTurn: String?
        var malformed = false
        var skippingPartialLine = false
    }
    private var cursors: [String: Cursor] = [:]
    private var recentCursors: [String: Cursor] = [:]
    private var pendingHistory = false
    private var historyPaths = Set<String>()
    private var pathSessions: [String: String] = [:]
    public var hasPendingHistory: Bool { lock.lock(); defer { lock.unlock() }; return pendingHistory }
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private let plainTimestampFormatter = ISO8601DateFormatter()
    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), allowedRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WorkSpace/sunkey")) {
        self.home = codexHome.resolvingSymlinksInPath(); self.allowedRoot = allowedRoot.resolvingSymlinksInPath()
    }
    public func allows(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return canonical == allowedRoot.path || canonical.hasPrefix(allowedRoot.path + "/")
    }
    /// nil asks for discovery; a set reads only those indexed sessions.
    public func read(sessionIDs: Set<String>? = nil) throws -> [ObservedSession] {
        lock.lock(); defer { lock.unlock() }
        let candidates = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let dbURL = candidates.first else { throw WorkbenchError.missing("未找到本机 Codex 会话数据库。") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw WorkbenchError.persistence("无法只读打开 Codex 会话索引。")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        var schema: OpaquePointer?
        var columns = Set<String>()
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK {
            while sqlite3_step(schema) == SQLITE_ROW { if let name = sqlite3_column_text(schema, 1) { columns.insert(String(cString: name)) } }
        }
        sqlite3_finalize(schema)
        let titleExpression = columns.contains("name") ? "COALESCE(NULLIF(name, ''), title)" : "title"
        let ids = sessionIDs.map { Array($0).sorted() }
        if ids?.isEmpty == true { return [] }
        let filter = ids.map { " WHERE id IN (" + Array(repeating: "?", count: $0.count).joined(separator: ",") + ")" } ?? ""
        let sql = "SELECT id, \(titleExpression), cwd, rollout_path, git_branch, git_sha FROM threads" + filter + " ORDER BY updated_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw WorkbenchError.invalid("Codex 索引格式已变化，需要更新本地适配器。") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, id) in (ids ?? []).enumerated() { sqlite3_bind_text(statement, Int32(i + 1), id, -1, transient) }
        func text(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
        var result: [ObservedSession] = []
        var encounteredPaths = Set<String>()
        // Bound historical work across the entire scan, while always reading the live tail.
        var historyBudget = 2 * 1024 * 1024
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let id = text(0), cwd = text(2)
            if allows(cwd) {
                let path = URL(fileURLWithPath: text(3)).resolvingSymlinksInPath()
                var session = ObservedSession(id: id, name: text(1), cwd: cwd)
                encounteredPaths.insert(path.path)
                historyPaths.remove(path.path)
                pathSessions[path.path] = id
                let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
                pathSessions[home.appendingPathComponent("codex-tasks-status/" + hash + ".json").path] = id
                // A database row must never redirect this adapter to arbitrary files.
                if path.path.hasPrefix(home.path + "/sessions/") || path.path.hasPrefix(home.path + "/archived_sessions/") {
                    do {
                        var cursor = cursors[path.path] ?? Cursor()
                        let handle = try FileHandle(forReadingFrom: path); defer { try? handle.close() }
                        let size = try handle.seekToEnd()
                        if size < cursor.offset { cursor = Cursor() }
                        if size < (recentCursors[path.path]?.offset ?? 0) { recentCursors[path.path] = nil }
                        var recent = recentCursors[path.path]
                        if recent == nil && size > 2 * 1024 * 1024 {
                            var tail = Cursor()
                            tail.offset = size - 2 * 1024 * 1024
                            // A tail can begin in the middle of JSON (or a UTF-8 character).
                            try handle.seek(toOffset: tail.offset - 1)
                            let previous = try handle.read(upToCount: 1)
                            tail.skippingPartialLine = previous?.first != 10
                            recent = tail
                        }
                        if var tail = recent {
                            try readRecords(handle, limit: 2 * 1024 * 1024, cursor: &tail)
                            recent = tail; recentCursors[path.path] = tail
                        }
                        if cursor.offset < size && historyBudget > 0 {
                            let before = cursor.offset
                            try readRecords(handle, limit: historyBudget, cursor: &cursor)
                            historyBudget -= Int(cursor.offset - before)
                        }
                        cursors[path.path] = cursor
                        let historyComplete = cursor.offset == size
                        let liveComplete = recent.map { $0.offset == size && !$0.skippingPartialLine } ?? historyComplete
                        if historyComplete { historyPaths.remove(path.path) } else { historyPaths.insert(path.path) }
                        if !historyComplete { session.warning = "正在补齐历史上下文" }
                        else if cursor.malformed || recent?.malformed == true { session.warning = "部分日志格式无法识别" }
                        // Recent evidence is safe to publish without waiting for old logs.
                        let commandCursors: [Cursor?] = historyComplete ? [cursor, recent] : [recent]
                        let command = commandCursors.compactMap { $0 }.filter { $0.commandAt != nil }.max { $0.commandAt! < $1.commandAt! }
                        if liveComplete || historyComplete { session.taskNumber = command?.taskNumber; session.commandAt = command?.commandAt }
                        var turns = historyComplete ? cursor.turns : []
                        if liveComplete, let recent {
                            for turn in recent.turns {
                                if let i = turns.firstIndex(where: { $0.id == turn.id }) {
                                    if turns[i].updatedAt < turn.updatedAt { turns[i] = turn }
                                } else { turns.append(turn) }
                            }
                        }
                        session.turns = turns.sorted { $0.updatedAt < $1.updatedAt }
                        let modified = try path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                        if Date().timeIntervalSince(modified) > 180 {
                            for i in session.turns.indices where session.turns[i].state == .running { session.turns[i].state = .unknown }
                        }
                        session.workspaces = ([cwd] + cursor.paths + (recent?.paths ?? [])).reduce(into: []) { workspaces, path in
                            if !workspaces.contains(where: { $0.path == path }) { workspaces.append(ObservedWorkspace(path: path)) }
                        }
                    } catch { session.warning = "会话日志读取失败：\(error.localizedDescription)" }
                } else { session.warning = "日志路径超出 Codex 数据目录" }
                if session.workspaces.isEmpty { session.workspaces = [ObservedWorkspace(path: cwd)] }
                // These fields are explicitly the session's recorded Git context, not a live HEAD claim.
                if let i = session.workspaces.firstIndex(where: { $0.path == cwd }) {
                    session.workspaces[i].branch = text(4).isEmpty ? nil : text(4)
                    session.workspaces[i].sha = text(5).isEmpty ? nil : text(5)
                }
                applyHookStatus(to: &session)
                result.append(session)
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw WorkbenchError.persistence("读取 Codex 会话索引失败。") }
        if sessionIDs == nil { historyPaths.formIntersection(encounteredPaths) }
        pendingHistory = !historyPaths.isEmpty
        return result
    }
    /// A DB change needs discovery. Known log/sidecar paths can be read directly.
    public func sessionIDs(forChangedPaths paths: Set<String>) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        if paths.contains(where: { URL(fileURLWithPath: $0).deletingLastPathComponent() == home }) { return nil }
        return Set(paths.compactMap { pathSessions[$0] })
    }
    public func needsHistory(sessionIDs: Set<String>?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let sessionIDs else { return !historyPaths.isEmpty }
        return historyPaths.contains { pathSessions[$0].map { sessionIDs.contains($0) } ?? false }
    }
    public func applying(_ record: CodexHookStatus, to observed: ObservedSession) -> ObservedSession {
        lock.lock(); defer { lock.unlock() }
        var session = observed; mergeHookStatus(record, into: &session); return session
    }
    private func applyHookStatus(to session: inout ObservedSession) {
        let directory = home.appendingPathComponent("codex-tasks-status")
        let hash = SHA256.hash(data: Data(session.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(hash + ".json")
        // A sidecar never authorizes a new session or a directory outside the active workspace.
        guard file.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024,
              let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(CodexHookStatus.self, from: data),
              record.version == 1 else { return }
        mergeHookStatus(record, into: &session)
    }
    private func mergeHookStatus(_ record: CodexHookStatus, into session: inout ObservedSession) {
        guard record.version == 1, record.sessionID == session.id, !record.turnID.isEmpty, record.turnID.utf8.count <= 4096,
              allows(record.cwd), URL(fileURLWithPath: record.cwd).resolvingSymlinksInPath().path == URL(fileURLWithPath: session.cwd).resolvingSymlinksInPath().path,
              let date = timestampFormatter.date(from: record.updatedAt), date <= Date().addingTimeInterval(60) else { return }
        let state: RunState
        switch record.event {
        case "UserPromptSubmit": state = Date().timeIntervalSince(date) > 180 ? .unknown : .running
        case "Stop": state = .completed
        case "Interrupt": state = .interrupted
        default: return
        }
        let turn = ObservedTurn(id: record.turnID, state: state, updatedAt: date, source: "Codex 生命周期 Hook")
        if let i = session.turns.firstIndex(where: { $0.id == record.turnID }) {
            guard !session.turns[i].state.isTerminal, date >= session.turns[i].updatedAt else { return }
            session.turns[i] = turn
        } else {
            guard date >= (session.turns.last?.updatedAt ?? .distantPast) else { return }
            session.turns.append(turn)
        }
        session.turns.sort { $0.updatedAt < $1.updatedAt }
    }
    private func readRecords(_ handle: FileHandle, limit: Int, cursor: inout Cursor) throws {
        try handle.seek(toOffset: cursor.offset)
        let bytes = try handle.read(upToCount: limit) ?? Data()
        cursor.offset += UInt64(bytes.count); cursor.pending.append(bytes)
        var consumed = cursor.pending.startIndex
        for newline in cursor.pending.indices where cursor.pending[newline] == 10 {
            if cursor.skippingPartialLine { cursor.skippingPartialLine = false }
            else {
                let line = cursor.pending[consumed..<newline]
                if let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { consume(record, cursor: &cursor) }
                else { cursor.malformed = true }
            }
            consumed = cursor.pending.index(after: newline)
        }
        if consumed > cursor.pending.startIndex { cursor.pending = Data(cursor.pending[consumed...]) }
        if cursor.pending.count > 16 * 1024 * 1024 { throw WorkbenchError.invalid("单条日志过大，暂停解析。") }
    }
    public func inspectWorkspace(_ workspace: ObservedWorkspace) -> ObservedWorkspace {
        guard allows(workspace.path), gitAccessAllowed(workspace.path) else { return ObservedWorkspace(path: workspace.path) }
        let root = git(["rev-parse", "--show-toplevel"], at: workspace.path) ?? workspace.path
        guard allows(root) else { return workspace }
        var result = ObservedWorkspace(path: root)
        result.branch = git(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        result.sha = git(["rev-parse", "--verify", "HEAD"], at: root)
        if result.branch == nil, let sha = result.sha { result.branch = "detached/" + sha.prefix(12) }
        if let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root), allows(common) {
            result.repositoryIdentity = "git-local:" + URL(fileURLWithPath: common).resolvingSymlinksInPath().path
        }
        return result
    }
    private func gitAccessAllowed(_ path: String) -> Bool {
        var directory = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while allows(directory.path) {
            let dotgit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotgit.path, isDirectory: &isDirectory) {
                guard allows(dotgit.path) else { return false }
                var gitDirectory = dotgit
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOf: dotgit), text.hasPrefix("gitdir: ") else { return false }
                    let target = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDirectory = URL(fileURLWithPath: target, relativeTo: directory).standardizedFileURL
                }
                guard allows(gitDirectory.path) else { return false }
                let commonFile = gitDirectory.appendingPathComponent("commondir")
                guard allows(commonFile.path) else { return false }
                if let common = try? String(contentsOf: commonFile) {
                    return allows(URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDirectory).standardizedFileURL.path)
                }
                return true
            }
            directory.deleteLastPathComponent()
        }
        return false
    }
    private func git(_ arguments: [String], at path: String) -> String? {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == false ? result : nil
    }
    private func consume(_ record: [String: Any], cursor: inout Cursor) {
        guard let payload = record["payload"] as? [String: Any] else { return }
        let type = record["type"] as? String ?? ""
        // Most records are tool output; do not parse their timestamps.
        func eventDate() -> Date {
            guard let text = record["timestamp"] as? String else { return .distantPast }
            return timestampFormatter.date(from: text) ?? plainTimestampFormatter.date(from: text) ?? .distantPast
        }
        if type == "response_item", payload["type"] as? String == "message", payload["role"] as? String == "user" {
            let content = payload["content"] as? [[String: Any]] ?? []
            recordCommand(content.compactMap { $0["text"] as? String }.joined(separator: "\n"), date: eventDate(), cursor: &cursor)
        }
        if type == "turn_context" || type == "session_meta", let cwd = payload["cwd"] as? String { addPath(cwd, cursor: &cursor) }
        if type == "response_item", payload["type"] as? String == "function_call",
           let name = payload["name"] as? String, name == "exec_command" || name.hasSuffix(".exec_command"),
           let arguments = payload["arguments"] as? String,
           let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any],
           let workdir = args["workdir"] as? String { addPath(workdir, cursor: &cursor) }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
        if event == "user_message", let message = payload["message"] as? String { recordCommand(message, date: eventDate(), cursor: &cursor) }
        let turnID = payload["turn_id"] as? String ?? cursor.activeTurn
        if event == "task_started", let turnID { cursor.activeTurn = turnID }
        let state: RunState?
        switch event {
        case "task_started": state = .running
        case "task_complete", "task_completed": state = .completed
        case "turn_aborted": state = .interrupted
        default: state = nil
        }
        if let state, let turnID {
            let date = eventDate()
            if let i = cursor.turns.firstIndex(where: { $0.id == turnID }) {
                if !cursor.turns[i].state.isTerminal { cursor.turns[i] = ObservedTurn(id: turnID, state: state, updatedAt: date) }
            } else { cursor.turns.append(ObservedTurn(id: turnID, state: state, updatedAt: date)) }
        }
    }
    private func addPath(_ path: String, cursor: inout Cursor) {
        guard allows(path) else { return }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if !cursor.paths.contains(canonical) { cursor.paths.append(canonical) }
    }
    private func recordCommand(_ text: String, date: Date, cursor: inout Cursor) {
        var inFence = false
        let commandText = text.components(separatedBy: .newlines).filter { line in
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("```") || clean.hasPrefix("~~~") { inFence.toggle(); return false }
            return !inFence
        }.joined(separator: "\n")
        let pattern = #"(?m)^\s*(?:关联任务|关联Codex[ \t]+Task)\s*[【\[]\s*T[#-]([0-9]+)\s*[】\]]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: commandText, range: NSRange(commandText.startIndex..., in: commandText)) {
            if let range = Range(match.range(at: 1), in: commandText), let number = Int(commandText[range]), number > 0 {
                if date >= (cursor.commandAt ?? .distantPast) { cursor.taskNumber = number; cursor.commandAt = date }
            }
        }
    }
}
