import Foundation

public struct WorkSpace: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var directory: String
    public var isArchived = false
}

/// Each manually maintained workspace owns its database. The original database stays in place.
public final class WorkspaceCatalog {
    private struct State: Codable {
        var version = 1
        var legacyID: UUID
        var activeID: UUID
        var workspaces: [WorkSpace]
    }
    private let directory: URL
    private let url: URL
    private var state: State
    public var workspaces: [WorkSpace] { state.workspaces.filter { !$0.isArchived } }
    public var active: WorkSpace { workspaces.first { $0.id == state.activeID }! }

    public init(dataDirectory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        directory = dataDirectory
        url = dataDirectory.appendingPathComponent("workspaces.json")
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard state.version == 1, !state.workspaces.isEmpty,
                  Set(state.workspaces.map(\.id)).count == state.workspaces.count,
                  state.workspaces.contains(where: { $0.id == state.legacyID }),
                  state.workspaces.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.directory.hasPrefix("/") && $0.directory != "/" }),
                  state.workspaces.contains(where: { $0.id == state.activeID && !$0.isArchived }) else {
                throw WorkbenchError.persistence("工作区配置无法解析，请保留 workspaces.json 并检查其版本与内容。")
            }
        } else {
            let legacy = WorkSpace(id: UUID(), name: "sunkey", directory: Self.canonical(home.appendingPathComponent("WorkSpace/sunkey").path))
            let shop = WorkSpace(id: UUID(), name: "ShopLnkit", directory: Self.canonical(home.appendingPathComponent("WorkSpace/ShopLnkit").path))
            state = State(legacyID: legacy.id, activeID: legacy.id, workspaces: [legacy, shop])
            try persist(state)
        }
    }
    public func databaseURL(for workspace: WorkSpace) -> URL {
        if workspace.id == state.legacyID { return directory.appendingPathComponent("workbench.sqlite") }
        return directory.appendingPathComponent("workspaces/\(workspace.id.uuidString)/workbench.sqlite")
    }
    public func select(_ id: UUID) throws {
        guard workspaces.contains(where: { $0.id == id }) else { throw WorkbenchError.missing("工作区不存在。") }
        var next = state; next.activeID = id
        try persist(next); state = next
    }
    @discardableResult public func save(id: UUID? = nil, name: String, directory path: String) throws -> WorkSpace {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !name.isEmpty, expanded.hasPrefix("/"), expanded != "/" else { throw WorkbenchError.invalid("请输入工作区名称和绝对目录。") }
        let canonical = Self.canonical(expanded)
        guard canonical != "/" else { throw WorkbenchError.invalid("不能把根目录设为工作区。") }
        let restored = state.workspaces.first { $0.isArchived && $0.directory == canonical }
        let targetID = id ?? restored?.id ?? UUID()
        guard !workspaces.contains(where: { $0.id != targetID && ($0.directory == canonical || $0.directory.hasPrefix(canonical + "/") || canonical.hasPrefix($0.directory + "/")) }) else {
            throw WorkbenchError.conflict("工作区目录不能重复或相互包含，以免同一个会话关联到两个工作区。")
        }
        if let old = state.workspaces.first(where: { $0.id == targetID }), old.directory != canonical {
            let snapshot = try WorkbenchService(databaseURL: databaseURL(for: old)).snapshot()
            guard snapshot.tasks.isEmpty, snapshot.projects.isEmpty, snapshot.draft.isEmpty else {
                throw WorkbenchError.conflict("这个工作区已有数据，可以改名；要绑定其他目录，请新增工作区。")
            }
        }
        let workspace = WorkSpace(id: targetID, name: name, directory: canonical)
        var next = state
        if let index = next.workspaces.firstIndex(where: { $0.id == targetID }) { next.workspaces[index] = workspace }
        else { next.workspaces.append(workspace) }
        try persist(next); state = next
        return workspace
    }
    public func archive(_ id: UUID) throws {
        guard workspaces.count > 1, let index = state.workspaces.firstIndex(where: { $0.id == id && !$0.isArchived }) else {
            throw WorkbenchError.invalid("至少保留一个工作区。")
        }
        var next = state; next.workspaces[index].isArchived = true
        if next.activeID == id { next.activeID = next.workspaces.first { !$0.isArchived }!.id }
        try persist(next); state = next
    }
    private func persist(_ next: State) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
    }
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
