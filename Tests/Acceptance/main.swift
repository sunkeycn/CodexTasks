import Foundation
import CSQLite
import CryptoKit
import WorkbenchCore

final class WorkbenchCoreTests {
    var directory: URL!
    var url: URL!
    var service: WorkbenchService!
    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-tests-\(UUID().uuidString)")
        url = directory.appendingPathComponent("state.sqlite")
        service = try WorkbenchService(databaseURL: url)
    }
    func tearDownWithError() throws { service = nil; try? FileManager.default.removeItem(at: directory) }
    private func fixture() throws -> (WorkTask, Project, Branch) {
        let project = try service.createProject(name: "测试项目", repository: "mock://\(UUID())")
        let branch = try service.createBranch(projectID: project.id, ref: "feature/example")
        let task = try service.createTask(title: "验收任务", branchID: branch.id)
        return (task, project, branch)
    }
    private func sql(_ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw WorkbenchError.persistence("test open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw WorkbenchError.persistence(String(cString: sqlite3_errmsg(db))) }
    }

    func testDeleteTaskCleansLocalRelationsAndKeepsNumbersAndPipelines() throws {
        let (task, project, branch) = try fixture()
        let other = try service.createTask(title: "保留任务")
        let session = ObservedSession(id: "delete-session", name: "原会话", cwd: directory.path, taskNumber: task.number, commandAt: Date(), turns: [ObservedTurn(id: "turn", state: .running)])
        try service.synchronizeSession(session, taskID: task.id)
        let run = try unwrap(service.snapshot().runs.first)
        try service.reportRun(runID: run.id, state: .completed, sequence: 1, summary: "完成", eventID: "delete-event")
        let plan = try service.prepareDeployment(branchID: branch.id, environment: "test", parameters: "", taskID: task.id)
        let pipeline = try service.confirmDeployment(planID: plan.id, expectedDigest: plan.digest)
        let pending = try service.prepareDeployment(branchID: branch.id, environment: "test", parameters: "different", taskID: task.id)
        let before = try service.snapshot()
        let current = try unwrap(before.tasks.first { $0.id == task.id })
        try expectThrows(try service.deleteTask(taskID: task.id, expectedVersion: current.version + 1))
        try expectEqual(try service.snapshot(), before)
        try service.deleteTask(taskID: task.id, expectedVersion: current.version)
        let state = try service.snapshot()
        try expectEqual(state.tasks.map(\.id), [other.id])
        try expectTrue(state.links.isEmpty && state.attachments.isEmpty && state.runs.isEmpty && state.eventLedger.isEmpty)
        try expectEqual(state.projects.first?.id, project.id)
        try expectEqual(state.branches.first?.id, branch.id)
        try expectEqual(state.pipelines.first?.id, pipeline.id)
        try expectNil(state.pipelines.first?.taskID)
        try expectEqual(state.plans.first { $0.id == plan.id }, before.plans.first { $0.id == plan.id })
        try expectThrows(try service.confirmDeployment(planID: pending.id, expectedDigest: pending.digest))
        try service.synchronizeSession(session)
        try expectTrue(try service.snapshot().attachments.isEmpty)
        let reopened = try WorkbenchService(databaseURL: url)
        try expectEqual(try reopened.createTask(title: "新任务").number, 3)
        try expectEqual(try reopened.snapshot().tasks.count, 2)
    }
    func testHookSidecarLifecycleAndBoundaries() throws {
        let home = directory.appendingPathComponent("codex")
        let workspace = directory.appendingPathComponent("workspace")
        let sidecars = home.appendingPathComponent("codex-tasks-status")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sidecars, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("sessions/test.jsonl")
        try Data().write(to: log)
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try expectEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,git_branch TEXT,git_sha TEXT,updated_at INT); INSERT INTO threads VALUES('s','测试','\(workspace.path)','\(log.path)','main','abc',1);", nil, nil, nil), SQLITE_OK)
        let hash = SHA256.hash(data: Data("s".utf8)).map { String(format: "%02x", $0) }.joined()
        let file = sidecars.appendingPathComponent(hash + ".json")
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func write(_ event: String, cwd: String? = nil, id: String = "s", date: Date = Date()) throws {
            try JSONSerialization.data(withJSONObject: ["version": 1, "sessionID": id, "turnID": "hook-turn", "cwd": cwd ?? workspace.path, "event": event, "updatedAt": formatter.string(from: date)]).write(to: file, options: .atomic)
        }
        let reader = LocalCodexReader(codexHome: home, allowedRoot: workspace)
        try write("UserPromptSubmit")
        try expectEqual(try reader.read().first?.turns.first?.state, .running)
        try write("Stop")
        var observed = try unwrap(reader.read().first)
        try expectEqual(observed.turns.first?.state, .completed)
        try expectEqual(observed.turns.first?.source, "Codex 生命周期 Hook")
        let task = try service.createTask(title: "生命周期")
        try service.synchronizeSession(observed, taskID: task.id)
        try expectEqual(try service.snapshot().runs.first?.source, "Codex 生命周期 Hook")
        try expectFalse(try service.snapshot().tasks[0].isDone)
        try write("Interrupt")
        try expectEqual(try reader.read().first?.turns.first?.state, .interrupted)
        try write("UserPromptSubmit", date: Date().addingTimeInterval(-181))
        try expectEqual(try reader.read().first?.turns.first?.state, .unknown)
        for event in ["PermissionRequest", "Invalid"] {
            try write(event); try expectTrue(try unwrap(reader.read().first).turns.isEmpty)
        }
        try write("Stop", cwd: directory.path); try expectTrue(try unwrap(reader.read().first).turns.isEmpty)
        try write("Stop", id: "different-session"); try expectTrue(try unwrap(reader.read().first).turns.isEmpty)
        try write("Stop", date: Date().addingTimeInterval(120)); try expectTrue(try unwrap(reader.read().first).turns.isEmpty)
        try Data("broken".utf8).write(to: file); try expectTrue(try unwrap(reader.read().first).turns.isEmpty)
        // A late hook cannot overwrite a newer log event for the same turn.
        try write("Stop", date: Date().addingTimeInterval(-60))
        let record: [String: Any] = ["type": "event_msg", "timestamp": formatter.string(from: Date()), "payload": ["type": "task_started", "turn_id": "hook-turn"]]
        var content = try JSONSerialization.data(withJSONObject: record); content.append(10); try content.write(to: log)
        observed = try unwrap(reader.read().first)
        try expectEqual(observed.turns.first?.state, .running)
        try expectEqual(observed.turns.first?.source, "本机 Codex 日志")
    }
    func testStableNumbersCompletionAndReopen() throws {
        let task = try service.createTask(title: "第一项")
        try service.setCompleted(taskID: task.id, value: true, expectedVersion: 1)
        var reopened: WorkbenchService? = try WorkbenchService(databaseURL: url)
        let persisted = try unwrap(reopened?.snapshot().tasks.first)
        try expectEqual(persisted.number, 1); try expectTrue(persisted.isDone); try expectNotNil(persisted.completedAt)
        try reopened?.updateTask(id: task.id, title: "改名", notes: "说明", acceptance: "验收", expectedVersion: persisted.version)
        let renamed = try unwrap(reopened?.snapshot().tasks.first)
        try reopened?.setCompleted(taskID: task.id, value: false, expectedVersion: renamed.version)
        try expectFalse(try unwrap(reopened?.snapshot().tasks.first).isDone)
        try expectNil(try unwrap(reopened?.snapshot().tasks.first).completedAt)
        try expectEqual(try reopened?.createTask(title: "第二项").number, 2)
        try expectEqual(try reopened?.snapshot().tasks.first?.id, task.id)
        reopened = nil
    }
    func testConcurrentNumberAllocationAcrossConnections() throws {
        let workers = try (0..<4).map { _ in try WorkbenchService(databaseURL: url) }
        let errors = ErrorCollector()
        DispatchQueue.concurrentPerform(iterations: 80) { index in
            do { _ = try workers[index % workers.count].createTask(title: "并发 \(index)") } catch { errors.add(error) }
        }
        try expectEqual(errors.messages, [])
        let state = try service.snapshot()
        try expectEqual(state.tasks.count, 80)
        try expectEqual(Set(state.tasks.map(\.number)), Set(1...80))
        try expectEqual(state.nextNumber, 81)
    }
    func testWriteFailureLeavesTrustedStateAndDraft() throws {
        let task = try service.createTask(title: "不能假完成")
        try service.saveDraft("保留输入")
        try sql("CREATE TRIGGER deny_write BEFORE UPDATE ON document BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END")
        try expectThrows(try service.setCompleted(taskID: task.id, value: true, expectedVersion: task.version))
        try expectFalse(try service.snapshot().tasks[0].isDone)
        try expectThrows(try service.createTask(title: "保留输入", clearDraft: true))
        try expectEqual(try service.snapshot().draft, "保留输入")
        try expectEqual(try service.snapshot().nextNumber, 2)
        try sql("DROP TRIGGER deny_write")
        try expectEqual(try service.createTask(title: "恢复写入").number, 2)
    }
    func testVersionConflictDoesNotOverwriteOtherEdit() throws {
        let task = try service.createTask(title: "原始")
        try service.updateTask(id: task.id, title: "新标题", notes: "", acceptance: "", expectedVersion: 1)
        try expectThrows(try service.updateTask(id: task.id, title: "旧页面", notes: "", acceptance: "", expectedVersion: 1))
        try expectEqual(try service.snapshot().tasks[0].title, "新标题")
    }
    func testCompletionRetryIsIdempotent() throws {
        let task = try service.createTask(title: "显式完成")
        try service.setCompleted(taskID: task.id, value: true, expectedVersion: 1)
        try service.setCompleted(taskID: task.id, value: true, expectedVersion: 1)
        try expectEqual(try service.snapshot().tasks[0].version, 2)
        try expectTrue(try service.snapshot().tasks[0].isDone)
    }
    func testRunsAndPipelinesNeverChangeManualCompletion() throws {
        let (task, _, branch) = try fixture()
        let run = try service.startMockRun(taskID: task.id, branchID: branch.id)
        try service.setCompleted(taskID: task.id, value: true, expectedVersion: task.version)
        try expectEqual(try service.snapshot().runs[0].state, .running)
        try service.reportRun(runID: run.id, state: .completed, sequence: 1, summary: "ok", eventID: "done")
        let plan = try service.prepareDeployment(branchID: branch.id, environment: "test", parameters: "", taskID: task.id)
        let pipeline = try service.confirmDeployment(planID: plan.id, expectedDigest: plan.digest)
        try service.updateMockPipeline(runID: pipeline.id, next: .succeeded)
        let completed = try service.snapshot().tasks[0]
        try expectTrue(completed.isDone)
        try service.setCompleted(taskID: task.id, value: false, expectedVersion: completed.version)
        let second = try service.startMockRun(taskID: task.id)
        try service.reportRun(runID: second.id, state: .completed, sequence: 1, summary: "done", eventID: "done2")
        try expectFalse(try service.snapshot().tasks[0].isDone)
    }
    func testConcurrentRunsAggregateAndLateEventsDoNotRevive() throws {
        let task = try service.createTask(title: "并发执行")
        let a = try service.startMockRun(taskID: task.id)
        let b = try service.startMockRun(taskID: task.id)
        try service.reportRun(runID: a.id, state: .completed, sequence: 3, summary: "a done", eventID: "a3")
        try expectEqual(try service.snapshot().runSummary(taskID: task.id), "正在运行 1 项")
        try service.reportRun(runID: a.id, state: .running, sequence: 2, summary: "late", eventID: "a2")
        try service.reportRun(runID: a.id, state: .running, sequence: 4, summary: "invalid resurrection", eventID: "a4")
        try expectEqual(try service.snapshot().runs.first { $0.id == a.id }?.state, .completed)
        try service.reportRun(runID: b.id, state: .needsInput, sequence: 5, summary: "input", eventID: "b5")
        try service.reportRun(runID: b.id, state: .running, sequence: 4, summary: "late", eventID: "b4")
        try expectEqual(try service.snapshot().runs.first { $0.id == b.id }?.state, .needsInput)
    }
    func testEventIdempotenceMismatchAndNoticeDeduplication() throws {
        let task = try service.createTask(title: "事件幂等")
        let run = try service.startMockRun(taskID: task.id)
        for _ in 0..<3 { try service.reportRun(runID: run.id, state: .needsInput, sequence: 1, summary: "input", eventID: "unique") }
        try expectEqual(try service.snapshot().notices.count, 1)
        try expectThrows(try service.reportRun(runID: run.id, state: .failed, sequence: 1, summary: "different", eventID: "unique"))
        try service.reportRun(runID: run.id, state: .needsInput, sequence: 2, summary: "input again", eventID: "unique2")
        try expectEqual(try service.snapshot().notices.count, 1)
        try service.markNoticesRead()
        try expectEqual(try service.snapshot().unreadCount, 0)
    }
    func testRecoveryUnknownRetainsTimestampAndCanReconcile() throws {
        let (task, _, branch) = try fixture()
        let run = try service.startMockRun(taskID: task.id)
        let plan = try service.prepareDeployment(branchID: branch.id, environment: "dev", parameters: "", taskID: nil)
        let pipeline = try service.confirmDeployment(planID: plan.id, expectedDigest: plan.digest)
        try service.recoverInterruptedRuns()
        let state = try service.snapshot()
        try expectEqual(state.runs[0].state, .unknown)
        try expectEqual(state.runs[0].updatedAt, run.updatedAt)
        try expectEqual(state.pipelines[0].state, .unknown)
        try expectEqual(state.pipelines[0].updatedAt, pipeline.updatedAt)
        try service.recoverInterruptedRuns()
        try expectEqual(try service.snapshot().pipelines.count, 1)
        try expectEqual(try service.confirmDeployment(planID: plan.id, expectedDigest: plan.digest).id, pipeline.id)
        try service.reportRun(runID: run.id, state: .completed, sequence: 1, summary: "verified", eventID: "reconcile")
        try expectEqual(try service.snapshot().runs[0].state, .completed)
    }
    func testFollowAndLinkAreIndependentWithUndoDefaults() throws {
        let (task, _, branch) = try fixture()
        try service.setFollowed(branchID: branch.id, value: false)
        try expectEqual(try service.snapshot().links.count, 1)
        let receipt = try service.unlink(taskID: task.id, branchID: branch.id)
        try expectNil(try service.snapshot().tasks[0].defaultBranchID)
        try expectEqual(try service.snapshot().branches.count, 1)
        try service.undoUnlink(receipt)
        let state = try service.snapshot()
        try expectFalse(state.branches[0].isFollowed)
        try expectEqual(state.tasks[0].defaultBranchID, branch.id)
        try expectTrue(state.links[0].isProjectDefault)
    }
    func testUndoDoesNotOverwriteLaterUserChanges() throws {
        let (task, _, branch) = try fixture()
        let receipt = try service.unlink(taskID: task.id, branchID: branch.id)
        let latest = try service.snapshot().tasks[0]
        try service.setCompleted(taskID: task.id, value: true, expectedVersion: latest.version)
        try expectThrows(try service.undoUnlink(receipt))
        try expectTrue(try service.snapshot().tasks[0].isDone)
    }
    func testResolveCurrentProjectPriorityAndAmbiguity() throws {
        let (task, p1, b1) = try fixture()
        let p2 = try service.createProject(name: "另一个项目", repository: "mock://p2")
        let b2 = try service.createBranch(projectID: p2.id, ref: "feature/two")
        try service.link(taskID: task.id, branchID: b2.id)
        let caller = CallerScope(authorizedProjectIDs: [p1.id, p2.id], currentProjectID: p2.id, currentBranchRef: "main")
        let result = try service.resolve(number: task.displayNumber, caller: caller)
        try expectEqual(result.branch.id, b2.id); try expectTrue(result.branchMismatch); try expectTrue(result.metadataOnly)
        let b3 = try service.createBranch(projectID: p2.id, ref: "feature/three")
        try service.link(taskID: task.id, branchID: b3.id)
        try expectThrows(try service.resolve(number: task.displayNumber, caller: caller))
        try service.setProjectDefault(taskID: task.id, branchID: b3.id)
        try expectEqual(try service.resolve(number: task.displayNumber, caller: caller).branch.id, b3.id)
        try expectEqual(try service.resolve(number: task.displayNumber, caller: CallerScope(authorizedProjectIDs: [p1.id, p2.id])).branch.id, b1.id)
    }
    func testResolveRejectsUnauthorizedAndPlainNumberAndUnrelatedContext() throws {
        let (task, project, _) = try fixture()
        try expectThrows(try service.resolve(number: "1", caller: CallerScope(authorizedProjectIDs: [project.id])))
        try expectThrows(try service.resolve(number: task.displayNumber, caller: CallerScope(authorizedProjectIDs: [])))
        let other = try service.createProject(name: "外部", repository: "mock://other")
        try expectThrows(try service.resolve(number: task.displayNumber, caller: CallerScope(authorizedProjectIDs: [project.id, other.id], currentProjectID: other.id)))
        try service.setDefaultBranch(taskID: task.id, branchID: nil)
        try expectThrows(try service.resolve(number: task.displayNumber, caller: CallerScope(authorizedProjectIDs: [project.id])))
    }
    func testBranchUnknownRetainsHistoryAndBlocksResolution() throws {
        let (task, project, branch) = try fixture()
        let run = try service.startMockRun(taskID: task.id, branchID: branch.id)
        try service.setBranchAvailability(branchID: branch.id, value: .unknown)
        try expectThrows(try service.resolve(number: task.displayNumber, caller: CallerScope(authorizedProjectIDs: [project.id])))
        try expectEqual(try service.snapshot().links.count, 1)
        try expectEqual(try service.snapshot().runs[0].scopeDescription, run.scopeDescription)
        try expectThrows(try service.prepareDeployment(branchID: branch.id, environment: "test", parameters: "", taskID: nil))
    }
    func testSessionReattachmentDoesNotMoveRunHistory() throws {
        let (first, project, branch) = try fixture()
        let second = try service.createTask(title: "第二任务", branchID: branch.id)
        let caller = CallerScope(authorizedProjectIDs: [project.id])
        _ = try service.attach(number: first.displayNumber, sessionID: "session", caller: caller)
        let run = try service.startMockRun(taskID: first.id, branchID: branch.id, sessionID: "session")
        try expectThrows(try service.attach(number: second.displayNumber, sessionID: "session", caller: caller))
        _ = try service.unlink(taskID: first.id, branchID: branch.id)
        let state = try service.snapshot()
        try expectEqual(state.attachments.count, 1)
        try expectEqual(state.attachments[0].taskID, first.id)
        try expectEqual(state.runs[0].taskID, first.id)
        try expectEqual(state.runs[0].scopeDescription, run.scopeDescription)
    }
    func testRealSessionBindingAndDynamicProjects() throws {
        let task = try service.createTask(title: "先记录，无项目")
        try expectEqual(task.displayNumber, "T#01")
        let now = Date().addingTimeInterval(1)
        var session = ObservedSession(id: "real-session", name: "实现卡包", cwd: directory.path, taskNumber: 1, commandAt: now,
            workspaces: [ObservedWorkspace(path: directory.path, branch: "feature/cards", sha: "abc")],
            turns: [ObservedTurn(id: "turn-1", state: .running, updatedAt: now)])
        try service.synchronizeSession(session)
        try service.synchronizeSession(session)
        var state = try service.snapshot()
        try expectEqual(state.attachments.count, 1); try expectEqual(state.runs.count, 1)
        try expectEqual(state.projects.count, 1); try expectEqual(state.links.count, 1)
        session.name = "卡包与接口"
        session.workspaces.append(ObservedWorkspace(path: directory.appendingPathComponent("api").path, branch: "feature/api", sha: "def"))
        session.turns[0].state = .completed
        try service.synchronizeSession(session)
        state = try service.snapshot()
        try expectEqual(state.projects.count, 2); try expectEqual(state.links.count, 2)
        try expectEqual(state.attachments[0].sessionName, "卡包与接口")
        try expectEqual(state.runs[0].state, .completed); try expectFalse(state.tasks[0].isDone)
        session.turns[0].state = .running
        session.turns.append(ObservedTurn(id: "turn-2", state: .running, updatedAt: now.addingTimeInterval(10)))
        try service.synchronizeSession(session)
        state = try WorkbenchService(databaseURL: url).snapshot()
        try expectEqual(state.runs.count, 2); try expectEqual(state.runs[0].state, .completed)
        try service.markUnavailableSessions(availableIDs: [])
        try expectEqual(try service.snapshot().runs[1].state, .unknown)
        try service.synchronizeSession(session)
        try expectEqual(try service.snapshot().runs[1].state, .running)
    }
    func testRealSessionOneToOneAndStaleCommands() throws {
        let first = try service.createTask(title: "一")
        let second = try service.createTask(title: "二")
        var a = ObservedSession(id: "a", name: "a", cwd: directory.path, taskNumber: 1, commandAt: .distantPast)
        try service.synchronizeSession(a)
        try expectTrue(try service.snapshot().attachments.isEmpty)
        a.commandAt = Date().addingTimeInterval(1)
        try service.synchronizeSession(a)
        var b = a; b.id = "b"
        try expectThrows(try service.synchronizeSession(b))
        a.taskNumber = 2
        try expectThrows(try service.synchronizeSession(a))
        try expectThrows(try service.synchronizeSession(a, taskID: second.id))
        try expectEqual(try service.snapshot().attachments[0].taskID, first.id)
    }
    func testManualProjectMatchesAutomaticWorkspace() throws {
        let path = directory.appendingPathComponent("project").path
        let project = try service.createProject(name: "我命名的项目", repository: "local:" + path, checkoutPath: path)
        let task = try service.createTask(title: "手动绑定")
        let session = ObservedSession(id: "manual", name: "会话", cwd: path, workspaces: [ObservedWorkspace(path: path, branch: "main")])
        try service.synchronizeSession(session, taskID: task.id)
        try expectEqual(try service.snapshot().projects.map(\.id), [project.id])
        try expectEqual(try service.snapshot().checkouts.count, 1)
        let same = try service.createProject(name: "另一个名称", repository: "different-identity", checkoutPath: path)
        try expectEqual(same.id, project.id)
        try expectEqual(try service.snapshot().attachments[0].workspacePath, path)
        let other = try service.createTask(title: "旧指令不应抢占手动绑定")
        var stale = session; stale.taskNumber = other.number; stale.commandAt = .distantPast
        try service.synchronizeSession(stale)
        try expectEqual(try service.snapshot().attachments[0].taskID, task.id)
    }
    func testGitInspectionFollowsBranchAndRejectsExternalGitDirectory() throws {
        let workspace = directory.appendingPathComponent("git-workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", workspace.path] + arguments
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit(); try expectEqual(p.terminationStatus, 0)
        }
        try git(["init", "-b", "main"])
        let reader = LocalCodexReader(codexHome: directory, allowedRoot: workspace)
        let task = try service.createTask(title: "分支变化")
        var session = ObservedSession(id: "git-session", name: "Git", cwd: workspace.path)
        session.workspaces = [reader.inspectWorkspace(ObservedWorkspace(path: workspace.path))]
        try expectEqual(session.workspaces[0].branch, "main")
        try service.synchronizeSession(session, taskID: task.id)
        try git(["symbolic-ref", "HEAD", "refs/heads/feature/cards"])
        session.workspaces = [reader.inspectWorkspace(ObservedWorkspace(path: workspace.path))]
        try service.synchronizeSession(session)
        let state = try service.snapshot()
        try expectEqual(state.projects.count, 1); try expectEqual(state.branches.count, 2)
        try expectEqual(state.branches.first { $0.id == state.attachments[0].branchID }?.ref, "feature/cards")
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"])
        let worktree = workspace.appendingPathComponent("linked-checkout")
        try git(["worktree", "add", "-b", "feature/worktree", worktree.path])
        let observedWorktree = reader.inspectWorkspace(ObservedWorkspace(path: worktree.path))
        try expectEqual(observedWorktree.branch, "feature/worktree")
        try expectEqual(observedWorktree.repositoryIdentity, reader.inspectWorkspace(ObservedWorkspace(path: workspace.path)).repositoryIdentity)
        session.workspaces.append(observedWorktree)
        try service.synchronizeSession(session)
        try expectEqual(try service.snapshot().projects.count, 1)
        try expectEqual(try service.snapshot().checkouts.count, 2)
        let external = directory.appendingPathComponent("external.git")
        try FileManager.default.moveItem(at: workspace.appendingPathComponent(".git"), to: external)
        try "gitdir: \(external.path)\n".write(to: workspace.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try expectNil(reader.inspectWorkspace(ObservedWorkspace(path: workspace.path)).branch)
    }

    func testCodexDispatchExecutesExactPromptAndBindsSession() throws {
        let task = try service.createTask(title: "卡包 & 中文 + #")
        let body = "1. 点击加入卡包期间显示遮罩\n2. 返回与失败时取消遮罩\n3. 卡片紧贴左右下三边"
        let request = CodexDispatchRequest(task: task, databaseURL: url, workspace: directory.path, notes: body, title: task.title)
        let executable = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, sys
        assert sys.argv[1:7] == ['exec', '--json', '--sandbox', 'workspace-write', '--skip-git-repo-check', '--cd']
        assert sys.argv[7:] == [str(pathlib.Path(__file__).parent), '-']
        pathlib.Path(__file__).with_suffix('.input').write_text(sys.stdin.read())
        print(json.dumps({'type': 'thread.started', 'thread_id': '11111111-1111-4111-8111-111111111111'}), flush=True)
        print(json.dumps({'type': 'turn.started'}), flush=True)
        # Verbose tool output must not block the dispatch helper.
        print(json.dumps({'type': 'item.completed', 'item': {'text': 'x' * 150000}}), flush=True)
        print(json.dumps({'type': 'turn.completed'}), flush=True)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try CodexDispatchRunner.run(request, executable: executable)
        let receipt = try CodexDispatchReceipt.read(from: request.receiptURL)
        try expectEqual(receipt.state, .completed)
        try expectEqual(receipt.sessionID, "11111111-1111-4111-8111-111111111111")
        try expectEqual(try String(contentsOf: executable.appendingPathExtension("input")), task.associationPrompt + "\n" + body)
        let snapshot = try service.snapshot()
        try expectEqual(snapshot.attachments.first?.taskID, task.id)
        try expectEqual(snapshot.attachments.first?.sessionID, receipt.sessionID)
        try expectEqual(snapshot.tasks.first?.isDone, false)
        let stored = try String(contentsOf: request.receiptURL)
        try expectTrue(!stored.contains(body))
    }

    func testCodexDispatchReportsFailuresWithoutPretendingToSend() throws {
        let task = try service.createTask(title: "失败测试")
        let request = CodexDispatchRequest(task: task, databaseURL: url, workspace: directory.path, notes: "修改代码", title: task.title)
        let executable = directory.appendingPathComponent("failing-codex")
        try "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"type\":\"turn.failed\",\"error\":{\"message\":\"请先登录 Codex\"}}'\nexit 2\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try CodexDispatchRunner.run(request, executable: executable)
        let failed = try CodexDispatchReceipt.read(from: request.receiptURL)
        try expectEqual(failed.state, .failed)
        try expectEqual(failed.message, "请先登录 Codex")
        try expectNil(failed.sessionID)
        try expectTrue(try service.snapshot().attachments.isEmpty)
        let missing = CodexDispatchRequest(task: task, databaseURL: url, workspace: directory.appendingPathComponent("missing").path, notes: "", title: task.title)
        try expectThrows(try CodexDispatchRunner.run(missing, executable: executable))
        try expectEqual(try CodexDispatchReceipt.read(from: missing.receiptURL).state, .failed)
        let cannotLaunch = CodexDispatchRequest(task: task, databaseURL: url, workspace: directory.path, notes: "", title: task.title)
        try expectThrows(try CodexDispatchRunner.run(cannotLaunch, executable: directory.appendingPathComponent("no-cli")))
        try expectEqual(try CodexDispatchReceipt.read(from: cannotLaunch.receiptURL).state, .failed)
    }

    func testCodexPromptDeepLinkAndWorkspaceMetadataIsolation() throws {
        let task = try service.createTask(title: "标题 & 中文")
        let prompt = "修改 A&B?\n保留 + # 与中文"
        let deepLink = try unwrap(task.codexURL(workspace: directory.path + "/目录 空格", notes: prompt))
        let components = try unwrap(URLComponents(url: deepLink, resolvingAgainstBaseURL: false))
        try expectEqual(components.host, "new")
        try expectTrue(deepLink.absoluteString.contains("%2B"))
        try expectEqual(components.queryItems?.first(where: { $0.name == "prompt" })?.value, task.associationPrompt + "\n" + prompt)
        try expectEqual(components.queryItems?.first(where: { $0.name == "path" })?.value, directory.path + "/目录 空格")
        try expectEqual(task.codexPrompt(notes: "   "), task.associationPrompt + "\n" + task.title)
        try expectEqual(task.codexPrompt(notes: task.associationPrompt + " \n" + prompt), task.associationPrompt + "\n" + prompt)
        try expectEqual(task.editableCodexNotes(task.associationPrompt + "\n" + prompt + "\n\n" + task.associationPrompt), prompt)
        try expectEqual(task.editableCodexNotes("关联Codex Task【T#99】\n" + prompt), "关联Codex Task【T#99】\n" + prompt)
        try expectEqual(task.codexPrompt(notes: task.associationPrompt), task.associationPrompt + "\n" + task.title)
        let now = Date().addingTimeInterval(1)
        let running = ObservedSession(id: "isolation", name: "执行前", cwd: directory.path,
            turns: [ObservedTurn(id: "turn", state: .running, updatedAt: now)])
        try service.synchronizeSession(running, taskID: task.id)
        var completed = running; completed.name = "新标题"; completed.turns = [ObservedTurn(id: "turn", state: .completed, updatedAt: now.addingTimeInterval(1))]
        try service.synchronizeSession(completed)
        try service.synchronizeSessionWorkspaces(sessionID: running.id, workspaces: [ObservedWorkspace(path: directory.path, branch: "main", sha: "abc")])
        let snapshot = try service.snapshot()
        try expectEqual(snapshot.attachments.first?.sessionName, "新标题")
        try expectEqual(snapshot.runs.first?.state, .completed)
        try expectEqual(snapshot.branches.first?.sha, "abc")
    }
    func testLargeSessionPublishesRecentStateBeforeHistory() throws {
        let home = directory.appendingPathComponent("codex")
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("sessions/large.jsonl")
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try expectEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT,name TEXT,title TEXT,cwd TEXT,rollout_path TEXT,git_branch TEXT,git_sha TEXT,updated_at INT); INSERT INTO threads VALUES('s','当前会话标题','旧标题','\(workspace.path)','\(log.path)','main','abc',1);", nil, nil, nil), SQLITE_OK)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date().addingTimeInterval(1)
        func line(_ payload: [String: Any], at date: Date) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: date), "payload": payload]); data.append(10); return data
        }
        var content = try line(["type": "user_message", "message": "关联Codex Task【T#99】"], at: now.addingTimeInterval(-60))
        let filler = try line(["type": "agent_message", "message": String(repeating: "历史正文", count: 4096)], at: now.addingTimeInterval(-30))
        while content.count < 7 * 1024 * 1024 { content.append(filler) }
        content.append(try line(["type": "user_message", "message": "关联Codex Task【T#01】"], at: now))
        content.append(try line(["type": "task_started", "turn_id": "live"], at: now))
        try content.write(to: log)
        let reader = LocalCodexReader(codexHome: home, allowedRoot: workspace)
        let start = Date()
        var observed = try unwrap(reader.read().first)
        print("Large-session first live scan: \(Date().timeIntervalSince(start))s")
        try expectTrue(reader.hasPendingHistory)
        try expectEqual(observed.name, "当前会话标题")
        try expectEqual(observed.taskNumber, 1)
        try expectEqual(observed.turns.last?.state, .running)
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        try handle.seekToEnd()
        let completion = try line(["type": "task_complete", "turn_id": "live"], at: now.addingTimeInterval(2))
        try handle.write(contentsOf: completion.dropLast())
        try expectEqual(try reader.read().first?.turns.last?.state, .running)
        try handle.write(contentsOf: Data([10]))
        try expectEqual(sqlite3_exec(db, "UPDATE threads SET name='重命名标题';", nil, nil, nil), SQLITE_OK)
        observed = try unwrap(reader.read().first)
        try expectEqual(observed.name, "重命名标题")
        try expectEqual(observed.turns.last?.state, .completed)
        for _ in 0..<10 where reader.hasPendingHistory { observed = try unwrap(reader.read().first) }
        try expectFalse(reader.hasPendingHistory)
        try expectEqual(observed.taskNumber, 1)
        try expectEqual(observed.turns.last?.state, .completed)
        // If the latest association is in the middle, partial old history must not bind a different task.
        var middle = try line(["type": "user_message", "message": "关联Codex Task【T#99】"], at: now.addingTimeInterval(-60))
        while middle.count < 3 * 1024 * 1024 { middle.append(filler) }
        middle.append(try line(["type": "user_message", "message": "关联Codex Task【T#01】"], at: now))
        while middle.count < 7 * 1024 * 1024 { middle.append(filler) }
        middle.append(try line(["type": "task_started", "turn_id": "middle"], at: now.addingTimeInterval(1)))
        try middle.write(to: log)
        let middleReader = LocalCodexReader(codexHome: home, allowedRoot: workspace)
        var middleSession = try unwrap(middleReader.read().first)
        try expectNil(middleSession.taskNumber)
        try expectEqual(middleSession.turns.last?.id, "middle")
        for _ in 0..<10 where middleReader.hasPendingHistory { middleSession = try unwrap(middleReader.read().first) }
        try expectEqual(middleSession.taskNumber, 1)
        // Truncation must invalidate both the history and the recent cursor.
        try line(["type": "task_started", "turn_id": "replacement"], at: now.addingTimeInterval(3)).write(to: log)
        observed = try unwrap(reader.read().first)
        try expectNil(observed.taskNumber)
        try expectEqual(observed.turns.map(\.id), ["replacement"])
    }
    func testLocalReaderCommandsIncrementalAndScope() throws {
        let home = directory.appendingPathComponent("codex")
        let workspace = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("sessions/test.jsonl")
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let ddl = "CREATE TABLE threads(id TEXT,title TEXT,cwd TEXT,rollout_path TEXT,git_branch TEXT,git_sha TEXT,updated_at INT); INSERT INTO threads VALUES('s','真实名称','\(workspace.path)','\(log.path)','main','abc',1);"
        try expectEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        let time = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        func line(_ type: String, _ payload: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": time, "payload": payload]); data.append(10); return data
        }
        var content = try line("response_item", ["type": "message", "role": "assistant", "content": [["text": "关联任务【T#99】"]]])
        content.append(try line("response_item", ["type": "message", "role": "user", "content": [["text": "举例：关联任务【T#88】\n```\n关联任务【T#77】\n```"]]]))
        content.append(try line("event_msg", ["type": "task_started", "turn_id": "turn"]))
        try content.write(to: log)
        let reader = LocalCodexReader(codexHome: home, allowedRoot: workspace)
        var observed = try unwrap(reader.read().first)
        try expectNil(observed.taskNumber); try expectEqual(observed.turns.first?.state, .running)
        let command = try line("response_item", ["type": "message", "role": "user", "content": [["text": "做功能\n关联任务【T#01】"]]])
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: command.dropLast())
        try expectNil(try reader.read().first?.taskNumber)
        try handle.write(contentsOf: Data([10]))
        let nested = workspace.appendingPathComponent("api").path
        let arguments = String(data: try JSONSerialization.data(withJSONObject: ["workdir": nested]), encoding: .utf8)!
        try handle.write(contentsOf: line("response_item", ["type": "function_call", "name": "functions.exec_command", "arguments": arguments]))
        try handle.write(contentsOf: line("turn_context", ["cwd": directory.appendingPathComponent("forbidden").path]))
        try handle.write(contentsOf: line("event_msg", ["type": "task_complete", "turn_id": "turn"]))
        observed = try unwrap(reader.read().first)
        try expectEqual(observed.taskNumber, 1); try expectEqual(observed.turns.count, 1)
        try expectEqual(observed.turns[0].state, .completed)
        try expectEqual(observed.workspaces.map(\.path), [workspace.path, nested])
        try expectEqual(try reader.read().first, observed)
        try handle.write(contentsOf: line("response_item", ["type": "message", "role": "assistant", "content": [["text": "关联Codex Task【T#99】"]]]))
        try handle.write(contentsOf: line("event_msg", ["type": "user_message", "message": "示例 关联Codex Task【T#88】\n```\n关联Codex Task【T#77】\n```\n> 关联Codex Task【T#66】"]))
        try expectEqual(try reader.read().first?.taskNumber, 1)
        try handle.write(contentsOf: line("event_msg", ["type": "user_message", "message": "关联Codex Task【T#02】"]))
        try expectEqual(try reader.read().first?.taskNumber, 2)
        let otherReader = LocalCodexReader(codexHome: home, allowedRoot: directory.appendingPathComponent("different-workspace"))
        try expectTrue(try otherReader.read().isEmpty)
        try expectFalse(reader.allows(workspace.path + "-other"))
        let link = workspace.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        try expectFalse(reader.allows(link.path))
    }

    func testWorkspaceIsolationPersistenceAndLegacyData() throws {
        let original = try service.createTask(title: "旧任务")
        try service.saveDraft("原草稿")
        let legacyURL = directory.appendingPathComponent("workbench.sqlite")
        try service.exportBackup(to: legacyURL)
        let catalog = try WorkspaceCatalog(dataDirectory: directory, home: directory.appendingPathComponent("home"))
        let legacy = catalog.active
        try expectEqual(catalog.databaseURL(for: legacy), legacyURL)
        let shop = try unwrap(catalog.workspaces.first { $0.name == "ShopLnkit" })
        let other = try WorkbenchService(databaseURL: catalog.databaseURL(for: shop))
        try expectTrue(try other.snapshot().tasks.isEmpty)
        try expectEqual(try other.snapshot().draft, "")
        let new = try other.createTask(title: "另一工作区的任务")
        try other.saveDraft("另一草稿")
        try expectEqual(new.number, 1)
        try expectEqual(try service.snapshot().tasks.map(\.id), [original.id])
        try catalog.select(shop.id)
        let reopened = try WorkspaceCatalog(dataDirectory: directory)
        try expectEqual(reopened.active, shop)
        try expectEqual(try WorkbenchService(databaseURL: reopened.databaseURL(for: reopened.active)).snapshot().draft, "另一草稿")
        try reopened.select(legacy.id)
        try expectEqual(try WorkbenchService(databaseURL: reopened.databaseURL(for: reopened.active)).snapshot().draft, "原草稿")
    }
    func testWorkspaceMaintenanceBoundariesAndArchiveRestore() throws {
        let catalog = try WorkspaceCatalog(dataDirectory: directory, home: directory.appendingPathComponent("home"))
        let legacy = catalog.active
        try expectThrows(try catalog.save(name: "重复", directory: legacy.directory))
        try expectThrows(try catalog.save(name: "子目录", directory: legacy.directory + "/child"))
        try expectThrows(try catalog.save(name: "父目录", directory: URL(fileURLWithPath: legacy.directory).deletingLastPathComponent().path))
        try expectThrows(try catalog.save(name: "相对目录", directory: "relative"))
        try expectThrows(try catalog.save(name: "根目录", directory: "/Users/.."))
        let path = directory.appendingPathComponent("extra").path
        let added = try catalog.save(name: "新工作区", directory: path)
        let db = try WorkbenchService(databaseURL: catalog.databaseURL(for: added))
        _ = try db.createTask(title: "移除后保留")
        let renamed = try catalog.save(id: added.id, name: "重命名", directory: path)
        try expectEqual(renamed.id, added.id)
        try expectThrows(try catalog.save(id: added.id, name: "改目录", directory: path + "-other"))
        try catalog.select(added.id); try catalog.archive(added.id)
        try expectEqual(catalog.active.id, legacy.id)
        try expectFalse(catalog.workspaces.contains { $0.id == added.id })
        let restored = try catalog.save(name: "恢复", directory: path)
        try expectEqual(restored.id, added.id)
        try expectEqual(try WorkbenchService(databaseURL: catalog.databaseURL(for: restored)).snapshot().tasks.first?.title, "移除后保留")
        try FileManager.default.createDirectory(atPath: legacy.directory, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: legacy.directory)
        try expectThrows(try catalog.save(name: "别名", directory: alias.path))
        try catalog.archive(restored.id)
        let shop = try unwrap(catalog.workspaces.first { $0.id != legacy.id })
        try catalog.archive(shop.id)
        try expectThrows(try catalog.archive(legacy.id))
    }
    func testWorkspaceCorruptRegistryIsPreserved() throws {
        let catalog = try WorkspaceCatalog(dataDirectory: directory)
        let registry = directory.appendingPathComponent("workspaces.json")
        let valid = try Data(contentsOf: registry)
        let bytes = Data("{broken".utf8)
        try bytes.write(to: registry)
        try expectThrows(try WorkspaceCatalog(dataDirectory: directory))
        try expectEqual(try Data(contentsOf: registry), bytes)
        try expectEqual(catalog.workspaces.count, 2)
        var object = try unwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var workspaces = try unwrap(object["workspaces"] as? [[String: Any]])
        workspaces[0]["directory"] = "relative"
        object["workspaces"] = workspaces
        let invalidPath = try JSONSerialization.data(withJSONObject: object)
        try invalidPath.write(to: registry)
        try expectThrows(try WorkspaceCatalog(dataDirectory: directory))
        try expectEqual(try Data(contentsOf: registry), invalidPath)
    }

    func testSuggestionAdoptionConcurrentAndNoAutomaticRun() throws {
        let task = try service.createTask(title: "源任务")
        let suggestion = try service.propose(taskID: task.id, title: "后续", reason: "发现")
        let workers = try (0..<3).map { _ in try WorkbenchService(databaseURL: url) }
        let errors = ErrorCollector()
        DispatchQueue.concurrentPerform(iterations: 12) { index in do { _ = try workers[index % 3].adopt(suggestionID: suggestion.id) } catch { errors.add(error) } }
        try expectEqual(errors.messages, [])
        let state = try service.snapshot()
        try expectEqual(state.tasks.count, 2); try expectEqual(state.runs.count, 0)
        try expectEqual(state.suggestions[0].adoptedTaskID, state.tasks[1].id)
        let ignored = try service.propose(taskID: task.id, title: "忽略项", reason: "")
        try service.ignore(suggestionID: ignored.id)
        try expectThrows(try service.adopt(suggestionID: ignored.id))
    }
    func testFixedSHAAndPreviewInvalidation() throws {
        let (_, _, branch) = try fixture()
        let plan = try service.prepareDeployment(branchID: branch.id, environment: "test", parameters: "mode=check", taskID: nil)
        try expectEqual(plan.scope.sha, branch.sha)
        try service.advanceMockBranch(branchID: branch.id)
        try expectThrows(try service.confirmDeployment(planID: plan.id, expectedDigest: plan.digest))
        try expectEqual(try service.snapshot().pipelines.count, 0)
        let fresh = try service.prepareDeployment(branchID: branch.id, environment: "test", parameters: "mode=check", taskID: nil)
        let run = try service.confirmDeployment(planID: fresh.id, expectedDigest: fresh.digest)
        try expectEqual(run.sha, fresh.scope.sha); try expectNotEqual(run.sha, branch.sha)
    }
    func testChangedParametersOrEnvironmentInvalidatePreviousPreview() throws {
        let (_, _, branch) = try fixture()
        let old = try service.prepareDeployment(branchID: branch.id, environment: "test", parameters: "a=1", taskID: nil)
        let fresh = try service.prepareDeployment(branchID: branch.id, environment: "dev", parameters: "a=2", taskID: nil)
        try expectNotEqual(old.digest, fresh.digest)
        try expectThrows(try service.confirmDeployment(planID: old.id, expectedDigest: old.digest))
        try expectThrows(try service.confirmDeployment(planID: fresh.id, expectedDigest: old.digest))
    }
    func testConcurrentConfirmationOnlySubmitsOnceAndSurvivesRestart() throws {
        let (_, _, branch) = try fixture()
        let plan = try service.prepareDeployment(branchID: branch.id, environment: "test", parameters: "", taskID: nil)
        let workers = try (0..<3).map { _ in try WorkbenchService(databaseURL: url) }
        let errors = ErrorCollector()
        DispatchQueue.concurrentPerform(iterations: 18) { index in do { _ = try workers[index % 3].confirmDeployment(planID: plan.id, expectedDigest: plan.digest) } catch { errors.add(error) } }
        try expectEqual(errors.messages, [])
        let state = try service.snapshot(); try expectEqual(state.pipelines.count, 1)
        try service.updateMockPipeline(runID: state.pipelines[0].id, next: .unknown)
        try service.advanceMockBranch(branchID: branch.id)
        let reopened = try WorkbenchService(databaseURL: url)
        let receipt = try reopened.confirmDeployment(planID: plan.id, expectedDigest: plan.digest)
        try expectEqual(receipt.id, state.pipelines[0].id); try expectEqual(receipt.state, .unknown)
        try expectEqual(try reopened.snapshot().pipelines.count, 1)
    }
    func testProductionAndUnknownEnvironmentRejected() throws {
        let (_, _, branch) = try fixture()
        for environment in ["prod", "eu", "sea", "publish", "", "staging", "Test"] {
            try expectThrows(try service.prepareDeployment(branchID: branch.id, environment: environment, parameters: "", taskID: nil))
        }
        try expectEqual(try service.snapshot().plans.count, 0)
    }
    func testBackupPreservesIdentityHistoryAndCounter() throws {
        let (task, _, _) = try fixture()
        _ = try service.startMockRun(taskID: task.id)
        try service.saveDraft("重启草稿")
        let backup = directory.appendingPathComponent("backup.sqlite")
        try service.exportBackup(to: backup)
        try expectThrows(try service.exportBackup(to: backup))
        let restored = try WorkbenchService(databaseURL: backup)
        try expectEqual(try restored.snapshot(), try service.snapshot())
        try expectEqual(try restored.createTask(title: "恢复后新任务").number, 2)
    }
    func testFutureSchemaRefusedAndCorruptionNotOverwritten() throws {
        _ = try service.createTask(title: "保留")
        try sql("PRAGMA user_version=99")
        try expectThrows(try WorkbenchService(databaseURL: url))
        try sql("PRAGMA user_version=1")
        try sql("UPDATE document SET payload=x'7b7d'")
        try expectThrows(try WorkbenchService(databaseURL: url))
        try expectThrows(try service.snapshot())
    }
    func testSeedIsIdempotentAndQuickEntryAtomic() throws {
        try service.seedDemoIfEmpty(); try service.seedDemoIfEmpty()
        try expectEqual(try service.snapshot().tasks.count, 1)
        try service.saveDraft("新任务")
        _ = try service.createTask(title: "新任务", clearDraft: true)
        try expectEqual(try service.snapshot().draft, "")
        try expectEqual(try service.snapshot().tasks.count, 2)
    }
    func testAdapterAuthorizationAndRestrictedAutomationSurface() throws {
        let (task, project, branch) = try fixture()
        let allowed = MockCodexAdapter(service: service, caller: CallerScope(authorizedProjectIDs: [project.id]))
        let denied = MockCodexAdapter(service: service, caller: CallerScope(authorizedProjectIDs: []))
        try expectThrows(try denied.resolve(number: task.displayNumber))
        _ = try allowed.attach(number: task.displayNumber, sessionID: "bridge-session")
        try expectThrows(try denied.start(sessionID: "bridge-session"))
        let run = try allowed.start(sessionID: "bridge-session")
        try expectThrows(try denied.report(runID: run.id, state: .completed, sequence: 1, summary: "spoof", eventID: "denied"))
        try allowed.report(runID: run.id, state: .completed, sequence: 1, summary: "mock done", eventID: "bridge-done")
        try expectFalse(try service.snapshot().tasks[0].isDone)
        try expectFalse(allowed.capabilities.reliableExistingSessionLifecycle)
        let pipeline = MockPipelineAdapter(service: service)
        try expectFalse(pipeline.capabilities.canTriggerRealDeployment)
        let plan = try pipeline.prepare(branchID: branch.id, environment: "test", parameters: "", taskID: task.id)
        _ = try pipeline.confirm(planID: plan.id, expectedDigest: plan.digest)
        try expectEqual(try pipeline.listRuns(projectID: project.id, environment: "test").count, 1)
    }
    func testUnknownLegacySchemaBackedUpBeforeRefusal() throws {
        _ = try service.createTask(title: "旧结构保留")
        try sql("PRAGMA user_version=0")
        try expectThrows(try WorkbenchService(databaseURL: url))
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("before-migration-") }
        try expectEqual(backups.count, 1)
        try expectTrue((try Data(contentsOf: backups[0])).count > 0)
        try sql("PRAGMA user_version=1")
        try expectEqual(try service.snapshot().tasks[0].title, "旧结构保留")
    }

}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; storage.append(error.localizedDescription) }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

struct AssertionFailure: Error, CustomStringConvertible {
    var description: String
}
func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) throws {
    let a = try actual(); let e = try expected()
    if a != e { throw AssertionFailure(description: "\(file):\(line): expected \(e), got \(a)") }
}
func expectNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, line: UInt = #line) throws {
    if try a() == b() { throw AssertionFailure(description: "line \(line): unexpectedly equal") }
}
func expectTrue(_ value: @autoclosure () throws -> Bool, line: UInt = #line) throws {
    if try !value() { throw AssertionFailure(description: "line \(line): expected true") }
}
func expectFalse(_ value: @autoclosure () throws -> Bool, line: UInt = #line) throws {
    if try value() { throw AssertionFailure(description: "line \(line): expected false") }
}
func expectNil<T>(_ value: @autoclosure () throws -> T?, line: UInt = #line) throws {
    if try value() != nil { throw AssertionFailure(description: "line \(line): expected nil") }
}
func expectNotNil<T>(_ value: @autoclosure () throws -> T?, line: UInt = #line) throws {
    if try value() == nil { throw AssertionFailure(description: "line \(line): expected non-nil") }
}
func unwrap<T>(_ value: T?, line: UInt = #line) throws -> T {
    guard let value else { throw AssertionFailure(description: "line \(line): nil value") }; return value
}
func expectThrows<T>(_ body: @autoclosure () throws -> T, line: UInt = #line) throws {
    do { _ = try body() } catch { return }
    throw AssertionFailure(description: "line \(line): expected operation to throw")
}


extension WorkbenchCoreTests {
    func testHTTPBridgeAuthenticationLimitsAndCleanup() throws {
        let endpoint = directory.appendingPathComponent("bridge/endpoint.json")
        let received = DispatchSemaphore(value: 0), ready = DispatchSemaphore(value: 0)
        let bridge = try CodexEventBridge(endpointURL: endpoint) { _ in received.signal() }
        bridge.start { if $0 { ready.signal() } }
        defer { bridge.stop() }
        try expectEqual(ready.wait(timeout: .now() + 3), .success)
        let attributes = try FileManager.default.attributesOfItem(atPath: endpoint.path)
        try expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let config = try unwrap(JSONSerialization.jsonObject(with: Data(contentsOf: endpoint)) as? [String: Any])
        let address = try unwrap(config["url"] as? String), token = try unwrap(config["token"] as? String)
        try expectEqual(URL(string: address)?.host, "127.0.0.1")
        func request(_ body: Data, auth: String?, path: String? = nil) throws -> Int {
            let done = DispatchSemaphore(value: 0), result = HTTPTestResult()
            var r = URLRequest(url: URL(string: path ?? address)!, timeoutInterval: 2)
            r.httpMethod = "POST"; r.httpBody = body
            if let auth { r.setValue("Bearer " + auth, forHTTPHeaderField: "Authorization") }
            let session = URLSession(configuration: .ephemeral)
            session.dataTask(with: r) { _, response, _ in result.set((response as? HTTPURLResponse)?.statusCode ?? 0); done.signal() }.resume()
            defer { session.invalidateAndCancel() }
            try expectEqual(done.wait(timeout: .now() + 3), .success)
            return result.get()
        }
        let event = CodexBridgeEvent(receiptURL: directory.appendingPathComponent("receipt.json"))
        let body = try JSONEncoder().encode(event)
        try expectEqual(try request(body, auth: nil), 401)
        try expectEqual(try request(body, auth: String(repeating: "0", count: 64)), 401)
        try expectEqual(try request(Data("{}".utf8), auth: token), 400)
        try expectEqual(try request(body, auth: token, path: address + "/other"), 404)
        try expectTrue(try request(Data(repeating: 32, count: 17 * 1024), auth: token) != 202)
        try expectEqual(received.wait(timeout: .now() + 0.05), .timedOut)
        try expectTrue(CodexBridgeClient.notify(event, endpointURL: endpoint))
        try expectEqual(received.wait(timeout: .now() + 1), .success)
        bridge.stop()
        try expectTrue(!FileManager.default.fileExists(atPath: endpoint.path))
        try expectTrue(!CodexBridgeClient.notify(event, endpointURL: endpoint))
    }

    func testHTTPHookScriptToTargetedReaderAndService() throws { try exerciseHTTPHook(native: false) }
    func testNativeHTTPHookToTargetedReaderAndService() throws { try exerciseHTTPHook(native: true) }
    private func exerciseHTTPHook(native: Bool) throws {
        let home = directory.appendingPathComponent("codex"), workspace = directory.appendingPathComponent("workspace")
        let status = home.appendingPathComponent("codex-tasks-status"), endpoint = home.appendingPathComponent("bridge/endpoint.json")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("sessions/one.jsonl"), otherLog = home.appendingPathComponent("sessions/two.jsonl")
        try Data().write(to: log); try Data().write(to: otherLog)
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT,rollout_path TEXT,git_branch TEXT,git_sha TEXT,updated_at INT); INSERT INTO threads VALUES('one','One','\(workspace.path)','\(log.path)','','',1); INSERT INTO threads VALUES('two','Two','\(workspace.path)','\(otherLog.path)','','',2);"
        try expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let reader = LocalCodexReader(codexHome: home, allowedRoot: workspace)
        let task = try service.createTask(title: "HTTP lifecycle")
        try service.synchronizeSession(ObservedSession(id: "one", name: "One", cwd: workspace.path), taskID: task.id)
        try expectEqual(try reader.read().count, 2)
        try expectEqual(reader.sessionIDs(forChangedPaths: [log.path]), ["one"])
        try expectNil(reader.sessionIDs(forChangedPaths: [home.appendingPathComponent("state_5.sqlite-wal").path]))
        try expectEqual(reader.sessionIDs(forChangedPaths: [home.appendingPathComponent("sessions/unrelated.jsonl").path]), [])
        let ready = DispatchSemaphore(value: 0), applied = DispatchSemaphore(value: 0)
        let bridge = try CodexEventBridge(endpointURL: endpoint) { [service] event in
            guard let hook = event.hook, let observed = try? reader.read(sessionIDs: [hook.sessionID]).first else { return }
            try? service?.synchronizeSession(reader.applying(hook, to: observed))
            applied.signal()
        }
        bridge.start { if $0 { ready.signal() } }; defer { bridge.stop() }
        try expectEqual(ready.wait(timeout: .now() + 3), .success)
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/codex-status-hook.py")
        func send(_ name: String) throws {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = native ? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("CodexStatusHook") : URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = (native ? [] : [script.path]) + ["--status-directory", status.path, "--endpoint-file", endpoint.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["session_id": "one", "turn_id": "turn", "cwd": workspace.path, "hook_event_name": name, "prompt": String(repeating: "synthetic-private-prompt", count: 8192), "agent_id": NSNull(), "agent_type": NSNull()]))
            try input.fileHandleForWriting.close(); process.waitUntilExit()
            try expectEqual(process.terminationStatus, 0)
            try expectTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
        try send("UserPromptSubmit"); try expectEqual(applied.wait(timeout: .now() + 2), .success)
        try expectEqual(try service.snapshot().runs.last?.state, .running)
        try send("Stop"); try expectEqual(applied.wait(timeout: .now() + 2), .success)
        try expectEqual(try service.snapshot().runs.last?.state, .completed)
        try send("UserPromptSubmit") // A late async start cannot overwrite the durable terminal record.
        try expectEqual(applied.wait(timeout: .now() + 0.05), .timedOut)
        try expectEqual(try reader.read(sessionIDs: ["one"]).count, 1)
        try expectEqual(try reader.read(sessionIDs: ["one"]).first?.turns.last?.state, .completed)
        try expectTrue(!(try service.snapshot().tasks[0].isDone))
        try expectTrue(try reader.read(sessionIDs: ["unknown"]).isEmpty)
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let invalid = CodexHookStatus(sessionID: "one", turnID: "wrong", cwd: directory.path, event: "Stop", updatedAt: date.string(from: Date()))
        let observed = try unwrap(reader.read(sessionIDs: ["one"]).first)
        try expectEqual(reader.applying(invalid, to: observed), observed)
        // Simulate restart: no HTTP endpoint, durable status still reconstructs the run.
        bridge.stop()
        let recovered = LocalCodexReader(codexHome: home, allowedRoot: workspace)
        try expectEqual(try recovered.read().first { $0.id == "one" }?.turns.last?.state, .completed)
    }
}
private final class HTTPTestResult: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func set(_ value: Int) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main struct AcceptanceRunner {
    static func main() {
        let suite = WorkbenchCoreTests()
        let tests: [(String, () throws -> Void)] = [
            ("testDeleteTaskCleansLocalRelationsAndKeepsNumbersAndPipelines", suite.testDeleteTaskCleansLocalRelationsAndKeepsNumbersAndPipelines),
            ("testHTTPBridgeAuthenticationLimitsAndCleanup", suite.testHTTPBridgeAuthenticationLimitsAndCleanup),
            ("testHTTPHookScriptToTargetedReaderAndService", suite.testHTTPHookScriptToTargetedReaderAndService),
            ("testNativeHTTPHookToTargetedReaderAndService", suite.testNativeHTTPHookToTargetedReaderAndService),
            ("testHookSidecarLifecycleAndBoundaries", suite.testHookSidecarLifecycleAndBoundaries),
            ("testGitInspectionFollowsBranchAndRejectsExternalGitDirectory", suite.testGitInspectionFollowsBranchAndRejectsExternalGitDirectory),
            ("testRealSessionBindingAndDynamicProjects", suite.testRealSessionBindingAndDynamicProjects),
            ("testRealSessionOneToOneAndStaleCommands", suite.testRealSessionOneToOneAndStaleCommands),
            ("testManualProjectMatchesAutomaticWorkspace", suite.testManualProjectMatchesAutomaticWorkspace),
            ("testWorkspaceIsolationPersistenceAndLegacyData", suite.testWorkspaceIsolationPersistenceAndLegacyData),
            ("testWorkspaceMaintenanceBoundariesAndArchiveRestore", suite.testWorkspaceMaintenanceBoundariesAndArchiveRestore),
            ("testWorkspaceCorruptRegistryIsPreserved", suite.testWorkspaceCorruptRegistryIsPreserved),
            ("testCodexPromptDeepLinkAndWorkspaceMetadataIsolation", suite.testCodexPromptDeepLinkAndWorkspaceMetadataIsolation),
            ("testCodexDispatchExecutesExactPromptAndBindsSession", suite.testCodexDispatchExecutesExactPromptAndBindsSession),
            ("testCodexDispatchReportsFailuresWithoutPretendingToSend", suite.testCodexDispatchReportsFailuresWithoutPretendingToSend),
            ("testLargeSessionPublishesRecentStateBeforeHistory", suite.testLargeSessionPublishesRecentStateBeforeHistory),
            ("testLocalReaderCommandsIncrementalAndScope", suite.testLocalReaderCommandsIncrementalAndScope),
            ("testStableNumbersCompletionAndReopen", suite.testStableNumbersCompletionAndReopen),
            ("testConcurrentNumberAllocationAcrossConnections", suite.testConcurrentNumberAllocationAcrossConnections),
            ("testWriteFailureLeavesTrustedStateAndDraft", suite.testWriteFailureLeavesTrustedStateAndDraft),
            ("testVersionConflictDoesNotOverwriteOtherEdit", suite.testVersionConflictDoesNotOverwriteOtherEdit),
            ("testCompletionRetryIsIdempotent", suite.testCompletionRetryIsIdempotent),
            ("testRunsAndPipelinesNeverChangeManualCompletion", suite.testRunsAndPipelinesNeverChangeManualCompletion),
            ("testConcurrentRunsAggregateAndLateEventsDoNotRevive", suite.testConcurrentRunsAggregateAndLateEventsDoNotRevive),
            ("testEventIdempotenceMismatchAndNoticeDeduplication", suite.testEventIdempotenceMismatchAndNoticeDeduplication),
            ("testRecoveryUnknownRetainsTimestampAndCanReconcile", suite.testRecoveryUnknownRetainsTimestampAndCanReconcile),
            ("testFollowAndLinkAreIndependentWithUndoDefaults", suite.testFollowAndLinkAreIndependentWithUndoDefaults),
            ("testUndoDoesNotOverwriteLaterUserChanges", suite.testUndoDoesNotOverwriteLaterUserChanges),
            ("testResolveCurrentProjectPriorityAndAmbiguity", suite.testResolveCurrentProjectPriorityAndAmbiguity),
            ("testResolveRejectsUnauthorizedAndPlainNumberAndUnrelatedContext", suite.testResolveRejectsUnauthorizedAndPlainNumberAndUnrelatedContext),
            ("testBranchUnknownRetainsHistoryAndBlocksResolution", suite.testBranchUnknownRetainsHistoryAndBlocksResolution),
            ("testSessionReattachmentDoesNotMoveRunHistory", suite.testSessionReattachmentDoesNotMoveRunHistory),
            ("testSuggestionAdoptionConcurrentAndNoAutomaticRun", suite.testSuggestionAdoptionConcurrentAndNoAutomaticRun),
            ("testFixedSHAAndPreviewInvalidation", suite.testFixedSHAAndPreviewInvalidation),
            ("testChangedParametersOrEnvironmentInvalidatePreviousPreview", suite.testChangedParametersOrEnvironmentInvalidatePreviousPreview),
            ("testConcurrentConfirmationOnlySubmitsOnceAndSurvivesRestart", suite.testConcurrentConfirmationOnlySubmitsOnceAndSurvivesRestart),
            ("testProductionAndUnknownEnvironmentRejected", suite.testProductionAndUnknownEnvironmentRejected),
            ("testBackupPreservesIdentityHistoryAndCounter", suite.testBackupPreservesIdentityHistoryAndCounter),
            ("testFutureSchemaRefusedAndCorruptionNotOverwritten", suite.testFutureSchemaRefusedAndCorruptionNotOverwritten),
            ("testSeedIsIdempotentAndQuickEntryAtomic", suite.testSeedIsIdempotentAndQuickEntryAtomic),
            ("testAdapterAuthorizationAndRestrictedAutomationSurface", suite.testAdapterAuthorizationAndRestrictedAutomationSurface),
            ("testUnknownLegacySchemaBackedUpBeforeRefusal", suite.testUnknownLegacySchemaBackedUpBeforeRefusal)
        ]
        var results: [[String: Any]] = []
        for (name, test) in tests {
            let start = Date()
            do {
                try suite.setUpWithError()
                try test()
                results.append(["name": name, "passed": true, "seconds": Date().timeIntervalSince(start)])
                print("PASS \(name)")
            } catch {
                results.append(["name": name, "passed": false, "error": String(describing: error)])
                print("FAIL \(name): \(error)")
            }
            try? suite.tearDownWithError()
        }
        let failed = results.filter { ($0["passed"] as? Bool) != true }.count
        let report: [String: Any] = ["passed": failed == 0, "total": tests.count, "failed": failed, "tests": results, "platform": ProcessInfo.processInfo.operatingSystemVersionString]
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1) {
            do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) } catch { print("Report write failed: \(error)"); exit(2) }
        }
        print("\(tests.count - failed)/\(tests.count) passed")
        if failed > 0 { exit(1) }
    }
}
