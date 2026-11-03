import AppKit
import Combine
import LiteCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = TaskSnapshot()
    @Published private(set) var observations: [ObservedSession] = []
    @Published var selectedTaskID: Int64?
    @Published var errorMessage: String?
    @Published var draft: String { didSet { preferences.set(draft, forKey: "lite.quickDraft") } }
    let store: TaskStore
    private let preferences: UserDefaults
    private let reader: CodexReader
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

    init(store: TaskStore, preferences: UserDefaults = .standard, reader: CodexReader = CodexReader(), initialObservations: [ObservedSession] = []) throws {
        self.store = store; self.preferences = preferences; self.reader = reader
        self.observations = initialObservations
        self.draft = preferences.string(forKey: "lite.quickDraft") ?? ""
        snapshot = try store.snapshot(); selectedTaskID = snapshot.tasks.first?.id
    }
    func start() {
        stopped = false
        monitor = CodexMonitor { [weak self] in self?.scheduleRead() }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleRead() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        scheduleRead(delay: 0)
    }
    func stop() { stopped = true; timer?.invalidate(); timer = nil; scheduled?.cancel(); monitor = nil }
    func scheduleRead(delay: TimeInterval = 0.3) {
        guard !stopped else { return }
        scheduled?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readSessions() }
        scheduled = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func readSessions() {
        guard !isReading else { readAgain = true; return }
        isReading = true
        let reader = reader, store = store
        queue.async { [weak self] in
            do {
                let beforeRead = try store.snapshot()
                let earliest = beforeRead.tasks.map(\.createdAt).min() ?? .distantFuture
                let linked = Set(beforeRead.sessions.filter { $0.taskID != nil }.map(\.id))
                let sessions = try reader.read(notBefore: earliest, linkedSessionIDs: linked)
                try store.reconcile(sessions)
                let pending = reader.hasPendingReads
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    self.isReading = false
                    if self.observations != sessions { self.observations = sessions }
                    do { try self.refresh() } catch { self.errorMessage = error.localizedDescription }
                    if self.sessionReadError != nil { self.objectWillChange.send(); self.sessionReadError = nil }
                    if self.readAgain || pending { self.readAgain = false; self.scheduleRead(delay: 0.2) }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
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
        if !snapshot.tasks.contains(where: { $0.id == selectedTaskID }) { selectedTaskID = snapshot.tasks.first?.id }
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
    func status(_ task: TaskItem, _ status: TaskStatus) { perform { try store.setStatus(task.id, status) } }
    func rename(_ task: TaskItem, _ title: String) {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines) != task.title else { return }
        perform { try store.renameTask(task.id, title: title) }
    }
    func delete(_ task: TaskItem) {
        let position = snapshot.tasks.firstIndex { $0.id == task.id } ?? 0
        guard perform({ try store.deleteTask(task.id) }) else { return }
        if !snapshot.tasks.isEmpty { selectedTaskID = snapshot.tasks[min(position, snapshot.tasks.count - 1)].id }
    }
    func attach(_ session: ObservedSession, to task: TaskItem) { if perform({ try store.attach(session, to: task.id) }) { scheduleRead(delay: 0) } }
    func detach(_ session: SessionItem) { perform { try store.detach(session.id) } }
    func copyPrompt(_ task: TaskItem) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.associationPrompt, forType: .string)
    }
    func open(_ session: SessionItem) {
        guard UUID(uuidString: session.id) != nil,
              let url = URL(string: "codex://threads/\(session.id)"), NSWorkspace.shared.open(url) else {
            errorMessage = "无法打开 Codex 会话。请确认本机已安装并启动 Codex。"; return
        }
    }
    func showCodex() {
        let candidates = ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            errorMessage = "未找到 Codex 应用，请先启动 Codex，再发送关联指令。"; return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
        }
    }
}
