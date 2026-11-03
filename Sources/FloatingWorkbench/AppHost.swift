import AppKit
import SwiftUI
import Carbon
import LiteCore
import Darwin

final class TaskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: TaskPanel!
    private var sidebarWidthInitialized = false
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var terminationSource: DispatchSourceSignal?
    private var lockFD: Int32 = -1
    private let smokePath = argument("--smoke-test-output")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = argument("--data-directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexTasks/Lite", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            lockFD = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw LiteError.message("此数据目录已有 Codex Tasks 在运行。请从菜单栏打开现有窗口。") }
            let store = try TaskStore(url: directory.appendingPathComponent("tasks.sqlite"))
            let isolated = smokePath != nil || CommandLine.arguments.contains("--demo")
            let preferences = isolated ? UserDefaults(suiteName: "ai.sunkey.codextasks.lite.smoke")! : .standard
            if isolated { if try store.snapshot().tasks.isEmpty { try seed(store) } }
            let fixtures: [ObservedSession] = isolated ? [
                ObservedSession(id: "00000000-0000-4000-8000-000000000001", title: "Codex Session", status: .running),
                ObservedSession(id: "00000000-0000-4000-8000-000000000002", title: "Codex Session", status: .completed),
                ObservedSession(id: "00000000-0000-4000-8000-000000000003", title: "梳理任务交互与长标题展示"),
                ObservedSession(id: "00000000-0000-4000-8000-000000000004", title: "检查多会话关联流程")
            ] : []
            model = try AppModel(store: store, preferences: preferences, initialObservations: fixtures)
            if isolated { model.selectedTaskID = model.snapshot.tasks.first?.id }
            configureMenu(); configureWindow(); registerHotKey()
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); terminationSource = source
            if !isolated { model.start() }
            showWindow()
            if let smokePath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in runSmoke(path: smokePath) }
            }
        } catch {
            if let smokePath {
                let result: [String: Any] = ["passed": false, "error": error.localizedDescription]
                try? JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: smokePath))
            } else {
                let alert = NSAlert(); alert.messageText = "Codex Tasks 无法启动"; alert.informativeText = error.localizedDescription; alert.runModal()
            }
            NSApp.terminate(nil)
        }
    }
    private func configureWindow() {
        panel = TaskPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "Codex Tasks"
        panel.contentMinSize = NSSize(width: 620, height: 400)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .white; panel.delegate = self
        panel.contentView = NSHostingView(rootView: RootView(model: model))
        panel.center()
    }
    private func configureMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), menu = NSMenu(title: "Codex Tasks")
        menu.addItem(withTitle: "打开 Codex Tasks", action: #selector(showWindow), keyEquivalent: "0").target = self
        menu.addItem(withTitle: "快速记录任务", action: #selector(quickTask), keyEquivalent: "n").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex Tasks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = menu; main.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Codex Tasks")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "打开 Codex Tasks", action: #selector(showWindow), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "快速记录任务", action: #selector(quickTask), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = statusMenu
    }
    private func registerHotKey() {
        // Smoke instances must not compete with the user's installed app for the global shortcut.
        guard smokePath == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, info in
            guard let info else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                if delegate.panel.isVisible && delegate.panel.isKeyWindow { delegate.panel.orderOut(nil) }
                else { delegate.showWindow() }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x43544C54, id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }
    @objc func showWindow() {
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !sidebarWidthInitialized, let content = panel.contentView {
            content.layoutSubtreeIfNeeded()
            if let split = findSplitView(in: content) {
                split.setPosition(260, ofDividerAt: 0)
                sidebarWidthInitialized = true
            }
        }
    }
    private func findSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews { if let split = findSplitView(in: child) { return split } }
        return nil
    }
    @objc private func quickTask() { showWindow(); NotificationCenter.default.post(name: .focusQuickTask, object: nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { panel.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
    private func seed(_ store: TaskStore) throws {
        let first = try store.createTask(title: "任务1")
        _ = try store.createTask(title: "优化任务与多个 Codex 会话的关联体验，并验证侧栏宽度调整与长标题的完整展示")
        try store.attach(ObservedSession(id: "00000000-0000-4000-8000-000000000001", title: "Codex Session", status: .running), to: first)
        try store.attach(ObservedSession(id: "00000000-0000-4000-8000-000000000002", title: "Codex Session", status: .completed), to: first)
    }
    private func capture(_ path: String) throws {
        guard let view = panel.contentView else { throw LiteError.message("没有可截图的窗口。") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiteError.message("无法生成窗口截图。") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LiteError.message("截图编码失败。") }
        try data.write(to: URL(fileURLWithPath: path))
    }
    private func runSmoke(path: String) {
        var checks: [String: Bool] = [:]
        let clipboard = NSPasteboard.general.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        func restoreClipboard() {
            NSPasteboard.general.clearContents()
            let items = clipboard.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            NSPasteboard.general.writeObjects(items)
        }
        do {
            checks["nativeWindowVisible"] = panel.isVisible && panel.contentView is NSHostingView<RootView>
            checks["windowHasNoToolbar"] = panel.toolbar == nil
            checks["taskHasTwoIndependentSessions"] = model.sessions.count == 2 && Set(model.sessions.map(\.status)).count == 2
            if let screenshot = argument("--screenshot-output") { try capture(screenshot); checks["screenshotWritten"] = FileManager.default.fileExists(atPath: screenshot) }
            let first = model.selectedTask!
            model.status(first, .doing)
            checks["manualTaskState"] = model.selectedTask?.status == .doing
            model.copyPrompt(first)
            checks["copyAssociation"] = NSPasteboard.general.string(forType: .string) == "关联任务【T#01】"
            model.rename(first, "改名任务")
            checks["renameTask"] = model.selectedTask?.title == "改名任务"
            model.rename(first, "任务1")
            model.draft = "快速记录验收"; model.addTask()
            checks["quickAddSelectsAndClearsDraft"] = model.selectedTask?.title == "快速记录验收" && model.draft.isEmpty
            let created = model.selectedTask!
            model.attach(ObservedSession(id: UUID().uuidString, title: "新增会话"), to: created)
            checks["attachSession"] = model.sessions.count == 1
            model.detach(model.sessions[0])
            checks["detachSession"] = model.sessions.isEmpty
            model.delete(created)
            checks["deleteTask"] = !model.snapshot.tasks.contains { $0.id == created.id }
            checks["otherTaskKeepsMultipleSessions"] = model.snapshot.sessions(for: first.id).count == 2
            model.status(first, .todo); model.selectedTaskID = first.id
            checks["noModelErrors"] = model.errorMessage == nil
        } catch { checks["smokeCompleted"] = false; model.errorMessage = error.localizedDescription }
        let report: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "error": model.errorMessage ?? "", "note": "Real AppKit/SwiftUI window; model actions and native render verified. Codex external navigation and physical hotkey require interactive verification."]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        restoreClipboard()
        NSApp.terminate(nil)
    }
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

@main struct FloatingWorkbenchMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
