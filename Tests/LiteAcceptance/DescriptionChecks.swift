import Foundation
import LiteCore

func runDescriptionChecks(root: URL, base: Date) throws {
    let url = root.appendingPathComponent("descriptions.sqlite")
    let store = try TaskStore(url: url)
    let first = try store.createTask(title: "任务", at: base)
    let child = try store.createTask(title: "子任务", parentID: first, at: base)
    let markdown = "# 描述 👋\n\n- **需求**与 `code`\n\n```swift\nlet value = \"quoted\"\n```\n\n  保留缩进和尾部换行\n"
    check("new-task-description-empty", try store.snapshot().tasks.allSatisfy { $0.details.isEmpty })
    try store.setTaskDetails(first, markdown)
    try store.setTaskDetails(child, "独立的子任务描述")
    try store.setStatus(first, .doing); try store.renameTask(first, title: "改名")
    let snapshot = try store.snapshot()
    check("description-markdown-exact-roundtrip", snapshot.rootTasks.first?.details == markdown)
    check("child-description-independent", snapshot.children(of: first).first?.details == "独立的子任务描述")
    check("description-survives-reopen", try TaskStore(url: url).snapshot() == snapshot)
    try store.setTaskDetails(first, "")
    check("description-can-be-cleared", try store.snapshot().rootTasks.first?.details == "")

    let home = root.appendingPathComponent("project-name-codex")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let index = home.appendingPathComponent("state_9.sqlite")
    try sql(index, """
    CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,rollout_path TEXT,updated_at REAL,cwd TEXT);
    INSERT INTO threads VALUES('assigned','自定义项目','',1800000000,'/unopened/outside');
    INSERT INTO threads VALUES('nested','嵌套项目','',1800000000,'/unopened/work/nested/sub');
    INSERT INTO threads VALUES('fallback','目录回退','',1800000000,'/unopened/fallback-project');
    INSERT INTO threads VALUES('boundary','边界相似','',1800000000,'/unopened/work-other');
    INSERT INTO threads VALUES('none','无项目','',1800000000,'');
    INSERT INTO threads VALUES('projectless','独立会话','',1800000000,'/unopened/work');
    """)
    let metadata: [String: Any] = [
        "local-projects": ["p": ["id":"p", "name":"自定义 Codex 项目", "rootPaths":["/unopened/work"]], "n": ["id":"n", "name":"嵌套项目名", "rootPaths":["/unopened/work/nested"]]],
        "thread-project-assignments": ["assigned": ["projectKind":"local", "projectId":"p"]],
        "projectless-thread-ids": ["projectless"]
    ]
    let metadataURL = home.appendingPathComponent(".codex-global-state.json")
    try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
    let reader = CodexReader(home: home)
    let sessions = try reader.read(notBefore: .distantFuture)
    func name(_ id: String) -> String? { sessions.first { $0.id == id }?.projectName }
    check("session-project-prefers-explicit-codex-assignment", name("assigned") == "自定义 Codex 项目")
    check("session-project-longest-root-match", name("nested") == "嵌套项目名")
    check("session-project-falls-back-to-cwd-name", name("fallback") == "fallback-project")
    check("session-project-respects-path-boundary", name("boundary") == "work-other")
    check("session-projectless-does-not-infer-from-cwd", name("projectless") == "")
    check("session-without-project-has-empty-name", name("none") == "")
    try store.attach(sessions.first { $0.id == "assigned" }!, to: first, at: base)
    check("session-project-name-persists", try TaskStore(url: url).snapshot().sessions(for: first).first?.projectName == "自定义 Codex 项目")
    try "invalid json".write(to: metadataURL, atomically: true, encoding: .utf8)
    check("invalid-codex-project-metadata-keeps-session-reader-working", try reader.read(notBefore: .distantFuture).first { $0.id == "fallback" }?.projectName == "fallback-project")
    try sql(index, "ALTER TABLE threads DROP COLUMN cwd")
    check("old-codex-index-without-cwd-still-readable", try reader.read(notBefore: .distantFuture).count == 6)

    let legacyURL = root.appendingPathComponent("description-v4.sqlite")
    try sql(legacyURL, """
    CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,status TEXT NOT NULL,created_at REAL NOT NULL,parent_id INTEGER,unread_completion INTEGER NOT NULL DEFAULT 0,sort_order INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE sessions(id TEXT PRIMARY KEY,task_id INTEGER,title TEXT NOT NULL,status TEXT NOT NULL,updated_at REAL NOT NULL,bound_at REAL NOT NULL,sort_order INTEGER NOT NULL DEFAULT 0);
    INSERT INTO tasks VALUES(8,'旧任务','doing',1800000000,NULL,1,2),(9,'先排序任务','todo',1800000000,NULL,0,1),(10,'子任务','todo',1800000000,8,0,0);
    INSERT INTO sessions VALUES('old-session',8,'旧会话','running',1800000000,1800000000,4);
    PRAGMA application_id=1129598036; PRAGMA user_version=4;
    """)
    let migrated = try TaskStore(url: legacyURL)
    let legacy = try migrated.snapshot()
    check("schema-four-upgrades-to-five", try scalar(legacyURL, "PRAGMA user_version") == 5)
    check("schema-four-keeps-order-hierarchy-and-unread", legacy.rootTasks.map(\.id) == [9,8] && legacy.children(of: 8).first?.id == 10 && legacy.rootTasks.last?.hasUnreadCompletion == true)
    check("schema-four-new-fields-default-empty", legacy.tasks.allSatisfy { $0.details.isEmpty } && legacy.sessions.first?.projectName == "" && legacy.sessions.first?.taskID == 8)
    try migrated.setTaskDetails(8, markdown)
    check("schema-four-description-upgrade-idempotent", try TaskStore(url: legacyURL).snapshot() == migrated.snapshot())
}
