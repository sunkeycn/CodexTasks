import Foundation
import Darwin

public struct HookRecord: Codable, Equatable, Sendable {
    public var sessionID: String
    public var status: SessionStatus
    public var updatedAt: Date
    public var turnID: String?
    public var taskNumber: Int64?
    public var commandAt: Date?
}

/// The hook bridge stores only lifecycle metadata, never prompts, responses or working directories.
public struct HookEventStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    @discardableResult public func record(_ input: Data, at date: Date = Date()) throws -> Bool {
        guard input.count <= 1_048_576, let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let rawID = payload["session_id"] as? String, let id = UUID(uuidString: rawID)?.uuidString.lowercased(),
              let event = payload["hook_event_name"] as? String else { return false }
        // Codex may report a subagent hook under its parent's session id.
        if payload["agent_id"] as? String != nil || payload["agent_type"] as? String != nil || payload["parent_thread_id"] as? String != nil { return false }
        let status: SessionStatus
        switch event {
        case "UserPromptSubmit": status = .running
        case "Stop": status = .completed
        case "Interrupt": status = .interrupted
        default: return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent(id + ".lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LiteError.message("无法锁定 Hooks 事件。") }
        defer { close(fd) }
        // A hook must never stall a Codex turn behind another process.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        let url = directory.appendingPathComponent(id + ".json")
        let previous = try? load(url)
        let turnID = payload["turn_id"] as? String
        if let previous {
            guard date >= previous.updatedAt else { return false }
            if event != "UserPromptSubmit", let turnID, let current = previous.turnID, turnID != current { return false }
            if event == "UserPromptSubmit", let turnID, turnID == previous.turnID, previous.status != .running { return false }
        }
        let number = event == "UserPromptSubmit" ? TaskAssociation.number(in: payload["prompt"] as? String ?? "") : nil
        let record = HookRecord(sessionID: id, status: status, updatedAt: date, turnID: turnID ?? previous?.turnID,
                                taskNumber: number ?? previous?.taskNumber, commandAt: number == nil ? previous?.commandAt : date)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
    private func load(_ url: URL) throws -> HookRecord {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 8192 else { throw LiteError.message("无效的 Hooks 事件文件。") }
        let record = try JSONDecoder().decode(HookRecord.self, from: Data(contentsOf: url))
        guard UUID(uuidString: record.sessionID) != nil, url.lastPathComponent == record.sessionID + ".json" else { throw LiteError.message("Hooks 会话标识不匹配。") }
        return record
    }
    public func merged(with observations: [ObservedSession], snapshot: TaskSnapshot, runningTimeout: TimeInterval, at date: Date = Date()) throws -> [ObservedSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return observations }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var merged = Dictionary(observations.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for url in files where url.pathExtension == "json" {
            guard let record = try? load(url), record.updatedAt <= date.addingTimeInterval(5) else { continue }
            let existing = snapshot.sessions.first { $0.id.lowercased() == record.sessionID }
            let linked = existing?.taskID != nil
            let hasTask = record.taskNumber.map { n in snapshot.tasks.contains { $0.id == n && $0.createdAt <= (record.commandAt ?? .distantPast) } } ?? false
            guard merged[record.sessionID] != nil || linked || hasTask else { continue }
            var observation = merged[record.sessionID] ?? ObservedSession(id: existing?.id ?? record.sessionID, title: existing?.title ?? "Codex Session", updatedAt: .distantPast, projectName: existing?.projectName ?? "")
            if record.updatedAt >= observation.updatedAt {
                observation.status = record.status == .running && date.timeIntervalSince(record.updatedAt) > runningTimeout ? .unknown : record.status
                observation.updatedAt = record.updatedAt
            }
            if let number = record.taskNumber, let commandAt = record.commandAt, commandAt >= (observation.commandAt ?? .distantPast) {
                observation.taskNumber = number; observation.commandAt = commandAt
            }
            merged[record.sessionID] = observation
        }
        return merged.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
}
