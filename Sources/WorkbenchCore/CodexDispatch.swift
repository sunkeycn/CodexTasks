import Foundation
import Darwin

public struct CodexDispatchRequest: Codable {
    public let id: UUID
    public let taskID: UUID
    public let databaseURL: URL
    public let workspace: String
    public let title: String
    public let prompt: String
    public let receiptURL: URL

    public init(task: WorkTask, databaseURL: URL, workspace: String, notes: String, title: String) {
        id = UUID(); taskID = task.id; self.databaseURL = databaseURL
        self.workspace = workspace; self.title = title
        prompt = task.codexPrompt(notes: notes, title: title)
        receiptURL = databaseURL.deletingLastPathComponent().appendingPathComponent("codex-dispatch/\(id.uuidString).json")
    }
}

public struct CodexDispatchReceipt: Codable {
    public enum State: String, Codable { case starting, running, completed, failed, unknown }
    public var taskID: UUID
    public var state: State = .starting
    public var sessionID: String?
    public var runnerPID: Int32?
    public var message: String?
    public var updatedAt = Date()
    public var isPending: Bool { state == .starting || state == .running }

    public init(taskID: UUID) { self.taskID = taskID }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

/// Runs in a separate helper so hiding, quitting or updating the workbench does
/// not close the CLI's pipes or interrupt a task that the user already submitted.
public enum CodexDispatchRunner {
    public static func executableURL() -> URL? {
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public static func run(_ request: CodexDispatchRequest, executable: URL? = nil) throws {
        var receipt = CodexDispatchReceipt(taskID: request.taskID)
        receipt.runnerPID = getpid()
        let process = Process()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        func publish() throws {
            receipt.updatedAt = Date(); try receipt.save(to: request.receiptURL)
            CodexBridgeClient.notify(CodexBridgeEvent(receiptURL: request.receiptURL))
        }
        do {
            try publish()
            guard let executable = executable ?? executableURL() else {
                throw WorkbenchError.invalid("未找到本机 Codex CLI，请安装或更新 Codex。")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: request.workspace, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw WorkbenchError.invalid("工作区目录不存在，未提交任务。")
            }
            // Retain model/auth/rules configuration. Allow code edits only within
            // the selected workspace; never bypass sandbox or approval checks.
            process.executableURL = executable
            process.arguments = ["exec", "--json", "--sandbox", "workspace-write", "--skip-git-repo-check", "--cd", request.workspace, "-"]
            process.currentDirectoryURL = URL(fileURLWithPath: request.workspace)
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(request.prompt.utf8))
            try input.fileHandleForWriting.close()
            let service = try WorkbenchService(databaseURL: request.databaseURL)
            var buffer = Data(), sawCompletion = false, failure: String?
            func consume(_ line: Data) throws {
                guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = value["type"] as? String else { return }
                switch type {
                case "thread.started":
                    guard let id = value["thread_id"] as? String, UUID(uuidString: id) != nil else { return }
                    guard receipt.sessionID == nil else { return }
                    receipt.sessionID = id
                    try service.synchronizeSession(ObservedSession(id: id, name: request.title, cwd: request.workspace), taskID: request.taskID)
                    try publish()
                case "turn.started":
                    receipt.state = .running; try publish()
                case "turn.completed": sawCompletion = true
                case "turn.failed", "error":
                    failure = (value["error"] as? [String: Any])?["message"] as? String ?? value["message"] as? String ?? "Codex 执行失败。"
                default: break
                }
            }
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    try consume(line)
                }
                // Tool output can contain very large lines; keep reading to avoid
                // back pressure without retaining their contents in this helper.
                if buffer.count > 4 * 1024 * 1024 { buffer.removeAll(keepingCapacity: false) }
            }
            if !buffer.isEmpty { try consume(buffer) }
            process.waitUntilExit()
            receipt.state = process.terminationStatus == 0 && sawCompletion && receipt.sessionID != nil ? .completed : .failed
            if receipt.state == .failed {
                receipt.message = String((failure ?? "Codex 执行未完成（退出码 \(process.terminationStatus)），请在 Codex 中检查会话及登录状态。").prefix(800))
            }
            try publish()
        } catch {
            receipt.state = .failed; receipt.message = error.localizedDescription
            try? publish()
            throw error
        }
    }
}
