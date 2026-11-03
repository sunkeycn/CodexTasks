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
    private enum WindowMode: String { case hidden, compact, normal }
    private var windowModeHistory: [String] = []
    private var lastShortcutTime: TimeInterval = -.infinity
    private var windowMode: WindowMode = .normal {
        didSet {
            // Optional local diagnostics let UI acceptance observe hidden windows without reopening them.
            if let path = argument("--window-state-output") {
                windowModeHistory.append(windowMode.rawValue)
                try? windowMode.rawValue.write(toFile: path, atomically: true, encoding: .utf8)
                try? windowModeHistory.joined(separator: "\n").write(toFile: path + ".history", atomically: true, encoding: .utf8)
            }
        }
    }
    private var normalFrame: NSRect?
    private var compactFrame: NSRect?
    private var normalContent: NSHostingView<RootView>!
    private var compactContent: NSHostingView<CompactTaskView>!
    private var sidebarWidthInitialized = false
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
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
            if smokePath != nil {
                preferences.removeObject(forKey: "lite.sidebarWidth")
                preferences.removeObject(forKey: "lite.collapsedTasks")
            }
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
        normalContent = NSHostingView(rootView: RootView(model: model))
        compactContent = NSHostingView(rootView: CompactTaskView(model: model, onOpenTask: { [weak self] task in
            self?.openTask(task)
        }))
        panel.contentView = normalContent
        panel.center()
    }
    private func configureMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), menu = NSMenu(title: "Codex Tasks")
        menu.addItem(withTitle: "打开 Codex Tasks", action: #selector(showWindow), keyEquivalent: "0").target = self
        menu.addItem(withTitle: "悬浮小窗口", action: #selector(showCompactWindow), keyEquivalent: "").target = self
        let cycleItem = menu.addItem(withTitle: "切换窗口形态", action: #selector(handleWindowShortcut), keyEquivalent: " ")
        cycleItem.keyEquivalentModifierMask = [.command, .shift]
        cycleItem.target = self
        menu.addItem(withTitle: "隐藏窗口", action: #selector(hideWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "快速记录任务", action: #selector(quickTask), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
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
        statusMenu.addItem(withTitle: "悬浮小窗口", action: #selector(showCompactWindow), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "切换窗口形态（⌘⇧空格）", action: #selector(cycleWindowMode), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "隐藏窗口", action: #selector(hideWindow), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "快速记录任务", action: #selector(quickTask), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = statusMenu
    }
    private func registerHotKey() {
        // Smoke instances must not compete with the user's installed app for the global shortcut.
        guard smokePath == nil, !CommandLine.arguments.contains("--demo") || argument("--window-state-output") != nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, info in
            guard let info else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                delegate.handleWindowShortcut()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x43544C54, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { model.errorMessage = "快捷键 ⌘⇧空格 注册失败（\(status)），可通过菜单切换窗口。" }
    }
    @objc private func handleWindowShortcut() {
        let now = ProcessInfo.processInfo.systemUptime
        // Carbon and the focused app's menu can observe the same key; advance exactly once.
        guard now - lastShortcutTime > 0.2 else { return }
        lastShortcutTime = now
        cycleWindowMode()
    }
    @objc private func cycleWindowMode() {
        guard panel.attachedSheet == nil else { return }
        switch windowMode {
        case .hidden: showCompactWindow()
        case .compact: showWindow()
        case .normal: hideWindow()
        }
    }
    private func rememberVisibleFrame() {
        switch windowMode {
        case .normal: normalFrame = panel.frame
        case .compact: compactFrame = panel.frame
        case .hidden: break
        }
    }
    @objc private func hideWindow() {
        guard panel.attachedSheet == nil else { return }
        rememberVisibleFrame()
        windowMode = .hidden
        panel.orderOut(nil)
    }
    @objc private func showCompactWindow() { presentWindow(.compact) }
    @objc func showWindow() { presentWindow(.normal) }
    private func openTask(_ task: TaskItem) {
        model.selectTask(task)
        showWindow()
    }
    private func presentWindow(_ mode: WindowMode) {
        guard panel.attachedSheet == nil || windowMode == mode else { return }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        if windowMode != mode || panel.contentView !== (mode == .compact ? compactContent : normalContent) {
            rememberVisibleFrame()
            let previousFrame = panel.frame
            windowMode = mode
            // Detach the normal host before shrinking so its minimum width cannot constrain compact mode.
            panel.contentView = nil
            panel.contentMinSize = mode == .compact ? NSSize(width: 260, height: 160) : NSSize(width: 620, height: 400)
            panel.contentMaxSize = mode == .compact ? NSSize(width: 440, height: 10000) : NSSize(width: 10000, height: 10000)
            var frame: NSRect
            if mode == .compact {
                let size = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 300, height: 400)).size
                frame = compactFrame ?? NSRect(x: previousFrame.minX, y: previousFrame.maxY - size.height, width: size.width, height: size.height)
            } else {
                frame = normalFrame ?? previousFrame
            }
            let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? panel.screen ?? NSScreen.main
            if let bounds = screen?.visibleFrame {
                frame.size.width = min(frame.width, bounds.width)
                frame.size.height = min(frame.height, bounds.height)
                frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
                frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
            }
            panel.setFrame(frame, display: false)
            panel.contentView = mode == .compact ? compactContent : normalContent
        }
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if mode == .normal, !sidebarWidthInitialized, let content = panel.contentView {
            content.layoutSubtreeIfNeeded()
            if let split = findSplitView(in: content) {
                split.setPosition(model.sidebarWidth, ofDividerAt: 0)
                sidebarWidthInitialized = true
            }
        }
    }
    private func findSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews { if let split = findSplitView(in: child) { return split } }
        return nil
    }
    @objc private func showSettings() {
        if let window = settingsWindow, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = settingsWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Tasks 设置"; window.isReleasedWhenClosed = false; window.level = .floating
        window.contentView = NSHostingView(rootView: SettingsView(model: model, onClose: { [weak window] in window?.close() }))
        settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quickTask() { showWindow(); NotificationCenter.default.post(name: .focusQuickTask, object: nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideWindow(); return false }
    func windowDidMiniaturize(_ notification: Notification) { rememberVisibleFrame(); windowMode = .hidden }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windowMode == .compact && panel.isVisible { showCompactWindow() }
        else { showWindow() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
    private func seed(_ store: TaskStore) throws {
        let first = try store.createTask(title: "任务1")
        _ = try store.createTask(title: "梳理任务交互与侧栏布局", parentID: first)
        _ = try store.createTask(title: "验证多会话关联", parentID: first)
        _ = try store.createTask(title: "优化任务与多个 Codex 会话的关联体验，并验证侧栏宽度调整与长标题的完整展示")
        try store.attach(ObservedSession(id: "00000000-0000-4000-8000-000000000001", title: "Codex Session", status: .running), to: first)
        let running = ObservedSession(id: "00000000-0000-4000-8000-000000000002", title: "Codex Session", status: .running)
        try store.attach(running, to: first)
        var completed = running; completed.status = .completed; completed.updatedAt = running.updatedAt.addingTimeInterval(1)
        try store.reconcile([completed])
    }
    private func capture(_ path: String) throws {
        guard let view = panel.contentView else { throw LiteError.message("没有可截图的窗口。") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiteError.message("无法生成窗口截图。") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LiteError.message("截图编码失败。") }
        try data.write(to: URL(fileURLWithPath: path))
    }
    private func checkWindowModes(_ checks: inout [String: Bool]) throws {
        let savedFrame = panel.frame
        let savedSidebar = model.sidebarWidth
        model.draft = "窗口切换保留草稿"
        lastShortcutTime = -.infinity
        handleWindowShortcut()
        handleWindowShortcut()
        checks["shortcutDeduplicatesSameKey"] = windowMode == .hidden
        checks["normalCyclesToHidden"] = windowMode == .hidden && !panel.isVisible
        cycleWindowMode()
        checks["hiddenCyclesToCompact"] = windowMode == .compact && panel.isVisible && panel.contentView === compactContent
        checks["compactHasOnlyTaskList"] = panel.contentView.flatMap { findSplitView(in: $0) } == nil
            && abs(panel.contentLayoutRect.width - 300) < 2
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        checks["reopenPreservesVisibleCompact"] = windowMode == .compact
        checks["compactFloatsAcrossSpaces"] = panel.level == .floating && !panel.hidesOnDeactivate
            && panel.collectionBehavior.contains(.canJoinAllSpaces)
        compactContent.layoutSubtreeIfNeeded()
        if let screenshot = argument("--compact-screenshot-output") { try capture(screenshot) }
        let compactSize = NSSize(width: 320, height: 340)
        panel.setContentSize(compactSize)
        let savedCompactFrame = panel.frame
        cycleWindowMode()
        checks["compactCyclesToNormal"] = windowMode == .normal && panel.contentView === normalContent
        checks["normalFrameRestores"] = panel.frame == savedFrame
        checks["normalSidebarWidthPreserved"] = abs(model.sidebarWidth - savedSidebar) < 2
        showCompactWindow()
        checks["compactFrameRestores"] = panel.frame == savedCompactFrame
        hideWindow(); cycleWindowMode()
        checks["hiddenReopensCompactFrame"] = panel.frame == savedCompactFrame && windowMode == .compact
        let child = model.snapshot.tasks.first { $0.parentID != nil }!
        compactContent.rootView.onOpenTask(child)
        normalContent.layoutSubtreeIfNeeded()
        checks["compactTaskOpensNormalDetail"] = windowMode == .normal && model.selectedTaskID == child.id
            && model.selectedTask?.parentID != nil && findSplitView(in: normalContent) != nil
        checks["switchPreservesDraft"] = model.draft == "窗口切换保留草稿"
        showCompactWindow(); quickTask()
        checks["quickTaskOpensNormal"] = windowMode == .normal && panel.isVisible
        _ = windowShouldClose(panel)
        checks["closeSetsHiddenState"] = windowMode == .hidden && !panel.isVisible
        cycleWindowMode()
        checks["closeThenCycleShowsCompact"] = windowMode == .compact && panel.isVisible
        showWindow()
        model.draft = ""
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
            checks["sidebarStartsAt300"] = panel.contentView.flatMap { findSplitView(in: $0)?.subviews.first?.frame.width }.map { abs($0 - 300) < 2 } ?? false
            checks["treeGroupsSeededSubtasks"] = model.snapshot.outlineTasks.prefix(3).map(\.parentID) == [nil, model.selectedTaskID, model.selectedTaskID]
            checks["taskHasTwoIndependentSessions"] = model.sessions.count == 2 && Set(model.sessions.map(\.status)).count == 2
            if let screenshot = argument("--screenshot-output") { try capture(screenshot); checks["screenshotWritten"] = FileManager.default.fileExists(atPath: screenshot) }
            let first = model.selectedTask!
            checks["completionBadgeFromRunningTransition"] = model.hasUnreadCompletion(first)
            model.selectTask(first)
            checks["selectTaskAcknowledgesCompletion"] = model.selectedTask?.hasUnreadCompletion == false
            model.toggleExpanded(first)
            checks["collapseHidesChildren"] = !model.visibleTasks.contains { $0.parentID == first.id }
            let restored = try AppModel(store: model.store, preferences: UserDefaults(suiteName: "ai.sunkey.codextasks.lite.smoke")!)
            checks["collapsedStateRestores"] = restored.collapsedTaskIDs.contains(first.id)
            model.toggleExpanded(first)
            checks["expandShowsChildren"] = model.visibleTasks.filter { $0.parentID == first.id }.count == 2
            model.rememberSidebarWidth(352)
            checks["sidebarWidthRestores"] = restored.sidebarWidth == 352
            model.rememberSidebarWidth(300)
            let seededChild = model.snapshot.children(of: first.id)[0]
            let childRun = ObservedSession(id: UUID().uuidString, title: "子任务完成提醒", status: .running)
            try model.store.attach(childRun, to: seededChild.id)
            var childDone = childRun; childDone.status = .completed; childDone.updatedAt = childRun.updatedAt.addingTimeInterval(1)
            try model.store.reconcile([childDone]); try model.refresh()
            model.toggleExpanded(first)
            checks["collapsedParentShowsUnreadChild"] = model.hasUnreadCompletion(model.selectedTask!)
            model.selectTask(first)
            checks["readingParentDoesNotClearChildBadge"] = model.hasUnreadCompletion(model.selectedTask!)
            model.selectTask(model.snapshot.children(of: first.id)[0])
            checks["selectChildExpandsParentAndReadsBadge"] = !model.collapsedTaskIDs.contains(first.id) && model.selectedTask?.hasUnreadCompletion == false
            model.selectTask(first)
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
            checks["createSubtaskSelectsChild"] = model.addSubtask(title: "子任务验收", to: created) && model.selectedTask?.parentID == created.id
            let child = model.selectedTask!
            model.status(child, .done)
            checks["childStateIndependent"] = model.snapshot.tasks.first { $0.id == created.id }?.status == .todo
            model.delete(created)
            checks["deleteParentKeepsChild"] = model.snapshot.tasks.first { $0.id == child.id }?.parentID == nil
            model.delete(child)
            checks["deleteTask"] = !model.snapshot.tasks.contains { $0.id == created.id }
            checks["otherTaskKeepsMultipleSessions"] = model.snapshot.sessions(for: first.id).count == 2
            model.status(first, .todo); model.selectedTaskID = first.id
            checks["noModelErrors"] = model.errorMessage == nil
            try checkWindowModes(&checks)
            checks.merge(try runSettingsAcceptance(directory: model.store.url.deletingLastPathComponent(), helper: model.bundledHookHelper)) { _, new in new }

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
