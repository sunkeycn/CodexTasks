import Foundation
import CryptoKit
import Darwin
import WorkbenchCore

// No stdout, model output, approval decisions, or prompts are retained.
func report() throws {
    let args = CommandLine.arguments
    func option(_ name: String, fallback: URL) -> URL {
        if let i = args.firstIndex(of: name), args.indices.contains(i + 1) { return URL(fileURLWithPath: args[i + 1]) }
        return fallback
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let directory = option("--status-directory", fallback: home.appendingPathComponent("codex-tasks-status"))
    let endpoint = option("--endpoint-file", fallback: CodexBridgeClient.defaultEndpointURL)
    var input = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
        input.append(chunk); guard input.count <= 8 * 1024 * 1024 else { return }
    }
    func isMainAgent(_ value: Any?) -> Bool {
        value == nil || value is NSNull || (value as? String)?.isEmpty == true
    }
    guard let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          isMainAgent(payload["agent_id"]), isMainAgent(payload["agent_type"]),
          let event = payload["hook_event_name"] as? String, ["UserPromptSubmit", "Stop", "Interrupt"].contains(event),
          let session = payload["session_id"] as? String, !session.isEmpty, session.utf8.count <= 4096,
          let turn = payload["turn_id"] as? String, !turn.isEmpty, turn.utf8.count <= 4096,
          let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 else { return }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let record = CodexHookStatus(sessionID: session, turnID: turn, cwd: URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path, event: event, updatedAt: formatter.string(from: Date()))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let filename = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    let lock = open(directory.appendingPathComponent("." + filename + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0 else { return }; defer { close(lock) }
    // Avoid holding a Codex lifecycle callback behind another stalled writer.
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    while flock(lock, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else { return }
        usleep(2000)
    }
    let file = directory.appendingPathComponent(filename)
    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024,
       let data = try? Data(contentsOf: file), let previous = try? JSONDecoder().decode(CodexHookStatus.self, from: data),
       previous.sessionID == session, previous.turnID == turn, ["Stop", "Interrupt"].contains(previous.event) { return }
    try JSONEncoder().encode(record).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    flock(lock, LOCK_UN)
    CodexBridgeClient.notify(CodexBridgeEvent(hook: record), endpointURL: endpoint)
}
// Telemetry failure must not fail a Codex operation.
try? report()
