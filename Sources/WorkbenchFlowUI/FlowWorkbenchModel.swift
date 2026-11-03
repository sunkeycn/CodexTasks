import AppKit
import AuthenticationServices
import SwiftUI
import WorkbenchCore

@MainActor final class FlowWorkbenchModel: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    let service: WorkbenchService
    let coordinator: FlowRunCoordinator
    @Published var state = CICDState()
    @Published var busy = false
    @Published var message: String?
    @Published var selectedID: String?
    @Published var readScopeAuthorized = false
    @Published var preview: FlowRunPreview?
    @Published var log = ""
    @Published var runSyncErrors: [String: String] = [:]
    private var operation: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var authSession: ASWebAuthenticationSession?
    private var generation = UUID()
    private var sessionSecrets = Set<String>()
    private let transport = FlowURLTransport()
    init(service: WorkbenchService) {
        self.service = service; coordinator = FlowRunCoordinator(service: service)
        super.init(); reload()
    }
    var connection: YunxiaoConnection? { state.connections.first { $0.id == state.selectedConnectionID } }
    var cache: FlowAccountCache? { state.accounts.first { $0.connectionID == state.selectedConnectionID } }
    var visibleAttempts: [FlowRunAttempt] {
        guard let connection else { return [] }
        return state.accounts.filter { $0.connectionID == connection.id || $0.resourceScope == connection.resourceScope }.flatMap { account in
            account.attempts.filter { account.connectionID == connection.id || $0.state != .accepted }
        }
    }
    var definition: PipelineDefinition? { cache?.definitions.first { $0.id == selectedID } }
    var binding: PipelineBinding? { selectedID.flatMap { cache?.bindings[$0] } }
    var localSnapshot: WorkbenchSnapshot { (try? service.snapshot()) ?? WorkbenchSnapshot() }
    func reload() { do { state = try service.cicdState() } catch { message = error.localizedDescription } }
    func local(_ body: () throws -> Void) { do { try body(); reload(); message = nil } catch { message = error.localizedDescription } }
    func chooseConnection(_ id: UUID) {
        stop(); sessionSecrets.removeAll(); readScopeAuthorized = false; selectedID = nil; preview = nil; log = ""; runSyncErrors = [:]
        local { try service.selectFlowConnection(id) }
    }
    func stop() { generation = UUID(); operation?.cancel(); operation = nil; polling?.cancel(); polling = nil; authSession?.cancel(); authSession = nil; busy = false; Task { await coordinator.invalidate() } }
    func disconnect() {
        guard let id = connection?.id else { return }; stop(); sessionSecrets.removeAll()
        local { try FlowCredentialStore.delete(connectionID: id); try service.disconnectFlowConnection(id) }
        readScopeAuthorized = false; selectedID = nil; preview = nil
    }
    private func perform(_ body: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = nil; let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.operation = nil; self.reload() } }
            do { try await body() }
            catch is CancellationError { }
            catch { if self.generation == token { self.message = error.localizedDescription } }
        }
    }
    private func api(_ connection: YunxiaoConnection) async throws -> YunxiaoAPI {
        guard readScopeAuthorized, self.connection?.id == connection.id else { throw WorkbenchError.unauthorized("请先确认读取范围：此组织目录和所选流水线/实例可能包含生产资源。") }
        let data = try FlowCredentialStore.read(connectionID: connection.id)
        let token: String
        if connection.auth == .pat {
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw WorkbenchError.unauthorized("PAT 不可用，请重新连接。") }; token = value
        } else {
            var tokens = try JSONDecoder().decode(FlowOAuthTokens.self, from: data)
            if tokens.expiresAt <= Date().addingTimeInterval(60) {
                guard let refresh = tokens.refreshToken else { throw WorkbenchError.unauthorized("授权已过期，请重新连接。") }
                do {
                    tokens = try await FlowOAuth.tokens(endpoint: tokens.tokenEndpoint, clientID: tokens.clientID, refreshToken: refresh, transport: transport)
                    try Task.checkCancellation()
                    guard self.connection?.id == connection.id else { throw CancellationError() }
                    try FlowCredentialStore.save(JSONEncoder().encode(tokens), connectionID: connection.id)
                } catch { throw WorkbenchError.unauthorized("OAuth 刷新失败，请重新授权。未自动重试运行请求。") }
            }
            token = tokens.accessToken
        }
        return YunxiaoAPI(connection: connection, token: token, transport: transport)
    }
    func connect(_ connection: YunxiaoConnection, pat: String) {
        guard !busy else { return }
        polling?.cancel(); preview = nil; sessionSecrets.removeAll(); runSyncErrors = [:]
        Task { await coordinator.invalidate() }
        perform { [self] in
            _ = try connection.validatedOrigin()
            if connection.auth == .pat {
                guard !pat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !pat.contains("\n"), !pat.contains("\r") else { throw WorkbenchError.invalid("请输入有效 PAT。") }
                // A test reads the complete directory; it never probes permissions by triggering a run.
                let api = YunxiaoAPI(connection: connection, token: pat, transport: transport)
                let definitions = try await api.listPipelines(); try Task.checkCancellation()
                try FlowCredentialStore.save(Data(pat.utf8), connectionID: connection.id)
                do { try service.saveFlowConnection(connection); try service.cacheFlowCatalog(connectionID: connection.id, definitions: definitions) }
                catch { try? FlowCredentialStore.delete(connectionID: connection.id); throw error }
                selectedID = nil; readScopeAuthorized = true; message = "已验证目录读取；运行权限未通过执行 Flow 测试。"
            } else {
                let metadata = try await FlowOAuth.discover(connection: connection, transport: transport)
                let clientID = try await FlowOAuth.register(metadata: metadata, transport: transport)
                let verifier = try FlowOAuth.randomString(), state = try FlowOAuth.randomString()
                let url = try FlowOAuth.authorizationURL(metadata: metadata, clientID: clientID, verifier: verifier, state: state)
                let callback = try await authenticate(url)
                let code = try FlowOAuth.code(callback: callback, state: state)
                let tokens = try await FlowOAuth.tokens(endpoint: metadata.token_endpoint, clientID: clientID, code: code, verifier: verifier, transport: transport)
                let api = YunxiaoAPI(connection: connection, token: tokens.accessToken, transport: transport)
                let definitions = try await api.listPipelines(); try Task.checkCancellation()
                try FlowCredentialStore.save(JSONEncoder().encode(tokens), connectionID: connection.id)
                do { try service.saveFlowConnection(connection); try service.cacheFlowCatalog(connectionID: connection.id, definitions: definitions) }
                catch { try? FlowCredentialStore.delete(connectionID: connection.id); throw error }
                selectedID = nil; readScopeAuthorized = true; message = "浏览器授权和目录读取成功。仅保留本机凭据，不承诺远端撤销。"
            }
        }
    }
    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "codextasks") { [weak self] url, _ in
                Task { @MainActor in
                    self?.authSession = nil
                    if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: WorkbenchError.unauthorized("浏览器授权取消或失败。")) }
                }
            }
            session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = true
            authSession = session
            if !session.start() { authSession = nil; continuation.resume(throwing: WorkbenchError.unauthorized("无法启动浏览器授权。")) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    func refreshCatalog() {
        guard let c = connection else { return }
        perform { [self] in
            let api = try await api(c); let definitions = try await api.listPipelines(); try Task.checkCancellation()
            try service.cacheFlowCatalog(connectionID: c.id, definitions: definitions)
        }
    }
    func favorite(_ definition: PipelineDefinition) {
        guard let c = connection else { return }
        local { try service.setFlowFavorite(connectionID: c.id, pipelineID: definition.id, favorite: !(cache?.favorites.contains(definition.id) ?? false)) }
    }
    func select(_ id: String) {
        guard !busy else { return }; polling?.cancel(); selectedID = id; preview = nil; log = ""
        if readScopeAuthorized { loadDetail() }
    }
    func loadDetail() {
        guard let c = connection, let id = selectedID else { return }
        perform { [self] in
            let api = try await api(c); let definition = try await api.getPipeline(id); try Task.checkCancellation()
            try service.cacheFlowDefinition(connectionID: c.id, definition: definition)
        }
    }
    func saveBinding(_ binding: PipelineBinding) {
        guard let c = connection else { return }; preview = nil
        local { try service.saveFlowBinding(connectionID: c.id, binding: binding) }
        Task { await coordinator.invalidate() }
    }
    func loadRuns() {
        guard let c = connection, let id = selectedID else { return }
        perform { [self] in
            let api = try await api(c)
            var runs = try await api.listRuns(id).sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
            // ListPipelineRuns does not promise a status field. Fetch the newest instance separately.
            if let first = runs.first { runs[0] = try await api.getRun(id, runID: first.id) }
            try Task.checkCancellation(); try service.cacheFlowRuns(connectionID: c.id, pipelineID: id, runs: runs)
            runSyncErrors[id] = nil; reload(); watch(connection: c, pipelineID: id)
        }
    }
    func loadRun(_ run: FlowRemoteRun) {
        guard let c = connection else { return }
        perform { [self] in
            let api = try await api(c); let fresh = try await api.getRun(run.pipelineID, runID: run.id); try Task.checkCancellation()
            var runs = cache?.runs[run.pipelineID] ?? []
            if let i = runs.firstIndex(where: { $0.id == fresh.id }) { runs[i] = fresh } else { runs.insert(fresh, at: 0) }
            try service.cacheFlowRuns(connectionID: c.id, pipelineID: run.pipelineID, runs: runs)
            reload(); watch(connection: c, pipelineID: run.pipelineID)
        }
    }
    private func watch(connection: YunxiaoConnection, pipelineID: String) {
        polling?.cancel(); let token = generation
        polling = Task { [weak self] in
            var delay: UInt64 = 8
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                guard let self, self.generation == token, self.connection?.id == connection.id, self.selectedID == pipelineID, self.readScopeAuthorized else { return }
                if self.busy { continue }
                let active = (self.cache?.runs[pipelineID] ?? []).filter(\.active)
                guard !active.isEmpty else { return }
                do {
                    let api = try await self.api(connection); var runs = self.cache?.runs[pipelineID] ?? []
                    for run in active {
                        let fresh = try await api.getRun(pipelineID, runID: run.id); try Task.checkCancellation()
                        if let i = runs.firstIndex(where: { $0.id == run.id }) { runs[i] = fresh }
                    }
                    guard self.generation == token else { return }
                    try self.service.cacheFlowRuns(connectionID: connection.id, pipelineID: pipelineID, runs: runs)
                    self.runSyncErrors[pipelineID] = nil; self.reload(); delay = 8
                } catch is CancellationError { return }
                catch {
                    self.runSyncErrors[pipelineID] = "运行同步失败；保留云端最后已知状态。"
                    if let error = error as? WorkbenchError {
                        switch error { case .unauthorized, .missing: return; default: break }
                    }
                    delay = min(60, delay * 2)
                }
            }
        }
    }
    func reconcile(_ attempt: FlowRunAttempt, runID: String, humanConfirmed: Bool) {
        guard let c = connection else { return }
        perform { [self] in
            guard humanConfirmed else { throw WorkbenchError.invalid("请先人工核对实例唯一归属。") }
            let api = try await api(c)
            let verified = try await api.getRun(attempt.preview.pipelineID, runID: runID)
            try Task.checkCancellation()
            try service.reconcileFlowAttempt(connectionID: c.id, previewID: attempt.id, verifiedRun: verified, humanConfirmed: humanConfirmed)
            message = "已按人工确认关联实例，不会重新执行 Flow。"
        }
    }
    func getLog(run: FlowRemoteRun, jobID: String) {
        guard let c = connection else { return }
        perform { [self] in
            let api = try await api(c); let text = try await api.getLog(run.pipelineID, runID: run.id, jobID: jobID); try Task.checkCancellation()
            log = sessionSecrets.sorted { $0.count > $1.count }.reduce(text) { value, secret in value.replacingOccurrences(of: secret, with: "••••") }
        }
    }
    func prepare(_ draft: FlowRunDraft) {
        guard let c = connection, let id = selectedID else { return }
        preview = nil
        for variable in binding?.variables ?? [] where variable.kind == .secret {
            if let value = draft.variables[variable.key], !value.isEmpty { sessionSecrets.insert(value) }
        }
        perform { [self] in
            let api = try await api(c)
            let next = try await coordinator.prepare(api: api, pipelineID: id, draft: draft)
            try Task.checkCancellation()
            guard connection?.id == c.id, selectedID == id else { throw CancellationError() }
            preview = next
        }
    }
    func submit(_ draft: FlowRunDraft, acknowledged: Bool) {
        guard let c = connection, let preview else { return }
        self.preview = nil
        perform { [self] in
            let api = try await api(c)
            let id = try await coordinator.submit(api: api, previewID: preview.id, draft: draft, acknowledged: acknowledged)
            try Task.checkCancellation()
            guard connection?.id == c.id else { throw CancellationError() }
            message = "已提交实例 \(id)，请在运行记录中核对实际状态与版本。"
        }
    }
}
