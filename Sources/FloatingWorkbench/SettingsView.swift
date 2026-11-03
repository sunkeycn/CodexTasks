import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LiteCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @State private var draft: IntegrationSettings
    @State private var notice: String?
    @State private var noticeIsError = false
    init(model: AppModel, onClose: @escaping () -> Void) {
        self.model = model; self.onClose = onClose
        _draft = State(initialValue: model.settings)
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("设置").font(.system(size: 22, weight: .bold))
                    shortcutCard
                    connectionCard
                    hooksCard
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本地数据").font(.system(size: 14, weight: .semibold))
                        Text(model.store.url.deletingLastPathComponent().path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Text("任务和设置仅保存在当前电脑。迁移步骤见项目 README。").font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Button("在访达中打开") { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }
                        }
                    }.padding(16).settingsCard()
                    if let notice {
                        Text(notice).font(.system(size: 12)).foregroundColor(noticeIsError ? .red : .secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("settings-notice")
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Button("恢复默认值") { draft = IntegrationSettings() }
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                Button("保存设置") { save() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("save-settings")
            }.padding(16).background(Color.white)
        }
        .frame(width: 600, height: 620).background(Color(red: 0.975, green: 0.976, blue: 0.98))
        .foregroundColor(Color(red: 0.15, green: 0.19, blue: 0.24)).preferredColorScheme(.light)
        .onAppear { model.refreshHookInspection() }
        .onDisappear { model.isRecordingShortcut = false }
    }
    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("窗口形态").font(.system(size: 14, weight: .semibold))
            HStack {
                Text("切换快捷键").font(.system(size: 12))
                Spacer()
                ShortcutRecorder(shortcut: $draft.windowShortcut, model: model) { error in
                    notice = error; noticeIsError = error != nil
                }.frame(width: 240, height: 28)
                Button("恢复默认") { draft.windowShortcut = WindowShortcut() }
                    .accessibilityIdentifier("reset-window-shortcut")
            }
            Text("点击快捷键后按下新组合，保存后生效。依次切换隐藏、小窗口和正常窗口；右上角按钮可直接展开／收起详情。")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).settingsCard()
    }
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex 连接").font(.system(size: 14, weight: .semibold))
            Text("数据目录").font(.system(size: 12))
            HStack {
                TextField("Codex 数据目录", text: $draft.codexHome).textFieldStyle(.roundedBorder).accessibilityIdentifier("settings-codex-home")
                Button("选择…") { chooseHome() }
            }
            Text("默认使用 CODEX_HOME；未设置时使用当前用户的 ~/.codex。").font(.system(size: 11)).foregroundColor(.secondary)
            Text("Codex 应用").font(.system(size: 12))
            HStack {
                TextField("自动识别已注册的 Codex 应用", text: $draft.applicationPath).textFieldStyle(.roundedBorder).accessibilityIdentifier("settings-codex-app")
                Button("选择…") { chooseApplication() }
                Button("自动") { draft.applicationPath = "" }
            }
            Stepper("定时补查：\(Int(draft.refreshInterval)) 秒", value: $draft.refreshInterval, in: 5...600, step: 5).font(.system(size: 12))
            Stepper("运行状态超时：\(Int(draft.runningTimeout)) 秒", value: $draft.runningTimeout, in: 30...3600, step: 30).font(.system(size: 12))
            Text("较短的补查间隔更新更及时；超过超时时间没有活动时，运行状态显示为未知。").font(.system(size: 11)).foregroundColor(.secondary)
        }.padding(16).settingsCard()
    }
    private var hooksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex Hooks").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(hookStatus).font(.system(size: 11)).foregroundColor(model.hookInspection?.isInstalled == true ? .green : .secondary)
                    .accessibilityIdentifier("settings-hook-status")
            }
            Text("实时接收会话开始、完成和中断。只记录关联编号及运行状态，不保存聊天正文。未安装时仍可使用本地会话自动关联。")
                .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.hookInspectionError { Text(error).font(.system(size: 11)).foregroundColor(.red) }
            Text("首次安装或更新后，请在 Codex 的 Hooks 审阅界面确认信任（CLI：/hooks）。配置变更会保留其他 Hooks，并备份原文件。")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("安装 / 更新 Hooks") { install() }.accessibilityIdentifier("install-hooks")
                Button("移除本应用 Hooks") { remove() }.accessibilityIdentifier("remove-hooks")
                Spacer()
                Button("刷新") { model.refreshHookInspection() }
            }.disabled(draft != model.settings)
            if draft != model.settings { Text("请先保存连接设置，再配置 Hooks。").font(.system(size: 11)).foregroundColor(.secondary) }
        }.padding(16).settingsCard()
    }
    private var hookStatus: String {
        if model.hookInspectionError != nil { return "需要检查" }
        if model.hookInspection?.isInstalled == true { return "已配置（需在 Codex 中信任）" }
        if (model.hookInspection?.legacyHandlers ?? 0) > 0 { return "检测到旧版配置" }
        if model.hookInspection?.installedEvents.isEmpty == false { return "配置不完整" }
        return "未配置"
    }
    private func save() {
        if model.applySettings(draft) {
            draft = model.settings; noticeIsError = false; notice = "设置已保存，连接已按新配置刷新。"
        } else { noticeIsError = true; notice = model.errorMessage }
    }
    private func install() {
        do {
            let backup = try model.installHooks()
            noticeIsError = false
            notice = "Hooks 已配置。请在 Codex 中审阅并信任新配置后开始新会话。" + (backup.map { "\n原配置备份：" + $0.path } ?? "")
        } catch { noticeIsError = true; notice = error.localizedDescription }
    }
    private func remove() {
        do {
            let backup = try model.removeHooks()
            noticeIsError = false
            notice = "已移除本应用的 Hooks，其他 Hooks 保留。" + (backup.map { "\n原配置备份：" + $0.path } ?? "")
        } catch { noticeIsError = true; notice = error.localizedDescription }
    }
    private func chooseHome() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.showsHiddenFiles = true; panel.directoryURL = draft.homeURL; panel.prompt = "选择 Codex 目录"
        if panel.runModal() == .OK, let url = panel.url { draft.codexHome = url.path }
    }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.prompt = "选择 Codex 应用"
        if panel.runModal() == .OK, let url = panel.url { draft.applicationPath = url.path }
    }
}

private extension View {
    func settingsCard() -> some View {
        background(Color.white).cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.05), lineWidth: 1))
    }
}
