import Foundation

public struct IntegrationSettings: Codable, Equatable, Sendable {
    public var codexHome: String
    public var applicationPath: String
    public var refreshInterval: Double
    public var runningTimeout: Double
    public init(codexHome: String = IntegrationSettings.defaultCodexHome.path, applicationPath: String = "", refreshInterval: Double = 60, runningTimeout: Double = 180) {
        self.codexHome = codexHome; self.applicationPath = applicationPath
        self.refreshInterval = refreshInterval; self.runningTimeout = runningTimeout
    }
    public static var defaultCodexHome: URL {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""
        return configured.hasPrefix("/") ? URL(fileURLWithPath: configured, isDirectory: true)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    public var homeURL: URL { URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL }
    public var applicationURL: URL? { applicationPath.isEmpty ? nil : URL(fileURLWithPath: (applicationPath as NSString).expandingTildeInPath) }
    public func validated() throws -> IntegrationSettings {
        let path = (codexHome.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw LiteError.message("Codex 数据目录需要使用绝对路径。") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw LiteError.message("Codex 数据目录不存在，请先启动 Codex 或选择正确目录。") }
        guard refreshInterval.isFinite, (5...600).contains(refreshInterval), runningTimeout.isFinite, (30...3600).contains(runningTimeout) else { throw LiteError.message("刷新间隔应为 5–600 秒，运行状态超时应为 30–3600 秒。") }
        let app = (applicationPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        if !app.isEmpty {
            guard app.hasPrefix("/"), app.hasSuffix(".app"), Bundle(url: URL(fileURLWithPath: app)) != nil else { throw LiteError.message("请选择有效的 Codex 应用程序（.app），也可以留空自动识别。") }
        }
        return IntegrationSettings(codexHome: URL(fileURLWithPath: path).standardizedFileURL.path, applicationPath: app, refreshInterval: refreshInterval, runningTimeout: runningTimeout)
    }
}

public struct IntegrationSettingsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> IntegrationSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return IntegrationSettings() }
        do {
            let settings = try JSONDecoder().decode(IntegrationSettings.self, from: Data(contentsOf: url))
            // Missing directories can be repaired in Settings; invalid values must not reach timers or UI conversions.
            guard settings.homeURL.path.hasPrefix("/"),
                  (settings.codexHome as NSString).expandingTildeInPath.hasPrefix("/"),
                  settings.refreshInterval.isFinite, (5...600).contains(settings.refreshInterval),
                  settings.runningTimeout.isFinite, (30...3600).contains(settings.runningTimeout) else {
                throw LiteError.message("设置值无效。")
            }
            return settings
        }
        catch { throw LiteError.message("无法读取设置文件，请保留原文件并检查格式：\(url.path)") }
    }
    public func save(_ settings: IntegrationSettings) throws {
        let validated = try settings.validated()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(validated).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum TaskAssociation {
    /// Only explicit user-message lines count; quoted text and fenced examples do not.
    public static func number(in text: String) -> Int64? {
        let pattern = #"^(?:关联任务|关联Codex[ \t]+Task)[ \t]*[【\[][ \t]*T[#-]([0-9]+)[ \t]*[】\]][ \t]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var fence: String?, number: Int64?
        for line in text.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("```") || clean.hasPrefix("~~~") {
                let marker = String(clean.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
                continue
            }
            guard fence == nil, let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
                  let range = Range(match.range(at: 1), in: clean), let parsed = Int64(clean[range]), parsed > 0 else { continue }
            number = parsed
        }
        return number
    }
}
