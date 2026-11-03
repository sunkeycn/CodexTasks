import Foundation
import WorkbenchCore

// Local debugging commands use the same service as the app. Codex storage is read-only.
do {
    var args = Array(CommandLine.arguments.dropFirst())
    var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FloatingWorkbench/Live")
    if let i = args.firstIndex(of: "--data-directory"), args.indices.contains(i + 1) {
        directory = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...i+1)
    }
    let catalog = try WorkspaceCatalog(dataDirectory: directory)
    let reader = LocalCodexReader(allowedRoot: URL(fileURLWithPath: catalog.active.directory))
    let command = args.first ?? "help"
    if command == "sessions" {
        let sessions = try reader.read()
        for session in sessions { print("\(session.id)\t\(session.name)\t\(session.cwd)\t\(session.turns.last?.state.rawValue ?? "unknown")") }
    } else if ["create", "status", "sync", "attach"].contains(command) {
        let service = try WorkbenchService(databaseURL: catalog.databaseURL(for: catalog.active))
        switch command {
        case "create":
            let task = try service.createTask(title: args.dropFirst().joined(separator: " "))
            print("\(task.displayNumber)\t\(task.title)\n\(task.associationPrompt)")
        case "attach":
            guard args.count == 3, let number = Int(args[1].dropFirst(2)), let task = try service.snapshot().tasks.first(where: { $0.number == number }),
                  var session = try reader.read().first(where: { $0.id == args[2] }) else { throw WorkbenchError.invalid("用法：attach T#01 <session-id>；需存在的任务和范围内会话。") }
            session.workspaces = session.workspaces.map { reader.inspectWorkspace($0) }
            try service.synchronizeSession(session, taskID: task.id)
            print("已关联 \(task.displayNumber)：\(session.name)")
        case "sync":
            let state = try service.snapshot()
            let sessions = try reader.read()
            try service.markUnavailableSessions(availableIDs: Set(sessions.filter { !$0.turns.isEmpty }.map(\.id)))
            for var session in sessions where state.attachments.contains(where: { $0.sessionID == session.id }) || state.tasks.contains(where: { $0.number == session.taskNumber && (session.commandAt ?? .distantPast) >= $0.createdAt }) {
                session.workspaces = session.workspaces.map { reader.inspectWorkspace($0) }
                try service.synchronizeSession(session)
            }
            print("同步完成：\(sessions.count) 个范围内会话")
        default:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(service.snapshot()), encoding: .utf8)!)
        }
    } else { print("WorkbenchCLI [--data-directory PATH] sessions | create <标题> | attach T#01 <session-id> | sync | status") }
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
