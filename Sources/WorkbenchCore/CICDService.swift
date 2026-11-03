import Foundation

extension WorkbenchService {
    public func cicdState() throws -> CICDState { try snapshot().cicd ?? CICDState() }
    public func saveFlowConnection(_ connection: YunxiaoConnection) throws {
        _ = try connection.validatedOrigin()
        try database.transaction { snapshot in
            var state = snapshot.cicd ?? CICDState()
            // Identity is immutable after credentials are installed; use a new ID on every reconnect.
            if let old = state.connections.first(where: { $0.id == connection.id }), old != connection { throw WorkbenchError.conflict("连接身份不能原位变更，请重新连接以隔离缓存。") }
            if !state.connections.contains(where: { $0.id == connection.id }) { state.connections.append(connection); state.accounts.append(FlowAccountCache(connectionID: connection.id, resourceScope: connection.resourceScope)) }
            state.selectedConnectionID = connection.id; snapshot.cicd = state
        }
    }
    public func selectFlowConnection(_ id: UUID) throws {
        try database.transaction { snapshot in
            guard var state = snapshot.cicd, state.connections.contains(where: { $0.id == id }) else { throw WorkbenchError.missing("连接不存在。") }
            state.selectedConnectionID = id; snapshot.cicd = state
        }
    }
    public func disconnectFlowConnection(_ id: UUID) throws {
        try database.transaction { snapshot in
            guard var state = snapshot.cicd else { return }
            state.connections.removeAll { $0.id == id }
            if state.selectedConnectionID == id { state.selectedConnectionID = state.connections.first?.id }
            // Keep the isolated account history for audit; never merge it into another identity.
            snapshot.cicd = state
        }
    }
    func mutateFlowAccount<T>(_ id: UUID, _ body: (inout FlowAccountCache) throws -> T) throws -> T {
        try database.transaction { snapshot in
            guard var state = snapshot.cicd, state.connections.contains(where: { $0.id == id }), let index = state.accounts.firstIndex(where: { $0.connectionID == id }) else { throw WorkbenchError.missing("云效连接已改变，请重新选择。") }
            let result = try body(&state.accounts[index]); snapshot.cicd = state; return result
        }
    }
    public func setFlowFavorite(connectionID: UUID, pipelineID: String, favorite: Bool) throws {
        try mutateFlowAccount(connectionID) { cache in
            if favorite { cache.favorites.insert(pipelineID) } else { cache.favorites.remove(pipelineID) }
        }
    }
    public func cacheFlowCatalog(connectionID: UUID, definitions: [PipelineDefinition]) throws {
        try mutateFlowAccount(connectionID) { cache in
            let ids = Set(definitions.map(\.id))
            var merged = definitions.map { value -> PipelineDefinition in
                if var old = cache.definitions.first(where: { $0.id == value.id }) { old.name = value.name; old.available = true; return old }
                return value
            }
            for var old in cache.definitions where !ids.contains(old.id) { old.available = false; merged.append(old) }
            cache.definitions = merged; cache.syncedAt = Date()
        }
    }
    public func cacheFlowDefinition(connectionID: UUID, definition: PipelineDefinition) throws {
        try mutateFlowAccount(connectionID) { cache in
            if let i = cache.definitions.firstIndex(where: { $0.id == definition.id }) { cache.definitions[i] = definition }
            else { cache.definitions.append(definition) }
        }
    }
    public func saveFlowBinding(connectionID: UUID, binding: PipelineBinding) throws {
        let projects = Set(try snapshot().projects.map(\.id))
        guard binding.sourceProjects.values.flatMap({ $0 }).allSatisfy(projects.contains),
              binding.variables.allSatisfy({ $0.kind != .secret || $0.defaultValue.isEmpty }) else { throw WorkbenchError.invalid("关联项目不可用，或私密变量含明文默认值。") }
        try mutateFlowAccount(connectionID) { cache in
            guard let definition = cache.definitions.first(where: { $0.id == binding.pipelineID }), definition.detailLoaded, definition.revision == binding.definitionRevision else { throw WorkbenchError.conflict("请加载最新定义后再保存关联。") }
            cache.bindings[binding.pipelineID] = binding
        }
    }
    public func cacheFlowRuns(connectionID: UUID, pipelineID: String, runs: [FlowRemoteRun]) throws {
        try mutateFlowAccount(connectionID) { $0.runs[pipelineID] = runs }
    }
    public func reconcileFlowAttempt(connectionID: UUID, previewID: UUID, verifiedRun: FlowRemoteRun, humanConfirmed: Bool) throws {
        guard humanConfirmed else { throw WorkbenchError.invalid("需要人工确认此实例唯一对应本次提交。") }
        try database.transaction { snapshot in
            guard var state = snapshot.cicd, let connection = state.connections.first(where: { $0.id == connectionID }),
                  let owner = state.accounts.firstIndex(where: { $0.attempts.contains(where: { $0.id == previewID }) }),
                  state.accounts[owner].resourceScope == connection.resourceScope,
                  let index = state.accounts[owner].attempts.firstIndex(where: { $0.id == previewID }),
                  state.accounts[owner].attempts[index].state != .accepted,
                  state.accounts[owner].attempts[index].preview.pipelineID == verifiedRun.pipelineID else { throw WorkbenchError.invalid("实例不属于本次组织/流水线或记录已经核对。") }
            state.accounts[owner].attempts[index].state = .accepted
            state.accounts[owner].attempts[index].remoteID = verifiedRun.id
            snapshot.cicd = state
        }
    }
    func beginFlowAttempt(_ preview: FlowRunPreview) throws {
        try database.transaction { snapshot in
            guard var state = snapshot.cicd, let connection = state.connections.first(where: { $0.id == preview.connectionID }),
                  let index = state.accounts.firstIndex(where: { $0.connectionID == preview.connectionID }) else { throw WorkbenchError.missing("连接已改变。") }
            guard !state.accounts.contains(where: { account in
                account.resourceScope == connection.resourceScope && account.attempts.contains(where: { $0.id == preview.id || ($0.preview.pipelineID == preview.pipelineID && $0.state != .accepted) })
            }) else { throw WorkbenchError.conflict("此组织的流水线已有结果未知的提交；切换账号或重新授权也不能重复提交。") }
            state.accounts[index].attempts.append(FlowRunAttempt(preview: preview, state: .submitting))
            snapshot.cicd = state
        }
    }
    func finishFlowAttempt(connectionID: UUID, previewID: UUID, remoteID: String?) throws {
        try mutateFlowAccount(connectionID) { cache in
            guard let i = cache.attempts.firstIndex(where: { $0.id == previewID }) else { throw WorkbenchError.missing("本地提交回执缺失，请在云效核对。") }
            cache.attempts[i].state = remoteID == nil ? .unknown : .accepted
            cache.attempts[i].remoteID = remoteID
        }
    }
}

public enum FlowRunValidation {
    public static func params(definition: PipelineDefinition, binding: PipelineBinding, draft: FlowRunDraft, snapshot: WorkbenchSnapshot) throws -> (Data, Data, [FlowTarget], [String]) {
        guard definition.available, definition.detailLoaded, definition.blockers.isEmpty else { throw WorkbenchError.invalid(definition.blockers.joined(separator: "\n").isEmpty ? "流水线不可用或尚未加载详情。" : definition.blockers.joined(separator: "\n")) }
        guard binding.reviewed, !binding.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              binding.definitionRevision == definition.revision else { throw WorkbenchError.conflict("参数和目标范围尚未核对，或流水线定义已变化。请重新配置关联。") }
        guard Set(definition.sources.map(\.id)).count == definition.sources.count,
              Set(definition.sources.map(\.repo)).count == definition.sources.count,
              Set(binding.sourceProjects.keys).isSubset(of: Set(definition.sources.map(\.id))) else { throw WorkbenchError.invalid("代码源重复或关联中含失效源，请重新核对。") }
        let projectIDs = Set(binding.sourceProjects.values.flatMap { $0 })
        guard projectIDs.isSubset(of: Set(snapshot.projects.map(\.id))), definition.sources.allSatisfy({ !(binding.sourceProjects[$0.id] ?? []).isEmpty }) else { throw WorkbenchError.invalid("请确认每个代码源对应的本地项目。") }
        if let taskID = draft.taskID { guard snapshot.tasks.contains(where: { $0.id == taskID }) else { throw WorkbenchError.missing("关联任务已被删除。") } }
        let targets: [FlowTarget]
        switch binding.mode {
        case .fixed: targets = binding.targets
        case .runtime:
            guard !binding.environmentKey.isEmpty, let selected = binding.targets.first(where: { $0.id == draft.targetID }), !selected.value.isEmpty else { throw WorkbenchError.invalid("请选择环境，并补充真实运行变量键和值。") }
            targets = binding.targets.filter { $0.value == selected.value }
        case .ci:
            guard binding.targets.isEmpty, binding.environmentKey.isEmpty else { throw WorkbenchError.invalid("纯 CI 配置不能隐藏部署目标或环境变量。") }
            targets = []
        }
        guard binding.mode == .ci || (!targets.isEmpty && targets.allSatisfy(\.complete)) else { throw WorkbenchError.invalid("环境、主机/资源、动作、影响面及证据必须完整。未知范围不能执行。") }
        // The public API does not prove immutable commit/artifact pinning. No production capability is advertised.
        guard !definition.productionHint, !targets.contains(where: \.isProduction) else { throw WorkbenchError.unauthorized("生产提交暂不可用：当前接口未验证不可变版本锁定能力。请在云效核对并执行，不能沿用此预览授权。") }
        var branches: [String: String] = [:], tags: [String: String] = [:]
        guard Set(draft.codes.keys).isSubset(of: Set(definition.sources.map(\.id))) else { throw WorkbenchError.invalid("代码源已变化，请重新填写。") }
        for source in definition.sources {
            guard let choice = draft.codes[source.id], !choice.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchError.invalid("代码源 \(source.id) 缺少分支或 Tag。") }
            if choice.isTag { tags[source.repo] = choice.value } else { branches[source.repo] = choice.value }
        }
        guard Set(branches.keys).isDisjoint(with: tags.keys) else { throw WorkbenchError.invalid("同一仓库不能同时选择分支和 Tag。") }
        let variableKeys = binding.variables.map(\.key)
        guard variableKeys.allSatisfy({ !$0.isEmpty }), Set(variableKeys).count == variableKeys.count,
              Set(draft.variables.keys).isSubset(of: Set(variableKeys)), !variableKeys.contains(binding.environmentKey) else { throw WorkbenchError.invalid("变量键缺失、重复或与环境变量冲突。") }
        var envs: [String: String] = [:], safeEnvs: [String: String] = [:]
        for variable in binding.variables {
            let override = draft.variables[variable.key]
            if !variable.editable && override != nil { throw WorkbenchError.invalid("变量 \(variable.key) 不允许覆盖。") }
            let effective = override ?? variable.defaultValue
            guard !variable.required || !effective.isEmpty else { throw WorkbenchError.invalid("请填写必填变量 \(variable.key)。") }
            if variable.kind == .enumeration && !effective.isEmpty && !variable.options.contains(effective) { throw WorkbenchError.invalid("变量 \(variable.key) 必须选择有效枚举值。") }
            if let override { envs[variable.key] = override; safeEnvs[variable.key] = "已设置（\(variable.kind == .secret ? "私密" : "不保存值")）" }
        }
        if binding.mode != .ci && !binding.environmentKey.isEmpty {
            let values = Set(targets.map(\.value))
            guard values.count == 1, let value = values.first, !value.isEmpty else { throw WorkbenchError.invalid("同次运行的环境变量值不一致。") }
            envs[binding.environmentKey] = value; safeEnvs[binding.environmentKey] = value
        }
        if binding.mode == .fixed && binding.targets.count != targets.count { throw WorkbenchError.invalid("固定流水线必须展示全部目标。") }
        var params: [String: Any] = ["envs": envs, "runningBranchs": branches, "runningTags": tags, "comment": draft.comment]
        // Receipts redact all user variable/artifact values and comments; secrets never enter the database.
        var redacted: [String: Any] = ["envs": safeEnvs, "runningBranchs": branches, "runningTags": tags, "comment": draft.comment.isEmpty ? "" : "已填写（不保存）"]
        guard Set(draft.artifacts.keys).isSubset(of: Set(binding.artifacts.map(\.id))) else { throw WorkbenchError.invalid("制品定义已变化。") }
        for kind in FlowArtifactKind.allCases {
            let definitions = binding.artifacts.filter { $0.kind == kind }
            guard Set(definitions.map(\.key)).count == definitions.count else { throw WorkbenchError.invalid("制品源键重复。") }
            var values: [String: String] = [:], safe: [String: String] = [:]
            for artifact in definitions {
                guard !artifact.key.isEmpty, let value = draft.artifacts[artifact.id], !value.isEmpty else { throw WorkbenchError.invalid("请填写制品 \(artifact.label) 的版本。") }
                values[artifact.key] = value; safe[artifact.key] = "已指定版本（不保存）"
            }
            if !values.isEmpty { params[kind.rawValue] = values; redacted[kind.rawValue] = safe }
        }
        return (try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys, .prettyPrinted]), targets, snapshot.projects.filter { projectIDs.contains($0.id) }.map(\.name))
    }
}

/// Owns ephemeral drafts. A restarted process cannot resurrect or replay a confirmation.
public actor FlowRunCoordinator {
    private let service: WorkbenchService
    private var pending: [UUID: (FlowRunPreview, FlowRunDraft)] = [:]
    public init(service: WorkbenchService) { self.service = service }
    public func prepare(api: YunxiaoAPI, pipelineID: String, draft: FlowRunDraft) async throws -> FlowRunPreview {
        guard !api.connection.readOnly else { throw WorkbenchError.unauthorized("此连接开启了本地只读模式。请新建允许运行的连接。") }
        let definition = try await api.getPipeline(pipelineID)
        try Task.checkCancellation()
        try service.cacheFlowDefinition(connectionID: api.connection.id, definition: definition)
        let snapshot = try service.snapshot()
        guard !(snapshot.cicd?.accounts.filter({ $0.resourceScope == api.connection.resourceScope }).flatMap({ $0.attempts }).contains(where: { $0.preview.pipelineID == pipelineID && $0.state != .accepted }) ?? false) else { throw WorkbenchError.conflict("此流水线有提交结果未知的记录，请先人工核对并关联已有实例，不能重复提交。") }
        guard let binding = snapshot.cicd?.accounts.first(where: { $0.connectionID == api.connection.id })?.bindings[pipelineID] else { throw WorkbenchError.invalid("请先配置项目、参数与环境关联。") }
        let (_, safe, targets, projects) = try FlowRunValidation.params(definition: definition, binding: binding, draft: draft, snapshot: snapshot)
        let preview = FlowRunPreview(connectionID: api.connection.id, pipelineID: pipelineID, pipelineName: definition.name, revision: definition.revision, bindingDigest: try FlowIdentity.digest(binding), targets: targets, projects: projects, redactedParameters: String(decoding: safe, as: UTF8.self), taskID: draft.taskID)
        pending = pending.filter { $0.value.0.connectionID != api.connection.id || $0.value.0.pipelineID != pipelineID }
        pending[preview.id] = (preview, draft)
        return preview
    }
    public func invalidate() { pending.removeAll() }
    public func submit(api: YunxiaoAPI, previewID: UUID, draft: FlowRunDraft, acknowledged: Bool) async throws -> String {
        guard acknowledged, let (preview, savedDraft) = pending.removeValue(forKey: previewID), preview.connectionID == api.connection.id, savedDraft == draft, Date() < preview.expiresAt, !api.connection.readOnly else { throw WorkbenchError.conflict("确认不存在、已失效或参数已变更，请重新生成范围预览。") }
        let fresh = try await api.getPipeline(preview.pipelineID)
        try Task.checkCancellation()
        try service.cacheFlowDefinition(connectionID: api.connection.id, definition: fresh)
        let snapshot = try service.snapshot()
        guard snapshot.cicd?.connections.contains(api.connection) == true,
              fresh.revision == preview.revision,
              let binding = snapshot.cicd?.accounts.first(where: { $0.connectionID == api.connection.id })?.bindings[preview.pipelineID],
              try FlowIdentity.digest(binding) == preview.bindingDigest else { throw WorkbenchError.conflict("定义、连接或关联已变化，原确认已失效。") }
        let (params, _, _, _) = try FlowRunValidation.params(definition: fresh, binding: binding, draft: draft, snapshot: snapshot)
        try service.beginFlowAttempt(preview)
        do {
            let id = try await api.submit(preview.pipelineID, params: params)
            try service.finishFlowAttempt(connectionID: api.connection.id, previewID: preview.id, remoteID: id)
            return id
        } catch {
            try? service.finishFlowAttempt(connectionID: api.connection.id, previewID: preview.id, remoteID: nil)
            throw WorkbenchError.conflict("提交结果未知，禁止自动重试。请在云效核对流水线 \(preview.pipelineID)；未按备注或时间推定归属。")
        }
    }
}
