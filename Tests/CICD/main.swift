import Foundation
import CryptoKit
import CSQLite
import WorkbenchCore

struct CheckFailure: Error, CustomStringConvertible { var description: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String = "断言失败") throws { if try !value() { throw CheckFailure(description: message) } }
func rejects(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw CheckFailure(description: "应拒绝操作") }
func rejectsAsync(_ body: () async throws -> Void) async throws { do { try await body() } catch { return }; throw CheckFailure(description: "应拒绝异步操作") }
actor MockFlowTransport: FlowHTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> FlowHTTPResponse
    private let handler: Handler
    private(set) var requests: [URLRequest] = []
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> FlowHTTPResponse { requests.append(request); return try handler(request, requests.count) }
    var postCount: Int { requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/runs") == true }.count }
}
func response(_ object: Any, headers: [String: String] = [:], status: Int = 200) throws -> FlowHTTPResponse {
    FlowHTTPResponse(status: status, headers: headers, data: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]))
}
struct Fixture {
    var directory: URL
    var service: WorkbenchService
    var connection: YunxiaoConnection
    var project: Project
    var task: WorkTask
    var definition: PipelineDefinition
    var binding: PipelineBinding
    var draft: FlowRunDraft
    static let raw: [String: Any] = ["name": "构建测试", "updateTime": 10, "pipelineConfig": ["flow": "schema: tb\npipeline: []", "settings": "{}", "sources": [["sign": "source1", "type": "Codeup", "data": ["repo": "https://example.com/Team/Repo.git", "branch": "main"]]]]]
    static func create() async throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cicd-acceptance-\(UUID())")
        let service = try WorkbenchService(databaseURL: dir.appendingPathComponent("state.sqlite"))
        var connection = YunxiaoConnection(); connection.organization = "org"; connection.account = "fixture"; connection.readOnly = false
        try service.saveFlowConnection(connection)
        let project = try service.createProject(name: "项目", repository: "git@example.com:Team/Repo.git")
        let task = try service.createTask(title: "不自动完成")
        let mock = MockFlowTransport { _,_ in try response(Fixture.raw) }
        let definition = try await YunxiaoAPI(connection: connection, token: "fixture", transport: mock).getPipeline("123")
        try service.cacheFlowDefinition(connectionID: connection.id, definition: definition)
        var binding = PipelineBinding(pipelineID: definition.id); binding.definitionRevision = definition.revision; binding.sourceProjects = ["source1": [project.id]]
        binding.environmentKey = "DEPLOY_ENV"; binding.evidence = "fixture 已核对"; binding.reviewed = true
        var target = FlowTarget(); target.environment = "test"; target.value = "test-value"; target.resources = "test-app"; target.action = "构建并部署测试服务"; target.impact = "测试服务滚动更新"; target.evidence = "测试清单"
        binding.targets = [target]
        var secret = FlowVariable(); secret.key = "SECRET"; secret.kind = .secret
        var text = FlowVariable(); text.key = "TEXT"; text.defaultValue = "remote-default"
        var pick = FlowVariable(); pick.key = "PICK"; pick.kind = .enumeration; pick.options = ["one", "two"]; pick.defaultValue = "one"
        binding.variables = [secret, text, pick]
        try service.saveFlowBinding(connectionID: connection.id, binding: binding)
        var draft = FlowRunDraft(); draft.codes["source1"] = FlowCodeChoice(value: "feature/test"); draft.targetID = target.id; draft.taskID = task.id
        return Fixture(directory: dir, service: service, connection: connection, project: project, task: task, definition: definition, binding: binding, draft: draft)
    }
    func api(_ transport: MockFlowTransport) -> YunxiaoAPI { YunxiaoAPI(connection: connection, token: "fixture-access-token", transport: transport) }
    func validated(_ draft: FlowRunDraft? = nil, binding: PipelineBinding? = nil, definition: PipelineDefinition? = nil) throws -> (Data, Data, [FlowTarget], [String]) { try FlowRunValidation.params(definition: definition ?? self.definition, binding: binding ?? self.binding, draft: draft ?? self.draft, snapshot: service.snapshot()) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@main struct CICDAcceptance {
    static func main() async {
        var results: [[String: Any]] = []
        func run(_ name: String, _ body: () async throws -> Void) async {
            do { try await body(); results.append(["name": name, "passed": true]); print("PASS \(name)") }
            catch { results.append(["name": name, "passed": false, "error": String(describing: error)]); print("FAIL \(name): \(error)") }
        }
        await run("完整分页超过30条与同名不同ID") {
            var c = YunxiaoConnection(); c.organization = "org"; c.account = "fixture"
            let transport = MockFlowTransport { r,_ in
                let page = Int(URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
                try check(r.value(forHTTPHeaderField: "x-yunxiao-token") == "pat-fixture")
                let start = (page - 1) * 30, end = min(page * 30, 65)
                return try response((start..<end).map { ["pipelineId": $0, "pipelineName": "同名"] as [String: Any] }, headers: ["X-Next-Page": page < 3 ? String(page+1) : "", "x-total-pages": "3"])
            }
            let values = try await YunxiaoAPI(connection: c, token: "pat-fixture", transport: transport).listPipelines()
            try check(values.count == 65 && Set(values.map(\.id)).count == 65); let count = await transport.requests.count; try check(count == 3)
        }
        await run("真实终页返回当前页码仍完整读取目录") {
            for total in [0, 7, 30, 37, 60] {
                var c = YunxiaoConnection(); c.organization = "org"; c.account = "fixture"
                let pages = max(1, (total + 29) / 30)
                let transport = MockFlowTransport { r,n in
                    try check(n <= pages, "终页后不应继续请求")
                    let page = Int(URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
                    try check(page == n, "必须按顺序请求全部页")
                    let start = (page - 1) * 30, end = min(page * 30, total)
                    return try response((start..<end).map { ["pipelineId": $0, "pipelineName": "fixture"] as [String: Any] }, headers: ["X-Next-Page": String(min(page + 1, pages)), "X-Total-Pages": String(pages), "X-Total": String(total)])
                }
                let list = try await YunxiaoAPI(connection: c, token: "fixture", transport: transport).listPipelines()
                try check(list.count == total && Set(list.map(\.id)).count == total)
                let count = await transport.requests.count; try check(count == pages)
            }
        }
        await run("实例列表同样识别有总页数证明的终页") {
            var c = YunxiaoConnection(); c.organization = "org"; c.account = "fixture"
            let transport = MockFlowTransport { _,n in
                try check(n == 1)
                return try response([["pipelineRunId": 123, "status": "SUCCESS"]], headers: ["x-next-page": "1", "x-total-pages": "1", "x-total": "1"])
            }
            let runs = try await YunxiaoAPI(connection: c, token: "fixture", transport: transport).listRuns("pipeline")
            try check(runs.count == 1 && runs[0].id == "123")
        }
        await run("未到终页的自引用及矛盾分页头仍拒绝") {
            var c = YunxiaoConnection(); c.organization = "org"; c.account = "fixture"
            let badHeaders = [
                ["x-next-page": "1", "x-total-pages": "2", "x-total": "37"],
                ["x-next-page": "2", "x-total-pages": "1", "x-total": "1"],
                ["x-next-page": "garbage", "x-total-pages": "1", "x-total": "1"],
                ["x-next-page": "1", "x-total-pages": "1", "x-total": "2"],
                ["x-next-page": "1", "x-total-pages": "invalid", "x-total": "1"]
            ]
            for headers in badHeaders {
                let transport = MockFlowTransport { _,n in
                    try check(n == 1, "无效分页必须立即停止")
                    return try response([["pipelineId": 1, "pipelineName": "fixture"]], headers: headers)
                }
                try await rejectsAsync { _ = try await YunxiaoAPI(connection: c, token: "fixture", transport: transport).listPipelines() }
                let count = await transport.requests.count; try check(count == 1)
            }
        }
        await run("缺少分页头继续读取满页而不截断") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let transport = MockFlowTransport { _,n in try response((0..<(n == 1 ? 30 : 2)).map { ["pipelineId": n * 100 + $0, "pipelineName": "Flow"] as [String: Any] }) }
            let list = try await f.api(transport).listPipelines(); try check(list.count == 32)
        }
        await run("异常分页拒绝部分成功与原始错误不泄漏") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let transport = MockFlowTransport { _,_ in try response([["pipelineId": 1, "pipelineName": "x"]], headers: ["x-next-page": "1"]) }
            try await rejectsAsync { _ = try await f.api(transport).listPipelines() }
            for status in [401,403,429,500] {
                let t = MockFlowTransport { _,_ in try response(["secret": "DO-NOT-LEAK"], status: status) }
                do { _ = try await f.api(t).listPipelines(); throw CheckFailure(description: "不应成功") }
                catch { try check(!String(describing: error).contains("DO-NOT-LEAK")) }
            }
            try check(try f.service.cicdState().accounts[0].definitions[0].id == "123")
        }
        await run("连接身份隔离、本地关注稳定及失权保留") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            try f.service.setFlowFavorite(connectionID: f.connection.id, pipelineID: "123", favorite: true)
            var other = f.connection; other.id = UUID(); other.account = "other"; try f.service.saveFlowConnection(other)
            let state = try f.service.cicdState(); try check(state.accounts.first { $0.connectionID == other.id }!.favorites.isEmpty)
            var renamed = f.definition; renamed.name = "新名称"
            try f.service.cacheFlowCatalog(connectionID: f.connection.id, definitions: [renamed]); try f.service.cacheFlowCatalog(connectionID: f.connection.id, definitions: [])
            let account = try f.service.cicdState().accounts.first { $0.connectionID == f.connection.id }!
            try check(account.favorites.contains("123") && account.definitions[0].name == "新名称" && !account.definitions[0].available)
            other.account = "changed"; try rejects { try f.service.saveFlowConnection(other) }
        }
        await run("Git归一化保留路径大小写与已有项目匹配") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            try check(FlowIdentity.repository("git@example.com:Team/Repo.git") == FlowIdentity.repository("https://EXAMPLE.com/Team/Repo/"))
            try check(FlowIdentity.repository("https://example.com/team/repo") != FlowIdentity.repository("https://example.com/Team/Repo"))
            try check(FlowIdentity.projectCandidates(source: f.definition.sources[0], snapshot: f.service.snapshot()).map(\.id) == [f.project.id])
        }
        await run("HTTPS与路径校验、Region独立路由") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            var c = f.connection; c.origin = "http://example.com"; try rejects { _ = try c.validatedOrigin() }
            c.origin = "https://user:pass@example.com"; c.site = .region; try rejects { _ = try c.validatedOrigin() }
            c.origin = "https://region.example.com"; c.organization = ""
            let t = MockFlowTransport { r,_ in try check(r.url!.path == "/oapi/v1/flow/pipelines"); return try response([]) }
            _ = try await YunxiaoAPI(connection: c, token: "pat", transport: t).listPipelines()
            try await rejectsAsync { _ = try await f.api(t).getRun("../evil", runID: "1") }
        }
        await run("多代码源分支Tag与运行参数编码") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            var def = f.definition; def.sources.append(FlowSource(id: "source2", repo: "git@example.com:Other.git"))
            var b = f.binding; b.sourceProjects["source2"] = [f.project.id]
            var draft = f.draft; draft.codes["source2"] = FlowCodeChoice(value: "v1.0", isTag: true); draft.variables["TEXT"] = "quote\"\n+&中文"; draft.variables["SECRET"] = "secret-never-store"
            let (params, safe, targets, _) = try f.validated(draft, binding: b, definition: def)
            let json = try JSONSerialization.jsonObject(with: params) as! [String: Any]
            try check((json["runningTags"] as? [String: String])?["git@example.com:Other.git"] == "v1.0")
            try check((json["envs"] as? [String: String])?["DEPLOY_ENV"] == "test-value" && targets.count == 1)
            try check(!String(decoding: safe, as: UTF8.self).contains("secret-never-store"))
            let t = MockFlowTransport { r,_ in
                let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: String]
                let inner = try JSONSerialization.jsonObject(with: Data(body["params"]!.utf8)) as! [String: Any]
                try check((inner["envs"] as? [String: String])?["TEXT"] == "quote\"\n+&中文"); return try response(7)
            }
            let id = try await f.api(t).submit("123", params: params); try check(id == "7")
        }
        await run("保留默认与提交空字符串不同") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let before = try JSONSerialization.jsonObject(with: f.validated().0) as! [String: Any]
            try check((before["envs"] as! [String: String])["TEXT"] == nil)
            var d = f.draft; d.variables["TEXT"] = ""
            let after = try JSONSerialization.jsonObject(with: f.validated(d).0) as! [String: Any]
            try check((after["envs"] as! [String: String])["TEXT"] == "")
        }
        await run("必填枚举与禁止覆盖校验") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            var d = f.draft; d.variables["PICK"] = "not-an-option"; try rejects { _ = try f.validated(d) }
            var b = f.binding; b.variables[0].required = true; try rejects { _ = try f.validated(binding: b) }
            b = f.binding; b.variables[1].editable = false; d = f.draft; d.variables["TEXT"] = "x"; try rejects { _ = try f.validated(d, binding: b) }
            d.variables["UNKNOWN"] = "x"; try rejects { _ = try f.validated(d) }
        }
        await run("动态环境实际变量与多目标联动") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            var b = f.binding; b.mode = .runtime
            var extra = b.targets[0]; extra.id = UUID(); extra.resources = "test-app-two"; b.targets.append(extra)
            let (data,_,targets,_) = try f.validated(binding: b)
            try check(targets.count == 2)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try check((json["envs"] as! [String: String])["DEPLOY_ENV"] == "test-value")
            b.environmentKey = ""; try rejects { _ = try f.validated(binding: b) }
        }
        await run("生产未知环境与伪装目标全部阻止") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            for name in ["eu", "sea", "publish", "prod", "", "unknown", "TEST"] {
                var b = f.binding; b.targets[0].environment = name; try rejects { _ = try f.validated(binding: b) }
            }
            var b = f.binding; var extra = b.targets[0]; extra.id = UUID(); extra.environment = "eu"; b.targets.append(extra); try rejects { _ = try f.validated(binding: b) }
            b = f.binding; b.targets[0].resources = "eu-app"; try rejects { _ = try f.validated(binding: b) }
            var def = f.definition; def.productionHint = true; try rejects { _ = try f.validated(definition: def) }
            b.mode = .ci; b.targets = []; b.environmentKey = ""; try rejects { _ = try f.validated(binding: b, definition: def) }
        }
        await run("范围缺失、配置漂移与失效项目阻止") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            var b = f.binding; b.targets[0].resources = ""; try rejects { _ = try f.validated(binding: b) }
            b = f.binding; b.definitionRevision = "old"; try rejects { _ = try f.validated(binding: b) }
            b = f.binding; b.sourceProjects["source1"] = [UUID()]; try rejects { _ = try f.validated(binding: b) }
            b = f.binding; b.reviewed = false; try rejects { _ = try f.validated(binding: b) }
            var def = f.definition; def.sources.append(def.sources[0]); try rejects { _ = try f.validated(definition: def) }
        }
        await run("三类制品参数保持原始键与版本") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            var b = f.binding; var d = f.draft
            for kind in FlowArtifactKind.allCases { var a = FlowArtifact(); a.kind = kind; a.key = "raw/key"; b.artifacts.append(a); d.artifacts[a.id] = "version-1" }
            let json = try JSONSerialization.jsonObject(with: f.validated(d, binding: b).0) as! [String: Any]
            for kind in FlowArtifactKind.allCases { try check((json[kind.rawValue] as! [String: String])["raw/key"] == "version-1") }
            d.artifacts = [:]; try rejects { _ = try f.validated(d, binding: b) }
        }
        await run("不支持的分支模式与凭据字段不持久化") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            var raw = Fixture.raw; raw["pipelineConfig"] = ["flow": "test", "settings": "{}", "sources": [["sign": "s", "type": "git", "data": ["repo": "https://example.com/R.git", "isBranchMode": true, "credentialId": "do-not-copy", "webhook": "do-not-copy"]]]]
            let frozen = try JSONSerialization.data(withJSONObject: raw)
            let t = MockFlowTransport { _,_ in FlowHTTPResponse(data: frozen) }
            let def = try await f.api(t).getPipeline("123"); try check(!def.blockers.isEmpty)
            let encoded = String(decoding: try JSONEncoder().encode(def), as: UTF8.self); try check(!encoded.contains("do-not-copy"))
        }
        await run("并发确认至多发送一次与任务人工状态不变") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let t = MockFlowTransport { r,_ in try response(r.httpMethod == "POST" ? 77 : Fixture.raw) }
            let coordinator = FlowRunCoordinator(service: f.service); let api = f.api(t)
            let preview = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft)
            let d = f.draft
            let results = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 { group.addTask { (try? await coordinator.submit(api: api, previewID: preview.id, draft: d, acknowledged: true)) != nil } }
                var values: [Bool] = []; for await value in group { values.append(value) }; return values
            }
            try check(results.filter { $0 }.count == 1); let count = await t.postCount; try check(count == 1)
            let snapshot = try f.service.snapshot(); try check(!snapshot.tasks.first { $0.id == f.task.id }!.isDone)
            try check(snapshot.cicd!.accounts[0].attempts[0].remoteID == "77")
        }
        await run("参数改变与取消确认均不可提交") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let t = MockFlowTransport { _,_ in try response(Fixture.raw) }; let coordinator = FlowRunCoordinator(service: f.service); let api = f.api(t)
            let preview = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft)
            var d = f.draft; d.variables["SECRET"] = "changed"
            try await rejectsAsync { _ = try await coordinator.submit(api: api, previewID: preview.id, draft: d, acknowledged: true) }
            let next = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft)
            try await rejectsAsync { _ = try await coordinator.submit(api: api, previewID: next.id, draft: f.draft, acknowledged: false) }
            let count = await t.postCount; try check(count == 0)
        }
        await run("提交前远端定义变化使旧确认失效") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let t = MockFlowTransport { _,n in var raw = Fixture.raw; if n > 1 { raw["updateTime"] = 99 }; return try response(raw) }
            let coordinator = FlowRunCoordinator(service: f.service); let api = f.api(t)
            let preview = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft)
            try await rejectsAsync { _ = try await coordinator.submit(api: api, previewID: preview.id, draft: f.draft, acknowledged: true) }
            let count = await t.postCount; try check(count == 0)
        }
        await run("提交超时未知不重试、跨重启不重放、人工唯一关联") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let t = MockFlowTransport { r,_ in if r.httpMethod == "POST" { throw URLError(.timedOut) }; return try response(Fixture.raw) }
            let coordinator = FlowRunCoordinator(service: f.service); let api = f.api(t)
            let preview = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft)
            try await rejectsAsync { _ = try await coordinator.submit(api: api, previewID: preview.id, draft: f.draft, acknowledged: true) }
            let reopened = try WorkbenchService(databaseURL: f.directory.appendingPathComponent("state.sqlite")); let next = FlowRunCoordinator(service: reopened)
            try await rejectsAsync { _ = try await next.prepare(api: api, pipelineID: "123", draft: f.draft) }
            try await rejectsAsync { _ = try await next.submit(api: api, previewID: preview.id, draft: f.draft, acknowledged: true) }
            let count = await t.postCount; try check(count == 1)
            try check(try reopened.cicdState().accounts[0].attempts[0].state == .unknown)
            let run = FlowRemoteRun(id: "88", pipelineID: "123")
            try rejects { try reopened.reconcileFlowAttempt(connectionID: f.connection.id, previewID: preview.id, verifiedRun: run, humanConfirmed: false) }
            try reopened.reconcileFlowAttempt(connectionID: f.connection.id, previewID: preview.id, verifiedRun: run, humanConfirmed: true)
            _ = try await next.prepare(api: api, pipelineID: "123", draft: f.draft)
        }
        await run("未知结果不能通过重新授权或切换账号绕过") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let t = MockFlowTransport { r,_ in if r.httpMethod == "POST" { throw URLError(.networkConnectionLost) }; return try response(Fixture.raw) }
            let coordinator = FlowRunCoordinator(service: f.service)
            let p = try await coordinator.prepare(api: f.api(t), pipelineID: "123", draft: f.draft)
            try await rejectsAsync { _ = try await coordinator.submit(api: f.api(t), previewID: p.id, draft: f.draft, acknowledged: true) }
            try f.service.disconnectFlowConnection(f.connection.id)
            var next = f.connection; next.id = UUID(); next.account = "reauthorized-account"
            try f.service.saveFlowConnection(next)
            try f.service.cacheFlowDefinition(connectionID: next.id, definition: f.definition)
            try f.service.saveFlowBinding(connectionID: next.id, binding: f.binding)
            let api = YunxiaoAPI(connection: next, token: "different-fixture", transport: t)
            try await rejectsAsync { _ = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft) }
            try f.service.reconcileFlowAttempt(connectionID: next.id, previewID: p.id, verifiedRun: FlowRemoteRun(id: "known", pipelineID: "123"), humanConfirmed: true)
            _ = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft)
            let count = await t.postCount; try check(count == 1)
        }
        await run("新预览立即使同Flow旧预览失效") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let t = MockFlowTransport { _,_ in try response(Fixture.raw) }; let coordinator = FlowRunCoordinator(service: f.service); let api = f.api(t)
            let old = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft)
            _ = try await coordinator.prepare(api: api, pipelineID: "123", draft: f.draft)
            try await rejectsAsync { _ = try await coordinator.submit(api: api, previewID: old.id, draft: f.draft, acknowledged: true) }
            let count = await t.postCount; try check(count == 0)
        }
        await run("私密参数与备注不写SQLite回执") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let t = MockFlowTransport { r,_ in try response(r.httpMethod == "POST" ? 91 : Fixture.raw) }
            var d = f.draft; d.variables["SECRET"] = "UNIQUE-SECRET-DO-NOT-PERSIST"; d.comment = "PRIVATE-COMMENT-DO-NOT-PERSIST"
            let c = FlowRunCoordinator(service: f.service); let p = try await c.prepare(api: f.api(t), pipelineID: "123", draft: d)
            _ = try await c.submit(api: f.api(t), previewID: p.id, draft: d, acknowledged: true)
            let dump = String(decoding: try JSONEncoder().encode(f.service.snapshot()), as: UTF8.self)
            try check(!dump.contains("UNIQUE-SECRET") && !dump.contains("PRIVATE-COMMENT"))
            for file in try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil) {
                let data = try Data(contentsOf: file); try check(data.range(of: Data("UNIQUE-SECRET".utf8)) == nil && data.range(of: Data("PRIVATE-COMMENT".utf8)) == nil)
            }
        }
        await run("运行列表无状态与实例阶段分开、日志不落盘") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            let t = MockFlowTransport { r,_ in
                if r.url!.path.hasSuffix("/log") { return try response(["content": "build fixture-access-token output", "more": false]) }
                if r.url!.path.hasSuffix("/runs") { return try response([["pipelineRunId": 1, "creatorAccountId": "who", "startTime": 1000]]) }
                return try response(["pipelineRunId": 1, "status": "RUNNING", "globalParams": [["key": "SECRET", "value": "not-persist"]], "stages": [["name": "构建", "stageInfo": ["status": "RUNNING"]]]])
            }
            let api = f.api(t); let runs = try await api.listRuns("123"); try check(runs[0].status == "UNKNOWN")
            let run = try await api.getRun("123", runID: "1"); try check(run.active && run.stages == ["构建 · RUNNING"])
            try f.service.cacheFlowRuns(connectionID: f.connection.id, pipelineID: "123", runs: [run])
            let log = try await api.getLog("123", runID: "1", jobID: "1"); try check(!log.contains("fixture-access-token"))
            let dump = String(decoding: try JSONEncoder().encode(f.service.snapshot()), as: UTF8.self); try check(!dump.contains("not-persist") && !dump.contains("build fixture"))
        }
        await run("OAuth PKCE RFC向量与回调state校验") {
            try check(FlowOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
            try rejects { _ = try FlowOAuth.code(callback: URL(string: "codextasks://oauth?code=x&state=wrong")!, state: "expected") }
            try rejects { _ = try FlowOAuth.code(callback: URL(string: "codextasks://evil?code=x&state=expected")!, state: "expected") }
            try check(try FlowOAuth.code(callback: URL(string: "codextasks://oauth?code=ok&state=expected")!, state: "expected") == "ok")
        }
        await run("OAuth发现、动态注册、换令牌与Bearer不混用PAT") {
            let f = try await Fixture.create(); defer { f.cleanup() }; var connection = f.connection; connection.auth = .oauth
            let t = MockFlowTransport { r,_ in
                switch r.url!.path {
                case "/.well-known/oauth-authorization-server": return try response(["authorization_endpoint": "https://login.example.com/authorize", "token_endpoint": "https://api.example.com/token", "registration_endpoint": "https://api.example.com/register", "code_challenge_methods_supported": ["S256"]])
                case "/register": return try response(["client_id": "fixture-client"])
                case "/token":
                    try check(String(decoding: r.httpBody!, as: UTF8.self).contains("code_verifier=")); return try response(["access_token": "oauth-fixture", "refresh_token": "refresh", "expires_in": 3600, "token_type": "Bearer"])
                default: try check(r.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-fixture" && r.value(forHTTPHeaderField: "x-yunxiao-token") == nil); return try response([])
                }
            }
            let m = try await FlowOAuth.discover(connection: connection, transport: t); let id = try await FlowOAuth.register(metadata: m, transport: t)
            let token = try await FlowOAuth.tokens(endpoint: m.token_endpoint, clientID: id, code: "code", verifier: "verifier", transport: t)
            _ = try await YunxiaoAPI(connection: connection, token: token.accessToken, transport: t).listPipelines()
        }
        await run("显式v1迁移备份且保留任务与工作区数据") {
            let f = try await Fixture.create(); defer { f.cleanup() }
            var snapshot = try f.service.snapshot(); snapshot.cicd = nil
            let payload = try JSONEncoder().encode(snapshot)
            var db: OpaquePointer?; try check(sqlite3_open(f.directory.appendingPathComponent("state.sqlite").path, &db) == SQLITE_OK); defer { sqlite3_close(db) }
            var statement: OpaquePointer?; try check(sqlite3_prepare_v2(db, "UPDATE document SET payload=? WHERE id=1", -1, &statement, nil) == SQLITE_OK)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }; try check(sqlite3_step(statement) == SQLITE_DONE); sqlite3_finalize(statement)
            try check(sqlite3_exec(db, "PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK)
            let migrated = try WorkbenchService(databaseURL: f.directory.appendingPathComponent("state.sqlite"))
            try check(try migrated.snapshot().tasks == snapshot.tasks && migrated.snapshot().projects == snapshot.projects && migrated.snapshot().cicd == nil)
            try check(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).contains { $0.hasPrefix("before-cicd-v2-") })
        }
        let failed = results.filter { $0["passed"] as? Bool != true }.count
        let report: [String: Any] = ["passed": failed == 0, "total": results.count, "failed": failed, "tests": results, "usesRealCredentials": false, "runsRealPipelines": false]
        if let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > index+1 { try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[index+1])) }
        print("\(results.count-failed)/\(results.count) passed"); if failed > 0 { exit(1) }
    }
}
