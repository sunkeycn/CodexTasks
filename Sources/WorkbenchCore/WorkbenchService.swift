import Foundation
import CryptoKit

public final class WorkbenchService: @unchecked Sendable {
    let database: Database
    public init(databaseURL: URL) throws { database = try Database(url: databaseURL) }
    public var databaseURL: URL { database.url }
    public func snapshot() throws -> WorkbenchSnapshot { try database.snapshot() }
    public func exportBackup(to url: URL) throws { try database.backup(to: url) }

    public func seedDemoIfEmpty() throws {
        try database.transaction { state in
            guard !state.demoSeeded else { return }
            state.demoSeeded = true
            guard state.tasks.isEmpty, state.projects.isEmpty else { return }
            let repository = Repository(identity: "mock://workbench-demo")
            let project = Project(name: "工作台示例", repositoryID: repository.id)
            let branch = Branch(projectID: project.id, ref: "feature/local-workbench", sha: Self.mockSHA())
            state.repositories.append(repository)
            state.projects.append(project)
            state.branches.append(branch)
            let task = try Self.newTask(title: "把工作留在手边", notes: "这是一个本地示例。试着记录任务、勾选完成，或在详情中模拟一次 Codex 执行。", acceptance: "任务状态由我决定；自动执行只更新自己的状态。", state: &state)
            state.links.append(TaskBranch(taskID: task.id, branchID: branch.id, isProjectDefault: true))
            state.tasks[0].defaultBranchID = branch.id
        }
    }

    @discardableResult public func createTask(title: String, notes: String = "", acceptance: String = "", branchID: UUID? = nil, clearDraft: Bool = false) throws -> WorkTask {
        try database.transaction { state in
            if let branchID { _ = try Self.branch(branchID, in: state) }
            var task = try Self.newTask(title: title, notes: notes, acceptance: acceptance, state: &state)
            if let branchID {
                state.links.append(TaskBranch(taskID: task.id, branchID: branchID, isProjectDefault: true))
                task.defaultBranchID = branchID
                state.tasks[state.tasks.count - 1] = task
            }
            if clearDraft { state.draft = "" }
            return task
        }
    }
    public func updateTask(id: UUID, title: String, notes: String, acceptance: String, expectedVersion: Int) throws {
        let cleanTitle = try Self.validTitle(title)
        try database.transaction { state in
            let index = try Self.taskIndex(id, in: state)
            try Self.version(state.tasks[index], expectedVersion)
            state.tasks[index].title = cleanTitle
            state.tasks[index].notes = notes
            state.tasks[index].acceptance = acceptance
            state.tasks[index].version += 1
        }
    }
    public func setCompleted(taskID: UUID, value: Bool, expectedVersion: Int) throws {
        try database.transaction { state in
            let index = try Self.taskIndex(taskID, in: state)
            // A retried explicit assignment is safe, even after its own version advanced.
            if state.tasks[index].isDone == value { return }
            try Self.version(state.tasks[index], expectedVersion)
            state.tasks[index].isDone = value
            state.tasks[index].completedAt = value ? Date() : nil
            state.tasks[index].version += 1
        }
    }
    /// Delete local task data only; never touches Codex sessions or project files.
    public func deleteTask(taskID: UUID, expectedVersion: Int) throws {
        try database.transaction { state in
            let index = try Self.taskIndex(taskID, in: state)
            try Self.version(state.tasks[index], expectedVersion)
            let runIDs = Set(state.runs.filter { $0.taskID == taskID }.map(\.id))
            state.tasks.remove(at: index)
            state.links.removeAll { $0.taskID == taskID }
            state.attachments.removeAll { $0.taskID == taskID }
            state.runs.removeAll { $0.taskID == taskID }
            state.eventLedger = state.eventLedger.filter { !runIDs.contains($0.value.runID) }
            state.suggestions.removeAll { $0.taskID == taskID }
            for i in state.suggestions.indices {
                if state.suggestions[i].adoptedTaskID == taskID { state.suggestions[i].adoptedTaskID = nil }
                if let id = state.suggestions[i].sourceRunID, runIDs.contains(id) { state.suggestions[i].sourceRunID = nil }
            }
            state.notices.removeAll { $0.taskID == taskID && $0.pipelineRunID == nil }
            for i in state.notices.indices where state.notices[i].taskID == taskID { state.notices[i].taskID = nil }
            for i in state.pipelines.indices where state.pipelines[i].taskID == taskID { state.pipelines[i].taskID = nil }
            // Executed plans are immutable historical snapshots; pending plans become unusable.
            for i in state.plans.indices where state.plans[i].scope.taskID == taskID && state.plans[i].pipelineRunID == nil {
                state.plans[i].invalidatedReason = "关联任务已删除，请重新生成预览。"
            }
            // nextNumber is intentionally monotonic: old linking instructions cannot bind a new task.
        }
    }
    public func saveDraft(_ text: String) throws { try database.transaction { $0.draft = text } }

    @discardableResult public func createProject(name: String, repository: String, checkoutPath: String = "") throws -> Project {
        let cleanName = try Self.validTitle(name)
        let identity = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else { throw WorkbenchError.invalid("请填写仓库身份（可用 mock://项目名），不会据此读取仓库。") }
        return try database.transaction { state in
            if !checkoutPath.isEmpty {
                let canonical = URL(fileURLWithPath: checkoutPath).resolvingSymlinksInPath().standardizedFileURL.path
                if let checkout = state.checkouts.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == canonical }),
                   let project = state.projects.first(where: { $0.repositoryID == checkout.repositoryID }) { return project }
            }
            guard !state.repositories.contains(where: { $0.identity == identity }) else { throw WorkbenchError.conflict("此仓库身份已登记，请使用已有项目。") }
            let repo = Repository(identity: identity)
            let project = Project(name: cleanName, repositoryID: repo.id)
            state.repositories.append(repo)
            state.projects.append(project)
            if !checkoutPath.isEmpty { state.checkouts.append(Checkout(repositoryID: repo.id, path: checkoutPath)) }
            return project
        }
    }
    @discardableResult public func createBranch(projectID: UUID, ref: String) throws -> Branch {
        let cleanRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRef.isEmpty, !cleanRef.contains("\n") else { throw WorkbenchError.invalid("请输入有效的分支名称。") }
        return try database.transaction { state in
            _ = try Self.project(projectID, in: state)
            guard !state.branches.contains(where: { $0.projectID == projectID && $0.ref == cleanRef }) else { throw WorkbenchError.conflict("该项目已登记这个分支。") }
            let branch = Branch(projectID: projectID, ref: cleanRef, sha: Self.mockSHA())
            state.branches.append(branch)
            return branch
        }
    }
    public func setFollowed(branchID: UUID, value: Bool) throws {
        try database.transaction { state in let index = try Self.branchIndex(branchID, in: state); state.branches[index].isFollowed = value }
    }
    public func setBranchAvailability(branchID: UUID, value: BranchAvailability) throws {
        try database.transaction { state in
            let index = try Self.branchIndex(branchID, in: state)
            state.branches[index].availability = value
            state.branches[index].confirmedAt = Date()
        }
    }
    public func link(taskID: UUID, branchID: UUID) throws {
        try database.transaction { state in
            let index = try Self.taskIndex(taskID, in: state)
            _ = try Self.branch(branchID, in: state)
            guard !state.links.contains(where: { $0.taskID == taskID && $0.branchID == branchID }) else { return }
            state.links.append(TaskBranch(taskID: taskID, branchID: branchID))
            state.tasks[index].version += 1
        }
    }
    public func unlink(taskID: UUID, branchID: UUID) throws -> UnlinkReceipt {
        try database.transaction { state in
            let index = try Self.taskIndex(taskID, in: state)
            guard let linkIndex = state.links.firstIndex(where: { $0.taskID == taskID && $0.branchID == branchID }) else { throw WorkbenchError.missing("关联已不存在。") }
            let removed = state.links.remove(at: linkIndex)
            let wasDefault = state.tasks[index].defaultBranchID == branchID
            if wasDefault { state.tasks[index].defaultBranchID = nil }
            state.tasks[index].version += 1
            return UnlinkReceipt(link: removed, wasTaskDefault: wasDefault, taskVersionAfter: state.tasks[index].version)
        }
    }
    public func undoUnlink(_ receipt: UnlinkReceipt) throws {
        try database.transaction { state in
            let index = try Self.taskIndex(receipt.link.taskID, in: state)
            try Self.version(state.tasks[index], receipt.taskVersionAfter)
            _ = try Self.branch(receipt.link.branchID, in: state)
            guard !state.links.contains(where: { $0.taskID == receipt.link.taskID && $0.branchID == receipt.link.branchID }) else { return }
            state.links.append(receipt.link)
            if receipt.wasTaskDefault { state.tasks[index].defaultBranchID = receipt.link.branchID }
            state.tasks[index].version += 1
        }
    }
    public func setDefaultBranch(taskID: UUID, branchID: UUID?) throws {
        try database.transaction { state in
            let index = try Self.taskIndex(taskID, in: state)
            if let branchID, !state.links.contains(where: { $0.taskID == taskID && $0.branchID == branchID }) { throw WorkbenchError.invalid("默认入口必须是此任务已关联的分支。") }
            state.tasks[index].defaultBranchID = branchID
            state.tasks[index].version += 1
        }
    }
    public func setProjectDefault(taskID: UUID, branchID: UUID) throws {
        try database.transaction { state in
            let taskIndex = try Self.taskIndex(taskID, in: state)
            let branch = try Self.branch(branchID, in: state)
            guard state.links.contains(where: { $0.taskID == taskID && $0.branchID == branchID }) else { throw WorkbenchError.invalid("请先关联该分支。") }
            let projectBranches = Set(state.branches.filter { $0.projectID == branch.projectID }.map(\.id))
            for index in state.links.indices where state.links[index].taskID == taskID && projectBranches.contains(state.links[index].branchID) {
                state.links[index].isProjectDefault = state.links[index].branchID == branchID
            }
            state.tasks[taskIndex].version += 1
        }
    }

    public func resolve(number: String, caller: CallerScope) throws -> ResolvedContext {
        try Self.resolve(number: number, caller: caller, state: database.snapshot())
    }
    @discardableResult public func attach(number: String, sessionID: String, caller: CallerScope) throws -> SessionAttachment {
        guard !sessionID.trimmingCharacters(in: .whitespaces).isEmpty else { throw WorkbenchError.invalid("需要明确的模拟会话标识。") }
        return try database.transaction { state in
            let context = try Self.resolve(number: number, caller: caller, state: state)
            if let index = state.attachments.firstIndex(where: { $0.sessionID == sessionID }) {
                guard state.attachments[index].taskID == context.task.id else { throw WorkbenchError.conflict("此会话已关联其他任务。") }
                state.attachments[index].taskID = context.task.id
                state.attachments[index].branchID = context.branch.id
                state.attachments[index].scopeDescription = context.description
                state.attachments[index].version += 1
                state.attachments[index].attachedAt = Date()
                return state.attachments[index]
            }
            guard !state.attachments.contains(where: { $0.taskID == context.task.id }) else { throw WorkbenchError.conflict("此任务已关联其他会话。") }
            let attachment = SessionAttachment(sessionID: sessionID, taskID: context.task.id, branchID: context.branch.id, scopeDescription: context.description)
            state.attachments.append(attachment)
            return attachment
        }
    }
    public func markUnavailableSessions(availableIDs: Set<String>) throws {
        try database.transaction { state in
            for i in state.runs.indices where state.runs[i].externalTurnID != nil && !availableIDs.contains(state.runs[i].sessionID) && !state.runs[i].state.isTerminal {
                state.runs[i].state = .unknown
                state.runs[i].summary = "本机 Codex 日志暂时不可用"
            }
        }
    }

    /// One task owns one session. Replays refresh metadata but never replace either side.
    public func synchronizeSession(_ observed: ObservedSession, taskID explicitTaskID: UUID? = nil) throws {
        try database.transaction { state in
            let existing = state.attachments.first { $0.sessionID == observed.id }
            let commandedTask = observed.taskNumber.flatMap { number in
                state.tasks.first { $0.number == number && (observed.commandAt ?? .distantPast) >= $0.createdAt }?.id
            }
            // Manual attachment is authoritative over instructions from before that attachment.
            let commandPredatesAttachment = existing.map { (observed.commandAt ?? .distantPast) < $0.attachedAt } ?? false
            let requested = explicitTaskID ?? (commandPredatesAttachment ? nil : commandedTask)
            guard let taskID = requested ?? existing?.taskID else { return }
            let taskIndex = try Self.taskIndex(taskID, in: state)
            if explicitTaskID == nil, existing == nil {
                guard let commandAt = observed.commandAt, commandAt >= state.tasks[taskIndex].createdAt else { return }
            }
            guard !state.attachments.contains(where: { ($0.sessionID == observed.id && $0.taskID != taskID) || ($0.taskID == taskID && $0.sessionID != observed.id) }) else {
                throw WorkbenchError.conflict("\(state.tasks[taskIndex].displayNumber) 与会话关联冲突：每个任务只能关联一个会话，每个会话只能关联一个任务。")
            }
            let attachmentIndex: Int
            if let index = state.attachments.firstIndex(where: { $0.sessionID == observed.id }) { attachmentIndex = index }
            else {
                state.attachments.append(SessionAttachment(sessionID: observed.id, taskID: taskID, branchID: nil, scopeDescription: observed.cwd))
                attachmentIndex = state.attachments.count - 1
            }
            state.attachments[attachmentIndex].sessionName = observed.name
            state.attachments[attachmentIndex].workspacePath = observed.cwd
            state.attachments[attachmentIndex].scopeDescription = observed.cwd
            try Self.synchronizeWorkspaces(observed.workspaces, taskID: taskID, attachmentIndex: attachmentIndex, state: &state)
            for turn in observed.turns {
                // Keep the turn containing the linking instruction, but do not import the entire older chat history.
                let cutoff = observed.commandAt ?? state.attachments[attachmentIndex].attachedAt
                if turn.updatedAt < cutoff && turn.id != observed.turns.last?.id { continue }
                if let i = state.runs.firstIndex(where: { $0.sessionID == observed.id && $0.externalTurnID == turn.id }) {
                    if state.runs[i].state.isTerminal { continue }
                    if state.runs[i].state != turn.state || state.runs[i].updatedAt != turn.updatedAt {
                        state.runs[i].state = turn.state; state.runs[i].updatedAt = turn.updatedAt; state.runs[i].sequence += 1
                        state.runs[i].summary = "本机 Codex：" + turn.state.label
                        state.runs[i].source = turn.source
                    }
                } else {
                    var run = CodexRun(taskID: taskID, sessionID: observed.id, branchID: state.attachments[attachmentIndex].branchID, scopeDescription: observed.cwd)
                    run.externalTurnID = turn.id; run.source = turn.source; run.state = turn.state; run.updatedAt = turn.updatedAt
                    run.summary = "本机 Codex：" + turn.state.label
                    state.runs.append(run)
                }
                if let run = state.runs.first(where: { $0.sessionID == observed.id && $0.externalTurnID == turn.id }), run.state == .completed || run.state.isException {
                    Self.notice(key: "run:\(run.id):\(run.state.rawValue)", taskID: taskID, message: "\(state.tasks[taskIndex].displayNumber)：\(run.state.label)", isError: run.state.isException, state: &state)
                }
            }
        }
    }

    public func synchronizeSessionWorkspaces(sessionID: String, workspaces: [ObservedWorkspace]) throws {
        try database.transaction { state in
            guard let index = state.attachments.firstIndex(where: { $0.sessionID == sessionID }) else { return }
            try Self.synchronizeWorkspaces(workspaces, taskID: state.attachments[index].taskID, attachmentIndex: index, state: &state)
        }
    }
    private static func synchronizeWorkspaces(_ workspaces: [ObservedWorkspace], taskID: UUID, attachmentIndex: Int, state: inout WorkbenchSnapshot) throws {
        let taskIndex = try Self.taskIndex(taskID, in: state)
        var linkedChanged = false
        for workspace in workspaces {
            let canonical = URL(fileURLWithPath: workspace.path).resolvingSymlinksInPath().standardizedFileURL.path
            let identity = workspace.repositoryIdentity ?? "local:" + canonical
            let repositoryID: UUID
            if let checkout = state.checkouts.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == canonical }) {
                repositoryID = checkout.repositoryID
            } else if let repository = state.repositories.first(where: { $0.identity == identity }) { repositoryID = repository.id }
            else {
                let repository = Repository(identity: identity); state.repositories.append(repository); repositoryID = repository.id
            }
            let projectID: UUID
            if let project = state.projects.first(where: { $0.repositoryID == repositoryID }) { projectID = project.id }
            else {
                let project = Project(name: URL(fileURLWithPath: canonical).lastPathComponent, repositoryID: repositoryID)
                state.projects.append(project); projectID = project.id
            }
            if !state.checkouts.contains(where: { $0.repositoryID == repositoryID && $0.path == canonical }) {
                var checkout = Checkout(repositoryID: repositoryID, path: canonical); checkout.authorization = "local-codex-readonly"
                state.checkouts.append(checkout)
            }
            let ref = workspace.branch ?? "未检测到 Git 分支"
            let branchID: UUID
            if let i = state.branches.firstIndex(where: { $0.projectID == projectID && $0.ref == ref }) {
                branchID = state.branches[i].id
                if state.branches[i].sha != (workspace.sha ?? "") { state.branches[i].confirmedAt = Date() }
                state.branches[i].sha = workspace.sha ?? ""
                state.branches[i].availability = workspace.branch == nil ? .unknown : .available
            } else {
                var branch = Branch(projectID: projectID, ref: ref, sha: workspace.sha ?? "")
                branch.availability = workspace.branch == nil ? .unknown : .available
                state.branches.append(branch); branchID = branch.id
            }
            if !state.links.contains(where: { $0.taskID == taskID && $0.branchID == branchID }) {
                state.links.append(TaskBranch(taskID: taskID, branchID: branchID)); linkedChanged = true
            }
            if state.tasks[taskIndex].defaultBranchID == nil { state.tasks[taskIndex].defaultBranchID = branchID; linkedChanged = true }
            if workspace.path == workspaces.first?.path { state.attachments[attachmentIndex].branchID = branchID }
        }
        if linkedChanged { state.tasks[taskIndex].version += 1 }
    }

    @discardableResult public func startMockRun(taskID: UUID, branchID: UUID? = nil, sessionID: String = "mock-local") throws -> CodexRun {
        try database.transaction { state in
            let index = try Self.taskIndex(taskID, in: state)
            var scope = "仅任务记录 · 无项目访问授权"
            if let branchID {
                let branch = try Self.branch(branchID, in: state)
                guard state.links.contains(where: { $0.taskID == taskID && $0.branchID == branchID }) else { throw WorkbenchError.unauthorized("此分支尚未关联到该任务。") }
                guard branch.availability == .available else { throw WorkbenchError.invalid("分支当前不可用，请先确认。") }
                let project = try Self.project(branch.projectID, in: state)
                scope = "\(project.name) / \(branch.ref) @ \(branch.sha) · 模拟元数据"
            }
            let run = CodexRun(taskID: state.tasks[index].id, sessionID: sessionID, branchID: branchID, scopeDescription: scope)
            state.runs.append(run)
            return run
        }
    }
    public func reportRun(runID: UUID, state next: RunState, sequence: Int, summary: String, eventID: String) throws {
        guard !eventID.isEmpty, sequence > 0 else { throw WorkbenchError.invalid("事件需要唯一标识和正整数序号。") }
        try database.transaction { state in
            let event = RunEvent(runID: runID, state: next, sequence: sequence, summary: summary)
            if let previous = state.eventLedger[eventID] {
                guard previous == event else { throw WorkbenchError.conflict("相同事件标识的内容不一致，拒绝覆盖。") }
                return
            }
            guard let index = state.runs.firstIndex(where: { $0.id == runID }) else { throw WorkbenchError.missing("找不到执行记录。") }
            state.eventLedger[eventID] = event
            guard sequence > state.runs[index].sequence else { return }
            guard !state.runs[index].state.isTerminal else { return }
            state.runs[index].state = next
            state.runs[index].sequence = sequence
            state.runs[index].summary = summary
            state.runs[index].updatedAt = Date()
            if next == .completed || next.isException {
                Self.notice(key: "run:\(runID):\(next.rawValue)", taskID: state.runs[index].taskID, message: "\(Self.taskNumber(state.runs[index].taskID, state)): \(next.label) · \(summary)", isError: next.isException, state: &state)
            }
        }
    }
    public func recoverInterruptedRuns() throws {
        try database.transaction { state in
            for index in state.runs.indices where state.runs[index].state == .running || state.runs[index].state == .needsInput {
                state.runs[index].state = .unknown
                state.runs[index].summary = "应用重启或设备唤醒，缺少可靠结束证据；请核对模拟运行。"
                // Keep last source sync time and sequence: local recovery is not a remote event.
                Self.notice(key: "recovery:\(state.runs[index].id)", taskID: state.runs[index].taskID, message: "\(Self.taskNumber(state.runs[index].taskID, state)): 执行同步未知，未自动重试。", isError: true, state: &state)
            }
            for index in state.pipelines.indices where [.running, .queued, .approval].contains(state.pipelines[index].state) {
                state.pipelines[index].state = .unknown
                state.pipelines[index].stage = "重启后等待核对，不重新提交"
                Self.notice(key: "pipeline-recovery:\(state.pipelines[index].id)", taskID: state.pipelines[index].taskID, pipelineRunID: state.pipelines[index].id, message: "模拟流水线等待核对，未重新触发。", isError: true, state: &state)
            }
        }
    }

    @discardableResult public func propose(taskID: UUID, title: String, reason: String, sourceRunID: UUID? = nil) throws -> Suggestion {
        let title = try Self.validTitle(title)
        return try database.transaction { state in
            _ = try Self.taskIndex(taskID, in: state)
            if let sourceRunID, !state.runs.contains(where: { $0.id == sourceRunID && $0.taskID == taskID }) { throw WorkbenchError.invalid("建议来源执行不属于此任务。") }
            let suggestion = Suggestion(taskID: taskID, sourceRunID: sourceRunID, title: title, reason: reason)
            state.suggestions.append(suggestion)
            return suggestion
        }
    }
    @discardableResult public func adopt(suggestionID: UUID) throws -> WorkTask {
        try database.transaction { state in
            guard let index = state.suggestions.firstIndex(where: { $0.id == suggestionID }) else { throw WorkbenchError.missing("建议不存在。") }
            if let id = state.suggestions[index].adoptedTaskID { return state.tasks[try Self.taskIndex(id, in: state)] }
            guard !state.suggestions[index].isIgnored else { throw WorkbenchError.conflict("此建议已忽略。") }
            let suggestion = state.suggestions[index]
            let task = try Self.newTask(title: suggestion.title, notes: "来源：\(Self.taskNumber(suggestion.taskID, state))\n\(suggestion.reason)", acceptance: "", state: &state)
            state.suggestions[index].adoptedTaskID = task.id
            return task
        }
    }
    public func ignore(suggestionID: UUID) throws {
        try database.transaction { state in
            guard let index = state.suggestions.firstIndex(where: { $0.id == suggestionID }) else { throw WorkbenchError.missing("建议不存在。") }
            guard state.suggestions[index].adoptedTaskID == nil else { throw WorkbenchError.conflict("已采纳的建议不能再忽略。") }
            state.suggestions[index].isIgnored = true
        }
    }

    public func prepareDeployment(branchID: UUID, environment: String, parameters: String, taskID: UUID?) throws -> DeploymentPlan {
        guard Self.nonProductionEnvironments.contains(environment) else { throw WorkbenchError.unauthorized("此环境按生产处理。当前仅开放 dev/test/daily/pre 的本地模拟，不提供真实或生产部署入口。") }
        return try database.transaction { state in
            let branch = try Self.branch(branchID, in: state)
            guard branch.availability == .available else { throw WorkbenchError.invalid("分支状态不可用，不能生成预览。") }
            let project = try Self.project(branch.projectID, in: state)
            if let taskID, !state.links.contains(where: { $0.taskID == taskID && $0.branchID == branchID }) { throw WorkbenchError.invalid("部署任务必须关联所选分支。") }
            let scope = DeploymentScope(projectID: project.id, projectName: project.name, branchID: branch.id, branchRef: branch.ref, environment: environment, sha: branch.sha, pipeline: "mock-build-and-release", resource: "本机模拟实例 / \(project.name)", action: "生成一个本地模拟流水线实例", impact: "仅更新本地数据库；不访问主机、不发布服务", parameters: parameters, taskID: taskID)
            for index in state.plans.indices where state.plans[index].scope.projectID == project.id && state.plans[index].pipelineRunID == nil {
                state.plans[index].invalidatedReason = "已生成新的部署范围，旧预览失效。"
            }
            let plan = DeploymentPlan(scope: scope, digest: try Self.digest(scope))
            state.plans.append(plan)
            return plan
        }
    }
    @discardableResult public func confirmDeployment(planID: UUID, expectedDigest: String) throws -> PipelineRun {
        try database.transaction { state in
            guard let index = state.plans.firstIndex(where: { $0.id == planID }) else { throw WorkbenchError.missing("预览不存在。") }
            let plan = state.plans[index]
            guard plan.digest == expectedDigest, try Self.digest(plan.scope) == expectedDigest else { throw WorkbenchError.conflict("确认与预览范围不匹配，请重新预览。") }
            // One-use confirmation returns the existing receipt even if the branch later advances.
            if let runID = plan.pipelineRunID, let run = state.pipelines.first(where: { $0.id == runID }) { return run }
            guard plan.invalidatedReason == nil else { throw WorkbenchError.conflict(plan.invalidatedReason!) }
            guard Self.nonProductionEnvironments.contains(plan.scope.environment) else { throw WorkbenchError.unauthorized("生产部署入口未开放。") }
            let branch = try Self.branch(plan.scope.branchID, in: state)
            guard branch.sha == plan.scope.sha, branch.availability == .available else { throw WorkbenchError.conflict("分支版本或可用状态已变化，原预览失效，请重新生成。") }
            let project = try Self.project(plan.scope.projectID, in: state)
            guard project.name == plan.scope.projectName, branch.ref == plan.scope.branchRef else { throw WorkbenchError.conflict("项目或分支范围已变化，请重新预览。") }
            if let taskID = plan.scope.taskID, !state.links.contains(where: { $0.taskID == taskID && $0.branchID == branch.id }) { throw WorkbenchError.conflict("关联关系已变化，请重新预览。") }
            guard Date().timeIntervalSince(plan.createdAt) < 900 else { throw WorkbenchError.conflict("预览已超过 15 分钟，请重新生成。") }
            let run = PipelineRun(projectID: project.id, branchID: branch.id, environment: plan.scope.environment, sha: plan.scope.sha, taskID: plan.scope.taskID, remoteID: "mock-\(UUID().uuidString.prefix(8).lowercased())", planID: plan.id)
            state.pipelines.append(run)
            state.plans[index].pipelineRunID = run.id
            return run
        }
    }
    public func advanceMockBranch(branchID: UUID) throws {
        try database.transaction { state in
            let index = try Self.branchIndex(branchID, in: state)
            state.branches[index].sha = Self.mockSHA()
            state.branches[index].confirmedAt = Date()
            for index in state.plans.indices where state.plans[index].scope.branchID == branchID && state.plans[index].pipelineRunID == nil {
                state.plans[index].invalidatedReason = "分支提交已推进，原预览失效，请重新生成。"
            }
        }
    }
    public func updateMockPipeline(runID: UUID, next: PipelineState) throws {
        try database.transaction { state in
            guard let index = state.pipelines.firstIndex(where: { $0.id == runID }) else { throw WorkbenchError.missing("流水线记录不存在。") }
            guard !state.pipelines[index].state.isTerminal else { return }
            state.pipelines[index].state = next
            state.pipelines[index].stage = next == .succeeded ? "模拟阶段完成，未证明真实服务健康" : next == .unknown ? "等待核对；禁止重复提交" : "模拟阶段 · \(next.label)"
            state.pipelines[index].updatedAt = Date()
            if next.isTerminal || next == .unknown || next == .approval {
                Self.notice(key: "pipeline:\(runID):\(next.rawValue)", taskID: state.pipelines[index].taskID, pipelineRunID: runID, message: "模拟流水线 \(state.pipelines[index].remoteID)：\(next.label)", isError: next != .succeeded && next != .cancelled, state: &state)
            }
        }
    }
    public func markNoticesRead() throws { try database.transaction { state in for index in state.notices.indices { state.notices[index].isRead = true } } }

    public static let nonProductionEnvironments = ["dev", "test", "daily", "pre"]
    private static func validTitle(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw WorkbenchError.invalid("标题不能为空。") }
        guard result.count <= 300 else { throw WorkbenchError.invalid("标题请控制在 300 字以内。") }
        return result
    }
    private static func newTask(title: String, notes: String, acceptance: String, state: inout WorkbenchSnapshot) throws -> WorkTask {
        guard state.nextNumber < Int.max else { throw WorkbenchError.invalid("任务编号已达上限。") }
        let task = WorkTask(number: state.nextNumber, title: try validTitle(title), notes: notes, acceptance: acceptance)
        state.nextNumber += 1
        state.tasks.append(task)
        return task
    }
    private static func taskIndex(_ id: UUID, in state: WorkbenchSnapshot) throws -> Int {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw WorkbenchError.missing("找不到任务。") }; return index
    }
    private static func branchIndex(_ id: UUID, in state: WorkbenchSnapshot) throws -> Int {
        guard let index = state.branches.firstIndex(where: { $0.id == id }) else { throw WorkbenchError.missing("找不到分支记录。") }; return index
    }
    private static func branch(_ id: UUID, in state: WorkbenchSnapshot) throws -> Branch { state.branches[try branchIndex(id, in: state)] }
    private static func project(_ id: UUID, in state: WorkbenchSnapshot) throws -> Project {
        guard let project = state.projects.first(where: { $0.id == id }) else { throw WorkbenchError.missing("找不到项目。") }; return project
    }
    private static func version(_ task: WorkTask, _ expected: Int) throws {
        guard task.version == expected else { throw WorkbenchError.conflict("任务已在其他操作中更新。已刷新，请核对后重试。") }
    }
    private static func taskNumber(_ id: UUID, _ state: WorkbenchSnapshot) -> String { state.tasks.first { $0.id == id }?.displayNumber ?? "任务" }
    private static func mockSHA() -> String { SHA256.hash(data: Data(UUID().uuidString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(40).description }
    private static func digest(_ scope: DeploymentScope) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
    }
    private static func notice(key: String, taskID: UUID?, pipelineRunID: UUID? = nil, message: String, isError: Bool, state: inout WorkbenchSnapshot) {
        guard !state.notices.contains(where: { $0.key == key }) else { return }
        state.notices.append(UpdateNotice(key: key, taskID: taskID, pipelineRunID: pipelineRunID, message: message, isError: isError))
    }
    private static func resolve(number: String, caller: CallerScope, state: WorkbenchSnapshot) throws -> ResolvedContext {
        guard number.range(of: "^T[#-]0*[1-9][0-9]*$", options: .regularExpression) != nil, let numeric = Int(number.dropFirst(2)), let task = state.tasks.first(where: { $0.number == numeric }) else { throw WorkbenchError.missing("请输入存在的完整任务号，例如 T-1；普通数字不作为任务号。") }
        let linkedIDs = Set(state.links.filter { $0.taskID == task.id }.map(\.branchID))
        let linked = state.branches.filter { linkedIDs.contains($0.id) }
        let chosen: Branch
        if let current = caller.currentProjectID {
            guard caller.authorizedProjectIDs.contains(current) else { throw WorkbenchError.unauthorized("当前项目未获调用者明确授权。") }
            let candidates = linked.filter { $0.projectID == current }
            guard !candidates.isEmpty else { throw WorkbenchError.conflict("当前项目不在此任务关联范围，请明确选择项目；不会跳到其他工作区。") }
            if candidates.count == 1 { chosen = candidates[0] }
            else {
                let defaults = Set(state.links.filter { $0.taskID == task.id && $0.isProjectDefault }.map(\.branchID))
                let matches = candidates.filter { defaults.contains($0.id) }
                guard matches.count == 1 else { throw WorkbenchError.conflict("此项目关联多个分支，请设置项目内默认分支或明确选择。") }
                chosen = matches[0]
            }
        } else {
            guard let defaultID = task.defaultBranchID, let candidate = linked.first(where: { $0.id == defaultID }) else { throw WorkbenchError.conflict("没有项目上下文或有效默认入口，请先明确选择。") }
            chosen = candidate
        }
        guard caller.authorizedProjectIDs.contains(chosen.projectID) else { throw WorkbenchError.unauthorized("目标项目超出调用者已授权范围；默认入口不授予代码访问权限。") }
        guard chosen.availability == .available else { throw WorkbenchError.invalid("目标分支当前不可用，需人工核对。") }
        let project = try project(chosen.projectID, in: state)
        let mismatch = caller.currentBranchRef.map { $0 != chosen.ref } ?? false
        return ResolvedContext(task: task, project: project, branch: chosen, description: "\(project.name) / \(chosen.ref) @ \(chosen.sha) · 仅模拟元数据，不授予目录访问权限\(mismatch ? " · 当前分支不符，不自动切换" : "")", branchMismatch: mismatch)
    }
}
