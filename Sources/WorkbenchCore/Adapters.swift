import Foundation

/// In-process contracts only. V1 exposes no network listener and installs no Codex configuration.
public struct AdapterCapabilities: Equatable, Sendable {
    public var name: String
    public var isSimulated: Bool
    public var reliableExistingSessionLifecycle: Bool
    public var canPinCommit: Bool
    public var canTriggerRealDeployment: Bool
}

public protocol TaskContextAdapter {
    var capabilities: AdapterCapabilities { get }
    func resolve(number: String) throws -> ResolvedContext
    func attach(number: String, sessionID: String) throws -> SessionAttachment
}

public protocol ExecutionEventAdapter {
    func start(sessionID: String) throws -> CodexRun
    func report(runID: UUID, state: RunState, sequence: Int, summary: String, eventID: String) throws
    func propose(runID: UUID, title: String, reason: String) throws -> Suggestion
}

/// This API deliberately has no method for modifying a task's manual completion state.
public final class MockCodexAdapter: TaskContextAdapter, ExecutionEventAdapter {
    private let service: WorkbenchService
    private let caller: CallerScope
    public let capabilities = AdapterCapabilities(name: "模拟 Codex", isSimulated: true, reliableExistingSessionLifecycle: false, canPinCommit: false, canTriggerRealDeployment: false)
    public init(service: WorkbenchService, caller: CallerScope) { self.service = service; self.caller = caller }
    public func resolve(number: String) throws -> ResolvedContext { try service.resolve(number: number, caller: caller) }
    public func attach(number: String, sessionID: String) throws -> SessionAttachment { try service.attach(number: number, sessionID: sessionID, caller: caller) }
    public func start(sessionID: String) throws -> CodexRun {
        let state = try service.snapshot()
        guard let attachment = state.attachments.first(where: { $0.sessionID == sessionID }) else { throw WorkbenchError.missing("请先按任务号关联模拟会话。") }
        guard let branchID = attachment.branchID else { throw WorkbenchError.invalid("模拟执行需要分支。") }
        try authorize(branchID: branchID, state: state)
        return try service.startMockRun(taskID: attachment.taskID, branchID: attachment.branchID, sessionID: sessionID)
    }
    public func report(runID: UUID, state: RunState, sequence: Int, summary: String, eventID: String) throws {
        _ = try authorizedRun(runID)
        try service.reportRun(runID: runID, state: state, sequence: sequence, summary: summary, eventID: eventID)
    }
    public func propose(runID: UUID, title: String, reason: String) throws -> Suggestion {
        let run = try authorizedRun(runID)
        return try service.propose(taskID: run.taskID, title: title, reason: reason, sourceRunID: run.id)
    }
    private func authorizedRun(_ id: UUID) throws -> CodexRun {
        let state = try service.snapshot()
        guard let run = state.runs.first(where: { $0.id == id }), let branchID = run.branchID else { throw WorkbenchError.unauthorized("此执行不在适配器已授权的项目范围。") }
        try authorize(branchID: branchID, state: state)
        return run
    }
    private func authorize(branchID: UUID, state: WorkbenchSnapshot) throws {
        guard let branch = state.branches.first(where: { $0.id == branchID }), caller.authorizedProjectIDs.contains(branch.projectID) else { throw WorkbenchError.unauthorized("适配器调用超出已授权项目范围。") }
    }
}

public protocol PipelineAdapter {
    var capabilities: AdapterCapabilities { get }
    func listRuns(projectID: UUID, environment: String) throws -> [PipelineRun]
    func prepare(branchID: UUID, environment: String, parameters: String, taskID: UUID?) throws -> DeploymentPlan
    func confirm(planID: UUID, expectedDigest: String) throws -> PipelineRun
}

public final class MockPipelineAdapter: PipelineAdapter {
    private let service: WorkbenchService
    public let capabilities = AdapterCapabilities(name: "模拟云效", isSimulated: true, reliableExistingSessionLifecycle: false, canPinCommit: true, canTriggerRealDeployment: false)
    public init(service: WorkbenchService) { self.service = service }
    public func listRuns(projectID: UUID, environment: String) throws -> [PipelineRun] {
        try service.snapshot().pipelines.filter { $0.projectID == projectID && $0.environment == environment }
    }
    public func prepare(branchID: UUID, environment: String, parameters: String, taskID: UUID?) throws -> DeploymentPlan {
        try service.prepareDeployment(branchID: branchID, environment: environment, parameters: parameters, taskID: taskID)
    }
    public func confirm(planID: UUID, expectedDigest: String) throws -> PipelineRun {
        try service.confirmDeployment(planID: planID, expectedDigest: expectedDigest)
    }
}
