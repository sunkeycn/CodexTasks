import SwiftUI
import AppKit
import LiteCore

// Preserve the full version's visual language; the wireframe specifies layout only.
private let ink = Color(red: 0.15, green: 0.19, blue: 0.24)
private let accent = Color(red: 0.18, green: 0.39, blue: 0.86)
private let canvas = Color(red: 0.975, green: 0.976, blue: 0.98)
private let sidebarColor = Color(red: 0.945, green: 0.953, blue: 0.969)

struct RootView: View {
    @ObservedObject var model: AppModel
    @FocusState private var quickFocused: Bool
    @State private var deleting: TaskItem?
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                taskList.frame(width: 220)
                Divider()
                taskDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(message).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark").foregroundColor(.secondary) }.help("关闭提示")
                }.padding(12).background(Color.orange.opacity(0.09))
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").foregroundColor(accent).font(.title3)
                TextField("快速记录一个任务…", text: $model.draft)
                    .textFieldStyle(.plain).focused($quickFocused).onSubmit { model.addTask() }
                    .accessibilityLabel("快速记录一个任务").accessibilityIdentifier("quick-task-input")
                Text("↩ 新建").font(.caption).foregroundColor(.secondary)
                Button("添加") { model.addTask(); quickFocused = true }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("创建任务并复制关联指令（回车）").accessibilityLabel("创建任务")
            }
            .padding(.horizontal, 20).padding(.vertical, 13).background(Color.white)
        }
        .foregroundColor(ink).background(canvas).preferredColorScheme(.light).tint(accent)
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
            LazyVStack(spacing: 8) {
                ForEach(model.snapshot.tasks) { task in
                    HStack(spacing: 10) {
                        Button { model.status(task, task.status == .done ? .todo : .done) } label: {
                            StatusCircle(status: task.status).frame(width: 18, height: 18)
                        }.help(task.status == .done ? "标为未开始" : "标为已完成").accessibilityLabel("切换 \(task.number) 完成状态")
                        Button { model.selectedTaskID = task.id } label: {
                            HStack(spacing: 8) {
                                Text(task.title).font(.system(size: 13, weight: .medium))
                                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                TaskNumberTag(number: task.number)
                            }.contentShape(Rectangle())
                        }.accessibilityIdentifier("task-row-\(task.id)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 13)
                    .background(model.selectedTaskID == task.id ? accent.opacity(0.09) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contextMenu {
                        Button("复制关联指令") { model.copyPrompt(task) }
                        Button("删除任务", role: .destructive) { deleting = task }
                    }
                }
                if model.snapshot.tasks.isEmpty {
                    Text("还没有任务").font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 16)
                }
            }.padding(12)
        }.frame(maxHeight: .infinity).background(sidebarColor)
    }
    @ViewBuilder private var taskDetail: some View {
        if let task = model.selectedTask {
            TaskDetailView(model: model, task: task, onDelete: { deleting = task }).id(task.id)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "checklist").font(.system(size: 30, weight: .light)).foregroundColor(accent.opacity(0.5))
                Text("从一个任务开始").font(.headline)
                Text("在下方输入，按回车记录").font(.callout).foregroundColor(.secondary)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TaskNumberTag: View {
    let number: String
    var body: some View {
        Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(accent)
            .padding(.horizontal, 6).padding(.vertical, 3).background(accent.opacity(0.08)).cornerRadius(4).fixedSize()
    }
}

private struct StatusCircle: View {
    let status: TaskStatus
    var body: some View {
        ZStack {
            Circle().stroke(status == .todo ? Color.gray.opacity(0.5) : status == .done ? .green : accent, lineWidth: 1.2)
            if status == .doing { Circle().fill(accent).padding(5) }
            if status == .done { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundColor(.green) }
        }
    }
}

private struct SessionStatusTag: View {
    let status: SessionStatus
    private var color: Color {
        switch status {
        case .running: return accent
        case .completed: return .green
        case .interrupted: return .orange
        case .failed: return .red
        case .idle, .unknown: return .gray
        }
    }
    var body: some View {
        Text(status.label).font(.system(size: 10, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 7).padding(.vertical, 4).background(color.opacity(0.09)).cornerRadius(5).fixedSize()
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        TextField("任务名称", text: $title).textFieldStyle(.plain)
                            .font(.system(size: 22, weight: .bold))
                            .focused($titleFocused).onSubmit { saveTitle(); titleFocused = false }
                            .onChange(of: titleFocused) { focused in if !focused { saveTitle() } }
                            .frame(minWidth: 40, maxWidth: min(360, max(40, (title as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22)]).width + 8)))
                            .accessibilityIdentifier("task-title")
                        Button { model.copyPrompt(task); copied = true } label: { TaskNumberTag(number: task.number) }
                            .help(copied ? "已复制关联指令" : "复制关联指令")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 16) {
                        HStack(spacing: 2) {
                            ForEach(TaskStatus.allCases, id: \.self) { status in
                                Button { model.status(task, status) } label: {
                                    Text(status.label).font(.system(size: 12, weight: task.status == status ? .semibold : .regular))
                                        .foregroundColor(task.status == status ? .white : ink.opacity(0.8))
                                        .padding(.horizontal, 11).padding(.vertical, 5)
                                        .background(task.status == status ? accent : .clear).cornerRadius(5)
                                }.accessibilityIdentifier("status-\(status.rawValue)")
                            }
                        }.padding(2).background(Color.black.opacity(0.045)).cornerRadius(7)
                        Button(action: onDelete) { Label("删除", systemImage: "trash").font(.system(size: 12)).foregroundColor(.secondary) }
                            .accessibilityIdentifier("delete-task")
                    }
                }
                Button { showingSessions.toggle() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundColor(accent)
                        .frame(width: 30, height: 30).background(accent.opacity(0.08)).clipShape(Circle())
                }
                .help("为任务关联更多 Codex 会话").accessibilityLabel("关联会话")
                .accessibilityIdentifier("attach-session")
                .popover(isPresented: $showingSessions, arrowEdge: .bottom) {
                    SessionPicker(model: model, task: task).frame(width: 380, height: 380)
                }
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.snapshot.sessions(for: task.id)) { session in
                        Button { model.open(session) } label: {
                            HStack(alignment: .center, spacing: 20) {
                                Text(session.title).font(.system(size: 13, weight: .semibold))
                                    .lineLimit(3).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                SessionStatusTag(status: session.status)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 18)
                            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                            .contentShape(Rectangle()).taskCard()
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
                            Text("还没有关联的 Codex Session").font(.system(size: 13, weight: .semibold))
                            Text("点击右上角 ＋ 选择会话，或在任意 Codex 聊天中发送：")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                Button { model.copyPrompt(task); copied = true } label: {
                                    Label(task.associationPrompt, systemImage: "doc.on.doc").font(.system(size: 12, design: .monospaced)).foregroundColor(accent)
                                }.help("点击复制")
                                if copied { Text("已复制").font(.system(size: 11)).foregroundColor(.secondary) }
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).taskCard()
                    }
                }.padding(1)
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                Button(copied ? "已复制关联指令" : "复制关联指令") { model.copyPrompt(task); copied = true }.foregroundColor(accent)
                Spacer()
                Button("打开 Codex") { model.copyPrompt(task); model.showCodex() }.foregroundColor(accent)
            }.font(.system(size: 12))
            Text("同一任务可关联多个聊天；在新聊天中发送关联指令即可添加。")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("搜索本机全部会话", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filtered) { session in
                        Button {
                            if model.snapshot.sessions.contains(where: { $0.id == session.id && $0.taskID != nil && $0.taskID != task.id }) { moving = session }
                            else { model.attach(session, to: task); dismiss() }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                HStack {
                                    SessionStatusTag(status: session.status)
                                    if let current = model.snapshot.sessions.first(where: { $0.id == session.id })?.taskID {
                                        Text("已关联 " + String(format: "T#%02lld", current)).font(.system(size: 10)).foregroundColor(.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).taskCard()
                        }
                    }
                    if filtered.isEmpty { Text(model.pickerMessage ?? "没有匹配的会话。可在 Codex 新建聊天后发送关联指令。").font(.system(size: 12)).foregroundColor(.secondary).padding(.vertical, 8) }
                }.padding(1)
            }
        }.padding(16).foregroundColor(ink).background(canvas).preferredColorScheme(.light).tint(accent).buttonStyle(.plain)
        .onAppear { model.scheduleRead(delay: 0) }
        .confirmationDialog("将会话移到 \(task.number)？", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }), titleVisibility: .visible) {
            Button("移动关联") { if let session = moving { model.attach(session, to: task) }; moving = nil; dismiss() }
            Button("取消", role: .cancel) { moving = nil }
        } message: { Text("该会话会从原任务移出，原任务的其他会话不受影响。") }
    }
}

private extension View {
    func taskCard() -> some View {
        background(Color.white).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.05), lineWidth: 1))
    }
}

extension Notification.Name { static let focusQuickTask = Notification.Name("codexTasksLite.focusQuickTask") }
