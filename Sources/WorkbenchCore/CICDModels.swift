import Foundation
import CryptoKit

public enum YunxiaoSite: String, Codable, CaseIterable, Sendable { case central, region }
public enum YunxiaoAuth: String, Codable, CaseIterable, Sendable { case pat, oauth }
public struct YunxiaoConnection: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var site: YunxiaoSite = .central
    public var origin = "https://openapi-rdc.aliyuncs.com"
    public var organization = ""
    /// User-facing account label; a new authorization always receives a new identity.
    public var account = ""
    public var auth: YunxiaoAuth = .pat
    public var readOnly = true
    public init() {}
    public func validatedOrigin() throws -> URL {
        guard let c = URLComponents(string: origin), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", c.port == nil || c.port == 443,
              site != .central || host == "openapi-rdc.aliyuncs.com",
              site != .central || organization.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = c.url else { throw WorkbenchError.invalid("请填写有效的 HTTPS 站点、组织及账号标识；中心站使用官方 OpenAPI 地址。") }
        return url
    }
    public var resourceScope: String { site.rawValue + "|" + origin.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + organization }
    public var label: String { "\(site == .central ? "中心站" : "Region") · \(organization.isEmpty ? origin : organization) · \(account)" }
}
public struct FlowSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var repo: String
    public var branch: String
    public var type: String
    public init(id: String, repo: String, branch: String = "", type: String = "git") { self.id = id; self.repo = repo; self.branch = branch; self.type = type }
}
public struct PipelineDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var revision = ""
    public var sources: [FlowSource] = []
    public var blockers: [String] = []
    public var productionHint = false
    public var detailLoaded = false
    public var available = true
    public var syncedAt: Date?
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public enum FlowVariableKind: String, Codable, CaseIterable, Sendable { case string, enumeration, secret }
public struct FlowVariable: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var key = ""
    public var label = ""
    public var kind: FlowVariableKind = .string
    public var options: [String] = []
    public var defaultValue = ""
    public var required = false
    public var editable = true
    public init() {}
}
public enum FlowArtifactKind: String, Codable, CaseIterable, Sendable { case runningPipelineArtifacts, runningAcrArtifacts, runningPackagesArtifacts }
public struct FlowArtifact: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: FlowArtifactKind = .runningPipelineArtifacts
    public var key = ""
    public var label = ""
    public init() {}
}
public enum FlowEnvironmentMode: String, Codable, CaseIterable, Sendable { case fixed, runtime, ci }
public struct FlowTarget: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var environment = ""
    public var value = ""
    public var resources = ""
    public var action = ""
    public var impact = ""
    public var evidence = ""
    public init() {}
    public var isProduction: Bool {
        !["dev", "test", "daily", "pre"].contains(environment)
            || resources.range(of: #"(?i)\b(prod|production|publish|eu|sea)\b"#, options: .regularExpression) != nil
    }
    public var complete: Bool { [environment, resources, action, impact, evidence].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}
public struct PipelineBinding: Codable, Equatable, Sendable {
    public var pipelineID: String
    public var definitionRevision = ""
    public var sourceProjects: [String: [UUID]] = [:]
    public var mode: FlowEnvironmentMode = .fixed
    public var environmentKey = ""
    public var targets: [FlowTarget] = []
    public var variables: [FlowVariable] = []
    public var artifacts: [FlowArtifact] = []
    public var reviewed = false
    public var evidence = ""
    public init(pipelineID: String) { self.pipelineID = pipelineID }
}
public struct FlowCodeChoice: Codable, Equatable, Sendable {
    public var isTag = false
    public var value: String
    public init(value: String, isTag: Bool = false) { self.value = value; self.isTag = isTag }
}
/// Kept in memory. Never serialize this object to SQLite, preferences, receipts or logs.
public struct FlowRunDraft: Equatable, Sendable {
    public var codes: [String: FlowCodeChoice] = [:]
    /// Missing key means preserve the server default; empty string is an explicit override.
    public var variables: [String: String] = [:]
    public var artifacts: [UUID: String] = [:]
    public var targetID: UUID?
    public var comment = ""
    public var taskID: UUID?
    public init() {}
}
public struct FlowRunPreview: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var connectionID: UUID
    public var pipelineID: String
    public var pipelineName: String
    public var revision: String
    public var bindingDigest: String
    public var targets: [FlowTarget]
    public var projects: [String]
    public var redactedParameters: String
    public var taskID: UUID?
    public var createdAt = Date()
    public var expiresAt = Date().addingTimeInterval(900)
    public var versionWarning = "按分支 / Tag 名运行，未锁定 commit SHA；实际构建版本以云效实例为准。"
}
public enum FlowAttemptState: String, Codable, Sendable { case submitting, unknown, accepted }
public struct FlowRunAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { preview.id }
    public var preview: FlowRunPreview
    public var state: FlowAttemptState
    public var remoteID: String?
    public var createdAt = Date()
}
public struct FlowJob: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var status: String
    public init(id: String, name: String, status: String) { self.id = id; self.name = name; self.status = status }
}
public struct FlowRemoteRun: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var pipelineID: String
    public var status = "UNKNOWN"
    public var creator = ""
    public var startedAt: Date?
    public var finishedAt: Date?
    public var stages: [String] = []
    public var jobs: [FlowJob] = []
    public var actualVersions: [String] = []
    public init(id: String, pipelineID: String) { self.id = id; self.pipelineID = pipelineID }
    public var statusLabel: String {
        switch status.uppercased() {
        case "SUCCESS", "SUCCEEDED": return "成功"
        case "FAIL", "FAILED": return "失败"
        case "RUNNING": return "运行中"
        case "WAITING", "QUEUED", "PENDING": return "排队"
        case "WAITING_FOR_CONFIRM", "WAITING_FOR_APPROVAL", "MANUAL": return "等待人工"
        case "CANCELED", "CANCELLED": return "取消"
        default: return "未知（\(status)）"
        }
    }
    public var active: Bool { ["RUNNING", "WAITING", "QUEUED", "PENDING", "WAITING_FOR_CONFIRM", "WAITING_FOR_APPROVAL", "MANUAL"].contains(status.uppercased()) }
}
public struct FlowAccountCache: Codable, Equatable, Sendable {
    public var connectionID: UUID
    public var resourceScope = ""
    public var definitions: [PipelineDefinition] = []
    public var favorites: Set<String> = []
    public var bindings: [String: PipelineBinding] = [:]
    public var runs: [String: [FlowRemoteRun]] = [:]
    public var attempts: [FlowRunAttempt] = []
    public var syncedAt: Date?
    public init(connectionID: UUID, resourceScope: String = "") { self.connectionID = connectionID; self.resourceScope = resourceScope }
}
public struct CICDState: Codable, Equatable, Sendable {
    public var connections: [YunxiaoConnection] = []
    public var selectedConnectionID: UUID?
    public var accounts: [FlowAccountCache] = []
    public init() {}
}
public enum FlowIdentity {
    public static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    public static func repository(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://"), let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":") {
            text = "ssh://" + text[..<colon] + "/" + text[text.index(after: colon)...]
        }
        guard let url = URLComponents(string: text), let host = url.host else { return nil }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        return host.lowercased() + (url.port.map { ":\($0)" } ?? "") + path
    }
    public static func projectCandidates(source: FlowSource, snapshot: WorkbenchSnapshot) -> [Project] {
        guard let repo = repository(source.repo) else { return [] }
        let ids = Set(snapshot.repositories.filter { repository($0.identity) == repo }.map(\.id))
        return snapshot.projects.filter { ids.contains($0.repositoryID) }
    }
}
