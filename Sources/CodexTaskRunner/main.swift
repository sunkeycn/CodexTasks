import Foundation
import WorkbenchCore

// Only explicit dispatch requests reach this helper; it has no GUI or database
// startup side effects. Prompts arrive on stdin, never in process arguments.
do {
    let request = try JSONDecoder().decode(CodexDispatchRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
    try CodexDispatchRunner.run(request)
} catch {
    exit(1)
}
