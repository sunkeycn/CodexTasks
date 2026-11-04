import AppKit
import Combine
import LiteCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = TaskSnapshot()
    @Published private(set) var observations: [ObservedSession] = []
    @Published var selectedTaskID: Int64?
    @Published private(set) var collapsedTaskIDs: Set<Int64> = [] {
        didSet { preferences.set(collapsedTaskIDs.sorted().map(String.init), forKey: "lite.collapsedTasks") }
    }
    @Published var taskFilter: TaskListFilter = .active {
        didSet {
            preferences.set(taskFilter.rawValue, forKey: "lite.taskFilter")
            normalizeSelection()
        }
    }
    @Published var isRecordingShortcut = false
    var applyWindowShortcut: ((WindowShortcut) throws -> Void)?
    @Published var errorMessage: String?
    @Published var draft: String { didSet { preferences.set(draft, forKey: "lite.quickDraft") } }
    let store: TaskStore
    private let preferences: UserDefaults
    @Published private(set) var settings: IntegrationSettings
    @Published private(set) var hookInspection: HookInspection?
    @Published private(set) var hookInspectionError: String?
    let settingsStore: IntegrationSettingsStore
    private var reader: CodexReader
    private var readGeneration = 0
    var hookInstaller: HookInstaller {
        HookInstaller(home: settings.homeURL, integrationDirectory: store.url.deletingLastPathComponent().appendingPathComponent("Integration", isDirectory: true))
    }
    var bundledHookHelper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexTasksHook") }
    private let queue = DispatchQueue(label: "ai.sunkey.codextasks.lite.reader", qos: .utility)
    private var monitor: CodexMonitor?
    private var timer: Timer?
    private var scheduled: DispatchWorkItem?
    private var isReading = false
    private var readAgain = false
    private var stopped = true
    private var sessionReadError: String?
    var selectedTask: TaskItem? { snapshot.tasks.first { $0.id == selectedTaskID } }
    var sessions: [SessionItem] { selectedTaskID.map { snapshot.sessions(for: $0) } ?? [] }
    var pickerMessage: String? { sessionReadError }
    var visibleTasks: [TaskItem] {
        snapshot.rootTasks.flatMap { root -> [TaskItem] in
            let children = snapshot.children(of: root.id)
            if taskFilter == .active && root.status == .done {
                // A completed parent must not hide its unfinished children.
                return children.filter { $0.status != .done }
            }
            return [root] + (collapsedTaskIDs.contains(root.id) ? [] : children.filter { taskFilter == .all || $0.status != .done })
        }
    }
    var sidebarWidth: CGFloat {
        let saved = preferences.double(forKey: "lite.sidebarWidth")
        return saved.isFinite && saved >= 180 ? min(440, saved) : 300
    }
    func rememberSidebarWidth(_ width: CGFloat) { preferences.set(Double(width), forKey: "lite.sidebarWidth") }
    func selectTask(_ task: TaskItem) {
        if let parentID = task.parentID { collapsedTaskIDs.remove(parentID) }
        selectedTaskID = task.id
        if task.hasUnreadCompletion { perform { try store.markTaskRead(task.id) } }
    }
    func toggleExpanded(_ task: TaskItem) {
        if collapsedTaskIDs.contains(task.id) { collapsedTaskIDs.remove(task.id) }
        else {
            collapsedTaskIDs.insert(task.id)
            if selectedTask?.parentID == task.id { selectedTaskID = task.id }
        }
    }
    func hasUnreadCompletion(_ task: TaskItem) -> Bool {
        task.hasUnreadCompletion || (collapsedTaskIDs.contains(task.id) && snapshot.children(of: task.id).contains { $0.hasUnreadCompletion })
    }

    init(store: TaskStore, preferences: UserDefaults = .standard, reader: CodexReader? = nil, initialObservations: [ObservedSession] = []) throws {
        self.store = store; self.preferences = preferences
        let configuration = IntegrationSettingsStore(url: store.url.deletingLastPathComponent().appendingPathComponent("settings.json"))
        self.settingsStore = configuration
        let settings: IntegrationSettings
        var configurationError: String?
        do { settings = try configuration.load() }
        catch { settings = IntegrationSettings(); configurationError = error.localizedDescription }
        self.settings = settings
        self.reader = reader ?? CodexReader(home: settings.homeURL, runningTimeout: settings.runningTimeout)
        self.observations = initialObservations
        self.collapsedTaskIDs = Set((preferences.stringArray(forKey: "lite.collapsedTasks") ?? []).compactMap(Int64.init))
        self.draft = preferences.string(forKey: "lite.quickDraft") ?? ""
        self.taskFilter = TaskListFilter(rawValue: preferences.string(forKey: "lite.taskFilter") ?? "") ?? .active
        snapshot = try store.snapshot(); selectedTaskID = visibleTasks.first?.id
        errorMessage = configurationError
    }
    func start() {
        stopped = false
        monitor = CodexMonitor(home: settings.homeURL, eventDirectory: hookInstaller.eventDirectory) { [weak self] in
            guard let self else { return }
            try? self.refresh()
            self.scheduleRead(delay: 0.05)
        }
        let timer = Timer(timeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleRead() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        scheduleRead(delay: 0)
    }
    func stop() {
        stopped = true; readGeneration += 1; isReading = false; readAgain = false
        timer?.invalidate(); timer = nil; scheduled?.cancel(); monitor = nil
    }
    func refreshHookInspection() {
        do { hookInspection = try hookInstaller.inspect(); hookInspectionError = nil }
        catch { hookInspection = nil; hookInspectionError = error.localizedDescription }
    }
    @discardableResult func applySettings(_ draft: IntegrationSettings) -> Bool {
        do {
            let validated = try draft.validated()
            if validated.homeURL != settings.homeURL {
                let old = try hookInstaller.inspect()
                guard old.installedEvents.isEmpty && old.legacyHandlers == 0 else { throw LiteError.message("请先移除旧目录中的 Codex Tasks Hooks，再切换 Codex 数据目录。") }
            }
            let previousShortcut = settings.windowShortcut
            let shortcutChanged = previousShortcut != validated.windowShortcut
            if shortcutChanged { try applyWindowShortcut?(validated.windowShortcut) }
            do { try settingsStore.save(validated) }
            catch {
                if shortcutChanged { try? applyWindowShortcut?(previousShortcut) }
                throw error
            }
            let wasRunning = !stopped
            stop(); settings = validated
            reader = CodexReader(home: validated.homeURL, runningTimeout: validated.runningTimeout)
            observations = []
            refreshHookInspection()
            if wasRunning { start() }
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func installHooks() throws -> URL? {
        _ = try settings.validated()
        let backup = try hookInstaller.install(helper: bundledHookHelper)
        refreshHookInspection()
        if !stopped { stop(); start() }
        return backup
    }
    func removeHooks() throws -> URL? {
        let backup = try hookInstaller.uninstall()
        refreshHookInspection()
        return backup
    }
    func scheduleRead(delay: TimeInterval = 0.3) {
        guard !stopped else { return }
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readSessions() }
        scheduled = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func readSessions() {
        guard !isReading else { readAgain = true; return }
        isReading = true
        let reader = reader, store = store, generation = readGeneration
        let events = HookEventStore(directory: hookInstaller.eventDirectory)
        let timeout = settings.runningTimeout
        queue.async { [weak self] in
            do {
                let beforeRead = try store.snapshot()
                let earliest = beforeRead.tasks.map(\.createdAt).min() ?? .distantFuture
                let linked = Set(beforeRead.sessions.filter { $0.taskID != nil }.map(\.id))
                var indexed: [ObservedSession] = [], readError: String?
                do { indexed = try reader.read(notBefore: earliest, linkedSessionIDs: linked) }
                catch { readError = error.localizedDescription }
                let sessions = try events.merged(with: indexed, snapshot: beforeRead, runningTimeout: timeout)
                let pending = reader.hasPendingReads
                DispatchQueue.main.async {
                    guard let self, !self.stopped, self.readGeneration == generation else { return }
                    self.isReading = false
                    do {
                        // Ignore stale work from the previous settings before writing any associations.
                        try store.reconcile(sessions)
                        if self.observations != sessions { self.observations = sessions }
                        try self.refresh()
                    } catch { self.errorMessage = error.localizedDescription }
                    if self.sessionReadError != readError { self.objectWillChange.send(); self.sessionReadError = readError }
                    if self.readAgain || pending { self.readAgain = false; self.scheduleRead(delay: 0.2) }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, !self.stopped, self.readGeneration == generation else { return }
                    self.isReading = false
                    if self.sessionReadError != message { self.objectWillChange.send(); self.sessionReadError = message }
                    if self.readAgain { self.readAgain = false; self.scheduleRead(delay: 1) }
                }
            }
        }
    }
    func refresh() throws {
        let current = try store.snapshot()
        if current != snapshot { snapshot = current }
        normalizeSelection()
    }
    private func normalizeSelection() {
        if !visibleTasks.contains(where: { $0.id == selectedTaskID }) { selectedTaskID = visibleTasks.first?.id }
    }
    @discardableResult func perform(_ operation: () throws -> Void) -> Bool {
        do { try operation(); try refresh(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func addTask() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var id: Int64?
        if perform({ id = try store.createTask(title: draft) }) {
            selectedTaskID = id; draft = ""
            if let task = selectedTask { copyPrompt(task) }
            scheduleRead(delay: 0)
        }
    }
    @discardableResult func addSubtask(title: String, to parent: TaskItem) -> Bool {
        var id: Int64?
        guard perform({ id = try store.createTask(title: title, parentID: parent.id) }) else { return false }
        collapsedTaskIDs.remove(parent.id)
        selectedTaskID = id
        normalizeSelection()
        if let task = selectedTask { copyPrompt(task) }
        scheduleRead(delay: 0)
        return true
    }
    func moveTask(_ id: Int64, relativeTo target: TaskItem, placement: SortPlacement) {
        perform { try store.moveTask(id, relativeTo: target.id, placement: placement) }
    }
    func moveSession(_ id: String, relativeTo target: SessionItem, in taskID: Int64, placement: SortPlacement) {
        perform { try store.moveSession(id, relativeTo: target.id, in: taskID, placement: placement) }
    }
    func status(_ task: TaskItem, _ status: TaskStatus) { perform { try store.setStatus(task.id, status) } }
    func rename(_ task: TaskItem, _ title: String) {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines) != task.title else { return }
        perform { try store.renameTask(task.id, title: title) }
    }
    @discardableResult func updateDetails(_ taskID: Int64, _ details: String) -> Bool {
        guard let task = snapshot.tasks.first(where: { $0.id == taskID }) else { return false }
        guard task.details != details else { return true }
        return perform { try store.setTaskDetails(taskID, details) }
    }
    func delete(_ task: TaskItem) {
        let position = visibleTasks.firstIndex { $0.id == task.id } ?? 0
        guard perform({ try store.deleteTask(task.id) }) else { return }
        selectedTaskID = visibleTasks.isEmpty ? nil : visibleTasks[min(position, visibleTasks.count - 1)].id
    }
    func attach(_ session: ObservedSession, to task: TaskItem) { if perform({ try store.attach(session, to: task.id) }) { scheduleRead(delay: 0) } }
    func detach(_ session: SessionItem) { perform { try store.detach(session.id) } }
    func copyPrompt(_ task: TaskItem) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.associationPrompt, forType: .string)
    }
    func open(_ session: SessionItem) {
        guard UUID(uuidString: session.id) != nil,
              let url = URL(string: "codex://threads/\(session.id)") else {
            errorMessage = "无法打开 Codex 会话。请确认本机已安装并启动 Codex。"; return
        }
        if let app = resolvedCodexApplication {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
                if error != nil { Task { @MainActor in self.errorMessage = "无法打开 Codex 会话，请检查设置中的应用位置。" } }
            }
        } else if !NSWorkspace.shared.open(url) { errorMessage = "未找到处理 Codex 会话链接的应用，请在设置中选择 Codex。" }
    }
    var resolvedCodexApplication: URL? {
        settings.applicationURL ?? URL(string: "codex://").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }
    func createSession(for task: TaskItem) {
        let url = task.newSessionURL
        if let app = resolvedCodexApplication {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
                if error != nil { Task { @MainActor in self.errorMessage = "无法创建 Codex 会话，请检查设置中的应用位置。" } }
            }
        } else if !NSWorkspace.shared.open(url) {
            errorMessage = "未找到 Codex 应用，请在设置中选择 Codex。"
        }
    }
}
