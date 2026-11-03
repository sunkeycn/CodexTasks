import Foundation
import Security
import CryptoKit

public struct FlowHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data
    public init(status: Int = 200, headers: [String: String] = [:], data: Data) { self.status = status; self.headers = headers; self.data = data }
}
public protocol FlowHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> FlowHTTPResponse }
private final class NoFlowRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class FlowURLTransport: FlowHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: NoFlowRedirect(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> FlowHTTPResponse {
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse, data.count <= 20 * 1024 * 1024 else { throw WorkbenchError.invalid("云效响应无效或超过大小限制。") }
        var headers: [String: String] = [:]
        for (k,v) in response.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        return FlowHTTPResponse(status: response.statusCode, headers: headers, data: data)
    }
}
public enum FlowCredentialStore {
    private static let service = "ai.sunkey.floatingworkbench.yunxiao"
    public static func save(_ value: Data, connectionID: UUID) throws {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: connectionID.uuidString]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw WorkbenchError.persistence("无法在 Keychain 保存云效凭据。") }
        } else if status != errSecSuccess { throw WorkbenchError.persistence("无法更新 Keychain 云效凭据。") }
    }
    public static func read(connectionID: UUID) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: connectionID.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { throw WorkbenchError.unauthorized("云效凭据不可用，请重新连接。") }
        return data
    }
    public static func delete(connectionID: UUID) throws {
        let result = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: connectionID.uuidString] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw WorkbenchError.persistence("Keychain 凭据尚未清除，请重试断开。") }
    }
}
public struct FlowOAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var clientID: String
    public var tokenEndpoint: URL
}
public struct FlowOAuthMetadata: Decodable, Sendable {
    public var authorization_endpoint: URL
    public var token_endpoint: URL
    public var registration_endpoint: URL
    public var code_challenge_methods_supported: [String]
}
public enum FlowOAuth {
    public static let redirectURI = "codextasks://oauth"
    public static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WorkbenchError.invalid("无法生成授权随机数。") }
        return base64(Data(bytes))
    }
    private static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func challenge(_ verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public static func endpoint(_ url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https", c.host != nil, c.user == nil, c.password == nil, c.fragment == nil else { throw WorkbenchError.invalid("授权端点必须为 HTTPS，不能包含凭据。") }
    }
    public static func discover(connection: YunxiaoConnection, transport: any FlowHTTPTransport) async throws -> FlowOAuthMetadata {
        let url = try connection.validatedOrigin().appendingPathComponent(".well-known/oauth-authorization-server")
        let response = try await transport.send(URLRequest(url: url))
        try YunxiaoAPI.check(response)
        let metadata = try JSONDecoder().decode(FlowOAuthMetadata.self, from: response.data)
        try endpoint(metadata.authorization_endpoint); try endpoint(metadata.token_endpoint); try endpoint(metadata.registration_endpoint)
        guard metadata.code_challenge_methods_supported.contains("S256") else { throw WorkbenchError.invalid("站点未声明 PKCE S256，已停止授权。") }
        return metadata
    }
    public static func register(metadata: FlowOAuthMetadata, transport: any FlowHTTPTransport) async throws -> String {
        var request = URLRequest(url: metadata.registration_endpoint); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": "Codex Tasks", "redirect_uris": [redirectURI], "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none"])
        let response = try await transport.send(request); try YunxiaoAPI.check(response)
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        guard let id = object?["client_id"] as? String, !id.isEmpty else { throw WorkbenchError.invalid("站点未返回 OAuth client_id。") }
        return id
    }
    public static func authorizationURL(metadata: FlowOAuthMetadata, clientID: String, verifier: String, state: String) throws -> URL {
        var c = URLComponents(url: metadata.authorization_endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "response_type", value: "code"), .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirectURI), .init(name: "code_challenge", value: challenge(verifier)), .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state)]
        return c.url!
    }
    public static func code(callback: URL, state: String) throws -> String {
        guard callback.scheme == "codextasks", callback.host == "oauth", callback.path.isEmpty || callback.path == "/",
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw WorkbenchError.invalid("授权回调地址不匹配。") }
        let items = parts.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
              !items.contains(where: { $0.name == "error" }), items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw WorkbenchError.unauthorized("授权已取消或回调校验失败。") }
        return code
    }
    public static func tokens(endpoint: URL, clientID: String, code: String? = nil, verifier: String? = nil, refreshToken: String? = nil, transport: any FlowHTTPTransport) async throws -> FlowOAuthTokens {
        try self.endpoint(endpoint)
        var fields: [String: String] = ["client_id": clientID]
        if let refreshToken { fields["grant_type"] = "refresh_token"; fields["refresh_token"] = refreshToken }
        else { fields["grant_type"] = "authorization_code"; fields["code"] = code; fields["code_verifier"] = verifier; fields["redirect_uri"] = redirectURI }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Data(body.utf8)
        let response = try await transport.send(request); try YunxiaoAPI.check(response)
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        guard let token = object?["access_token"] as? String, !token.isEmpty, (object?["token_type"] as? String)?.lowercased() == "bearer", let expiry = object?["expires_in"] as? Double, expiry > 0 else { throw WorkbenchError.unauthorized("授权响应不完整，请重新授权。") }
        return FlowOAuthTokens(accessToken: token, refreshToken: object?["refresh_token"] as? String ?? refreshToken, expiresAt: Date().addingTimeInterval(expiry), clientID: clientID, tokenEndpoint: endpoint)
    }
}
public struct YunxiaoAPI: Sendable {
    public var connection: YunxiaoConnection
    private var token: String
    private var transport: any FlowHTTPTransport
    public init(connection: YunxiaoConnection, token: String, transport: any FlowHTTPTransport = FlowURLTransport()) { self.connection = connection; self.token = token; self.transport = transport }
    static func check(_ response: FlowHTTPResponse) throws {
        switch response.status {
        case 200..<300: return
        case 401: throw WorkbenchError.unauthorized("云效授权失效，请重新连接。")
        case 403: throw WorkbenchError.unauthorized("账号没有此资源的读取或运行权限；未通过执行流水线测试权限。")
        case 404: throw WorkbenchError.missing("云效资源不存在或当前账号不可见。")
        case 429: throw WorkbenchError.conflict("云效限流，请稍后手动重试；已有缓存保留。")
        default: throw WorkbenchError.invalid("云效请求未完成（HTTP \(response.status)）；未记录服务器原始响应。")
        }
    }
    private func request(_ components: [String], query: [URLQueryItem] = [], body: Data? = nil) async throws -> FlowHTTPResponse {
        var url = try connection.validatedOrigin().appendingPathComponent("oapi/v1/flow")
        if connection.site == .central { url.appendPathComponent("organizations"); url.appendPathComponent(connection.organization) }
        url.appendPathComponent("pipelines")
        for part in components {
            guard !part.isEmpty, part != ".", part != "..", !part.contains("/"), !part.contains("?"), !part.contains("#") else { throw WorkbenchError.invalid("云效资源 ID 无效。") }
            url.appendPathComponent(part)
        }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!); r.httpMethod = body == nil ? "GET" : "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if connection.auth == .pat { r.setValue(token, forHTTPHeaderField: "x-yunxiao-token") }
        else { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        r.httpBody = body
        try Task.checkCancellation()
        // No automatic write retries, including on transient failures or token expiry.
        let response = try await transport.send(r); try Self.check(response)
        return response
    }
    private func pages(_ path: [String]) async throws -> [[String: Any]] {
        var output: [[String: Any]] = []; var page = 1; var visited = Set<Int>(); var pageDigests = Set<Data>(); var expectedTotal: Int?; var expectedPages: Int?
        while true {
            guard page > 0, visited.insert(page).inserted, visited.count <= 10000 else { throw WorkbenchError.invalid("云效分页异常；没有把部分结果覆盖完整目录。") }
            let r = try await request(path, query: [.init(name: "page", value: String(page)), .init(name: "perPage", value: "30")])
            guard let values = try JSONSerialization.jsonObject(with: r.data) as? [[String: Any]] else { throw WorkbenchError.invalid("云效列表格式不受支持。") }
            if !values.isEmpty {
                let canonical = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
                guard pageDigests.insert(Data(SHA256.hash(data: canonical))).inserted else { throw WorkbenchError.invalid("云效重复返回同一页，已停止分页并保留旧缓存。") }
            }
            output.append(contentsOf: values)
            let headers = Dictionary(r.headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }, uniquingKeysWith: { a,_ in a })
            if let totalHeader = headers["x-total"] {
                guard let total = Int(totalHeader), total >= 0, expectedTotal == nil || expectedTotal == total else { throw WorkbenchError.conflict("云效目录总数变化或分页头无效，请重新刷新完整目录。") }
                expectedTotal = total
            }
            if let pagesHeader = headers["x-total-pages"] {
                guard let total = Int(pagesHeader), total >= 0,
                      expectedPages == nil || expectedPages == total,
                      (total == 0 ? page == 1 && output.isEmpty : page <= total) else {
                    throw WorkbenchError.conflict("云效总页数变化或分页头无效，请重新刷新完整目录。")
                }
                expectedPages = total
            }
            if let next = headers["x-next-page"], !next.isEmpty, next != "0" {
                guard let n = Int(next) else { throw WorkbenchError.invalid("云效下一页标记无效。") }
                // The live Flow API repeats the current page on the last page.
                // Accept that only when total-pages independently confirms completion.
                if n == page, let total = expectedPages, page >= total { break }
                guard n > page, expectedPages.map({ n <= $0 }) ?? true else { throw WorkbenchError.invalid("云效下一页标记无效。") }
                page = n
            } else if let total = expectedPages, page < total { page += 1 }
            else if headers["x-next-page"] != nil || headers["x-total-pages"] != nil || values.count < 30 { break }
            else { page += 1 }
        }
        guard expectedTotal == nil || output.count == expectedTotal else { throw WorkbenchError.invalid("分页结果与云效总数不一致，已保留旧缓存。") }
        return output
    }
    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }; if let n = value as? NSNumber { return n.stringValue }; return nil
    }
    public func listPipelines() async throws -> [PipelineDefinition] {
        let values = try await pages([]); var seen = Set<String>()
        return try values.map { item in
            guard let id = Self.string(item["pipelineId"]), let name = item["pipelineName"] as? String, seen.insert(id).inserted else { throw WorkbenchError.invalid("目录含缺失或重复流水线 ID，已保留旧缓存。") }
            return PipelineDefinition(id: id, name: name)
        }
    }
    public func getPipeline(_ id: String) async throws -> PipelineDefinition {
        let r = try await request([id])
        guard let raw = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], let name = raw["name"] as? String, let config = raw["pipelineConfig"] as? [String: Any] else { throw WorkbenchError.invalid("无法识别此流水线详情，禁止运行。") }
        var result = PipelineDefinition(id: id, name: name)
        // Hash the complete configuration but persist only safe structured metadata, never webhook/credentials/YAML.
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        result.revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        result.detailLoaded = true; result.syncedAt = Date()
        let flowText = (config["flow"] as? String ?? "") + " " + (raw["envName"] as? String ?? "")
        result.productionHint = flowText.range(of: #"(?i)(\b(prod|production|publish|eu|sea)\b|正式|生产)"#, options: .regularExpression) != nil
        let sources = config["sources"] as? [[String: Any]] ?? []
        var seen = Set<String>(); var repos = Set<String>()
        for source in sources {
            let sourceType = source["type"] as? String ?? ""
            let knownGitTypes = Set(["aliyungit", "customgitlab", "giteegit", "codeup", "git", "gitlab", "bitbucket", "githuboauth", "github"])
            if !knownGitTypes.contains(sourceType.lowercased()) { result.blockers.append("代码源类型 \(sourceType) 尚未适配，请在云效核对。"); continue }
            let sourceData = source["data"] as? [String: Any] ?? [:]
            if sourceData["isBranchMode"] as? Bool == true { result.blockers.append("分支模式尚未适配，请在云效运行。") }
            guard let repo = sourceData["repo"] as? String, let sign = source["sign"] as? String else {
                result.blockers.append("存在未识别的代码 / 制品源，请在云效核对。")
                continue
            }
            if !seen.insert(sign).inserted || !repos.insert(repo).inserted { result.blockers.append("重复代码源不能唯一映射到运行参数。") }
            if let u = URLComponents(string: repo), u.password != nil || u.query != nil || (u.user != nil && u.user != "git") { result.blockers.append("仓库地址含凭据或查询串，禁止保存与运行。"); continue }
            result.sources.append(FlowSource(id: sign, repo: repo, branch: sourceData["branch"] as? String ?? "", type: source["type"] as? String ?? "git"))
        }
        if config["flow"] == nil { result.blockers.append("缺少流程定义，无法核对执行范围。") }
        return result
    }
    public func listRuns(_ pipelineID: String) async throws -> [FlowRemoteRun] {
        let values = try await pages([pipelineID, "runs"]).map { try Self.run($0, pipelineID: pipelineID) }
        guard Set(values.map(\.id)).count == values.count else { throw WorkbenchError.invalid("运行分页出现重复实例，请重新读取。") }
        return values
    }
    public func getRun(_ pipelineID: String, runID: String) async throws -> FlowRemoteRun {
        let r = try await request([pipelineID, "runs", runID])
        guard let raw = try JSONSerialization.jsonObject(with: r.data) as? [String: Any] else { throw WorkbenchError.invalid("运行详情格式无法解析。") }
        let result = try Self.run(raw, pipelineID: pipelineID)
        guard result.id == runID, Self.string(raw["pipelineId"]).map({ $0 == pipelineID }) ?? true else { throw WorkbenchError.invalid("返回实例与请求的流水线 / 实例 ID 不一致。") }
        return result
    }
    private static func run(_ raw: [String: Any], pipelineID: String) throws -> FlowRemoteRun {
        guard let id = string(raw["pipelineRunId"]) else { throw WorkbenchError.invalid("运行实例没有稳定 ID。") }
        var run = FlowRemoteRun(id: id, pipelineID: pipelineID)
        run.status = raw["status"] as? String ?? "UNKNOWN"; run.creator = raw["creatorAccountId"] as? String ?? ""
        if let ms = (raw["startTime"] ?? raw["createTime"]) as? Double, ms > 0 { run.startedAt = Date(timeIntervalSince1970: ms / 1000) }
        if let ms = raw["endTime"] as? Double, ms > 0 { run.finishedAt = Date(timeIntervalSince1970: ms / 1000) }
        run.stages = (raw["stages"] as? [[String: Any]] ?? []).map { stage in
            let info = stage["stageInfo"] as? [String: Any] ?? [:]
            return "\(stage["name"] as? String ?? "阶段") · \(info["status"] as? String ?? "UNKNOWN")"
        }
        run.jobs = (raw["stages"] as? [[String: Any]] ?? []).flatMap { stage -> [FlowJob] in
            let info = stage["stageInfo"] as? [String: Any] ?? [:]
            return (info["jobs"] as? [[String: Any]] ?? []).compactMap { job in
                guard let id = Self.string(job["id"]) else { return nil }
                return FlowJob(id: id, name: job["name"] as? String ?? "任务", status: job["status"] as? String ?? "UNKNOWN")
            }
        }
        // Never persist globalParams, job params/results or returned authorization material.
        run.actualVersions = (raw["sources"] as? [[String: Any]] ?? []).compactMap { source in
            let d = source["data"] as? [String: Any] ?? [:]
            guard let sha = d["commitId"] as? String ?? d["commit"] as? String else { return nil }
            return "\(source["sign"] as? String ?? "代码源"): \(sha)"
        }
        return run
    }
    public func getLog(_ pipelineID: String, runID: String, jobID: String) async throws -> String {
        let r = try await request([pipelineID, "runs", runID, "job", jobID, "log"])
        let raw = try JSONSerialization.jsonObject(with: r.data) as? [String: Any]
        guard let content = raw?["content"] as? String else { throw WorkbenchError.invalid("日志格式无法解析。") }
        return content.replacingOccurrences(of: token, with: "••••")
    }
    public func submit(_ pipelineID: String, params: Data) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["params": String(decoding: params, as: UTF8.self)])
        let r = try await request([pipelineID, "runs"], body: body)
        let value = try JSONSerialization.jsonObject(with: r.data, options: [.fragmentsAllowed])
        guard let id = Self.string(value), !id.isEmpty else { throw WorkbenchError.invalid("云效未返回实例 ID，需要人工核对。") }
        return id
    }
}
