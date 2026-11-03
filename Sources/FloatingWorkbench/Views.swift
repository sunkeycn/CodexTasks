import SwiftUI
import WorkbenchCore
import WorkbenchFlowUI

private let ink = Color(red: 0.15, green: 0.19, blue: 0.24)
private let accent = Color(red: 0.18, green: 0.39, blue: 0.86)
private let canvas = Color(red: 0.975, green: 0.976, blue: 0.98)
private let sidebarColor = Color(red: 0.945, green: 0.953, blue: 0.969)

struct RootView: View {
    @ObservedObject var model: AppModel
    @FocusState private var quickFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 166)
                Divider()
                VStack(spacing: 0) {
                    if let message = model.errorMessage {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(message).font(.callout).textSelection(.enabled)
                            Spacer()
                            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(12).background(Color.orange.opacity(0.09))
                        Divider()
                    }
                    Group {
                        switch model.section {
                        case .tasks: TasksView(model: model)
                        case .projects: ProjectsView(model: model)
                        case .cicd:
                            if model.isDemo { CICDView(model: model) }
                            else { FlowWorkbenchView(service: model.service, initialConnectionID: model.selectedFlowConnectionID, initialPipelineID: model.selectedFlowID).onDisappear { model.refresh() } }
                        }
                    }.id(model.activeWorkspace.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let toast = model.toast {
                        HStack {
                            Text(toast).font(.caption)
                            if model.unlinkReceipt != nil { Button("撤销解除") { model.undoUnlink() } }
                            Spacer()
                            Button { model.toast = nil; model.unlinkReceipt = nil } label: { Image(systemName: "xmark") }
                        }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 8).background(accent.opacity(0.07))
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").foregroundColor(accent).font(.title3)
                TextField("快速记录一个任务…", text: Binding(get: { model.snapshot.draft }, set: { model.saveDraft($0) }))
                    .textFieldStyle(.plain).focused($quickFocused).onSubmit { model.addQuickTask() }.accessibilityIdentifier("quick-entry")
                Text("↩ 新建").font(.caption).foregroundColor(.secondary)
                Button("添加") { model.addQuickTask() }.buttonStyle(.borderedProminent).tint(accent).disabled(model.snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 13).background(.white)
        }
        .background(canvas).preferredColorScheme(.light).tint(accent)
        .frame(minWidth: 840, minHeight: 580)
        .sheet(isPresented: $model.showWorkspaceSettings) { WorkspaceSettingsView(model: model) }
        .onChange(of: model.requestedQuickEntry) { requested in
            if requested { model.section = .tasks; quickFocused = true; model.requestedQuickEntry = false }
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarTitleView(model: model).padding(.top, 18).padding(.bottom, 10)
            Menu {
                ForEach(model.workspaces) { workspace in
                    Button { model.switchWorkspace(workspace.id) } label: {
                        if workspace.id == model.activeWorkspace.id { Label(workspace.name, systemImage: "checkmark") }
                        else { Text(workspace.name) }
                    }
                }
                Divider()
                Button("管理工作区…") { model.showWorkspaceSettings = true }
            } label: {
                HStack { Image(systemName: "square.stack.3d.up"); Text(model.activeWorkspace.name).lineLimit(1); Spacer() }
                    .font(.system(size: 13, weight: .semibold))
            }.menuStyle(.borderlessButton).help(model.activeWorkspace.directory)
            Text(model.activeWorkspace.directory.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2).textSelection(.enabled)
            Divider().padding(.vertical, 6)
            ForEach(AppModel.Section.allCases, id: \.self) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section == .tasks ? "checklist" : section == .projects ? "square.stack.3d.up" : "point.3.connected.trianglepath.dotted").frame(width: 18)
                        Text(section.rawValue).font(.system(size: 14, weight: .medium))
                        Spacer()
                        if section == .tasks { Text("\(model.snapshot.tasks.filter { !$0.isDone }.count)").font(.caption.monospacedDigit()) }
                    }.foregroundColor(model.section == section ? accent : ink.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .background(model.section == section ? .white : .clear).cornerRadius(9)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            Button { model.showWorkspaceSettings = true } label: { Label("应用设置", systemImage: "gearshape") }.buttonStyle(.plain).font(.caption).padding(12)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Circle().fill(Color.green).frame(width: 6, height: 6); Text("本地服务运行中").font(.caption) }
                Text("\(model.snapshot.activeRuns) 项执行中").font(.caption).foregroundColor(.secondary)
                Text(model.isDemo ? "Codex / 云效未接入" : model.syncStatus).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(4)
                Divider().padding(.vertical, 4)
                Text("⌘ ⇧ 空格  唤出 / 隐藏").font(.system(size: 10)).foregroundColor(.secondary)
                Text("⌘ N  快速记录").font(.system(size: 10)).foregroundColor(.secondary)
            }.padding(12)
        }.padding(.horizontal, 10).padding(.bottom, 14).background(sidebarColor)
    }
}

private struct SidebarTitleView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 18, weight: .semibold)).foregroundColor(accent)
                Text("Codex Tasks").font(.system(size: 14, weight: .semibold)).foregroundColor(ink).lineLimit(1)
            }
            Tag(text: model.isDemo ? "本地模拟" : "本机 Codex", color: model.isDemo ? .orange : accent)
        }
    }
}

struct CompactView: View {
    @ObservedObject var model: AppModel
    var expand: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(model.compactTasks.count)")
                        .font(.system(size: 32, weight: .bold, design: .rounded)).foregroundColor(ink)
                    Text(model.activeWorkspace.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.blue).lineLimit(1)
                }
                Spacer(minLength: 12)
                Button(action: expand) {
                    Image(systemName: "list.bullet").font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white).frame(width: 34, height: 34).background(Color.blue).clipShape(Circle())
                }.buttonStyle(.plain).help("展开工作台").accessibilityLabel("展开工作台")
            }.padding(.top, 18).padding(.bottom, 14)
            Divider()
            if model.compactTasks.isEmpty {
                Text("已完成所有待办事项").font(.system(size: 14)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.compactTasks) { task in
                            HStack(alignment: .top, spacing: 10) {
                                Button { model.toggle(task) } label: {
                                    Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20, weight: .light)).foregroundColor(task.isDone ? .blue : Color.secondary.opacity(0.55))
                                        .frame(width: 24, height: 24)
                                }.buttonStyle(.plain).help(task.isDone ? "标记为待办" : "标记为完成")
                                    .accessibilityLabel("\(task.isDone ? "标记为待办" : "标记为完成")：\(task.title)")
                                Button {
                                    model.openTask(task.id)
                                    expand()
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(task.title).font(.system(size: 14)).foregroundColor(ink)
                                            .multilineTextAlignment(.leading).lineLimit(2)
                                        if model.isRunning(task) {
                                            HStack(spacing: 5) {
                                                ProgressView().controlSize(.mini)
                                                Text("正在运行").font(.system(size: 11)).foregroundColor(.blue)
                                            }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
                                }.buttonStyle(.plain).help("打开任务详情")
                            }.padding(.vertical, 12)
                                .contentShape(Rectangle())
                                .onTapGesture { model.openTask(task.id); expand() }
                                .contextMenu { Button(role: .destructive) { model.deleteTask(task) } label: { Label("删除任务", systemImage: "trash") } }
                            Divider().padding(.leading, 34)
                        }
                    }
                }.padding(.top, 2)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .preferredColorScheme(.light).tint(.blue)
    }
}

private struct PromptTag: View {
    @ObservedObject var model: AppModel
    let task: WorkTask
    var body: some View {
        Button { model.copyAssociationPrompt(task) } label: {
            Text(task.displayNumber).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(accent)
                .padding(.horizontal, 6).padding(.vertical, 3).background(accent.opacity(0.08)).cornerRadius(4)
        }.buttonStyle(.plain).fixedSize().help("复制 \(task.associationPrompt)").accessibilityLabel("复制 \(task.displayNumber) 关联提示词")
    }
}

private struct TaskRunIcon: View {
    let snapshot: WorkbenchSnapshot
    let task: WorkTask
    private var runs: [CodexRun] { snapshot.runs.filter { $0.taskID == task.id } }
    private var currentRun: CodexRun? {
        let active = runs.filter { $0.state == .running }
        return (active.isEmpty ? runs : active).max { $0.updatedAt < $1.updatedAt }
    }
    private var label: String {
        guard let run = currentRun else { return "未运行" }
        return run.state.isTerminal ? "运行完成" : "运行中"
    }
    private var detail: String {
        guard let run = currentRun else { return label }
        return run.state.isException ? "\(label) · \(run.state.label)" : label
    }
    var body: some View {
        Group {
            if let run = currentRun {
                if run.state == .running {
                    ProgressView().controlSize(.mini).tint(accent)
                } else {
                    Image(systemName: run.state.isTerminal ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                        .foregroundColor(run.state.isException ? .orange : accent)
                }
            } else {
                Image(systemName: "clock").foregroundColor(.secondary)
            }
        }
        .font(.system(size: 12)).frame(width: 14, height: 14)
        .help(detail).accessibilityElement(children: .ignore).accessibilityLabel(detail)
    }
}

private struct SessionSubtitle: View {
    @ObservedObject var model: AppModel
    let task: WorkTask
    var body: some View {
        if let attachment = model.attachment(for: task) {
            Button { model.openSession(attachment) } label: {
                Text("| " + (attachment.sessionName?.isEmpty == false ? attachment.sessionName! : attachment.sessionID))
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }.buttonStyle(.plain).help("在 Codex 中打开会话").accessibilityLabel("打开关联会话")
        }
    }
}

private struct WorkspaceSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var path = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("应用设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack { Text("状态同步").font(.headline); Spacer(); Button("复制 Hooks 配置") { model.copyStatusHookConfiguration() } }
            Text("默认由本机日志变化触发同步，60 秒兜底。可选用生命周期 Hooks 主动上报开始、结束和中断；配置需在 Codex 中审核并信任。接入步骤见应用内的说明文件。")
                .font(.caption).foregroundColor(.secondary)
            Button("打开 Hooks 接入说明") { model.openStatusHookGuide() }.buttonStyle(.borderless)
            Divider()
            Text("工作区 · WorkSpace").font(.headline)
            Text("每次只在一个工作区中工作。任务、项目、执行记录与草稿分别保存，目录需手动维护。")
                .font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.workspaces) { workspace in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(workspace.name).font(.callout.bold()); if workspace.id == model.activeWorkspace.id { Tag(text: "当前", color: accent) } }
                                Text(workspace.directory).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("编辑") { editingID = workspace.id; name = workspace.name; path = workspace.directory }
                            Button("移除") { model.archiveWorkspace(workspace); if editingID == workspace.id { reset() } }.disabled(model.workspaces.count == 1)
                        }.padding(12).background(canvas).cornerRadius(8)
                    }
                }
            }.frame(maxHeight: 200)
            Text("移除只隐藏工作区，保留本地数据；重新添加相同目录即可恢复。已有数据的工作区可改名，绑定其他目录请新增。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            HStack { Text(editingID == nil ? "新增工作区" : "编辑工作区").font(.headline); Spacer(); if editingID != nil { Button("改为新增") { reset() } } }
            TextField("名称，例如 ShopLnkit", text: $name)
            HStack {
                TextField("绑定目录，例如 ~/WorkSpace/ShopLnkit", text: $path)
                Button("选目录…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { path = url.path; if name.isEmpty { name = url.lastPathComponent } }
                }
            }
            if let error = model.errorMessage { Text(error).font(.caption).foregroundColor(.orange) }
            HStack {
                Text("Codex 会话与日志由本机直接读取，无需配置关联协议提示词。")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button("保存工作区") { if model.saveWorkspace(id: editingID, name: name, path: path) { model.errorMessage = nil; reset() } }
                    .buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 570).background(canvas).preferredColorScheme(.light)
    }
    private func reset() { editingID = nil; name = ""; path = "" }
}

private struct TasksView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var filter = "全部"
    private var tasks: [WorkTask] {
        model.snapshot.tasks.filter {
            (filter == "全部" || (filter == "进行中" ? !$0.isDone : $0.isDone)) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.displayNumber.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) { Text("任务").font(.system(size: 24, weight: .bold)); Spacer(); Text("\(model.snapshot.tasks.count) 项").font(.caption).foregroundColor(.secondary) }
                HStack { Image(systemName: "magnifyingglass").foregroundColor(.secondary); TextField("搜索任务或编号", text: $search).textFieldStyle(.plain) }.padding(8).background(Color.black.opacity(0.035)).cornerRadius(7)
                Picker("筛选", selection: $filter) { ForEach(["全部", "进行中", "已完成"], id: \.self) { Text($0) } }.pickerStyle(.segmented).labelsHidden()
                ScrollView {
                    LazyVStack(spacing: 5) {
                        if tasks.isEmpty { EmptyHint(symbol: "checklist", title: "这里还很安静", detail: "在底部记录任务，按回车即可保存。") }
                        ForEach(tasks) { task in
                            TaskCard(model: model, task: task)
                        }
                    }
                }
            }.padding(18).frame(width: 282).background(.white)
            Divider()
            if let task = model.snapshot.tasks.first(where: { $0.id == model.selectedTaskID }) {
                TaskDetail(model: model, task: task).id(task.id)
            } else { EmptyHint(symbol: "rectangle.and.pencil.and.ellipsis", title: "从一个小任务开始", detail: "选择任务查看详情，或在底部快速记录。") }
        }
    }
}

private struct TaskCard: View {
    @ObservedObject var model: AppModel
    let task: WorkTask
    private var branches: [Branch] {
        model.snapshot.links.filter { $0.taskID == task.id }.compactMap { link in model.snapshot.branches.first { $0.id == link.branchID } }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CompletionCircle(done: task.isDone) { model.toggle(task) }.padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.title).font(.system(size: 13, weight: .medium)).strikethrough(task.isDone)
                        .foregroundColor(task.isDone ? .secondary : ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PromptTag(model: model, task: task)
                }
                HStack(spacing: 6) {
                    if model.attachment(for: task) != nil {
                        SessionSubtitle(model: model, task: task)
                        Spacer(minLength: 0)
                    } else {
                        Text("| 未关联会话").font(.system(size: 11)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TaskRunIcon(snapshot: model.snapshot, task: task)
                }
                Group {
                    if let branch = branches.first {
                        Text("\(model.snapshot.project(for: branch)?.name ?? "项目") · \(branch.ref)\(branches.count > 1 ? " +\(branches.count - 1)" : "")")
                            .foregroundColor(accent.opacity(0.8))
                    } else { Text("未关联项目").foregroundColor(.secondary) }
                }.font(.system(size: 10)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11).background(model.selectedTaskID == task.id ? accent.opacity(0.08) : Color.white).cornerRadius(9)
        .contentShape(Rectangle())
        .onTapGesture { model.openTask(task.id) }
        .contextMenu { Button(role: .destructive) { model.deleteTask(task) } label: { Label("删除任务", systemImage: "trash") } }
        .accessibilityIdentifier("task-card-\(task.number)")
    }
}

private struct TaskDetail: View {
    @ObservedObject var model: AppModel
    var task: WorkTask
    @State private var title = ""
    @State private var notes = ""
    @State private var baseVersion = 0
    @State private var baseTitle = ""
    @State private var baseNotes = ""
    @State private var suggestionTitle = ""
    @State private var bindResult: String?
    private var dirty: Bool { title != baseTitle || notes != baseNotes }
    private var links: [TaskBranch] { model.snapshot.links.filter { $0.taskID == task.id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Button(task.displayNumber) { model.copy(task.displayNumber) }.font(.system(size: 12, weight: .semibold, design: .monospaced)).buttonStyle(.plain).foregroundColor(accent)
                    Tag(text: task.isDone ? "已完成" : "进行中", color: task.isDone ? .green : accent)
                    Spacer()
                    CompletionCircle(done: task.isDone) { model.toggle(task) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("任务标题", text: $title).font(.system(size: 23, weight: .semibold)).textFieldStyle(.plain).accessibilityIdentifier("task-title")
                        PromptTag(model: model, task: task)
                    }
                    SessionSubtitle(model: model, task: task)
                    if let attachment = model.attachment(for: task) {
                        Button { model.openSession(attachment) } label: { Label("打开Codex", systemImage: "arrow.up.forward.app") }
                            .accessibilityIdentifier("open-codex")
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        SectionCaption(title: "Prompt", symbol: "text.alignleft")
                        Spacer()
                        if model.attachment(for: task) == nil {
                            Button { sendToCodex() } label: { Label(model.sendingTaskIDs.contains(task.id) ? "正在发送…" : "发送至Codex", systemImage: "paperplane") }
                                .disabled(model.sendingTaskIDs.contains(task.id))
                                .accessibilityIdentifier("send-to-codex")
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(task.associationPrompt)
                            .font(.system(size: 13)).textSelection(.enabled)
                            .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 2)
                            .accessibilityLabel("固定首行：" + task.associationPrompt)
                            .accessibilityIdentifier("prompt-association-header")
                        TextEditor(text: $notes)
                            .font(.system(size: 13)).scrollContentBackground(.hidden)
                            .frame(minHeight: 100, maxHeight: 220)
                            .padding(.horizontal, 6).padding(.bottom, 6)
                            .accessibilityLabel("Prompt 正文")
                            .accessibilityIdentifier("prompt-body")
                    }
                    .background(.white).cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.06)))
                    HStack {
                        Text(dirty ? "有未保存的详情修改" : "已保存在本机").font(.caption2).foregroundColor(dirty ? .orange : .secondary)
                        Spacer()
                        if dirty { Button("还原") { load() }.buttonStyle(.borderless) }
                        Button("保存详情") {
                            if model.perform({ try model.service.updateTask(id: task.id, title: title, notes: notes, acceptance: task.acceptance, expectedVersion: baseVersion) }) { load() }
                        }.disabled(!dirty)
                    }
                }
                Divider()
                branchSection
                Divider()
                if model.isDemo { suggestions }
                let flowState = (try? model.service.cicdState()) ?? CICDState()
                let flowAccounts = flowState.accounts.filter { $0.attempts.contains(where: { $0.preview.taskID == task.id }) }
                if !flowAccounts.isEmpty {
                    Divider()
                    SectionCaption(title: "相关云效实例", symbol: "point.3.connected.trianglepath.dotted")
                    ForEach(flowAccounts, id: \.connectionID) { account in
                        ForEach(account.attempts.filter { $0.preview.taskID == task.id }.reversed()) { attempt in
                            Button {
                                model.selectedFlowConnectionID = account.connectionID
                                model.selectedFlowID = attempt.preview.pipelineID
                                model.section = .cicd
                            } label: {
                                HStack {
                                    Text(attempt.preview.pipelineName)
                                    Spacer()
                                    Text(attempt.remoteID.map { "实例 #" + $0 } ?? "提交结果未知")
                                }
                            }.font(.caption).buttonStyle(.borderless).disabled(!flowState.connections.contains(where: { $0.id == account.connectionID }))
                        }
                    }
                }
                let pipelines = model.snapshot.pipelines.filter { $0.taskID == task.id }
                if !pipelines.isEmpty {
                    Divider()
                    SectionCaption(title: "相关流水线", symbol: "point.3.connected.trianglepath.dotted")
                    ForEach(pipelines.reversed()) { run in
                        Button { model.selectedPipelineID = run.id; model.section = .cicd } label: { HStack { Text(run.remoteID); Spacer(); Text("\(run.environment) · \(run.state.label)") } }.font(.caption).buttonStyle(.borderless)
                    }
                }
            }.padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).onAppear { load() }.onChange(of: task.version) { _ in if !dirty { load() } }
    }
    private func load() {
        let current = model.snapshot.tasks.first { $0.id == task.id } ?? task
        title = current.title; notes = current.editableCodexNotes()
        baseTitle = title; baseNotes = notes; baseVersion = current.version
    }
    private func sendToCodex() {
        if dirty {
            guard model.perform({ try model.service.updateTask(id: task.id, title: title, notes: notes, acceptance: task.acceptance, expectedVersion: baseVersion) }) else { return }
            load()
        }
        model.sendToCodex(task, notes: notes, title: title)
    }
    private var branchSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionCaption(title: "项目与分支", symbol: "arrow.triangle.branch")
                Spacer()
                Menu("关联分支") {
                    ForEach(model.snapshot.projects) { project in
                        Menu(project.name) {
                            ForEach(model.snapshot.branches.filter { $0.projectID == project.id }) { branch in
                                Button(branch.ref) { model.perform { try model.service.link(taskID: task.id, branchID: branch.id) } }.disabled(links.contains { $0.branchID == branch.id })
                            }
                        }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if links.isEmpty { Text("尚未关联项目。记录任务不需要先选分支。").font(.caption).foregroundColor(.secondary) }
            ForEach(model.snapshot.projects.filter { project in links.contains { link in model.snapshot.branches.contains { $0.id == link.branchID && $0.projectID == project.id } } }) { project in
                VStack(alignment: .leading, spacing: 7) {
                    Text(project.name).font(.caption.weight(.semibold)).foregroundColor(ink)
                    ForEach(links.filter { link in model.snapshot.branches.contains { $0.id == link.branchID && $0.projectID == project.id } }) { link in
                        if let branch = model.snapshot.branches.first(where: { $0.id == link.branchID }) {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "arrow.triangle.branch").font(.caption).foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(branch.ref).font(.caption).textSelection(.enabled)
                                    HStack(spacing: 5) {
                                        if task.defaultBranchID == branch.id { Tag(text: "默认入口", color: accent) }
                                        if link.isProjectDefault { Tag(text: "项目默认", color: .gray) }
                                        if branch.availability != .available { Tag(text: branch.availability.label, color: .orange) }
                                    }
                                }
                                Spacer()
                                Menu {
                                    Button("设为任务默认入口") { model.perform { try model.service.setDefaultBranch(taskID: task.id, branchID: branch.id) } }
                                    Button("设为项目内默认分支") { model.perform { try model.service.setProjectDefault(taskID: task.id, branchID: branch.id) } }
                                    if task.defaultBranchID == branch.id { Button("清空默认入口") { model.perform { try model.service.setDefaultBranch(taskID: task.id, branchID: nil) } } }
                                    Divider()
                                    Button("解除关联") { model.unlink(taskID: task.id, branchID: branch.id) }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            }.padding(9).background(.white).cornerRadius(7)
                        }
                    }
                }
            }
            Text("关联只定位上下文，不切换 Git 分支、不授予目录访问权限。").font(.system(size: 10)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                if model.attachment(for: task) == nil {
                    Button("复制关联指令") { model.copyAssociationPrompt(task) }
                    Text("在 Codex 提示词末尾独立一行粘贴，发送后自动关联当前会话及工作目录。").font(.caption).foregroundColor(.secondary)
                    Menu("手动关联现有会话") {
                        ForEach(model.sessions) { session in
                            Button(session.name.isEmpty ? session.id : session.name) { model.attachSession(session, task: task) }
                        }
                    }.disabled(model.sessions.isEmpty || model.isManualSyncing)
                }
                HStack {
                    Text(model.syncStatus).font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Button("立即同步") { model.syncNow(manual: true) }.font(.caption).disabled(model.isManualSyncing)
                }
                if let lastSync = model.lastSync { Text("最近更新：\(lastSync.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundColor(.secondary) }
            }

        }
    }
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(title: "后续建议", symbol: "lightbulb")
            HStack {
                TextField("模拟 Codex 提出一个后续事项", text: $suggestionTitle).textFieldStyle(.roundedBorder)
                Button("提出") {
                    if model.perform({ _ = try model.service.propose(taskID: task.id, title: suggestionTitle, reason: "来自本地模拟适配器，采纳后才会创建任务。", sourceRunID: model.snapshot.runs.last(where: { $0.taskID == task.id })?.id) }) { suggestionTitle = "" }
                }.disabled(suggestionTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(model.snapshot.suggestions.filter { $0.taskID == task.id }) { suggestion in
                VStack(alignment: .leading, spacing: 7) {
                    Text(suggestion.title).font(.callout)
                    Text(suggestion.reason).font(.caption).foregroundColor(.secondary)
                    if let adopted = suggestion.adoptedTaskID {
                        Button("已采纳 · 查看任务") { model.openTask(adopted) }.font(.caption).buttonStyle(.borderless)
                    } else if suggestion.isIgnored { Text("已忽略").font(.caption).foregroundColor(.secondary) }
                    else {
                        HStack {
                            Button("采纳为任务") { model.perform { let created = try model.service.adopt(suggestionID: suggestion.id); model.toast = "已创建 \(created.displayNumber)，未启动执行" } }
                            Button("忽略") { model.perform { try model.service.ignore(suggestionID: suggestion.id) } }.buttonStyle(.borderless)
                        }.font(.caption)
                    }
                }.padding(11).background(.white).cornerRadius(8)
            }
        }
    }
}

struct CompletionCircle: View {
    var done: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 21, weight: .light)).foregroundColor(done ? accent : Color.gray.opacity(0.6)) }
            .buttonStyle(.plain).accessibilityLabel(done ? "取消完成" : "标记完成").help("\(done ? "恢复进行中" : "标记完成") · 聚焦后按空格")
    }
}
private struct Tag: View {
    var text: String
    var color: Color
    var body: some View { Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(color).padding(.horizontal, 6).padding(.vertical, 3).background(color.opacity(0.09)).cornerRadius(5) }
}
private struct SectionCaption: View {
    var title: String
    var symbol: String
    var body: some View { Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(ink.opacity(0.8)) }
}
private struct EmptyHint: View {
    var symbol: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundColor(accent.opacity(0.5))
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedProjectID: UUID?
    @State private var showAll = false
    @State private var showProjectForm = false
    @State private var showBranchForm = false
    @State private var projectName = ""
    @State private var repository = ""
    @State private var branchRef = ""
    @State private var taskBranch: Branch?
    @State private var newTitle = ""
    private var project: Project? { model.snapshot.projects.first { $0.id == selectedProjectID } ?? model.snapshot.projects.first }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("项目").font(.system(size: 24, weight: .bold)); Spacer(); Button { if model.isDemo { showProjectForm = true } else { model.chooseProjectDirectory() } } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("选择项目目录") }
                Text("登记的仓库与关注分支").font(.caption).foregroundColor(.secondary)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.snapshot.projects) { item in
                            Button { selectedProjectID = item.id } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(item.name, systemImage: "folder").font(.system(size: 13, weight: .medium))
                                    let branchIDs = Set(model.snapshot.branches.filter { $0.projectID == item.id }.map(\.id))
                                    let taskIDs = Set(model.snapshot.links.filter { branchIDs.contains($0.branchID) }.map(\.taskID))
                                    Text("\(model.snapshot.branches.filter { $0.projectID == item.id && $0.isFollowed }.count) 个关注分支 · \(taskIDs.count) 个任务 · \(model.snapshot.tasks.filter { taskIDs.contains($0.id) && !$0.isDone }.count) 项进行中").font(.system(size: 10)).foregroundColor(.secondary)
                                    if let run = model.snapshot.pipelines.last(where: { $0.projectID == item.id }) { Text("流水线 · \(run.environment) · \(run.state.label)").font(.system(size: 10)).foregroundColor(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(project?.id == item.id ? accent.opacity(0.08) : canvas).cornerRadius(9)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Text("关联会话后自动登记项目，也可手动选择目录。").font(.system(size: 10)).foregroundColor(.secondary)
            }.padding(18).frame(width: 260).background(.white)
            Divider()
            if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack { Text(project.name).font(.system(size: 23, weight: .semibold)); Spacer(); Tag(text: model.isDemo ? "模拟项目" : "本地项目", color: accent) }
                        Text(model.snapshot.repositories.first { $0.id == project.repositoryID }?.identity ?? "").font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                        ForEach(model.snapshot.checkouts.filter { $0.repositoryID == project.repositoryID }) { checkout in
                            Text(checkout.path).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        HStack {
                            Text(showAll ? "全部登记分支" : "我关注的开发分支").font(.headline)
                            Spacer()
                            Toggle("显示全部", isOn: $showAll).toggleStyle(.switch).controlSize(.mini)
                            if model.isDemo { Button("添加分支") { showBranchForm = true } }
                        }
                        let branches = model.snapshot.branches.filter { $0.projectID == project.id && (showAll || $0.isFollowed) }
                        if branches.isEmpty { EmptyHint(symbol: "arrow.triangle.branch", title: "还没有关注的分支", detail: "登记分支或打开“显示全部”添加关注。") }
                        ForEach(branches) { branch in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "arrow.triangle.branch").foregroundColor(accent)
                                    Text(branch.ref).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                                    Spacer()
                                    Button { model.perform { try model.service.setFollowed(branchID: branch.id, value: !branch.isFollowed) } } label: { Image(systemName: branch.isFollowed ? "star.fill" : "star").foregroundColor(branch.isFollowed ? .orange : .secondary) }.buttonStyle(.plain).help(branch.isFollowed ? "取消关注，不解除任务关联" : "关注分支")
                                }
                                HStack { Text(String(branch.sha.prefix(12))).font(.caption.monospaced()); Spacer(); Text(branch.availability.label).font(.caption) }.foregroundColor(.secondary)
                                let linkedTasks = model.snapshot.links.filter { $0.branchID == branch.id }.compactMap { link in model.snapshot.tasks.first { $0.id == link.taskID } }
                                ForEach(linkedTasks) { task in
                                    HStack {
                                        CompletionCircle(done: task.isDone) { model.toggle(task) }
                                        Button { model.openTask(task.id) } label: { Text("\(task.displayNumber) · \(task.title)").font(.caption).strikethrough(task.isDone) }.buttonStyle(.plain)
                                        Spacer()
                                        Button { model.unlink(taskID: task.id, branchID: branch.id) } label: { Image(systemName: "link.badge.plus").rotationEffect(.degrees(45)) }.buttonStyle(.plain).help("解除关联，保留分支与历史")
                                    }
                                }
                                if linkedTasks.isEmpty { Text("暂无关联任务").font(.caption).foregroundColor(.secondary) }
                                if let run = model.snapshot.runs.last(where: { $0.branchID == branch.id }) { Text("最近执行 · \(run.state.label)").font(.caption).foregroundColor(.secondary) }
                                if let run = model.snapshot.pipelines.last(where: { $0.branchID == branch.id }) { Text("最近流水线 · \(run.environment) · \(run.state.label)").font(.caption).foregroundColor(.secondary) }
                                HStack {
                                    Menu("关联已有任务") {
                                        ForEach(model.snapshot.tasks) { task in
                                            Button("\(task.displayNumber) · \(task.title)") { model.perform { try model.service.link(taskID: task.id, branchID: branch.id) } }.disabled(linkedTasks.contains { $0.id == task.id })
                                        }
                                    }.menuStyle(.borderlessButton).fixedSize()
                                    Button("新建关联任务") { newTitle = ""; taskBranch = branch }
                                    Spacer()
                                    if model.isDemo { Menu("模拟状态") {
                                        ForEach(BranchAvailability.allCases, id: \.self) { state in Button(state.label) { model.perform { try model.service.setBranchAvailability(branchID: branch.id, value: state) } } }
                                    }.menuStyle(.borderlessButton).fixedSize() }
                                }.font(.caption)
                            }.padding(16).background(.white).cornerRadius(11).overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.black.opacity(0.04)))
                        }
                        Text("关注与任务关联分别保存。取消关注不会解除关联；分支读取未知也不会删除历史。").font(.caption).foregroundColor(.secondary)
                    }.padding(24)
                }.frame(maxWidth: .infinity)
            } else { EmptyHint(symbol: "folder.badge.plus", title: "登记第一个项目", detail: "在 Codex 中关联任务后自动出现；也可点击加号选择项目目录。") }
        }
        .sheet(isPresented: $showProjectForm) {
            FormSheet(title: "登记模拟项目", subtitle: "这里只保存身份信息，不读取仓库、不授予代码访问权限。", cancel: { showProjectForm = false }, confirm: {
                if model.perform({ let project = try model.service.createProject(name: projectName, repository: repository.isEmpty ? "mock://\(UUID().uuidString.lowercased())" : repository); selectedProjectID = project.id }) { projectName = ""; repository = ""; showProjectForm = false }
            }) {
                TextField("项目名称", text: $projectName)
                TextField("仓库身份（留空自动生成 mock:// 身份）", text: $repository)
                if let error = model.errorMessage { Text(error).font(.caption).foregroundColor(.orange) }
            }
        }
        .sheet(isPresented: $showBranchForm) {
            FormSheet(title: "登记模拟分支", subtitle: "提交 SHA 由模拟适配器生成。不会执行 Git 命令。", cancel: { showBranchForm = false }, confirm: {
                guard let project else { return }
                if model.perform({ _ = try model.service.createBranch(projectID: project.id, ref: branchRef) }) { branchRef = ""; showBranchForm = false }
            }) { TextField("例如 feature/my-task", text: $branchRef); if let error = model.errorMessage { Text(error).font(.caption).foregroundColor(.orange) } }
        }
        .sheet(item: $taskBranch) { branch in
            FormSheet(title: "新建关联任务", subtitle: branch.ref, cancel: { taskBranch = nil }, confirm: {
                if model.perform({ let task = try model.service.createTask(title: newTitle, branchID: branch.id); model.selectedTaskID = task.id }) { taskBranch = nil; newTitle = "" }
            }) { TextField("任务标题", text: $newTitle); if let error = model.errorMessage { Text(error).font(.caption).foregroundColor(.orange) } }
        }
    }
}

private struct CICDView: View {
    @ObservedObject var model: AppModel
    @State private var selectedProjectID: UUID?
    @State private var selectedBranchID: UUID?
    @State private var environment = "test"
    @State private var parameters = ""
    @State private var taskID: UUID?
    @State private var previewID: UUID?
    @State private var scopeAcknowledged = false
    private var projectID: UUID? { selectedProjectID ?? model.snapshot.projects.first?.id }
    private var branches: [Branch] { model.snapshot.branches.filter { $0.projectID == projectID } }
    private var branchID: UUID? { selectedBranchID ?? branches.first?.id }
    private var preview: DeploymentPlan? { model.snapshot.plans.first { $0.id == previewID } }
    private var linkedTasks: [WorkTask] {
        let ids = Set(model.snapshot.links.filter { $0.branchID == branchID }.map(\.taskID))
        return model.snapshot.tasks.filter { ids.contains($0.id) }
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("CI/CD").font(.system(size: 24, weight: .bold))
                        Text("按项目 · 按环境").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Tag(text: "模拟云效 · 未连接真实资源", color: .orange)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        SectionCaption(title: "单项目部署预览", symbol: "shippingbox")
                        HStack {
                            Picker("项目", selection: Binding(get: { projectID }, set: { selectedProjectID = $0; selectedBranchID = nil; taskID = nil; clearPreview() })) {
                                ForEach(model.snapshot.projects) { Text($0.name).tag(Optional($0.id)) }
                            }
                            Picker("环境", selection: $environment) { ForEach(WorkbenchService.nonProductionEnvironments, id: \.self) { Text($0).tag($0) } }.frame(width: 150)
                        }
                        Picker("分支", selection: Binding(get: { branchID }, set: { selectedBranchID = $0; taskID = nil; clearPreview() })) { ForEach(branches) { Text($0.ref).tag(Optional($0.id)) } }
                        Picker("关联任务", selection: $taskID) { Text("不关联任务").tag(Optional<UUID>.none); ForEach(linkedTasks) { Text("\($0.displayNumber) · \($0.title)").tag(Optional($0.id)) } }
                        TextField("模拟参数（只作为文本保存，不执行）", text: $parameters).textFieldStyle(.roundedBorder)
                        HStack {
                            if let branch = branches.first(where: { $0.id == branchID }) { Text("当前 SHA  \(branch.sha.prefix(12))").font(.caption.monospaced()).foregroundColor(.secondary) }
                            Spacer()
                            Button("模拟提交推进") { if let branchID { model.perform { try model.service.advanceMockBranch(branchID: branchID) } } }.font(.caption).disabled(branchID == nil)
                            Button("生成预览") {
                                guard let branchID else { return }
                                model.perform { let plan = try model.service.prepareDeployment(branchID: branchID, environment: environment, parameters: parameters, taskID: taskID); previewID = plan.id; scopeAcknowledged = false }
                            }.buttonStyle(.borderedProminent).disabled(branchID == nil)
                        }
                    }.padding(18).background(.white).cornerRadius(12)
                    if let preview { previewCard(preview) }
                    HStack { Text("运行实例").font(.headline); Spacer(); Text("保留历史结果与最后同步时间").font(.caption).foregroundColor(.secondary) }
                    let runs = model.snapshot.pipelines.filter { ($0.projectID == projectID && $0.environment == environment) || $0.id == model.selectedPipelineID }
                    if runs.isEmpty { EmptyHint(symbol: "point.3.connected.trianglepath.dotted", title: "还没有运行实例", detail: "先生成预览，再确认一次本地模拟。") }
                    ForEach(runs.reversed()) { run in
                        pipelineCard(run).id(run.id)
                    }
                    Text("当前只验证本地状态与确认逻辑。模拟成功不代表真实发布成功，也不证明服务健康。真实 CLI 适配、凭据与环境授权尚未接入。").font(.caption).foregroundColor(.secondary)
                }.padding(24)
            }.onChange(of: model.selectedPipelineID) { id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            .onAppear { if let id = model.selectedPipelineID { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } } }
        }
        .onChange(of: environment) { _ in clearPreview() }
        .onChange(of: parameters) { _ in clearPreview() }
        .onChange(of: taskID) { _ in clearPreview() }
    }
    private func clearPreview() { previewID = nil; scopeAcknowledged = false }
    private func previewCard(_ plan: DeploymentPlan) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack { Label("确认本次范围", systemImage: "doc.text.magnifyingglass").font(.headline); Spacer(); Tag(text: plan.pipelineRunID != nil ? "已提交一次" : plan.invalidatedReason != nil ? "已失效" : "待确认", color: plan.invalidatedReason != nil ? .orange : accent) }
            scopeLine("项目 / 分支", "\(plan.scope.projectName) / \(plan.scope.branchRef)")
            scopeLine("环境 / 资源", "\(plan.scope.environment) / \(plan.scope.resource)")
            scopeLine("具体动作", plan.scope.action)
            scopeLine("影响面", plan.scope.impact)
            scopeLine("固定提交", plan.scope.sha)
            scopeLine("流水线", plan.scope.pipeline)
            scopeLine("参数", plan.scope.parameters.isEmpty ? "无" : plan.scope.parameters)
            scopeLine("预览摘要", String(plan.digest.prefix(16)))
            if let reason = plan.invalidatedReason { Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange) }
            if let runID = plan.pipelineRunID { Text("已生成模拟实例 \(model.snapshot.pipelines.first { $0.id == runID }?.remoteID ?? "")。此确认不会再次触发。").font(.caption).foregroundColor(.secondary) }
            else {
                Toggle("我已核对本次范围，仅执行本地模拟", isOn: $scopeAcknowledged).font(.caption)
                HStack { Text("预览 15 分钟有效，版本或参数变化后需重新生成。").font(.system(size: 10)).foregroundColor(.secondary); Spacer(); Button("确认本地模拟") { model.perform { let run = try model.service.confirmDeployment(planID: plan.id, expectedDigest: plan.digest); model.selectedPipelineID = run.id } }.buttonStyle(.borderedProminent).disabled(!scopeAcknowledged || plan.invalidatedReason != nil) }
            }
        }.padding(18).background(accent.opacity(0.04)).cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.16)))
    }
    private func scopeLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) { Text(label).font(.caption).foregroundColor(.secondary).frame(width: 76, alignment: .leading); Text(value).font(.caption).textSelection(.enabled); Spacer(minLength: 0) }
    }
    private func pipelineCard(_ run: PipelineRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(run.remoteID).font(.system(size: 13, weight: .semibold, design: .monospaced)); Tag(text: run.environment, color: .gray); Spacer(); Tag(text: run.state.label, color: run.state == .succeeded ? .green : run.state == .running ? accent : .orange) }
            Text(run.stage).font(.callout)
            Text("SHA  \(run.sha)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).textSelection(.enabled)
            HStack {
                Text("\(run.source) · 同步于 \(run.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundColor(.secondary)
                if Date().timeIntervalSince(run.updatedAt) > 300 { Tag(text: "数据已过期", color: .orange) }
                Spacer()
            }
            if let task = model.snapshot.tasks.first(where: { $0.id == run.taskID }) { Button("\(task.displayNumber) · \(task.title)") { model.openTask(task.id) }.font(.caption).buttonStyle(.borderless) }
            if !run.state.isTerminal {
                HStack {
                    Button(run.state == .unknown ? "模拟核对成功" : "模拟成功") { model.perform { try model.service.updateMockPipeline(runID: run.id, next: .succeeded) } }
                    Button("模拟失败") { model.perform { try model.service.updateMockPipeline(runID: run.id, next: .failed) } }
                    Menu("其他状态") {
                        ForEach([PipelineState.queued, .running, .approval, .cancelled, .unknown], id: \.self) { next in Button(next.label) { model.perform { try model.service.updateMockPipeline(runID: run.id, next: next) } } }
                    }.menuStyle(.borderlessButton).fixedSize()
                }.font(.caption)
            }
        }.padding(16).background(.white).cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(model.selectedPipelineID == run.id ? accent.opacity(0.5) : Color.black.opacity(0.05)))
    }
}

private struct FormSheet<Content: View>: View {
    let title: String
    let subtitle: String
    let cancel: () -> Void
    let confirm: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(subtitle).font(.callout).foregroundColor(.secondary)
            content().textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("取消", action: cancel).keyboardShortcut(.cancelAction); Button("保存", action: confirm).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.padding(25).frame(width: 440).preferredColorScheme(.light)
    }
}
