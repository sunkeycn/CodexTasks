import Foundation
import Darwin

public struct HookInspection: Sendable {
    public let installedEvents: [String]
    public let legacyHandlers: Int
    public var isInstalled: Bool { Set(installedEvents) == Set(HookInstaller.events) }
}

/// Only this app's handlers are edited; other hooks and unknown JSON fields are preserved.
public struct HookInstaller: Sendable {
    public static let events = ["UserPromptSubmit", "Stop", "Interrupt"]
    public let home: URL
    public let integrationDirectory: URL
    public var eventDirectory: URL { integrationDirectory.appendingPathComponent("events", isDirectory: true) }
    public var helperURL: URL { integrationDirectory.appendingPathComponent("CodexTasksHook") }
    public var hooksURL: URL { home.appendingPathComponent("hooks.json") }
    public init(home: URL, integrationDirectory: URL) { self.home = home; self.integrationDirectory = integrationDirectory }
    private func isOwned(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains(" --codex-tasks-hook ") || command.hasSuffix(" --codex-tasks-hook")
    }
    private func isLegacy(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains("/Contents/Helpers/CodexStatusHook") || command.contains("/floating-dev-workbench-v1/scripts/codex-status-hook.py")
    }
    private func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: hooksURL.path) else { return [:] }
        let values = try hooksURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 4 * 1024 * 1024 else { throw LiteError.message("hooks.json 是符号链接或文件过大，已保留原文件，请手动检查。") }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any] else { throw LiteError.message("hooks.json 格式无效，未做更改。") }
        if let hooks = root["hooks"] {
            guard let dictionary = hooks as? [String: Any], dictionary.values.allSatisfy({ value in
                guard let groups = value as? [[String: Any]] else { return false }
                return groups.allSatisfy { $0["hooks"] is [[String: Any]] }
            }) else { throw LiteError.message("hooks.json 的 hooks 结构不受支持，未做更改。") }
        }
        return root
    }
    public func inspect() throws -> HookInspection {
        let root = try read(), hooks = root["hooks"] as? [String: [[String: Any]]] ?? [:]
        var installed: [String] = [], legacy = 0
        for (event, groups) in hooks {
            let handlers = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            if handlers.contains(where: isOwned) { installed.append(event) }
            legacy += handlers.filter(isLegacy).count
        }
        return HookInspection(installedEvents: installed, legacyHandlers: legacy)
    }
    @discardableResult public func install(helper source: URL) throws -> URL? {
        guard FileManager.default.isExecutableFile(atPath: source.path) else { throw LiteError.message("应用包缺少 Hooks 助手，请重新下载完整应用。") }
        try FileManager.default.createDirectory(at: integrationDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Validate hooks before touching the installed helper.
        _ = try read()
        let temporary = integrationDirectory.appendingPathComponent(".helper-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        guard rename(temporary.path, helperURL.path) == 0 else { throw LiteError.message("无法更新 Hooks 助手。") }
        let command = Self.quote(helperURL.path) + " --events-directory " + Self.quote(eventDirectory.path) + " --codex-tasks-hook"
        return try update(command: command)
    }
    @discardableResult public func uninstall() throws -> URL? { try update(command: nil) }
    private func update(command: String?) throws -> URL? {
        guard FileManager.default.fileExists(atPath: home.path) else { throw LiteError.message("Codex 数据目录不存在。") }
        let lockURL = home.appendingPathComponent(".codex-tasks-hooks.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LiteError.message("无法锁定 Hooks 配置。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw LiteError.message("Hooks 配置正在更新，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        var root = try read()
        var hooks = root["hooks"] as? [String: [[String: Any]]] ?? [:]
        for event in Array(hooks.keys) {
            hooks[event] = hooks[event]!.compactMap { group in
                var group = group
                let original = group["hooks"] as? [[String: Any]] ?? []
                let remaining = original.filter { !isOwned($0) && !isLegacy($0) }
                if remaining.count == original.count { return group }
                guard !remaining.isEmpty else { return nil }
                group["hooks"] = remaining
                return group
            }
            if hooks[event]?.isEmpty == true { hooks.removeValue(forKey: event) }
        }
        if let command {
            for event in Self.events {
                hooks[event, default: []].append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
            }
        }
        root["hooks"] = hooks
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let original = try? Data(contentsOf: hooksURL)
        if let original, let parsed = try? JSONSerialization.jsonObject(with: original) as? NSDictionary, parsed == root as NSDictionary { return nil }
        if original == nil && command == nil { return nil }
        var backup: URL?
        if let original {
            let url = home.appendingPathComponent("hooks.json.codex-tasks-backup-" + UUID().uuidString)
            try original.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            backup = url
        }
        try output.write(to: hooksURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooksURL.path)
        return backup
    }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
