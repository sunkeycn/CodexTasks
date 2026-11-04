import Foundation
import LiteCore

@MainActor
func runTaskActivityAcceptance() throws -> [String: Bool] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-tasks-activity-\(UUID().uuidString)")
    let suite = "ai.sunkey.codextasks.activity.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        try? FileManager.default.removeItem(at: directory)
        preferences.removePersistentDomain(forName: suite)
    }
    let store = try TaskStore(url: directory.appendingPathComponent("tasks.sqlite"))
    let parent = try store.createTask(title: "运行状态主任务")
    let child = try store.createTask(title: "运行状态子任务", parentID: parent)
    let sibling = try store.createTask(title: "无运行子任务", parentID: parent)
    let other = try store.createTask(title: "独立主任务")
    let model = try AppModel(store: store, preferences: preferences)
    func task(_ id: Int64) -> TaskItem { model.snapshot.tasks.first { $0.id == id }! }
    func activity(_ id: Int64) -> TaskSessionActivity { model.sessionActivity(task(id)) }
    var checks: [String: Bool] = [:]
    checks["idleTaskHasNoActivityIndicator"] = activity(parent) == .none
    let base = Date()
    var first = ObservedSession(id: UUID().uuidString, title: "运行一", status: .running, updatedAt: base)
    var second = ObservedSession(id: UUID().uuidString, title: "运行二", status: .running, updatedAt: base)
    try store.attach(first, to: child)
    try store.attach(second, to: child)
    try model.refresh()
    checks["runningChildShowsSpinner"] = activity(child) == .running
    checks["expandedParentAggregatesRunningChild"] = activity(parent) == .running
    checks["runningChildDoesNotAffectSiblingOrOtherTask"] = activity(sibling) == .none && activity(other) == .none
    model.toggleExpanded(task(parent))
    checks["collapsedParentAggregatesRunningChild"] = activity(parent) == .running && !model.visibleTasks.contains { $0.id == child }
    try store.setStatus(child, .done)
    try model.refresh()
    checks["filteredCompletedChildStillMakesParentSpin"] = activity(parent) == .running && !model.visibleTasks.contains { $0.id == child }
    first.status = .completed; first.updatedAt = base.addingTimeInterval(1)
    try store.reconcile([first]); try model.refresh()
    checks["remainingRunningSessionTakesPriorityOverUnreadCompletion"] = task(child).hasUnreadCompletion && activity(child) == .running && activity(parent) == .running
    second.status = .completed; second.updatedAt = base.addingTimeInterval(2)
    try store.reconcile([second]); try model.refresh()
    checks["lastSessionCompletionReplacesSpinnerWithRedDot"] = activity(child) == .unreadCompletion && activity(parent) == .unreadCompletion
    model.selectTask(task(parent))
    checks["readingParentPreservesChildCompletionAfterRun"] = activity(parent) == .unreadCompletion
    model.taskFilter = .all
    model.selectTask(task(child))
    checks["readingChildClearsCompletionAfterRun"] = activity(child) == .none && activity(parent) == .none
    first.status = .running; first.updatedAt = base.addingTimeInterval(3)
    try store.reconcile([first]); try model.refresh()
    checks["newTurnRestartsChildAndParentSpinners"] = activity(child) == .running && activity(parent) == .running
    first.status = .failed; first.updatedAt = base.addingTimeInterval(4)
    try store.reconcile([first]); try model.refresh()
    checks["failedSessionStopsSpinnerWithoutCompletionDot"] = activity(child) == .none && activity(parent) == .none
    first.status = .running; first.updatedAt = base.addingTimeInterval(5)
    try store.reconcile([first]); try model.refresh()
    first.status = .interrupted; first.updatedAt = base.addingTimeInterval(6)
    try store.reconcile([first]); try model.refresh()
    checks["interruptedSessionStopsSpinner"] = activity(child) == .none && activity(parent) == .none
    first.status = .running; first.updatedAt = base.addingTimeInterval(7)
    try store.reconcile([first]); try model.refresh()
    try store.detach(first.id); try model.refresh()
    checks["detachedRunningSessionStopsTaskSpinners"] = activity(child) == .none && activity(parent) == .none
    try store.attach(first, to: parent); try model.refresh()
    checks["directParentSessionShowsSpinnerWithoutChildActivity"] = activity(parent) == .running && activity(child) == .none
    let restored = try AppModel(store: store, preferences: preferences)
    checks["runningIndicatorRestoresFromStoredSessionState"] = restored.sessionActivity(task(parent)) == .running
    return checks
}
