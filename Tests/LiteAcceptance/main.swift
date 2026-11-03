import Foundation
import LiteCore
import CSQLite

var checks: [String: Bool] = [:]
var failures: [String] = []
func check(_ name: String, _ test: @autoclosure () throws -> Bool) {
    do { let passed = try test(); checks[name] = passed; if !passed { failures.append(name) }; print("\(passed ? "PASS" : "FAIL") \(name)") }
    catch { checks[name] = false; failures.append("\(name): \(error)"); print("FAIL \(name): \(error)") }
}
func sql(_ url: URL, _ query: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw LiteError.message("fixture open failed") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw LiteError.message(String(cString: sqlite3_errmsg(db))) }
}
func scalar(_ url: URL, _ query: String) throws -> Int {
    var db: OpaquePointer?, s: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw LiteError.message("read failed") }
    defer { sqlite3_finalize(s); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, query, -1, &s, nil) == SQLITE_OK, sqlite3_step(s) == SQLITE_ROW else { throw LiteError.message("query failed: " + String(cString: sqlite3_errmsg(db))) }
    return Int(sqlite3_column_int64(s, 0))
}
func rejected(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-tasks-lite-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let base = Date(timeIntervalSince1970: 1_800_000_000)
let url = root.appendingPathComponent("tasks.sqlite")
let store = try TaskStore(url: url)
let first = try store.createTask(title: "  任务一  ", at: base)
let second = try store.createTask(title: "任务二", at: base)
check("new-schema-has-only-task-and-session", try scalar(url, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 2)
check("blank-task-rejected", rejected { _ = try store.createTask(title: " \n ") })
check("task-title-trimmed", try store.snapshot().tasks.first { $0.id == first }?.title == "任务一")
check("display-number", try store.snapshot().tasks.first { $0.id == first }?.number == "T#01")
var a = ObservedSession(id: UUID().uuidString, title: "会话 A", status: .running, updatedAt: base.addingTimeInterval(3), taskNumber: first, commandAt: base.addingTimeInterval(1))
var b = ObservedSession(id: UUID().uuidString, title: "会话 B", status: .completed, updatedAt: base.addingTimeInterval(3), taskNumber: first, commandAt: base.addingTimeInterval(2))
try store.reconcile([a,b])
check("one-task-many-sessions", try store.snapshot().sessions(for: first).count == 2)
check("session-states-independent", try Set(store.snapshot().sessions(for: first).map(\.status)) == [.running,.completed])
try store.setStatus(first, .done)
a.status = .failed; a.title = "新会话名称"
try store.reconcile([a,b])
check("session-update-does-not-change-task-status", try store.snapshot().tasks.first { $0.id == first }?.status == .done)
check("session-name-and-state-refresh", try store.snapshot().sessions.first { $0.id == a.id }?.title == "新会话名称" && store.snapshot().sessions.first { $0.id == a.id }?.status == .failed)
try store.detach(a.id, at: base.addingTimeInterval(10))
try store.reconcile([a,b])
check("detach-not-undone-by-old-command", try store.snapshot().sessions(for: first).count == 1)
a.commandAt = base.addingTimeInterval(11)
try store.reconcile([a])
check("new-user-command-can-reattach", try store.snapshot().sessions(for: first).count == 2)
a.taskNumber = second; a.commandAt = base.addingTimeInterval(12)
try store.reconcile([a])
check("move-session-leaves-other-sessions", try store.snapshot().sessions(for: second).count == 1 && store.snapshot().sessions(for: first).map(\.id) == [b.id])
try store.attach(a, to: first, at: base.addingTimeInterval(20))
try store.reconcile([a])
check("manual-binding-beats-older-automatic-command", try store.snapshot().sessions(for: first).count == 2)
var stale = ObservedSession(id: UUID().uuidString, title: "旧指令", taskNumber: first, commandAt: base.addingTimeInterval(-1))
try store.reconcile([stale])
check("commands-predating-task-are-ignored", try !store.snapshot().sessions.contains { $0.id == stale.id })
check("invalid-task-foreign-key-rejected", rejected { try store.attach(stale, to: 99999) })
check("failed-write-rolls-back", try !store.snapshot().sessions.contains { $0.id == stale.id })
let reloaded = try TaskStore(url: url)
check("restart-preserves-relations-and-state", try reloaded.snapshot() == store.snapshot())
try reloaded.renameTask(first, title: "重命名")
check("separate-connections-see-updates", try store.snapshot().tasks.first { $0.id == first }?.title == "重命名")
try store.deleteTask(first)
check("task-delete-cascades-only-local-session-metadata", try store.snapshot().sessions.allSatisfy { $0.taskID == nil })
try store.reconcile([a,b])
check("deleted-task-not-resurrected", try store.snapshot().sessions.allSatisfy { $0.taskID == nil })
let third = try store.createTask(title: "任务三")
check("task-number-never-reused", third > second)
let oldURL = root.appendingPathComponent("legacy.sqlite")
try sql(oldURL, "CREATE TABLE legacy(data TEXT); INSERT INTO legacy VALUES('unchanged'); PRAGMA user_version=1;")
check("legacy-database-rejected", rejected { _ = try TaskStore(url: oldURL) })
check("legacy-database-left-intact", try scalar(oldURL, "SELECT count(*) FROM legacy") == 1)
let unknownURL = root.appendingPathComponent("unknown.sqlite")
try sql(unknownURL, "CREATE TABLE unknown(data TEXT);")
check("unknown-schema-not-overwritten", rejected { _ = try TaskStore(url: unknownURL) })
let futureURL = root.appendingPathComponent("future.sqlite")
try sql(futureURL, "PRAGMA user_version=99;")
check("future-schema-rejected", rejected { _ = try TaskStore(url: futureURL) })

// One-level hierarchy and a real v1 -> v2 migration, in isolated databases.
let treeURL = root.appendingPathComponent("tree.sqlite")
let tree = try TaskStore(url: treeURL)
let parent = try tree.createTask(title: "父任务", at: base)
let otherRoot = try tree.createTask(title: "另一个主任务", at: base)
let child = try tree.createTask(title: "子任务", parentID: parent, at: base)
let sibling = try tree.createTask(title: "第二个子任务", parentID: parent, at: base)
check("subtask-persists-parent", try tree.snapshot().children(of: parent).map(\.id) == [child, sibling])
check("tree-order-groups-children-under-parent", try tree.snapshot().outlineTasks.map(\.id) == [parent, child, sibling, otherRoot])
check("third-level-rejected", rejected { _ = try tree.createTask(title: "孙任务", parentID: child) })
check("missing-parent-rejected", rejected { _ = try tree.createTask(title: "孤立子任务", parentID: 99999) })
check("database-rejects-third-level", rejected { try sql(treeURL, "INSERT INTO tasks(title,created_at,parent_id) VALUES('invalid',0,\(child));") })
check("database-rejects-self-parent", rejected { try sql(treeURL, "UPDATE tasks SET parent_id=id WHERE id=\(otherRoot);") })
check("database-rejects-reparenting-with-children", rejected { try sql(treeURL, "UPDATE tasks SET parent_id=\(otherRoot) WHERE id=\(parent);") })
let childSession = ObservedSession(id: UUID().uuidString, title: "子任务会话", taskNumber: child, commandAt: base.addingTimeInterval(1))
try tree.reconcile([childSession])
try tree.setStatus(child, .done)
check("subtask-state-and-session-independent", try tree.snapshot().tasks.first { $0.id == parent }?.status == .todo && tree.snapshot().sessions(for: child).count == 1)
let treeReloaded = try TaskStore(url: treeURL)
check("tree-survives-reopen", try treeReloaded.snapshot() == tree.snapshot())
try tree.deleteTask(parent)
check("delete-parent-promotes-children", try tree.snapshot().rootTasks.map(\.id) == [otherRoot, child, sibling])
check("delete-parent-preserves-child-sessions", try tree.snapshot().sessions(for: child).count == 1)
try tree.deleteTask(child)
try tree.reconcile([childSession])
check("delete-child-does-not-affect-sibling", try tree.snapshot().tasks.map(\.id) == [otherRoot, sibling] && tree.snapshot().sessions.allSatisfy { $0.taskID == nil })
let migrationURL = root.appendingPathComponent("lite-v1.sqlite")
try sql(migrationURL, """
CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'todo',created_at REAL NOT NULL);
CREATE TABLE sessions(id TEXT PRIMARY KEY,task_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE,title TEXT NOT NULL,status TEXT NOT NULL,updated_at REAL NOT NULL,bound_at REAL NOT NULL);
CREATE INDEX sessions_by_task ON sessions(task_id,updated_at DESC);
INSERT INTO tasks(id,title,status,created_at) VALUES(7,'保留原任务','doing',1800000000);
INSERT INTO sessions VALUES('legacy-session',7,'保留会话','running',1800000001,1800000001);
PRAGMA application_id=1129598036;
PRAGMA user_version=1;
""")
let migrated = try TaskStore(url: migrationURL)
let migratedSnapshot = try migrated.snapshot()
check("migration-upgrades-to-schema-two", try scalar(migrationURL, "PRAGMA user_version") == 2)
check("migration-preserves-old-task", migratedSnapshot.rootTasks.first?.id == 7 && migratedSnapshot.rootTasks.first?.status == .doing && migratedSnapshot.rootTasks.first?.title == "保留原任务")
check("migration-preserves-session-binding", try migrated.snapshot().sessions(for: 7).first?.id == "legacy-session")
let migratedChild = try migrated.createTask(title: "升级后子任务", parentID: 7)
check("migration-preserves-sequence-and-adds-subtasks", try migrated.snapshot().children(of: 7).map(\.id) == [8] && migratedChild == 8)
check("migration-reopen-is-idempotent", try TaskStore(url: migrationURL).snapshot() == migrated.snapshot())

// Synthetic Codex index and logs: no real user session or repository is needed.
let home = root.appendingPathComponent("codex")
let logs = home.appendingPathComponent("sessions")
try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
let index = home.appendingPathComponent("state_5.sqlite")
try sql(index, "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,name TEXT,rollout_path TEXT,updated_at REAL,cwd TEXT);")
let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func event(_ type: String, _ payload: [String: Any], at time: Double = 0) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["timestamp": iso.string(from: base.addingTimeInterval(time)), "type": type, "payload": payload], options: [.sortedKeys])
    data.append(10); return data
}
func add(_ path: URL, _ data: Data) throws {
    let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }
    try handle.seekToEnd(); try handle.write(contentsOf: data)
}
func fixture(_ title: String, _ data: Data, cwd: String = "/unopened/repository", logOverride: URL? = nil) throws -> (String, URL) {
    let id = UUID().uuidString
    let log = logs.appendingPathComponent(id + ".jsonl")
    try data.write(to: log)
    try sql(index, "INSERT INTO threads VALUES('\(id)','\(title)',NULL,'\((logOverride ?? log).path)',1800000000,'\(cwd)')")
    return (id, log)
}
let commandA = try event("event_msg", ["type":"user_message","message":"实现任务\n关联任务【T#03】"], at: 1)
let (idA, logA) = try fixture("A", commandA + event("event_msg", ["type":"task_started","turn_id":"one"], at: 2), cwd: "/Users/example/WorkSpace/namespace-a/project")
let (idB, _) = try fixture("B", event("response_item", ["type":"message","role":"user","content":[["text":"关联Codex Task【T#03】"]]], at: 3) + event("event_msg", ["type":"task_complete","turn_id":"two"], at: 4), cwd: "/Users/example/WorkSpace/namespace-b/project")
let reader = CodexReader(home: home)
var observations = try reader.read()
check("all-indexed-sessions-without-workspace-filter", observations.count == 2)
check("both-user-message-formats-link-same-task", observations.allSatisfy { $0.taskNumber == 3 })
check("lifecycle-event-states", observations.first { $0.id == idA }?.status == .running && observations.first { $0.id == idB }?.status == .completed)
try add(logA, event("event_msg", ["type":"task_complete","turn_id":"one"], at: 5))
observations = try reader.read()
check("incremental-tail-completion", observations.first { $0.id == idA }?.status == .completed)
try add(logA, event("event_msg", ["type":"task_started","turn_id":"three"], at: 6))
observations = try reader.read()
check("new-turn-can-run-after-completion", observations.first { $0.id == idA }?.status == .running)
try sql(index, "UPDATE threads SET name='桌面改名' WHERE id='\(idA)'")
check("desktop-name-preferred-over-title", try reader.read().first { $0.id == idA }?.title == "桌面改名")
let (ignoredID, _) = try fixture("ignore", event("response_item", ["type":"message","role":"assistant","content":[["text":"关联任务【T#99】"]]], at: 10) + event("event_msg", ["type":"user_message","message":"```\n关联任务【T#99】\n```\n> 关联任务【T#99】\n示例关联任务【T#99】"], at: 11))
check("assistant-code-and-quoted-commands-ignored", try reader.read().first { $0.id == ignoredID }?.taskNumber == nil)
let outside = root.appendingPathComponent("outside.jsonl")
try commandA.write(to: outside)
let (outsideID, _) = try fixture("outside", Data(), logOverride: outside)
check("index-cannot-redirect-reader-outside-codex-logs", try reader.read().first { $0.id == outsideID }?.taskNumber == nil)
let (splitID, splitLog) = try fixture("partial", Data())
let split = try event("event_msg", ["type":"user_message","message":"关联任务【T#44】"], at: 12)
try add(splitLog, Data(split.prefix(split.count / 2)))
check("partial-line-not-published", try reader.read().first { $0.id == splitID }?.taskNumber == nil)
try add(splitLog, Data(split.dropFirst(split.count / 2)))
check("partial-line-completes-on-next-read", try reader.read().first { $0.id == splitID }?.taskNumber == 44)
try event("event_msg", ["type":"turn_aborted"], at: 14).write(to: splitLog)
check("truncated-log-resets-cursor", try reader.read().first { $0.id == splitID }?.status == .interrupted)
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: logA.path)
check("stale-running-event-is-unknown", try reader.read().first { $0.id == idA }?.status == .unknown)
// A large history contains old commands; the live tail always wins as history catches up.
var big = try event("event_msg", ["type":"user_message","message":"关联任务【T#77】"], at: 1)
let padding = try event("response_item", ["type":"function_call_output","output":String(repeating: "x", count: 16384)])
for _ in 0..<350 { big.append(padding) }
big.append(try event("event_msg", ["type":"user_message","message":"关联任务【T#88】"], at: 20))
big.append(try event("event_msg", ["type":"task_complete","turn_id":"large"], at: 21))
let (bigID, _) = try fixture("large", big)
observations = try reader.read()
check("large-log-live-tail-read-first", observations.first { $0.id == bigID }?.taskNumber == 88 && observations.first { $0.id == bigID }?.status == .completed)
var passes = 0
while reader.hasPendingReads && passes < 50 { observations = try reader.read(); passes += 1 }
check("large-history-eventually-catches-up", !reader.hasPendingReads)
check("old-history-does-not-overwrite-latest-command", observations.first { $0.id == bigID }?.taskNumber == 88 && observations.first { $0.id == bigID }?.status == .completed)
let (historicalID, _) = try fixture("historical-association", commandA + Data(repeating: 32, count: 700_000) + Data([10]) + event("event_msg", ["type":"task_complete"], at: 30))
observations = try reader.read()
passes = 0
while reader.hasPendingReads && passes < 50 { observations = try reader.read(); passes += 1 }
check("association-found-outside-live-tail", observations.first { $0.id == historicalID }?.taskNumber == 3)
check("completion-without-turn-id-not-guessed-running", observations.first { $0.id == historicalID }?.status == .completed)
try FileManager.default.removeItem(at: logA)
check("missing-log-reports-unknown", try reader.read().first { $0.id == idA }?.status == .unknown)

let metadataOnly = CodexReader(home: home)
let metadata = try metadataOnly.read(notBefore: .distantFuture)
check("empty-task-list-still-lists-all-session-metadata", metadata.count == observations.count)
check("irrelevant-old-logs-not-parsed", metadata.allSatisfy { $0.taskNumber == nil && $0.status == .unknown })
let linkedOnly = try metadataOnly.read(notBefore: .distantFuture, linkedSessionIDs: [idB])
check("manually-linked-old-session-gets-live-state", linkedOnly.first { $0.id == idB }?.status == .completed)
check("old-unlinked-sessions-stay-metadata-only", linkedOnly.filter { $0.id != idB }.allSatisfy { $0.taskNumber == nil })

let report: [String: Any] = ["passed": failures.isEmpty, "checks":checks, "failures":failures, "count":checks.count]
if let arg = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(arg + 1) {
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[arg + 1]))
}
print("\(checks.count - failures.count)/\(checks.count) checks passed")
exit(failures.isEmpty ? 0 : 1)
