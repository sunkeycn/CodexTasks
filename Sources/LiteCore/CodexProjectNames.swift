import Foundation

/// Resolves display names from Codex metadata only; never opens a workspace directory.
struct CodexProjectNames {
    private let projects: [String: [String: Any]]
    private let assignments: [String: [String: Any]]
    private let projectless: Set<String>

    init(home: URL) {
        let url = home.appendingPathComponent(".codex-global-state.json")
        let object = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        projects = object["local-projects"] as? [String: [String: Any]] ?? [:]
        assignments = object["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
        projectless = Set(object["projectless-thread-ids"] as? [String] ?? [])
    }

    func name(for sessionID: String, cwd: String) -> String {
        if let assignment = assignments[sessionID], let id = assignment["projectId"] as? String,
           let name = projects[id]?["name"] as? String, !name.isEmpty { return name }
        if projectless.contains(sessionID) { return "" }
        guard !cwd.isEmpty else { return "" }
        // String path comparison deliberately avoids resolving symlinks or reading repositories.
        let path = (cwd as NSString).standardizingPath
        var best: (length: Int, name: String)?
        for project in projects.values {
            guard let name = project["name"] as? String, !name.isEmpty else { continue }
            for root in project["rootPaths"] as? [String] ?? [] {
                let normalized = (root as NSString).standardizingPath
                if path == normalized || path.hasPrefix(normalized == "/" ? "/" : normalized + "/") {
                    if normalized.count > (best?.length ?? -1) { best = (normalized.count, name) }
                }
            }
        }
        return best?.name ?? (path as NSString).lastPathComponent
    }
}
