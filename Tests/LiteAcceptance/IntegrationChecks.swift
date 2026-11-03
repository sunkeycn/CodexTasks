import Foundation
import LiteCore

func runIntegrationChecks(root: URL, base: Date) throws {
    let fm = FileManager.default
    let home = root.appendingPathComponent("custom codex's home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let settingsStore = IntegrationSettingsStore(url: root.appendingPathComponent("configuration/settings.json"))
    check("settings-default-follows-current-user", try settingsStore.load() == IntegrationSettings())
    let settings = IntegrationSettings(codexHome: home.path, refreshInterval: 15, runningTimeout: 60)
    try settingsStore.save(settings)
    check("settings-roundtrip-custom-home-and-timing", try settingsStore.load() == settings)
    check("settings-rejects-relative-home", try rejected { _ = try IntegrationSettings(codexHome: "relative").validated() })
    check("settings-rejects-invalid-interval", try rejected { _ = try IntegrationSettings(codexHome: home.path, refreshInterval: 0).validated() })
    check("settings-rejects-invalid-application", try rejected { _ = try IntegrationSettings(codexHome: home.path, applicationPath: home.path).validated() })
    let broken = Data("{broken".utf8)
    try broken.write(to: settingsStore.url)
    check("settings-malformed-file-not-overwritten-on-load", try rejected { _ = try settingsStore.load() } && (try Data(contentsOf: settingsStore.url)) == broken)

    let integration = root.appendingPathComponent("Application Support/Task's Integration")
    let installer = HookInstaller(home: home, integrationDirectory: integration)
    let fixture: [String: Any] = ["version": 1, "custom": ["keep": true], "hooks": [
        "Stop": [["matcher": "*", "customGroup": "preserved", "hooks": [
            ["type": "command", "command": "echo unrelated", "timeout": 8],
            ["type": "command", "command": "'/old/app/Contents/Helpers/CodexStatusHook'"]]]],
        "SessionStart": [["hooks": [["type": "command", "command": "echo other-event"]]]]
    ]]
    let original = try JSONSerialization.data(withJSONObject: fixture, options: .sortedKeys)
    try original.write(to: installer.hooksURL)
    check("hooks-detects-legacy", try installer.inspect().legacyHandlers == 1)
    let helper = root.appendingPathComponent("fixture helper")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let backup = try installer.install(helper: helper)
    check("hooks-original-backup-exact", try backup.map { try Data(contentsOf: $0) == original } == true)
    check("hooks-installs-all-events-migrates-legacy", try installer.inspect().isInstalled && installer.inspect().legacyHandlers == 0)
    let installed = try Data(contentsOf: installer.hooksURL)
    let installedRoot = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
    let allHooks = installedRoot["hooks"] as! [String: [[String: Any]]]
    check("hooks-preserves-unrelated-top-level-fields", installedRoot["version"] as? Int == 1 && (installedRoot["custom"] as? [String: Bool])?["keep"] == true)
    check("hooks-preserves-unrelated-event", allHooks["SessionStart"]?.count == 1)
    check("hooks-preserves-mixed-group-fields-and-handlers", allHooks["Stop"]?.first?["customGroup"] as? String == "preserved" && (allHooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "echo unrelated")
    let command = (allHooks["UserPromptSubmit"]!.first!["hooks"] as! [[String: Any]])[0]["command"] as! String
    check("hooks-stable-path-avoids-repo-and-app-output", command.contains(HookInstaller.quote(installer.helperURL.path)) && !command.contains("/Contents/"))
    check("hooks-posix-escaping-space-and-quote", HookInstaller.quote("a'b c") == "'a'\\''b c'")
    check("hooks-idempotent-install-no-backup-or-duplicates", try installer.install(helper: helper) == nil && Data(contentsOf: installer.hooksURL) == installed)
    let executable = Process(); executable.executableURL = URL(fileURLWithPath: "/bin/sh"); executable.arguments = ["-c", command]
    try executable.run(); executable.waitUntilExit()
    check("hooks-command-runs-with-spaces-and-quotes", executable.terminationStatus == 0)
    _ = try installer.uninstall()
    let removed = try installer.inspect()
    check("hooks-removal-only-affects-app", removed.installedEvents.isEmpty && removed.legacyHandlers == 0)
    let after = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.hooksURL)) as! [String: Any]
    check("hooks-uninstall-preserves-other-commands", (after["hooks"] as? [String: [[String: Any]]])?["Stop"]?.count == 1)
    check("hooks-idempotent-uninstall", try installer.uninstall() == nil)
    try broken.write(to: installer.hooksURL)
    check("hooks-malformed-json-unchanged", try rejected { _ = try installer.install(helper: helper) } && (try Data(contentsOf: installer.hooksURL)) == broken)
    try fm.removeItem(at: installer.hooksURL)
    let target = home.appendingPathComponent("real-hooks.json"); try original.write(to: target)
    try fm.createSymbolicLink(at: installer.hooksURL, withDestinationURL: target)
    check("hooks-refuses-symlink-without-changing-target", try rejected { _ = try installer.uninstall() } && (try Data(contentsOf: target)) == original)

    let store = try TaskStore(url: root.appendingPathComponent("hooks-tasks.sqlite"))
    let task = try store.createTask(title: "Hook task", at: base.addingTimeInterval(-1))
    let events = HookEventStore(directory: root.appendingPathComponent("events"))
    let id = UUID().uuidString.lowercased()
    func input(_ event: String, turn: String = "turn-a", session: String? = nil, extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["session_id": session ?? id, "hook_event_name": event, "turn_id": turn]
        object.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }
    let prompt = "private content never persisted\n关联任务【T#\(task)】"
    check("hooks-records-prompt-start", try events.record(input("UserPromptSubmit", extra: ["prompt": prompt, "cwd": "/private-path"]), at: base))
    let eventURL = events.directory.appendingPathComponent(id + ".json")
    let eventData = try Data(contentsOf: eventURL)
    check("hooks-never-persists-prompt-or-cwd", !String(decoding: eventData, as: UTF8.self).contains("private"))
    let initial = try events.merged(with: [], snapshot: store.snapshot(), runningTimeout: 60, at: base)
    check("hooks-index-lag-associated-session-admitted", initial.count == 1 && initial.first?.taskNumber == task && initial.first?.status == .running)
    try store.reconcile(initial)
    try store.attach(ObservedSession(id: id, title: "Retained title", status: .running, updatedAt: base), to: task, at: base)
    check("hooks-stale-time-rejected", try !events.record(input("Stop"), at: base.addingTimeInterval(-1)))
    check("hooks-cross-turn-stop-rejected", try !events.record(input("Stop", turn: "older-turn"), at: base.addingTimeInterval(1)))
    check("hooks-records-stop", try events.record(input("Stop"), at: base.addingTimeInterval(2)))
    check("hooks-late-same-turn-start-rejected", try !events.record(input("UserPromptSubmit"), at: base.addingTimeInterval(3)))
    let completed = try events.merged(with: [], snapshot: store.snapshot(), runningTimeout: 60, at: base.addingTimeInterval(3))
    check("hooks-keeps-session-title", completed.first?.title == "Retained title")
    try store.reconcile(completed)
    check("hooks-completion-reaches-task-unread-badge", try store.snapshot().tasks.first?.hasUnreadCompletion == true && store.snapshot().sessions.first?.status == .completed)
    check("hooks-next-turn-can-run", try events.record(input("UserPromptSubmit", turn: "turn-b"), at: base.addingTimeInterval(4)))
    let expired = try events.merged(with: [], snapshot: store.snapshot(), runningTimeout: 60, at: base.addingTimeInterval(100))
    check("hooks-idle-running-expires-to-unknown", expired.first?.status == .unknown)
    check("hooks-interrupt-recorded", try events.record(input("Interrupt", turn: "turn-b"), at: base.addingTimeInterval(5)))
    let interrupted = try events.merged(with: [], snapshot: store.snapshot(), runningTimeout: 60, at: base.addingTimeInterval(6))
    check("hooks-interrupt-status", interrupted.first?.status == .interrupted)
    check("hooks-subagent-cannot-change-parent", try !events.record(input("Stop", extra: ["agent_id": "subagent"]), at: base.addingTimeInterval(7)))
    check("hooks-path-traversal-session-rejected", try !events.record(input("Stop", session: "../escape"), at: base))
    check("hooks-unknown-event-rejected", try !events.record(input("OtherEvent"), at: base))
    check("hooks-oversized-input-rejected", try !events.record(Data(repeating: 32, count: 1_048_577), at: base))
    let unknownID = UUID().uuidString.lowercased()
    _ = try events.record(input("Stop", session: unknownID), at: base)
    check("hooks-unassociated-unindexed-events-not-listed", try events.merged(with: [], snapshot: store.snapshot(), runningTimeout: 60, at: base.addingTimeInterval(6)).count == 1)
    let futureID = UUID().uuidString.lowercased()
    _ = try events.record(input("UserPromptSubmit", session: futureID, extra: ["prompt": prompt]), at: base.addingTimeInterval(1000))
    check("hooks-future-events-ignored", try events.merged(with: [], snapshot: store.snapshot(), runningTimeout: 60, at: base.addingTimeInterval(6)).count == 1)
    let newer = ObservedSession(id: id, title: "Newest indexed title", status: .completed, updatedAt: base.addingTimeInterval(20))
    let mergedNewer = try events.merged(with: [newer], snapshot: store.snapshot(), runningTimeout: 60, at: base.addingTimeInterval(21))
    check("hooks-does-not-replace-newer-index-state", mergedNewer.first?.status == .completed && mergedNewer.first?.title == newer.title)
}
