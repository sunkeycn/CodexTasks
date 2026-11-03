import Foundation
import Combine
import CSQLite
import WorkbenchCore

/// Runs only under --smoke-test-output, with an isolated Codex index, tasks and endpoint.
@MainActor
final class BridgeSmokeTest {
    private(set) var checks: [String: Bool] = ["httpLifecycleUpdatesModel": false, "httpCompletionPreservesOtherSessions": false, "httpRejectsUnknownSession": false]
    private(set) var latencyMilliseconds: [Double] = []
    private var model: AppModel?
    private var bridge: CodexEventBridge?
    private var subscription: AnyCancellable?
    private var sentAt = Date()
    private var root: URL!
    private var endpoint: URL!
    private var script: URL!
    private var taskID: UUID?
    private var sawRunning = false
    private var sawCompleted = false

    func start(directory: URL) {
        do {
            root = directory.appendingPathComponent("http-model-test")
            let home = root.appendingPathComponent("codex"), workspace = root.appendingPathComponent("workspace")
            let data = root.appendingPathComponent("data")
            endpoint = home.appendingPathComponent("bridge/endpoint.json")
            script = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexStatusHook")
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let log = home.appendingPathComponent("sessions/one.jsonl"), other = home.appendingPathComponent("sessions/two.jsonl")
            try Data().write(to: log); try Data().write(to: other)
            var db: OpaquePointer?
            guard sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }
            let sql = "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,rollout_path TEXT,git_branch TEXT,git_sha TEXT,updated_at INT); INSERT INTO threads VALUES('one','One','\(workspace.path)','\(log.path)','','',1); INSERT INTO threads VALUES('two','Two','\(workspace.path)','\(other.path)','','',2);"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return }
            let catalog = try WorkspaceCatalog(dataDirectory: data)
            try catalog.save(id: catalog.active.id, name: "Isolated", directory: workspace.path)
            let service = try WorkbenchService(databaseURL: catalog.databaseURL(for: catalog.active))
            let task = try service.createTask(title: "HTTP smoke")
            taskID = task.id
            try service.synchronizeSession(ObservedSession(id: "one", name: "One", cwd: workspace.path), taskID: task.id)
            let model = try AppModel(service: service, codexHome: home)
            self.model = model
            let bridge = try CodexEventBridge(endpointURL: endpoint) { [weak model] event in
                DispatchQueue.main.async { model?.receiveBridgeEvent(event) }
            }
            self.bridge = bridge
            subscription = model.$snapshot.sink { [weak self] state in
                guard let self, let run = state.runs.first(where: { $0.sessionID == "one" }) else { return }
                if run.state == .running && !self.sawRunning {
                    self.sawRunning = true
                    self.latencyMilliseconds.append(Date().timeIntervalSince(self.sentAt) * 1000)
                    self.checks["httpLifecycleUpdatesModel"] = true
                    DispatchQueue.main.async { self.send("Stop", home: home, workspace: workspace) }
                } else if run.state == .completed && !self.sawCompleted {
                    self.sawCompleted = true
                    self.latencyMilliseconds.append(Date().timeIntervalSince(self.sentAt) * 1000)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.checks["httpCompletionPreservesOtherSessions"] = model.sessions.count == 2 && !model.snapshot.tasks[0].isDone
                        let before = model.snapshot
                        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        let unknown = CodexBridgeEvent(hook: CodexHookStatus(sessionID: "unindexed", turnID: "unknown", cwd: workspace.path, event: "Stop", updatedAt: formatter.string(from: Date())))
                        let endpoint = self.endpoint!
                        DispatchQueue.global().async { CodexBridgeClient.notify(unknown, endpointURL: endpoint) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            self.checks["httpRejectsUnknownSession"] = model.snapshot == before
                        }
                    }
                }
            }
            model.syncNow()
            bridge.start { [weak self] ready in
                guard ready else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.send("UserPromptSubmit", home: home, workspace: workspace) }
            }
        } catch { checks["httpModelFixtureCreated"] = false }
    }
    private func send(_ event: String, home: URL, workspace: URL) {
        guard let script, let endpoint else { return }
        sentAt = Date()
        DispatchQueue.global().async {
            let process = Process(), input = Pipe()
            process.executableURL = script
            process.arguments = [ "--status-directory", home.appendingPathComponent("codex-tasks-status").path, "--endpoint-file", endpoint.path]
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["session_id": "one", "turn_id": "turn", "cwd": workspace.path, "hook_event_name": event]))
                try input.fileHandleForWriting.close(); process.waitUntilExit()
            } catch { }
        }
    }
    func stop() { subscription = nil; bridge?.stop(); bridge = nil; model?.stopLiveSync(); model = nil }
}
