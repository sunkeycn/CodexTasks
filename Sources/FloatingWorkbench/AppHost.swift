import AppKit
import SwiftUI
import Combine
import Carbon
import UserNotifications
import WorkbenchCore
import Darwin

final class WorkbenchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, UNUserNotificationCenterDelegate {
    private var panel: WorkbenchPanel!
    private var regularContentView: NSHostingView<RootView>?
    private var regularToolbar: NSToolbar!
    private let compactItemID = NSToolbarItem.Identifier("workbench-compact")
    private var model: AppModel!
    private var service: WorkbenchService!
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var subscriptions = Set<AnyCancellable>()
    private var seenNoticeIDs = Set<UUID>()
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var regularFrame = NSRect(x: 120, y: 120, width: 1060, height: 740)
    private var switchingLayout = false
    private var lockFD: Int32 = -1
    private var updateTerminationSource: DispatchSourceSignal?
    private var isTerminatingForUpdate = false
    private let smokePath = argument("--smoke-test-output")
    private var preferences: UserDefaults { smokePath == nil ? .standard : UserDefaults(suiteName: "ai.sunkey.floatingworkbench.smoke")! }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let dataDirectory: URL
            if let path = argument("--data-directory") { dataDirectory = URL(fileURLWithPath: path, isDirectory: true) }
            else { dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FloatingWorkbench/Live", isDirectory: true) }
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            lockFD = open(dataDirectory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw HostError.message("此数据目录已有工作台在运行。请从菜单栏打开已有窗口，或使用独立数据目录。") }
            service = try WorkbenchService(databaseURL: dataDirectory.appendingPathComponent("workbench.sqlite"))
            if smokePath != nil || CommandLine.arguments.contains("--demo") { try service.seedDemoIfEmpty() }
            model = try AppModel(service: service, preferences: preferences)
            model.isDemo = smokePath != nil || CommandLine.arguments.contains("--demo")
            if !model.isDemo { model.startLiveSync() }
            seenNoticeIDs = Set(model.snapshot.notices.map(\.id))
            // Packaging uses SIGTERM to replace this local development app without
            // an interactive quit dialog, while still running normal cleanup.
            signal(SIGTERM, SIG_IGN)
            let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            terminationSource.setEventHandler { [weak self] in
                self?.isTerminatingForUpdate = true
                NSApp.terminate(nil)
            }
            updateTerminationSource = terminationSource
            terminationSource.resume()
            configureMenu()
            configureWindow()
            configureStatusItem()
            configureHotKey()
            configureObservers()
            UNUserNotificationCenter.current().delegate = self
            model.$snapshot.sink { [weak self] snapshot in self?.handleSnapshot(snapshot) }.store(in: &subscriptions)
            showWindow()
            if let smokePath { runWindowSmokeTest(outputPath: smokePath) }
        } catch {
            if let smokePath {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "error": error.localizedDescription], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: smokePath))
                NSApp.terminate(nil)
            } else {
                let alert = NSAlert(); alert.messageText = "工作台无法打开"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
            }
        }
    }
    private func configureWindow() {
        panel = WorkbenchPanel(contentRect: regularFrame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Codex Tasks · 本机 Codex"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .normal
        panel.minSize = NSSize(width: 840, height: 580)
        panel.delegate = self
        if smokePath == nil, let frame = preferences.string(forKey: "windowFrame") {
            let saved = NSRectFromString(frame)
            if saved.width >= 840, saved.height >= 580, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) { regularFrame = saved }
        } else { panel.center(); regularFrame = panel.frame }
        panel.setFrame(regularFrame, display: false)
        model.onCompactChanged = { [weak self] compact in self?.setCompact(compact) }
        model.onHide = { [weak self] in self?.hideWindow() }
        regularToolbar = NSToolbar(identifier: "workbench-toolbar")
        regularToolbar.delegate = self
        regularToolbar.displayMode = .iconOnly
        regularToolbar.allowsUserCustomization = false
        panel.toolbarStyle = .unifiedCompact
        panel.toolbar = regularToolbar
        installRootView()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow, self.panel.attachedSheet == nil else { return event }
            if event.keyCode == 53 { self.hideWindow(); return nil }
            if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, !(self.panel.firstResponder is NSTextView), self.model.section == .tasks,
               let task = self.model.snapshot.tasks.first(where: { $0.id == self.model.selectedTaskID }) { self.model.toggle(task); return nil }
            return event
        }
    }
    private func installRootView() {
        if regularContentView == nil { regularContentView = NSHostingView(rootView: RootView(model: model)) }
        panel.contentView = regularContentView
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, compactItemID]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == compactItemID {
            item.image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: "缩小为待办窗口")
            item.label = "缩小为待办窗口"
            item.toolTip = "缩小为待办窗口（自动置顶）"
            item.target = self
            item.action = #selector(toggleCompact)
        } else { return nil }
        return item
    }
    private func setCompact(_ compact: Bool) {
        guard panel != nil else { return }
        switchingLayout = true; defer { switchingLayout = false }
        if compact {
            regularFrame = panel.frame
            panel.toolbar = nil
            panel.styleMask = [.borderless]
            panel.minSize = NSSize(width: 344, height: 344)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.contentView = NSHostingView(rootView: CompactView(model: model, expand: { [weak self] in self?.model.isCompact = false }))
            panel.setFrame(NSRect(x: regularFrame.minX, y: regularFrame.maxY - 344, width: 344, height: 344), display: true)
        } else {
            panel.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.toolbarStyle = .unifiedCompact
            panel.toolbar = regularToolbar
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.level = .normal
            panel.minSize = NSSize(width: 840, height: 580)
            installRootView()
            panel.setFrame(regularFrame, display: true)
        }
        panel.isMovableByWindowBackground = true
    }
    @objc private func toggleWindow() { panel.isVisible ? hideWindow() : showWindow() }
    @objc private func showWindow() {
        model.refresh()
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    @objc private func quickEntry() {
        if model.isCompact { model.isCompact = false }
        showWindow()
        model.requestedQuickEntry = true
    }
    @objc private func hideWindow() { saveWindowFrame(); panel.orderOut(nil) }
    @objc private func toggleCompact() { model.isCompact.toggle(); showWindow() }
    @objc private func enableNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
            if let error { DispatchQueue.main.async { self.model.errorMessage = error.localizedDescription } }
        }
    }
    @objc private func exportBackup() {
        showWindow()
        let dialog = NSSavePanel()
        dialog.nameFieldStringValue = "workbench-backup-\(Date().formatted(.iso8601.year().month().day()))-\(UUID().uuidString.prefix(4)).sqlite"
        dialog.title = "导出当前工作区 \(model.activeWorkspace.name) 的数据库备份"
        dialog.beginSheetModal(for: panel) { response in
            if response == .OK, let url = dialog.url {
                self.model.perform { try self.model.service.exportBackup(to: url); self.model.toast = "已导出当前工作区备份，含任务编号与运行历史" }
            }
        }
    }
    @objc private func showSettings() { showWindow(); model.showWorkspaceSettings = true }
    @objc private func showAbout() {
        showWindow()
        let alert = NSAlert()
        alert.messageText = "Codex Tasks V1.3.3"
        alert.informativeText = "本地任务与分支工作台\n\n默认读取本机 Codex 会话与执行日志，自动关联任务、项目和分支。可在手动维护的工作区之间切换；每个工作区绑定一个目录。云效尚未接入，不执行部署。\n\n⌘⇧空格 唤出/隐藏 · ⌘N 快速记录 · Esc 隐藏\n任务选中且不在输入框时，空格切换完成。\n\n关闭窗口保留同步与草稿。日志超过 3 分钟无更新时显示同步未知。"
        alert.beginSheetModal(for: panel)
    }
    @objc private func requestQuit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminatingForUpdate, smokePath == nil, model != nil else { return .terminateNow }
        showWindow()
        let alert = NSAlert()
        alert.messageText = "退出 Codex Tasks？"
        alert.informativeText = "任务与快速记录草稿已保存。退出后本地同步停止；未结束的执行和流水线在下次启动时标记为同步未知。\n详情中尚未点击“保存”的修改不会保存。若只想收起，请选择隐藏窗口。"
        alert.addButton(withTitle: "隐藏窗口")
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .terminateNow
        case .alertFirstButtonReturn: hideWindow(); return .terminateCancel
        default: return .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.stopLiveSync()
        saveWindowFrame()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideWindow(); return false }
    func windowDidMove(_ notification: Notification) { saveWindowFrame() }
    func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    private func saveWindowFrame() {
        guard panel != nil, model != nil, !switchingLayout, smokePath == nil else { return }
        if !model.isCompact { regularFrame = panel.frame }
        preferences.set(NSStringFromRect(regularFrame), forKey: "windowFrame")
    }
    private func configureObservers() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.model.perform { try self.model.service.recoverInterruptedRuns() }
            }
        })
    }
    private func configureMenu() {
        let mainMenu = NSMenu()
        let root = NSMenuItem(); let appMenu = NSMenu()
        addMenuItem("关于Codex Tasks", action: #selector(showAbout), to: appMenu)
        addMenuItem("应用设置…", action: #selector(showSettings), key: ",", to: appMenu)
        addMenuItem("快速记录", action: #selector(quickEntry), key: "n", to: appMenu)
        addMenuItem("隐藏窗口", action: #selector(hideWindow), key: "w", to: appMenu)
        addMenuItem("导出数据库备份…", action: #selector(exportBackup), to: appMenu)
        appMenu.addItem(.separator())
        addMenuItem("退出 Codex Tasks…", action: #selector(requestQuit), key: "q", to: appMenu)
        root.submenu = appMenu; mainMenu.addItem(root)
        let editRoot = NSMenuItem(); let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)) }
        editRoot.submenu = edit; mainMenu.addItem(editRoot); NSApp.mainMenu = mainMenu
    }
    private func addMenuItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Codex Tasks")
        statusItem.button?.toolTip = "Codex Tasks · 本机 Codex · ⌘⇧空格"
        let menu = NSMenu()
        addMenuItem("显示 Codex Tasks  ⌘⇧空格", action: #selector(showWindow), to: menu)
        addMenuItem("快速记录", action: #selector(quickEntry), to: menu)
        addMenuItem("切换待办窗口", action: #selector(toggleCompact), to: menu)
        menu.addItem(.separator())
        addMenuItem("启用异常系统提醒…", action: #selector(enableNotifications), to: menu)
        addMenuItem("导出数据库备份…", action: #selector(exportBackup), to: menu)
        addMenuItem("关于与使用说明", action: #selector(showAbout), to: menu)
        menu.addItem(.separator())
        addMenuItem("退出 Codex Tasks…", action: #selector(requestQuit), to: menu)
        statusItem.menu = menu; handleSnapshot(model.snapshot)
    }
    private func configureHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let host = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { host.toggleWindow() }; return noErr
        }, 1, &eventType, pointer, &hotKeyHandler)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x46574231, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if installed != noErr || status != noErr { model.errorMessage = "⌘⇧空格注册失败或已被占用（\(status)），可从菜单栏唤出工作台。" }
    }
    private func handleSnapshot(_ snapshot: WorkbenchSnapshot) {
        statusItem?.button?.title = snapshot.unreadCount > 0 ? " \(snapshot.unreadCount)" : ""
        let workspaceID = model.activeWorkspace.id.uuidString
        for notice in snapshot.notices where !seenNoticeIDs.contains(notice.id) {
            seenNoticeIDs.insert(notice.id)
            guard notice.isError else { continue }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else { return }
                let content = UNMutableNotificationContent()
                content.userInfo["workspaceID"] = workspaceID
                content.title = "Codex Tasks · 执行更新"; content.body = notice.message; content.sound = .default
                if let taskID = notice.taskID { content.userInfo["taskID"] = taskID.uuidString }
                if let pipelineID = notice.pipelineRunID { content.userInfo["pipelineID"] = pipelineID.uuidString }
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil))
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let workspaceID = (info["workspaceID"] as? String).flatMap(UUID.init(uuidString:))
        let taskID = (info["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let pipelineID = (info["pipelineID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let workspaceID { self.model.switchWorkspace(workspaceID); guard self.model.activeWorkspace.id == workspaceID else { completionHandler(); return } }
            if self.model.isCompact { self.model.isCompact = false }
            if let pipelineID { self.model.selectedPipelineID = pipelineID; self.model.section = .cicd }
            else if let taskID { self.model.openTask(taskID) }
            self.showWindow(); completionHandler()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }

    private func runWindowSmokeTest(outputPath: String) {
        let bridgeSmoke = BridgeSmokeTest()
        bridgeSmoke.start(directory: service.databaseURL.deletingLastPathComponent())
        model.section = .tasks
        let monitorHome = service.databaseURL.deletingLastPathComponent().appendingPathComponent("codex-monitor-test")
        try? FileManager.default.createDirectory(at: monitorHome.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let hookHome = service.databaseURL.deletingLastPathComponent().appendingPathComponent("codex-hook-monitor-test")
        try? FileManager.default.createDirectory(at: hookHome.appendingPathComponent("codex-tasks-status"), withIntermediateDirectories: true)
        var hookObserved = false
        let hookMonitor = CodexChangeMonitor(home: hookHome) { hookObserved = true }
        let noiseHome = service.databaseURL.deletingLastPathComponent().appendingPathComponent("codex-shm-monitor-test")
        let walHome = service.databaseURL.deletingLastPathComponent().appendingPathComponent("codex-wal-monitor-test")
        try? FileManager.default.createDirectory(at: noiseHome, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: walHome, withIntermediateDirectories: true)
        var noiseObserved = false
        var walObserved = false
        let noiseMonitor = CodexChangeMonitor(home: noiseHome) { noiseObserved = true }
        let walMonitor = CodexChangeMonitor(home: walHome) { walObserved = true }
        var writtenAt: Date?
        var observedAt: Date?
        let monitor = CodexChangeMonitor(home: monitorHome) {
            if writtenAt != nil && observedAt == nil { observedAt = Date() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            writtenAt = Date()
            try? Data("read lock bookkeeping".utf8).write(to: noiseHome.appendingPathComponent("state_5.sqlite-shm"))
            try? Data("committed metadata".utf8).write(to: walHome.appendingPathComponent("state_5.sqlite-wal"))
            try? Data("{}\n".utf8).write(to: monitorHome.appendingPathComponent("sessions/event.jsonl"))
            try? Data("{}".utf8).write(to: hookHome.appendingPathComponent("codex-tasks-status/test.json"), options: .atomic)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            withExtendedLifetime(monitor) {}
            withExtendedLifetime(hookMonitor) {}
            withExtendedLifetime(noiseMonitor) {}
            withExtendedLifetime(walMonitor) {}
            var checks: [String: Bool] = bridgeSmoke.checks
            let httpLatencies = bridgeSmoke.latencyMilliseconds
            bridgeSmoke.stop()
            checks["sqliteSharedMemoryDoesNotTriggerSync"] = !noiseObserved
            checks["sqliteWALStillTriggersSync"] = walObserved
            checks["sqliteMonitorMatchesOnlyDatabaseAndWAL"] = walMonitor.relevant(walHome.appendingPathComponent("state_5.sqlite").path)
                && !walMonitor.relevant(walHome.appendingPathComponent("state_5.sqlite-shm").path)
                && !walMonitor.relevant(walHome.appendingPathComponent("state_5.sqlite.backup").path)
            checks["hookFileChangeDetectedWithoutPolling"] = hookObserved
            checks["bundledCodexDispatchHelperExists"] = FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexTaskRunner").path)
            checks["bundledHookScriptAndGuideExist"] = Bundle.main.url(forResource: "codex-status-hook", withExtension: "py") != nil && Bundle.main.url(forResource: "CODEX-HOOKS", withExtension: "md") != nil
            checks["codexFileChangeDetectedWithoutPolling"] = observedAt != nil
            let monitorLatency = observedAt.flatMap { observed in writtenAt.map { observed.timeIntervalSince($0) } }
            checks["codexFileChangeDetectedWithinOneSecond"] = monitorLatency.map { $0 < 1 } ?? false
            checks["nativeWindowVisible"] = panel.isVisible && panel.contentView is NSHostingView<RootView>
            checks["canBecomeKey"] = panel.canBecomeKey
            checks["globalHotKeyRegistered"] = hotKey != nil
            checks["menuBarCreated"] = statusItem.button != nil
            checks["closeHidesWithoutDestroying"] = !windowShouldClose(panel) && !panel.isVisible
            showWindow()
            model.isCompact = true
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            checks["compactFloatsAndSurvivesDeactivate"] = panel.isVisible && panel.level == .floating && model.isPinned
            model.isCompact = false
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            checks["regularStaysVisibleOnDeactivateWithoutPinning"] = panel.isVisible && panel.level == .normal && !model.isPinned && !panel.hidesOnDeactivate
            showWindow()
            model.saveDraft("窗口验收草稿")
            model.isCompact = true
            checks["compactWindow"] = panel.frame.size == NSSize(width: 344, height: 344) && panel.contentView is NSHostingView<CompactView> && panel.toolbar == nil && !panel.styleMask.contains(.titled)
            model.isCompact = false
            checks["expandedWindow"] = panel.frame == regularFrame && panel.contentView is NSHostingView<RootView> && panel.level == .normal
            checks["nativeTitlebarContainsCompactOnly"] = panel.toolbar?.items.map(\.itemIdentifier) == [.flexibleSpace, compactItemID]
            let expectedCompactIDs = Set(model.snapshot.tasks.filter { !$0.isDone || model.isRunning($0) }.map(\.id))
            checks["compactShowsOnlyTodoOrRunning"] = Set(model.compactTasks.map(\.id)) == expectedCompactIDs
            checks["compactRunningTasksFirst"] = !zip(model.compactTasks, model.compactTasks.dropFirst()).contains { !model.isRunning($0.0) && model.isRunning($0.1) }
            hideWindow(); model.refresh()
            checks["draftSurvivesHide"] = model.snapshot.draft == "窗口验收草稿"
            checks["serviceSurvivesHide"] = (try? service.snapshot()) != nil
            model.saveDraft("原生窗口验收任务")
            model.addQuickTask()
            if let task = model.snapshot.tasks.first(where: { $0.id == model.selectedTaskID }) {
                checks["quickEntryCreatesTaskAndClearsDraft"] = task.title == "原生窗口验收任务" && model.snapshot.draft.isEmpty
                model.toggle(task)
                checks["completionThroughViewModel"] = model.snapshot.tasks.first { $0.id == task.id }?.isDone == true
                if let updated = model.snapshot.tasks.first(where: { $0.id == task.id }) { model.toggle(updated) }
                checks["reopenThroughViewModel"] = model.snapshot.tasks.first { $0.id == task.id }?.isDone == false
            }
            do {
                let task = try service.createTask(title: "调整标题栏与待办小窗口")
                let run = try service.startMockRun(taskID: task.id)
                try service.setCompleted(taskID: task.id, value: true, expectedVersion: task.version)
                model.refresh()
                checks["compactRetainsCompletedTaskWhileRunning"] = model.compactTasks.first?.id == task.id
                model.report(run, .completed)
                checks["compactRemovesCompletedTaskAfterRunEnds"] = !model.compactTasks.contains { $0.id == task.id }
                if let updated = model.snapshot.tasks.first(where: { $0.id == task.id }) { model.toggle(updated) }
            } catch {
                checks["compactRetainsCompletedTaskWhileRunning"] = false
                checks["compactRemovesCompletedTaskAfterRunEnds"] = false
            }
            do {
                let quietService = try WorkbenchService(databaseURL: service.databaseURL.deletingLastPathComponent().appendingPathComponent("quiet-ui/workbench.sqlite"))
                let quiet = try AppModel(service: quietService, preferences: preferences)
                let first = ObservedSession(id: "a", name: "谷歌卡包参数配置", cwd: quiet.activeWorkspace.directory)
                let other = ObservedSession(id: "b", name: "其它会话", cwd: quiet.activeWorkspace.directory)
                quiet.publishSyncResult([first, other], warnings: [])
                let baseline = quiet.lastSync
                var publications = 0
                let subscription = quiet.objectWillChange.sink { publications += 1 }
                for _ in 0..<20 { quiet.publishSyncResult([other, first], warnings: []) }
                checks["unchangedBackgroundSyncDoesNotPublishUI"] = publications == 0
                checks["unchangedSyncKeepsDisplayedUpdateTime"] = quiet.lastSync == baseline
                var renamed = first; renamed.name = "已更新的会话标题"
                quiet.publishSyncResult([other, renamed], warnings: [])
                checks["sessionChangesStillPublishUI"] = publications > 0 && quiet.sessions.first?.name == renamed.name
                publications = 0
                let created = try quiet.service.createTask(title: "后台任务状态变化")
                quiet.publishSyncResult([other, renamed], warnings: [])
                checks["taskChangesStillPublishUI"] = publications > 0 && quiet.snapshot.tasks.contains { $0.id == created.id }
                withExtendedLifetime(subscription) {}
            } catch {
                checks["unchangedBackgroundSyncDoesNotPublishUI"] = false
                checks["quietSyncFixtureCreated"] = false
            }
            let originalWorkspace = model.activeWorkspace
            if let task = model.snapshot.tasks.first(where: { $0.id == model.selectedTaskID }) {
                model.copyAssociationPrompt(task)
                checks["eventDrivenSyncUsesLowFrequencyFallback"] = AppModel.syncFallbackInterval == 60
                checks["associationPromptCopied"] = NSPasteboard.general.string(forType: .string) == "关联Codex Task【\(task.displayNumber)】"
                let observed = ObservedSession(id: "smoke-session", name: "卡包功能讨论", cwd: originalWorkspace.directory)
                model.perform { try model.service.synchronizeSession(observed, taskID: task.id) }
                checks["sessionDisplayNameAvailable"] = model.attachment(for: task)?.sessionName == "卡包功能讨论"
            }
            model.saveDraft("sunkey 专属草稿")
            do {
                let first = try model.service.createTask(title: "删除后选择回退")
                let second = try model.service.createTask(title: "删除其它任务")
                model.refresh(); model.selectedTaskID = first.id
                model.deleteTask(second)
                checks["deleteOtherTaskPreservesSelection"] = model.selectedTaskID == first.id && !model.snapshot.tasks.contains { $0.id == second.id }
                model.deleteTask(first)
                checks["deleteSelectedTaskRepairsSelection"] = !model.snapshot.tasks.contains { $0.id == first.id } && model.selectedTaskID != first.id && (model.selectedTaskID == nil || model.snapshot.tasks.contains { $0.id == model.selectedTaskID })
            } catch { checks["deleteSelectedTaskRepairsSelection"] = false }
            let originalState = model.snapshot
            if let shop = model.workspaces.first(where: { $0.name == "ShopLnkit" }) {
                checks["shopWorkspacePreconfigured"] = shop.directory.hasSuffix("/WorkSpace/ShopLnkit")
                model.switchWorkspace(shop.id)
                checks["workspaceSwitchClearsSelectionAndSessions"] = model.selectedTaskID == nil && model.sessions.isEmpty && model.lastSync == nil && model.unlinkReceipt == nil
                checks["workspaceStartsWithIsolatedData"] = model.snapshot.tasks.isEmpty && model.snapshot.projects.isEmpty && model.snapshot.attachments.isEmpty && model.snapshot.draft.isEmpty
                model.saveDraft("ShopLnkit 专属任务"); model.addQuickTask(); model.saveDraft("ShopLnkit 专属草稿")
                let reopened = try? AppModel(service: service, preferences: preferences)
                checks["workspaceSelectionSurvivesRestart"] = reopened?.activeWorkspace.id == shop.id && reopened?.snapshot.draft == "ShopLnkit 专属草稿"
                model.switchWorkspace(originalWorkspace.id)
                checks["workspaceRestoresPreviousData"] = model.snapshot == originalState
                model.switchWorkspace(shop.id)
                checks["workspaceRestoresOtherDraft"] = model.snapshot.draft == "ShopLnkit 专属草稿" && model.snapshot.tasks.count == 1
                model.switchWorkspace(originalWorkspace.id)
            } else { checks["shopWorkspacePreconfigured"] = false }
            model.selectedTaskID = model.snapshot.tasks.first(where: { model.attachment(for: $0) == nil })?.id
            model.toast = nil
            if let task = model.snapshot.tasks.first(where: { $0.title == "调整标题栏与待办小窗口" }) { model.startRun(task) }
            showWindow()
            let result: [String: Any] = ["passed": checks.values.allSatisfy { $0 }, "checks": checks, "fileChangeLatencySeconds": monitorLatency ?? -1, "httpHookToModelMilliseconds": httpLatencies, "platform": ProcessInfo.processInfo.operatingSystemVersionString, "note": "Real AppKit window and SwiftUI hosting; deactivate events injected, data actions driven via AppModel. Physical hotkey, multi-screen/full-screen and notifications need separate validation."]
            do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: outputPath)) } catch { NSLog("Smoke report error: %@", error.localizedDescription) }
            if let imagePath = argument("--screenshot-output") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                    captureView(path: imagePath)
                    if let linked = model.snapshot.tasks.first(where: { model.attachment(for: $0) != nil }) {
                        model.selectedTaskID = linked.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                            captureView(path: URL(fileURLWithPath: imagePath).deletingLastPathComponent().appendingPathComponent("任务详情-已关联.png").path)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in model.section = .projects }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        captureView(path: URL(fileURLWithPath: imagePath).deletingLastPathComponent().appendingPathComponent("项目视角.png").path)
                        model.section = .cicd
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                            captureView(path: URL(fileURLWithPath: imagePath).deletingLastPathComponent().appendingPathComponent("CI-CD视角.png").path)
                            model.showWorkspaceSettings = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                                captureView(path: URL(fileURLWithPath: imagePath).deletingLastPathComponent().appendingPathComponent("工作区设置.png").path, contentView: panel.attachedSheet?.contentView)
                                model.showWorkspaceSettings = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                                    model.isCompact = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                                        let directory = URL(fileURLWithPath: imagePath).deletingLastPathComponent()
                                        captureView(path: directory.appendingPathComponent("待办小窗口.png").path)
                                        model.snapshot.tasks = []
                                        model.snapshot.runs = []
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                                            captureView(path: directory.appendingPathComponent("待办小窗口-空状态.png").path)
                                            NSApp.terminate(nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else { NSApp.terminate(nil) }
        }
    }
    private func captureView(path: String, contentView: NSView? = nil) {
        guard let view = contentView ?? panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

enum HostError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }; return args[index + 1]
}
@main struct FloatingWorkbenchMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
