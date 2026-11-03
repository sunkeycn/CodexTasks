import AppKit
import Combine
import WorkbenchCore
import Darwin

@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable { case tasks = "任务", projects = "项目", cicd = "CI/CD" }
    private(set) var service: WorkbenchService
    @Published var snapshot = WorkbenchSnapshot()
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var selectedTaskID: UUID?
    @Published var selectedPipelineID: UUID?
    @Published var selectedFlowConnectionID: UUID?
    @Published var selectedFlowID: String?
    @Published var requestedQuickEntry = false
    var isPinned: Bool { isCompact }
    @Published var isCompact = false { didSet { onCompactChanged?(isCompact) } }
    @Published var section: Section { didSet { preferences.set(section.rawValue, forKey: "selectedSection") } }
    @Published var unlinkReceipt: UnlinkReceipt?
    var onCompactChanged: ((Bool) -> Void)?
    var onHide: (() -> Void)?
    @Published var sessions: [ObservedSession] = []
    @Published var syncStatus = "等待本机 Codex 同步"
    @Published var lastSync: Date?
    // Background I/O is an internal guard, not a reason to invalidate the editor.
    private(set) var isSyncing = false
    @Published private(set) var isManualSyncing = false
    var isDemo = false
    @Published private(set) var workspaces: [WorkSpace] = []
    @Published private(set) var activeWorkspace: WorkSpace
    @Published var showWorkspaceSettings = false
    @Published private(set) var sendingTaskIDs = Set<UUID>()
    private var dispatchTimer: Timer?
    private var dispatchReceipts = Set<URL>()
    private var dispatchStates: [URL: CodexDispatchReceipt.State] = [:]
    private var openedDispatchSessions = Set<String>()
    private let catalog: WorkspaceCatalog
    private var reader: LocalCodexReader
    private let codexHome: URL
    private var bridgeReady = false
    private var syncGeneration = UUID()
    private let syncQueue = DispatchQueue(label: "workbench.codex-reader", qos: .userInitiated)
    private var syncTimer: Timer?
    private var syncWakeObserver: NSObjectProtocol?
    private var syncActivationObserver: NSObjectProtocol?
    static let syncFallbackInterval: TimeInterval = 60
    private var changeMonitor: CodexChangeMonitor?
    private var eventBridge: CodexEventBridge?
    private var requestedSessionIDs: Set<String>? = []
    private var hookRecords: [String: CodexHookStatus] = [:]
    private var hookRetries: [String: Int] = [:]
    private var deferredDiscovery = false
    private var scheduledSync: DispatchWorkItem?
    private var syncRequested = false
    private let workspaceQueue = DispatchQueue(label: "workbench.git-metadata", qos: .utility)
    private var isRefreshingWorkspaces = false
    private var lastWorkspaceRefresh = Date.distantPast
    private var workspaceInputs: [String: [ObservedWorkspace]] = [:]
    private let preferences: UserDefaults

    init(service: WorkbenchService, preferences: UserDefaults = .standard, codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) throws {
        self.codexHome = codexHome
        catalog = try WorkspaceCatalog(dataDirectory: service.databaseURL.deletingLastPathComponent())
        activeWorkspace = catalog.active
        workspaces = catalog.workspaces
        self.service = catalog.databaseURL(for: catalog.active) == service.databaseURL ? service : try WorkbenchService(databaseURL: catalog.databaseURL(for: catalog.active))
        reader = LocalCodexReader(codexHome: codexHome, allowedRoot: URL(fileURLWithPath: catalog.active.directory))
        self.preferences = preferences
        section = Section(rawValue: preferences.string(forKey: "selectedSection") ?? "") ?? .tasks
        try self.service.recoverInterruptedRuns()
        refresh()
        selectedTaskID = snapshot.tasks.first?.id
        resumeCodexDispatches()
    }
    func switchWorkspace(_ id: UUID) {
        guard id != activeWorkspace.id else { return }
        do {
            guard let workspace = catalog.workspaces.first(where: { $0.id == id }) else { return }
            let nextService = try WorkbenchService(databaseURL: catalog.databaseURL(for: workspace))
            try nextService.recoverInterruptedRuns()
            try catalog.select(id)
            syncGeneration = UUID()
            resetWorkspaceSync()
            service = nextService
            reader = LocalCodexReader(codexHome: codexHome, allowedRoot: URL(fileURLWithPath: workspace.directory))
            activeWorkspace = workspace; workspaces = catalog.workspaces
            sessions = []; lastSync = nil; isSyncing = false; isManualSyncing = false
            errorMessage = nil; toast = nil; unlinkReceipt = nil; selectedPipelineID = nil; selectedFlowID = nil; selectedFlowConnectionID = nil
            syncStatus = "等待本机 Codex 同步"
            refresh(); selectedTaskID = snapshot.tasks.first?.id
            resumeCodexDispatches()
            syncNow()
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult func saveWorkspace(id: UUID? = nil, name: String, path: String) -> Bool {
        do {
            let workspace = try catalog.save(id: id, name: name, directory: path)
            workspaces = catalog.workspaces
            if workspace.id == activeWorkspace.id {
                activeWorkspace = workspace
                syncGeneration = UUID(); resetWorkspaceSync(); isSyncing = false; isManualSyncing = false; sessions = []; lastSync = nil
                reader = LocalCodexReader(codexHome: codexHome, allowedRoot: URL(fileURLWithPath: workspace.directory))
                syncNow()
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func archiveWorkspace(_ workspace: WorkSpace) {
        do {
            // Switch first so the active service always matches the selected workspace.
            if workspace.id == activeWorkspace.id, let other = workspaces.first(where: { $0.id != workspace.id }) {
                switchWorkspace(other.id)
                guard activeWorkspace.id == other.id else { return }
            }
            try catalog.archive(workspace.id); workspaces = catalog.workspaces
        } catch { errorMessage = error.localizedDescription }
    }
    func isRunning(_ task: WorkTask) -> Bool {
        snapshot.runs.contains { $0.taskID == task.id && $0.state == .running }
    }
    var compactTasks: [WorkTask] {
        snapshot.tasks.filter { !$0.isDone || isRunning($0) }.sorted {
            let leftRunning = isRunning($0), rightRunning = isRunning($1)
            if leftRunning != rightRunning { return leftRunning }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.number > $1.number
        }
    }
    func attachment(for task: WorkTask) -> SessionAttachment? { snapshot.attachments.first { $0.taskID == task.id } }
    func openSession(_ attachment: SessionAttachment) {
        guard let url = URL(string: "codex://threads/\(attachment.sessionID)"), NSWorkspace.shared.open(url) else {
            errorMessage = "无法打开 Codex 会话，请确认本机已安装 Codex。"; return
        }
    }
    func copyAssociationPrompt(_ task: WorkTask) { copy(task.associationPrompt) }
    func sendToCodex(_ task: WorkTask, notes: String, title: String) {
        guard attachment(for: task) == nil, !sendingTaskIDs.contains(task.id) else { return }
        guard CodexDispatchRunner.executableURL() != nil else {
            errorMessage = "未找到本机 Codex CLI，请安装或更新 Codex。"; return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexTaskRunner")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            errorMessage = "应用中缺少 Codex 发送组件，请重新打包。"; return
        }
        let request = CodexDispatchRequest(task: task, databaseURL: service.databaseURL, workspace: activeWorkspace.directory, notes: notes, title: title)
        do {
            let payload = try JSONEncoder().encode(request)
            try CodexDispatchReceipt(taskID: task.id).save(to: request.receiptURL)
            let process = Process(), input = Pipe()
            process.executableURL = helper; process.standardInput = input
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            dispatchReceipts.insert(request.receiptURL); sendingTaskIDs.insert(task.id)
            toast = "正在提交至 Codex…"
            startDispatchTimer()
        } catch {
            try? FileManager.default.removeItem(at: request.receiptURL)
            errorMessage = "无法提交至 Codex：" + error.localizedDescription
        }
    }
    private func resumeCodexDispatches() {
        dispatchTimer?.invalidate(); dispatchTimer = nil
        dispatchReceipts.removeAll(); dispatchStates.removeAll(); sendingTaskIDs.removeAll()
        let directory = service.databaseURL.deletingLastPathComponent().appendingPathComponent("codex-dispatch")
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            if let receipt = try? CodexDispatchReceipt.read(from: url), receipt.isPending {
                dispatchReceipts.insert(url)
                // Restoring a running task must not steal focus from this chat.
                if let id = receipt.sessionID { openedDispatchSessions.insert(id) }
                if receipt.state == .starting { sendingTaskIDs.insert(receipt.taskID) }
            }
        }
        if !dispatchReceipts.isEmpty { startDispatchTimer() }
    }
    private func startDispatchTimer() {
        guard dispatchTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollCodexDispatches() }
        }
        RunLoop.main.add(timer, forMode: .common); dispatchTimer = timer
    }
    private func pollCodexDispatches() {
        for url in Array(dispatchReceipts) {
            guard var receipt = try? CodexDispatchReceipt.read(from: url) else { continue }
            if receipt.isPending {
                let workerGone = receipt.runnerPID.map { kill($0, 0) != 0 && errno == ESRCH } ?? (Date().timeIntervalSince(receipt.updatedAt) > 30)
                if workerGone {
                    receipt.state = .unknown
                    receipt.message = "Codex 发送组件已退出，执行结果尚未确认。请先在 Codex 中检查会话，避免重复提交。"
                    try? receipt.save(to: url)
                }
            }
            if let id = receipt.sessionID, !openedDispatchSessions.contains(id) {
                openedDispatchSessions.insert(id)
                refresh()
                if let attachment = snapshot.attachments.first(where: { $0.sessionID == id }) { openSession(attachment) }
            }
            if dispatchStates[url] != receipt.state {
                dispatchStates[url] = receipt.state
                refresh(); scheduleSync()
                switch receipt.state {
                case .starting: break
                case .running: toast = "已发送至 Codex，任务已开始执行"
                case .completed: toast = "Codex 已执行完成"
                case .failed, .unknown: errorMessage = receipt.message ?? "Codex 执行失败，请打开会话检查。"
                }
            }
            if receipt.state != .starting { sendingTaskIDs.remove(receipt.taskID) }
            if !receipt.isPending { dispatchReceipts.remove(url) }
        }
        if dispatchReceipts.isEmpty { dispatchTimer?.invalidate(); dispatchTimer = nil }
    }
    func copyStatusHookConfiguration() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexStatusHook")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            errorMessage = "应用中缺少状态上报组件，请重新打包。"; return
        }
        let command = "'" + helper.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let hooks = Dictionary(uniqueKeysWithValues: ["UserPromptSubmit", "Stop", "Interrupt"].map { event in
            (event, [["hooks": [["type": "command", "command": command, "timeout": 3, "async": true] as [String: Any]]]])
        })
        do {
            let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
            copy(String(decoding: data, as: UTF8.self))
            toast = "已复制 Hooks 配置；请按接入说明合并，并在 Codex 中审核信任"
        } catch { errorMessage = error.localizedDescription }
    }
    func openStatusHookGuide() {
        guard let url = Bundle.main.url(forResource: "CODEX-HOOKS", withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }
    func stopLiveSync() {
        syncTimer?.invalidate(); syncTimer = nil
        scheduledSync?.cancel(); scheduledSync = nil
        changeMonitor = nil
        eventBridge?.stop(); eventBridge = nil; bridgeReady = false
        if let observer = syncWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = syncActivationObserver { NotificationCenter.default.removeObserver(observer) }
        syncWakeObserver = nil; syncActivationObserver = nil
    }
    func startLiveSync() {
        guard syncTimer == nil else { return }
        if !isDemo {
            do {
                let bridge = try CodexEventBridge(endpointURL: codexHome.appendingPathComponent("codex-tasks-bridge/endpoint.json")) { [weak self] event in
                    DispatchQueue.main.async { self?.receiveBridgeEvent(event) }
                }
                eventBridge = bridge
                bridge.start { [weak self] ready in DispatchQueue.main.async { self?.bridgeReady = ready } }
            } catch { /* File events and the fallback timer remain available. */ }
        }
        changeMonitor = CodexChangeMonitor(home: codexHome, onChanges: { [weak self] paths in
            guard let self else { return }
            let reader = self.reader, generation = self.syncGeneration
            self.syncQueue.async {
                let ids = paths.flatMap { reader.sessionIDs(forChangedPaths: $0) }
                DispatchQueue.main.async {
                    guard self.syncGeneration == generation else { return }
                    if ids?.isEmpty != true { self.scheduleSync(after: ids == nil ? 0.3 : 0.05, sessionIDs: ids) }
                }
            }
        })
        syncNow()
        syncWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync(after: 0.3) }
        }
        syncActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync() }
        }
        let timer = Timer(timeInterval: Self.syncFallbackInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }
    func receiveBridgeEvent(_ event: CodexBridgeEvent) {
        guard !isDemo else { return }
        if event.kind == "dispatch", let path = event.receiptPath {
            guard dispatchReceipts.contains(URL(fileURLWithPath: path).standardizedFileURL) else { return }
            pollCodexDispatches(); return
        }
        guard event.kind == "hook", let record = event.hook else { return }
        // Queue by session, retaining the latest metadata while a sync is in flight.
        if let previous = hookRecords[record.sessionID], previous.updatedAt > record.updatedAt { return }
        hookRecords[record.sessionID] = record
        // A queued discovery scan must not turn a direct HTTP update into a full scan.
        if requestedSessionIDs == nil {
            deferredDiscovery = true; requestedSessionIDs = []
            scheduledSync?.cancel(); scheduledSync = nil
        }
        scheduleSync(after: 0, sessionIDs: [record.sessionID])
    }
    private func scheduleSync(after delay: TimeInterval = 0.3, sessionIDs: Set<String>? = nil) {
        guard !isDemo else { return }
        if requestedSessionIDs != nil {
            if let sessionIDs { requestedSessionIDs?.formUnion(sessionIDs) } else { requestedSessionIDs = nil }
        }
        if isSyncing { syncRequested = true; return }
        if scheduledSync != nil {
            if delay > 0 { return }
            scheduledSync?.cancel(); scheduledSync = nil
        }
        let work = DispatchWorkItem { [weak self] in
            self?.scheduledSync = nil
            guard let self else { return }; self.syncNow(sessionIDs: self.requestedSessionIDs)
        }
        scheduledSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func syncNow(manual: Bool = false, sessionIDs: Set<String>? = nil) {
        guard !isDemo else { return }
        if manual && !isManualSyncing { isManualSyncing = true }
        guard !isSyncing else { scheduleSync(sessionIDs: sessionIDs); return }
        scheduledSync?.cancel(); scheduledSync = nil
        isSyncing = true; syncRequested = false; requestedSessionIDs = []
        if sessionIDs == nil { deferredDiscovery = false }
        let records = hookRecords.filter { sessionIDs?.contains($0.key) ?? true }
        for id in records.keys { hookRecords.removeValue(forKey: id) }
        let service = service, reader = reader, generation = syncGeneration
        syncQueue.async { [weak self] in
            do {
                let sessions = try reader.read(sessionIDs: sessionIDs).map { observed in
                    records[observed.id].map { reader.applying($0, to: observed) } ?? observed
                }
                let needsHistory = reader.needsHistory(sessionIDs: sessionIDs)
                let state = try service.snapshot()
                if sessionIDs == nil { try service.markUnavailableSessions(availableIDs: Set(sessions.filter { !$0.turns.isEmpty }.map(\.id))) }
                var warnings: [String] = []
                for session in sessions {
                    let linked = state.attachments.contains { $0.sessionID == session.id }
                    let requested = state.tasks.contains { $0.number == session.taskNumber && (session.commandAt ?? .distantPast) >= $0.createdAt }
                    guard linked || requested else { continue }
                    do {
                        var observed = session
                        observed.workspaces = [] // Git runs independently of the session/title/state path.
                        try service.synchronizeSession(observed)
                        if let warning = session.warning { warnings.append("\(session.name)：\(warning)") }
                    } catch { warnings.append(error.localizedDescription) }
                }
                DispatchQueue.main.async {
                    guard let self, self.syncGeneration == generation else { return }
                    self.isSyncing = false
                    let merged = sessionIDs.map { ids in self.sessions.filter { !ids.contains($0.id) } + sessions } ?? sessions
                    self.publishSyncResult(merged, warnings: warnings)
                    let attachedIDs = Set(self.snapshot.attachments.map(\.sessionID))
                    self.refreshWorkspaces(merged.filter { attachedIDs.contains($0.id) })
                    for (id, record) in records {
                        if sessions.contains(where: { $0.id == id }) { self.hookRetries.removeValue(forKey: id); continue }
                        let count = self.hookRetries[id, default: 0]
                        guard count < 3 else { self.hookRetries.removeValue(forKey: id); continue }
                        self.hookRetries[id] = count + 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * pow(2, Double(count))) { [weak self] in
                            guard let self, self.syncGeneration == generation else { return }
                            self.receiveBridgeEvent(CodexBridgeEvent(hook: record))
                        }
                    }
                    if self.syncRequested { self.scheduleSync(sessionIDs: self.requestedSessionIDs) }
                    else if needsHistory { self.scheduleSync(sessionIDs: sessionIDs) }
                    else if self.deferredDiscovery { self.deferredDiscovery = false; self.scheduleSync() }
                }
            } catch {
                if sessionIDs == nil { try? service.markUnavailableSessions(availableIDs: []) }
                DispatchQueue.main.async {
                    guard let self, self.syncGeneration == generation else { return }
                    self.refresh()
                    self.isSyncing = false
                    if self.isManualSyncing { self.isManualSyncing = false }
                    let status = "同步失败：" + error.localizedDescription
                    if self.syncStatus != status { self.syncStatus = status }
                    if self.syncRequested { self.scheduleSync(sessionIDs: self.requestedSessionIDs) }
                }
            }
        }
    }
    // Tool/log writes and database bookkeeping can trigger reads without changing
    // any user-visible data. Publish only semantic changes, with stable ordering.
    func publishSyncResult(_ observed: [ObservedSession], warnings: [String]) {
        let ordered = observed.sorted { $0.id < $1.id }
        let sessionsChanged = sessions != ordered
        let snapshotChanged = refresh()
        let status = warnings.sorted().first ?? "已同步 \(ordered.count) 个本机会话 · \(bridgeReady ? "HTTP + 文件事件" : (changeMonitor?.isActive == true ? "文件事件驱动" : "监听不可用")) / 60 秒兜底"
        let statusChanged = syncStatus != status
        if sessionsChanged { sessions = ordered }
        if statusChanged { syncStatus = status }
        if sessionsChanged || snapshotChanged || statusChanged || lastSync == nil || isManualSyncing {
            lastSync = Date()
        }
        if isManualSyncing { isManualSyncing = false }
    }
    private func resetWorkspaceSync() {
        isRefreshingWorkspaces = false; lastWorkspaceRefresh = .distantPast; workspaceInputs = [:]
        syncRequested = false; requestedSessionIDs = []; hookRecords = [:]; hookRetries = [:]; deferredDiscovery = false
    }
    private func refreshWorkspaces(_ sessions: [ObservedSession]) {
        let inputs = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.workspaces) })
        guard !isRefreshingWorkspaces, !inputs.isEmpty,
              inputs != workspaceInputs || Date().timeIntervalSince(lastWorkspaceRefresh) >= 15 else { return }
        isRefreshingWorkspaces = true
        let service = service, reader = reader, generation = syncGeneration
        workspaceQueue.async { [weak self] in
            var failure: String?
            var inspected: [String: ObservedWorkspace] = [:]
            for session in sessions {
                do {
                    let workspaces = session.workspaces.map { workspace -> ObservedWorkspace in
                        if let cached = inspected[workspace.path] { return cached }
                        let result = reader.inspectWorkspace(workspace); inspected[workspace.path] = result; return result
                    }
                    try service.synchronizeSessionWorkspaces(sessionID: session.id, workspaces: workspaces)
                } catch { failure = error.localizedDescription }
            }
            DispatchQueue.main.async {
                guard let self, self.syncGeneration == generation else { return }
                self.isRefreshingWorkspaces = false; self.lastWorkspaceRefresh = Date(); self.workspaceInputs = inputs
                self.refresh()
                if let failure { self.syncStatus = "项目同步失败：" + failure }
            }
        }
    }
    func attachSession(_ session: ObservedSession, task: WorkTask) {
        guard !isSyncing else { toast = "正在同步，请稍后关联"; return }
        isSyncing = true
        let reader = reader, service = service, generation = syncGeneration
        syncQueue.async { [weak self] in
            do {
                var observed = session
                observed.workspaces = session.workspaces.map { reader.inspectWorkspace($0) }
                try service.synchronizeSession(observed, taskID: task.id)
                DispatchQueue.main.async {
                    guard let self, self.syncGeneration == generation else { return }
                    self.isSyncing = false; self.refresh(); self.toast = "已关联 \(task.displayNumber) 与 \(session.name)"
                }
            } catch {
                DispatchQueue.main.async { guard let self, self.syncGeneration == generation else { return }; self.isSyncing = false; self.errorMessage = error.localizedDescription }
            }
        }
    }
    func chooseProjectDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = "选择 \(activeWorkspace.name) 工作区内的项目目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard reader.allows(url.path) else { errorMessage = "请选择当前工作区 \(activeWorkspace.directory) 范围内的目录。"; return }
        let reader = reader, service = service, generation = syncGeneration
        syncQueue.async { [weak self] in
            do {
                let workspace = reader.inspectWorkspace(ObservedWorkspace(path: url.path))
                let project = try service.createProject(name: URL(fileURLWithPath: workspace.path).lastPathComponent, repository: workspace.repositoryIdentity ?? "local:" + workspace.path, checkoutPath: workspace.path)
                DispatchQueue.main.async { guard let self, self.syncGeneration == generation else { return }; self.refresh(); self.toast = "已登记项目：\(project.name)" }
            } catch {
                DispatchQueue.main.async { guard let self, self.syncGeneration == generation else { return }; self.errorMessage = error.localizedDescription }
            }
        }
    }
    @discardableResult func refresh() -> Bool {
        do {
            let current = try service.snapshot()
            guard current != snapshot else { return false }
            snapshot = current
            return true
        } catch {
            let message = error.localizedDescription
            if errorMessage != message { errorMessage = message }
            return false
        }
    }
    @discardableResult func perform(_ operation: () throws -> Void) -> Bool {
        do { try operation(); refresh(); return true }
        catch { refresh(); errorMessage = error.localizedDescription; return false }
    }
    func saveDraft(_ text: String) { perform { try service.saveDraft(text) } }
    func markUpdatesRead() { perform { try service.markNoticesRead() } }
    func addQuickTask() {
        perform {
            let task = try service.createTask(title: snapshot.draft, clearDraft: true)
            selectedTaskID = task.id
            copyAssociationPrompt(task)
            section = .tasks
        }
    }
    func deleteTask(_ task: WorkTask) {
        let previousIndex = snapshot.tasks.firstIndex { $0.id == task.id } ?? 0
        guard perform({ try service.deleteTask(taskID: task.id, expectedVersion: task.version) }) else { return }
        if selectedTaskID == task.id {
            selectedTaskID = snapshot.tasks.isEmpty ? nil : snapshot.tasks[min(previousIndex, snapshot.tasks.count - 1)].id
        }
        if unlinkReceipt?.link.taskID == task.id { unlinkReceipt = nil }
        toast = "已删除 \(task.displayNumber)；Codex 会话仍保留"
    }
    func toggle(_ task: WorkTask) { perform { try service.setCompleted(taskID: task.id, value: !task.isDone, expectedVersion: task.version) } }
    func unlink(taskID: UUID, branchID: UUID) { perform { unlinkReceipt = try service.unlink(taskID: taskID, branchID: branchID); toast = "已解除关联，分支与历史仍保留" } }
    func undoUnlink() {
        guard let receipt = unlinkReceipt else { return }
        if perform({ try service.undoUnlink(receipt) }) { unlinkReceipt = nil; toast = "已恢复关联与默认入口" }
    }
    func openTask(_ id: UUID) { selectedTaskID = id; section = .tasks }
    func openNotice(_ notice: UpdateNotice) {
        if let pipeline = notice.pipelineRunID { section = .cicd; selectedPipelineID = pipeline }
        else if let id = notice.taskID { openTask(id) }
    }
    func startRun(_ task: WorkTask) {
        perform { _ = try service.startMockRun(taskID: task.id, branchID: task.defaultBranchID, sessionID: "mock-\(task.displayNumber)") }
    }
    func report(_ run: CodexRun, _ state: RunState) {
        perform { try service.reportRun(runID: run.id, state: state, sequence: run.sequence + 1, summary: "手动模拟：\(state.label)", eventID: UUID().uuidString) }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); toast = "已复制 \(text)" }
}
