import Foundation
import LiteCore
import Darwin

// Never emit a prompt, response or credentials, and never block a Codex turn on integration failure.
let args = CommandLine.arguments
if let flag = args.firstIndex(of: "--events-directory"), args.indices.contains(flag + 1), args.contains("--codex-tasks-hook") {
    let data = FileHandle.standardInput.readData(ofLength: 1_048_577)
    _ = try? HookEventStore(directory: URL(fileURLWithPath: args[flag + 1], isDirectory: true)).record(data)
}
exit(0)
