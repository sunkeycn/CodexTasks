import SwiftUI
import WorkbenchCore

@MainActor public struct FlowWorkbenchView: View {
    @StateObject private var model: FlowWorkbenchModel
    @State private var showConnection = false
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var projectFilter = "all"
    @State private var environmentFilter = "all"
    @State private var statusFilter = "all"
    @State private var tab = "概览"
    public init(service: WorkbenchService, initialConnectionID: UUID? = nil, initialPipelineID: String? = nil) {
        let value = FlowWorkbenchModel(service: service)
        if let id = initialConnectionID, value.state.connections.contains(where: { $0.id == id }) { value.chooseConnection(id) }
        if let id = initialPipelineID, value.cache?.definitions.contains(where: { $0.id == id }) == true { value.selectedID = id }
        _model = StateObject(wrappedValue: value)
        _tab = State(initialValue: initialPipelineID == nil ? "概览" : "运行记录")
    }
    private var flows: [PipelineDefinition] {
        (model.cache?.definitions ?? []).filter { flow in
            let binding = model.cache?.bindings[flow.id]
            let projects = binding?.sourceProjects.values.flatMap { $0 } ?? []
            let environments = binding?.targets.map(\.environment) ?? []
            let latest = model.cache?.runs[flow.id]?.first
            return (!favoritesOnly || model.cache?.favorites.contains(flow.id) == true)
                && (search.isEmpty || flow.name.localizedCaseInsensitiveContains(search) || flow.id.contains(search))
                && (projectFilter == "all" || (projectFilter == "none" ? projects.isEmpty : projects.contains { $0.uuidString == projectFilter }))
                && (environmentFilter == "all" || (environmentFilter == "none" ? environments.isEmpty && binding?.mode != .ci : environments.contains(environmentFilter)))
                && (statusFilter == "all" || (statusFilter == "unloaded" ? latest == nil : latest?.status == statusFilter))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let message = model.message { Text(message).font(.callout).foregroundColor(.orange).textSelection(.enabled) }
            if model.connection != nil {
                Toggle("允许本次读取：所选站点/组织目录及所选 Flow、实例、日志，可能包含生产资源。", isOn: $model.readScopeAuthorized).font(.caption).disabled(model.busy)
                Text("读取不会执行 Flow。运行需另行核对范围；生产提交在版本锁定能力验证前不可用。").font(.caption2).foregroundColor(.secondary)
                Divider()
                if let flow = model.definition {
                    HStack {
                        Button { model.stop(); model.selectedID = nil; model.preview = nil } label: { Label("返回流水线", systemImage: "chevron.left") }.disabled(model.busy)
                        Text(flow.name).font(.headline).lineLimit(1); Text("#\(flow.id)").font(.caption.monospaced()).foregroundColor(.secondary)
                        Spacer()
                        Button { model.favorite(flow) } label: { Image(systemName: model.cache?.favorites.contains(flow.id) == true ? "star.fill" : "star") }
                    }
                    Picker("详情", selection: $tab) { ForEach(["概览", "运行记录", "关联配置", "运行配置"], id: \.self) { Text($0) } }.pickerStyle(.segmented).disabled(model.busy)
                    Group {
                        switch tab {
                        case "关联配置": FlowBindingEditor(model: model, definition: flow).id(flow.id + flow.revision)
                        case "运行配置": FlowRunEditor(model: model, definition: flow).id(flow.id + flow.revision + ((try? FlowIdentity.digest(model.binding ?? PipelineBinding(pipelineID: flow.id))) ?? ""))
                        case "运行记录": FlowHistoryView(model: model, definition: flow)
                        default: overview(flow)
                        }
                    }
                } else { directory }
            } else {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 38)).foregroundColor(.secondary)
                    Text("连接云效，查看你的流水线").font(.title3.bold())
                    Text("完整目录 · 本地关注 · 项目与环境关联 · 参数化运行").font(.callout).foregroundColor(.secondary)
                    Button("连接云效") { showConnection = true }.buttonStyle(.borderedProminent)
                    Text("支持 PAT；浏览器 OAuth 路径需结合实际站点联调。").font(.caption).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            }
        }.padding(20)
        .sheet(isPresented: $showConnection) { FlowConnectionView(model: model) }
        .onAppear { restoreDirectoryPreference() }
        .onChange(of: favoritesOnly) { value in
            if let id = model.connection?.id { UserDefaults.standard.set(value, forKey: "cicd.favoritesOnly." + id.uuidString) }
        }
        .onChange(of: model.state.selectedConnectionID) { _ in
            search = ""; projectFilter = "all"; environmentFilter = "all"; statusFilter = "all"; restoreDirectoryPreference()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.readScopeAuthorized) { allowed in if !allowed { model.stop(); model.preview = nil; model.log = "" } }

    }
    private func restoreDirectoryPreference() {
        guard let id = model.connection?.id else { favoritesOnly = false; return }
        favoritesOnly = !(model.cache?.favorites.isEmpty ?? true) && UserDefaults.standard.bool(forKey: "cicd.favoritesOnly." + id.uuidString)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CI/CD").font(.system(size: 24, weight: .bold)); Spacer()
                if model.busy { ProgressView().controlSize(.small); Button("停止等待") { model.stop() } }
                Button("连接设置") { showConnection = true }.disabled(model.busy)
                if model.connection != nil { Button("刷新目录") { model.refreshCatalog() }.disabled(model.busy || !model.readScopeAuthorized) }
            }
            if let c = model.connection {
                HStack {
                    Menu(c.label) { ForEach(model.state.connections) { item in Button(item.label) { model.chooseConnection(item.id) } } }.disabled(model.busy)
                    Text(c.readOnly ? "本地只读" : "允许非生产运行").font(.caption).foregroundColor(c.readOnly ? .secondary : .orange)
                    Spacer()
                    if let date = model.cache?.syncedAt { Text("目录同步 \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundColor(.secondary) }
                }
            }
        }
    }
    private var directory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("目录", selection: $favoritesOnly) { Text("全部流水线").tag(false); Text("我的关注（本地）").tag(true) }.pickerStyle(.segmented)
            TextField("搜索名称或流水线 ID", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Picker("项目", selection: $projectFilter) {
                    Text("全部").tag("all"); Text("未关联").tag("none")
                    ForEach(model.localSnapshot.projects) { Text($0.name).tag($0.id.uuidString) }
                }
                Picker("环境", selection: $environmentFilter) {
                    Text("全部").tag("all"); Text("未关联").tag("none")
                    ForEach(Array(Set((model.cache?.bindings.values.flatMap { $0.targets.map(\.environment) }) ?? [])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("状态", selection: $statusFilter) {
                    Text("全部").tag("all"); Text("尚未加载").tag("unloaded"); Text("成功").tag("SUCCESS"); Text("失败").tag("FAIL"); Text("运行中").tag("RUNNING"); Text("排队").tag("WAITING"); Text("取消").tag("CANCELED"); Text("未知").tag("UNKNOWN")
                }
            }.font(.caption)
            HStack { Text("\(flows.count) 条流水线").font(.caption).foregroundColor(.secondary); Spacer(); Text("星标仅保存在本机，不同步云效网页收藏").font(.caption2).foregroundColor(.secondary) }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if flows.isEmpty { Text(model.cache?.syncedAt == nil ? "尚未读取目录。确认读取范围后刷新。" : "当前筛选下没有流水线。读取错误会保留旧缓存。 ").foregroundColor(.secondary).padding(28) }
                    ForEach(flows) { flow in
                        HStack(alignment: .top, spacing: 12) {
                            Button { model.favorite(flow) } label: { Image(systemName: model.cache?.favorites.contains(flow.id) == true ? "star.fill" : "star").foregroundColor(.orange) }.buttonStyle(.plain).padding(.top, 3)
                            Button { model.select(flow.id); tab = "概览" } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(flow.name).font(.headline).foregroundColor(.primary)
                                    Text("#\(flow.id) · \(projectNames(flow))").font(.caption).foregroundColor(.secondary)
                                    Text(environmentSummary(flow)).font(.caption).foregroundColor(.secondary)
                                    Text(model.cache?.runs[flow.id].map { $0.first.map { "最近实例 #\($0.id) · \($0.statusLabel)" } ?? "从未运行" } ?? "最近运行尚未加载").font(.caption2).foregroundColor(.secondary)
                                    if !flow.available { Text("当前账号目录中不可用；保留关注和历史").font(.caption).foregroundColor(.orange) }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.busy)
                            Button("运行") { model.select(flow.id); tab = "运行配置" }.disabled(model.busy || !flow.available)
                        }.padding(14).background(Color.white).cornerRadius(10)
                    }
                }
            }
        }
    }
    private func projectNames(_ flow: PipelineDefinition) -> String {
        let ids = Set(model.cache?.bindings[flow.id]?.sourceProjects.values.flatMap { $0 } ?? [])
        let names = model.localSnapshot.projects.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? "项目未关联" : names.joined(separator: "、")
    }
    private func environmentSummary(_ flow: PipelineDefinition) -> String {
        guard let b = model.cache?.bindings[flow.id] else { return "环境未关联" }
        if b.mode == .ci { return "不涉及部署（已人工核对）" }
        return (b.mode == .runtime ? "运行时选择 · " : "固定目标 · ") + b.targets.map(\.environment).joined(separator: "、")
    }
    private func overview(_ flow: PipelineDefinition) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(flow.detailLoaded ? "定义已加载" : "尚未加载详情").font(.headline); Spacer(); Button("读取最新定义") { model.loadDetail() }.disabled(model.busy || !model.readScopeAuthorized) }
                Text(projectNames(flow)); Text(environmentSummary(flow))
                if flow.detailLoaded {
                    Text("配置版本 \(flow.revision.prefix(16))").font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(flow.sources) { source in
                        VStack(alignment: .leading, spacing: 4) { Text("代码源 \(source.id)").font(.headline); Text(source.repo).textSelection(.enabled); Text("默认分支：\(source.branch.isEmpty ? "未提供" : source.branch)").foregroundColor(.secondary) }.font(.caption)
                    }
                    ForEach(flow.blockers, id: \.self) { Text($0).foregroundColor(.orange) }
                    if let b = model.binding {
                        Text(b.definitionRevision == flow.revision ? "关联与当前定义一致" : "定义已变化：请重新核对关联与参数").foregroundColor(b.definitionRevision == flow.revision ? .secondary : .orange)
                        Text("依据：\(b.evidence)").font(.caption)
                    }
                    Text("运行变量与部署脚本尚不能可靠自动解析，请在关联配置中补配并核对完整范围。名称、envId 与本地分支不会改变远端部署行为。").font(.callout).foregroundColor(.secondary)
                }
                Button("配置项目、环境和运行参数") { tab = "关联配置" }.disabled(!flow.detailLoaded)
                Text("当前客户端未验证不可变版本锁定能力，生产运行被阻止。").font(.caption).foregroundColor(.orange)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.white).cornerRadius(10)
        }
    }
}

@MainActor private struct FlowConnectionView: View {
    @ObservedObject var model: FlowWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var connection = YunxiaoConnection()
    @State private var pat = ""
    @State private var acknowledged = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("连接云效").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.disabled(model.busy) }
            Picker("站点", selection: $connection.site) { Text("中心站").tag(YunxiaoSite.central); Text("Region 实例").tag(YunxiaoSite.region) }.pickerStyle(.segmented)
            if connection.site == .region { TextField("实例 HTTPS 地址", text: $connection.origin) }
            else { Text("中心站：openapi-rdc.aliyuncs.com").font(.caption); TextField("组织 ID", text: $connection.organization) }
            TextField("账号标识（用于显示；每次授权单独隔离缓存）", text: $connection.account)
            Picker("认证方式", selection: $connection.auth) { Text("PAT").tag(YunxiaoAuth.pat); Text("浏览器 OAuth（待站点联调）").tag(YunxiaoAuth.oauth) }.pickerStyle(.segmented)
            if connection.auth == .pat { SecureField("个人访问令牌 · 仅保存到 Keychain", text: $pat) }
            else { Text("OAuth 使用 PKCE S256 和站点元数据发现。令牌拥有授权用户同等资源权限；本地只读模式不会缩减 OAuth 权限。回调与 API 令牌传递尚需实际站点验证。").font(.caption).foregroundColor(.secondary) }
            Toggle("本地只读模式", isOn: $connection.readOnly)
            Text("目标：\(connection.origin)\n组织：\(connection.site == .region ? "Region 实例" : (connection.organization.isEmpty ? "待填写" : connection.organization))\n动作：读取有权访问的完整流水线目录，可能涉及生产资源；不触发运行。OAuth 还会注册公共客户端并打开浏览器授权。").font(.caption).textSelection(.enabled)
            Toggle("我确认以上站点、组织及读取范围", isOn: $acknowledged).font(.callout)
            if let message = model.message { Text(message).font(.caption).foregroundColor(.orange) }
            HStack {
                if model.connection != nil { Button("断开当前连接") { model.disconnect() }.disabled(model.busy) }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(connection.auth == .pat ? "测试连接并保存" : "在浏览器授权并测试") { model.connect(connection, pat: pat); pat = "" }.buttonStyle(.borderedProminent).disabled(model.busy || !acknowledged || connection.account.isEmpty || (connection.auth == .pat && pat.isEmpty))
            }
            Text("断开仅清除本机凭据，不承诺远端撤销。新版 OpenAPI 使用独立 HTTP 传输，不读取已有 CLI profile 或浏览器 Cookie。").font(.caption2).foregroundColor(.secondary)
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 580)
        .onChange(of: connection.site) { site in connection.origin = site == .central ? "https://openapi-rdc.aliyuncs.com" : ""; acknowledged = false }
        .onChange(of: connection.origin) { _ in acknowledged = false }
        .onChange(of: connection.organization) { _ in acknowledged = false }
        .onChange(of: model.state.selectedConnectionID) { id in if id == connection.id { dismiss() } }
    }
}
