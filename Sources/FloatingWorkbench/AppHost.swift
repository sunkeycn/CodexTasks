import AppKit
import SwiftUI
import Combine
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
    private var normalSize = NSSize(width: 940, height: 680)
    private let presentation = WindowPresentation()
    private var content: NSHostingView<RootView>!
    private var cycleMenuItem: NSMenuItem!
    private var cycleStatusItem: NSMenuItem!
    private var registeredShortcut: WindowShortcut?
    private var shortcutPaused = false
    private var recordingObservation: AnyCancellable?
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
                preferences.removeObject(forKey: "lite.taskFilter")
            }
            if isolated { if try store.snapshot().tasks.isEmpty { try seed(store) } }
            let fixtures: [ObservedSession] = isolated ? [
                ObservedSession(id: "00000000-0000-4000-8000-000000000001", title: "Codex Session", status: .running, projectName: "Codex Tasks"),
                ObservedSession(id: "00000000-0000-4000-8000-000000000002", title: "Codex Session", status: .completed),
                ObservedSession(id: "00000000-0000-4000-8000-000000000003", title: "梳理任务交互与长标题展示"),
                ObservedSession(id: "00000000-0000-4000-8000-000000000004", title: "检查多会话关联流程")
            ] : []
            model = try AppModel(store: store, preferences: preferences, initialObservations: fixtures)
            if isolated { model.selectedTaskID = model.snapshot.tasks.first?.id }
            configureMenu(); configureWindow(); configureHotKey()
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
        panel = TaskPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Codex Tasks"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.contentMinSize = NSSize(width: 620, height: 240)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .white; panel.delegate = self
        content = NSHostingView(rootView: RootView(model: model, presentation: presentation, onToggleDetail: { [weak self] in self?.toggleDetail() }))
        panel.contentView = content
        panel.center()
    }
    private func configureMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), menu = NSMenu(title: "Codex Tasks")
        menu.addItem(withTitle: "打开 Codex Tasks", action: #selector(showWindow), keyEquivalent: "0").target = self
        menu.addItem(withTitle: "悬浮小窗口", action: #selector(showCompactWindow), keyEquivalent: "").target = self
        cycleMenuItem = menu.addItem(withTitle: "切换窗口形态", action: #selector(handleWindowShortcut), keyEquivalent: "")
        cycleMenuItem.target = self
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
        cycleStatusItem = statusMenu.addItem(withTitle: "切换窗口形态", action: #selector(cycleWindowMode), keyEquivalent: "")
        cycleStatusItem.target = self
        statusMenu.addItem(withTitle: "隐藏窗口", action: #selector(hideWindow), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "快速记录任务", action: #selector(quickTask), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = statusMenu
    }
    private var usesGlobalHotKey: Bool {
        smokePath == nil && (!CommandLine.arguments.contains("--demo") || argument("--window-state-output") != nil)
    }
    private func updateShortcutMenu(_ shortcut: WindowShortcut) {
        cycleMenuItem.keyEquivalent = shortcutPaused ? "" : shortcut.keyEquivalent
        cycleMenuItem.keyEquivalentModifierMask = shortcut.eventModifiers
        cycleStatusItem.title = "切换窗口形态（\(shortcut.label)）"
    }
    private func configureHotKey() {
        if usesGlobalHotKey {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, info in
                guard let info else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in delegate.handleWindowShortcut() }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        model.applyWindowShortcut = { [weak self] shortcut in try self?.applyShortcut(shortcut) }
        do { try applyShortcut(model.settings.windowShortcut) }
        catch { model.errorMessage = error.localizedDescription }
        recordingObservation = model.$isRecordingShortcut.dropFirst().sink { [weak self] recording in
            guard let self else { return }
            self.shortcutPaused = recording
            if recording {
                if let hotKey = self.hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
                self.cycleMenuItem.keyEquivalent = ""
            } else {
                do { try self.applyShortcut(self.model.settings.windowShortcut) }
                catch { self.model.errorMessage = error.localizedDescription }
            }
        }
    }
    private func applyShortcut(_ shortcut: WindowShortcut) throws {
        try shortcut.validate()
        if usesGlobalHotKey, !shortcutPaused, hotKey == nil || registeredShortcut != shortcut {
            var next: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                EventHotKeyID(signature: 0x43544C54, id: 1), GetApplicationEventTarget(), 0, &next)
            guard status == noErr else { throw LiteError.message("快捷键 \(shortcut.label) 无法注册，可能已被占用（\(status)）。请换一个组合。") }
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = next
        }
        registeredShortcut = shortcut
        updateShortcutMenu(shortcut)
    }
    @objc private func handleWindowShortcut() {
        let now = ProcessInfo.processInfo.systemUptime
        // Carbon and the focused app's menu can observe the same key; advance exactly once.
        guard now - lastShortcutTime > 0.2 else { return }
        lastShortcutTime = now
        cycleWindowMode()
    }
    @objc private func cycleWindowMode() {
        guard panel.attachedSheet == nil, !model.isRecordingShortcut, !presentation.isTransitioning else { return }
        switch windowMode {
        case .hidden: showCompactWindow()
        case .compact: showWindow()
        case .normal: hideWindow()
        }
    }
    private func rememberVisibleFrame() {
        if windowMode == .normal {
            normalSize = panel.frame.size
            if let width = findSplitView(in: content)?.subviews.first?.frame.width {
                model.rememberSidebarWidth(width)
            }
        }
    }
    @objc private func hideWindow() {
        guard panel.attachedSheet == nil, !presentation.isTransitioning else { return }
        rememberVisibleFrame(); windowMode = .hidden; panel.orderOut(nil)
    }
    @objc private func showCompactWindow() { presentWindow(.compact) }
    @objc func showWindow() { presentWindow(.normal) }
    private func toggleDetail() {
        presentWindow(presentation.isCompact ? .normal : .compact)
    }
    private func presentWindow(_ mode: WindowMode) {
        guard !presentation.isTransitioning, panel.attachedSheet == nil || windowMode == mode else { return }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        let compact = mode == .compact
        if presentation.isCompact != compact {
            rememberVisibleFrame()
            let previousFrame = panel.frame
            let animated = panel.isVisible && windowMode != .hidden && smokePath == nil
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            presentation.isTransitioning = true
            presentation.isCompact = compact
            windowMode = mode
            // Anchor the top-left corner while both dimensions animate between a card and the workspace.
            panel.contentAspectRatio = .zero
            panel.contentMinSize = NSSize(width: 180, height: 180)
            panel.contentMaxSize = NSSize(width: 10000, height: 10000)
            let side = min(440, max(180, model.sidebarWidth))
            var size = compact ? NSSize(width: side, height: side)
                : NSSize(width: max(620, normalSize.width), height: max(240, normalSize.height))
            let bounds = (panel.screen ?? NSScreen.main)?.visibleFrame
            if let bounds {
                if compact {
                    let fittedSide = min(side, bounds.width, bounds.height)
                    size = NSSize(width: fittedSide, height: fittedSide)
                } else {
                    size.width = min(size.width, bounds.width)
                    size.height = min(size.height, bounds.height)
                }
            }
            var frame = NSRect(x: previousFrame.minX, y: previousFrame.maxY - size.height,
                               width: size.width, height: size.height)
            if let bounds {
                frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
                frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
            }
            content.layoutSubtreeIfNeeded()
            panel.setFrame(frame, display: true, animate: animated)
            panel.contentMinSize = NSSize(width: compact ? 180 : 620, height: compact ? 180 : 240)
            panel.contentMaxSize = NSSize(width: compact ? 440 : 10000, height: compact ? 440 : 10000)
            panel.contentAspectRatio = compact ? NSSize(width: 1, height: 1) : .zero
            presentation.isTransitioning = false
            content.layoutSubtreeIfNeeded()
        } else { windowMode = mode }
        panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if !sidebarWidthInitialized {
            content.layoutSubtreeIfNeeded()
            if let split = findSplitView(in: content), !compact {
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
        try store.setTaskDetails(first, "## 目标\n完善任务详情与会话信息。\n\n- 支持 **Markdown** 描述\n- 显示会话所属项目\n\n> 编辑后自动保存，重启后保留。")
        _ = try store.createTask(title: "梳理任务交互与侧栏布局", parentID: first)
        _ = try store.createTask(title: "验证多会话关联", parentID: first)
        _ = try store.createTask(title: "优化任务与多个 Codex 会话的关联体验，并验证侧栏宽度调整与长标题的完整展示")
        try store.attach(ObservedSession(id: "00000000-0000-4000-8000-000000000001", title: "Codex Session", status: .running, projectName: "Codex Tasks"), to: first)
        let running = ObservedSession(id: "00000000-0000-4000-8000-000000000002", title: "Codex Session", status: .running, projectName: "Codex Tasks")
        try store.attach(running, to: first)
        var completed = running; completed.status = .completed; completed.updatedAt = running.updatedAt.addingTimeInterval(1)
        try store.reconcile([completed])
    }
    private func capture(_ path: String) throws {
        guard let view = panel.contentView else { throw LiteError.message("没有可截图的窗口。") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiteError.message("无法生成窗口截图。") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        compositeMarkdownSnapshots(in: view, onto: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LiteError.message("截图编码失败。") }
        try data.write(to: URL(fileURLWithPath: path))
    }
    private func checkWindowModes(_ checks: inout [String: Bool]) throws {
        let savedFrame = panel.frame
        let savedSidebar = model.sidebarWidth
        let sharedHost = panel.contentView
        let sharedList = findSplitView(in: content)?.subviews.first
        checks["unifiedTitlebar"] = panel.styleMask.contains(.fullSizeContentView) && panel.titleVisibility == .hidden
        model.draft = "窗口切换保留草稿"
        lastShortcutTime = -.infinity
        handleWindowShortcut(); handleWindowShortcut()
        checks["shortcutDeduplicatesSameKey"] = windowMode == .hidden
        checks["normalCyclesToHidden"] = windowMode == .hidden && !panel.isVisible
        cycleWindowMode()
        checks["hiddenCyclesToCompact"] = windowMode == .compact && panel.isVisible && presentation.isCompact
        checks["compactRetainsHostAndList"] = panel.contentView === sharedHost && findSplitView(in: content)?.subviews.first === sharedList
        checks["compactHidesRightPane"] = findSplitView(in: content)?.subviews.last?.isHidden == true
            && abs(panel.frame.width - savedSidebar) < 2
        checks["compactIsSquareAndShrinksVertically"] = panel.frame.width == panel.frame.height && panel.frame.height < savedFrame.height
        checks["collapsePreservesTopLeft"] = panel.frame.minX == savedFrame.minX && panel.frame.maxY == savedFrame.maxY
        checks["compactResizeKeepsSquareAspectRatio"] = panel.contentAspectRatio == NSSize(width: 1, height: 1)
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        checks["reopenPreservesVisibleCompact"] = windowMode == .compact
        checks["compactFloatsAcrossSpaces"] = panel.level == .floating && !panel.hidesOnDeactivate
        if let screenshot = argument("--compact-screenshot-output") { try capture(screenshot) }
        let first = model.snapshot.rootTasks.first!
        let collapsed = model.collapsedTaskIDs.contains(first.id)
        model.toggleExpanded(first)
        checks["compactDisclosureDoesNotExpandWindow"] = windowMode == .compact && model.collapsedTaskIDs.contains(first.id) != collapsed
        model.toggleExpanded(first)
        let child = model.snapshot.tasks.first { $0.parentID != nil }!
        model.selectTask(child)
        checks["compactTaskSelectionDoesNotExpandWindow"] = windowMode == .compact && model.selectedTaskID == child.id
        let previousStatus = child.status
        model.status(child, previousStatus == .done ? .todo : .done)
        checks["compactCompletionStaysCompact"] = windowMode == .compact
        model.status(child, previousStatus)
        model.selectTask(child)
        toggleDetail()
        checks["headerToggleExpandsRightPane"] = windowMode == .normal && !presentation.isCompact
            && findSplitView(in: content)?.subviews.last?.isHidden == false && model.selectedTaskID == child.id
        checks["expandRestoresWidthAndKeepsAnchor"] = panel.frame == savedFrame
        checks["normalSidebarWidthPreserved"] = abs(model.sidebarWidth - savedSidebar) < 2
        toggleDetail()
        checks["headerToggleCollapses"] = windowMode == .compact && panel.contentView === sharedHost
        panel.setContentSize(NSSize(width: 320, height: 320)); content.layoutSubtreeIfNeeded()
        let resizedFrame = panel.frame
        model.rememberSidebarWidth(320)
        cycleWindowMode()
        checks["expandRestoresNormalHeightAfterCompactResize"] = panel.frame.height == savedFrame.height
        checks["expandPreservesCompactTopLeft"] = panel.frame.minX == resizedFrame.minX && panel.frame.maxY == resizedFrame.maxY
        checks["normalResizeIsUnconstrained"] = panel.contentAspectRatio == .zero
        findSplitView(in: content)?.setPosition(180, ofDividerAt: 0)
        model.rememberSidebarWidth(180)
        toggleDetail()
        checks["narrowCompactMatchesActualSidebar"] = panel.frame.width == 180 && panel.frame.height == 180
        toggleDetail()
        checks["switchPreservesDraft"] = model.draft == "窗口切换保留草稿"
        showCompactWindow(); quickTask()
        checks["quickTaskOpensNormal"] = windowMode == .normal && panel.isVisible
        _ = windowShouldClose(panel)
        checks["closeSetsHiddenState"] = windowMode == .hidden && !panel.isVisible
        cycleWindowMode()
        checks["closeThenCycleShowsCompact"] = windowMode == .compact && panel.isVisible
        showWindow(); model.draft = ""
        model.rememberSidebarWidth(savedSidebar)
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
            checks.merge(runMarkdownAcceptance(in: content)) { _, new in new }
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
            checks.merge(try runTaskListAcceptance(model: model)) { _, new in new }
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
