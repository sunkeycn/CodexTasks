import SwiftUI
import AppKit
import LiteCore

private let ink = Color(red: 0.95, green: 0.08, blue: 0.09)
private let lineWidth: CGFloat = 1

struct RootView: View {
    @ObservedObject var model: AppModel
    @FocusState private var quickFocused: Bool
    @State private var deleting: TaskItem?
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                taskList.frame(width: 200)
                taskDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = model.errorMessage {
                HStack(alignment: .top) {
                    Text(message).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.help("关闭提示")
                }.padding(8).border(ink, width: lineWidth)
            }
            HStack(spacing: 10) {
                TextField("", text: $model.draft)
                    .textFieldStyle(.plain).focused($quickFocused).onSubmit { model.addTask() }
                    .overlay(alignment: .leading) {
                        if model.draft.isEmpty { Text("快速记录一个任务").foregroundColor(ink).allowsHitTesting(false) }
                    }
                    .accessibilityLabel("快速记录一个任务").accessibilityIdentifier("quick-task-input")
                if !model.draft.isEmpty {
                    Button { model.addTask(); quickFocused = true } label: { Image(systemName: "return") }
                        .help("创建任务并复制关联指令（回车）").accessibilityLabel("创建任务")
                }
            }
            .padding(.horizontal, 16).frame(height: 34).border(ink, width: lineWidth)
        }
        .padding(12).foregroundColor(ink).background(Color.white)
        .font(.system(size: 13)).buttonStyle(.plain)
        .frame(minWidth: 620, minHeight: 400)
        .onReceive(NotificationCenter.default.publisher(for: .focusQuickTask)) { _ in quickFocused = true }
        .confirmationDialog("删除 \(deleting?.number ?? "")？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除任务及其关联", role: .destructive) { if let task = deleting { model.delete(task) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("只删除本地任务与关联记录，Codex 中的会话会保留。") }
    }
    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.snapshot.tasks) { task in
                    HStack(spacing: 10) {
                        Button { model.status(task, task.status == .done ? .todo : .done) } label: {
                            StatusCircle(status: task.status).frame(width: 14, height: 14)
                        }.help(task.status == .done ? "标为未开始" : "标为已完成").accessibilityLabel("切换 \(task.number) 完成状态")
                        Button { model.selectedTaskID = task.id } label: {
                            HStack(spacing: 8) {
                                Text(task.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(task.number).font(.system(size: 12, weight: .semibold)).fixedSize()
                            }.contentShape(Rectangle())
                        }.accessibilityIdentifier("task-row-\(task.id)")
                    }
                    .padding(.horizontal, 9).frame(height: 34)
                    .background(model.selectedTaskID == task.id ? ink.opacity(0.055) : Color.white)
                    .border(ink, width: model.selectedTaskID == task.id ? 1.5 : lineWidth)
                    .contextMenu {
                        Button("复制关联指令") { model.copyPrompt(task) }
                        Button("删除任务", role: .destructive) { deleting = task }
                    }
                }
                if model.snapshot.tasks.isEmpty {
                    Text("还没有任务").font(.system(size: 12)).padding(.top, 16)
                }
            }.padding(10)
        }.frame(maxHeight: .infinity).border(ink, width: lineWidth)
    }
    @ViewBuilder private var taskDetail: some View {
        if let task = model.selectedTask {
            TaskDetailView(model: model, task: task, onDelete: { deleting = task }).id(task.id)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Text("从一个任务开始").font(.system(size: 14))
                Text("在下方输入，按回车记录").font(.system(size: 12))
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity).border(ink, width: lineWidth)
        }
    }
}

private struct StatusCircle: View {
    let status: TaskStatus
    var body: some View {
        ZStack {
            Circle().stroke(ink, lineWidth: 1.2)
            if status == .doing { Circle().fill(ink).padding(4) }
            if status == .done { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
        }
    }
}

private struct TaskDetailView: View {
    @ObservedObject var model: AppModel
    let task: TaskItem
    let onDelete: () -> Void
    @State private var title = ""
    @State private var showingSessions = false
    @State private var copied = false
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        TextField("任务名称", text: $title).textFieldStyle(.plain)
                            .focused($titleFocused).onSubmit { saveTitle(); titleFocused = false }
                            .onChange(of: titleFocused) { focused in if !focused { saveTitle() } }
                            .frame(minWidth: 40, maxWidth: min(360, max(40, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 8)))
                            .accessibilityIdentifier("task-title")
                        Button(task.number) { model.copyPrompt(task); copied = true }
                            .font(.system(size: 12, weight: .semibold)).fixedSize()
                            .help(copied ? "已复制关联指令" : "复制关联指令")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 18) {
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            Button { model.status(task, status) } label: {
                                Text(status.label).fontWeight(task.status == status ? .semibold : .regular)
                                    .underline(task.status == status, color: ink)
                            }.accessibilityIdentifier("status-\(status.rawValue)")
                        }
                        Button("删除", action: onDelete).accessibilityIdentifier("delete-task")
                    }.font(.system(size: 12))
                }
                Button { showingSessions.toggle() } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .medium))
                        .frame(width: 20, height: 20).overlay(Circle().stroke(ink, lineWidth: 1.2))
                }
                .help("为任务关联更多 Codex 会话").accessibilityLabel("关联会话")
                .accessibilityIdentifier("attach-session")
                .popover(isPresented: $showingSessions, arrowEdge: .bottom) {
                    SessionPicker(model: model, task: task).frame(width: 380, height: 380)
                }
            }.padding(.horizontal, 2)
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(model.snapshot.sessions(for: task.id)) { session in
                        Button { model.open(session) } label: {
                            HStack(alignment: .top, spacing: 20) {
                                Text(session.title).font(.system(size: 13, weight: .semibold))
                                    .lineLimit(3).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(session.status.label).font(.system(size: 12)).fixedSize()
                            }
                            .padding(.horizontal, 18).padding(.vertical, 16)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
                            .contentShape(Rectangle()).border(ink, width: lineWidth)
                        }
                        .accessibilityIdentifier("session-\(session.id)")
                        .help("在 Codex 中打开此会话")
                        .contextMenu {
                            Button("在 Codex 中打开") { model.open(session) }
                            Button("解除关联") { model.detach(session) }
                        }
                    }
                    if model.snapshot.sessions(for: task.id).isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("还没有关联的 Codex Session").font(.system(size: 13, weight: .medium))
                            Text("点击右上角 ＋ 选择会话，或在任意 Codex 聊天中发送：").font(.system(size: 12))
                            Button(task.associationPrompt) { model.copyPrompt(task); copied = true }
                                .font(.system(size: 12, weight: .semibold)).help("点击复制")
                            if copied { Text("已复制").font(.system(size: 11)) }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).border(ink, width: lineWidth)
                    }
                }.padding(1)
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .border(ink, width: lineWidth)
        .onAppear { title = task.title }
        .onChange(of: task.title) { title = $0 }
        .onDisappear { saveTitle() }
    }
    private func saveTitle() { if !title.isEmpty { model.rename(task, title) } }
}

private struct SessionPicker: View {
    @ObservedObject var model: AppModel
    let task: TaskItem
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var moving: ObservedSession?
    @State private var copied = false
    private var filtered: [ObservedSession] {
        model.observations.filter { session in
            !model.snapshot.sessions(for: task.id).contains { $0.id == session.id }
                && (search.isEmpty || session.title.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关联 Codex 会话 · \(task.number)").font(.system(size: 14, weight: .semibold))
            HStack {
                Button(copied ? "已复制关联指令" : "复制关联指令") { model.copyPrompt(task); copied = true }
                Spacer()
                Button("打开 Codex") { model.copyPrompt(task); model.showCodex() }
            }.font(.system(size: 12))
            Text("同一任务可关联多个聊天；在新聊天中发送关联指令即可添加。")
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            TextField("搜索本机全部会话", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filtered) { session in
                        Button {
                            if model.snapshot.sessions.contains(where: { $0.id == session.id && $0.taskID != nil && $0.taskID != task.id }) { moving = session }
                            else { model.attach(session, to: task); dismiss() }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title).lineLimit(2).multilineTextAlignment(.leading)
                                HStack {
                                    Text(session.status.label)
                                    if let current = model.snapshot.sessions.first(where: { $0.id == session.id })?.taskID {
                                        Text("· 已关联 " + String(format: "T#%02lld", current))
                                    }
                                }.font(.system(size: 10))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10).border(ink, width: 1)
                        }
                    }
                    if filtered.isEmpty { Text(model.pickerMessage ?? "没有匹配的会话。可在 Codex 新建聊天后发送关联指令。").font(.system(size: 12)).padding(.vertical, 8) }
                }
            }
        }.padding(16).foregroundColor(ink).background(Color.white).buttonStyle(.plain)
        .onAppear { model.scheduleRead(delay: 0) }
        .confirmationDialog("将会话移到 \(task.number)？", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }), titleVisibility: .visible) {
            Button("移动关联") { if let session = moving { model.attach(session, to: task) }; moving = nil; dismiss() }
            Button("取消", role: .cancel) { moving = nil }
        } message: { Text("该会话会从原任务移出，原任务的其他会话不受影响。") }
    }
}

extension Notification.Name { static let focusQuickTask = Notification.Name("codexTasksLite.focusQuickTask") }
