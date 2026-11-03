import AppKit
import SwiftUI
import LiteCore

/// Invoked only by the existing isolated window acceptance runner.
@MainActor func runSettingsAcceptance(directory: URL, helper: URL) throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let fm = FileManager.default
    let root = directory.appendingPathComponent("settings-acceptance")
    let home = root.appendingPathComponent("synthetic-codex")
    let nextHome = root.appendingPathComponent("other-codex")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try fm.createDirectory(at: nextHome, withIntermediateDirectories: true)
    let settingsStore = IntegrationSettingsStore(url: root.appendingPathComponent("settings.json"))
    try settingsStore.save(IntegrationSettings(codexHome: home.path))
    let store = try TaskStore(url: root.appendingPathComponent("tasks.sqlite"))
    _ = try store.createTask(title: "设置验收任务")
    let suiteName = "ai.sunkey.codextasks.settings-test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suiteName)!
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let model = try AppModel(store: store, preferences: preferences)
    defer { model.stop() }
    model.refreshHookInspection()
    checks["settingsInitialInspection"] = model.hookInspection?.installedEvents.isEmpty == true
    var configuration = model.settings
    configuration.refreshInterval = 15; configuration.runningTimeout = 90
    checks["settingsSaveAppliesImmediately"] = model.applySettings(configuration) && model.settings == configuration
    checks["settingsSavedAcrossModelRestart"] = try AppModel(store: store, preferences: preferences).settings == configuration
    var invalid = configuration; invalid.refreshInterval = 0
    checks["settingsRejectInvalidWithoutLosingSavedValues"] = try !model.applySettings(invalid) && model.settings == configuration && (try settingsStore.load()) == configuration
    checks["settingsRecoverAfterValidationError"] = model.applySettings(configuration) && model.errorMessage == nil
    checks["settingsBundledNativeHelperExists"] = fm.isExecutableFile(atPath: helper.path)
    _ = try model.installHooks()
    checks["settingsModelInstallsAllHooks"] = model.hookInspection?.isInstalled == true
    var changedHome = configuration; changedHome.codexHome = nextHome.path
    checks["settingsOldHooksPreventDirectorySwitch"] = !model.applySettings(changedHome) && model.settings.homeURL.path == home.path
    _ = try model.removeHooks()
    checks["settingsModelRemovesOnlyItsHooks"] = model.hookInspection?.installedEvents.isEmpty == true
    checks["settingsCanSwitchDirectoryAfterRemoval"] = model.applySettings(changedHome) && model.errorMessage == nil
    checks["settingsTaskDatabaseUnchanged"] = try store.snapshot().tasks.count == 1
    checks["functionKeyUsesNativeMenuEquivalent"] = WindowShortcut(keyCode: 122, key: "F1").keyEquivalent == "\u{f704}"
    var shortcutApplied: WindowShortcut?
    model.applyWindowShortcut = { shortcutApplied = $0 }
    var custom = model.settings
    custom.windowShortcut = WindowShortcut(keyCode: 40, key: "K", command: true, shift: true)
    checks["shortcutSaveAppliesImmediately"] = model.applySettings(custom) && shortcutApplied == custom.windowShortcut
    checks["shortcutSurvivesRestart"] = try AppModel(store: store, preferences: preferences).settings.windowShortcut == custom.windowShortcut
    model.applyWindowShortcut = { _ in throw LiteError.message("模拟快捷键占用") }
    var conflict = custom; conflict.windowShortcut = WindowShortcut(keyCode: 37, key: "L")
    checks["shortcutConflictKeepsPreviousSettings"] = try !model.applySettings(conflict) && model.settings == custom && settingsStore.load() == custom
    model.applyWindowShortcut = { _ in }
    checks["shortcutRecoversAfterConflict"] = model.applySettings(custom)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = NSHostingView(rootView: SettingsView(model: model, onClose: {}))
    window.contentView = view; view.frame = NSRect(x: 0, y: 0, width: 600, height: 620)
    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    checks["settingsNativeViewFitsWindow"] = view.fittingSize.width == 600 && view.fittingSize.height == 620
    if let path = argument("--settings-screenshot-output"), let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: path)) }
    }
    window.close()
    try Data("{broken".utf8).write(to: settingsStore.url)
    let recovered = try AppModel(store: store, preferences: preferences)
    checks["settingsMalformedFileKeepsTasksAccessible"] = try recovered.snapshot.tasks.count == 1 && recovered.errorMessage != nil && (try Data(contentsOf: settingsStore.url)) == Data("{broken".utf8)
    recovered.stop()
    checks["settingsMenuHasShortcut"] = NSApp.mainMenu?.items.first?.submenu?.items.contains { $0.title == "设置…" && $0.keyEquivalent == "," } == true
    return checks
}
