import Foundation
import LiteCore

@MainActor
func runTaskListAcceptance(model: AppModel) throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let originalFilter = model.taskFilter
    let originalSelection = model.selectedTaskID
    let parent = try model.store.createTask(title: "筛选验收主任务")
    let child = try model.store.createTask(title: "筛选验收子任务", parentID: parent)
    let sibling = try model.store.createTask(title: "筛选验收已完成子任务", parentID: parent)
    let other = try model.store.createTask(title: "排序验收主任务")
    defer {
        try? model.store.deleteTask(child); try? model.store.deleteTask(sibling)
        try? model.store.deleteTask(parent); try? model.store.deleteTask(other)
        model.taskFilter = originalFilter; try? model.refresh(); model.selectedTaskID = originalSelection
    }
    try model.refresh()
    let details = "## 任务描述\n\n- **自动保存**\n- 独立于状态与排序"
    checks["taskDescriptionSavedThroughModel"] = model.updateDetails(parent, details)
        && model.snapshot.tasks.first { $0.id == parent }?.details == details
    checks["taskDescriptionSurvivesModelRestart"] = try AppModel(store: model.store, preferences: UserDefaults(suiteName: "ai.sunkey.codextasks.lite.smoke")!).snapshot.tasks.first { $0.id == parent }?.details == details
    checks["taskDescriptionDoesNotChangeChild"] = model.snapshot.tasks.first { $0.id == child }?.details == ""
    try model.store.setStatus(sibling, .done)
    try model.store.setStatus(other, .doing)
    try model.refresh()
    checks["taskFilterDefaultsToActive"] = model.taskFilter == .active
    model.taskFilter = .active
    checks["activeIncludesTodoAndDoing"] = [parent, child, other].allSatisfy { id in model.visibleTasks.contains { $0.id == id } }
    checks["activeHidesCompletedChildren"] = !model.visibleTasks.contains { $0.id == sibling }
    model.selectedTaskID = child
    model.status(model.selectedTask!, .done)
    checks["completingSelectedTaskSelectsVisibleTask"] = model.selectedTaskID != child && model.selectedTask?.status != .done
    try model.store.setStatus(child, .doing); try model.store.setStatus(parent, .done)
    try model.refresh()
    if !model.collapsedTaskIDs.contains(parent) { model.toggleExpanded(model.snapshot.tasks.first { $0.id == parent }!) }
    checks["activeHidesDoneParentButKeepsUnfinishedChild"] = !model.visibleTasks.contains { $0.id == parent } && model.visibleTasks.contains { $0.id == child }
    model.taskFilter = .all
    checks["allIncludesCompletedParent"] = model.visibleTasks.contains { $0.id == parent }
    model.toggleExpanded(model.snapshot.tasks.first { $0.id == parent }!)
    checks["allIncludesCompletedChildrenWhenExpanded"] = model.visibleTasks.contains { $0.id == sibling }
    let prefs = UserDefaults(suiteName: "ai.sunkey.codextasks.lite.smoke")!
    checks["taskFilterSurvivesRestart"] = try AppModel(store: model.store, preferences: prefs).taskFilter == .all
    model.selectedTaskID = parent; model.taskFilter = .active
    checks["filterChangeNormalizesSelection"] = model.selectedTaskID != parent
    model.moveTask(other, relativeTo: model.snapshot.tasks.first { $0.id == parent }!, placement: .before)
    let order = model.snapshot.rootTasks.map(\.id)
    model.taskFilter = .all
    checks["taskOrderSharedAcrossFilters"] = model.snapshot.rootTasks.map(\.id) == order
    let sessionTask = model.snapshot.rootTasks.first { model.snapshot.sessions(for: $0.id).count > 1 }!
    let sessions = model.snapshot.sessions(for: sessionTask.id)
    model.moveSession(sessions[1].id, relativeTo: sessions[0], in: sessionTask.id, placement: .before)
    checks["sessionDragUpdatesModel"] = model.snapshot.sessions(for: sessionTask.id).prefix(2).map(\.id) == [sessions[1].id, sessions[0].id]
    try model.refresh()
    checks["sessionOrderSurvivesModelRefresh"] = model.snapshot.sessions(for: sessionTask.id).prefix(2).map(\.id) == [sessions[1].id, sessions[0].id]
    model.moveSession(sessions[0].id, relativeTo: sessions[1], in: sessionTask.id, placement: .before)
    let bottom = model.snapshot.sessions(for: sessionTask.id).last!
    let nextActivity = model.snapshot.sessions(for: sessionTask.id).map(\.updatedAt).max()!.addingTimeInterval(1)
    try model.store.reconcile([ObservedSession(id: bottom.id, title: bottom.title, status: bottom.status, updatedAt: nextActivity, projectName: bottom.projectName)])
    try model.refresh()
    checks["sessionNewActivityOverridesManualBottomPosition"] = model.snapshot.sessions(for: sessionTask.id).first?.id == bottom.id
    try model.refresh()
    checks["sessionActivityOrderSurvivesModelRefresh"] = model.snapshot.sessions(for: sessionTask.id).first?.id == bottom.id
    checks.merge(try runTaskActivityAcceptance()) { _, new in new }
    return checks
}
