import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo, doing, done
    public var label: String {
        switch self { case .todo: return "未开始"; case .doing: return "进行中"; case .done: return "已完成" }
    }
}

public struct TaskItem: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var title: String
    public var status: TaskStatus
    public let createdAt: Date
    public var parentID: Int64? = nil
    public var number: String { String(format: "T#%02lld", id) }
    public var associationPrompt: String { "关联任务【\(number)】" }
}

public enum SessionStatus: String, Codable, Sendable {
    case idle, running, completed, interrupted, failed, unknown
    public var label: String {
        switch self {
        case .idle: return "未运行"
        case .running: return "运行中"
        case .completed: return "运行完成"
        case .interrupted: return "已中断"
        case .failed: return "运行失败"
        case .unknown: return "状态未知"
        }
    }
}

public struct SessionItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskID: Int64?
    public let title: String
    public let status: SessionStatus
    public let updatedAt: Date
    public let boundAt: Date
}

public struct ObservedSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: SessionStatus
    public var updatedAt: Date
    public var taskNumber: Int64?
    public var commandAt: Date?
    public init(id: String, title: String, status: SessionStatus = .unknown, updatedAt: Date = Date(), taskNumber: Int64? = nil, commandAt: Date? = nil) {
        self.id = id; self.title = title; self.status = status; self.updatedAt = updatedAt
        self.taskNumber = taskNumber; self.commandAt = commandAt
    }
}

public struct TaskSnapshot: Equatable, Sendable {
    public var tasks: [TaskItem]
    public var sessions: [SessionItem]
    public init(tasks: [TaskItem] = [], sessions: [SessionItem] = []) { self.tasks = tasks; self.sessions = sessions }
    public var rootTasks: [TaskItem] { tasks.filter { $0.parentID == nil } }
    public func children(of taskID: Int64) -> [TaskItem] { tasks.filter { $0.parentID == taskID } }
    public var outlineTasks: [TaskItem] { rootTasks.flatMap { [$0] + children(of: $0.id) } }
    public func sessions(for taskID: Int64) -> [SessionItem] { sessions.filter { $0.taskID == taskID } }
}

public enum LiteError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
