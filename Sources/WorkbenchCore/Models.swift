import Foundation

public struct WorkTask: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var number: Int
    public var title: String
    public var notes = ""
    public var acceptance = ""
    public var isDone = false
    public var completedAt: Date?
    public var version = 1
    public var createdAt = Date()
    public var defaultBranchID: UUID?
    public var displayNumber: String { String(format: "T#%02d", number) }
    public var associationPrompt: String { "关联Codex Task【\(displayNumber)】" }
    public func editableCodexNotes(_ notes: String? = nil) -> String {
        // Earlier versions allowed users to paste the association into notes.
        // Remove only this task's own outer header/footer, preserving the body.
        var lines = (notes ?? self.notes).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == associationPrompt { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == associationPrompt { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func codexPrompt(notes: String? = nil, title: String? = nil) -> String {
        let body = editableCodexNotes(notes)
        return associationPrompt + "\n" + (body.isEmpty ? (title ?? self.title).trimmingCharacters(in: .whitespacesAndNewlines) : body)
    }
    public func codexURL(workspace: String, notes: String? = nil, title: String? = nil) -> URL? {
        var url = URLComponents()
        url.scheme = "codex"; url.host = "new"
        url.queryItems = [URLQueryItem(name: "prompt", value: codexPrompt(notes: notes, title: title)), URLQueryItem(name: "path", value: workspace)]
        // Codex uses URL query decoding; preserve literal plus signs in the Prompt.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url
    }
}

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var repositoryID: UUID
}

public struct Repository: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var identity: String
}

public struct Checkout: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var repositoryID: UUID
    public var path: String
    // V1 only stores metadata. Registration never grants filesystem access.
    public var authorization = "metadata-only"
}

public enum BranchAvailability: String, Codable, CaseIterable, Sendable {
    case available, unknown, deleted
    public var label: String {
        switch self {
        case .available: return "可用"
        case .unknown: return "读取未知"
        case .deleted: return "已删除"
        }
    }
}

public struct Branch: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID
    public var ref: String
    public var sha: String
    public var isFollowed = true
    public var availability = BranchAvailability.available
    public var confirmedAt = Date()
}

public struct TaskBranch: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var taskID: UUID
    public var branchID: UUID
    public var isProjectDefault = false
}

public struct UnlinkReceipt: Codable, Equatable, Sendable {
    public var link: TaskBranch
    public var wasTaskDefault: Bool
    public var taskVersionAfter: Int
}

public struct SessionAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var sessionID: String
    public var taskID: UUID
    public var branchID: UUID?
    public var sessionName: String?
    public var workspacePath: String?
    public var scopeDescription: String
    public var version = 1
    public var attachedAt = Date()
}

public enum RunState: String, Codable, CaseIterable, Sendable {
    case running, completed, needsInput, failed, interrupted, unknown
    public var label: String {
        switch self {
        case .running: return "正在运行"
        case .completed: return "运行完成"
        case .needsInput: return "需要输入"
        case .failed: return "执行失败"
        case .interrupted: return "执行中断"
        case .unknown: return "同步未知"
        }
    }
    public var isTerminal: Bool { [.completed, .failed, .interrupted].contains(self) }
    public var isException: Bool { [.needsInput, .failed, .interrupted, .unknown].contains(self) }
}

public struct CodexRun: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var taskID: UUID
    public var sessionID: String
    public var branchID: UUID?
    public var scopeDescription: String
    public var state = RunState.running
    public var sequence = 0
    public var updatedAt = Date()
    public var summary = "等待模拟生命周期事件"
    public var source = "模拟适配器"
    public var externalTurnID: String?
}

public struct Suggestion: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var taskID: UUID
    public var sourceRunID: UUID?
    public var title: String
    public var reason: String
    public var adoptedTaskID: UUID?
    public var isIgnored = false
    public var createdAt = Date()
}

public enum PipelineState: String, Codable, CaseIterable, Sendable {
    case queued, running, approval, succeeded, failed, cancelled, unknown
    public var label: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "运行中"
        case .approval: return "待审批"
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .unknown: return "提交结果未知"
        }
    }
    public var isTerminal: Bool { [.succeeded, .failed, .cancelled].contains(self) }
}

public struct PipelineRun: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var projectID: UUID
    public var branchID: UUID
    public var environment: String
    public var sha: String
    public var state = PipelineState.running
    public var stage = "模拟构建"
    public var updatedAt = Date()
    public var taskID: UUID?
    public var source = "模拟云效"
    public var remoteID: String
    public var planID: UUID
}

public struct DeploymentScope: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var projectName: String
    public var branchID: UUID
    public var branchRef: String
    public var environment: String
    public var sha: String
    public var pipeline: String
    public var resource: String
    public var action: String
    public var impact: String
    public var parameters: String
    public var taskID: UUID?
}

public struct DeploymentPlan: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var scope: DeploymentScope
    public var digest: String
    public var createdAt = Date()
    public var pipelineRunID: UUID?
    public var invalidatedReason: String?
}

public struct UpdateNotice: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var key: String
    public var taskID: UUID?
    public var pipelineRunID: UUID?
    public var message: String
    public var isError: Bool
    public var isRead = false
    public var createdAt = Date()
}

public struct RunEvent: Codable, Equatable, Sendable {
    public var runID: UUID
    public var state: RunState
    public var sequence: Int
    public var summary: String
    public init(runID: UUID, state: RunState, sequence: Int, summary: String) {
        self.runID = runID; self.state = state; self.sequence = sequence; self.summary = summary
    }
}

public struct WorkbenchSnapshot: Codable, Equatable, Sendable {
    public var cicd: CICDState?
    public var nextNumber = 1
    public var demoSeeded = false
    public var tasks: [WorkTask] = []
    public var projects: [Project] = []
    public var repositories: [Repository] = []
    public var checkouts: [Checkout] = []
    public var branches: [Branch] = []
    public var links: [TaskBranch] = []
    public var attachments: [SessionAttachment] = []
    public var runs: [CodexRun] = []
    public var suggestions: [Suggestion] = []
    public var pipelines: [PipelineRun] = []
    public var plans: [DeploymentPlan] = []
    public var notices: [UpdateNotice] = []
    public var eventLedger: [String: RunEvent] = [:]
    public var draft = ""
    public init() {}
    public var activeRuns: Int { runs.filter { $0.state == .running }.count }
    public var unreadCount: Int { notices.filter { !$0.isRead }.count }
    public func runSummary(taskID: UUID) -> String {
        let relevant = runs.filter { $0.taskID == taskID }
        let count = relevant.filter { $0.state == .running }.count
        if count > 0 { return "正在运行 \(count) 项" }
        return relevant.max(by: { $0.updatedAt < $1.updatedAt })?.state.label ?? "尚未运行"
    }
    public func project(for branch: Branch) -> Project? { projects.first { $0.id == branch.projectID } }
}

public struct ResolvedContext: Equatable, Sendable {
    public var task: WorkTask
    public var project: Project
    public var branch: Branch
    public var description: String
    public var branchMismatch: Bool
    public var metadataOnly = true
}

public struct CallerScope: Sendable {
    public var authorizedProjectIDs: Set<UUID>
    public var currentProjectID: UUID?
    public var currentBranchRef: String?
    public init(authorizedProjectIDs: Set<UUID>, currentProjectID: UUID? = nil, currentBranchRef: String? = nil) {
        self.authorizedProjectIDs = authorizedProjectIDs
        self.currentProjectID = currentProjectID
        self.currentBranchRef = currentBranchRef
    }
}

public enum WorkbenchError: LocalizedError, Equatable, Sendable {
    case invalid(String), missing(String), conflict(String), persistence(String), unauthorized(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .missing(let text), .conflict(let text), .persistence(let text), .unauthorized(let text): return text
        }
    }
}
